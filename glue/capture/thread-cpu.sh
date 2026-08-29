#!/usr/bin/env bash
# thread-cpu.sh - sample ml-pipeline's per-thread CPU on the goggle, for a leg's duration.
#
# The goggle has two cores carrying both decoder streaming threads, compose, the display/flip
# thread, the pace servo, the encoder's v4l2 threads, the record-bin queue thread and the RTSP
# server's client thread. When a loaded leg costs latch wait rather than decode time, the question
# is which of those is taking the core at the moment the flip should be submitted, and that is not
# visible in the latency marks. This writes one row per thread per second: jiffies of user and
# system time, so a later pass can turn consecutive rows into a per-thread share.
#
# PREREQ: goggle reachable at DEVICE_IP as root/ROOT_PASS, ml-pipeline running.
#
# Usage:
#   glue/capture/thread-cpu.sh <seconds> <out.csv>
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=../lib/ssh-opts.sh
. "$HERE/../lib/ssh-opts.sh"

SECS="${1:?usage: thread-cpu.sh <seconds> <out.csv>}"
OUT="${2:?usage: thread-cpu.sh <seconds> <out.csv>}"

mkdir -p "$(dirname "$OUT")"

# Sampled on the device rather than over one ssh call per second: a round trip per sample would
# put its own latency into the spacing, and the whole point is even spacing.
# shellcheck disable=SC2016  # every expansion below runs on the device
sshg "
p=\$(pgrep ml-pipeline | tail -1)
[ -n \"\$p\" ] || { echo 'no ml-pipeline' >&2; exit 1; }
echo 'sec,tid,comm,utime,stime'
i=0
while [ \$i -lt $SECS ]; do
    for t in /proc/\$p/task/*/stat; do
        [ -e \"\$t\" ] || continue
        read -r line < \"\$t\" || continue
        tid=\${line%% *}
        rest=\${line#*(}
        comm=\${rest%%)*}
        set -- \${rest#*) }
        echo \"\$i,\$tid,\$comm,\${12},\${13}\"
    done
    i=\$((i + 1))
    sleep 1
done
" </dev/null >"$OUT" 2>/dev/null

rows=$(wc -l <"$OUT")
if [ "$rows" -lt 2 ]; then
    echo "thread-cpu: no samples collected" >&2
    exit 1
fi

echo "thread-cpu: $rows rows -> $OUT"
