#!/usr/bin/env bash
# au-record.sh - record the camera through the wave5 encoder to a file and pull it.
#
# The validation recorder: one 1080p HEVC stream over the zero-copy dmabuf bridge, written to
# /tmp on the device, pulled here and remuxed to MP4. Judged by playing it.
#
# MUST be the boot's first encoder use: wave5 encoder instances created after a previous one
# was destroyed watchdog or garbage-encode (kernel/docs/wave5-encoder-instance-reuse.md). Run
# the chain bring-up first, then this, before anything else touches the encoder.
#
# /tmp on the device is a 32 MiB tmpfs; the recorder caps itself at CAP_MB and the file is
# removed from the device after the pull.
#
# Requires the camera chain live: CVDEPTH=3 glue/camera/au-v4l2-chain.sh first (26 s).
#
# Usage: glue/camera/au-record.sh
# Env: SECONDS_RUN (30), GOP (60), CAP_MB (24), OUT dir. Target from the device profile.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/../lib/au-camera.sh"

SECONDS_RUN="${SECONDS_RUN:-30}"
GOP="${GOP:-60}"
CAP_MB="${CAP_MB:-24}"
# CBR target in bps; 0 keeps the driver's constant-QP default. The wave5 driver ships with
# rate control OFF, which pixelates motion badly; the vendor runs 8 Mbps CBR. Mind /tmp:
# at 10 Mbps the 24 MB cap truncates past ~19 s.
BITRATE="${BITRATE:-10000000}"
OUT="${OUT:-$REPO/out/au-record}"
FRAMES=$((SECONDS_RUN * 60))

mkdir -p "$OUT"

echo "=== staging ==="
device_push "$REPO/native/build/ml-cam2enc" || exit 1

# Depth 1 re-arms one buffer per frame, so any encode latency reads a buffer
# mid-overwrite: torn frames with a clean drop counter. Refuse to record.
au_require_cvisp 3

echo "=== recording ${SECONDS_RUN}s (GOP $GOP, cap ${CAP_MB} MB, CBR $BITRATE) ==="
sshg "rm -f /tmp/rec.265; /tmp/ml-cam2enc -n $FRAMES -G $GOP -m $CAP_MB -R $BITRATE -o /tmp/rec.265" </dev/null | tail -5

echo "=== pulling ==="
if ! device_pull /tmp/rec.265 "$OUT/rec.265"; then
	echo "no recording came back" >&2
	exit 1
fi
sshg 'rm -f /tmp/rec.265' </dev/null

SIZE="$(stat -c %s "$OUT/rec.265")"
echo "  $OUT/rec.265, $SIZE bytes"

if command -v ffmpeg >/dev/null 2>&1; then
	ffmpeg -loglevel error -y -fflags +genpts -r 60 -i "$OUT/rec.265" -c copy "$OUT/rec.mp4"
	echo "  $OUT/rec.mp4"
	# The IRAP cadence, so a wrong GOP shows here instead of during a seek later.
	if command -v ffprobe >/dev/null 2>&1; then
		KEYS="$(ffprobe -loglevel error -select_streams v -show_entries frame=key_frame \
			-of csv=p=0 "$OUT/rec.mp4" | grep -c '^1')"
		FRAMECOUNT="$(ffprobe -loglevel error -select_streams v -count_frames \
			-show_entries stream=nb_read_frames -of csv=p=0 "$OUT/rec.mp4")"
		echo "  $FRAMECOUNT frames, $KEYS IRAPs"
	fi
else
	echo "  no ffmpeg on the host, raw .265 only"
fi
