#!/usr/bin/env bash
# au-sample-frames.sh - dump a handful of camera frames spread over a run, and render them.
#
# Answers one question by eye rather than by statistic: does the capture path hand out sound
# buffers? No encoder is opened, so nothing downstream can be blamed for what the pictures show.
#
# Luma only, because a full frame is 3.34 MB across three planes and /tmp is a 32 MB tmpfs;
# 2.2 MB per frame leaves room for five with margin. Each frame is pulled and removed from the
# device as it is rendered, so the peak on /tmp is what the run itself wrote.
#
# Requires the camera modules loaded and the chain live: run au-v4l2-chain.sh first (26 s).
#
# Usage: glue/camera/au-sample-frames.sh
# Env: COUNT (5), SECONDS_RUN (60), OUT dir. Target from the active device profile.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/../lib/au-camera.sh"

COUNT="${COUNT:-5}"
SECONDS_RUN="${SECONDS_RUN:-60}"
OUT="${OUT:-$REPO/out/au-sample}"
FRAMES=$((SECONDS_RUN * 60))

mkdir -p "$OUT"
rm -f "$OUT"/frame-*.png

echo "=== staging ==="
device_push "$REPO/native/build/ml-cam2enc" || exit 1

au_require_cvisp

echo "=== sampling $COUNT frames over ${SECONDS_RUN}s ==="
sshg "rm -f /tmp/s.*; /tmp/ml-cam2enc -D /tmp/s -N $COUNT -n $FRAMES" </dev/null

echo "=== pulling ==="
i=0
while [ "$i" -lt "$COUNT" ]
do
	tag="$(printf '%02d' "$i")"
	if device_pull "/tmp/s.$tag.0" "$OUT/frame-$tag.raw"
	then
		# Raw luma at the block's 2048-byte stride, cropped to the 1920 the block writes.
		ffmpeg -loglevel error -y -f rawvideo -pix_fmt gray -s 2048x1080 \
			-i "$OUT/frame-$tag.raw" -vf "crop=1920:1080:0:0" "$OUT/frame-$tag.png"
		rm -f "$OUT/frame-$tag.raw"
		sshg "rm -f /tmp/s.$tag.0" </dev/null
		echo "  $OUT/frame-$tag.png"
	fi
	i=$((i + 1))
done
