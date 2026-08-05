#!/usr/bin/env bash
# au-enc-repeat.sh - open the encoder N times in a row and see whether every instance works.
#
# The heap-source mode encodes a fixed pattern, so every instance of one build must produce the
# same bitstream. It does not: instances alternate strictly between a full 60-frame stream and
# one that codes nothing at all. This runs the sequence long enough to see whether the
# alternation holds, and prints what the driver said in between.
#
# No camera is opened, so this says nothing about the capture path and does not need the chain up.
#
# Usage: glue/camera/au-enc-repeat.sh
# Env: RUNS (8), FRAMES (60).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/../lib/au-camera.sh"

RUNS="${RUNS:-8}"
FRAMES="${FRAMES:-60}"
EXTRA="${EXTRA:-}"

echo "=== staging ==="
device_push "$REPO/native/build/ml-cam2enc" || exit 1

sshg 'dmesg -c >/dev/null' </dev/null

i=0
while [ "$i" -lt "$RUNS" ]; do
	line="$(sshg "/tmp/ml-cam2enc -e -n $FRAMES $EXTRA" </dev/null | grep '^STREAM:')"
	echo "run $i: ${line:-NO STREAM LINE}"
	sshg 'dmesg -c | grep -i "wave5\|vpu" | head -6' </dev/null | sed 's/^/    /'
	i=$((i + 1))
done
