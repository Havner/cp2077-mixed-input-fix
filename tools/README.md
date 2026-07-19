# Static analysis tools for Cyberpunk2077.exe

The reverse-engineering toolkit used to build this plugin, kept in the repo
for future game patches or similar work. Python 3 + `pip install capstone
pefile numpy`. All scripts assume the exe path configured at the top of
`cp77.py` (currently `D:\Games\GOG\Cyberpunk 2077\bin\x64\Cyberpunk2077.exe`)
— **update it after a game move or patch**.

## Core modules (imported by the CLI tools)

- **cp77.py** — PE loader, section map, function boundary table from `.pdata`
  (`func_bounds(va)`), capstone disassembly (`disasm(start, end)`), raw byte
  search (`find_bytes`), `fnv1a64(str)` for CName hashes.
- **riprefs.py** — `rip_refs(target_va)`: numpy scan of .text for
  rip-relative displacements resolving to a VA (finds code references to
  strings/globals; tries +0/+1/+4 trailing-immediate adjustments). The PE
  load is cached per process; the scan itself reruns per call (a few seconds
  of numpy work over .text per target).

## CLI tools

- **dumpfunc.py `0x14XXXXXXXX ...`** — disassemble the function containing a
  VA, with resolved rip-targets and the address-library offset
  (`0001:XXXXXXXX`) to grep in `cyberpunk2077_addresses.json` for the
  RED4ext hash. The go-to first step for any address (watchpoint RIPs,
  callscan results, thunk candidates).
- **callscan.py `0x14XXXXXXXX`** — find all E8/E9 rel32 call/jmp sites
  targeting a VA, grouped by containing function. Misses virtual and
  rip-indirect (`FF 15`) calls.
- **findnative.py `Name ...`** — recipe 1 automated: given a script-visible
  native function name (e.g. `PlayerLastUsedKBM`), finds its RTTI
  registration function and lists the `lea` targets inside it; the one
  annotated with its own function bounds + addr-lib offset is the registered
  native handler ("script thunk") — hookable to intercept all script calls.
  This is how the v0.9/v0.9.1 hook targets were found.
- **storescan.py `0xDISP [byte|dword]`** — scan .text for
  `mov [reg+DISP], ...` store encodings: candidate writers of a struct field
  when the object address is unknown. Beware: common offsets hit hundreds of
  unrelated classes; cross-check with dumpfunc.py/singleton loads, or prefer
  the plugin's opt-in hardware-watchpoint diag (README.md) which needs no
  guessing.
- **logstats.py `<mixedinputfix-*.log>`** — summarize a plugin log:
  per-message counts, max counters, per-minute counter deltas. Written for
  the observer-mode crash-run analysis (RE-notes.md, "Freeze reproduction
  evidence"); works on any MixedInputFix log.

## Recipes that worked (see RE-notes.md for results)

1. **Find native impl of a script-visible method** (e.g. `SetUint`,
   `SetInputAction`, `PlayerLastUsedKBM`): `findnative.py Name`, then
   `dumpfunc.py` the thunk; for virtual natives the thunk's tail is
   `call [rax+SLOT]` — the per-class impl needs the object's vtable, but
   hooking the thunk itself covers every script caller (v0.9 approach).
2. **Find users of a CName**: `fnv1a64("Name")` packed little-endian as an
   8-byte pattern → `find_bytes` → hits in .text are `movabs` immediates
   inside lazy CName-interning helpers → `callscan.py` the helper for users.
   (Only some names are interned this way; others exist only as ASCII
   registration strings.)
3. **Address library round-trip**: `bin\x64\cyberpunk2077_addresses.json`
   maps `hash <-> "000S:OFFSET"` per build (~440k entries, ~84 with symbol
   names). VA = 0x140000000 + section RVA (sec 1 = .text @ 0x1000 in 2.31 —
   re-read the PE section table per patch) + offset. dumpfunc.py prints the
   offset; grep the JSON for it to get the hash for
   `UniversalRelocBase::Resolve`; RED4ext keeps the hash valid across
   patches.
4. **Find a field's writer**: `storescan.py OFFSET [byte|dword]`, then filter
   candidates. For heavily-used offsets use the plugin's hardware-watchpoint
   diagnostic instead (one game session, exact RIP, no false positives).
5. **Runtime diffing** when statics fail: hook a per-frame function with the
   plugin (e.g. `inkSystem::ProcessInputEvents`, hash 673454961) and
   byte-diff a snapshot of a candidate object across frames, logging changed
   offsets — this is how the hint-device field's *cluster* was found; note it
   missed state behind pointers, which needed the SetInputAction chain
   instead.

## Hard-learned rules

- The game's CrashReporter reacts to first-chance access violations: even
  SEH-guarded reads of unmapped addresses kill the process. Only dereference
  pointers on chains the game itself uses (singletons, validated members).
- `.pdata` gives exact function bounds for ~240k functions; cold/outlined
  blocks (0x141Exxxxx region) belong to hot functions elsewhere.
- Address-library JSON: most entries are anonymous; symbol names cover ~84.
- Virtual natives (`call [vtbl+N]` in the thunk) can't be resolved statically
  without the concrete class vtable — either hook the thunk (covers script
  callers only) or log the resolved pointer at runtime from the plugin (the
  v0.8 one-time getter log pattern).
