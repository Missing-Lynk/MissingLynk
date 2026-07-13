#!/usr/bin/env bash
# link-quality.sh - measure the goggle<->air link WITHOUT any video request running.
# Scores the same way on slot A (vendor) and slot B (open), so they are directly comparable.
# CRITICAL: do NOT run ml-rf-video during this - its video-open poll wedges the air (~11s).
#
# Measures, from the goggle to the air (10.0.0.100):
#   - ping RTT/loss, small (64B) and large (1400B)
#   - SSH handshake latency to the air unit (N connects, each runs `true`), via ml-tcprelay
#
# PREREQ: goggle reachable at DEVICE_IP as root/ROOT_PASS; air powered + associated (telemetry
#         flowing); ml-tcprelay staged (this script pushes it). Good air battery.
# Usage:  DEVICE_IP=192.168.3.100 ROOT_PASS=libre SLOT=B glue/capture/link-quality.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
SLOT="${SLOT:-?}"; N="${N:-5}"
. "$HERE/../lib/ssh-opts.sh"   # provides sshg + DEVICE_IP/PASS defaults

echo "===================== LINK QUALITY (slot $SLOT) ====================="
echo "== association check (telemetry must be flowing; if 0, power-cycle the air) =="
sshg 'r1=$(awk "/sdio0:/{gsub(/.*sdio0:/,\"\");print \$2}" /proc/net/dev); sleep 3; r2=$(awk "/sdio0:/{gsub(/.*sdio0:/,\"\");print \$2}" /proc/net/dev); echo "  telemetry RX +$((r2-r1)) pkts/3s $([ $((r2-r1)) -gt 8 ] && echo ASSOCIATED || echo NOT-ASSOCIATED)"'

echo "== (a) ping small (64B x10) =="
sshg 'ping -c 10 -i 0.3 -W 2 10.0.0.100 2>&1 | tail -2'

echo "== (b) ping large (1400B x10) =="
sshg 'ping -c 10 -i 0.3 -s 1400 -W 2 10.0.0.100 2>&1 | tail -2'

echo "== (c) SSH handshake latency to the air ($N connects) =="
sshg 'pidof ml-tcprelay >/dev/null 2>&1 || true'
sshg 'cat > /tmp/ml-tcprelay; chmod +x /tmp/ml-tcprelay' < "$REPO/libre/tools/ml-tcprelay/ml-tcprelay" 2>/dev/null || echo "  (ml-tcprelay push skipped - already there?)"
sshg 'kill -9 $(pidof ml-tcprelay) 2>/dev/null; setsid /tmp/ml-tcprelay 8822 10.0.0.100 22 >/tmp/relay.log 2>&1 </dev/null & sleep 1; echo "  relay up pid=$(pidof ml-tcprelay)"'

AIR=(-p 8822 -o ConnectTimeout=25 "${SSH_OPTS_LEGACY[@]}")
ok=0

for i in $(seq 1 "$N"); do
  t0=$(date +%s.%N)
  if timeout 30 sshpass -p artosyn ssh "${AIR[@]}" root@"$DEVICE_IP" 'true' 2>/dev/null; then
    t1=$(date +%s.%N); printf "  connect %d: OK  %.2fs\n" "$i" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')"; ok=$((ok+1))
  else
    printf "  connect %d: FAIL/timeout\n" "$i"
  fi
done

echo "  SSH handshakes: $ok/$N succeeded"
echo "======================================================================"
