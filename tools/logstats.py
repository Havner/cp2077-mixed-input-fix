"""Summarize a mixedinputfix-*.log: per-message-type line counts, highest
counter values, and per-minute counter deltas.

Usage: python logstats.py <path-to-log>

Written for the observer-mode crash run analysis (see RE-notes.md, "Freeze
reproduction evidence"): the per-minute table shows event *rates* over the
session, and the max counters give the totals at freeze (lower bounds — the
counters are sampled: the release plugin logs the first 20 then every 1000th
event, the observer build logged every 100th, and the logger flushes in
batches). Works on any MixedInputFix log since the messages embed
(count=N)/(transition#N).
"""
import collections
import datetime
import re
import sys

TS = re.compile(r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.(\d{3})\]")
CNT = re.compile(r"\((?:count=|transition#)(\d+)\)")
TAG = re.compile(r"\[MixedInputFix\] (\[[^\]]+\]|\S+)")


def ts(line):
    m = TS.match(line)
    if not m:
        return None
    return (datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
            + datetime.timedelta(milliseconds=int(m.group(2))))


def main():
    lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
    t0, tN = ts(lines[0]), ts(lines[-1])
    print(f"{len(lines)} lines, span {t0} .. {tN} ({(tN - t0).total_seconds() / 60:.1f} min)\n")

    tags = collections.Counter()
    maxcount = {}
    last_ts = {}
    per_min = collections.defaultdict(dict)  # key -> minute -> last counter
    for l in lines:
        m = TAG.search(l)
        if not m:
            continue
        key = m.group(1) + " " + " ".join(l[m.end():].strip().split()[:4])
        tags[key] += 1
        t = ts(l)
        if t:
            last_ts[key] = t
        c = CNT.search(l)
        if c and t:
            v = int(c.group(1))
            maxcount[key] = max(maxcount.get(key, 0), v)
            per_min[key][t.replace(second=0, microsecond=0)] = v

    print("lines | max counter | last seen | message")
    for key, n in tags.most_common():
        print(f"{n:6d} | {maxcount.get(key, '-')!s:>9} | {last_ts.get(key, '?')} | {key[:90]}")

    for key in sorted(per_min, key=lambda k: -maxcount.get(k, 0)):
        buckets = per_min[key]
        if maxcount.get(key, 0) < 200:
            continue
        print(f"\nper-minute deltas: {key[:90]}")
        prev = 0
        for minute in sorted(buckets):
            v = buckets[minute]
            print(f"  {minute.time()}  {v:>9}  (+{v - prev})")
            prev = v


if __name__ == "__main__":
    main()
