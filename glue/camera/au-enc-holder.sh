#!/usr/bin/env bash
# au-enc-holder.sh - does a live second instance prevent the create/destroy corruption?
#
# Encoder instances created after a previous one was destroyed watchdog or garbage-encode
# (see au-enc-repeat.sh). The goggle rebuilds its DVR encoder per recording without ever
# hitting this, and the one structural difference is that its RF tile decoders keep the
# firmware's instance count above zero the whole time. Every failing air-unit experiment
# took the firmware through the zero-instance state between runs.
#
# This isolates that variable. A background holder instance (480p, paced to ~30 fps) stays
# live while the usual 60-frame instances are created and destroyed around it:
#
#   alternation with the holder live      the zero-instance theory is dead
#   clean with it, alternating without    corruption happens at last-destroy or
#                                         first-create-from-zero, and the fix is to keep
#                                         any instance alive across encoder restarts
#
# The holder's own first start may itself be poisoned by the baseline runs; a watchdogged
# start clears the state, so it is simply started again.
#
# No camera, no chain bring-up. About 2 minutes on the device.
#
# Usage: glue/camera/au-enc-holder.sh
# Env: RUNS (6) foreground runs with the holder live, FRAMES (60).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/../lib/au-camera.sh"

RUNS="${RUNS:-6}"
FRAMES="${FRAMES:-60}"

echo "=== staging ==="
device_push "$REPO/native/build/ml-cam2enc" || exit 1

phase() {
	local tag="$1"
	local count="$2"
	local i=0

	while [ "$i" -lt "$count" ]
	do
		sshg "/tmp/ml-cam2enc -e -n $FRAMES" </dev/null | grep '^STREAM:' | sed "s/^/  $tag $i: /"
		i=$((i + 1))
	done
}

echo "=== baseline: no holder (expect alternation) ==="
phase base 4

echo "=== starting the holder (480p, paced, stays live) ==="
started=0
for attempt in 0 1 2
do
	sshg 'rm -f /tmp/holder.log /tmp/holder.pid; setsid /tmp/ml-cam2enc -e -g 640x480 -n 100000 -w 30 \
		>/tmp/holder.log 2>&1 & echo $! > /tmp/holder.pid' </dev/null
	sleep 3
	# shellcheck disable=SC2016  # the substitution belongs to the device shell, not this one
	if sshg 'kill -0 "$(cat /tmp/holder.pid)" 2>/dev/null && grep -q "coded frame 0" /tmp/holder.log' </dev/null
	then
		started=1
		echo "  holder live (attempt $attempt)"
		break
	fi
	echo "  holder died at start (attempt $attempt), poisoned start expected once; retrying"
done

if [ "$started" != 1 ]
then
	echo "  holder never came up, aborting" >&2
	sshg 'cat /tmp/holder.log' </dev/null
	exit 1
fi

echo "=== foreground create/destroy cycles with the holder live ==="
phase held "$RUNS"

echo "=== stopping the holder ==="
# shellcheck disable=SC2016  # the substitution belongs to the device shell, not this one
sshg 'kill "$(cat /tmp/holder.pid)" 2>/dev/null' </dev/null
sleep 1

echo "=== after: no holder again (expect alternation back) ==="
phase after 4
