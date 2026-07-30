#!/usr/bin/env python3
"""Diff two register-window dumps produced by ml-regdump.

Both sides must have been captured with the same window list, which is why
au-prove-camera.sh stage 4c copies au-snapshot-vendor.sh's list verbatim.

The point of this script over a plain diff is that it separates the noise from
the signal. Runtime values (DMA pointers, statistics, frame counters) differ on
every read and drown a raw diff; contiguous runs holding the same wrong value
are the interesting case, because they are one coefficient array from a wrong
default rather than scattered drift.

    diff-live-registers.py VENDOR OURS [--runs]
"""

import contextlib
import re
import sys
from collections import defaultdict

HEADER = re.compile(r"^---\s+(\S+)\s+\+(\S+)\s+\((\d+) words\)")
LINE = re.compile(r"^\+(?:0[xX])?([0-9a-fA-F]+):\s+(.*)$")

# Registers whose value is expected to change between any two reads. Comparing
# them says nothing, and leaving them in the count is how an earlier pass
# reported differences that were only ever frame state.
RUNTIME = {
    # ISP statistics and DMA pointers, republished every frame.
    ("isp", 0x0030), ("isp", 0x0040), ("isp", 0x0050), ("isp", 0x0060),
    ("isp", 0x0014), ("isp", 0x0018), ("isp", 0x001c),
    # VIF frame counters and W1C status.
    ("vif", 0x017c), ("vif", 0x0184), ("vif", 0x01b0), ("vif", 0x0020),
    # CVISP ring pointers.
    ("cvisp", 0x8010), ("cvisp", 0x8014), ("cvisp", 0x8018),
}


def parse(path):
    """Return {(block, addr): value} for every word in the dump.

    ml-regdump prints offsets relative to the address it was given, so every
    window restarts at +0x0000. The window's own base has to be added back or
    the ISP's nine windows all collide at the same keys.
    """
    out = {}
    block = None
    base = 0
    with open(path) as fh:
        for raw in fh:
            h = HEADER.match(raw)
            if h:
                block = h.group(1)
                base = int(h.group(2), 16)
                continue
            m = LINE.match(raw)
            if not m or block is None:
                continue
            addr = base + int(m.group(1), 16)
            for i, word in enumerate(m.group(2).split()):
                with contextlib.suppress(ValueError):
                    out[(block, addr + i * 4)] = int(word, 16)
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    show_runs = "--runs" in sys.argv
    if len(args) != 2:
        print(__doc__)
        return 1

    vendor = parse(args[0])
    ours = parse(args[1])

    common = sorted(set(vendor) & set(ours))
    if not common:
        print("no overlapping registers: were both dumps taken with the same window list?")
        return 1

    diffs = []
    runtime = 0
    for key in common:
        if vendor[key] == ours[key]:
            continue
        if key in RUNTIME:
            runtime += 1
            continue
        diffs.append(key)

    zeros = sum(1 for k in diffs if ours[k] == 0)
    print(f"{len(common)} registers present on both sides")
    print(f"{len(common) - len(diffs) - runtime} identical")
    print(f"{runtime} known runtime values, excluded")
    print(f"{len(diffs)} differ, {zeros} of them zero on ours")

    if not diffs:
        return 0

    pages = defaultdict(int)
    for blk, addr in diffs:
        pages[(blk, addr & ~0xFF)] += 1
    print("\nby page:")
    for (blk, page), n in sorted(pages.items(), key=lambda kv: -kv[1])[:16]:
        print(f"  {blk} 0x{page:04x}: {n}")

    # Contiguous runs sharing one (ours, vendor) pair. This is what found the
    # 0x1800 array: eighteen consecutive words holding 0x000f000a against
    # 0x002e002d is a single wrong default, not eighteen independent faults.
    runs = []
    start = None
    for i, key in enumerate(diffs):
        pair = (ours[key], vendor[key])
        prev = diffs[i - 1] if i else None
        contiguous = (
            prev is not None
            and key[0] == prev[0]
            and key[1] == prev[1] + 4
            and pair == (ours[prev], vendor[prev])
        )
        if not contiguous:
            if start is not None and i - start >= 3:
                runs.append((diffs[start], i - start, ours[diffs[start]], vendor[diffs[start]]))
            start = i
    if start is not None and len(diffs) - start >= 3:
        runs.append((diffs[start], len(diffs) - start, ours[diffs[start]], vendor[diffs[start]]))

    if runs:
        print("\nuniform runs (3+ consecutive words, same wrong value):")
        for (blk, addr), n, o, v in runs:
            print(f"  {blk} +0x{addr:04x} x{n:<4} ours 0x{o:08x}  vendor 0x{v:08x}")

    if show_runs:
        print("\nall differences:")
        for blk, addr in diffs:
            print(f"  {blk} +0x{addr:04x}  ours 0x{ours[(blk, addr)]:08x}  vendor 0x{vendor[(blk, addr)]:08x}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
