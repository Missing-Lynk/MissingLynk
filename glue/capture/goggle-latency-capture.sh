#!/usr/bin/env bash
# goggle-latency-capture.sh - capture ML_LATSTATS/ML_LATRAW logs and render the timeline.
#
# This is read-only on the device: it tails /var/log/ml-pipeline.log and records metadata. It does
# not start/stop services, change flag files, reboot, flash, or touch RF settings.
#
# PREREQ:
#   - goggle reachable at DEVICE_IP as root/ROOT_PASS
#   - ml-video is already running
#   - /usrdata/missinglynk/latstats exists for 1 Hz summary lines
#   - /usrdata/missinglynk/latraw exists for per-frame pair/flip timing and the display tail
#
# Usage:
#   glue/capture/goggle-latency-capture.sh
#   SECS=120 OUT=out/goggle-latency/manual-run glue/capture/goggle-latency-capture.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

SECS="${SECS:-60}"
OUT_BASE="${OUT_BASE:-$REPO/out/goggle-latency}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUT:-$OUT_BASE/$STAMP}"
LOG="$OUT/ml-pipeline.log"
META="$OUT/metadata.txt"
SVG="$OUT/goggle-latency-timeline.svg"
PLOTTER="$HERE/goggle-latency-plot.py"

# shellcheck source=../lib/ssh-opts.sh
. "$HERE/../lib/ssh-opts.sh"
# shellcheck source=../lib/capture-identity.sh
. "$HERE/../lib/capture-identity.sh"

mkdir -p "$OUT"

echo "writing $OUT"
echo "capturing ml-pipeline latency log for ${SECS}s"

{
    echo "recorded: $STAMP"
    echo "duration_secs: $SECS"
    echo "goggle_ip: $DEVICE_IP"
    echo
    capture_identity "$REPO"
    echo
    echo "--- services ---"
    sshg 'rc-service ml-video status 2>/dev/null || true; rc-service ml-hud status 2>/dev/null || true' 2>&1 || true
    echo
    echo "--- rf ---"
    sshg 'ip -br addr show sdio0 2>/dev/null || true; tail -20 /var/log/ml-linkd.log 2>/dev/null || true' 2>&1 || true
} > "$META"

# device_ssh_timeout returns 124 when the timeout expires; that is the expected success path for
# this bounded tail. The remote shell only reads the log.
if device_ssh_timeout "$((SECS + 5))" "tail -n 0 -F /var/log/ml-pipeline.log" > "$LOG"; then
    :
else
    rc=$?
    if [ "$rc" -ne 124 ]; then
        echo "log capture failed with exit $rc" >&2
        exit "$rc"
    fi
fi

if [ ! -s "$LOG" ]; then
    echo "captured log is empty: $LOG" >&2
    echo "check that ml-video is running and latstats/latraw are enabled" >&2
    exit 1
fi

if [ -x "$PLOTTER" ]; then
    "$PLOTTER" "$LOG" -o "$SVG"
else
    python3 "$PLOTTER" "$LOG" -o "$SVG"
fi

echo "log: $LOG"
echo "metadata: $META"
echo "timeline: $SVG"
