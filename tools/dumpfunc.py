"""Disassemble the function containing a VA (bounds from .pdata).

Usage: python dumpfunc.py 0x140269954 [more VAs...]

For each VA prints the containing function's full disassembly with resolved
rip-relative targets, marks the argument VA, and prints the address-library
offset line ("0001:XXXXXXXX") to grep in cyberpunk2077_addresses.json for the
function's hash. This was the workhorse for analyzing the device writer
(0x140269954), its helpers, and the PlayerLastUsed* thunks.
"""
import sys
from cp77 import Binary, BASE, fmt_ins


def main():
    b = Binary()
    for arg in sys.argv[1:]:
        va = int(arg, 16)
        fb = b.func_bounds(va)
        if not fb:
            print(f"{va:#x}: no .pdata bounds (cold block or data?)")
            continue
        start, end = fb
        print(f"=== {va:#x} in func {start:#x}..{end:#x} (size {end - start:#x}) ===")
        print(f"addr-lib offset (if in .text): 0001:{start - BASE - 0x1000:08x}")
        for ins in b.disasm(start, end):
            extra = ""
            if "rip" in ins.op_str and ins.disp:
                extra = f"   ; -> {ins.address + ins.size + ins.disp:#x}"
            mark = "  <== arg VA" if ins.address <= va < ins.address + ins.size else ""
            print(fmt_ins(ins) + extra + mark)
        print()


if __name__ == "__main__":
    main()
