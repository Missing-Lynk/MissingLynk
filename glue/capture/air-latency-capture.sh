#!/usr/bin/env bash
# air-latency-capture.sh - capture ml-air-video latency logs from the air unit.
#
# This is read-only on the device: it records /tmp/cam-tx.log or /var/log/ml-air-camera.log and
# metadata. Enable the instrumentation in the producer with:
#   EXTRA_ENV='ML_AIR_LATSTATS=1 ML_AIR_LATRAW=1' TX=1 glue/camera/au-cam-tx.sh
#
# Usage:
#   glue/capture/air-latency-capture.sh
#   SECS=120 LOG_PATH=/tmp/cam-tx.log OUT=out/air-latency/manual-run glue/capture/air-latency-capture.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

SECS="${SECS:-60}"
OUT_BASE="${OUT_BASE:-$REPO/out/air-latency}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUT:-$OUT_BASE/$STAMP}"
LOG="$OUT/ml-air-video.log"
META="$OUT/metadata.txt"
LOG_PATH="${LOG_PATH:-/tmp/cam-tx.log}"

# shellcheck source=../lib/au-camera.sh
. "$HERE/../lib/au-camera.sh"
# shellcheck source=../lib/capture-identity.sh
. "$HERE/../lib/capture-identity.sh"

mkdir -p "$OUT"

echo "writing $OUT"
echo "capturing $LOG_PATH for ${SECS}s"

{
    echo "recorded: $STAMP"
    echo "duration_secs: $SECS"
    echo "air_ip: $DEVICE_IP"
    echo "log_path: $LOG_PATH"
    echo
    capture_identity "$REPO"
    echo
    echo "--- services ---"
    sshg 'rc-service ml-air-camera status 2>/dev/null || true; rc-service ml-air-link status 2>/dev/null || true' 2>&1 || true
    echo
    echo "--- process ---"
    # shellcheck disable=SC2016  # the loop variables expand on the device, inside the remote shell
    sshg 'for p in /proc/[0-9]*/comm; do read -r c < "$p" || continue; [ "$c" = ml-air-video ] && echo "${p%/comm}"; done' 2>&1 || true
    echo
    echo "--- rf ---"
    sshg 'ip -br addr show sdio0 2>/dev/null || true; tail -20 /var/log/ml-linkd.log 2>/dev/null || true' 2>&1 || true
} > "$META"

if device_ssh_timeout "$((SECS + 5))" "tail -n 0 -F '$LOG_PATH'" > "$LOG"; then
    :
else
    rc=$?
    if [ "$rc" -ne 124 ]; then
        echo "log capture failed with exit $rc" >&2
        exit "$rc"
    fi
fi

if ! grep -q "${TAG:-\\[ml-air-video\\]} lat" "$LOG"; then
    echo "captured no latency lines in $LOG" >&2
    echo "start ml-air-video with ML_AIR_LATSTATS=1 or ML_AIR_LATRAW=1" >&2
    exit 1
fi

echo "log: $LOG"
echo "metadata: $META"
