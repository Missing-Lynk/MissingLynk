#!/usr/bin/env python3
"""
Turn CVISP plane dumps into viewable PNGs.

ml-isploop --dump writes one file per plane: .0 is luma at stride 2048 for a 1920 wide frame,
.1 and .2 are the chroma planes at stride 1024 for 960 wide, half height. Only the active part
of each row is real; the rest of the stride is whatever was in DRAM, which has produced a false
positive before, so the padding is cropped rather than rendered.

Writes a greyscale PNG from luma always, and a colour PNG as well when both chroma planes are
present and the right size.

Usage:
  planes2png.py <dump-prefix> <out-prefix>
"""

import os
import struct
import sys
import zlib

Y_STRIDE, Y_WIDTH, Y_HEIGHT = 2048, 1920, 1080
C_STRIDE, C_WIDTH, C_HEIGHT = 1024, 960, 540


def write_png(path, width, height, rows, colour):
    """Minimal PNG writer. rows is a list of bytes, each already width*channels long."""
    raw = b"".join(b"\x00" + bytes(r) for r in rows)

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2 if colour else 0, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))

    with open(path, "wb") as f:
        f.write(png)

    return len(png)


def crop(data, stride, width, height):
    if len(data) < stride * height:
        return None

    return [data[r * stride : r * stride + width] for r in range(height)]


def main():
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <dump-prefix> <out-prefix>")
    src, dst = sys.argv[1], sys.argv[2]

    ypath = src + ".0"
    if not os.path.exists(ypath):
        sys.exit(f"{ypath}: missing, nothing to render")

    with open(ypath, "rb") as handle:
        y = crop(handle.read(), Y_STRIDE, Y_WIDTH, Y_HEIGHT)

    if y is None:
        sys.exit(f"{ypath}: too short for {Y_WIDTH}x{Y_HEIGHT} at stride {Y_STRIDE}")

    n = write_png(dst + "-luma.png", Y_WIDTH, Y_HEIGHT, y, colour=False)
    flat = b"".join(y)
    mean = sum(flat) / len(flat)
    floor = 100.0 * (flat.count(0) + flat.count(1)) / len(flat)
    print(f"{dst}-luma.png  {n} bytes   mean {mean:.1f}   at luma 0-1 {floor:.1f}%")

    # Distinct values in the active area is the honest "is there a picture here" number: a dead
    # pipeline gives one or two, a real frame gives hundreds.
    print(f"  distinct luma values: {len(set(flat))}")

    # An all-zero plane means the buffer was never written, and it has to be called out rather
    # than left to the picture. Zero chroma is not neutral chroma, neutral is 128, so an
    # untouched YUV buffer renders as solid green rather than black: a plausible-looking image
    # that reads as a colour fault instead of as no data at all.
    if len(set(flat)) == 1:
        print(f"  WARNING: luma is entirely {flat[0]}, the buffer was never written."
              " A colour render of this is solid green, not an image.")

    upath, vpath = src + ".1", src + ".2"
    if not (os.path.exists(upath) and os.path.exists(vpath)):
        print("  (no chroma planes, greyscale only)")
        return

    with open(upath, "rb") as handle:
        u = crop(handle.read(), C_STRIDE, C_WIDTH, C_HEIGHT)

    with open(vpath, "rb") as handle:
        v = crop(handle.read(), C_STRIDE, C_WIDTH, C_HEIGHT)

    if u is None or v is None:
        print("  (chroma planes too short, greyscale only)")
        return

    rows = []
    for r in range(Y_HEIGHT):
        yr, ur, vr = y[r], u[r // 2], v[r // 2]
        out = bytearray(Y_WIDTH * 3)
        for c in range(Y_WIDTH):
            yy, uu, vv = yr[c] - 16, ur[c // 2] - 128, vr[c // 2] - 128
            rr = (298 * yy + 409 * vv + 128) >> 8
            gg = (298 * yy - 100 * uu - 208 * vv + 128) >> 8
            bb = (298 * yy + 516 * uu + 128) >> 8
            out[c * 3] = 0 if rr < 0 else (255 if rr > 255 else rr)
            out[c * 3 + 1] = 0 if gg < 0 else (255 if gg > 255 else gg)
            out[c * 3 + 2] = 0 if bb < 0 else (255 if bb > 255 else bb)

        rows.append(out)

    n = write_png(dst + "-colour.png", Y_WIDTH, Y_HEIGHT, rows, colour=True)
    print(f"{dst}-colour.png  {n} bytes")


if __name__ == "__main__":
    main()
