#!/usr/bin/env python3
"""Compare latency-matrix runs by each leg's distance from its own base leg.

A run's absolute numbers carry the panel phase its pipeline generation settled on, and that phase
differs between generations, so two runs taken across an ml-video restart cannot be read against
each other directly. What survives the restart is what the encoder costs: the distance from the
run's own base leg. This prints that distance, one column per run, so a lever that changes the
encoder's cost is visible even though every absolute number moved.

The base leg carries no encoder, so its own row is the control: if two runs disagree there, their
generations differ by more than the phase and the deltas below are not comparable either.

  glue/capture/latency-delta.py out/latency-matrix/<run-a> out/latency-matrix/<run-b>
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# (json key, label, format). Ordered along the pipeline. The decode terms are the ones that carry
# the encoder's cost; subflip is downstream consequence and moves with the phase as well.
TERMS: list[tuple[str, str, str]] = [
    ("rxdec0", "rxdec0", ".2f"),
    ("rxdec1", "rxdec1", ".2f"),
    ("pair_skew", "pair_skew", ".2f"),
    ("pair_issue", "compose", ".2f"),
    ("subflip", "subflip", ".2f"),
    ("rxflip50", "rx2flip p50", ".2f"),
    ("rxflip99", "rx2flip p99", ".2f"),
    ("repeats", "repeats", "d"),
    ("judder", "judder", "d"),
]

LEGS: list[str] = ["base", "rec", "stream", "both"]


def load_run(run: Path) -> tuple[str, dict[str, dict]]:
    """Return the run's label and its legs' summaries, keyed by leg name."""
    codec_file: Path = run / "codec.txt"
    codec: str = codec_file.read_text().strip() if codec_file.is_file() else "?"
    label: str = f"{run.name[:15]} {codec}"

    legs: dict[str, dict] = {}
    for leg in LEGS:
        summary: Path = run / leg / "summary.json"
        if summary.is_file():
            with summary.open() as fh:
                legs[leg] = json.load(fh)

    return label, legs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("runs", nargs="+", type=Path, help="latency-matrix run directories")
    args = parser.parse_args()

    runs: list[tuple[str, dict[str, dict]]] = [load_run(run) for run in args.runs]
    runs = [(label, legs) for label, legs in runs if legs]
    if not runs:
        print("no legs with a summary.json under those directories", file=sys.stderr)
        return 1

    missing: list[str] = [label for label, legs in runs if "base" not in legs]
    if missing:
        print(f"no base leg in: {', '.join(missing)}", file=sys.stderr)
        return 1

    width: int = max(len(label) for label, _ in runs) + 2

    print("absolute, base leg (the control: these should agree)")
    print(f"  {'term':<14}" + "".join(f"{label:>{width}}" for label, _ in runs))
    for key, label, fmt in TERMS:
        cells: str = ""
        for _, legs in runs:
            value = legs["base"].get(key)
            cells += f"{value:>{width}{fmt}}" if value is not None else f"{'-':>{width}}"
        print(f"  {label:<14}{cells}")

    for leg in LEGS:
        if leg == "base" or not any(leg in legs for _, legs in runs):
            continue

        print()
        print(f"{leg} minus base")
        print(f"  {'term':<14}" + "".join(f"{label:>{width}}" for label, _ in runs))
        for key, label, fmt in TERMS:
            cells = ""
            for _, legs in runs:
                if leg not in legs:
                    cells += f"{'-':>{width}}"
                    continue

                value, base = legs[leg].get(key), legs["base"].get(key)
                if value is None or base is None:
                    cells += f"{'-':>{width}}"
                else:
                    cells += f"{value - base:>+{width}{fmt}}"
            print(f"  {label:<14}{cells}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
