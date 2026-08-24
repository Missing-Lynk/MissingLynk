#!/usr/bin/env python3
"""Measure how far a DVR recording's two RF tiles drift apart, from the recording alone.

The downlink carries the picture as two vertically stacked HEVC tiles, encoded and decoded
independently, that overlap by SEAM_ROWS luma rows. Both tiles therefore hold the SAME source
rows in the overlap band, and ml-pipeline cross-fades between them. When the two reconstructions
disagree, the cross-fade turns that disagreement into a linear luma ramp across the band, which
is what shows on screen as a soft horizontal wash through the middle of the picture.

This measures the disagreement from the finished MP4: per sampled frame, fit the luma row profile
on each side of the band, extrapolate both fits to the band centre, and take the gap. A smooth
scene gradient across the seam cancels; only a discontinuity survives. Control probes at other
rows give the noise floor the seam value is judged against.

A second pass, --tiles, answers which tile broke. Decode garbage from a missing reference shows
as energy concentrated on the codec's 32-pixel transform grid, so measuring that ratio per tile
separates "the upper tile lost its reference" from "the picture is just detailed".

Usage:
    seam-divergence.py Video136.mp4 [--fps 1] [--seam 544] [--threshold 1.5]
    seam-divergence.py Video136.mp4 --tiles --from 176 --length 20 --fps 10
"""

from __future__ import annotations

import argparse
import statistics
import subprocess
import sys
from dataclasses import dataclass

import numpy as np

FRAME_HEIGHT: int = 1080
SEAM_CENTRE: int = 544          # midpoint of the 32-row band at TILE1_Y 528
FIT_INNER: int = 16             # skip this many rows either side: the band itself
FIT_OUTER: int = 48             # and fit the trend over the rows from INNER out to here
CONTROL_STEP: int = 40
CONTROL_EXCLUDE: int = 120      # keep control probes this far from the seam
FRAME_WIDTH: int = 1920
TRANSFORM_GRID: int = 32        # HEVC CTU/transform boundary the blocking lands on
TILE0_LAST: int = 528           # first row of the overlap band, so the last tile-0-only row
TILE1_FIRST: int = 560          # first row past the band, so the first tile-1-only row


@dataclass
class Sample:
    """One sampled frame's seam measurement."""

    index: int
    seconds: float
    seam_gap: float
    control_median: float
    control_max: float

    @property
    def ratio(self) -> float:
        """Seam gap as a multiple of the largest control gap in the same frame."""
        return abs(self.seam_gap) / max(self.control_max, 1e-9)


def read_row_profiles(path: str, fps: float) -> list[bytes]:
    """Return one FRAME_HEIGHT-byte row-mean luma profile per sampled frame."""
    command = [
        "ffmpeg", "-v", "error", "-i", path,
        "-vf", f"fps={fps},scale=1:{FRAME_HEIGHT}:flags=area,format=gray",
        "-f", "rawvideo", "-pix_fmt", "gray", "-",
    ]
    result = subprocess.run(command, capture_output=True, check=True)
    raw: bytes = result.stdout
    return [raw[i:i + FRAME_HEIGHT] for i in range(0, len(raw) - FRAME_HEIGHT + 1, FRAME_HEIGHT)]


def extrapolate(profile: bytes, low: int, high: int, target: int) -> float:
    """Least-squares fit over rows [low, high) evaluated at row `target`."""
    count: int = high - low
    xs: list[int] = list(range(low, high))
    ys: list[int] = [profile[x] for x in xs]
    mean_x: float = sum(xs) / count
    mean_y: float = sum(ys) / count
    denominator: float = sum((x - mean_x) ** 2 for x in xs)
    slope: float = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys, strict=True)) / denominator
    return mean_y + slope * (target - mean_x)


def discontinuity_at(profile: bytes, row: int) -> float:
    """Luma step at `row` once the local trend on both sides is removed."""
    above: float = extrapolate(profile, row - FIT_OUTER, row - FIT_INNER, row)
    below: float = extrapolate(profile, row + FIT_INNER, row + FIT_OUTER, row)
    return below - above


def measure(profiles: list[bytes], seam: int, fps: float) -> list[Sample]:
    """Seam discontinuity and its per-frame control distribution."""
    controls: list[int] = [
        row for row in range(200, FRAME_HEIGHT - 200, CONTROL_STEP)
        if abs(row - seam) > CONTROL_EXCLUDE
    ]
    samples: list[Sample] = []
    for index, profile in enumerate(profiles):
        gaps: list[float] = [abs(discontinuity_at(profile, row)) for row in controls]
        samples.append(Sample(
            index=index,
            seconds=index / fps,
            seam_gap=discontinuity_at(profile, seam),
            control_median=statistics.median(gaps),
            control_max=max(gaps),
        ))
    return samples


def episodes(samples: list[Sample], threshold: float,
             min_gap: float) -> list[tuple[float, float, float]]:
    """Contiguous runs over both thresholds, as (start_s, end_s, peak_gap).

    The ratio test alone fires on a frame whose control probes all landed on flat picture,
    where a few levels of ordinary coding noise at the seam divides into a large number.
    `min_gap` is the absolute floor that keeps such a frame out.
    """
    runs: list[tuple[float, float, float]] = []
    start: float | None = None
    previous: float = 0.0
    peak: float = 0.0
    for sample in samples:
        if sample.ratio > threshold and abs(sample.seam_gap) >= min_gap:
            if start is None:
                start = sample.seconds
                peak = sample.seam_gap
            elif abs(sample.seam_gap) > abs(peak):
                peak = sample.seam_gap
            previous = sample.seconds
        elif start is not None:
            runs.append((start, previous, peak))
            start = None
    if start is not None:
        runs.append((start, previous, peak))
    return runs


def blockiness(tile: np.ndarray) -> float:
    """Column-edge energy on the transform grid over the energy off it.

    Around 1.0 on clean picture whatever its detail, because texture puts as much energy on the
    grid columns as anywhere else. A tile decoding against a reference it never received pushes
    it well above 1.
    """
    gradient = np.abs(np.diff(tile.astype(np.int16), axis=1)).mean(axis=0)
    on_grid: float = gradient[TRANSFORM_GRID - 1::TRANSFORM_GRID].mean()
    off_mask = np.ones(gradient.size, dtype=bool)
    off_mask[TRANSFORM_GRID - 1::TRANSFORM_GRID] = False
    off_grid: float = gradient[off_mask].mean()
    return float(on_grid / max(off_grid, 1e-9))


def scan_tiles(path: str, fps: float, start: float, length: float) -> None:
    """Print per-tile blockiness over a window, so a corrupt tile names itself."""
    command = [
        "ffmpeg", "-v", "error", "-ss", str(start), "-t", str(length), "-i", path,
        "-vf", f"fps={fps},format=gray", "-f", "rawvideo", "-pix_fmt", "gray", "-",
    ]
    raw: bytes = subprocess.run(command, capture_output=True, check=True).stdout
    frame_bytes: int = FRAME_WIDTH * FRAME_HEIGHT
    count: int = len(raw) // frame_bytes

    print(f"{count} frames at {fps} fps from {start} s")
    print("     t    tile0  tile1")
    for index in range(count):
        frame = np.frombuffer(raw[index * frame_bytes:(index + 1) * frame_bytes],
                              dtype=np.uint8).reshape(FRAME_HEIGHT, FRAME_WIDTH)
        upper: float = blockiness(frame[0:TILE0_LAST])
        lower: float = blockiness(frame[TILE1_FIRST:FRAME_HEIGHT])
        seconds: float = start + index / fps
        bar = "#" * int(max(0.0, (upper - 1.0) * 20))
        bar_lower = "#" * int(max(0.0, (lower - 1.0) * 20))
        print(f"{seconds:7.1f}   {upper:5.2f} {bar:<24} {lower:5.2f} {bar_lower}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("video", help="DVR .mp4 to measure")
    parser.add_argument("--fps", type=float, default=1.0, help="frames sampled per second")
    parser.add_argument("--seam", type=int, default=SEAM_CENTRE, help="band centre row")
    parser.add_argument("--threshold", type=float, default=1.5,
                        help="seam gap over control max that counts as divergence")
    parser.add_argument("--min-gap", type=float, default=20.0,
                        help="luma levels the seam gap must reach to count")
    parser.add_argument("--all", action="store_true", help="print every sample, not just episodes")
    parser.add_argument("--tiles", action="store_true",
                        help="per-tile blockiness scan instead: which tile lost its reference")
    parser.add_argument("--from", dest="start", type=float, default=0.0,
                        help="--tiles window start, seconds")
    parser.add_argument("--length", type=float, default=20.0,
                        help="--tiles window length, seconds")
    args = parser.parse_args()

    if args.tiles:
        scan_tiles(args.video, args.fps, args.start, args.length)
        return 0

    profiles: list[bytes] = read_row_profiles(args.video, args.fps)
    if not profiles:
        print("no frames decoded", file=sys.stderr)
        return 1

    samples: list[Sample] = measure(profiles, args.seam, args.fps)

    if args.all:
        print("    t   seam_gap  ctrl_median  ctrl_max  ratio")
        for sample in samples:
            is_divergent = sample.ratio > args.threshold and abs(sample.seam_gap) >= args.min_gap
            mark = " <<<" if is_divergent else ""
            print(f"{sample.seconds:7.1f}  {sample.seam_gap:+8.1f}    {sample.control_median:8.1f}"
                  f"  {sample.control_max:8.1f}  {sample.ratio:5.2f}{mark}")
        print()

    runs = episodes(samples, args.threshold, args.min_gap)
    inside: set[int] = {s.index for s in samples
                        for start, end, _ in runs if start <= s.seconds <= end}
    baseline: list[float] = [abs(s.seam_gap) for s in samples if s.index not in inside]
    print(f"{len(samples)} samples at {args.fps} fps, seam row {args.seam}")
    if baseline:
        print(f"baseline |seam gap|: mean {statistics.mean(baseline):.1f}, "
              f"max {max(baseline):.1f} luma levels")

    if not runs:
        print("no divergence episodes")
        return 0

    print(f"\n{len(runs)} divergence episode(s):")
    for start, end, peak in runs:
        direction = "lower tile brighter" if peak > 0 else "upper tile brighter"
        print(f"  {start:7.1f} s .. {end:7.1f} s  ({end - start + 1 / args.fps:5.1f} s)  "
              f"peak {peak:+6.1f} levels, {direction}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
