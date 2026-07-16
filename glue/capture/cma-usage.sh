#!/usr/bin/env bash
# cma-usage.sh - measure the goggle's real CMA usage floor and itemize the consumers,
# to derive a safe CONFIG_CMA_SIZE_MBYTES target for the deferred CMA shrink
# (plans/cma-mmz-composite-heap-rebalance.md).
#
# Runs a 1 Hz sampler ON the goggle (tiny busybox sh loop appending to /tmp, no host SSH
# per sample), so the measurement adds no USB/link load. While it runs, walk the full
# display-state matrix by hand: video+HUD, DVR record start/stop, playback open/close,
# back to live, menu open, AU power-cycle, sustained push. Then `stop` pulls the log and
# prints the floor, the transient peak usage, and an itemized DRM framebuffer list.
#
# Usage:
#   glue/capture/cma-usage.sh start     # start the on-device sampler
#   glue/capture/cma-usage.sh status    # sample count + current values while walking the matrix
#   glue/capture/cma-usage.sh stop      # stop, fetch, summarize
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/ssh-opts.sh"   # sshg + DEVICE_IP/PASS defaults

LOG=/tmp/cma-sample.log
PIDF=/tmp/cma-sample.pid

case "${1:-}" in
start)
    sshg "kill \$(cat $PIDF 2>/dev/null) 2>/dev/null; rm -f $LOG
        setsid sh -c 'while true; do
            awk \"/CmaFree|MemAvailable|MemFree/ {printf \\\"%s %s \\\", \\\$1, \\\$2}\" /proc/meminfo >> $LOG
            date +%s >> $LOG
            sleep 1
        done' >/dev/null 2>&1 < /dev/null &
        echo \$! > $PIDF
        echo \"sampler up pid=\$(cat $PIDF)\""
    echo "Walk the matrix now: video+HUD, DVR rec start/stop, playback open/close, live again,"
    echo "menu, AU power-cycle, sustained push. Then: $0 stop"
    ;;
status)
    sshg "echo \"samples: \$(wc -l < $LOG 2>/dev/null)\"; tail -1 $LOG"
    ;;
stop)
    OUT="${OUT:-/tmp/cma-usage-$(date +%Y%m%d-%H%M%S)}"
    mkdir -p "$OUT"
    sshg "kill \$(cat $PIDF 2>/dev/null) 2>/dev/null; rm -f $PIDF; cat $LOG" > "$OUT/samples.log"
    sshg 'grep -E "CmaTotal" /proc/meminfo' > "$OUT/cmatotal.txt"
    # Itemize: every live DRM framebuffer (allocator, size, dma_addr shows CMA vs MMZ range)
    sshg 'cat /sys/kernel/debug/dri/0/framebuffer 2>/dev/null' > "$OUT/drm-framebuffers.txt"
    sshg 'dmesg | grep -iE "cma.*(fail|alloc error)|page allocation failure"' > "$OUT/cma-errors.txt"

    total_kb=$(awk '{print $2}' "$OUT/cmatotal.txt")
    awk -v total="$total_kb" '
        /CmaFree/ {
            free = 0; avail = 0
            for (i = 1; i <= NF; i++) {
                if ($i == "CmaFree:")      { free  = $(i+1) }
                if ($i == "MemAvailable:") { avail = $(i+1) }
            }
            used = total - free
            n++
            if (free < minfree || n == 1)  { minfree = free }
            if (used > maxused || n == 1)  { maxused = used }
            if (avail < minavail || n == 1) { minavail = avail }
        }
        END {
            if (n == 0) { print "no samples captured"; exit 1 }
            printf "samples             : %d (~%d s)\n", n, n
            printf "CmaTotal            : %d kB\n", total
            printf "CmaFree floor       : %d kB\n", minfree
            printf "CMA peak usage      : %d kB (%.1f MB)\n", maxused, maxused / 1024
            printf "MemAvailable floor  : %d kB\n", minavail
            printf "suggested CMA target: peak + 8 MB margin = %.0f MB (round up to a sane value)\n",
                   maxused / 1024 + 8
        }' "$OUT/samples.log"
    echo
    echo "cma alloc errors during the run: $(wc -l < "$OUT/cma-errors.txt") (see $OUT/cma-errors.txt)"
    echo "DRM framebuffer itemization:      $OUT/drm-framebuffers.txt"
    echo "raw samples:                      $OUT/samples.log"
    ;;
*)
    echo "usage: $0 start|status|stop" >&2
    exit 2
    ;;
esac
