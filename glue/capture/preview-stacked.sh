#!/usr/bin/env bash
# preview-stacked.sh - reconstruct the full frame from a capture by decoding both
# encode channels (vertical tiles) and stacking them: ChnIdx 0 on top, ChnIdx 1
# below. Writes an mp4 (and plays it if ffplay is present). Host-side, needs ffmpeg.
#
# Usage:  glue/capture/preview-stacked.sh <sdio0-capture.pcap> [out.mp4]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
DECODE="$REPO/libre/tools/ml-rf-udp/ml-rf-udp.py"
PCAP="${1:?usage: preview-stacked.sh <capture.pcap> [out.mp4]}"
OUT="${2:-${PCAP%.pcap}.stacked.mp4}"
TMP="$(dirname "$OUT")"
C0="$TMP/.preview.c0.h265"
C1="$TMP/.preview.c1.h265"

command -v ffmpeg >/dev/null || { echo "ffmpeg not installed" >&2; exit 1; }

echo "[*] demux channel 0 (top tile) + channel 1 (bottom tile) ..."
python3 "$DECODE" --chn 0 --h265 "$C0" "$PCAP" | grep -E "DECODABLE|wrote" || true
python3 "$DECODE" --chn 1 --h265 "$C1" "$PCAP" | grep -E "DECODABLE|wrote" || true

echo "[*] decoding + vertical-stacking to $OUT ..."
# both tiles are 1920 wide (vstack needs equal width); pair frames by index
ffmpeg -v warning -y \
    -i "$C0" -i "$C1" \
    -filter_complex "[0:v][1:v]vstack=inputs=2[v]" \
    -map "[v]" -c:v libx264 -pix_fmt yuv420p -r 30 "$OUT"
rm -f "$C0" "$C1"
echo "[+] wrote $OUT"

if command -v ffplay >/dev/null; then
    echo "[*] playing (close the window to exit) ..."
    ffplay -autoexit -loglevel error "$OUT" || true
else
    echo "    (no ffplay; open $OUT in any player)"
fi
