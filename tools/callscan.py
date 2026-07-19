"""Generic E8/E9 rel32 call-site scanner."""
import struct, sys
from cp77 import Binary, BASE

def call_sites(b, targets):
    name, srva, vsize, praw, rsize = next(s for s in b.sections if s[0] == '.text')
    lo, hi = praw, praw + rsize
    results = {t: [] for t in targets}
    for opcode in (b'\xe8', b'\xe9'):
        idx = b.raw.find(opcode, lo, hi)
        while idx != -1:
            if idx + 5 <= hi:
                rel = struct.unpack_from('<i', b.raw, idx + 1)[0]
                va = BASE + srva + (idx - praw)
                tgt = va + 5 + rel
                if tgt in results:
                    results[tgt].append(va)
            idx = b.raw.find(opcode, idx + 1, hi)
    return results

if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    b = Binary()
    tgt = int(sys.argv[1], 16) if len(sys.argv) > 1 else 0x14060D1EC
    res = call_sites(b, [tgt])[tgt]
    print(f"{len(res)} call sites for {tgt:#x}")
    funcs = {}
    for va in res:
        fb = b.func_bounds(va)
        key = fb if fb else (0, 0)
        funcs.setdefault(key, []).append(va)
    for (fs, fe), sites in sorted(funcs.items()):
        print(f"  func {fs:#x}..{fe:#x} (size {fe-fs:#x}): "
              + ", ".join(hex(v) for v in sites))
