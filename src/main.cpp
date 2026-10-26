/*
 * MixedInputFix - RED4ext plugin
 *
 * Works around the Cyberpunk 2077 2.11+ freeze and input-hint flicker with
 * mixed controls (gamepad + real/emulated mouse, e.g. Steam Controller /
 * Steam Deck / gyro aim). The UI's notion of the "current input device" is
 * pinned to the device of your choice (see Modes below). The raw input
 * layer is never touched - mouse, cursor and all input handling keep
 * working normally.
 *
 * Three cooperating layers (full reverse-engineering record: ../RE-notes.md):
 *
 *  1. Writer suppression (the core fix): the ink UI device field
 *     [[InkSystem]+0x210]+0x1E0 has a single steady-state writer (InkSystem
 *     method, hash 3719303744). The hook derives the would-be value exactly
 *     like the writer does (provider vcall) and skips the writer entirely
 *     when it would switch the field off the pinned device: no field
 *     write, no listener broadcasts, no hint churn. This removes the per-
 *     event UI work whose accumulation caused the 20-60 min freeze.
 *
 *  2. Script-side stickiness: redscript reads the device through the
 *     virtual natives GameObject::PlayerLastUsedKBM/Pad/PS5Pad. All script
 *     calls funnel through their registered native handlers (hashes
 *     1037639234 / 1291656829 / 2647269205); the hooks force the returned
 *     bools to answers consistent with the pinned device (per-mode values
 *     in ScriptDesired()). This fixes the contextual HUD hint widget
 *     flickering between its KBM/pad layouts, and keeps every script
 *     device check coherent.
 *
 *  3. Fallback latch (watchdog): hooks on the hint icon refresh (hash
 *     4042789608) and inkSystem::ProcessInputEvents (hash 673454961)
 *     restore the pinned value if anything else ever appears in the field
 *     anyway (e.g. written by session-init code outside the hooked
 *     writer). Restores are logged as warnings: any of them during normal
 *     play means a game patch introduced a new writer path. If the writer
 *     hook ever fails to attach, this latch alone still provides the
 *     proven v0.6-level fix.
 *
 * Modes (MixedInputFix.ini "mode"): "controller" (default) pins the UI to
 * the gamepad as described above - vanilla until the first gamepad input.
 * "kbm" is the mirror image for players whose primary is keyboard/mouse
 * with auxiliary analog inputs (e.g. movement on a stick): switches *to*
 * gamepad are suppressed instead, and the script natives answer
 * keyboard/mouse; active from boot since KBD_MOUSE is the field's boot
 * state. Both modes pin the field to a constant, so both remove the
 * flip churn that causes the freeze.
 *
 * Game builds: the hooks resolve through RED4ext's address library and are
 * patch-stable, but the struct offsets are not. The plugin reads the game
 * executable's file version and picks its offsets from the kBindings table.
 * An unlisted build falls back to the newest known row and verifies it at
 * runtime before changing anything; if that fails, the offset-dependent
 * layers stay off rather than write to a wrong address.
 *
 * Optional config: MixedInputFix.ini next to the DLL ("enabled", "mode",
 * "verbose").
 * Opt-in diagnostic: an empty file MixedInputFix.diag next to the DLL arms
 * a hardware write-watchpoint that logs the field's writer RIPs - the
 * re-porting tool for new game patches (see README.md and RE-notes.md,
 * "Porting to a new game patch"; struct offsets below are 2.31).
 */

#include <RED4ext/RED4ext.hpp>
#include <RED4ext/Api/v1/EMainReason.hpp>
#include <RED4ext/Api/v1/PluginHandle.hpp>
#include <RED4ext/Api/v1/PluginInfo.hpp>
#include <RED4ext/Api/v1/Runtime.hpp>
#include <RED4ext/Api/v1/Sdk.hpp>
#include <RED4ext/Api/v1/Version.hpp>
#include <RED4ext/Api/ApiVersion.hpp>
#include <RED4ext/Relocation.hpp>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include <Windows.h>
#include <winver.h> // VS_FIXEDFILEINFO / GetFileVersionInfo (not pulled in by
                    // Windows.h under WIN32_LEAN_AND_MEAN)

namespace
{
// ---------------------------------------------------------------------------
// Version (single source for Query() and the startup banner)
// ---------------------------------------------------------------------------
constexpr std::uint8_t VerMajor = 1;
constexpr std::uint16_t VerMinor = 1;
constexpr std::uint32_t VerPatch = 0;
constexpr const char* VersionStr = "1.1.0";

// ---------------------------------------------------------------------------
// Game binding: address-library hashes and struct offsets.
//
// The hashes are shared by every game build - the address library maps them to
// the right address per patch, which is what makes the hooks patch-stable.
// Only the struct offsets move, so supporting a new build is one row in
// kBindings below (re-derivation procedure in RE-notes.md, "Porting to a new
// game patch").
//
// On a build that is not in the table the newest row is used as a fallback and
// verified at runtime before anything is suppressed or written - see
// BindingCheck. Most hotfixes do not move these structs, so the fallback
// usually just works; when it does not, the offset-dependent layers stay off
// instead of writing to a wrong address.
// ---------------------------------------------------------------------------
constexpr std::uint32_t InkSystemInstance_Hash = 2635337807u;    // &InkSystem*
constexpr std::uint32_t HintRefresh_Hash = 4042789608u;          // 2.31: 0x1404a3090
constexpr std::uint32_t ProcessInputEvents_Hash = 673454961u;    // 2.31: 0x14039bb18
constexpr std::uint32_t DeviceWriter_Hash = 3719303744u;         // 2.31: 0x140269954
constexpr std::uint32_t LastUsedKBMThunk_Hash = 1037639234u;     // 2.31: 0x1404d70e8
constexpr std::uint32_t LastUsedPadThunk_Hash = 1291656829u;     // 2.31: 0x14188e878
constexpr std::uint32_t LastUsedPS5PadThunk_Hash = 2647269205u;  // 2.31: 0x141cad8d0

struct GameBinding
{
    RED4ext::v1::FileVer version;   // game executable file version
    const char* label;              // patch name, for logs
    std::size_t hintManager;        // InkSystem -> manager ptr
    std::size_t hintDevice;         // manager -> input::EInputDevice
    std::size_t deviceProvider;     // InkSystem -> device state provider
    std::size_t vtblGetDeviceValue; // provider vfunc: current EInputDevice
};

// One row per supported build, newest LAST (the last row is also the fallback
// for unlisted builds). Not constexpr: RED4EXT_V1_RUNTIME_VERSION_* expand to
// CreateFileVer() calls, so this is dynamically initialised at DLL load, well
// before Main() runs.
const GameBinding kBindings[] = {
    {RED4EXT_V1_RUNTIME_VERSION_2_31, "2.31", 0x210, 0x1E0, 0x300, 0x218},
    {RED4EXT_V1_RUNTIME_VERSION_2_50, "2.5", 0x210, 0x1F8, 0x300, 0x228},
};
constexpr std::size_t BindingCount = sizeof(kBindings) / sizeof(kBindings[0]);

// Offsets actually in use; filled in from the selected binding in Main()
// before any hook is attached.
const GameBinding* g_binding = nullptr;
bool g_bindingExact = false;
std::size_t g_offHintManager = 0;
std::size_t g_offHintDevice = 0;
std::size_t g_offDeviceProvider = 0;
std::size_t g_vtblGetDeviceValue = 0;

// input::EInputDevice (RED4ext.SDK Generated/input/EInputDevice.hpp)
constexpr std::uint32_t EInputDevice_KBD_MOUSE = 1;
// PS5 pad. The game's own PlayerLastUsedPS5Pad handler is exactly
// `GetLastUsedDevice() == 9`, which the PS5Pad hook mirrors.
constexpr std::uint32_t EInputDevice_PROSPERO = 9;
// Highest PC pad. 2.5 added NINTENDO_TOUCH = 10 (EID_COUNT 10 -> 11), a
// Switch 2 device that never occurs on PC, so it stays outside the pad range.
constexpr std::uint32_t EInputDevice_Max = 9;

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
using HintRefresh_t = void (*)(void* aController);
using ProcessInputEvents_t = void (*)(void* aInkSystem, std::uint64_t aArg2, void* aBuffer);
using DeviceWriter_t = void (*)(void* aInkSystem);
// Registered native function handler: (context, stack frame, out value, rtti type)
using NativeHandler_t = void (*)(void* aContext, void* aFrame, void* aRet, std::int64_t aRtti);

HintRefresh_t g_refreshOriginal = nullptr;
void* g_refreshTarget = nullptr;

ProcessInputEvents_t g_pieOriginal = nullptr;
void* g_pieTarget = nullptr;

DeviceWriter_t g_writerOriginal = nullptr;
void* g_writerTarget = nullptr;

NativeHandler_t g_lastKBMOriginal = nullptr;
void* g_lastKBMTarget = nullptr;

NativeHandler_t g_lastPadOriginal = nullptr;
void* g_lastPadTarget = nullptr;

NativeHandler_t g_lastPS5PadOriginal = nullptr;
void* g_lastPS5PadTarget = nullptr;

void** g_inkSystemPtr = nullptr; // address of the singleton pointer

RED4ext::v1::PluginHandle g_handle = nullptr;
const RED4ext::v1::Sdk* g_sdk = nullptr;

std::atomic<std::uint32_t> g_lastPadDevice{0}; // 0 = none seen yet
std::atomic<bool> g_padAnnounced{false};
std::atomic<std::uint32_t> g_writerLastVal{0xFFFFFFFFu};
std::atomic<std::uint64_t> g_writerTransitions{0};
std::atomic<std::uint64_t> g_suppressed{0};
std::atomic<std::uint64_t> g_restores{0};
std::atomic<std::uint64_t> g_kbmOverrides{0};
std::atomic<std::uint64_t> g_padOverrides{0};
std::atomic<std::uint64_t> g_ps5PadOverrides{0};

// Offset trust state. Stays Trusted for a build that is in kBindings, so the
// exact-match path behaves exactly as it did before this was introduced.
enum class BindingCheck
{
    Trusted,  // offsets confirmed: exact table match, or fallback that passed
    Sampling, // fallback offsets under test - nothing suppressed or written yet
    Failed,   // fallback offsets look wrong - offset-dependent layers disabled
};
std::atomic<BindingCheck> g_bindingCheck{BindingCheck::Trusted};
std::atomic<int> g_bindingSamples{0};
std::atomic<int> g_bindingInRange{0};
std::atomic<int> g_bindingMatches{0};
constexpr int BindingSamplesNeeded = 10;

// ---------------------------------------------------------------------------
// Config: MixedInputFix.ini next to the DLL (missing file = defaults)
// ---------------------------------------------------------------------------
enum class StickyMode
{
    Controller, // pin UI to the last used gamepad (armed by first gamepad input)
    KBM,        // pin UI to keyboard/mouse (active from boot)
};

bool g_cfgEnabled = true;
StickyMode g_cfgMode = StickyMode::Controller;
bool g_cfgVerbose = false;

bool ParseBool(const char* aValue, bool aDefault)
{
    if (_stricmp(aValue, "true") == 0 || strcmp(aValue, "1") == 0 || _stricmp(aValue, "yes") == 0 ||
        _stricmp(aValue, "on") == 0)
    {
        return true;
    }
    if (_stricmp(aValue, "false") == 0 || strcmp(aValue, "0") == 0 || _stricmp(aValue, "no") == 0 ||
        _stricmp(aValue, "off") == 0)
    {
        return false;
    }
    return aDefault;
}

void LoadConfig(const wchar_t* aDir)
{
    wchar_t path[MAX_PATH]{};
    swprintf_s(path, L"%sMixedInputFix.ini", aDir);
    FILE* file = nullptr;
    if (_wfopen_s(&file, path, L"r") != 0 || !file)
    {
        return;
    }
    char line[256];
    while (fgets(line, sizeof(line), file))
    {
        char key[64]{};
        char value[64]{};
        if (sscanf_s(line, " %63[A-Za-z_] = %63[A-Za-z0-9]", key, static_cast<unsigned>(sizeof(key)), value,
                     static_cast<unsigned>(sizeof(value))) != 2)
        {
            continue; // comments, sections, blanks
        }
        if (_stricmp(key, "enabled") == 0)
        {
            g_cfgEnabled = ParseBool(value, g_cfgEnabled);
        }
        else if (_stricmp(key, "mode") == 0)
        {
            if (_stricmp(value, "kbm") == 0 || _stricmp(value, "keyboard") == 0)
            {
                g_cfgMode = StickyMode::KBM;
            }
            else if (_stricmp(value, "controller") == 0 || _stricmp(value, "gamepad") == 0 ||
                     _stricmp(value, "pad") == 0)
            {
                g_cfgMode = StickyMode::Controller;
            }
            // unknown value: keep default
        }
        else if (_stricmp(key, "verbose") == 0)
        {
            g_cfgVerbose = ParseBool(value, g_cfgVerbose);
        }
    }
    fclose(file);
}

// ---------------------------------------------------------------------------
// Game build detection.
// RED4ext keys its own RED4EXT_V1_RUNTIME_VERSION_* constants on the game
// executable's *file* version, which - unlike the product version handed to us
// in Sdk::runtime - also distinguishes hotfixes (1.50, 1.50 HF1 and 1.50 HF2
// share a product version but differ in the revision field). The executable is
// found via the OS, not a hardcoded path, so this works on any store and any
// install location.
// ---------------------------------------------------------------------------
bool GetGameFileVersion(RED4ext::v1::FileVer& aOut)
{
    wchar_t path[MAX_PATH]{};
    if (!GetModuleFileNameW(GetModuleHandleW(nullptr), path, MAX_PATH))
    {
        return false;
    }

    DWORD ignored = 0;
    const DWORD size = GetFileVersionInfoSizeW(path, &ignored);
    unsigned char buffer[8192];
    if (size == 0 || size > sizeof(buffer) || !GetFileVersionInfoW(path, 0, size, buffer))
    {
        return false;
    }

    VS_FIXEDFILEINFO* info = nullptr;
    UINT len = 0;
    if (!VerQueryValueW(buffer, L"\\", reinterpret_cast<void**>(&info), &len) || !info ||
        len < sizeof(VS_FIXEDFILEINFO) || info->dwSignature != 0xFEEF04BDu)
    {
        return false;
    }

    aOut.major = static_cast<std::uint16_t>(HIWORD(info->dwFileVersionMS));
    aOut.minor = static_cast<std::uint16_t>(LOWORD(info->dwFileVersionMS));
    aOut.build = static_cast<std::uint16_t>(HIWORD(info->dwFileVersionLS));
    aOut.revision = static_cast<std::uint16_t>(LOWORD(info->dwFileVersionLS));
    return true;
}

// ---------------------------------------------------------------------------
// Guarded memory access. NOTE: the game's CrashReporter reacts to
// first-chance access violations, so these guards only cover races on
// pointer chains the game itself uses - never probe untrusted addresses.
// ---------------------------------------------------------------------------
bool SafeReadPtr(const void* aAddr, void** aOut)
{
    __try
    {
        *aOut = *static_cast<void* const*>(aAddr);
        return true;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        return false;
    }
}

bool SafeReadU32(const void* aAddr, std::uint32_t* aOut)
{
    __try
    {
        *aOut = *static_cast<const std::uint32_t*>(aAddr);
        return true;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        return false;
    }
}

bool SafeWriteU32(void* aAddr, std::uint32_t aVal)
{
    __try
    {
        *static_cast<std::uint32_t*>(aAddr) = aVal;
        return true;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        return false;
    }
}

// Sanity filters for pointers read out of a struct whose layout is not
// confirmed for this game build. A wrong offset typically yields a small
// integer, a float bit pattern or an unaligned value - all rejected here
// before anything is dereferenced. Only used on the fallback path.
bool PlausibleAddress(const void* aPtr)
{
    const auto value = reinterpret_cast<std::uintptr_t>(aPtr);
    return value >= 0x10000 && value < 0x7FFFFFFFFFFFull;
}

// As above, plus 8-byte alignment (object and vtable pointers). Deliberately
// not applied to function pointers, which carry no such guarantee.
bool PlausiblePointer(const void* aPtr)
{
    return PlausibleAddress(aPtr) && (reinterpret_cast<std::uintptr_t>(aPtr) & 7) == 0;
}

// Unified cadence for repeating-event logs: the first LogHead occurrences,
// then every LogEvery-th. Totals always appear in the session summary.
constexpr std::uint64_t LogHead = 20;
constexpr std::uint64_t LogEvery = 1000;

bool ShouldLog(std::uint64_t aCount)
{
    return aCount <= LogHead || aCount % LogEvery == 0;
}

// Remember the last gamepad-family device; announce the first sighting.
void NotePadDevice(std::uint32_t aDevice)
{
    g_lastPadDevice.store(aDevice);
    if (!g_padAnnounced.exchange(true))
    {
        g_sdk->logger->InfoF(g_handle, "gamepad detected (device %u): UI device is now locked to gamepad", aDevice);
    }
}

// ---------------------------------------------------------------------------
// Opt-in diagnostic: hardware watchpoint to find the field's writer.
// Enabled when a file named "MixedInputFix.diag" exists next to the DLL.
// Arms a write watchpoint (DR0) on the hint device field on every thread that
// runs one of our hooks; a vectored exception handler records the RIP of each
// write (data breakpoints report the instruction AFTER the write). Our own
// latch writes are filtered out. Results are logged from the normal hook path.
// This is the re-porting tool for new game patches - see README.md.
// ---------------------------------------------------------------------------
bool g_diagEnabled = false;
std::uintptr_t g_ownBase = 0;
std::uintptr_t g_ownEnd = 0;
std::uintptr_t g_exeBase = 0;

struct WriterHit
{
    std::atomic<std::uintptr_t> rip{0};
    std::atomic<std::uint64_t> count{0};
    std::atomic<bool> logged{false};
};
constexpr int MaxWriterHits = 16;
WriterHit g_writerHits[MaxWriterHits];
std::atomic<std::uint64_t> g_watchEvents{0};
std::atomic<std::uintptr_t> g_watchAddr{0};
constexpr std::uint64_t WatchEventCap = 400;

LONG CALLBACK WatchpointVeh(PEXCEPTION_POINTERS aInfo)
{
    if (aInfo->ExceptionRecord->ExceptionCode != EXCEPTION_SINGLE_STEP)
    {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    auto* ctx = aInfo->ContextRecord;
    if (!(ctx->Dr6 & 0x1)) // not our DR0 data breakpoint
    {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    ctx->Dr6 &= ~std::uint64_t{0x1}; // clear only our B0 status bit

    const auto rip = reinterpret_cast<std::uintptr_t>(aInfo->ExceptionRecord->ExceptionAddress);
    const bool ours = rip >= g_ownBase && rip < g_ownEnd;

    if (!ours)
    {
        for (int i = 0; i < MaxWriterHits; ++i)
        {
            std::uintptr_t expected = 0;
            if (g_writerHits[i].rip.compare_exchange_strong(expected, rip) || expected == rip)
            {
                ++g_writerHits[i].count;
                break;
            }
        }
    }

    if (++g_watchEvents >= WatchEventCap)
    {
        ctx->Dr7 &= ~std::uint64_t{0xF0003}; // disarm on this thread
    }
    return EXCEPTION_CONTINUE_EXECUTION;
}

void ArmWatchpointOnCurrentThread()
{
    thread_local bool armed = false;
    if (armed || g_watchEvents.load() >= WatchEventCap)
    {
        return;
    }
    const auto addr = g_watchAddr.load();
    if (!addr)
    {
        return;
    }
    CONTEXT ctx{};
    ctx.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    if (GetThreadContext(GetCurrentThread(), &ctx))
    {
        ctx.Dr0 = addr;
        ctx.Dr7 = (ctx.Dr7 & ~std::uint64_t{0xF0003}) // clear L0/G0 + R/W0 + LEN0
                  | 0x1                                // L0: local enable
                  | (std::uint64_t{0b01} << 16)        // R/W0: break on write
                  | (std::uint64_t{0b11} << 18);       // LEN0: 4 bytes
        if (SetThreadContext(GetCurrentThread(), &ctx))
        {
            armed = true;
        }
    }
}

void ReportWriterHits()
{
    for (auto& hit : g_writerHits)
    {
        const auto rip = hit.rip.load();
        if (rip && !hit.logged.exchange(true))
        {
            g_sdk->logger->InfoF(g_handle,
                                 "[diag] field written from RIP %p (exe+0x%llx, next-insn after write), hits so far=%llu",
                                 reinterpret_cast<void*>(rip),
                                 static_cast<unsigned long long>(rip - g_exeBase),
                                 static_cast<unsigned long long>(hit.count.load()));
        }
    }
}

// ---------------------------------------------------------------------------
// Fallback binding validation (unrecognised game build only).
// The writer exists to keep the hint device field equal to what the provider
// getter returns, so the two chains can be checked against each other while
// the writer runs untouched. Sampling happens in pass-through: nothing is
// suppressed, latched or written until the offsets check out.
// ---------------------------------------------------------------------------
std::uint32_t* HintDeviceField(); // Layer 3

void SampleBinding(std::uint32_t aGetterValue)
{
    bool inRange = aGetterValue <= EInputDevice_Max;
    bool match = false;

    auto* field = HintDeviceField();
    std::uint32_t device = 0;
    if (field && SafeReadU32(field, &device))
    {
        inRange = inRange && device <= EInputDevice_Max;
        match = device == aGetterValue;
    }
    else
    {
        inRange = false;
    }

    if (inRange)
    {
        ++g_bindingInRange;
    }
    if (match)
    {
        ++g_bindingMatches;
    }

    if (++g_bindingSamples != BindingSamplesNeeded)
    {
        return; // still sampling, or the verdict is already in
    }

    // Pass = every sample had both chains inside the enum range, and at least
    // one saw them agree (proving the two offsets describe the same logical
    // value). Not every sample has to agree: the writer has an early-out
    // branch that leaves the field untouched for some device types.
    const auto inRangeTotal = g_bindingInRange.load();
    const auto matchTotal = g_bindingMatches.load();
    const bool ok = inRangeTotal == BindingSamplesNeeded && matchTotal > 0;
    g_bindingCheck.store(ok ? BindingCheck::Trusted : BindingCheck::Failed);

    if (ok)
    {
        g_sdk->logger->InfoF(g_handle, "fallback offsets verified over %d samples - fix engaged",
                             BindingSamplesNeeded);
    }
    else
    {
        g_sdk->logger->WarnF(g_handle,
                             "fallback offsets FAILED verification (%d/%d samples in range, %d matches) - writer "
                             "suppression and latch stay DISABLED for safety; script-side stickiness is still "
                             "active. Check for a MixedInputFix update built for this game version.",
                             inRangeTotal, BindingSamplesNeeded, matchTotal);
    }
}

// ---------------------------------------------------------------------------
// Layer 1: writer suppression.
// Hook on the single steady-state writer of [[InkSystem]+0x210]+0x1E0
// (InkSystem method, 2.31: 0x140269954). Mirrors the writer's own value
// derivation (the vcall target is a verified pure getter - RE-notes.md),
// then either passes through or skips the whole function (a would-be switch
// off the pinned device): no field write, no id/value broadcasts, no hint
// churn.
// ---------------------------------------------------------------------------
void DeviceWriter_Detour(void* aInkSystem)
{
    const auto check = g_bindingCheck.load(std::memory_order_relaxed);
    if (check == BindingCheck::Failed)
    {
        g_writerOriginal(aInkSystem); // offsets rejected: stay out of the way
        return;
    }
    const bool unverified = check != BindingCheck::Trusted;

    void* provider = nullptr;
    if (!SafeReadPtr(static_cast<std::uint8_t*>(aInkSystem) + g_offDeviceProvider, &provider) || !provider ||
        (unverified && !PlausiblePointer(provider)))
    {
        g_writerOriginal(aInkSystem);
        return;
    }

    void* vtbl = nullptr;
    void* getter = nullptr;
    if (!SafeReadPtr(provider, &vtbl) || !vtbl || (unverified && !PlausiblePointer(vtbl)) ||
        !SafeReadPtr(static_cast<std::uint8_t*>(vtbl) + g_vtblGetDeviceValue, &getter) || !getter ||
        (unverified && !PlausibleAddress(getter)))
    {
        g_writerOriginal(aInkSystem);
        return;
    }

    const auto newVal = reinterpret_cast<std::uint32_t (*)(void*)>(getter)(provider);

    if (unverified)
    {
        // Offsets not confirmed for this build: run vanilla and measure.
        g_writerOriginal(aInkSystem);
        SampleBinding(newVal);
        return;
    }

    if (g_cfgVerbose)
    {
        const auto prev = g_writerLastVal.exchange(newVal);
        if (prev != newVal)
        {
            const auto t = ++g_writerTransitions;
            if (ShouldLog(t))
            {
                g_sdk->logger->InfoF(g_handle, "[writer] device %u -> %u (count=%llu)", prev, newVal,
                                     static_cast<unsigned long long>(t));
            }
        }
    }

    bool suppress = false;
    if (g_cfgMode == StickyMode::Controller)
    {
        if (newVal > EInputDevice_KBD_MOUSE && newVal <= EInputDevice_Max)
        {
            NotePadDevice(newVal);
        }
        else if (newVal == EInputDevice_KBD_MOUSE && g_lastPadDevice.load() != 0)
        {
            suppress = true;
        }
    }
    else // StickyMode::KBM: keep the field at its KBD_MOUSE boot state
    {
        suppress = newVal > EInputDevice_KBD_MOUSE && newVal <= EInputDevice_Max;
    }

    if (suppress)
    {
        const auto n = ++g_suppressed;
        if (g_cfgVerbose && ShouldLog(n))
        {
            g_sdk->logger->InfoF(g_handle, "[writer] suppressed switch to %s (count=%llu)",
                                 g_cfgMode == StickyMode::Controller ? "KBM" : "gamepad",
                                 static_cast<unsigned long long>(n));
        }
        return;
    }

    g_writerOriginal(aInkSystem);
}

// ---------------------------------------------------------------------------
// Layer 2: script-side stickiness.
// Hooks on the registered native handlers of GameObject::PlayerLastUsedKBM /
// Pad / PS5Pad (all redscript calls funnel through them; native engine code
// does not use them). Each runs the original, then forces the returned bool
// to the pinned-device answer while overrides are engaged (ScriptDesired).
// ---------------------------------------------------------------------------
void ForceBoolResult(void* aRet, std::uint8_t aDesired, std::atomic<std::uint64_t>& aCounter, const char* aName)
{
    *static_cast<std::uint8_t*>(aRet) = aDesired;
    const auto n = ++aCounter;
    if (g_cfgVerbose && ShouldLog(n))
    {
        g_sdk->logger->InfoF(g_handle, "[script] %s forced to %u (count=%llu)", aName, aDesired,
                             static_cast<unsigned long long>(n));
    }
}

// Overrides engaged: always in KBM mode, after the first gamepad input in
// controller mode. Returns false when the natives should stay vanilla.
bool ScriptDesired(std::uint8_t& aKBM, std::uint8_t& aPad, std::uint8_t& aPS5)
{
    if (g_cfgMode == StickyMode::KBM)
    {
        aKBM = 1;
        aPad = 0;
        aPS5 = 0;
        return true;
    }
    const auto pad = g_lastPadDevice.load();
    if (pad == 0)
    {
        return false;
    }
    aKBM = 0;
    aPad = 1;
    aPS5 = pad == EInputDevice_PROSPERO ? 1 : 0;
    return true;
}

void LastUsedKBM_Detour(void* aContext, void* aFrame, void* aRet, std::int64_t aRtti)
{
    g_lastKBMOriginal(aContext, aFrame, aRet, aRtti);

    std::uint8_t kbm, pad, ps5;
    if (aRet && ScriptDesired(kbm, pad, ps5) && *static_cast<std::uint8_t*>(aRet) != kbm)
    {
        ForceBoolResult(aRet, kbm, g_kbmOverrides, "PlayerLastUsedKBM");
    }
}

void LastUsedPad_Detour(void* aContext, void* aFrame, void* aRet, std::int64_t aRtti)
{
    g_lastPadOriginal(aContext, aFrame, aRet, aRtti);

    std::uint8_t kbm, pad, ps5;
    if (aRet && ScriptDesired(kbm, pad, ps5) && *static_cast<std::uint8_t*>(aRet) != pad)
    {
        ForceBoolResult(aRet, pad, g_padOverrides, "PlayerLastUsedPad");
    }
}

void LastUsedPS5Pad_Detour(void* aContext, void* aFrame, void* aRet, std::int64_t aRtti)
{
    g_lastPS5PadOriginal(aContext, aFrame, aRet, aRtti);

    std::uint8_t kbm, pad, ps5;
    if (aRet && ScriptDesired(kbm, pad, ps5) && *static_cast<std::uint8_t*>(aRet) != ps5)
    {
        ForceBoolResult(aRet, ps5, g_ps5PadOverrides, "PlayerLastUsedPS5Pad");
    }
}

// ---------------------------------------------------------------------------
// Layer 3: fallback latch (watchdog).
// Observes the device field before every hint icon resolution and once per
// UI input pump. Remembers gamepad values (controller mode) and restores the
// pinned value if the field ever leaves it (only possible via writes outside
// the suppressed writer, e.g. session-init code). Also hosts the opt-in
// watchpoint diagnostic.
// ---------------------------------------------------------------------------

// Returns the address of the device field, or nullptr if the chain is not up.
std::uint32_t* HintDeviceField()
{
    if (!g_inkSystemPtr)
    {
        return nullptr;
    }
    void* inkSystem = nullptr;
    if (!SafeReadPtr(g_inkSystemPtr, &inkSystem) || !inkSystem)
    {
        return nullptr;
    }
    void* manager = nullptr;
    if (!SafeReadPtr(reinterpret_cast<const std::uint8_t*>(inkSystem) + g_offHintManager, &manager) || !manager ||
        (g_bindingCheck.load(std::memory_order_relaxed) != BindingCheck::Trusted && !PlausiblePointer(manager)))
    {
        return nullptr;
    }
    return reinterpret_cast<std::uint32_t*>(reinterpret_cast<std::uint8_t*>(manager) + g_offHintDevice);
}

void LatchDevice(const char* aWhere)
{
    if (g_bindingCheck.load(std::memory_order_relaxed) != BindingCheck::Trusted)
    {
        return; // offsets unconfirmed for this build: never write, never arm diag
    }

    auto* field = HintDeviceField();
    if (!field)
    {
        return;
    }

    if (g_diagEnabled)
    {
        g_watchAddr.store(reinterpret_cast<std::uintptr_t>(field));
        ArmWatchpointOnCurrentThread();
        ReportWriterHits();
    }

    std::uint32_t device = 0;
    if (!SafeReadU32(field, &device) || device > EInputDevice_Max)
    {
        return;
    }

    std::uint32_t restore = 0; // 0 = nothing to do
    if (g_cfgMode == StickyMode::Controller)
    {
        if (device > EInputDevice_KBD_MOUSE)
        {
            NotePadDevice(device);
            return;
        }
        const auto pad = g_lastPadDevice.load();
        if (device == EInputDevice_KBD_MOUSE && pad != 0)
        {
            restore = pad;
        }
    }
    else if (device > EInputDevice_KBD_MOUSE) // StickyMode::KBM
    {
        restore = EInputDevice_KBD_MOUSE;
    }

    if (restore != 0 && SafeWriteU32(field, restore))
    {
        const auto n = ++g_restores;
        if (ShouldLog(n))
        {
            // With the writer hook attached this should only trigger for
            // writes that bypass it (e.g. session init). Frequent
            // occurrences mean a game patch added a new writer path.
            g_sdk->logger->WarnF(g_handle, "[fallback:%s] restored device %u over %u (count=%llu)", aWhere, restore,
                                 device, static_cast<unsigned long long>(n));
        }
    }
}

void HintRefresh_Detour(void* aController)
{
    LatchDevice("refresh");
    g_refreshOriginal(aController);
}

void ProcessInputEvents_Detour(void* aInkSystem, std::uint64_t aArg2, void* aBuffer)
{
    g_pieOriginal(aInkSystem, aArg2, aBuffer);
    LatchDevice("frame");
}

// ---------------------------------------------------------------------------
// Plugin entry
// ---------------------------------------------------------------------------
void* AttachHook(std::uint32_t aHash, void* aDetour, void** aOriginalOut, const char* aName)
{
    // No null check on purpose: Resolve() terminates the process with a clear
    // RED4ext error naming the hash if it is missing from the address library,
    // so a null target can never reach Attach().
    auto* target = reinterpret_cast<void*>(RED4ext::UniversalRelocBase::Resolve(aHash));
    if (!g_sdk->hooking->Attach(g_handle, target, aDetour, aOriginalOut))
    {
        g_sdk->logger->ErrorF(g_handle, "failed to attach %s hook (hash %u)", aName, aHash);
        return nullptr;
    }
    return target;
}
} // namespace

RED4EXT_C_EXPORT bool RED4EXT_CALL Main(RED4ext::v1::PluginHandle aHandle, RED4ext::v1::EMainReason aReason,
                                        const RED4ext::v1::Sdk* aSdk)
{
    switch (aReason)
    {
    case RED4ext::v1::EMainReason::Load:
    {
        g_handle = aHandle;
        g_sdk = aSdk;

        // Own module range (for diag RIP filtering), module dir (config +
        // diag marker), exe base (for exe-relative diag offsets).
        wchar_t dir[MAX_PATH]{};
        {
            HMODULE self = nullptr;
            GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
                               reinterpret_cast<LPCWSTR>(&Main), &self);
            if (self && GetModuleFileNameW(self, dir, MAX_PATH))
            {
                g_ownBase = reinterpret_cast<std::uintptr_t>(self);
                auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(self);
                auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(
                    reinterpret_cast<const std::uint8_t*>(self) + dos->e_lfanew);
                g_ownEnd = g_ownBase + nt->OptionalHeader.SizeOfImage;

                if (auto* slash = wcsrchr(dir, L'\\'))
                {
                    slash[1] = 0;
                }
            }
            g_exeBase = reinterpret_cast<std::uintptr_t>(GetModuleHandleW(nullptr));
        }

        LoadConfig(dir);
        if (!g_cfgEnabled)
        {
            aSdk->logger->InfoF(aHandle, "MixedInputFix %s DISABLED via MixedInputFix.ini - game runs vanilla",
                                VersionStr);
            return true;
        }

        // Select the offset set for this game build. An exact table match is
        // trusted outright; anything else falls back to the newest known row
        // and has to prove itself at runtime (see BindingCheck / SampleBinding).
        RED4ext::v1::FileVer gameVer{};
        const bool gameVerKnown = GetGameFileVersion(gameVer);
        char gameVerStr[64];
        if (gameVerKnown)
        {
            sprintf_s(gameVerStr, "%u.%u.%u.%u", static_cast<unsigned>(gameVer.major),
                      static_cast<unsigned>(gameVer.minor), static_cast<unsigned>(gameVer.build),
                      static_cast<unsigned>(gameVer.revision));
        }
        else
        {
            strcpy_s(gameVerStr, "unknown");
        }

        g_binding = &kBindings[BindingCount - 1];
        if (gameVerKnown)
        {
            for (const auto& binding : kBindings)
            {
                if (binding.version == gameVer)
                {
                    g_binding = &binding;
                    g_bindingExact = true;
                    break;
                }
            }
        }
        g_offHintManager = g_binding->hintManager;
        g_offHintDevice = g_binding->hintDevice;
        g_offDeviceProvider = g_binding->deviceProvider;
        g_vtblGetDeviceValue = g_binding->vtblGetDeviceValue;
        if (!g_bindingExact)
        {
            g_bindingCheck.store(BindingCheck::Sampling);
        }

        {
            wchar_t marker[MAX_PATH]{};
            swprintf_s(marker, L"%sMixedInputFix.diag", dir);
            g_diagEnabled = GetFileAttributesW(marker) != INVALID_FILE_ATTRIBUTES;
            if (g_diagEnabled)
            {
                AddVectoredExceptionHandler(1, &WatchpointVeh);
                aSdk->logger->Warn(aHandle, "[diag] writer watchpoint diagnostic ARMED - this is a debugging aid; "
                                            "delete MixedInputFix.diag next to the DLL for normal play");
            }
        }

        g_inkSystemPtr = reinterpret_cast<void**>(RED4ext::UniversalRelocBase::Resolve(InkSystemInstance_Hash));

        g_writerTarget = AttachHook(DeviceWriter_Hash, reinterpret_cast<void*>(&DeviceWriter_Detour),
                                    reinterpret_cast<void**>(&g_writerOriginal), "device writer");
        g_lastKBMTarget = AttachHook(LastUsedKBMThunk_Hash, reinterpret_cast<void*>(&LastUsedKBM_Detour),
                                     reinterpret_cast<void**>(&g_lastKBMOriginal), "PlayerLastUsedKBM");
        g_lastPadTarget = AttachHook(LastUsedPadThunk_Hash, reinterpret_cast<void*>(&LastUsedPad_Detour),
                                     reinterpret_cast<void**>(&g_lastPadOriginal), "PlayerLastUsedPad");
        g_lastPS5PadTarget = AttachHook(LastUsedPS5PadThunk_Hash, reinterpret_cast<void*>(&LastUsedPS5Pad_Detour),
                                        reinterpret_cast<void**>(&g_lastPS5PadOriginal), "PlayerLastUsedPS5Pad");
        g_refreshTarget = AttachHook(HintRefresh_Hash, reinterpret_cast<void*>(&HintRefresh_Detour),
                                     reinterpret_cast<void**>(&g_refreshOriginal), "hint refresh (latch)");
        g_pieTarget = AttachHook(ProcessInputEvents_Hash, reinterpret_cast<void*>(&ProcessInputEvents_Detour),
                                 reinterpret_cast<void**>(&g_pieOriginal), "ProcessInputEvents (latch)");

        if (!g_writerTarget && !g_refreshTarget && !g_pieTarget)
        {
            aSdk->logger->Error(aHandle, "no field-level hook attached - plugin cannot function");
            return false;
        }

        aSdk->logger->InfoF(aHandle,
                            "MixedInputFix %s active (mode:%s game:%s offsets:%s/%s writer:%s scriptKBM:%s "
                            "scriptPad:%s scriptPS5:%s latch:%s+%s%s)",
                            VersionStr, g_cfgMode == StickyMode::Controller ? "controller" : "kbm", gameVerStr,
                            g_binding->label, g_bindingExact ? "exact" : "fallback",
                            g_writerTarget ? "on" : "OFF", g_lastKBMTarget ? "on" : "OFF",
                            g_lastPadTarget ? "on" : "OFF", g_lastPS5PadTarget ? "on" : "OFF",
                            g_refreshTarget ? "on" : "OFF", g_pieTarget ? "on" : "OFF",
                            g_cfgVerbose ? " verbose" : "");
        if (!g_bindingExact)
        {
            aSdk->logger->WarnF(aHandle,
                                "game build %s is not in the offset table - trying the newest known offsets (%s) "
                                "and verifying them over the first %d device updates; nothing is suppressed or "
                                "written until they check out",
                                gameVerStr, g_binding->label, BindingSamplesNeeded);
        }
        if (g_cfgMode == StickyMode::KBM)
        {
            aSdk->logger->Info(aHandle, "kbm mode: UI device locked to keyboard/mouse from boot");
        }
        if (g_cfgVerbose)
        {
            aSdk->logger->InfoF(aHandle, "targets: writer=%p lastKBM=%p lastPad=%p lastPS5=%p refresh=%p pie=%p "
                                         "inkSystemPtr=%p",
                                g_writerTarget, g_lastKBMTarget, g_lastPadTarget, g_lastPS5PadTarget,
                                g_refreshTarget, g_pieTarget, g_inkSystemPtr);
        }
        break;
    }
    case RED4ext::v1::EMainReason::Unload:
    {
        for (void* target : {g_refreshTarget, g_pieTarget, g_writerTarget, g_lastKBMTarget, g_lastPadTarget,
                             g_lastPS5PadTarget})
        {
            if (target)
            {
                aSdk->hooking->Detach(aHandle, target);
            }
        }
        if (g_cfgEnabled)
        {
            aSdk->logger->InfoF(aHandle,
                                "session summary: suppressed=%llu scriptKBM=%llu scriptPad=%llu scriptPS5=%llu "
                                "fallbackRestores=%llu",
                                static_cast<unsigned long long>(g_suppressed.load()),
                                static_cast<unsigned long long>(g_kbmOverrides.load()),
                                static_cast<unsigned long long>(g_padOverrides.load()),
                                static_cast<unsigned long long>(g_ps5PadOverrides.load()),
                                static_cast<unsigned long long>(g_restores.load()));
        }
        break;
    }
    }

    return true;
}

RED4EXT_C_EXPORT void RED4EXT_CALL Query(RED4ext::v1::PluginInfo* aInfo)
{
    aInfo->name = L"MixedInputFix";
    aInfo->author = L"Havner";
    aInfo->version = RED4EXT_V1_SEMVER(VerMajor, VerMinor, VerPatch);
    aInfo->runtime = RED4EXT_V1_RUNTIME_VERSION_INDEPENDENT;
    aInfo->sdk = RED4EXT_V1_SDK_VERSION_CURRENT;
}

RED4EXT_C_EXPORT std::uint32_t RED4EXT_CALL Supports()
{
    return RED4EXT_API_VERSION_1_COMPAT_0;
}
