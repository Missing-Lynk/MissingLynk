#!/usr/bin/env bash
# telem-continuity-watch.sh - measure whether the air's :10000 telemetry arrives CONTINUOUSLY.
#
# Purpose: A/B a driver build for a telemetry-stability regression. Samples sdio0 RX at the
# NETDEV level (/proc/net/dev packets+bytes per second) - the right metric because it counts
# frames as they arrive at the interface, BEFORE the kernel's martian filter. So it is valid
# even on driver builds that lack the RX prefix-rebuild fix (where ping/app sockets would see
# nothing because the frames are martian-dropped after arrival).
#
# Reference shape (a known-good slot-B capture): after association, steady ~10-14 pkts/s for
# 40s+ with no gaps. A regression looks like a short burst then a cliff to 0.
#
# PREREQ: slot B freshly RAM-booted with the driver under test; air unit powered + associated.
# Usage:  DEVICE_IP=192.168.3.100 [SECS=45] glue/capture/telem-continuity-watch.sh
set -uo pipefail
SECS="${SECS:-45}"
. "$(dirname "$0")/../lib/ssh-opts.sh"   # provides sshg + DEVICE_IP/PASS defaults

echo "== driver identity =="
sshg 'grep -q artosyn_sdio /proc/modules && echo "artosyn_sdio loaded" || { echo "NOT loaded - RAM-boot slot B first"; exit 1; }' || exit 1

echo "== sdio0 up? =="
sshg 'ip -br addr show sdio0 2>/dev/null'
echo

echo "== per-second sdio0 RX for ${SECS}s (watch for STEADY ~11 pkts/s vs burst-then-cliff) =="
sshg 'S='"$SECS"'
pp=0; pb=0; first=1; zeros=0; maxrate=0; total0=0
for i in $(seq 1 $S); do
  read p b < <(awk "/sdio0:/{gsub(/.*sdio0:/,\"\"); print \$2, \$1}" /proc/net/dev)
  if [ $first -eq 1 ]; then first=0; pp=$p; pb=$b; sleep 1; continue; fi
  dp=$((p-pp)); db=$((b-pb)); pp=$p; pb=$b
  [ $dp -gt $maxrate ] && maxrate=$dp
  [ $dp -eq 0 ] && zeros=$((zeros+1))
  printf "t=%2ds  +%3d pkts  +%6d B\n" "$i" "$dp" "$db"
  sleep 1
done
echo "---- summary ----"
echo "peak pkts/s=$maxrate   seconds-with-zero-RX=$zeros/$((S-1))"
[ $maxrate -ge 6 ] && [ $zeros -le 3 ] && echo "VERDICT: CONTINUOUS (matches known-good shape)" \
  || { [ $maxrate -ge 6 ] && echo "VERDICT: BURSTY/STALLING (rose then went quiet - regression shape)" \
       || echo "VERDICT: NO TELEMETRY (never associated, or air off)"; }'