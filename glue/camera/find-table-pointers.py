#!/usr/bin/env python3
"""
List register words that look like pointers into the vendor's media carveout.

au-snapshot-vendor.sh dumps every ISP and CVISP register window to registers.txt while the
vendor stack is running. The tables those blocks read live in DRAM, and the only way to find
them without knowing each register's meaning is to look for register values that fall inside
the carveout: 0x28000000..0x40000000, which sits above the memory the kernel is capped to and
so cannot be an ordinary kernel address.

This is a candidate list, not a decode. A value in range is a pointer-shaped word, nothing more.

Reads registers.txt from the capture directory, writes the list to stdout.

Usage: find-table-pointers.py <capture-dir>
"""

import re
import sys
from pathlib import Path

# The vendor media carveout, above the kernel's capped memory.
CARVEOUT_LO = 0x28000000
CARVEOUT_HI = 0x40000000

BLOCK_RE = re.compile(r"--- (\w+) \+(0x[0-9a-f]+)")
WORDS_RE = re.compile(r"\+0x([0-9a-f]+):((?: [0-9a-f]{8})+)")


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    txt = (Path(sys.argv[1]) / "registers.txt").read_text()
    block, base = None, 0
    seen: dict[tuple[str, int], int] = {}

    for line in txt.splitlines():
        m = BLOCK_RE.match(line)
        if m:
            block, base = m.group(1), int(m.group(2), 16)
            continue

        m = WORDS_RE.match(line)
        if not m or block is None:
            continue

        off = base + int(m.group(1), 16)
        for i, w in enumerate(m.group(2).split()):
            v = int(w, 16)
            if CARVEOUT_LO <= v < CARVEOUT_HI:
                seen[(block, off + 4 * i)] = v

    for (blk, off), v in sorted(seen.items()):
        print(f"{blk:<6} +0x{off:04x}  ->  0x{v:08x}")

    print(f"\n{len(seen)} candidate table pointers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
