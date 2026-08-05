#!/usr/bin/env bash
# au-cam2enc.sh - decide whether camera buffers can reach the wave5 encoder without a copy.
#
# Three measurements, cheapest first, because only the last one costs a bring-up:
#
#   export    REQBUFS plus EXPBUF on the CVISP node, nothing streams. Answers whether a
#             `no-map shared-dma-pool` buffer can be exported as a dmabuf at all, which is the
#             question the whole recorder design hangs on.
#   encoder   the encoder fed dma-heap buffers in the camera's exact layout (three planes,
#             luma stride 2048 for 1920 pixels). No camera involved, so a refusal here is about
#             the geometry alone.
#   joined    camera buffers imported straight onto the encoder's OUTPUT queue, real frames,
#             bitstream written to /tmp and pulled here.
#
# Requires the camera modules to be loaded and the chain live: run au-prove-camera.sh first.
# This script does not load modules or program clocks, so it cannot half-configure anything.
#
# Usage: glue/camera/au-cam2enc.sh
# Env: MODE (all|export|encoder|static|hold|joined), FRAMES (60), BUFS (5), CODEC (hevc).
#      Target: the active device profile, AU_IP / AU_PASS override.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/../lib/au-camera.sh"

MODE="${MODE:-all}"
FRAMES="${FRAMES:-60}"
BUFS="${BUFS:-5}"
CODEC="${CODEC:-hevc}"
OUT="$REPO/out/au-cam2enc"

mkdir -p "$OUT"

echo "=== staging ==="
device_push "$REPO/native/build/ml-cam2enc" || exit 1
echo "  staged ml-cam2enc"

au_ensure_wave5

# The camera modules have to be up for the modes that open the capture node. Saying so is
# cheaper than a run that fails halfway with an error about a missing node. The encoder-only
# mode does not touch the camera, so it is allowed to run on its own.
if [ "$MODE" != encoder ]; then
	au_require_cvisp
fi

if [ "$MODE" = all ] || [ "$MODE" = export ]; then
	echo "=== export: can a no-map pool buffer become a dmabuf? ==="
	sshg "/tmp/ml-cam2enc -x -b $BUFS" </dev/null
	echo "  exit $?"
fi

if [ "$MODE" = all ] || [ "$MODE" = encoder ]; then
	echo "=== encoder: does wave5 take the camera's geometry? ==="
	sshg "/tmp/ml-cam2enc -e -c $CODEC" </dev/null
	echo "  exit $?"
fi

# The two narrowing variants. Both are cheap and neither needs its own bring-up, so on a boot
# where the joined run fails they are what say why.
if [ "$MODE" = static ]; then
	echo "=== static: camera buffers, camera stopped ==="
	sshg "/tmp/ml-cam2enc -s -n $FRAMES -b $BUFS -c $CODEC" </dev/null
	echo "  exit $?"
fi

if [ "$MODE" = hold ]; then
	echo "=== hold: camera streaming, buffer 0 kept out of its rotation ==="
	sshg "/tmp/ml-cam2enc -k -n $FRAMES -b $BUFS -c $CODEC" </dev/null
	echo "  exit $?"
fi

if [ "$MODE" = all ] || [ "$MODE" = joined ]; then
	echo "=== joined: camera to encoder, no copy ==="
	sshg "rm -f /tmp/cam.bit; /tmp/ml-cam2enc -n $FRAMES -b $BUFS -c $CODEC -o /tmp/cam.bit" </dev/null
	echo "  exit $?"

	if device_pull /tmp/cam.bit "$OUT/cam.bit"; then
		echo "  pulled $OUT/cam.bit, $(stat -c %s "$OUT/cam.bit") bytes"
		# Decode one frame so the run is judged on a picture rather than a byte count.
		if command -v ffmpeg >/dev/null 2>&1; then
			rm -f "$OUT/frame.png"
			ffmpeg -loglevel error -y -i "$OUT/cam.bit" -frames:v 1 "$OUT/frame.png" 2>&1 | head -5
			[ -s "$OUT/frame.png" ] && echo "  decoded $OUT/frame.png"
		else
			echo "  no ffmpeg on the host, bitstream not decoded"
		fi
	else
		echo "  no bitstream came back"
	fi
fi
