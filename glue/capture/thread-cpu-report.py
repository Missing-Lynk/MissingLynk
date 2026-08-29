#!/usr/bin/env python3
"""Turn thread-cpu.sh samples into a per-thread share of the goggle's two cores.

The samples are cumulative jiffies, so the work is in the differences: each consecutive pair of
seconds for a thread gives that second's user and system time. What matters for a leg that lost
time to latch wait rather than decode is whether a core was saturated and which threads held it,
so the totals are printed against the two cores the part actually has.

Threads are grouped by name. GStreamer names a streaming thread after the pad that drives it, so
the two decoders read as src0:src and src1:src, and several short-lived pool threads share a name.

  glue/capture/thread-cpu-report.py out/latency-matrix/<run>/*-threads.csv
"""

from __future__ import annotations

import argparse
import csv
import sys
from collections import defaultdict
from pathlib import Path

USER_HZ: int = 100
CORES: int = 2


def leg_shares(path: Path) -> tuple[dict[str, float], int]:
    """Return each thread name's mean share of one core, and the seconds covered."""
    # (name, tid) -> {second: jiffies}, so a tid that is reused keeps its own series.
    series: dict[tuple[str, str], dict[int, int]] = defaultdict(dict)

    with path.open(newline="") as fh:
        for row in csv.DictReader(fh):
            try:
                second: int = int(row["sec"])
                jiffies: int = int(row["utime"]) + int(row["stime"])
            except (KeyError, TypeError, ValueError):
                continue

            series[(row["comm"], row["tid"])][second] = jiffies

    seconds: set[int] = set()
    totals: dict[str, int] = defaultdict(int)
    for (name, _tid), samples in series.items():
        marks: list[int] = sorted(samples)
        for previous, current in zip(marks, marks[1:], strict=False):
            if current != previous + 1:
                continue

            totals[name] += samples[current] - samples[previous]
            seconds.add(current)

    span: int = len(seconds)
    if span == 0:
        return {}, 0

    return {name: total / USER_HZ / span * 100 for name, total in totals.items()}, span


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("samples", nargs="+", type=Path, help="<leg>-threads.csv files")
    parser.add_argument("--top", type=int, default=12, help="threads to show per leg (default 12)")
    args = parser.parse_args()

    for path in args.samples:
        if not path.is_file():
            print(f"no such file: {path}", file=sys.stderr)
            continue

        shares, span = leg_shares(path)
        if not shares:
            print(f"{path.name}: no usable samples", file=sys.stderr)
            continue

        busiest: list[tuple[str, float]] = sorted(shares.items(), key=lambda kv: -kv[1])
        total: float = sum(shares.values())

        print(f"=== {path.name}  ({span} s)")
        print(f"  {'thread':<20}{'% of one core':>14}")
        for name, share in busiest[:args.top]:
            print(f"  {name:<20}{share:>14.1f}")

        if len(busiest) > args.top:
            rest: float = sum(share for _, share in busiest[args.top:])
            print(f"  {f'({len(busiest) - args.top} more)':<20}{rest:>14.1f}")

        print(f"  {'TOTAL':<20}{total:>14.1f}"
              f"   = {total / CORES:.0f}% of the {CORES} cores")
        print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
