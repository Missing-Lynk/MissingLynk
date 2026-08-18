#!/usr/bin/env python3
"""Measure mains banding in a recording, so an anti-flicker leg is judged by a number.

Light driven from the mains ripples at twice the mains frequency. A rolling shutter exposes each
row at a different phase of that ripple, so the frame carries a horizontal luminance wave. The
wave sits at one point in two-dimensional frequency space, and both coordinates are predictable:

  spatial   over the sensor's active rows the elapsed readout time is `active_lines * line_time`,
            so the wave completes

                cycles = active_lines * line_time * 2 * mains

            over the image height, whatever the recording is scaled to. At 1080 active lines and
            14.815 us that is 1.600 cycles under 50 Hz mains and 1.920 under 60 Hz.

  temporal  successive frames sample the ripple at a different phase, advancing by
            `2 * mains / frame_rate` cycles per frame, of which only the fraction is observable:
            0.667 at 50 Hz and 60 fps. The bands drift, and the scene's own structure does not.

The measurement is a lock-in on that cell. Each frame is reduced to its row-mean profile, the
clip's average profile is subtracted (removing every time-invariant vertical feature exactly), the
residual is projected onto the predicted spatial frequency to give one complex amplitude per
frame, and that series is projected onto the predicted drift. A 30 s clip integrates about 1800
frames coherently, so a band far too shallow to see in any single frame comes out well above the
background.

Filtering on BOTH axes is what makes this work, and doing only the spatial half does not. A scene
carries plenty of energy at 1.600 cycles per height, and on real captures it swamped a band that
was plainly visible to the eye: the uncorrected leg measured a 0.610% band at 337x the background
while the spatial-only amplitude at the same frequency read 2.4%, most of which was scene. Only
the coherent line separates them.

Reported per clip:

  band %      the lock-in amplitude at the predicted cell, as a percentage of mean luma. This is
              the band depth.
  SNR         that line against the background of the same estimator at every other drift rate.
              This is the "is it real" test. Above about 20 the band is unambiguous; below about
              10 there is nothing at that cell.
  peak cyc    the spatial frequency at which the coherent line is strongest, searched around the
              prediction. It should land on the prediction, and says the geometry is understood.
  peak drift  likewise on the temporal axis.
  resid %     the whole residual, unprojected, as an upper bound on what could be flicker.

Limits worth knowing. The clip must hold still: a panning camera puts broadband energy into the
residual, which raises the background and costs sensitivity rather than producing a false line.
The recording is the goggle's re-encode of the decoded downlink, so compression attenuates a
shallow band, making this a floor on the real depth. And a comparison between legs is only valid
when the legs share a scene and a light.

    glue/camera/flicker-metric.py off.mp4 fifty.mp4 --mains 50
"""

import argparse
import json
import math
import pathlib
import subprocess
import sys

import numpy as np

# Columns the frame is scaled to before the row means are taken. The metric only needs a row
# average, so the horizontal axis is decimated hard: it cuts the decoded volume by 60x at 1080p
# and changes the row mean by nothing that survives the ripple.
COLUMNS = 32

# Half-width of the search band around the predicted spatial frequency, as a fraction of it.
SEARCH_SPAN = 0.35


class Clip:
    """One recording's geometry, read from the container rather than assumed."""

    def __init__(self, path: pathlib.Path) -> None:
        self.path = path
        probe = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=width,height,avg_frame_rate",
             "-of", "json", str(path)],
            check=True, capture_output=True, text=True)
        streams = json.loads(probe.stdout).get("streams", [])

        if not streams:
            raise SystemExit(f"{path}: no video stream")

        self.width: int = int(streams[0]["width"])
        self.height: int = int(streams[0]["height"])
        self.fps: float = _parse_rate(streams[0].get("avg_frame_rate", "0/0"))


def _parse_rate(rate: str) -> float:
    """ffprobe's a/b frame rate as a float, 0.0 when it is unknown."""
    if "/" not in rate:
        return float(rate or 0.0)

    num, den = rate.split("/", 1)

    return float(num) / float(den) if float(den) else 0.0


def row_profiles(clip: Clip, max_frames: int) -> np.ndarray:
    """Per-frame row-mean luma, shape (frames, height).

    Decoded to 8-bit gray and decimated horizontally by ffmpeg, then averaged here. Frames are
    consumed one at a time so a long clip never has to fit in memory.
    """
    frame_bytes = COLUMNS * clip.height
    proc = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-i", str(clip.path),
         "-vf", f"scale=w={COLUMNS}:h=ih", "-pix_fmt", "gray", "-f", "rawvideo", "-"],
        stdout=subprocess.PIPE)
    profiles: list[np.ndarray] = []

    assert proc.stdout is not None

    try:
        while len(profiles) < max_frames:
            raw = proc.stdout.read(frame_bytes)

            if len(raw) < frame_bytes:
                break

            frame = np.frombuffer(raw, dtype=np.uint8).reshape(clip.height, COLUMNS)
            profiles.append(frame.mean(axis=1))
    finally:
        proc.stdout.close()
        proc.wait()

    if not profiles:
        raise SystemExit(f"{clip.path}: decoded no frames")

    return np.asarray(profiles, dtype=np.float64)


def predicted_cycles(active_lines: int, line_ns: int, mains: float) -> float:
    """Ripple cycles across the image height, from the readout time of the active rows."""
    return active_lines * (line_ns / 1e9) * 2.0 * mains


def project(residual: np.ndarray, cycles: float) -> np.ndarray:
    """Complex amplitude of the residual at one spatial frequency, per frame.

    A Hann window along the row axis, because the wave does not complete a whole number of cycles
    over the image and an unwindowed projection at a fractional frequency leaks badly.
    """
    height = residual.shape[1]
    rows = np.arange(height)
    window = np.hanning(height)
    basis = window * np.exp(-2j * math.pi * cycles * rows / height)

    # 2 / sum(window) rather than 2 / height: the window removes part of the signal's energy, and
    # dividing by its sum rather than its length puts that back, so this returns the amplitude of
    # the underlying sinusoid rather than the windowed one.
    return residual @ basis * (2.0 / window.sum())


def lock_in(amps: np.ndarray, drift: float) -> float:
    """Magnitude of the per-frame amplitude series at one drift rate.

    The series is already complex and one-sided, so the normalisation is 1 / sum(window) here
    rather than the 2 / sum(window) the real-valued spatial projection needs.
    """
    frames = amps.size
    window = np.hanning(frames)
    basis = window * np.exp(-2j * math.pi * drift * np.arange(frames))

    return float(abs(amps @ basis / window.sum()))


def background(amps: np.ndarray, drift: float) -> float:
    """The same estimator at every drift rate the band is not at.

    Excluded: the line itself and its mirror, DC, and the half-rate alias, all of which carry
    signal rather than background.
    """
    avoid = [0.0, drift % 1.0, (-drift) % 1.0]
    levels = [lock_in(amps, freq) for freq in np.linspace(-0.5, 0.5, 401)
              if all(min((freq - a) % 1.0, (a - freq) % 1.0) > 0.03 for a in avoid)]

    return float(np.median(levels))


def predicted_drift(mains: float, fps: float) -> float:
    """Cycles of band phase per frame, of which only the fraction is observable."""
    return (2.0 * mains / fps) % 1.0


def analyse(clip: Clip, profiles: np.ndarray, mains: float,
            active_lines: int, line_ns: int, fps: float) -> dict[str, float]:
    """Every reported quantity for one clip."""
    mean_luma = float(profiles.mean())
    residual = profiles - profiles.mean(axis=0)

    cycles = predicted_cycles(active_lines, line_ns, mains)
    drift = predicted_drift(mains, fps)

    # The sign of the drift depends on whether the mains ripple leads or lags the readout, which
    # nothing here observes, so both are the same physical prediction and the stronger one wins.
    amps = project(residual, cycles)
    line = max(lock_in(amps, drift), lock_in(amps, -drift))
    floor = background(amps, drift)

    # Where the coherent line actually sits. Searched with the temporal filter already applied,
    # which is what makes these positions meaningful rather than a report of where the scene is.
    grid = np.linspace(cycles * (1.0 - SEARCH_SPAN), cycles * (1.0 + SEARCH_SPAN), 41)
    spatial = [max(lock_in(project(residual, c), drift), lock_in(project(residual, c), -drift))
               for c in grid]
    peak_cycles = float(grid[int(np.argmax(spatial))])

    tgrid = np.linspace(drift - 0.15, drift + 0.15, 61)
    temporal = [lock_in(amps, f) for f in tgrid]
    peak_drift = float(tgrid[int(np.argmax(temporal))])

    return {
        "frames": float(profiles.shape[0]),
        "mean_luma": mean_luma,
        "cycles": cycles,
        "drift": drift,
        "amplitude_pct": 100.0 * line / mean_luma if mean_luma else float("nan"),
        # A synthetic clip with no noise at all makes the background exactly zero, so guard the
        # degenerate ratio rather than reporting a still image as infinitely banded.
        "snr": (line / floor) if floor > 0 else (0.0 if line <= 0 else float("inf")),
        "peak_cycles": peak_cycles,
        "peak_drift": peak_drift,
        "residual_rms_pct": 100.0 * float(residual.std()) / mean_luma if mean_luma else float("nan"),
        "container_fps": clip.fps,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+", type=pathlib.Path)
    ap.add_argument("--mains", type=float, default=50.0, help="mains frequency in Hz")
    ap.add_argument("--active-lines", type=int, default=1080,
                    help="sensor rows read out into the visible frame")
    ap.add_argument("--line-ns", type=int, default=14815, help="sensor line time in nanoseconds")
    ap.add_argument("--fps", type=float, default=60.0,
                    help="sensor frame rate, which sets the predicted phase advance")
    ap.add_argument("--max-frames", type=int, default=1800)
    args = ap.parse_args()

    cycles = predicted_cycles(args.active_lines, args.line_ns, args.mains)
    drift = predicted_drift(args.mains, args.fps)
    print(f"{args.mains:g} Hz mains, {args.active_lines} active lines at {args.line_ns} ns: "
          f"the band wave completes {cycles:.3f} cycles over the image height")
    print(f"at {args.fps:g} fps its phase advances {drift:.3f} cycles per frame\n")

    print(f"{'file':<26} {'frames':>6} {'luma':>6} {'band %':>7} {'SNR':>8} "
          f"{'peak cyc':>8} {'peak drift':>10} {'resid %':>8}")

    results: list[tuple[pathlib.Path, dict[str, float]]] = []

    for path in args.files:
        if not path.exists():
            print(f"{path}: no such file", file=sys.stderr)

            continue

        clip = Clip(path)
        stats = analyse(clip, row_profiles(clip, args.max_frames),
                        args.mains, args.active_lines, args.line_ns, args.fps)
        results.append((path, stats))
        print(f"{path.name[:26]:<26} {stats['frames']:6.0f} {stats['mean_luma']:6.1f} "
              f"{stats['amplitude_pct']:7.3f} {stats['snr']:8.1f} "
              f"{stats['peak_cycles']:8.3f} {stats['peak_drift']:10.3f} "
              f"{stats['residual_rms_pct']:8.3f}")

    if len(results) >= 2:
        base_path, base = results[0]
        print(f"\nagainst {base_path.name}, taken as the uncorrected leg:")

        for path, stats in results[1:]:
            if base["amplitude_pct"] > 0:
                ratio = base["amplitude_pct"] / stats["amplitude_pct"] \
                    if stats["amplitude_pct"] > 0 else float("inf")
                print(f"  {path.name}: band {base['amplitude_pct']:.3f}% -> "
                      f"{stats['amplitude_pct']:.3f}%, {ratio:.1f}x shallower")

    print("\nRead SNR first: it is the coherent line against the background of the same estimator")
    print("at every other drift rate. Above about 20 the band is real and the band % is its depth;")
    print("below about 10 there is nothing at that cell and the band % is noise. A band % that")
    print("falls while SNR collapses to the single digits is a correction that worked.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
