#!/usr/bin/env bash
# au-node-streaming.sh - does a streaming capture node disturb the encoder?
#
# Every configuration that encoded cleanly so far had the capture node stopped, and every one
# that produced noise had it streaming. That variable was never isolated: the clean runs also
# differed in buffer source, and the noisy ones also differed in stride and in ownership.
#
# This run changes nothing but that. The encoder is fed dma-heap buffers holding a fixed pattern,
# so its bitstream is a pure function of the encoder and repeats byte for byte across runs. The
# camera is nowhere in the path. Three such runs are taken with the node idle, then three more
# with the node streaming into its own buffers next door.
#
#   hashes all equal          the node streaming is harmless, and the noise is about the camera
#                             buffers after all: everything above has to be revisited
#   streaming hashes differ   concurrent capture disturbs the encoder itself, and the camera
#                             buffers were never implicated
#
# Requires the camera modules loaded and the chain live: run au-v4l2-chain.sh first (26 s).
# Costs about 90 s on the device.
#
# Usage: glue/camera/au-node-streaming.sh
# Env: RUNS (3), FRAMES (60) per encoder run, LOAD_SECONDS (100) the background stream length.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/../lib/au-camera.sh"

RUNS="${RUNS:-3}"
FRAMES="${FRAMES:-60}"
LOAD_SECONDS="${LOAD_SECONDS:-100}"
LOAD_FRAMES=$((LOAD_SECONDS * 60))

echo "=== staging ==="
device_push "$REPO/native/build/ml-cam2enc" || exit 1

if ! sshg 'lsmod | grep -q "^ar_cvisp "' </dev/null
then
	echo "ar_cvisp is not loaded: run glue/camera/au-v4l2-chain.sh first" >&2
	exit 1
fi

# The whole STREAM line, so a differing hash can be read against the frame count and byte total
# that produced it: two runs that coded a different number of frames are not comparable at all.
run_phase() {
	local out=""
	local line
	local i=0

	while [ "$i" -lt "$RUNS" ]
	do
		line="$(sshg "/tmp/ml-cam2enc -e -n $FRAMES" </dev/null | grep '^STREAM:')"
		echo "  run $i: ${line:-NO STREAM LINE}" >&2
		out="$out${line#STREAM: }
"
		i=$((i + 1))
	done

	printf '%s' "$out"
}

echo "=== baseline: encoder alone, node idle ==="
IDLE="$(run_phase)"

echo "=== starting the capture node (${LOAD_SECONDS}s of streaming, no encoder) ==="
# The driver announces every STREAMON in the log, and that is the only evidence that survives:
# the background tool's own stdout sits in its stdio buffer until it exits.
BEFORE="$(sshg 'dmesg | grep -c "cvisp.*streaming:"' </dev/null | tr -d '\r')"

# The verify-only mode streams the camera and touches nothing else. setsid so the SSH channel
# closing does not take it with it; the PID is kept because pkill -x is unreliable on busybox.
sshg "rm -f /tmp/load.log /tmp/load.pid; setsid /tmp/ml-cam2enc -V -n $LOAD_FRAMES \
	>/tmp/load.log 2>&1 & echo \$! > /tmp/load.pid" </dev/null
sleep 5

# A phase that measured nothing is worse than no phase: prove the node is streaming before the
# runs that are supposed to be disturbed by it.
AFTER="$(sshg 'dmesg | grep -c "cvisp.*streaming:"' </dev/null | tr -d '\r')"
# shellcheck disable=SC2016  # the substitution belongs to the device shell, not this one
ALIVE="$(sshg 'kill -0 "$(cat /tmp/load.pid)" 2>/dev/null && echo yes' </dev/null | tr -d '\r')"

if [ "$ALIVE" != yes ] || [ "$AFTER" -le "$BEFORE" ]
then
	echo "  the background capture is not streaming (alive=${ALIVE:-no}, STREAMON $BEFORE -> $AFTER)" >&2
	echo "  aborting rather than reporting a phase that did nothing" >&2
	# shellcheck disable=SC2016  # the substitution belongs to the device shell, not this one
	sshg 'cat /tmp/load.log; kill "$(cat /tmp/load.pid)" 2>/dev/null' </dev/null
	exit 1
fi
sshg 'dmesg | grep "cvisp.*streaming:" | tail -1' </dev/null

echo "=== same encoder runs, node streaming ==="
BUSY="$(run_phase)"

echo "=== stopping the capture node ==="
# shellcheck disable=SC2016  # the substitution belongs to the device shell, not this one
sshg 'kill "$(cat /tmp/load.pid)" 2>/dev/null; sleep 1; tail -3 /tmp/load.log' </dev/null

echo "=== verdict ==="
NIDLE="$(printf '%s\n' "$IDLE" | grep -c . )"
NBUSY="$(printf '%s\n' "$BUSY" | grep -c . )"
UIDLE="$(printf '%s\n' "$IDLE" | sort -u | grep -c . )"
UBUSY="$(printf '%s\n' "$BUSY" | sort -u | grep -c . )"
UBOTH="$(printf '%s\n%s\n' "$IDLE" "$BUSY" | sort -u | grep -c . )"

echo "  idle:      $NIDLE runs, $UIDLE distinct results"
echo "  streaming: $NBUSY runs, $UBUSY distinct results"

if [ "$UIDLE" != 1 ]
then
	echo "  INCONCLUSIVE: the encoder is not even repeatable on its own"
elif [ "$UBOTH" = 1 ]
then
	echo "  NODE IS INNOCENT: identical bitstream with the node streaming"
else
	echo "  NODE DISTURBS THE ENCODER: same input, different bitstream while capture runs"
fi
