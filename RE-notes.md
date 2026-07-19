# RE notes — Cyberpunk 2077 input device switching (2.31)

Reverse-engineering record behind MixedInputFix, kept chronological (each
section documents what was known at that point; later sections supersede
earlier ones). Static analysis of `Cyberpunk2077.exe` (GOG 2.31, exe dated
2025-10-05) done with python + capstone/pefile — the analysis scripts and
recipes live in `tools/`. Goal: find and suppress the KBM<->PAD active-device
flip that causes input hint flicker and (after 20m-1h) the mixed-input freeze
(see bug.md).

## The device-switch machinery (all VAs for 2.31)

Central object: an **input device manager** (exact RTTI name unknown; lives inside
the input system, obtained via handle at `manager+0x98`-adjacent getters).
Layout (partial):

| offset | meaning |
|--------|---------|
| +0x50  | ptr to owner (leads to BlackboardSystem via +0xC0) |
| +0x98  | `Handle<InputDevice>` current device |
| +0xC0  | per-device table (0x68-stride records; +0x38 id, +0x3C active flag) |
| +0xCC  | device count |
| +0x320 | listener/settings object (+0x1E8 flag feeds Scheme calc; vtbl+0x1B8 = OnInputSystemEvent) |
| +0x344 | "ready" flag (blackboard IDs resolved) |
| +0x360 | spinlock |

Device object: `+0xA4` = uint32 script enum `InputDevice { KBM=0, PAD=1 }`.
Device-change tracker (same/related object): `+0xF0` 0x20-byte change record,
`+0x110` "changed this frame" bool.

Key functions:

| VA (2.31) | addr-lib hash | role |
|-----------|---------------|------|
| `0x1401059ac` | **2236947577** | **OnDeviceActivated(this, DeviceDesc*, bool active)** — updates device table, sets current device (+0x98), calls blackboard updater. THE flip point. NOTE: 2nd arg is a pointer to a 0x18-byte POD descriptor (IDs), NOT a handle/object ptr — deref of desc[0] as pointer crashes. The device *object* comes from the device table record (+0x18) inside SetCurrentDevice. |
| `0x140105a8c` | (offset 0001:00104a8c) | UpdateDeviceSchemeBlackboard — GetUint/SetUint InputSchemes.Device (+ Scheme) only on change |
| `0x140105328` | — | InitDeviceBlackboard — force-writes Device/Scheme/3rd field + InitializedInputHintManagerList variant |
| `0x140105bc8` | — | SetCurrentDevice (only called from OnDeviceActivated + its cold path) |
| `0x140107930` | — | GetCurrentDeviceHandle(out, &this->0x98) |
| `0x14010586c` | — | DeviceToScriptEnum: returns device->0xA4 |
| `0x140106160` | — | DeviceToIndex |
| `0x14010654c` | — | input system per-frame Update: iterates connect/disconnect/activated lists, dispatches device-change event via listener vtbl+0x1B8 when tracker flag (+0x110) set |
| `0x14060d1ec` | — | IBlackboard::SetUint(this, BlackboardID*, uint32*, bool forceFire) |
| `0x14060d288` | — | IBlackboard::GetUint |
| `0x1425e586c` | — | writes 4th InputSchemes field; on equal value force-fires listeners (vtbl+0x158) |
| `0x1425ed160` | — | settings setter: writes listener+0x1E8 flag then UpdateDeviceSchemeBlackboard |

Blackboard ID globals (.data, resolved at runtime):
`0x143472D50` = InputSchemes blackboard ID, `0x143472D38` = Device field,
`0x143472D30` = Scheme field, `0x143472D40` = 4th field, `0x143472D48` = variant
(InitializedInputHintManagerList).

CName interning helpers: "InputSchemes" `0x141893c50`, "Device" `0x1418d61a0`,
"Scheme" `0x1418ca86c` (all callers are the giant native blackboard-def bootstrap
`0x140824108..0x14082f593` — dead end for finding writers, they use cached IDs).

Useful anchors: `inkSystem::ProcessInputEvents` = addr-lib hash 673454961
(VA 0x14039bb18); IK_MouseX/Y/Z = 228/229/230; pad keys ~130..155 (IK_Pad_Last=155).
"SetUint" RTTI registration string at `0x142e8b3d0` → script thunk `0x14130fa58` →
impl `0x14060d1ec` (found via rip-ref numpy scan; CName imm64 search: fnv1a64).

## The hint-icon authority (v0.6 findings, re-verified 2026-07-19)

The visible button-hint flicker is driven by NEITHER of the above. Verified chain:
`inkInputDisplayController::SetInputAction` thunk (`0x1412a2a50`, via RTTI string
"SetInputAction" @ 0x142e86a68 -> registration 0x141860de4) stores the action
CName at controller+0x128 and calls the icon refresh `0x1404a3090`
(**addr-lib hash 4042789608**). The refresh reads:

```
rcx = *[0x143495C70]        ; InkSystem singleton
rdi = [rcx + 0x210]         ; hint/input manager object
r12d = [rdi + 0x1e0]        ; current device, input::EInputDevice
cmp r12d, 1                 ; KBD_MOUSE == 1, pads are 2..9
```

`[[InkSystem]+0x210]+0x1E0` is the single authority for hint icons. Its writer
was not isolated statically (offset +0x1E0 too common; likely a method of the
manager reached per input event). Failed attempts (documented so they are not
repeated): game-side OnDeviceActivated sticky (never fires during flicker);
ink pointer-mode switch 0x14039b390 hash 1690311569 suppression (kills cursor
for ALL devices - it manages pointer objects, runs ~90/s, boot value 0 is
"uninitialized" not "pad mode"; and hints still flickered while fully no-op'd).

## The fix (MixedInputFix plugin)

This plugin's v0.6 "device latch": hooks the hint icon refresh (hash
4042789608) and ProcessInputEvents (hash 673454961). Reads
`[[InkSystem]+0x210]+0x1E0`; remembers the last gamepad value (2..9) seen there;
whenever it reads KBD_MOUSE(1) and a pad is known, writes the pad value back
(before every hint refresh + once per UI input pump). Vanilla until a pad is
used.

Hard-learned: the game's CrashReporter reacts to first-chance access violations,
so even SEH-guarded probing of unmapped addresses kills the process — never rely
on guarded reads of untrusted pointers inside the game.

Build and install: see README.md.

**Confirmed working** (short menu test): log shows boot field=1 (KBM,
untouched), first gamepad input (a Steam Controller) sets field=5 (XINPUT_PAD,
memorized), then every mouse event flips 5->1 and is restored before icon
resolution ("restored pad device 5 over KBM"). Button hints stopped flickering
entirely; mouse cursor still appears/hides on device switch (vanilla
pointer-mode machinery, deliberately untouched).

Caveat for the freeze prognosis: the underlying writer still flips the field per
mouse event and its change-notification still fires (hint refreshes still run,
they just resolve to unchanged icons). If freeze accumulation is per *visible*
hint change -> fixed; if per *notification* -> may persist. If it persists, next
step: find the field's writer at runtime (hardware watchpoint on
[[InkSystem]+0x210]+0x1E0, log RIP) and silence the notification itself.

Verification (v0.6): `red4ext\logs\mixedinputfix-*.log` shows
"v0.6 device latch active"; after first pad input, "hint device 1 -> N" then
"restored pad device N over KBM" lines while hints stay on gamepad.

## The field's writer (v0.8 findings, 2026-07-19)

The v0.7 watchpoint diagnostic (one menu session, 2026-07-19 13:01) captured a
single writer RIP for both flip directions: `exe+0x269a54` = the instruction
after `mov [rcx+0x1e0], edi` at `0x140269a4e`, inside the InkSystem method
**`0x140269954`** (offset `0001:00268954`, addr-lib hash **3719303744**).
Anatomy (signature: `void (InkSystem* this)`):

```
provider = [this+0x300]            ; device state provider, bail if null
id  = provider->vtbl[+0x220]()     ; physical device id (rbp), -1 = none
val = provider->vtbl[+0x218]()     ; input::EInputDevice value (edi)
if id == [this+0x310] && val == [mgr+0x1E0]: return      ; edge detection
if [this+0x310] != -1:             ; handle-check branch: for some new-device
    ...                            ;   types sets [this+0x318]=1 and returns
[this+0x310] = id; [this+0x318] = 0
broadcast id  -> listeners at this+0x10   (0x140bdcb8c)
if [mgr+0x1E0] != val:
    [mgr+0x1E0] = val
    broadcast val -> listeners at mgr+0x30 (0x140caab14)   ; the hint hide/churn
```

Both broadcast helpers are plain listener-array iterations (lock + 0x38-stride
callback records). Single call site: `0x140269860`, a per-frame poller that
derives the same device value itself (`[this+0xC0]` record, classification via
`0x1404a4de8`, else default KBM) and propagates its own isKBM bool via
`0x14026984c` *before* calling the writer — so cursor-related machinery does
not depend on the writer running. Confirmed independently: .text byte-writes
to the pointer-mode cursor flag `InkSystem+0x28A` exist only at `0x14039b7a1`
inside the pointer-mode fn `0x14039b390` (which reads none of
`+0x300/+0x310/+0x318/mgr+0x1E0`) and in a small standalone setter
`0x140268b64` (`SetCursorFlag(this, bool)`, writes +0x289/+0x28A — likely the
target of the caller's isKBM propagation chain; found later by the improved
`tools/storescan.py`, the original narrower scan missed it). Neither reads
the suppressed state, hence skipping the writer wholesale is cursor-safe.

v0.8 = hook hash 3719303744; recompute `val` via the same `vtbl+0x218` vcall;
pads 2..9 pass through (and are remembered), KBM after a known pad returns
without calling the original (no write, no broadcasts). v0.6 latch kept as
`[fallback:...]`-logged watchdog for other writers (session init etc.).
Double-call safety of the vcall (the detour calls it once, the original then
calls it again in pass-through) was later verified: the getter is pure — see
the observer-run section.

## The contextual-hints layout flicker (v0.9 findings, 2026-07-19)

v0.8 test feedback: everything fixed except the bottom-right contextual HUD
hints widget (crouch/dodge/shoot), which kept flickering between its two
*layout* variants (KBM vs pad — combos differ per device) while showing pad
icons in both. Root cause found in the vanilla game scripts, decompiled with
the redscript decompiler (not included in this repo; more complete than the
REDmod source dump):

- The widget's hints are pushed by the PSM input-context transitions
  (`cyberpunk\player\psm\inputContextTransitions.swift`,
  `InputContextTransitionEvents` and subclasses, `Show*/Remove*InputHints`).
- `ConsumeControllerChange()` (line ~616) polls the native
  `GameObject::PlayerLastUsedKBM()` each update; any flip sets
  `m_hasControllerChanged`, which re-enters the active base context and
  re-pushes the entire hint set → the visible layout flicker. The pushed hint
  *contents* also branch on `PlayerLastUsedKBM()` (lines ~272/392), so a
  script-only patch of the trigger could strand a stale KBM layout.
- `PlayerLastUsedKBM` is a **virtual** native (`GameObject` vfunc, thunk does
  `call [vtbl+0x210]`), so the impl is class-dependent — but every flickering
  consumer is redscript, and all script calls go through the single
  registered native handler found via recipe 1: name string `0x142c1a840` →
  registration `0x1410864d4` → handler **`0x1404d70e8`** (offset
  `0001:004d60e8`, addr-lib hash **1037639234**), single rip-ref (unique to
  this function). Handler shape: `(context, frame, out bool*, rtti)`, result
  byte written through r8 if non-null.

Sibling natives (same recipe, v0.9.1): `PlayerLastUsedPad` handler
`0x14188e878` (offset `0001:0188d878`, hash **1291656829**, vcall
`[vtbl+0x208]`) — forced true after pad use; `PlayerLastUsedPS5Pad` handler
`0x141cad8d0` (offset `0001:01cac8d0`, hash **2647269205**) — its body is
`GetLastUsedDevice vcall [vtbl+0x218] == 9 (PROSPERO)`, so we force
`lastPad == 9`. The vtbl triple +0x208/+0x210/+0x218 = Pad/KBM/device-enum
GameObject vfuncs.

v0.9 = hook the handler, call original, force `*out = false` once
`g_lastPadDevice != 0`. This makes ALL script device checks sticky-pad
(hint layouts, shards/codex layout, car-color-picker navigation, crouch
toggle nuances in locomotionTransitions.swift:2317) — consistent with the
mod's sticky-gamepad premise; native engine callers don't use the handler.
Related script symbols if ever needed again: `InputSchemesDef` blackboard
(`Device`, `Scheme`, `IsKeyboardConnected`, `InitializedInputHintManagerList`),
`OnInputSchemeUpdated` (scheme, not device), native widget controller
`InputHintManagerGameController`.

## Porting to a new game patch

The plugin resolves functions via RED4ext address-library hashes, which survive
patches — but three things must be re-verified per patch:

1. **Hashes still resolve**: RED4ext terminates with a clear error naming the
   hash if an entry is missing from the new `cyberpunk2077_addresses.json`.
   Current hashes: InkSystem instance = 2635337807, hint refresh = 4042789608,
   ProcessInputEvents = 673454961 (all also used by Codeware except the refresh,
   so the first two effectively cannot silently break), device writer =
   3719303744 (v0.8; not used by other mods — if it vanishes, re-find via the
   v0.7 watchpoint diag and grep the new offset in the JSON), PlayerLastUsedKBM
   handler = 1037639234 (v0.9; re-find via recipe 1 from the
   "PlayerLastUsedKBM" name string).
2. **Struct offsets** (hardcoded in main.cpp, patch-fragile):
   - `InkSystem + 0x210` -> hint/input manager pointer
   - `manager + 0x1E0` -> uint32 input::EInputDevice (KBD_MOUSE=1, pads 2..9)
   - `InkSystem + 0x300` -> device state provider; `vtbl + 0x218` -> value
     getter (re-derive from the writer function's prologue: the two vcalls
     before the edge-detection compares)
   Re-derive: update exe path in `tools/cp77.py`, resolve the refresh function's
   new VA from the JSON (hash 4042789608 -> offset), disassemble its first ~30
   instructions (`tools/` + recipe 1 in its README.md if the hash vanished) and
   read the two displacements from the singleton-load / manager-load / field-load
   sequence (`mov rcx,[rip+X]; mov rdi,[rcx+OFF1]; mov r12d,[rdi+OFF2]; cmp r12d,1`).
3. **Enum values**: input::EInputDevice from RED4ext.SDK
   `Scripting/Natives/Generated/input/EInputDevice.hpp` (KBD_MOUSE=1 since
   forever; EID_COUNT bound used for the sanity filter).

## Status 2026-07-19 (post 2h test) and the world-map hint issue

2h mixed-input gameplay session with v0.6: **no freeze** (previously 20-60 min).
Minor regression found: on a few screens (world map confirmed) hints show pad
variant on entry, disappear on mouse move, and do NOT return on pad input.
Theory (consistent with the latch design): the field's writer edge-detects for
its notifications. Mouse -> writes KBM + broadcasts "switched to KBM" (map's
gamepad-specific hint bar hides); latch restores pad value; next pad input ->
writer compares new(pad) == current(pad, ours) -> no broadcast -> bar never
re-shows. Fix plan: hook the WRITER and skip KBM writes entirely (no write, no
hide broadcast, churn gone too). v0.7 adds an opt-in HW-watchpoint diagnostic
(marker file `MixedInputFix.diag` next to the DLL) that logs writer RIPs as
exe-relative offsets; see README.md.

Additional consumers of `[[InkSystem]+0x210]+0x1E0` found statically (scan for
functions that load singleton->+0x210 and read +0x1E0 — useful when assessing
side effects of writer-level suppression): 0x140636ee4 (+cmp 1), 0x140636fc0,
0x14063b768, 0x1408fcb1c, 0x1427d6db0, 0x1427fd998, 0x1427fdc24, 0x1428c0f6c
(cursor-flags logic, cmp field vs 1), 0x1402ec9c4. The manager object is also
reachable at 0x1404a3758 (two +0x210 loads, likely another hint-path helper).

## Freeze reproduction evidence (observer run, 2026-07-19)

One deliberate crash run with the plugin in an "observer mode" build (all
hooks attached but passive: no value changed, no suppression — pure vanilla
behavior with counting; a small local patch gating every value write behind
an #if). Intensive mixed-input play; the game froze after **26.8 min**
(historical vanilla range 20-60 min). 16,417 log lines, counters logged
every 100th event.

Final counters (lower bounds, logger batches may cut up to ~100 events):

| counter | value at freeze |
|---------|-----------------|
| writer device transitions | 25,800 (13,200 of them pad->KBM) |
| hint refreshes observing KBM with pad known | 1,563,700 |
| script `PlayerLastUsedKBM` == true with pad known | 22,200 |
| share of KBM observations from refresh hook vs frame pump | ~98% / ~2% |

Analysis results:

- **Refreshes per pad->KBM flip ≈ 105-135, flat across the whole session** (no
  growth trend minute-over-minute). Whatever accumulates toward the freeze is
  invisible in call counts — per-flip work is constant at this level.
- **Death was abrupt, mid-burst**: final minutes were sustained mixed input
  (~4,500 refreshes/s at the end), log cadence perfectly steady (100 events
  per ~22 ms) up to the very last line, then silence. No slowdown, no
  widening gaps before the freeze.
- **Key interpretive datum (empirical, across dozens of vanilla sessions)**:
  freeze time is *consistently* inversely proportional to input-flip
  intensity — intensive play always freezes at ~20-25 min, calm play at 60+
  min, with low variance at a given intensity. A per-event race/lottery would
  give an exponential
  (high-variance) time distribution at fixed intensity; the observed
  consistency instead indicates **deterministic accumulation toward a fixed
  threshold** — a per-flip (or per-refresh) resource cost (memory, handles,
  pool/queue entries) that exhausts a fixed budget. Pool exhaustion followed
  by an infinite wait also matches the abrupt full-speed stop. This run's
  totals (~13.2k pad->KBM flips / ~1.56M KBM refreshes) estimate that budget
  at this intensity; a second observer run comparing counters at freeze would
  identify which counter the threshold tracks (optional — the fix removes the
  events regardless).
- The run also captured the provider getter (`exe+0x26a258`, logged by the
  v0.8 one-time diagnostic): disassembled — spinlock-guarded read of a cached
  value at provider+0x28, nothing else. **Pure getter confirmed**; the
  detour's extra call is provably harmless.

Why the fix works either way: v0.6 already prevented the freeze for 2h+ while
leaving all broadcasts running — it stopped only the *icon swaps* (refreshes
resolved to unchanged pad icons). So the accumulating cost is incurred at or
downstream of the actual icon change (plausibly icon resource load/swap).
v0.8/0.9 remove the flip events entirely, upstream of all of it.

## Open questions / future work

- All three fix layers confirmed in gameplay testing (world map fixed, cursor
  stays on the gamepad variant, contextual HUD hints keep their layout,
  CrystalCoat UI stable); long-session validation summarized in the README
  version history.
- Semantics of the writer's handle-check branch (`[this+0x318]=1` + skip for
  certain new-device types) — unknown, untouched by the v0.8 hook.
- Root cause of the freeze: narrowed to deterministic accumulation per icon
  change with an exhaustion threshold (see the observer-run section); exact
  leaking resource not identified — the fix works by prevention. A watchdog
  crash dump (`%LOCALAPPDATA%\CD Projekt Red\Cyberpunk 2077\`) would pinpoint
  it if ever needed.
- Possible future feature: a reset hotkey so the pinned device can be
  switched intentionally mid-session (currently: restart, or edit the ini).
- `tools/` has the analysis scripts + recipes (see its README.md), including
  consolidated CLI versions of the one-off recon scripts used throughout
  these notes (dumpfunc/findnative/storescan/logstats).

## History of failed approaches (do not retry blindly)

1. **v0.1-0.3, game-side sticky** (hook OnDeviceActivated 2236947577): correct
   analysis of the InputSchemes-blackboard machinery, but that path never fires
   during hint flicker — it handles connect/disconnect/init, not per-input
   switching. v0.1/0.2 also crashed: 2nd arg is a POD descriptor, not an object
   pointer, and even SEH-guarded bad derefs kill the game via CrashReporter.
2. **v0.5, pointer-mode suppression** (hook 0x14039b390, hash 1690311569):
   suppressing while byte [InkSystem+0x28A]==0 blocked the function from boot
   (0 = uninitialized, not pad mode), which prevented pointer-object creation ->
   cursor dead for all devices; and hints flickered regardless (pointer mode is
   cursor-only). Function is legit for cursor experiments: runs ~90/s, flag
   +0x28A (1=mouse-ish), speed +0x28C, pointer handles +0x2D8/+0x2E0.
