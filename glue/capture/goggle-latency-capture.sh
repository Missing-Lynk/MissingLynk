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
PLOTTER="$HERE/goggle-latency-plot.py"

# shellcheck source=../lib/ssh-opts.sh
. "$HERE/../lib/ssh-opts.sh"
# shellcheck source=../lib/capture-identity.sh
. "$HERE/../lib/capture-identity.sh"

# Name the run by capture time then the build it measured, so a listing is in
# chronological order. The build is taken from the device rather than the host tree: the
# goggle can be running an older bundle than the checkout, and it is the flashed bytes that produced
# the numbers. ML_VERSION is the wrapper describe for bundles that carry one, and the kernel
# describe for older ones; either way it is the string that identifies the image.
# shellcheck disable=SC2016  # ML_VERSION is sourced and expanded on the device, in the remote shell
DEVICE_VERSION="$(sshg '. /etc/ml-release 2>/dev/null; echo "$ML_VERSION"' </dev/null 2>/dev/null |
                  tr -cd 'A-Za-z0-9._-')"
OUT="${OUT:-$OUT_BASE/$STAMP-${DEVICE_VERSION:-unknown}}"
LOG="$OUT/ml-pipeline.log"
META="$OUT/metadata.txt"
SVG="$OUT/goggle-latency-timeline.svg"

mkdir -p "$OUT"

echo "writing $OUT"
echo "capturing ml-pipeline latency log for ${SECS}s"

# The conditions that decide whether two captures are comparable, read from the process that was
# measured rather than from the flag directory: ml-video-up reads those flags only at ml-video
# start, so one changed since then is visible on disk and has no effect on the running pipeline.
# shellcheck disable=SC2016  # the pid lookup, /proc read and clock read expand on the device
sshg 'p=$(pgrep ml-pipeline | tail -1)
      env=""
      [ -n "$p" ] && env=$(tr "\0" "\n" < "/proc/$p/environ")
      val() { printf %s "$env" | sed -n "s/^$1=//p" | tail -1; }
      echo "pixclk_hz=$(cat /sys/kernel/debug/ar9311_pixclk_rate 2>/dev/null)"
      echo "pace_hz=$(val ML_PACE)"
      echo "seam=$(val ML_SEAM)"
      echo "phase_force_us=$(val ML_PHASE_FORCE)"
      p=$(pgrep ml-pipeline | tail -1)
      # The DVR opens a third wave5 instance beside the two decoders and contends with them for
      # the codec and the MMZ pool; measured at ~5 ms on the second tile. Read from the open file
      # descriptor, which is what recording is, rather than from a setting held somewhere else.
      if [ -n "$p" ] && ls -l "/proc/$p/fd" 2>/dev/null | grep -qE "sdcard.*(mp4|mkv)"; then
          echo "recording=1"
      else
          echo "recording=0"
      fi
      if pgrep ml-rf-replay >/dev/null 2>&1; then
          echo "source=replay"
      else
          rx() { sed -n "s/.*sdio0: *\([0-9]*\).*/\1/p" /proc/net/dev; }
          a=$(rx); sleep 1; b=$(rx)
          if [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ]; then echo "source=air"
          else echo "source=none"; fi
      fi' </dev/null > "$OUT/conditions.env" 2>/dev/null

# The air unit is the other half of what a goggle-side latency figure measures, so its build belongs
# in the same summary. Best-effort: absent means it was not reachable, not that it did not matter.
printf 'air_version=%s\n' \
    "$(air_identity | sed -n 's/^ML_VERSION="\(.*\)"/\1/p' | head -1)" >> "$OUT/conditions.env"

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

CAPTURE="$OUT" python3 "$HERE/summary-merge.py" ||
    echo "could not merge the run conditions into summary.json" >&2

echo "log: $LOG"
echo "metadata: $META"
echo "timeline: $SVG"
