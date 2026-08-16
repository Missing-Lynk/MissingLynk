#!/usr/bin/env python3
"""Summarise several vendor/open AB reports from a forced ISP sweep.

Input directories are the outputs of glue/capture/ab-image-diff.py. The helper
keeps the comparison at the level the AB method can prove: which forced point
best reduces the measured image deltas, and which family remains dominant after
the forced tone selector changes.

Usage:
  ab-sweep-summary.py out/au-ab/report-g3-d3 out/au-ab/report-g2-d3 \
      out/au-ab/report-g3-d4 out/au-ab/report-g2-d4 -o out/au-ab/tone-sweep.md
"""

import argparse
import csv
import math
import re
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Any

# One capture leg's per-frame metric samples, and one report's summary row.
Samples = dict[str, list[dict[str, float]]]
Row = dict[str, Any]

TONE_LEVELS = (16, 32, 64, 96, 128, 160, 192, 224, 240)
REQUIRED_SAMPLE_FIELDS = (
    "leg",
    "mean",
    "p50",
    "p95",
    "p99",
    "gradient",
    "spatial_noise",
    "temporal_noise",
    "local_contrast",
    "chroma",
    "rg_all",
    "bg_all",
    "rg_mid",
    "bg_mid",
    "rg_high",
    "bg_high",
)


def mean(values: Sequence[float]) -> float:
    values = [v for v in values if not math.isnan(v)]
    return sum(values) / len(values) if values else math.nan


def rel_delta(open_value: float, vendor_value: float) -> float:
    return (open_value - vendor_value) / max(abs(vendor_value), 1.0)


def parse_sample_value(path: Path, row_number: int, key: str,
                       value: str | None) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{path}: row {row_number}: {key} must be numeric") from exc

    if not math.isfinite(number):
        raise ValueError(f"{path}: row {row_number}: {key} must be finite")

    return number


def read_samples(path: Path) -> Samples:
    rows: Samples = {"vendor": [], "open": []}
    with path.open(newline="") as handle:
        reader = csv.DictReader(handle)
        missing = [field for field in REQUIRED_SAMPLE_FIELDS if field not in (reader.fieldnames or ())]
        if missing:
            raise ValueError(f"{path}: missing required sample column(s): {', '.join(missing)}")

        for row in reader:
            leg = row.get("leg")
            if leg in rows:
                sample = {}
                for key, value in row.items():
                    if key == "leg":
                        continue

                    if key is None:
                        raise ValueError(f"{path}: row {reader.line_num}: unexpected extra sample value")

                    sample[key] = parse_sample_value(path, reader.line_num, key, value)

                rows[leg].append(sample)

    if not rows["vendor"] or not rows["open"]:
        raise ValueError(f"{path}: expected vendor and open rows")

    return rows


def read_report(path: Path) -> tuple[str, dict[str, float]]:
    label = path.parent.name
    tone_values = []
    for line in path.read_text().splitlines():
        match = re.match(r"- ([^:]+): `", line)
        if match and match.group(1) != "vendor":
            label = match.group(1)

        if line.startswith("| vendor luma |"):
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            try:
                tone_values = [float(cell) for cell in cells[1:]]
            except ValueError as exc:

                raise ValueError(f"{path}: malformed tone-transfer row") from exc

    if len(tone_values) != len(TONE_LEVELS):
        raise ValueError(f"{path}: could not read tone-transfer row")

    return label, tone_values


def metric_delta(samples: Samples, key: str) -> tuple[float, float, float]:
    vendor_value = mean(row[key] for row in samples["vendor"])
    open_value = mean(row[key] for row in samples["open"])
    return vendor_value, open_value, open_value - vendor_value


def ratio_delta(samples: Samples, key: str) -> float:
    vendor_value, open_value, delta = metric_delta(samples, key)
    if math.isnan(vendor_value) or math.isnan(open_value):
        return 0.0

    return abs(delta)


def summarise(report_dir: Path) -> Row:
    report_dir = Path(report_dir)
    samples = read_samples(report_dir / "samples.csv")
    label, tone_values = read_report(report_dir / "report.md")

    mean_luma = metric_delta(samples, "mean")
    p50 = metric_delta(samples, "p50")
    p95 = metric_delta(samples, "p95")
    p99 = metric_delta(samples, "p99")
    gradient = metric_delta(samples, "gradient")
    spatial = metric_delta(samples, "spatial_noise")
    temporal = metric_delta(samples, "temporal_noise")
    local = metric_delta(samples, "local_contrast")
    chroma = metric_delta(samples, "chroma")

    tone_abs = mean(abs(value - level)
                    for level, value in zip(TONE_LEVELS, tone_values, strict=True))
    shoulder_abs = mean(abs(delta) for delta in (p95[2], p99[2]))
    tone_score = mean(abs(delta) for delta in (p50[2], p95[2], p99[2]))
    denoise_rel = max(abs(rel_delta(gradient[1], gradient[0])),
                      abs(rel_delta(spatial[1], spatial[0])),
                      abs(rel_delta(temporal[1], temporal[0])))
    colour_delta = max(ratio_delta(samples, key) for key in (
        "rg_all", "bg_all", "rg_mid", "bg_mid", "rg_high", "bg_high",
    ))
    local_rel = abs(rel_delta(local[1], local[0]))

    return {
        "label": label,
        "dir": str(report_dir),
        "mean_delta": mean_luma[2],
        "tone_score": tone_score,
        "tone_abs": tone_abs,
        "shoulder_abs": shoulder_abs,
        "colour_delta": colour_delta,
        "chroma_rel": abs(rel_delta(chroma[1], chroma[0])),
        "denoise_rel": denoise_rel,
        "local_rel": local_rel,
    }


def dominant_residual(row: Row) -> str:
    residuals = [
        (abs(row["mean_delta"]) / 5.0, "AE mean luma"),
        (row["tone_score"] / 6.0, "global tone"),
        (max(row["colour_delta"] / 0.04,
             row["chroma_rel"] / 0.08,
             row["denoise_rel"] / 0.10), "cfa/cnf/cm/cm2 shared gate"),
        (row["local_rel"] / 0.10, "LTM/CLAHE"),
    ]
    score, label = max(residuals, key=lambda item: item[0])

    return label if score >= 1.0 else "inside coarse thresholds"


def markdown(rows: list[Row]) -> str:
    best_tone = min(rows, key=lambda row: row["tone_score"])
    best_transfer = min(rows, key=lambda row: row["tone_abs"])
    lines = [
        "# ISP Forced Tone Sweep Summary",
        "",
        "| point | mean delta | p50/p95/p99 score | tone-transfer MAD | shoulder score | colour ratio max | chroma rel | denoise rel | local contrast rel | dominant residual |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    for row in sorted(rows, key=lambda item: item["tone_score"]):
        lines.append(
            f"| {row['label']} | {row['mean_delta']:+.2f} | {row['tone_score']:.2f} | "
            f"{row['tone_abs']:.2f} | {row['shoulder_abs']:.2f} | "
            f"{row['colour_delta']:.3f} | {100.0 * row['chroma_rel']:.1f}% | "
            f"{100.0 * row['denoise_rel']:.1f}% | {100.0 * row['local_rel']:.1f}% | "
            f"{dominant_residual(row)} |"
        )

    lines += [
        "",
        "## Reading",
        "",
        f"- Best p50/p95/p99 point: `{best_tone['label']}`.",
        f"- Best whole tone-transfer point: `{best_transfer['label']}`.",
        "- If those are the same point and mean delta stays small, land the gamma/DRC selector.",
        "- If all points retain a local-contrast residual, move LTM/CLAHE ahead of selector work.",
        "- If all points retain a luma-banded colour, chroma, gradient or noise residual, move the shared `cfa/cnf/cm/cm2` gate ahead of selector work.",
    ]

    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("reports", nargs="+", help="report directories from ab-image-diff.py")
    parser.add_argument("-o", "--out", help="write Markdown summary here")
    args = parser.parse_args()

    try:
        rows = [summarise(path) for path in args.reports]
    except (OSError, ValueError) as exc:
        raise SystemExit(str(exc)) from exc

    text = markdown(rows)
    if args.out:
        Path(args.out).write_text(text)

    print(text, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
