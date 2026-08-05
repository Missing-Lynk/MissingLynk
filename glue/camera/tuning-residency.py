#!/usr/bin/env python3
"""
Report which vendor tuning pages were still resident in DRAM before a bring-up.

au-prove-camera.sh dumps pre_gamma.bin, pre_compander.bin and pre_drc.bin before it loads
anything, to establish what the vendor left behind. This decodes those dumps through the
codecs in glue/isp rather than scoring them.

An earlier version judged residency by counting zero words and testing monotonicity, and
called correct data "garbage": these are packed multi-lane formats, so a valid table is
neither mostly zero nor monotonic when read as a flat u32 array. Both scores measured the
packing, not the content. Where no decoder exists the output says so instead of guessing.

Usage: tuning-residency.py <capture-dir>
"""

import importlib.util
import os
import struct
import sys
from pathlib import Path
from types import ModuleType

# The codecs live beside this file's parent, and their names are hyphenated, so they cannot be
# imported by name.
ISP = Path(__file__).resolve().parent.parent / "isp"

# Page name to the byte count the vendor's allocation carries.
PAGES = (("gamma", 0x4000), ("compander", 0x7800), ("drc", 0x2000))


def load(name: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, ISP / f"{name}-codec.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    out = sys.argv[1]

    print("  tuning pages the vendor left resident, before this bring-up:")
    for nm, size in PAGES:
        f = os.path.join(out, "pre_" + nm + ".bin")
        if not os.path.exists(f) or os.path.getsize(f) < size:
            print(f"    {nm:<10} missing")
            continue

        data = Path(f).read_bytes()[:size]
        if nm == "gamma":
            curves = load("gamma").curves(data)
            mono = [all(c[i] >= c[i - 1] for i in range(1, len(c))) for c in curves]
            print(f"    {nm:<10} page 0 max {max(curves[0]):4d} monotonic {mono[0]}, "
                  f"page 1 max {max(curves[1]):4d} monotonic {mono[1]}")
        elif nm == "drc":
            try:
                banks = [load("drc").decode_source_bank(data, b) for b in (0, 0x800)]
                print(f"    {nm:<10} two {len(banks[0])}-sample curves, overlap fields valid")
            except ValueError as err:
                print(f"    {nm:<10} does NOT decode as a DRC page: {err}")
        else:
            words = struct.unpack(f"<{size // 4}I", data)
            print(f"    {nm:<10} {size} bytes, {words.count(0)} zero words "
                  f"(no decoder: the generator is not recovered)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
