#!/usr/bin/env python3
"""Read the goggle's latency counter out of captured frames.

ml-pipeline burns a millisecond counter into every composite (goggles.show_latency_counter), so it
reaches the panel, the DVR file and the RTSP restream identically. Digits are 7-segment bars, and
each one is read by correlating all ten patterns against its cell: point probes are enough for the
burned copy but not for the filmed one, which arrives bloomed and small.

Two modes:

  --nested   glass-to-glass. With the air unit filming the goggle's own panel, each frame carries
             the burned counter AND an older nested copy that went out through the panel, the
             camera, the encoder, the link and the decoder. Their difference is the whole latency.
  default    stamp check. Reads the burned copy only and reports the interval between frames,
             which validates the harness with no optics involved.

Capture and read in one step (rtsp-watch.sh and rtsp-record.sh write files this also reads):
  glue/capture/latency-read.py --rtsp rtsp://192.168.3.101:554/venc8/stream --secs 10 --nested
Or read a capture already taken:
  glue/capture/latency-read.py out/rtsp/goggle-20260818T222823Z.ts --nested

Needs gstreamer with an HEVC decoder (avdec_h265 or libde265dec), Pillow and numpy.
"""

from __future__ import annotations

import argparse
import collections
import contextlib
import glob
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

# Counter geometry in luma pixels, mirroring mlp-latency-counter.c. Changing it there means
# changing it here: cell positions are derived from these, not searched for in the image.
PAD: int = 26
DIGIT_W: int = 88
DIGIT_H: int = 160
STROKE: int = 26
GAP: int = 32
DIGITS: int = 5
BORDER: int = 12

# Tracking markers: a solid bar inside each end of the box, taller than the digits. They are part
# of the correlated pattern rather than something found separately, which is what makes them worth
# having: a bloomed digit stops contributing to the match, a solid bar does not.
MARK_W: int = 52
MARK_GAP: int = 64
MARK_OVER: int = 12
MARK_H: int = DIGIT_H + 2 * MARK_OVER

# The sweep bar under the digits, which is where the fine time comes from. The digits fail
# undetectably when a camera exposure spans two panel frames: the union of two 7-segment glyphs is
# a legible WRONG digit. Two superimposed bars are just the longer one, so the bar's right edge is
# the later of the two times, and being wrong by a frame is at least visible as being wrong.
SWEEP_MS: int = 100
TRACK_H: int = 44
TRACK_GAP: int = 26

DIGITS_W: int = DIGITS * DIGIT_W + (DIGITS - 1) * GAP
BOX_W: int = DIGITS_W + 2 * (PAD + MARK_W + MARK_GAP)
BOX_H: int = 2 * PAD + DIGIT_H + TRACK_GAP + TRACK_H

TRACK_X: int = PAD
TRACK_W: int = BOX_W - 2 * PAD
TRACK_Y: int = PAD + DIGIT_H + TRACK_GAP
MARK_Y: int = PAD - MARK_OVER

# Where the digits start inside the box, past the padding and the left marker.
DIGITS_X: int = PAD + MARK_W + MARK_GAP

# Where ml-pipeline draws the box. Only a starting point: the burned copy is located by correlation
# once per capture, so a capture made with the box somewhere else still reads.
BOX_X: int = (((1920 - BOX_W) // 2) // 2) * 2
BOX_Y: int = 180

# The frame drawn around the box.
FRAME_W: int = BOX_W + 2 * BORDER
FRAME_H: int = BOX_H + 2 * BORDER

# The border is NOT found by its colour. It reads red on the panel, but the air unit meters for the
# dark goggle body around it, so the panel clips and the border comes back white. What the border
# does earn is contrast: it is a closed bright rectangle around the box, which is what makes the
# pattern search below lock on. Judge it by that, not by hue.

# The counter wraps every 100 s, so a difference is taken modulo its range.
COUNTER_RANGE: int = 10 ** DIGITS

MIDDLE: int = (DIGIT_H - STROKE) // 2

SEGMENTS_TO_DIGIT: dict[str, int] = {
    "abcdef": 0,
    "bc": 1,
    "abdeg": 2,
    "abcdg": 3,
    "bcfg": 4,
    "acdfg": 5,
    "acdefg": 6,
    "abc": 7,
    "abcdefg": 8,
    "abcdfg": 9,
}

SEGMENTS_TO_DIGIT_INVERSE: dict[int, str] = {v: k for k, v in SEGMENTS_TO_DIGIT.items()}

# Nested-counter search. The copy that comes back through the camera lands wherever the panel
# happens to sit in frame, at whatever size, so it is found by correlating a rendered template of
# the box against the frame across a range of sizes. Sizes are expressed as the box width in
# pixels: below ~60 the digits are too few pixels to separate, and the panel never fills the frame.
NESTED_MIN_WIDTH: int = 90
NESTED_MAX_WIDTH: int = 600
NESTED_SCALE_STEPS: int = 26

# A digit is read by correlating all ten patterns against its cell and taking the best. Point
# probes fail here: the filmed panel is usually overexposed, so the ink blooms across the gaps that
# tell an 8 from a 9. The margin between the best and second-best score is the confidence, and a
# reading is dropped below this, which throws away blurred frames rather than inventing digits.
NESTED_MIN_MARGIN: float = 0.04

# Below this the best match is not the counter at all, just the least bad patch of scene.
NESTED_MIN_SCORE: float = 0.30

# How many frames from the start are tried when locating the burned copy. It sits at one place for
# a whole capture, so this only has to find it once.
BURNED_SEARCH_FRAMES: int = 12

# The burned copy is rendered, not filmed, so it correlates far better than the filmed one ever
# does. Anything below this is a frame where the counter is not drawn at all.
BURNED_MIN_SCORE: float = 0.55

# The window a latency must land in. The goggle alone accounts for ~30 ms (ML_LATSTATS rx2flip),
# so anything under that is a misread, and 400 ms is far past anything the chain produces. The
# window is also the candidate set for the joint read below, so keeping it tight is what makes that
# read cheap.
LATENCY_MIN_MS: int = 20
LATENCY_MAX_MS: int = 400

# A filmed value is only used when the whole box correlates this well. Below it the panel is out of
# shot, out of focus or half occluded, and the best-fitting value is fitting noise.
NESTED_MIN_VALUE_SCORE: float = 0.55

# How often the size sweep may re-run once tracking is lost. The sweep is seconds per frame and the
# panel does not come back into shot for a single frame, so retrying it on every frame of a long
# out-of-shot stretch costs an hour and finds nothing.
RESWEEP_FRAMES: int = 15

# How much of the track may sit at an intermediate level before the sample is discarded, as a
# fraction. One frame of straddle covers about a frame period of track (17% at 60 Hz); a straddle
# across the reset covers most of it.
SWEEP_MAX_PARTIAL: float = 0.35

# The bar has to stand out from the track it sits on. Below this the track is empty, occluded, or
# washed out to a single level, and any edge found in it is noise.
SWEEP_MIN_CONTRAST: float = 24.0

# The alignment slack the joint read searches, in pixels either way. The box position already comes
# from the pattern search; this only absorbs the last pixel or two.
NESTED_VALUE_SHIFT: int = 3

# How close a filmed step has to be to one capture frame period to count as the panel's clock
# ticking rather than a misread, as a fraction of that period.
NESTED_STEP_TOLERANCE: float = 0.5

# The filmed counter is a clock: between two captured frames it must advance by the time that
# elapsed between them. A reading that does not is a misread, whatever it looks like. The tolerance
# is in frame periods, wide enough to pass real link jitter and the sweep bar's own rounding.
#
# This is the guard that makes a broken read loud. Both failures so far were silent: a fused digit
# reads as a clean wrong number, and a latched tracking hint reported "nothing found" for a capture
# whose counter was plainly in frame.
TRACK_TOLERANCE: float = 1.5

# Consecutive rejections before the track is abandoned and re-seeded from the current reading. The
# panel really can jump - the operator re-aims, or the box is re-acquired somewhere else - and a
# track that can never re-seed would throw away the rest of the capture.
TRACK_RESEED_AFTER: int = 4

# What share of the readable frames must carry a sweep-bar reading before those readings are used
# on their own. The bar is per-frame exact where the digits are not, so mixing the two would let
# the smeared ones widen a distribution the bar had already resolved.
SWEEP_PREFER_FRACTION: float = 0.5

# How many frames the capture period is measured over before the sweep bar is read against it.
PERIOD_SAMPLE_FRAMES: int = 30

# The digit place the crossing estimator works in. The two fastest digits change every frame or
# faster than the air unit's exposure, so they smear; this is the fastest place that survives.
CROSSING_PLACE: int = 100


def _digit_template(digit: int, width: int, height: int, stroke: int) -> np.ndarray:
    """One digit rendered as a float array, ink 1.0 on 0.0, at an arbitrary size."""
    cell = np.zeros((height, width), dtype=np.float32)
    middle = (height - stroke) // 2
    segments = SEGMENTS_TO_DIGIT_INVERSE[digit]

    if "a" in segments:
        cell[0:stroke, :] = 1.0
    if "g" in segments:
        cell[middle:middle + stroke, :] = 1.0
    if "d" in segments:
        cell[height - stroke:height, :] = 1.0
    if "f" in segments:
        cell[0:middle + stroke, 0:stroke] = 1.0
    if "b" in segments:
        cell[0:middle + stroke, width - stroke:width] = 1.0
    if "e" in segments:
        cell[middle:height, 0:stroke] = 1.0
    if "c" in segments:
        cell[middle:height, width - stroke:width] = 1.0

    return cell


def _box_template(box_width: int) -> tuple[np.ndarray, float]:
    """The whole counter box at @p box_width, with every digit cell half-lit.

    Half-lit because the value is unknown at search time: averaging the ten patterns gives a
    template that correlates with any of them, which is what locating the box needs.
    """
    scale = box_width / float(BOX_W)
    height = max(4, int(round(BOX_H * scale)))
    template = np.zeros((height, box_width), dtype=np.float32)

    pad = int(round(PAD * scale))
    digit_w = max(2, int(round(DIGIT_W * scale)))
    digit_h = max(4, int(round(DIGIT_H * scale)))
    stroke = max(1, int(round(STROKE * scale)))
    gap = int(round(GAP * scale))

    average = np.mean([_digit_template(d, digit_w, digit_h, stroke) for d in range(10)], axis=0)
    digits_x = int(round(DIGITS_X * scale))
    for index in range(DIGITS):
        x = digits_x + index * (digit_w + gap)
        if x + digit_w <= box_width and pad + digit_h <= height:
            template[pad:pad + digit_h, x:x + digit_w] = average

    _draw_markers(template, scale)
    _draw_track(template, scale, 0.5)

    return template, scale


def _draw_markers(strip: np.ndarray, scale: float) -> None:
    """Add the two end bars to a rendered box, in place."""
    height, width = strip.shape
    mark_w = max(1, int(round(MARK_W * scale)))
    mark_h = max(1, int(round(MARK_H * scale)))
    mark_y = int(round(MARK_Y * scale))
    pad = int(round(PAD * scale))

    for x in (pad, width - pad - mark_w):
        if x >= 0 and x + mark_w <= width and mark_y + mark_h <= height:
            strip[mark_y:mark_y + mark_h, x:x + mark_w] = 1.0


def _draw_track(strip: np.ndarray, scale: float, fraction: float) -> None:
    """Add the sweep bar, filled to @p fraction of the track, in place."""
    height, width = strip.shape
    track_x = int(round(TRACK_X * scale))
    track_y = int(round(TRACK_Y * scale))
    track_h = max(1, int(round(TRACK_H * scale)))
    filled = int(round(TRACK_W * scale * fraction))

    if filled > 0 and track_y + track_h <= height and track_x + filled <= width:
        strip[track_y:track_y + track_h, track_x:track_x + filled] = 1.0


def _correlate(image: np.ndarray, template: np.ndarray) -> np.ndarray:
    """Zero-mean normalised cross-correlation of @p template over @p image, via FFT.

    Proper NCC, bounded to [-1, 1]: the denominator carries both the window's own deviation and the
    template's, and windows with almost no contrast are floored rather than divided by nearly zero.
    A blown-out patch of panel is exactly such a window, and without the floor it outscores the
    real box every time.
    """
    th, tw = template.shape
    ih, iw = image.shape
    if th >= ih or tw >= iw:
        return np.zeros((1, 1), dtype=np.float32)

    kernel = template - template.mean()
    kernel_norm = float(np.sqrt((kernel ** 2).sum()))
    if kernel_norm < 1e-6:
        return np.zeros((1, 1), dtype=np.float32)

    shape = (ih, iw)
    image_f = np.fft.rfft2(image, shape)
    ones = np.ones_like(kernel)
    ones_f = np.conj(np.fft.rfft2(ones, shape))

    numerator = np.fft.irfft2(image_f * np.conj(np.fft.rfft2(kernel, shape)), shape)
    total = np.fft.irfft2(image_f * ones_f, shape)
    total_sq = np.fft.irfft2(np.fft.rfft2(image ** 2, shape) * ones_f, shape)

    view = (slice(0, ih - th + 1), slice(0, iw - tw + 1))
    count = float(th * tw)
    window_sq = total_sq[view] - total[view] ** 2 / count
    window_norm = np.sqrt(np.maximum(window_sq, 0.0))

    # The floor is a fraction of what a real box's window carries: ink against box is most of the
    # dynamic range, so anything far below that is a flat region and cannot be the counter.
    floor = 0.02 * 255.0 * np.sqrt(count)

    return numerator[view] / (np.maximum(window_norm, floor) * kernel_norm)


def _best_match(image: np.ndarray, widths: list[int],
                exclude: tuple[int, int, int, int] | None = None
                ) -> tuple[int, int, int, float] | None:
    """Best (x, y, width, score) over @p widths, by correlating the box template at each.

    @p exclude is a rectangle in @p image's own coordinates that no match may touch, used to rule
    out the burned copy. It is applied to the score map rather than by painting over the image: a
    painted patch has hard edges of its own, and the template matches those instead.
    """
    best = None
    for width in widths:
        if width < 8:
            continue

        template, _ = _box_template(width)
        scores = _correlate(image, template)
        if scores.size <= 1:
            continue

        if exclude is not None:
            height = template.shape[0]
            ex0, ey0, ex1, ey1 = exclude
            scores[max(0, ey0 - height + 1):ey1, max(0, ex0 - width + 1):ex1] = -1.0

        index = int(np.argmax(scores))
        peak = float(scores.flat[index])
        y, x = divmod(index, scores.shape[1])
        if best is None or peak > best[3]:
            best = (x, y, width, peak)

    return best


def _search_near(frame: np.ndarray, box: tuple[int, int, int]
                 ) -> tuple[int, int, int, float] | None:
    """Look for the box near where it was last frame, against a crop rather than the whole frame."""
    x, y, width = box
    height = int(round(BOX_H * width / float(BOX_W)))
    margin = max(8, width // 3)
    y0 = max(0, y - margin)
    x0 = max(0, x - margin)
    region = frame[y0:y + height + margin, x0:x + width + margin]

    found = _best_match(region, [width - 6, width - 4, width - 2, width, width + 2, width + 4, width + 6])
    if found is None:
        return None

    return x0 + found[0], y0 + found[1], found[2], found[3]


def find_nested_box(frame: np.ndarray, hint: tuple[int, int, int] | None = None,
                    burned_box: tuple[int, int] | None = None
                    ) -> tuple[int, int, int] | None:
    """Locate the filmed copy of the counter: returns (x, y, box_width) or None.

    The sweep across sizes runs at full resolution, because at half resolution the bars are two
    pixels wide and correlate with anything. It is also the expensive part, so a hint from the
    previous frame is tried first against a crop: the panel barely moves between frames, so that
    path serves nearly every frame of a real capture and the sweep runs only when tracking is lost.
    """
    if hint is not None:
        near = _search_near(frame, hint)
        if near is not None and near[3] >= NESTED_MIN_SCORE:
            return near[0], near[1], near[2]

    widths = []
    for step in range(NESTED_SCALE_STEPS):
        fraction = step / float(NESTED_SCALE_STEPS - 1)
        widths.append(int(round(NESTED_MIN_WIDTH
                                * (NESTED_MAX_WIDTH / NESTED_MIN_WIDTH) ** fraction)))

    origin = burned_box if burned_box is not None else (BOX_X, BOX_Y)
    burned = (origin[0], origin[1], origin[0] + BOX_W, origin[1] + BOX_H)
    candidate = _best_match(frame, sorted(set(widths)), burned)
    if candidate is None or candidate[3] < NESTED_MIN_SCORE:
        return None

    refined = _search_near(frame, (candidate[0], candidate[1], candidate[2]))
    if refined is not None and refined[3] >= candidate[3]:
        return refined[0], refined[1], refined[2]

    return candidate[0], candidate[1], candidate[2]


def read_counter_at(frame: np.ndarray, x: int, y: int, box_width: int,
                    first_digit: int = 0, slack: int | None = None) -> int | None:
    """Read the counter from a box of @p box_width at (@p x, @p y) by per-digit correlation.

    Cell positions come from unrounded geometry, and each cell is then matched over a few pixels of
    slack. Rounding each step and accumulating drifts the last digits by several pixels at the
    sizes the filmed copy arrives at, and the panel is filmed at an angle besides, so the cells are
    never exactly where flat scaling says.
    """
    scale = box_width / float(BOX_W)
    digit_w = max(2, int(round(DIGIT_W * scale)))
    digit_h = max(4, int(round(DIGIT_H * scale)))
    stroke = max(1, int(round(STROKE * scale)))
    # How far each cell may be hunted for. The filmed panel is off-axis, so the cells sit a few
    # pixels from where flat scaling puts them, and that error grows across the row. A quarter of a
    # cell absorbs it; the burned copy is exact and passes 1.
    if slack is None:
        slack = max(2, digit_w // 4)

    templates = []
    for digit in range(10):
        cell = _digit_template(digit, digit_w, digit_h, stroke)
        kernel = cell - cell.mean()
        templates.append((kernel, float(np.sqrt((kernel ** 2).sum()))))

    value = ""
    for index in range(first_digit, DIGITS):
        x0 = x + int(round(scale * (DIGITS_X + index * (DIGIT_W + GAP))))
        y0 = y + int(round(scale * PAD))

        best = (-2.0, -1)
        second = -2.0
        for dy in range(-slack, slack + 1):
            for dx in range(-slack, slack + 1):
                cell = frame[y0 + dy:y0 + dy + digit_h, x0 + dx:x0 + dx + digit_w]
                if cell.shape != (digit_h, digit_w):
                    continue

                centred = cell - cell.mean()
                norm = float(np.sqrt((centred ** 2).sum()))
                if norm < 1e-6:
                    continue

                for digit, (kernel, kernel_norm) in enumerate(templates):
                    score = float((centred * kernel).sum() / (norm * kernel_norm))
                    if score > best[0]:
                        if digit != best[1]:
                            second = best[0]
                        best = (score, digit)
                    elif digit != best[1] and score > second:
                        second = score

        if best[1] < 0 or best[0] - second < NESTED_MIN_MARGIN:
            return None

        value += str(best[1])

    return int(value)


def find_burned_box(frame: np.ndarray) -> tuple[int, int] | None:
    """Locate the burned copy, which is at a known size but not necessarily a known place.

    Hard-coding the position ties the reader to one build of ml-pipeline: the box has already moved
    down the frame once, and a capture taken before that still has to read. The size IS known, so
    this is one scale of the search rather than a sweep, and the result holds for a whole capture.
    """
    found = _best_match(frame, [BOX_W], None)
    if found is None or found[3] < BURNED_MIN_SCORE:
        return None

    return found[0], found[1]


def read_burned(frame: np.ndarray, box: tuple[int, int]) -> int | None:
    """The counter ml-pipeline burned in, at the position find_burned_box settled on."""
    return read_counter_at(frame, box[0], box[1], BOX_W, slack=1)


def _strip_template(value: int, width: int) -> np.ndarray:
    """The whole counter box rendered as one array, ink 1.0 on 0.0, at box width @p width."""
    scale = width / float(BOX_W)
    height = max(4, int(round(BOX_H * scale)))
    strip = np.zeros((height, width), dtype=np.float32)

    digit_w = max(2, int(round(DIGIT_W * scale)))
    digit_h = max(4, int(round(DIGIT_H * scale)))
    stroke = max(1, int(round(STROKE * scale)))

    for index, character in enumerate(f"{value % COUNTER_RANGE:0{DIGITS}d}"):
        cell = _digit_template(int(character), digit_w, digit_h, stroke)
        x0 = int(round(scale * (DIGITS_X + index * (DIGIT_W + GAP))))
        y0 = int(round(scale * PAD))
        target = strip[y0:y0 + digit_h, x0:x0 + digit_w]
        if target.shape != cell.shape:
            cell = cell[:target.shape[0], :target.shape[1]]

        np.maximum(target, cell, out=target)

    _draw_markers(strip, scale)
    _draw_track(strip, scale, (value % SWEEP_MS) / float(SWEEP_MS))

    return strip


def read_nested_value(frame: np.ndarray, box: tuple[int, int, int],
                      burned: int) -> tuple[int, float] | None:
    """The filmed copy's value, chosen by matching the WHOLE box against every plausible one.

    Reading each digit on its own is what fails on a filmed panel. The air unit meters for the dark
    goggle body, so the panel clips, the strokes bloom across the gaps, and an independent per-digit
    decision turns a 4 into a 9. Matching whole candidate values instead makes the digits vote
    together, and the candidate set is small because latency is bounded: one rendering per
    millisecond over LATENCY_MIN_MS..LATENCY_MAX_MS behind the burned value.

    Returns the value and its correlation, or None when nothing fits well enough to use.
    """
    x, y, width = box
    height = int(round(BOX_H * width / float(BOX_W)))

    values = list(range(burned - LATENCY_MAX_MS, burned - LATENCY_MIN_MS + 1))
    strips = np.stack([_strip_template(value, width) for value in values]).reshape(len(values), -1)

    # One matmul per shift rather than a correlation per candidate: the candidate set is in the
    # hundreds and the box is thousands of pixels, so the loop form dominates a whole capture.
    kernels = strips - strips.mean(axis=1, keepdims=True)
    norms = np.sqrt((kernels ** 2).sum(axis=1))
    usable = norms > 1e-6
    kernels = kernels[usable] / norms[usable, None]
    usable_values = [value for value, keep in zip(values, usable, strict=True) if keep]
    if not usable_values:
        return None

    best_score = -2.0
    best_value = None
    for dy in range(-NESTED_VALUE_SHIFT, NESTED_VALUE_SHIFT + 1, 2):
        for dx in range(-NESTED_VALUE_SHIFT, NESTED_VALUE_SHIFT + 1, 2):
            window = frame[y + dy:y + dy + height, x + dx:x + dx + width]
            if window.shape != (height, width):
                continue

            centred = (window - window.mean()).reshape(-1)
            norm = float(np.sqrt((centred ** 2).sum()))
            if norm < 1e-6:
                continue

            scores = kernels @ (centred / norm)
            index = int(np.argmax(scores))
            if float(scores[index]) > best_score:
                best_score = float(scores[index])
                best_value = usable_values[index]

    if best_value is None or best_score < NESTED_MIN_VALUE_SCORE:
        return None

    return best_value, best_score


def _band(frame: np.ndarray, box: tuple[int, int, int],
          x0: int, y0: int, w: int, h: int) -> np.ndarray | None:
    """A rectangle of @p frame given in unscaled box coordinates, or None if it is off frame."""
    x, y, width = box
    scale = width / float(BOX_W)
    left = x + int(round(x0 * scale))
    top = y + int(round(y0 * scale))
    region = frame[top:top + max(1, int(round(h * scale))),
                   left:left + max(1, int(round(w * scale)))]

    return region if region.size and region.shape[0] >= 1 and region.shape[1] >= 4 else None


def read_sweep(frame: np.ndarray, box: tuple[int, int, int], period: float) -> float | None:
    """How far the sweep bar has run, in ms within its cycle, or None.

    Not a threshold. The filmed panel has a brightness gradient across it, enough that the left end
    of a LIT bar comes back dimmer than the middle of one, so any single cut-off either loses the
    dim end of the bar or swallows the unlit track. Instead every column is normalised against what
    unlit and lit look like AT THAT COLUMN: the box's bottom padding is always unlit, and the two
    end markers are always lit, so interpolating between them gives a local ink reference. That is
    the job the markers were added for.

    The result is then an integral rather than an edge, which is what makes it exposure-weighted.
    A camera that catches two panel frames does not see a union: it sees columns lit for the whole
    exposure at full brightness and columns lit for part of it in proportion. Summing the
    normalised columns returns the MEAN time across the exposure, so a straddle costs precision
    rather than correctness.
    """
    track = _band(frame, box, TRACK_X, TRACK_Y, TRACK_W, TRACK_H)
    floor = _band(frame, box, TRACK_X, TRACK_Y + TRACK_H + (PAD // 4), TRACK_W, PAD // 2)
    left = _band(frame, box, PAD, MARK_Y, MARK_W, MARK_H)
    right = _band(frame, box, BOX_W - PAD - MARK_W, MARK_Y, MARK_W, MARK_H)
    if track is None or floor is None or left is None or right is None:
        return None

    columns = track.shape[1]
    dark = np.interp(np.linspace(0.0, 1.0, columns),
                     np.linspace(0.0, 1.0, floor.shape[1]), floor.mean(axis=0))
    ink = np.linspace(float(np.median(left)), float(np.median(right)), columns)

    span = ink - dark
    if float(np.median(span)) < SWEEP_MIN_CONTRAST:
        return None

    # Guard the division: a column whose references have collapsed carries no information, and
    # letting it through would make its normalised level enormous rather than merely wrong.
    usable = span >= SWEEP_MIN_CONTRAST
    if usable.sum() < columns // 2:
        return None

    level = np.zeros(columns, dtype=np.float64)
    level[usable] = (track.mean(axis=0)[usable] - dark[usable]) / span[usable]
    level = np.clip(level, 0.0, 1.0)

    # A straddle shows up as columns at an intermediate level: lit for part of the exposure only.
    # One frame of straddle is one frame period's worth of track and is exactly what the integral
    # is meant to average over. A straddle across the bar's RESET is not: it catches a nearly full
    # bar and a nearly empty one, so most of the track sits half lit and the integral returns a
    # plausible mid-track value that is pure fiction. Width tells the two apart, and nothing else
    # does - the reading itself looks ordinary.
    partial = float(((level > 0.15) & (level < 0.85))[usable].sum()) / float(usable.sum())
    if partial > SWEEP_MAX_PARTIAL:
        return None

    filled = float(level[usable].sum()) * columns / float(usable.sum())

    return SWEEP_MS * filled / float(columns)


def refine_with_sweep(digits: int, offset: float) -> int:
    """The filmed value with its fast places taken from the bar instead of the digits.

    The digits keep the SWEEP_MS place and above, which they read reliably; the bar replaces what
    is below it. The two are read from the same image but can straddle a rollover, so the coarse
    part is stepped when they disagree by more than half a cycle.
    """
    value = (digits // SWEEP_MS) * SWEEP_MS + int(round(offset))
    if value - digits > SWEEP_MS // 2:
        value -= SWEEP_MS
    elif digits - value > SWEEP_MS // 2:
        value += SWEEP_MS

    return value


class ClockTrack:
    """Rejects filmed readings that the panel's own clock cannot explain.

    Holds the last accepted reading and the frame it came from, and asks of each new one whether it
    advanced by the elapsed time. Nothing here presumes a latency: the test is on the filmed clock's
    RATE, which is known, not on the difference being measured.
    """

    def __init__(self, period: float) -> None:
        self.period = period
        self.value: int | None = None
        self.index: int = 0
        self.rejected: int = 0
        self.reseeds: int = 0
        self._misses: int = 0

    def accept(self, index: int, value: int) -> bool:
        """Whether @p value at frame @p index is consistent with what came before."""
        if self.value is None:
            self.value, self.index = value, index

            return True

        expected = self.value + self.period * (index - self.index)
        if abs(value - expected) <= TRACK_TOLERANCE * self.period:
            self.value, self.index = value, index
            self._misses = 0

            return True

        self.rejected += 1
        self._misses += 1
        if self._misses >= TRACK_RESEED_AFTER:
            self.value, self.index = value, index
            self._misses = 0
            self.reseeds += 1

        return False


def frame_period(burned: list[int]) -> float:
    """The capture's frame period in ms, measured from the burned counter rather than assumed."""
    steps = [b - a for a, b in zip(burned, burned[1:], strict=False) if 0 < b - a < 200]
    if not steps:
        return 1000.0 / 60.0

    return percentile(steps, 0.50)


def latencies_direct(series: list[tuple[int, int, int]], period: float) -> list[int] | None:
    """Per-frame latency, used only when the filmed values tick like the clock they are.

    @p series is (frame index, burned, nested). If the filmed copy is legible to the last digit its
    successive values step by the elapsed time, the same as the burned copy. The frame index is
    what makes that test work across gaps: samples get dropped, and a step over a dropped frame is
    two periods, which is right rather than wrong. When the steps do not hold, the fast places are
    smeared and every difference taken from them is noise, so this returns None and the caller
    falls back to the crossing estimator.
    """
    steps = [(nb - na, ib - ia)
             for (ia, _, na), (ib, _, nb) in zip(series, series[1:], strict=False)]
    if not steps:
        return None

    clean = sum(1 for step, gap in steps
                if abs(step - period * gap) <= NESTED_STEP_TOLERANCE * period)
    if clean < 0.8 * len(steps):
        return None

    return [burned - nested for _, burned, nested in series]


def latencies_from_crossings(series: list[tuple[int, int, int]], period: float) -> list[float]:
    """Latency from the moments the filmed copy's hundreds digit ticks over.

    The fast digits smear, but the hundreds digit does not, and its transition is a timestamp: when
    the filmed value crosses a round hundred between two captured frames, the panel time in the
    later frame is within one frame period above that hundred. Subtracting it from the burned value
    brackets the latency to a frame, which is the capture's resolution anyway.

    Each crossing yields one sample, so a 100 ms counter gives ten a second.
    """
    samples = []
    for (_, _, before), (_, burned, after) in zip(series, series[1:], strict=False):
        coarse_before = (before // CROSSING_PLACE) * CROSSING_PLACE
        coarse_after = (after // CROSSING_PLACE) * CROSSING_PLACE
        if coarse_after - coarse_before != CROSSING_PLACE:
            continue

        # The panel time sits in (coarse_after, coarse_after + period]; take the middle of that.
        latency = burned - coarse_after - period / 2.0
        if LATENCY_MIN_MS <= latency <= LATENCY_MAX_MS:
            samples.append(latency)

    return samples


def capture_rtsp(url: str, secs: int, path: str) -> None:
    """Record @p secs of the restream to @p path as raw Annex-B, without re-encoding.

    Raw rather than MP4 on purpose: the capture ends by killing the pipeline, and a container
    written that way never gets its index, while an elementary stream truncated mid-frame still
    decodes up to the cut.
    """
    pipeline = [
        "gst-launch-1.0", "-q",
        "rtspsrc", f"location={url}", "latency=0", "protocols=tcp",
        "!", "rtph265depay", "!", "h265parse", "config-interval=-1",
        "!", "video/x-h265,stream-format=byte-stream,alignment=au",
        "!", "filesink", f"location={path}",
    ]
    print(f"capturing {secs}s from {url}", file=sys.stderr)
    with contextlib.suppress(subprocess.TimeoutExpired):
        subprocess.run(pipeline, timeout=secs, check=False)


def decode_frames(path: str, out_dir: str) -> list[str]:
    """Decode every frame of @p path to 8-bit grey PNGs, returning them in order."""
    # decodebin rather than a fixed demuxer chain: captures arrive as MPEG-TS, Matroska, MP4 or a
    # raw elementary stream depending on how they were taken, and a truncated one still decodes up
    # to the cut.
    pipeline = (
        f"filesrc location={path} ! decodebin ! videoconvert"
        f" ! video/x-raw,format=GRAY8 ! pngenc ! multifilesink location={out_dir}/f_%05d.png"
    )
    subprocess.run(["gst-launch-1.0", "-q"] + pipeline.split(), check=False)

    return sorted(glob.glob(os.path.join(out_dir, "f_*.png")))


def percentile(values: list[int], fraction: float) -> float:
    """The @p fraction percentile of @p values, nearest-rank."""
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(round(fraction * (len(ordered) - 1)))))

    return float(ordered[index])


def report_stamp(values: list[int | None]) -> None:
    """Burned counter only: the series and its per-frame interval, which validates the stamp."""
    good = [v for v in values if v is not None]
    if not good:
        print("no counter found in any frame - is goggles.show_latency_counter on?")

        return

    deltas = [b - a for a, b in zip(good, good[1:], strict=False)]
    histogram = collections.Counter(d for d in deltas if d >= 0)

    print(f"frames: {len(values)}, counter readable in {len(good)}")
    print(f"span: {good[0]} -> {good[-1]} = {good[-1] - good[0]} ms over {len(good)} frames")
    if len(good) > 1:
        print(f"mean interval: {(good[-1] - good[0]) / (len(good) - 1):.2f} ms")
    print(f"backward steps: {sum(1 for d in deltas if d < 0)}")
    print("interval histogram (ms: frames):")
    for delta, count in sorted(histogram.items()):
        print(f"  {delta:3d}: {'#' * min(count, 60)} {count}")


def report_latency(series: list[tuple[int, int, int, bool]], burned_all: list[int], frames: int,
                   swept: int = 0, track: ClockTrack | None = None) -> None:
    """Glass-to-glass, read either straight off the filmed digits or off their hundreds crossings."""
    if len(series) < 2:
        print(f"frames: {frames}, the filmed counter was readable in {len(series)}")
        print("It has to be in shot, in focus and not blown out. Aim the air unit at the panel and")
        print("light the bench: the exposure the air unit picks for a dark room is what clips it.")

        return

    period = frame_period(burned_all)
    print(f"frames: {frames}, filmed counter read in {len(series)}"
          f" ({100.0 * len(series) / frames:.0f}%), capture period {period:.1f} ms")
    print(f"sweep bar read in {swept} of those"
          f" ({100.0 * swept / max(1, len(series)):.0f}%)")
    if track is not None and track.rejected:
        print(f"{track.rejected} reading(s) rejected as inconsistent with the panel clock,"
              f" {track.reseeds} re-seed(s)")

    plain = [(index, burned, nested) for index, burned, nested, _ in series]
    from_bar = [(index, burned, nested) for index, burned, nested, bar in series if bar]

    if len(from_bar) >= 2 and len(from_bar) >= SWEEP_PREFER_FRACTION * len(series):
        # The bar's readings stand alone rather than being averaged with the digit-only frames.
        # Those are the frames where the fast places were smeared, which is exactly the error the
        # bar exists to avoid, and letting them in would re-widen a distribution it had resolved.
        samples = [float(burned - nested) for _, burned, nested in from_bar
                   if LATENCY_MIN_MS <= burned - nested <= LATENCY_MAX_MS]
        source = "per frame, from the sweep bar"
    elif (direct := latencies_direct(plain, period)) is not None:
        samples = [float(value) for value in direct
                   if LATENCY_MIN_MS <= value <= LATENCY_MAX_MS]
        source = "per frame, from the digits"
    else:
        samples = latencies_from_crossings(plain, period)
        source = f"from {CROSSING_PLACE} ms crossings"
        print("The filmed digits do not step by one frame, so the fast places are smeared: the air")
        print("unit's exposure spans more than one panel frame. Falling back to crossings, which")
        print(f"resolve to one frame period (+/- {period / 2.0:.0f} ms) and need no fast digit.")

    if not samples:
        print("no sample landed in the plausible window: every reading was a misread")

        return

    integers = [int(round(value)) for value in samples]
    print(f"glass-to-glass p50 {percentile(integers, 0.50):.0f} ms,"
          f" p99 {percentile(integers, 0.99):.0f} ms,"
          f" min {min(integers)} ms, max {max(integers)} ms ({source}, {len(samples)} samples)")
    print(f"mean {sum(samples) / len(samples):.1f} ms")

    # A single sample resolves to about one frame period, so the shape matters more than any one
    # reading: a tight cluster is a real measurement, a spread of hundreds of ms is a misread.
    print("distribution (ms: samples):")
    histogram = collections.Counter(value - value % 5 for value in integers)
    for bucket, count in sorted(histogram.items()):
        print(f"  {bucket:4d}: {'#' * min(count, 60)} {count}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", nargs="?", help="captured file to read")
    parser.add_argument("--rtsp", help="capture from this restream URL instead of reading a file")
    parser.add_argument("--secs", type=int, default=10, help="capture length with --rtsp")
    parser.add_argument("--keep", help="write the captured file here instead of a temporary one")
    parser.add_argument("--nested", action="store_true",
                        help="also read the filmed copy and report glass-to-glass latency")
    args = parser.parse_args()

    if (args.path is None) == (args.rtsp is None):
        parser.error("give either a file to read or --rtsp to capture")

    work_dir = tempfile.mkdtemp(prefix="latency-read-")
    try:
        source = args.path
        if args.rtsp is not None:
            source = args.keep or os.path.join(work_dir, "capture.ts")
            capture_rtsp(args.rtsp, args.secs, source)

        frames = decode_frames(source, work_dir)
        if not frames:
            print(f"no frames decoded from {source}", file=sys.stderr)

            return 1

        # Over the first several frames, not just the first one: a capture can open on a frame the
        # counter is missing from - the pipeline restarting, a partial frame at the cut - and
        # giving up there would throw away a whole good recording.
        burned_box = None
        for path in frames[:BURNED_SEARCH_FRAMES]:
            burned_box = find_burned_box(np.asarray(Image.open(path).convert("L"),
                                                    dtype=np.float32))
            if burned_box is not None:
                break

        if burned_box is None:
            print(f"no burned counter in the first {BURNED_SEARCH_FRAMES} frames:"
                  " is goggles.show_latency_counter on?", file=sys.stderr)

            return 1

        print(f"burned counter at {burned_box[0]},{burned_box[1]} ({BOX_W}x{BOX_H})")

        if not args.nested:
            report_stamp([read_burned(np.asarray(Image.open(f).convert("L"), dtype=np.float32),
                                      burned_box)
                          for f in frames])

            return 0

        series = []
        burned_all = []
        period = None
        swept = 0
        track = None
        hint = None
        for index, path in enumerate(frames):
            frame = np.asarray(Image.open(path).convert("L"), dtype=np.float32)
            burned = read_burned(frame, burned_box)
            if burned is None:
                continue

            burned_all.append(burned)
            if period is None and len(burned_all) >= PERIOD_SAMPLE_FRAMES:
                period = frame_period(burned_all)

            if hint is None and index % RESWEEP_FRAMES:
                continue

            found = find_nested_box(frame, hint, burned_box)
            if found is None:
                hint = None

                continue

            read = read_nested_value(frame, found, burned)
            if read is None:
                # Tracking is confirmed by a VALUE, never by the box score alone. The box template
                # scores above its own threshold on plenty of scene clutter, so a hint taken on
                # faith latches onto the first such patch and, because a hint suppresses the sweep,
                # never lets go: the whole capture then reads as nothing found.
                hint = None

                continue

            # Track with the previous frame's box: the sweep costs seconds from cold and a fraction
            # of that from a hint, and the panel moves by pixels between frames.
            hint = found

            nested = read[0]
            offset = read_sweep(frame, found, period or 1000.0 / 60.0)
            if offset is not None:
                nested = refine_with_sweep(nested, offset)

            if track is None:
                track = ClockTrack(period or 1000.0 / 60.0)

            if not track.accept(index, nested):
                continue

            swept += offset is not None
            series.append((index, burned, nested, offset is not None))

        report_latency(series, burned_all, len(frames), swept, track)
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)

    return 0


if __name__ == "__main__":
    sys.exit(main())
