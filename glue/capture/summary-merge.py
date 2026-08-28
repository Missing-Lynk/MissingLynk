#!/usr/bin/env python3
"""Fold a capture's runtime conditions into its summary.json.

A latency figure only means something next to the conditions it was taken under. Those conditions
live in identity.txt as prose, which is the right place to read them and the wrong place to compare
them: a reader scanning a table of runs will not open a text file per row, which is how a paced run
and an unpaced one came to be compared as though they measured the same thing.

So the handful that change what the numbers mean are carried in the summary itself, beside the
medians they qualify: the pixel clock, whether the pacing servo was steering it, the seam mode, and
for a pinned-clock leg the span the leaf actually held.

Reads the capture directory from CAPTURE, and optionally ASKED (the rate a pinned leg requested).
Merges conditions.env (key=value, written by the capture script) and clock.csv if present.
"""

from __future__ import annotations

import contextlib
import csv
import json
import os
import sys
from pathlib import Path

# conditions.env key -> summary key. Absent or empty means the knob was off, which is a fact worth
# recording as None rather than omitting: a missing key reads as "not measured".
CONDITIONS: dict[str, str] = {
    "pixclk_hz": "pixclk_hz",
    "pace_hz": "pace_hz",
    "seam": "seam_mode",
    "recording": "recording",
}

# Not an integer, and the one condition that decides whether a run measured the real link at all:
# the replayer plays a captured dump at its own rate, so its cadence and tile spacing are its own.
# "air" is asserted from RF ingress actually advancing rather than from the replayer being absent,
# so a capture taken with nothing feeding the goggle reads "none" instead of claiming a live link.
TEXT_CONDITIONS: dict[str, str] = {"source": "source", "air_version": "air_version"}


def read_conditions(path: Path) -> dict[str, object]:
    values: dict[str, object] = dict.fromkeys(
        list(CONDITIONS.values()) + list(TEXT_CONDITIONS.values()))
    if not path.is_file():
        return values

    for line in path.read_text(encoding="utf-8").splitlines():
        key, _, raw = line.partition("=")
        name = key.strip()
        if name in TEXT_CONDITIONS and raw.strip():
            values[TEXT_CONDITIONS[name]] = raw.strip()
            continue

        target = CONDITIONS.get(name)
        if target is None or not raw.strip():
            continue
        with contextlib.suppress(ValueError):
            values[target] = int(raw.strip())

    return values


def read_clock(path: Path) -> dict[str, object]:
    rates: list[int] = []
    latches: set[str] = set()
    if path.is_file():
        with path.open(encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                # A sample the poller could not read leaves a blank or "na" field; the leg is
                # still summarised from the readings that did land.
                with contextlib.suppress(KeyError, TypeError, ValueError):
                    rates.append(int(row["pixclk_hz"]))
                for key in ("int_st1_a", "int_st1_b"):
                    value = row.get(key)
                    if value and value != "na":
                        latches.add(value)

    return {
        # A leaf that moved during the leg makes every figure on the row an average over two panel
        # rates, so the span is reported rather than a single reading.
        "pixclk_hz_min": min(rates) if rates else None,
        "pixclk_hz_max": max(rates) if rates else None,
        "pixclk_samples": len(rates),
        # 0x80 is a DPI FIFO overrun: the DC fed the DSI faster than it drained.
        "dsi_int_st1": sorted(latches) or None,
    }


def main() -> int:
    capture = Path(os.environ["CAPTURE"])
    summary_path = capture / "summary.json"
    if not summary_path.is_file():
        print(f"{summary_path} does not exist; nothing to merge", file=sys.stderr)
        return 1

    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    summary.update(read_conditions(capture / "conditions.env"))

    asked = os.environ.get("ASKED")
    if asked:
        summary["pixclk_hz_asked"] = int(asked)
        summary.update(read_clock(capture / "clock.csv"))

    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
