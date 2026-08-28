#!/usr/bin/env python3
"""Fold a pinned-clock leg's clock trace into that leg's summary.json.

pinned-clock-latency.sh samples the pixel-clock leaf and the DSI INT_ST1 latch through each leg and
writes them to clock.csv. Those belong with the leg's latency medians rather than in a file beside
them: one summary then answers both what the panel was doing and what it cost. The trace itself is
a few hundred bytes of repeated readings, so the scalars replace it rather than joining it.

Reads LEG (the leg directory) and ASKED (the rate the leg requested) from the environment.
"""

from __future__ import annotations

import contextlib
import csv
import json
import os
import sys
from pathlib import Path


def main() -> int:
    leg = Path(os.environ["LEG"])
    asked = int(os.environ["ASKED"])
    summary_path = leg / "summary.json"
    clock_path = leg / "clock.csv"

    if not summary_path.is_file():
        print(f"{summary_path} does not exist; nothing to merge", file=sys.stderr)
        return 1

    rates: list[int] = []
    latches: set[str] = set()
    if clock_path.is_file():
        with clock_path.open(encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                # A sample the poller could not read leaves a blank or "na" field; the leg is
                # still summarised from the readings that did land.
                with contextlib.suppress(KeyError, TypeError, ValueError):
                    rates.append(int(row["pixclk_hz"]))
                for key in ("int_st1_a", "int_st1_b"):
                    value = row.get(key)
                    if value and value != "na":
                        latches.add(value)

    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    summary["pixclk_hz_asked"] = asked
    # A leaf that moved during the leg makes every figure on the row an average over two panel
    # rates, so the span is reported rather than a single reading.
    summary["pixclk_hz_min"] = min(rates) if rates else None
    summary["pixclk_hz_max"] = max(rates) if rates else None
    summary["pixclk_samples"] = len(rates)
    # 0x80 is a DPI FIFO overrun: the DC fed the DSI faster than it drained.
    summary["dsi_int_st1"] = sorted(latches) or None

    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
