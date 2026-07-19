"""Scan .text for `mov [reg+DISP], ...` store encodings of a given
displacement — finds candidate writers of a struct field when the object's
address is unknown statically.

Usage: python storescan.py 0x28A [byte|dword]   (default: byte)

Matches mod=10 (disp32) ModRM forms without SIB:
  byte  stores: 88 /r (reg8) and C6 /0 (imm8)
  dword stores: 89 /r (reg32) and C7 /0 (imm32)
REX prefixes don't affect the match (they precede the opcode).

Each hit is printed with its containing function bounds; disassemble
interesting ones with dumpfunc.py. Caveat (hard-learned): common offsets
(0x110, 0x1E0...) hit hundreds of unrelated classes — cross-check by
singleton loads or use the plugin's hardware-watchpoint diag instead.
This found the single writer of the pointer-mode cursor flag
InkSystem+0x28A (at 0x14039b7a1) proving cursor independence from the
suppressed device writer.
"""
import re
import struct
import sys
from cp77 import Binary, BASE


def main():
    disp = int(sys.argv[1], 16)
    width = sys.argv[2] if len(sys.argv) > 2 else "byte"
    opcodes = {"byte": (0x88, 0xC6), "dword": (0x89, 0xC7)}[width]
    d32 = struct.pack("<i", disp)

    b = Binary()
    name, srva, vsize, praw, rsize = next(s for s in b.sections if s[0] == ".text")

    # ModRM mod=10, rm != 100 (no SIB): 0x80-0xBF minus (x & 7) == 4
    modrm = bytes(m for m in range(0x80, 0xC0) if m & 7 != 4)
    pat = re.compile(
        b"(?:" + b"|".join(re.escape(bytes([op])) for op in opcodes) + b")"
        b"[" + re.escape(modrm) + b"]" + re.escape(d32),
        re.DOTALL)

    hits = 0
    for m in pat.finditer(b.raw, praw, praw + rsize):
        va = BASE + srva + (m.start() - praw)
        fb = b.func_bounds(va)
        fstr = f"func {fb[0]:#x}..{fb[1]:#x}" if fb else "no bounds"
        print(f"{va:#x}  ({fstr})")
        hits += 1
    print(f"{hits} candidate {width}-store(s) of [reg+{disp:#x}] in .text")


if __name__ == "__main__":
    main()
