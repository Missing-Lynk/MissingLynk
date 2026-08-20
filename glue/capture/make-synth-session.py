#!/usr/bin/env python3
"""
make-synth-session.py - generate a synthetic RF video session (.rfdump) for ml-rf-replay.

A synthetic pipeline testbed, an alternative to a real bench capture:
a testsrc2 1920x1080@60 clip with a huge frame counter drawn ACROSS the tile seam
(rows ~460-620), split into the two vendor tiles (c0 = rows 0..559, c1 = rows 528..1079,
32-row overlap), encoded with the FPV shape (H.265, keyint 60, no B, ref 1), and wrapped
in bit-exact RF datagram framing (36 B header + ES + 4 B trailer, header facts verified
against a real capture; res field = 0x07800438 = 1920x1080 composite for BOTH channels).

FrameIds run 0..N-1 and match across channels; TimeStap = frame * 1000/60 ms; isIdrStream
follows the encoder's actual keyframes. The result loops cleanly: ml-rf-replay --loop wraps
FrameId N-1 -> 0, ml-pipeline detects the regression, re-arms its IDR gate, and frame 0 is
an IDR.

Usage: make-synth-session.py out.rfdump [--secs 10]
"""
import argparse
import json
import struct
import subprocess
import tempfile
import zlib
from pathlib import Path

FPS = 60
MAGIC, TAIL = 0x12345678, 0x87654321
RES = 0x07800438            # 1920<<16 | 1080, same value on both channels in real captures
TILES = [                   # (crop_h, crop_y)
    (560, 0),
    (552, 528),
]


# Content presets, distinct along the axes an FPV feed varies on: sustained motion everywhere in
# the frame, near-static hover, and hard per-frame scene change (every pixel new, worst case for
# the P-frame budget). All carry the frame counter across the tile seam.
COUNTER = ("drawtext=text='%{n}':fontsize=160:fontcolor=white:borderw=6:bordercolor=black:"
           "x=(w-tw)/2:y=460")
PRESETS = {
    "flight": "testsrc2=size=1920x1080:rate=60," + COUNTER,
    "hover":  "smptehdbars=size=1920x1080:rate=60," + COUNTER,
    "chaos":  "mandelbrot=size=1920x1080:rate=60:end_pts=100000," + COUNTER,
}


def encode_tile(src_filter, h, y, secs, mbit, out):
    # VBV bounds every access unit under the wire format's u16 payload length (and a UDP
    # datagram): one AU per datagram, so an unbounded IDR does not fit. 480 kbit = 60 KB ceiling.
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", src_filter, "-t", str(secs),
        "-vf", f"crop=1920:{h}:0:{y}",
        "-c:v", "libx265", "-preset", "fast",
        "-x265-params", (f"keyint={FPS}:min-keyint={FPS}:bframes=0:ref=1:scenecut=0"
                         f":vbv-maxrate={mbit * 1000}:vbv-bufsize=350:strict-cbr=1"),
        "-pix_fmt", "yuv420p", "-b:v", f"{mbit}M", "-f", "hevc", str(out),
    ], check=True)


def split_aus(es_path):
    """[(bytes, is_keyframe)] per frame, using ffprobe packet sizes over the elementary stream."""
    probe = subprocess.run(
        ["ffprobe", "-loglevel", "error", "-show_packets", "-of", "json", str(es_path)],
        check=True, capture_output=True, text=True)
    pkts = json.loads(probe.stdout)["packets"]
    data = Path(es_path).read_bytes()
    aus, off = [], 0
    for p in pkts:
        sz = int(p["size"])
        aus.append((data[off:off + sz], "K" in p.get("flags", "")))
        off += sz

    if off != len(data):
        # trailing bytes (e.g. end-of-seq NAL) ride along with the last AU
        es, k = aus[-1]
        aus[-1] = (es + data[off:], k)

    return aus


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--secs", type=int, default=10)
    ap.add_argument("--preset", choices=sorted(PRESETS), default="flight")
    ap.add_argument("--bitrate", type=int, default=6, metavar="MBIT")
    args = ap.parse_args()

    src = PRESETS[args.preset]

    with tempfile.TemporaryDirectory() as td:
        tiles = []
        for i, (h, y) in enumerate(TILES):
            out = Path(td) / f"tile{i}.h265"
            encode_tile(src, h, y, args.secs, args.bitrate, out)
            tiles.append(split_aus(out))

        n = min(len(t) for t in tiles)
        with open(args.out, "wb") as f:
            for fid in range(n):
                for chn, aus in enumerate(tiles):
                    es, key = aus[fid]
                    # One AU per datagram: the record length is u16 and the replayer sends each
                    # record as a single UDP datagram, so an AU that VBV failed to bound is a
                    # generation error, not something to write through.
                    if len(es) + 44 > 65000:
                        raise SystemExit(f"[synth] tile{chn} frame {fid} AU is {len(es)} B, "
                                         f"over the datagram bound - lower --bitrate")
                    hdr = struct.pack("<8I", MAGIC, len(es), chn, 1 if key else 0,
                                      fid, fid * 1000 // FPS, RES, TAIL)
                    hdr += struct.pack("<I", zlib.crc32(hdr))
                    delta = (16667 if chn == 0 and fid > 0 else 300 if chn == 1 else 0)
                    payload = hdr + es + struct.pack("<I", TAIL)  # trailer 21 43 65 87 on the wire
                    f.write(struct.pack("<IHH", delta, 10001, len(payload)))
                    f.write(payload)

        print(f"[synth] {n} frames x2 tiles -> {args.out} "
              f"({Path(args.out).stat().st_size // 1024} KiB)")

        if n < args.secs * FPS:
            print(f"[synth] note: encoder emitted {n} frames (< {args.secs * FPS})")


if __name__ == "__main__":
    main()
