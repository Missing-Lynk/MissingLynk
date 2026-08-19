#!/usr/bin/env python3
"""Compare two DVR recordings and say how the image differs, stage by stage.

Input is the two legs written by glue/capture/ab-record.sh: the same scene, the same light, the
same goggle, once with a stock vendor air unit and once with ours. Both files went through the
same receive, decode and re-encode path, so a difference between them came from the air side.

What each measurement is diagnostic of, which is the reason the set is this set and not a
generic "video quality" report:

  exposure level          the AE operating point: sensor exposure and gain
  luma percentiles        black level (BLC) and highlight handling; a lifted p1 is a black-level
                          offset, a compressed p95..p99 is tone-curve or DRC shoulder
  tone transfer curve     the empirical mapping from our luma to the vendor's, recovered by
                          matching cumulative histograms. This is the single most diagnostic
                          output: gamma, DRC and BLC differences all land here as a curve shape
  channel ratios          static WB/CCM state or the gain-keyed cm/cm2 rows. R/G and B/G are
                          reported per luma band, because a cast that only appears in shadows is
                          a different defect from a global one
  chroma magnitude        saturation, so cm/cm2 gain against a desaturating denoise stage
  gradient energy         sharpening and the denoise stages (lnr, de3d, cnf); low means mushy.
                          Colour, chroma, gradient and noise residuals share one gate now:
                          cfa/cnf/cm/cm2 move on the same AE abscissa and should be validated
                          together before deeper denoise work
  local contrast          tile-to-tile contrast after global exposure is accounted for; LTM/CLAHE
  spatial noise floor     denoise strength, measured on the flattest tiles so scene detail does
                          not count as noise
  temporal noise          denoise strength again, from consecutive frames; separates a static
                          pattern from frame-to-frame grain
  clipped fractions       highlight and shadow clipping, which no amount of tone curve recovers
  timeline                AE dynamics: convergence speed, overshoot, hunting. Only visible over
                          a run, which is why the legs are 30 s and not a still

Two cautions the numbers cannot state for themselves. Both legs are re-encoded by the goggle, so
gradient energy and the noise floors carry a compression component; they are comparable between
the legs but they are not absolute. And the tone curve conflates the AE operating point with the
tone response, by construction: if one leg is simply exposed darker the curve shows that as well.
Read it together with the exposure level, not instead of it.

Usage:
  ab-image-diff.py VENDOR.mp4 OPEN.mp4 -o out/au-ab/report [--samples 12] [--rate 5]
                   [--vendor-start S] [--open-start S] [--dur S]

Needs ffmpeg and ffprobe on PATH. numpy and pillow are project dependencies; matplotlib is
optional and only adds the plots.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

import numpy as np

# ffprobe's stream facts, one sample position's metrics, and the merged
# per-leg summary the ranking reads.
Info = dict[str, Any]
Sample = dict[str, float]
Summary = dict[str, Any]
# (score, title, detail), ranked highest score first.
Ranked = tuple[float, str, str]

try:
    from PIL import Image
except ImportError:
    Image = None

# Rec.709 luma, which is what the pipeline tags and what the goggle displays.
LUMA_R, LUMA_G, LUMA_B = 0.2126, 0.7152, 0.0722


def probe(path: Path) -> Info:
    """Duration, geometry and frame rate of a file, as a dict."""
    out = subprocess.run(
        ["ffprobe", "-hide_banner", "-loglevel", "error", "-print_format", "json",
         "-show_format", "-show_streams", str(path)],
        capture_output=True, text=True, check=True,
    ).stdout
    info = json.loads(out)
    video = next(s for s in info["streams"] if s["codec_type"] == "video")
    num, _, den = video.get("avg_frame_rate", "0/1").partition("/")
    fps = float(num) / float(den) if float(den or 0) else 0.0
    return {
        "duration": float(info["format"].get("duration", 0.0)),
        "width": int(video["width"]),
        "height": int(video["height"]),
        "fps": fps,
        "codec": video.get("codec_name", "?"),
    }


def decode(path: Path, start: float, count: int, width: int, height: int,
           gray: bool = False) -> np.ndarray:
    """Decode `count` consecutive frames from `start` seconds, as a uint8 array.

    Returns (count, height, width) for gray or (count, height, width, 3) for rgb24. Seeking is
    done before the input so it is a keyframe seek plus decode, which is fast enough to sample a
    30 s file a dozen times and accurate enough for a scene that is not moving.
    """
    fmt = "gray" if gray else "rgb24"
    planes = 1 if gray else 3
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-ss", f"{start:.3f}", "-i", str(path),
        "-frames:v", str(count),
        "-vf", f"scale={width}:{height}",
        "-pix_fmt", fmt, "-f", "rawvideo", "-",
    ]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    frame_bytes = width * height * planes
    have = len(raw) // frame_bytes
    if have == 0:
        raise SystemExit(f"{path}: no frames decoded at {start:.3f}s")
    array = np.frombuffer(raw[: have * frame_bytes], dtype=np.uint8)
    shape = (have, height, width) if gray else (have, height, width, 3)
    return array.reshape(shape)


def luma(rgb: np.ndarray) -> np.ndarray:
    """Rec.709 luma of an rgb24 frame, float32."""
    return (LUMA_R * rgb[..., 0] + LUMA_G * rgb[..., 1] + LUMA_B * rgb[..., 2]).astype(np.float32)


def tile_std(plane: np.ndarray, tile: int = 16) -> np.ndarray:
    """Standard deviation of every whole `tile`-square tile, as a flat array."""
    height, width = plane.shape
    rows, cols = height // tile, width // tile
    if rows == 0 or cols == 0:
        return np.array([plane.std()])
    trimmed = plane[: rows * tile, : cols * tile]
    tiles = trimmed.reshape(rows, tile, cols, tile).transpose(0, 2, 1, 3).reshape(rows * cols, -1)
    return tiles.std(axis=1)


def gradient_energy(plane: np.ndarray) -> float:
    """Mean absolute 4-neighbour Laplacian, the sharpening-versus-denoise proxy.

    Normalised by the frame's own contrast, so a leg that is merely exposed brighter does not
    read as sharper. Two frames of the same scene at the same contrast differ here only by what
    the sharpen and denoise stages did.
    """
    lap = (4.0 * plane[1:-1, 1:-1]
           - plane[:-2, 1:-1] - plane[2:, 1:-1]
           - plane[1:-1, :-2] - plane[1:-1, 2:])
    contrast = plane.std()
    return float(np.abs(lap).mean() / contrast) if contrast > 1e-6 else 0.0


def local_contrast(plane: np.ndarray) -> float:
    """Median tile contrast normalised by the frame contrast, the LTM/CLAHE proxy."""
    contrast = plane.std()
    if contrast <= 1e-6:
        return 0.0
    return float(np.median(tile_std(plane)) / contrast)


def channel_ratios(rgb: np.ndarray, luma_plane: np.ndarray) -> Sample:
    """R/G and B/G per luma band (shadows, midtones, highlights) and overall.

    A cast confined to one band points at a different stage from a global one: a global ratio
    offset first checks the static WB/CCM state and then cm/cm2, while a shadow-only cast is
    black-level or the shading correction.
    """
    bands = {"shadow": (0, 64), "mid": (64, 160), "high": (160, 256), "all": (0, 256)}
    result = {}
    for name, (low, high) in bands.items():
        mask = (luma_plane >= low) & (luma_plane < high)
        if mask.sum() < 1000:
            result[name] = (float("nan"), float("nan"), int(mask.sum()))
            continue
        red = float(rgb[..., 0][mask].mean())
        green = float(rgb[..., 1][mask].mean())
        blue = float(rgb[..., 2][mask].mean())
        # Below a few counts of green the ratio is division by noise and reads as a huge cast
        # that is not there. Report it as missing rather than as a number.
        if green < 4.0:
            result[name] = (float("nan"), float("nan"), int(mask.sum()))
            continue
        result[name] = (red / green, blue / green, int(mask.sum()))
    return result


def chroma_magnitude(rgb: np.ndarray, luma_plane: np.ndarray) -> float:
    """Mean sqrt(Cb^2 + Cr^2): saturation, independent of hue."""
    blue_diff = (rgb[..., 2].astype(np.float32) - luma_plane) * 0.5389
    red_diff = (rgb[..., 0].astype(np.float32) - luma_plane) * 0.6350
    return float(np.sqrt(blue_diff ** 2 + red_diff ** 2).mean())


def sample_metrics(path: Path, info: Info, positions: list[float],
                   burst: int) -> tuple[list[Sample], np.ndarray,
                                        dict[float, np.ndarray]]:
    """Full-resolution metrics at each sample position, plus an accumulated luma histogram."""
    per_sample: list[Sample] = []
    histogram = np.zeros(256, dtype=np.int64)
    frames_for_stills: dict[float, np.ndarray] = {}

    for position in positions:
        frames = decode(path, position, burst, info["width"], info["height"])
        first = frames[0]
        luma_plane = luma(first)
        histogram += np.bincount(luma_plane.astype(np.uint8).ravel(), minlength=256)

        stds = tile_std(luma_plane)
        # The flattest decile: tiles with the least scene detail, where what is left is the
        # denoise stage's residual rather than the picture.
        spatial_noise = float(np.percentile(stds, 10))

        if frames.shape[0] >= 2:
            temporal = luma(frames[1]) - luma_plane
            temporal_noise = float(temporal.std())
        else:
            temporal_noise = float("nan")

        ratios = channel_ratios(first, luma_plane)
        per_sample.append({
            "t": position,
            "mean": float(luma_plane.mean()),
            "p1": float(np.percentile(luma_plane, 1)),
            "p5": float(np.percentile(luma_plane, 5)),
            "p50": float(np.percentile(luma_plane, 50)),
            "p95": float(np.percentile(luma_plane, 95)),
            "p99": float(np.percentile(luma_plane, 99)),
            "clip_high": float((luma_plane >= 250).mean()),
            "clip_low": float((luma_plane <= 5).mean()),
            "gradient": gradient_energy(luma_plane),
            "local_contrast": local_contrast(luma_plane),
            "spatial_noise": spatial_noise,
            "temporal_noise": temporal_noise,
            "chroma": chroma_magnitude(first, luma_plane),
            "rg_all": ratios["all"][0],
            "bg_all": ratios["all"][1],
            "rg_mid": ratios["mid"][0],
            "bg_mid": ratios["mid"][1],
            "rg_shadow": ratios["shadow"][0],
            "bg_shadow": ratios["shadow"][1],
            "rg_high": ratios["high"][0],
            "bg_high": ratios["high"][1],
        })
        frames_for_stills[position] = first

    return per_sample, histogram, frames_for_stills


def timeline(path: Path, info: Info, start: float, duration: float,
             rate: float) -> list[Sample]:
    """Luma mean and percentiles at `rate` samples per second, for the AE dynamics."""
    width, height = 320, 180
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-ss", f"{start:.3f}", "-t", f"{duration:.3f}", "-i", str(path),
        "-vf", f"fps={rate},scale={width}:{height}",
        "-pix_fmt", "gray", "-f", "rawvideo", "-",
    ]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    frame_bytes = width * height
    count = len(raw) // frame_bytes
    if count == 0:
        return []
    frames = np.frombuffer(raw[: count * frame_bytes], dtype=np.uint8).reshape(count, height, width)
    flat = frames.reshape(count, -1).astype(np.float32)
    means = flat.mean(axis=1)
    p5 = np.percentile(flat, 5, axis=1)
    p95 = np.percentile(flat, 95, axis=1)
    return [{"t": start + i / rate, "mean": float(means[i]), "p5": float(p5[i]), "p95": float(p95[i])}
            for i in range(count)]


def tone_curve(hist_open: np.ndarray, hist_vendor: np.ndarray) -> np.ndarray:
    """The luma level in the vendor leg that carries the same population share as each level in ours.

    Histogram matching, so it needs no pixel correspondence between the two files, only that the
    two legs framed the same scene. The result reads directly: at input level x, the vendor's
    picture sits at level y.
    """
    cdf_open = np.cumsum(hist_open).astype(np.float64)
    cdf_vendor = np.cumsum(hist_vendor).astype(np.float64)
    if cdf_open[-1] == 0 or cdf_vendor[-1] == 0:
        return np.arange(256, dtype=np.float64)
    cdf_open /= cdf_open[-1]
    cdf_vendor /= cdf_vendor[-1]
    return np.interp(cdf_open, cdf_vendor, np.arange(256, dtype=np.float64))


def classify(delta: float, drift: float) -> str:
    """How an effect compares with the drift between two recordings of one configuration.

    3x is not a statistical test, it is a floor blunt enough to survive a scene that moves. The
    withdrawn tone reading had effects of 0.7 against a drift of 5.1 and read as a result.
    """
    if drift <= 0:
        return "real" if delta else "buried"

    ratio = abs(delta) / drift

    if ratio >= 3.0:
        return "real"

    return "marginal" if ratio >= 1.0 else "buried"


def mean_of(samples: list[Sample], key: str) -> float:
    values = [s[key] for s in samples if not np.isnan(s[key])]
    return float(np.mean(values)) if values else float("nan")


def rel_delta(open_value: float, vendor_value: float) -> float:
    """Relative delta with a floor so near-zero metrics do not explode."""
    denom = max(abs(vendor_value), 1.0)
    return (open_value - vendor_value) / denom


def add_if_ranked(items: list[Ranked], score: float, title: str,
                  detail: str) -> None:
    if score > 0:
        items.append((score, title, detail))


def ratio_delta(summary: Summary, key: str) -> float:
    vendor_value, open_value = summary[key]
    if np.isnan(vendor_value) or np.isnan(open_value):
        return 0.0
    return abs(open_value - vendor_value)


def suggested_work(summary: Summary, vendor_line: list[Sample],
                   open_line: list[Sample]) -> list[Ranked]:
    """Turn the report metrics into a concrete next-work order."""
    items = []
    mean_delta = summary["mean"][1] - summary["mean"][0]
    p50_delta = summary["p50"][1] - summary["p50"][0]
    p95_delta = summary["p95"][1] - summary["p95"][0]
    p99_delta = summary["p99"][1] - summary["p99"][0]
    clip_low_delta = summary["clip_low"][1] - summary["clip_low"][0]
    clip_high_delta = summary["clip_high"][1] - summary["clip_high"][0]
    gradient_rel = abs(rel_delta(summary["gradient"][1], summary["gradient"][0]))
    local_contrast_rel = abs(rel_delta(summary["local_contrast"][1],
                                       summary["local_contrast"][0]))
    spatial_rel = abs(rel_delta(summary["spatial_noise"][1], summary["spatial_noise"][0]))
    temporal_rel = abs(rel_delta(summary["temporal_noise"][1], summary["temporal_noise"][0]))
    chroma_rel = abs(rel_delta(summary["chroma"][1], summary["chroma"][0]))
    colour_ratio_delta = max(
        ratio_delta(summary, key)
        for key in ("rg_all", "bg_all", "rg_mid", "bg_mid", "rg_high", "bg_high")
    )

    if vendor_line and open_line:
        vendor_means = [s["mean"] for s in vendor_line]
        open_means = [s["mean"] for s in open_line]
        timeline_delta = abs(float(np.std(open_means) - np.std(vendor_means)))
        range_delta = abs(float(np.ptp(open_means) - np.ptp(vendor_means)))
    else:
        timeline_delta = 0.0
        range_delta = 0.0

    add_if_ranked(
        items,
        abs(mean_delta) if abs(mean_delta) >= 5.0 or timeline_delta >= 2.0 or range_delta >= 5.0 else 0.0,
        "AE operating point or dynamics",
        "Mean luma or the timeline differs enough to check exposure/gain, target, convergence and "
        "anti-flicker before blaming downstream tone.",
    )
    add_if_ranked(
        items,
        max(abs(p50_delta), abs(p95_delta), abs(p99_delta))
        if max(abs(p50_delta), abs(p95_delta), abs(p99_delta)) >= 6.0 else 0.0,
        "Tone-table selector",
        "Midtone or shoulder percentiles differ. The open stack generates gamma/DRC pages from "
        "the blob, but their selector is still pinned.",
    )
    gain_keyed_score = max(gradient_rel, spatial_rel, temporal_rel,
                           chroma_rel, colour_ratio_delta) * 100.0
    add_if_ranked(
        items,
        gain_keyed_score
        if max(gradient_rel, spatial_rel, temporal_rel) >= 0.10
        or chroma_rel >= 0.08 or colour_ratio_delta >= 0.04 else 0.0,
        "cfa/cnf/cm/cm2 shared gate",
        "Gradient, noise, chroma magnitude or luma-band channel ratios differ. Gate-boot the "
        "implemented gain-keyed demosaic, chroma and colour rows together; use a raw_3dnr "
        "capture only if the noise delta remains after that.",
    )
    add_if_ranked(
        items,
        max(abs(clip_low_delta), abs(clip_high_delta)) * 100.0
        if max(abs(clip_low_delta), abs(clip_high_delta)) >= 0.01 else 0.0,
        "Clipping and black/shadow handling",
        "The clipped share differs by at least one percentage point. Read this with p1/p5 and "
        "the tone curve before deciding whether the fix is BLC-like shadow state or DRC.",
    )
    add_if_ranked(
        items,
        local_contrast_rel * 100.0 if local_contrast_rel >= 0.10 else 0.0,
        "LTM/CLAHE local contrast",
        "Local tile contrast differs by at least ten percent. Take this after AE, tone, denoise "
        "and colour rows unless the stills show a clearly local contrast defect.",
    )

    if not items:
        return [(
            0.0,
            "No dominant image delta in this run",
            "The sampled metrics are inside the report's coarse thresholds. Inspect stills and "
            "repeat with a harder scene before spending an ISP boot.",
        )]

    items.sort(key=lambda item: item[0], reverse=True)
    return items


def write_stills(out_dir: Path, vendor_frames: dict[float, np.ndarray],
                 open_frames: dict[float, np.ndarray]) -> list[str]:
    """One side-by-side PNG per matched sample position, vendor left, ours right."""
    if Image is None:
        return []
    stills_dir = out_dir / "stills"
    stills_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for index, (position, vendor_frame) in enumerate(sorted(vendor_frames.items())):
        open_position = sorted(open_frames)[min(index, len(open_frames) - 1)]
        open_frame = open_frames[open_position]
        height = min(vendor_frame.shape[0], open_frame.shape[0])
        pair = np.concatenate([vendor_frame[:height], open_frame[:height]], axis=1)
        path = stills_dir / f"pair-{index:02d}-t{position:05.1f}.png"
        Image.fromarray(pair).save(path)
        written.append(path)
    return written


def write_plots(out_dir: Path, vendor_line: list[Sample],
                open_line: list[Sample], curve: np.ndarray,
                vendor_hist: np.ndarray, open_hist: np.ndarray,
                vendor_label: str, open_label: str) -> list[str]:
    os.environ.setdefault("MPLCONFIGDIR", "/tmp/ml-ab-matplotlib-cache")
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        return []

    written = []

    figure, axis = plt.subplots(figsize=(10, 4))
    for line, label, colour in ((vendor_line, vendor_label, "#1f77b4"),
                                (open_line, open_label, "#d62728")):
        if not line:
            continue
        axis.plot([s["t"] for s in line], [s["mean"] for s in line], color=colour, label=f"{label} mean")
        axis.fill_between([s["t"] for s in line], [s["p5"] for s in line], [s["p95"] for s in line],
                          color=colour, alpha=0.15)
    axis.set_xlabel("seconds")
    axis.set_ylabel("luma (0-255)")
    axis.set_title("AE over the run: mean luma, p5-p95 band")
    axis.legend()
    axis.grid(alpha=0.3)
    path = out_dir / "timeline.png"
    figure.tight_layout()
    figure.savefig(path, dpi=110)
    plt.close(figure)
    written.append(path)

    figure, (left, right) = plt.subplots(1, 2, figsize=(11, 4))
    left.plot(np.arange(256), curve, color="#d62728")
    left.plot([0, 255], [0, 255], "--", color="#888888", linewidth=1)
    left.set_xlabel("our luma")
    left.set_ylabel("vendor luma at the same population share")
    left.set_title("tone transfer, ours to vendor")
    left.grid(alpha=0.3)
    right.plot(np.arange(256), vendor_hist / max(vendor_hist.sum(), 1), label=vendor_label,
               color="#1f77b4")
    right.plot(np.arange(256), open_hist / max(open_hist.sum(), 1), label=open_label,
               color="#d62728")
    right.set_xlabel("luma")
    right.set_ylabel("share")
    right.set_title("luma histogram")
    right.legend()
    right.grid(alpha=0.3)
    path = out_dir / "tone.png"
    figure.tight_layout()
    figure.savefig(path, dpi=110)
    plt.close(figure)
    written.append(path)
    return written


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("vendor", help="the vendor leg's recording")
    parser.add_argument("open", help="our leg's recording")
    parser.add_argument("-o", "--out", default="out/au-ab/report", help="output directory")
    parser.add_argument("--samples", type=int, default=12, help="sample positions per file")
    parser.add_argument("--burst", type=int, default=2,
                        help="consecutive frames per position; 2 is the minimum for temporal noise")
    parser.add_argument("--rate", type=float, default=5.0, help="timeline samples per second")
    parser.add_argument("--vendor-start", type=float, default=1.0,
                        help="seconds to skip at the head of the vendor leg")
    parser.add_argument("--open-start", type=float, default=1.0,
                        help="seconds to skip at the head of our leg")
    parser.add_argument("--dur", type=float, default=0.0,
                        help="seconds to analyse; 0 uses the shorter of the two")
    parser.add_argument("--vendor-label", default="vendor",
                        help="label for the vendor leg in the report and plots")
    parser.add_argument("--open-label", default="open",
                        help="label for our leg in the report and plots")
    parser.add_argument("--null", default=None,
                        help="a THIRD recording of the same configuration as the open leg. Every "
                             "difference is then reported against the drift between those two, "
                             "which is the only way to tell an effect from the scene moving")
    parser.add_argument("--null-start", type=float, default=1.0,
                        help="seconds to skip at the head of the null-control leg")
    args = parser.parse_args()

    if args.samples <= 0:
        raise SystemExit("--samples must be positive")
    if args.burst <= 0:
        raise SystemExit("--burst must be positive")
    if args.rate <= 0:
        raise SystemExit("--rate must be positive")
    if args.vendor_start < 0 or args.open_start < 0:
        raise SystemExit("--vendor-start and --open-start must be non-negative")
    for option, label in (("--vendor-label", args.vendor_label), ("--open-label", args.open_label)):
        if not label or any(ch in label for ch in "\n\r|:"):
            raise SystemExit(f"{option} must be non-empty and must not contain newlines, ':' or '|'")
    if args.vendor_label == args.open_label:
        raise SystemExit("--vendor-label and --open-label must differ")

    for tool in ("ffmpeg", "ffprobe"):
        if shutil.which(tool) is None:
            raise SystemExit(f"{tool} is not on PATH")

    vendor_path, open_path = Path(args.vendor), Path(args.open)
    for path in (vendor_path, open_path):
        if not path.exists():
            raise SystemExit(f"no such file: {path}")

    vendor_info, open_info = probe(vendor_path), probe(open_path)
    duration = args.dur or min(vendor_info["duration"] - args.vendor_start,
                               open_info["duration"] - args.open_start)
    if duration <= 0:
        raise SystemExit("--dur must be positive when supplied")
    if duration <= 1.0:
        raise SystemExit("less than a second of overlap; check the two durations and the offsets")

    # Sample positions are the same fractions of each leg's analysed window, so the two legs are
    # compared at matching points of the scene even when the recordings differ in length.
    fractions = [(index + 0.5) / args.samples for index in range(args.samples)]
    vendor_positions = [args.vendor_start + f * duration for f in fractions]
    open_positions = [args.open_start + f * duration for f in fractions]

    print(f"{args.vendor_label}: {vendor_path.name} {vendor_info['width']}x{vendor_info['height']} "
          f"{vendor_info['fps']:.2f} fps {vendor_info['duration']:.1f}s {vendor_info['codec']}")
    print(f"{args.open_label}:   {open_path.name} {open_info['width']}x{open_info['height']} "
          f"{open_info['fps']:.2f} fps {open_info['duration']:.1f}s {open_info['codec']}")
    if (vendor_info["width"], vendor_info["height"]) != (open_info["width"], open_info["height"]):
        print("  WARNING: the two legs are different geometries; every spatial statistic "
              "(gradient energy, noise) is comparing different pixel densities")
    print(f"analysing {duration:.1f}s, {args.samples} positions, timeline at {args.rate}/s")

    vendor_samples, vendor_hist, vendor_frames = sample_metrics(
        vendor_path, vendor_info, vendor_positions, args.burst)
    open_samples, open_hist, open_frames = sample_metrics(
        open_path, open_info, open_positions, args.burst)

    # The null control is a repeat of the open leg's own configuration, so the difference between
    # them is pure scene and AE drift: the floor any claimed effect has to clear.
    null_samples = None
    if args.null:
        null_path = Path(args.null)

        if not null_path.exists():
            raise SystemExit(f"no such file: {null_path}")

        null_info = probe(null_path)
        null_positions = [args.null_start + f * duration for f in fractions]
        print(f"null:   {null_path.name} {null_info['width']}x{null_info['height']} "
              f"{null_info['fps']:.2f} fps {null_info['duration']:.1f}s {null_info['codec']}")
        null_samples, _null_hist, _null_frames = sample_metrics(
            null_path, null_info, null_positions, args.burst)

    vendor_line = timeline(vendor_path, vendor_info, args.vendor_start, duration, args.rate)
    open_line = timeline(open_path, open_info, args.open_start, duration, args.rate)
    curve = tone_curve(open_hist, vendor_hist)

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    rows = [
        ("exposure, mean luma", "mean", "AE operating point"),
        ("black, p1", "p1", "black level (BLC) and shadow tone"),
        ("shadow, p5", "p5", "shadow tone"),
        ("median, p50", "p50", "midtone placement, gamma"),
        ("highlight, p95", "p95", "shoulder"),
        ("highlight, p99", "p99", "shoulder and clipping"),
        ("clipped high, share", "clip_high", "blown highlights"),
        ("clipped low, share", "clip_low", "crushed blacks"),
        ("gradient energy", "gradient", "shared cfa/cnf/cm/cm2 gate, then denoise"),
        ("local contrast", "local_contrast", "LTM/CLAHE after global tone"),
        ("spatial noise floor", "spatial_noise", "shared cfa/cnf/cm/cm2 gate, then denoise"),
        ("temporal noise", "temporal_noise", "shared cfa/cnf/cm/cm2 gate, then denoise"),
        ("chroma magnitude", "chroma", "saturation, shared cfa/cnf/cm/cm2 gate"),
        ("R/G, all", "rg_all", "static WB/CCM or cm/cm2"),
        ("B/G, all", "bg_all", "static WB/CCM or cm/cm2"),
        ("R/G, midtones", "rg_mid", "midtone colour: static CCM or cm/cm2"),
        ("B/G, midtones", "bg_mid", "midtone colour: static CCM or cm/cm2"),
        ("R/G, shadows", "rg_shadow", "shadow cast: black level or shading"),
        ("B/G, shadows", "bg_shadow", "shadow cast: black level or shading"),
        ("R/G, highlights", "rg_high", "highlight cast"),
        ("B/G, highlights", "bg_high", "highlight cast"),
    ]

    lines = ["# Vendor versus open: image comparison", "",
             f"- {args.vendor_label}: `{vendor_path}` {vendor_info['width']}x{vendor_info['height']} "
             f"{vendor_info['fps']:.2f} fps {vendor_info['duration']:.1f} s",
             f"- {args.open_label}: `{open_path}` {open_info['width']}x{open_info['height']} "
             f"{open_info['fps']:.2f} fps {open_info['duration']:.1f} s",
             f"- analysed {duration:.1f} s at {args.samples} positions, "
             f"{args.burst} consecutive frames each",
             "",
             "Both legs were recorded through the same goggle, so the receive, decode and "
             "re-encode path is common to both and the differences below are air-side. The "
             "spatial statistics still carry a compression component and are comparable between "
             "the legs rather than absolute.",
             "",
             (f"| measurement | {args.vendor_label} | {args.open_label} | delta | drift | verdict "
              f"| what it points at |" if null_samples else
              f"| measurement | {args.vendor_label} | {args.open_label} | delta | what it points at |"),
             ("|---|---:|---:|---:|---:|---|---|" if null_samples else "|---|---:|---:|---:|---|")]

    summary = {}
    survived = 0
    for label, key, meaning in rows:
        vendor_value = mean_of(vendor_samples, key)
        open_value = mean_of(open_samples, key)
        summary[key] = (vendor_value, open_value)
        delta = open_value - vendor_value

        if null_samples is None:
            lines.append(f"| {label} | {vendor_value:.3f} | {open_value:.3f} | {delta:+.3f} "
                         f"| {meaning} |")

            continue

        drift = abs(mean_of(null_samples, key) - open_value)
        verdict = classify(delta, drift)
        survived += verdict == "real"
        lines.append(f"| {label} | {vendor_value:.3f} | {open_value:.3f} | {delta:+.3f} "
                     f"| {drift:.3f} | {verdict} | {meaning} |")

    if null_samples is not None:
        lines += ["",
                  f"**{survived} of {len(rows)} measurements clear their own drift floor by 3x.** "
                  "A row marked `buried` has an effect smaller than the difference between two "
                  "recordings of the SAME configuration, so it says nothing whatever its sign. "
                  "A `marginal` row is between 1x and 3x the floor and is not evidence on its own. "
                  "This column exists because a tone reading was once published from this report "
                  "and had to be withdrawn: every headline number in it was smaller than the "
                  "drift, and nothing in the report said so.",
                  "",
                  "The null leg must come from the SAME session as the other two, on the same "
                  "scene and light, recorded adjacent to them. A null from another session "
                  "measures the difference between sessions, which is large, and buries "
                  "everything. A null that is too similar is worse: a drift near zero makes the "
                  "ratio explode and marks noise as `real`, so treat any row whose drift is "
                  "orders below the others as unmeasured rather than significant."]

    lines += ["", "## Tone transfer, ours to the vendor's", "",
              "The vendor luma level carrying the same population share as each of ours. A "
              "straight diagonal means the two tone responses agree; a curve above the diagonal "
              "means the vendor is brighter at that level, below means darker. Exposure "
              "difference and tone-curve difference both appear here, so read it with the "
              "exposure row above.", "",
              "| our luma | 16 | 32 | 64 | 96 | 128 | 160 | 192 | 224 | 240 |",
              "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
              "| vendor luma | " + " | ".join(f"{curve[level]:.1f}" for level in
                                              (16, 32, 64, 96, 128, 160, 192, 224, 240)) + " |"]

    if vendor_line and open_line:
        vendor_means = [s["mean"] for s in vendor_line]
        open_means = [s["mean"] for s in open_line]
        lines += ["", "## AE over the run", "",
                  "Standard deviation of the mean luma across the run is the hunting measure: a "
                  "loop that is settled holds it near zero on a static scene, and a loop that "
                  "pumps does not.", "",
                  f"| | {args.vendor_label} | {args.open_label} |", "|---|---:|---:|",
                  f"| mean luma | {np.mean(vendor_means):.2f} | {np.mean(open_means):.2f} |",
                  f"| std of mean luma | {np.std(vendor_means):.3f} | {np.std(open_means):.3f} |",
                  f"| min to max | {np.ptp(vendor_means):.2f} | {np.ptp(open_means):.2f} |"]

    lines += ["", "## Suggested next work", "",
              "Ranked from this report only. Treat this as the next question to answer, not as "
              "proof that the named stage is wrong.", "",
              "| rank | score | next work | why |",
              "|---:|---:|---|---|"]
    for rank, (score, title, detail) in enumerate(suggested_work(summary, vendor_line, open_line), 1):
        lines.append(f"| {rank} | {score:.1f} | {title} | {detail} |")

    plots = write_plots(out_dir, vendor_line, open_line, curve, vendor_hist, open_hist,
                        args.vendor_label, args.open_label)
    stills = write_stills(out_dir, vendor_frames, open_frames)

    if plots:
        lines += ["", "## Plots", ""] + [f"- `{p.name}`" for p in plots]
    else:
        lines += ["", "matplotlib is not installed, so no plots were written.", ""]
    if stills:
        lines += ["", "## Stills", "",
                  f"{len(stills)} side-by-side pairs in `stills/`, vendor left, ours right."]

    csv_path = out_dir / "samples.csv"
    keys = list(vendor_samples[0].keys())
    with csv_path.open("w") as handle:
        handle.write("leg," + ",".join(keys) + "\n")
        for leg, samples in (("vendor", vendor_samples), ("open", open_samples)):
            for sample in samples:
                handle.write(leg + "," + ",".join(f"{sample[k]:.6g}" for k in keys) + "\n")

    timeline_path = out_dir / "timeline.csv"
    with timeline_path.open("w") as handle:
        handle.write("leg,t,mean,p5,p95\n")
        for leg, line in (("vendor", vendor_line), ("open", open_line)):
            for sample in line:
                handle.write(f"{leg},{sample['t']:.3f},{sample['mean']:.4f},"
                             f"{sample['p5']:.4f},{sample['p95']:.4f}\n")

    report_path = out_dir / "report.md"
    report_path.write_text("\n".join(lines) + "\n")

    print()
    print("\n".join(lines))
    print()
    print(f"wrote {report_path}")
    print(f"      {csv_path}")
    print(f"      {timeline_path}")
    for path in plots + stills[:3]:
        print(f"      {path}")
    if len(stills) > 3:
        print(f"      ... and {len(stills) - 3} more stills")
    return 0


if __name__ == "__main__":
    sys.exit(main())
