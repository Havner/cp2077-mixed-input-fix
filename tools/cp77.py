"""Shared helpers for static analysis of Cyberpunk2077.exe"""
import bisect
import pefile
import capstone

EXE = r"D:\Games\GOG\Cyberpunk 2077\bin\x64\Cyberpunk2077.exe"
BASE = 0x140000000

class Binary:
    def __init__(self, path=EXE):
        self.pe = pefile.PE(path, fast_load=True)
        self.pe.parse_data_directories(directories=[
            pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_EXCEPTION']])
        with open(path, 'rb') as f:
            self.raw = f.read()
        self.sections = []
        for s in self.pe.sections:
            name = s.Name.rstrip(b'\0').decode()
            self.sections.append((name, s.VirtualAddress, s.Misc_VirtualSize,
                                  s.PointerToRawData, s.SizeOfRawData))
        # function table from .pdata
        self.func_starts = []
        self.func_ends = {}
        for rf in self.pe.DIRECTORY_ENTRY_EXCEPTION:
            try:
                beg = rf.struct.BeginAddress
                end = rf.struct.EndAddress
            except AttributeError:
                continue
            if beg and end:
                self.func_starts.append(beg)
                self.func_ends[beg] = end
        self.func_starts = sorted(set(self.func_starts))
        self.cs = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
        self.cs.detail = True

    def va2off(self, va):
        rva = va - BASE
        for name, srva, vsize, praw, rsize in self.sections:
            if srva <= rva < srva + max(vsize, rsize):
                return praw + (rva - srva)
        raise ValueError(f"va {va:#x} not in any section")

    def read(self, va, size):
        off = self.va2off(va)
        return self.raw[off:off + size]

    def func_bounds(self, va):
        """Return (start_va, end_va) of function containing va, using .pdata.
        Chained entries: walk down to enclosing entry."""
        rva = va - BASE
        i = bisect.bisect_right(self.func_starts, rva) - 1
        if i < 0:
            return None
        beg = self.func_starts[i]
        end = self.func_ends[beg]
        if not (beg <= rva < end):
            return None
        return (BASE + beg, BASE + end)

    def disasm(self, start_va, end_va):
        code = self.read(start_va, end_va - start_va)
        return list(self.cs.disasm(code, start_va))

    def find_bytes(self, pattern, section=None):
        """Find raw byte pattern; returns list of VAs."""
        hits = []
        for name, srva, vsize, praw, rsize in self.sections:
            if section and name != section:
                continue
            lo, hi = praw, praw + rsize
            idx = self.raw.find(pattern, lo, hi)
            while idx != -1:
                hits.append(BASE + srva + (idx - praw))
                idx = self.raw.find(pattern, idx + 1, hi)
        return hits

def fnv1a64(s: str) -> int:
    h = 0xCBF29CE484222325
    for c in s.encode():
        h ^= c
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h

def fmt_ins(ins):
    return f"{ins.address:012x}  {ins.mnemonic:<12} {ins.op_str}"
