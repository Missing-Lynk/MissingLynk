#!/usr/bin/env python3
"""Tabulate goggle latency captures side by side, so two builds can be compared by name.

Every capture writes a summary.json beside its SVG (goggle-latency-plot.py). Point this at the
capture directories, or at a run directory holding several legs, and it prints one row per capture
with the stage medians and the counts that say whether the run is usable at all.

  glue/capture/latency-compare.py out/goggle-latency/*/
  glue/capture/latency-compare.py out/pinned-clock-latency/6f773ba-dirty-20260828T081932Z
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# (json key, header, width, format). The conditions come first: a row is only comparable with
# another when the source rate, the panel rate and the pacing state line up, and putting them left
# of the medians is what stops two runs taken under different conditions being read as one result.
CONDITIONS: list[tuple[str, str, int, str]] = [
    ("source", "source", 8, "s"),
    ("recording", "rec", 5, "d"),
    ("source_fps", "src fps", 8, ".1f"),
    ("pixclk_hz", "pixclk", 10, "d"),
    ("pace_hz", "pace", 10, "d"),
]

# Ordered along the pipeline, ending with the counts that say whether a row means anything.
COLUMNS: list[tuple[str, str, int, str]] = [
    ("rxdec0", "dec t0", 7, ".1f"),
    ("rxdec1", "dec t1", 7, ".1f"),
    ("pair_skew", "pair", 6, ".1f"),
    ("subflip", "sub2flip", 9, ".1f"),
    ("rxflip50", "rx2flip", 8, ".1f"),
    ("rxflip99", "p99", 7, ".1f"),
    ("fdt50", "fdt", 6, ".1f"),
    ("judder", "jud", 5, "d"),
    ("repeats", "rep", 5, "d"),
    ("frames", "frames", 7, "d"),
]


def find_summaries(target: Path) -> list[Path]:
    """A capture directory holds summary.json; a run directory holds capture directories."""
    if target.is_file():
        return [target]

    own = target / "summary.json"
    if own.is_file():
        return [own]

    return sorted(target.glob("*/summary.json"))


def label_for(summary: Path, root: Path) -> str:
    """The capture's directory name, prefixed by the run's when the run holds several legs."""
    capture = summary.parent
    if capture == root or capture.parent == root.parent:
        return capture.name

    return f"{root.name}/{capture.name}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("targets", type=Path, nargs="+",
                        help="capture directories, run directories, or summary.json paths")
    args = parser.parse_args()

    rows: list[tuple[str, dict[str, object]]] = []
    for target in args.targets:
        summaries = find_summaries(target)
        if not summaries:
            print(f"no summary.json under {target}", file=sys.stderr)
            continue

        for summary in summaries:
            rows.append((label_for(summary, target),
                         json.loads(summary.read_text(encoding="utf-8"))))

    if not rows:
        print("nothing to compare", file=sys.stderr)
        return 1

    width = max(len(label) for label, _ in rows)
    columns = CONDITIONS + COLUMNS
    header = f"{'capture':{width}s}" + "".join(f"{h:>{w}s}" for _, h, w, _ in columns)
    print(header)
    print("-" * len(header))

    for label, stats in rows:
        line = f"{label:{width}s}"
        for key, _, w, fmt in columns:
            value = stats.get(key)
            line += f"{value:>{w}{fmt}}" if value is not None else f"{'n/a':>{w}s}"
        if stats.get("phase_forced_us") is not None:
            line += f"   PHASE-FORCED {stats['phase_forced_us']} us, NOT A LATENCY RESULT"
        print(line)

    print("\nAll figures are medians over the capture's 1 Hz summary lines, in ms.")
    print("src fps / pixclk / pace are the conditions: rows only compare when those agree.")
    print("A pace column with a value means the servo was steering the clock, so sub2flip is a "
          "swept figure, not a held one.")
    print("rec=1 means the DVR was recording: a third wave5 instance beside the two decoders, "
          "measured at about 5 ms on dec t1 and 4 ms on tile skew.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
