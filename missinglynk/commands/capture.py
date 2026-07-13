"""Framebuffer capture: the `screenshot` subcommand."""
from __future__ import annotations

import argparse
import os
import re
import time

from .. import framebuffer
from .common import connect


def _parse_crop(spec: str) -> framebuffer.Region:
    """Parse a 'WxH' or 'WxH+X+Y' geometry string into (x, y, w, h)."""
    match: re.Match[str] | None = re.fullmatch(r"(\d+)x(\d+)(?:\+(\d+)\+(\d+))?", spec)
    if not match:
        raise ValueError(f"bad --crop '{spec}', expected WxH or WxH+X+Y")

    w, h, x, y = int(match[1]), int(match[2]), int(match[3] or 0), int(match[4] or 0)
    return (x, y, w, h)


def _cmd_screenshot(args: argparse.Namespace) -> int:
    name: str = args.output or f"missinglynk-{time.strftime('%Y%m%d-%H%M%S')}"
    if not name.endswith(".png"):
        name += ".png"

    # default into the screenshots/ dir unless an explicit path is given
    out_path: str = os.path.join("screenshots", name)
    if os.path.sep in name:
        out_path = name

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    region: framebuffer.Region | None = _parse_crop(args.crop) if args.crop else None

    with connect(args) as goggle:
        framebuffer.capture(goggle, out_path, page=args.page, region=region, full=args.full,
                            progress=not args.quiet)

    print("wrote", out_path)
    return 0


def register(subparsers: argparse._SubParsersAction) -> None:
    parser = subparsers.add_parser("screenshot", help="capture the OSD framebuffer to a PNG")
    parser.add_argument("-o", "--output",
                        help="output name/path (default screenshots/missinglynk-<ts>.png)")
    parser.add_argument("--page", type=int, choices=range(framebuffer.PAGE_COUNT), default=0,
                        help="which of the 3 stacked 1080-row pages to fetch "
                             "(triple-buffered; default 0 = displayed)")
    parser.add_argument("--crop", metavar="WxH+X+Y",
                        help="crop region within the page (default: the whole 1920x1080 page)")
    parser.add_argument("--full", action="store_true",
                        help="fetch the whole raw buffer (all 3 pages), no crop - slower")
    parser.add_argument("-q", "--quiet", action="store_true", help="no progress bar")
    parser.set_defaults(func=_cmd_screenshot)
