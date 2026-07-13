"""
Fetch and decode the goggle's OSD framebuffer (/dev/fb0).

fb0 is the OSD/UI overlay only (the camera video is a separate HW layer, see
docs/01). Format is ARGB4444 (16bpp, 4 bits each); the line stride is padded
wider than the visible width (2048 px vs 1920). Layout is like ffmpeg's
`rgb444le`: a little-endian u16 is (msb) 4X 4R 4G 4B (lsb); the alpha nibble is
dropped. We expand each 4-bit channel to 8-bit by replication (n*17, 0xF->255 =
true white). Cross-platform: numpy + Pillow, no ffmpeg.

The buffer (`virtual_size` 1920x3240, `yres` 1080) is 3 stacked 1920x1080 pages
(triple-buffered, confirmed on hardware; it is not a stereo / two-eye buffer).
The visible OSD is in the displayed page, so we capture page 0 (the top
1920x1080) by default. We fetch only the rows the requested region needs, via
`dd`, so a default capture transfers far less than the full 13.3 MB buffer.
`full=True` dumps the whole raw 3240-row buffer for debugging.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from numpy.typing import NDArray
from PIL import Image

from .connection import Goggle
from .progress import printer, ProgressCb

# crop / region geometry: (x, y, w, h)
Region = tuple[int, int, int, int]

# the buffer is 3 stacked full-screen pages (triple-buffered, see docstring)
PAGE_COUNT: int = 3


@dataclass
class FbGeometry:
    width: int      # visible width (1920)
    height: int     # full buffer height (3240 = 3 stacked 1080-row pages, triple-buffered)
    stride_px: int  # padded line width in pixels (2048)
    bpp: int        # bits per pixel (16)

    @property
    def stride_bytes(self) -> int:
        return self.stride_px * (self.bpp // 8)

    @property
    def page_height(self) -> int:
        return self.height // PAGE_COUNT


def read_geometry(goggle: Goggle) -> FbGeometry:
    virtual_size: str = goggle.read_file("/sys/class/graphics/fb0/virtual_size").decode().strip()
    width, height = (int(x) for x in virtual_size.replace(",", " ").split()[:2])
    bpp: int = int(goggle.read_file("/sys/class/graphics/fb0/bits_per_pixel").decode().strip())
    try:
        stride_bytes: int = int(
            goggle.read_file("/sys/class/graphics/fb0/stride").decode().strip())
        stride_px: int = stride_bytes // (bpp // 8)
    except Exception as e:
        raise RuntimeError(
            "could not read /sys/class/graphics/fb0/stride; cannot size the fetch") from e

    return FbGeometry(width=width, height=height, stride_px=stride_px, bpp=bpp)


def decode_argb4444(raw: bytes, width: int, height: int, stride_px: int) -> NDArray[np.uint8]:
    pixels: NDArray[np.uint16] = np.frombuffer(raw, dtype="<u2")
    needed: int = stride_px * height
    if pixels.size < needed:
        raise ValueError(f"short framebuffer: {pixels.size} u16 < {needed} expected")

    pixels = pixels[:needed].reshape(height, stride_px)[:, :width]
    red: NDArray[np.uint8] = ((pixels >> 8) & 0xF).astype(np.uint8) * 17
    green: NDArray[np.uint8] = ((pixels >> 4) & 0xF).astype(np.uint8) * 17
    blue: NDArray[np.uint8] = (pixels & 0xF).astype(np.uint8) * 17

    return np.dstack([red, green, blue])


def fetch(goggle: Goggle, page: int = 0, region: Region | None = None,
          full: bool = False, progress: bool = True) -> NDArray[np.uint8]:
    """
    Pull a region of fb0 via `dd` and return a decoded RGB array.

    `page` selects one of the PAGE_COUNT stacked full-screen pages (0 = the
    displayed one). `region` = (x, y, w, h) within that page; only rows
    [y, y+h) are transferred, then columns [x, x+w) are kept. `region=None`
    fetches the whole page. `full=True` fetches the entire raw buffer (all
    pages), ignoring `page` and `region`.
    """
    geometry: FbGeometry = read_geometry(goggle)

    if full:
        first_row, row_count, x, w = 0, geometry.height, 0, geometry.width
        label: str = "fetch fb0 (full buffer)"
    else:
        if not 0 <= page < PAGE_COUNT:
            raise ValueError(f"page must be 0..{PAGE_COUNT - 1}")
        x, y, w, h = (0, 0, geometry.width, geometry.page_height) if region is None else region
        w = min(w, geometry.width - x)
        h = min(h, geometry.page_height - y)
        first_row, row_count = page * geometry.page_height + y, h
        label = f"fetch fb0 (page {page})"

    expected: int = row_count * geometry.stride_bytes
    command: str = (f"dd if=/dev/fb0 bs={geometry.stride_bytes} "
                    f"skip={first_row} count={row_count} 2>/dev/null")
    progress_cb: ProgressCb | None = printer(label) if progress else None
    raw: bytes = goggle.read_stream(command, expected_bytes=expected, on_progress=progress_cb)
    rgb: NDArray[np.uint8] = decode_argb4444(raw, geometry.width, row_count, geometry.stride_px)

    return rgb[:, x:x + w]


def capture(goggle: Goggle, out_path: str, page: int = 0,
            region: Region | None = None, full: bool = False,
            progress: bool = True) -> str:
    rgb: NDArray[np.uint8] = fetch(goggle, page=page, region=region, full=full,
                                   progress=progress)
    Image.fromarray(rgb, "RGB").save(out_path)

    return out_path
