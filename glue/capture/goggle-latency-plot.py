#!/usr/bin/env python3
"""Render a goggle-side latency timeline SVG from ml-pipeline latency logs."""

from __future__ import annotations

import argparse
import html
import json
import re
import statistics
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

LAT_RE = re.compile(
    r"ml-pipeline: lat n=(?P<n>\d+) "
    r"rx2flip p50=(?P<rxflip50>[0-9.]+) p99=(?P<rxflip99>[0-9.]+) \| "
    r"rx2dec (?P<rxdec0>[0-9.]+)/(?P<rxdec1>[0-9.]+) "
    r"pair (?P<pair>[0-9.]+) sub2flip (?P<subflip>[0-9.]+) \| "
    r"fdt p50=(?P<fdt50>[0-9.]+) p99=(?P<fdt99>[0-9.]+) "
    r"jud=(?P<jud>\d+) rep=(?P<rep>\d+) \(ms\)"
    r"(?: PHASE-FORCED=(?P<forced>\d+)us)?"
)

LATRAW_RE = re.compile(
    r"ml-pipeline: latraw pts=(?P<pts>\d+) pair=(?P<pair>\d+) "
    r"issue=(?P<issue>\d+) sub=(?P<sub>\d+) evt=(?P<evt>\d+)"
)


@dataclass(frozen=True)
class LatStats:
    lines: int
    frames: int
    rxflip50: float
    rxflip99: float
    rxdec0: float
    rxdec1: float
    pair_skew: float
    subflip: float
    fdt50: float
    fdt99: float
    judder: int
    repeats: int
    raw_frames: int
    pair_issue: float | None
    issue_submit: float | None
    submit_event: float | None
    pair_event: float | None
    phase_forced_us: int | None


def median(values: list[float]) -> float:
    if not values:
        raise ValueError("no values to reduce")
    return float(statistics.median(values))


def parse_log(path: Path) -> LatStats:
    summary: dict[str, list[float]] = {
        "rxflip50": [],
        "rxflip99": [],
        "rxdec0": [],
        "rxdec1": [],
        "pair": [],
        "subflip": [],
        "fdt50": [],
        "fdt99": [],
    }
    frames = 0
    judder = 0
    repeats = 0
    phase_forced_us: int | None = None
    pair_issue: list[float] = []
    issue_submit: list[float] = []
    submit_event: list[float] = []
    pair_event: list[float] = []

    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if match := LAT_RE.search(line):
            frames += int(match.group("n"))
            judder += int(match.group("jud"))
            repeats += int(match.group("rep"))
            if match.group("forced"):
                phase_forced_us = int(match.group("forced"))
            for key in summary:
                src = "pair" if key == "pair" else key
                summary[key].append(float(match.group(src)))
            continue

        if match := LATRAW_RE.search(line):
            pair = int(match.group("pair"))
            issue = int(match.group("issue"))
            submit = int(match.group("sub"))
            event = int(match.group("evt"))
            if pair and issue and submit and event:
                pair_issue.append((issue - pair) / 1000.0)
                issue_submit.append((submit - issue) / 1000.0)
                submit_event.append((event - submit) / 1000.0)
                pair_event.append((event - pair) / 1000.0)

    if not summary["rxflip50"]:
        raise ValueError(f"{path} has no ml-pipeline latency summary lines")

    return LatStats(
        lines=len(summary["rxflip50"]),
        frames=frames,
        rxflip50=median(summary["rxflip50"]),
        rxflip99=median(summary["rxflip99"]),
        rxdec0=median(summary["rxdec0"]),
        rxdec1=median(summary["rxdec1"]),
        pair_skew=median(summary["pair"]),
        subflip=median(summary["subflip"]),
        fdt50=median(summary["fdt50"]),
        fdt99=median(summary["fdt99"]),
        judder=judder,
        repeats=repeats,
        raw_frames=len(pair_event),
        pair_issue=median(pair_issue) if pair_issue else None,
        issue_submit=median(issue_submit) if issue_submit else None,
        submit_event=median(submit_event) if submit_event else None,
        pair_event=median(pair_event) if pair_event else None,
        phase_forced_us=phase_forced_us,
    )


def fmt(value: float | None) -> str:
    if value is None:
        return "n/a"
    return f"{value:.1f}"


def clamp(value: float, lo: float, hi: float) -> float:
    return min(max(value, lo), hi)


def render_svg(stats: LatStats, title: str) -> str:
    width = 1120
    height = 560
    left = 150.0
    right = 1050.0
    scale = 30.0

    rx_t = 0.0
    dec0_t = stats.rxdec0
    dec1_t = stats.rxdec1
    pair_t = max(dec0_t, dec1_t)
    issue_t = pair_t + (stats.pair_issue or 0.0)
    submit_t = issue_t + (stats.issue_submit or 0.0)
    latch_t = stats.rxflip50

    # These are median landmarks from different reduced distributions, so prevent visual inversion
    # without hiding the original labels.
    issue_x = max(issue_t, pair_t)
    submit_x = max(submit_t, issue_x + 0.12)
    latch_x = max(latch_t, submit_x + 0.12)

    def x(ms: float) -> float:
        return left + ms * scale

    def sx(ms: float) -> float:
        return clamp(x(ms), left, right)

    title = html.escape(title)
    subtitle = (
        f"{stats.lines} summary lines, {stats.frames} summary frames, "
        f"{stats.raw_frames} raw frames. Median landmarks; segment medians are not additive."
    )
    if stats.phase_forced_us is not None:
        title = (f"{title} [PHASE FORCED {stats.phase_forced_us} us, "
                 f"NOT A LATENCY RESULT]")
        subtitle = (f"Vblank phase forcing was armed: the tile-0 submit is held back by up to one "
                    f"vsync, so every wait below reads high. {subtitle}")

    dot_radius = 7
    guide_label_y = 500
    guide_label_y2 = 518
    event_labels = [
        (rx_t, "0.0 ms", guide_label_y2),
        (dec0_t, f"{fmt(dec0_t)} ms", guide_label_y2),
        (dec1_t, f"{fmt(dec1_t)} ms", guide_label_y2),
        (issue_t, f"{fmt(issue_t)} ms", guide_label_y),
        (submit_t, f"{fmt(submit_t)} ms", guide_label_y2),
        (latch_t, f"{fmt(latch_t)} ms", guide_label_y2),
    ]
    event_label_y_by_t = {t: y for t, _label, y in event_labels}

    guide_svg = "\n".join(
        f'  <line class="guide" x1="{sx(t):.1f}" y1="{dot_y + dot_radius}" '
        f'x2="{sx(t):.1f}" y2="{event_label_y_by_t[t] - 13}"/>'
        for t, dot_y in [
            (rx_t, 112),
            (dec0_t, 172),
            (dec1_t, 232),
            (issue_t, 296),
            (submit_t, 416),
            (latch_t, 464),
        ]
    )
    label_svg = "\n".join(
        f'  <text class="time" x="{sx(t):.1f}" y="{y}">{label}</text>'
        for t, label, y in event_labels
    )

    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">
  <title id="title">{title}</title>
  <desc id="desc">Grouped timeline from first received UDP datagram to DRM scanout latch, with decode, composition, and display stages.</desc>
  <style>
    .bg {{ fill: #ffffff; }}
    .title {{ fill: #111827; font: 18px sans-serif; font-weight: 700; }}
    .small {{ fill: #4b5563; font: 12px sans-serif; }}
    .label {{ fill: #18212f; font: 14px sans-serif; }}
    .rowlabel {{ fill: #111827; font: 14px sans-serif; font-weight: 700; dominant-baseline: middle; }}
    .group {{ fill: #64748b; font: 13px sans-serif; font-weight: 700; text-anchor: middle; dominant-baseline: middle; }}
    .time {{ fill: #4b5563; font: 12px sans-serif; text-anchor: middle; }}
    .row {{ stroke: #e0e5eb; stroke-width: 1.2; }}
    .guide {{ stroke: #9aa4b2; stroke-width: 1.1; stroke-dasharray: 5 5; }}
    .bracket {{ stroke: #334155; stroke-width: 1.4; fill: none; }}
    .bar {{ stroke-width: 10; stroke-linecap: round; }}
    .decode0 {{ stroke: #0f766e; fill: #0f766e; }}
    .decode1 {{ stroke: #b45309; fill: #b45309; }}
    .comp {{ stroke: #7c3aed; fill: #7c3aed; }}
    .flip {{ stroke: #be123c; fill: #be123c; }}
    .wait {{ stroke: #334155; fill: #334155; }}
    .rx {{ fill: #2563eb; }}
    .muted {{ fill: #eef2f7; stroke: #cbd5e1; stroke-width: 1; }}
  </style>

  <rect class="bg" x="0" y="0" width="{width}" height="{height}"/>
  <text class="title" x="72" y="36">{title}</text>
  <text class="small" x="72" y="58">{html.escape(subtitle)}</text>
  <text class="small" x="72" y="76">rx2flip p50 = {stats.rxflip50:.1f} ms, p99 = {stats.rxflip99:.1f} ms.</text>

  <text class="group" transform="translate(28 172) rotate(-90)">RX + decoding</text>
  <text class="group" transform="translate(28 326) rotate(-90)">Composition</text>
  <text class="group" transform="translate(28 440) rotate(-90)">Display</text>

  <line class="row" x1="{left:.1f}" y1="112" x2="{right:.1f}" y2="112"/>
  <line class="row" x1="{left:.1f}" y1="172" x2="{right:.1f}" y2="172"/>
  <line class="row" x1="{left:.1f}" y1="232" x2="{right:.1f}" y2="232"/>
  <line class="row" x1="{left:.1f}" y1="296" x2="{right:.1f}" y2="296"/>
  <line class="row" x1="{left:.1f}" y1="356" x2="{right:.1f}" y2="356"/>
  <line class="row" x1="{left:.1f}" y1="416" x2="{right:.1f}" y2="416"/>
  <line class="row" x1="{left:.1f}" y1="464" x2="{right:.1f}" y2="464"/>

  <text class="rowlabel" x="72" y="112">RX</text>
  <text class="rowlabel" x="72" y="172">Tile 0</text>
  <text class="rowlabel" x="72" y="232">Tile 1</text>
  <text class="rowlabel" x="72" y="296">Blend</text>
  <text class="rowlabel" x="72" y="356">Queue</text>
  <text class="rowlabel" x="72" y="416">Flip</text>
  <text class="rowlabel" x="72" y="464">Latch</text>

{guide_svg}

  <circle class="rx" cx="{sx(rx_t):.1f}" cy="112" r="7"/>
  <text class="label" x="{sx(rx_t) + 14:.1f}" y="108">first frame datagram</text>
  <text class="small" x="{sx(rx_t) + 14:.1f}" y="125">RX start</text>

  <line class="decode0 bar" x1="{sx(rx_t):.1f}" y1="172" x2="{sx(dec0_t):.1f}" y2="172"/>
  <circle class="decode0" cx="{sx(dec0_t):.1f}" cy="172" r="7"/>
  <text class="label" x="{sx(dec0_t) + 14:.1f}" y="166">decoded</text>

  <line class="decode1 bar" x1="{sx(rx_t):.1f}" y1="232" x2="{sx(dec1_t):.1f}" y2="232"/>
  <circle class="decode1" cx="{sx(dec1_t):.1f}" cy="232" r="7"/>
  <text class="label" x="{sx(dec1_t) + 14:.1f}" y="226">decoded</text>

  <line class="comp bar" x1="{sx(pair_t):.1f}" y1="296" x2="{sx(issue_x):.1f}" y2="296"/>
  <circle class="comp" cx="{sx(issue_x):.1f}" cy="296" r="6"/>
  <text class="label" x="{sx(issue_x) + 14:.1f}" y="292">blend / compose</text>
  <text class="small" x="{sx(issue_x) + 14:.1f}" y="312">starts when both tiles are ready</text>

  <rect class="muted" x="{sx(pair_t):.1f}" y="341" width="{max(10.0, sx(issue_x) - sx(pair_t)):.1f}" height="30" rx="5"/>
  <text class="label" x="{sx(issue_x) + 14:.1f}" y="350">queue is inside pair-to-issue timing</text>

  <line class="flip bar" x1="{sx(issue_x):.1f}" y1="416" x2="{sx(submit_x):.1f}" y2="416"/>
  <circle class="flip" cx="{sx(submit_x):.1f}" cy="416" r="5"/>
  <text class="label" x="{sx(submit_x) + 14:.1f}" y="410">DRM flip ioctl</text>

  <line class="wait bar" x1="{sx(submit_x):.1f}" y1="464" x2="{sx(latch_x):.1f}" y2="464"/>
  <circle class="wait" cx="{sx(latch_x):.1f}" cy="464" r="7"/>
  <text class="label" x="{sx(latch_x) + 14:.1f}" y="460">scanout latch event</text>
  <text class="small" x="{sx(latch_x) + 14:.1f}" y="480">panel scanout and LCD response follow after this</text>

{label_svg}

  <path class="bracket" d="M{sx(dec0_t):.1f} 145 H{sx(dec1_t):.1f}"/>
  <path class="bracket" d="M{sx(dec0_t):.1f} 140 V150"/>
  <path class="bracket" d="M{sx(dec1_t):.1f} 140 V150"/>
  <text class="label" x="{sx(dec0_t) + 18:.1f}" y="139">tile skew = {stats.pair_skew:.1f} ms</text>

  <text class="label" x="442" y="548">event time since first frame UDP datagram on goggle</text>
</svg>
"""


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Render an SVG timeline from ml-pipeline ML_LATSTATS/ML_LATRAW logs."
    )
    parser.add_argument("log", type=Path, help="ml-pipeline log containing latency lines")
    parser.add_argument("-o", "--output", type=Path, help="output SVG path")
    parser.add_argument("--summary", type=Path,
                        help="also write the parsed medians as JSON (default: summary.json "
                             "beside the SVG)")
    parser.add_argument("--title", default="Goggle-side latency, RX to scanout latch")
    args = parser.parse_args()

    # A capture taken while no video was flowing is the common case worth reporting plainly: the
    # log exists and is full of other lines, so the emptiness is only visible here.
    try:
        stats = parse_log(args.log)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        print("       the pipeline logged no latency summaries; check that video was flowing and "
              "that /usrdata/missinglynk/latstats existed when ml-video started", file=sys.stderr)
        return 1

    output = args.output or args.log.with_name("goggle-latency-timeline.svg")
    output.write_text(render_svg(stats, args.title), encoding="utf-8")

    # The SVG is for reading, not for comparing: put the same medians somewhere a later run can
    # diff against without re-parsing a log whose format has since moved.
    summary = args.summary or output.with_name("summary.json")
    summary.write_text(json.dumps(asdict(stats), indent=2, sort_keys=True) + "\n",
                       encoding="utf-8")

    print(f"wrote {output}")
    print(f"wrote {summary}")
    if stats.phase_forced_us is not None:
        print(f"WARNING: vblank phase forcing was armed at {stats.phase_forced_us} us during this "
              f"capture; the waits below read high by up to one vsync")
    print(f"rx2flip p50={stats.rxflip50:.1f} ms p99={stats.rxflip99:.1f} ms")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
