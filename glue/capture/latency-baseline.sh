#!/usr/bin/env bash
# latency-baseline.sh - put a freshly flashed goggle into the state latency runs are compared in.
#
# A flashed unit does not measure anything on its own. The measurement knobs are flag files under
# /usrdata/missinglynk, they survive reboots, and three of the four are absent after a flash, so a
# capture taken without arming them either fails outright or silently measures a different
# configuration from the runs it is being compared against. This script arms the set and prints
# what it armed, so a baseline is a command rather than a memory.
#
# The set, and why each is in it:
#   latstats   the 1 Hz lat line. Every published median comes from it.
#   latraw     the per-frame pair/issue/sub/evt marks. Needed for anything below a median.
#   pace-dbg   the 1 Hz pace line. Without it the margin the servo held is unrecorded and
#              latency-baseline's own point of comparison, glue/capture/pace-curve.py, has no input.
#   seam=2     split geometry plus the cross-fade. ML_SEAM unset means SEAM_OFF, so the flashed
#              default is NOT the configuration the published runs used.
#
# Deliberately left alone: pace (absent means the servo runs at the mode rate, which is the
# baseline), pmsg (on by default, so its per-frame cost is inside every published number), and
# recording, which is a separate configuration and is measured on its own.
#
# This restarts ml-video, because the flag files are read at launch. Restarting also restarts
# ml-linkd, so run it with the air unit off and power the air unit afterwards.
#
# PREREQ: goggle reachable at DEVICE_IP as root/ROOT_PASS.
#
# Usage:
#   glue/capture/latency-baseline.sh
#   glue/capture/latency-baseline.sh --check    report the state, change nothing
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=../lib/ssh-opts.sh
. "$HERE/../lib/ssh-opts.sh"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

report() {
    sshg 'cd /usrdata/missinglynk 2>/dev/null || exit 1
          for f in latstats latraw pace-dbg pace phase-force stats no-pmsg; do
              [ -e "$f" ] && printf "  %-12s present\n" "$f" || printf "  %-12s absent\n" "$f"
          done
          printf "  %-12s %s\n" seam "$(cat seam 2>/dev/null || echo "absent (SEAM_OFF)")"
          printf "  %-12s %s\n" pclk \
              "$(cat /sys/bus/platform/devices/8810000.vo/pclk_hz 2>/dev/null || echo unknown)"'
}

echo "--- knobs before"
report || { echo "cannot read /usrdata/missinglynk on $DEVICE_IP" >&2; exit 1; }

if [ "$CHECK" = 1 ]; then
    exit 0
fi

echo "--- arming the baseline set"
sshg 'set -e
      cd /usrdata/missinglynk
      touch latstats latraw pace-dbg
      echo 2 > seam
      rm -f phase-force
      rc-service ml-video restart >/dev/null 2>&1
      sleep 10' || { echo "arming failed" >&2; exit 1; }

echo "--- knobs after"
report

echo "--- pipeline"
sshg 'grep -E "pace:|seam mode|latstats" /var/log/ml-pipeline.log | tail -3'

cat <<'TXT'

Armed. The air unit can be powered now. Then:
  SECS=90 glue/capture/goggle-latency-capture.sh
  glue/capture/pace-curve.py <the captured ml-pipeline.log>
TXT
