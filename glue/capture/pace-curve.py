#!/usr/bin/env python3
"""Read the pace servo's latency-against-smoothness curve out of a pipeline log.

The margin the servo holds is the last term of goggle-side latency that policy can
move: everything below it is decode, transmission and compose. Choosing it needs
both halves of the trade measured on the same source, because a margin that is too
wide costs milliseconds nobody can perceive and one that is too narrow costs
repeated frames, which a viewer sees at once.

The servo random-walks its own margin, so a long run has already swept it. Each
second it prints a `pace` line carrying the margin it held and a `lat` line
carrying the latency and repeat counts that margin bought. Pairing them and
bucketing by margin turns any run of a few minutes into the curve.

Only seconds where the proportional term was idle (`cmd == hold`) are counted. On
a steering tick the panel phase is moving under the measurement, so the second's
latency belongs to the slew and not to the margin.

Usage:
  pace-curve.py <ml-pipeline.log> [...]
"""

from __future__ import annotations

import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

LAT = re.compile(
    r"lat n=(\d+) rx2flip p50=([\d.]+) p99=([\d.]+) \| rx2dec ([\d.]+)/([\d.]+) "
    r"pair ([\d.]+) sub2flip ([\d.]+) \| fdt p50=([\d.]+) p99=([\d.]+) "
    r"jud=(\d+) rep=(\d+)"
)
PACE = re.compile(
    r"pace n=(\d+) lo=(-?\d+)us tgt=(\d+)us(?: miss=(\d+) gap=(\d+))? "
    r"hold=(\d+) cmd=(\d+)"
)

MIN_FLIPS = 55        # a second short of a full 60 measures a stalled generation
MIN_SECONDS = 8       # a bucket thinner than this is one transit, not a dwell


def read_seconds(path: Path) -> list[dict[str, float]]:
    """Pair each `lat` summary with the `pace` line printed for the same second."""
    seconds: list[dict[str, float]] = []
    pending: dict[str, float] | None = None

    for line in path.read_text(errors="replace").splitlines():
        lat = LAT.search(line)
        if lat:
            pending = {
                "flips": int(lat.group(1)),
                "rx50": float(lat.group(2)), "rx99": float(lat.group(3)),
                "dec0": float(lat.group(4)), "dec1": float(lat.group(5)),
                "skew": float(lat.group(6)), "sub": float(lat.group(7)),
                "judder": int(lat.group(10)), "repeats": int(lat.group(11)),
            }
            continue

        pace = PACE.search(line)
        if pace and pending is not None:
            pending.update(
                margin=int(pace.group(3)),
                low=int(pace.group(2)),
                hold=int(pace.group(6)),
                cmd=int(pace.group(7)),
            )
            seconds.append(pending)
            pending = None

    return seconds


def report(path: Path) -> None:
    seconds = read_seconds(path)
    if not seconds:
        print(f"{path}: no paired pace/lat seconds "
              f"(needs ML_LATSTATS=1 and ML_PACE_DBG=1)")
        return

    settled = [s for s in seconds
               if s["cmd"] == s["hold"] and s["flips"] >= MIN_FLIPS]

    print(f"\n=== {path}")
    print(f"{len(seconds)} paired seconds, {len(settled)} of them settled "
          f"(the servo idle and the panel at rate)")
    if not settled:
        return

    buckets: dict[int, list[dict[str, float]]] = defaultdict(list)
    for s in settled:
        buckets[int(s["margin"]) // 1000].append(s)

    print(f"\n{'margin':>9} {'seconds':>8} {'rx2flip p50':>12} {'rx2flip p99':>12} "
          f"{'sub2flip':>9} {'repeats/min':>12} {'judder/min':>11}")
    for key in sorted(buckets):
        rows = buckets[key]
        if len(rows) < MIN_SECONDS:
            continue
        print(f"{key}-{key + 1} ms {len(rows):8d} "
              f"{statistics.median([r['rx50'] for r in rows]):12.2f} "
              f"{statistics.median([r['rx99'] for r in rows]):12.2f} "
              f"{statistics.median([r['sub'] for r in rows]):9.2f} "
              f"{60 * sum(r['repeats'] for r in rows) / len(rows):12.2f} "
              f"{60 * sum(r['judder'] for r in rows) / len(rows):11.2f}")

    thin = sum(len(r) for k, r in buckets.items() if len(r) < MIN_SECONDS)
    if thin:
        print(f"  {thin} settled seconds fell in buckets under {MIN_SECONDS} s "
              f"and are not shown")

    print(f"\nover the settled seconds: {sum(s['repeats'] for s in settled)} repeats, "
          f"{sum(s['judder'] for s in settled)} judder events in {len(settled)} s")
    print(f"source, unaffected by the margin: rx2dec "
          f"{statistics.median([s['dec0'] for s in settled]):.2f}/"
          f"{statistics.median([s['dec1'] for s in settled]):.2f} ms, tile skew "
          f"{statistics.median([s['skew'] for s in settled]):.2f} ms")


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    for arg in sys.argv[1:]:
        report(Path(arg))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
