"""Find the registered native handler ("script thunk") of a script-visible
native function by name — recipe 1 automated.

Usage: python findnative.py PlayerLastUsedKBM [OtherName...]

Steps performed: locate the ASCII "Name\\0" string in the exe, numpy-scan
.text for rip-relative references to it (that reference sits in the RTTI
registration function), then list every `lea` rip-target inside that
function. The native handler is the `lea rax, [rip +/- X]` loaded right
before the registration call — in the output it is the target that has its
own .pdata function bounds (annotated with [func ... addr-lib ...]).
Verify by disassembling it with dumpfunc.py: registered bool-returning
natives look like `resolve context -> vcall [vtbl+N] -> mov [r8], al`.

This is how the PlayerLastUsedKBM/Pad/PS5Pad handlers (hashes 1037639234 /
1291656829 / 2647269205) were found for the v0.9/v0.9.1 hooks.

Each name costs a few seconds of numpy scanning over .text.
"""
import sys
from cp77 import BASE
import riprefs


def main():
    b = riprefs.get_binary()
    for name in sys.argv[1:]:
        hits = b.find_bytes(name.encode() + b"\x00")
        print(f"### {name!r}: string at {[hex(h) for h in hits]}")
        for h in hits:
            for dw_va, imm in riprefs.rip_refs(h):
                fb = b.func_bounds(dw_va)
                if not fb:
                    continue
                print(f"  registration func {fb[0]:#x}..{fb[1]:#x} (ref at {dw_va:#x})")
                for ins in b.disasm(fb[0], fb[1]):
                    if ins.mnemonic == "lea" and "rip" in ins.op_str and ins.disp:
                        tgt = ins.address + ins.size + ins.disp
                        tf = b.func_bounds(tgt)
                        note = ""
                        if tf and tf[0] == tgt:
                            note = f"  [func {tf[0]:#x}..{tf[1]:#x}, addr-lib 0001:{tf[0] - BASE - 0x1000:08x}]"
                        print(f"    lea @{ins.address:#x} {ins.op_str}  -> {tgt:#x}{note}")
        print()


if __name__ == "__main__":
    main()
