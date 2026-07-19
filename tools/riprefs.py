"""Find rip-relative references to given VAs across .text using numpy displacement scan."""
import numpy as np
from cp77 import Binary, BASE

_b = None
_text = None

def get_binary():
    """Load (and cache for the process) the PE plus the .text section info."""
    global _b, _text
    if _b is None:
        _b = Binary()
        name, srva, vsize, praw, rsize = next(s for s in _b.sections if s[0] == '.text')
        _text = (srva, praw, rsize)
    return _b

def rip_refs(target_va, extra_imm=(0, 1, 4)):
    """Return VAs (of the dword position) where dword + end-of-dword-va (+imm) == target.

    The PE load is cached (get_binary); the displacement scan itself reruns on
    every call - a few seconds of numpy work over .text per target."""
    b = get_binary()
    srva, praw, rsize = _text
    # dword at raw offset praw+i (i in 0..rsize-4) sits at VA BASE+srva+i
    n = rsize - 4
    # build an unaligned little-endian dword view from 4 shifted byte views
    arr = np.frombuffer(b.raw, dtype=np.uint8, count=rsize, offset=praw)
    res = []
    a32 = arr[0:n].astype(np.uint32)
    a32 += arr[1:n+1].astype(np.uint32) << 8
    a32 += arr[2:n+2].astype(np.uint32) << 16
    a32 += arr[3:n+3].astype(np.uint32) << 24
    base_vas = np.arange(n, dtype=np.int64) + (BASE + srva)
    for imm in extra_imm:
        # target = va_of_dword + 4 + imm + disp  (disp signed)
        disp = np.int64(target_va) - (base_vas + 4 + imm)
        hits = np.nonzero(a32.astype(np.int64).astype(np.int32) == disp)[0]
        for i in hits:
            res.append((int(BASE + srva + i), imm))
    return res

if __name__ == '__main__':
    import sys
    sys.stdout.reconfigure(encoding='utf-8')
    b = get_binary()
    for label, va in [("str_SetUint", 0x142e8b3d0), ("str_gameIBlackboard", 0x142ba66e0)]:
        refs = rip_refs(va)
        print(f"{label} ({va:#x}): {len(refs)} rip-refs")
        for dw_va, imm in refs:
            # instruction likely starts 3 bytes before dword (lea r64) — report func
            fb = b.func_bounds(dw_va)
            fstr = f"func {fb[0]:#x}..{fb[1]:#x}" if fb else "?"
            print(f"  dword@{dw_va:#x} (+imm{imm})  {fstr}")
