#!/usr/bin/env bash
# au-ae-cover-test.sh - record the AE loop reacting to the lens being covered and uncovered.
#
# The closed-loop validation: ml-aed runs at full authority (the recovered vendor law, no step
# clamp) while the wave5 encoder records the result, so the video and the decision log describe
# the same frames. Judged by playing it: brightness must recover after each transition without
# hunting, and the ladders must track the gain without artifacts.
#
# MUST be the boot's first encoder use, like au-record.sh: a wave5 instance created after a
# previous one was destroyed watchdogs or garbage-encodes. This script brings the chain up
# itself so the boot goes straight from power-on to the recording.
#
# The recorder is the streaming client; ml-aed only reads statistics through debugfs, so it is
# started first and left running for the whole take.
#
# Usage: glue/camera/au-ae-cover-test.sh
# Env: SECONDS_RUN (30), BITRATE (6000000, sized so 30 s fits the 24 MB /tmp cap), START_INDEX.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$HERE/../lib/au-camera.sh"

SECONDS_RUN="${SECONDS_RUN:-30}"
BITRATE="${BITRATE:-6000000}"
START_INDEX="${START_INDEX:-317}"
OUT="${OUT:-$REPO/out/au-ae-cover}"

mkdir -p "$OUT"

# Depth 3 is mandatory for recording: depth 1 re-arms one buffer per frame, so the encoder
# reads mid-overwrite and the result tears with a clean drop counter.
echo "=== chain bring-up (CVDEPTH=3) ==="
CVDEPTH=3 "$HERE/au-v4l2-chain.sh" || exit 1

echo "=== starting ml-aed at full authority ==="
sshg "rm -f /tmp/ml-aed.log
setsid /tmp/ml-aed --start-index $START_INDEX --verbose >/tmp/ml-aed.log 2>&1 &
sleep 2
head -2 /tmp/ml-aed.log" </dev/null || exit 1

echo
echo "=== COVER AND UNCOVER THE LENS NOW, twice, holding each about five seconds ==="
echo

SECONDS_RUN="$SECONDS_RUN" BITRATE="$BITRATE" OUT="$OUT" "$HERE/au-record.sh" || exit 1

echo "=== pulling the decision log ==="
# shellcheck disable=SC2016  # expansion happens in the device shell, not this one.
sshg 'for p in /proc/[0-9]*/comm; do
    read -r c < "$p" || continue
    [ "$c" = ml-aed ] && kill "${p%/comm}"
done' </dev/null 2>/dev/null || true
device_pull /tmp/ml-aed.log "$OUT/ml-aed.log" || exit 1

echo "=== decision summary ==="
awk '{ for (i = 1; i <= NF; i++) {
           if ($i == "luma") luma = $(i + 1)
           if ($i == "index") idx = $(i + 1)
       }
       if (NR == 1 || idx != last) { print "  " $0; last = idx } }' "$OUT/ml-aed.log" | head -40

echo "  ($(wc -l < "$OUT/ml-aed.log") decisions logged, $(awk '{for(i=1;i<=NF;i++) if($i=="step" && $(i+1) != 0) c++} END {print c+0}' "$OUT/ml-aed.log") of them moving the index)"
