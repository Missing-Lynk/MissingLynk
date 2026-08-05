#!/usr/bin/env bash
# au-video-tx.sh - the validated end-to-end air-to-goggle video path, sampled at both ends.
#
# Runs ml-air-video in its ordinary videotestsrc mode, NOT benchmark mode: the configuration that
# was visually confirmed on the goggle panel (ML_AIR_PATTERN=smpte, 15 fps, two tiles). Leaves it
# running afterwards, so the panel keeps showing the pattern once the script returns.
#
# Judge the result by the deltas printed here, not by a single sample. ml-pipeline's `rx=` line
# prints far less often than its latency lines, so one `grep rx=` reads FROZEN while video is
# flowing fine. Liveness is the byte and datagram counters, and the `prof`/`latraw` lines.
#
# Good-result signature, two tiles at 15 fps:
#   AU      chn0 == chn1 and climbing, dropped 0, sdio0 TX about 800 KB/s
#   goggle  sdio0 RX about 642 KB/s, UDP InDatagrams about 28/s, ml-pipeline drop=0 with
#           composed climbing, prof t0 n == t1 n, rx2flip p50 about 35 ms, no wave5 faults
#
# One encoder instance pair per boot: a second run in the same boot encodes garbage or watchdogs.
# The script refuses if the AU already has one running rather than silently spending it.
#
# Usage: glue/camera/au-video-tx.sh
# Env: PATTERN (smpte), FPS (15), SECS (20 sample window), GOGGLE_IP (192.168.3.101),
#      GOGGLE_PASS (libre), FORCE=1 to run despite an existing instance, STOP=1 to stop and exit.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/au-camera.sh"

PATTERN="${PATTERN:-smpte}"
FPS="${FPS:-15}"
SECS="${SECS:-20}"
GOGGLE_IP="${GOGGLE_IP:-192.168.3.101}"
GOGGLE_PASS="${GOGGLE_PASS:-libre}"
BIN="$REPO/userspace/gstreamer/build/static/ml-air-video"

goggle() {
	device_ssh "$GOGGLE_PASS" "$GOGGLE_IP" "$@"
}

if [ -n "${STOP:-}" ]; then
	sshg "killall ml-air-video 2>/dev/null; sleep 1; echo stopped"
	exit 0
fi

[ -x "$BIN" ] || { echo "missing $BIN (run userspace/gstreamer/scripts/build-static.sh)" >&2; exit 1; }

[ "$SECS" -ge 1 ] || { echo "SECS must be at least 1 (every rate below divides by it)" >&2; exit 1; }

echo "=== air unit ==="

au_require_rf_link
sshg "ping -c 2 -W 2 $AU_RF_PEER | tail -2" </dev/null || exit 1

# A live instance means this boot's usable encoder pair is already spent. pgrep/pkill -f match
# their own command line on this busybox, so ask killall what it would find instead.
if [ -z "${FORCE:-}" ]; then
	au_refuse_air_video_running
elif au_air_video_running; then
	echo "FORCE: stopping the running instance (its encoder pair is already spent)"
	sshg "killall ml-air-video; sleep 2"
fi

device_push "$BIN" || exit 1
sshg "chmod +x /tmp/ml-air-video"

echo
echo "=== goggle ==="
goggle "hostname; rc-service ml-video status 2>&1 | head -1; ip -br addr show sdio0" </dev/null || exit 1

# sample - read both ends into AU_TX, GG_RX and GG_UDP.
sample() {
	AU_TX=$(sshg "cat /sys/class/net/sdio0/statistics/tx_bytes" </dev/null | tr -d '\r')
	GG=$(goggle "cat /sys/class/net/sdio0/statistics/rx_bytes; \
		awk '/^Udp:/{if(h)print \$2;h=1}' /proc/net/snmp" </dev/null | tr -d '\r')
	GG_RX=$(echo "$GG" | sed -n 1p)
	GG_UDP=$(echo "$GG" | sed -n 2p)

	au_require_num "AU sdio0 tx_bytes" "$AU_TX"
	au_require_num "goggle sdio0 rx_bytes" "$GG_RX"
	au_require_num "goggle UDP InDatagrams" "$GG_UDP"
}

# Baseline both ends before the transmitter starts, so every figure below is a delta over a known
# window rather than a total that includes association traffic and telemetry.
sample
AU_TX0="$AU_TX"
GG_RX0="$GG_RX"
GG_UDP0="$GG_UDP"

echo
echo "=== starting ml-air-video: pattern $PATTERN, $FPS fps, two tiles ==="
sshg "cd /tmp && setsid env ML_AIR_PATTERN=$PATTERN ML_AIR_FPS=$FPS ML_AIR_VERBOSE=1 \
	./ml-air-video >/tmp/air-video.log 2>&1 < /dev/null &
	sleep 2
	echo 'launched'" </dev/null

echo "sampling for $SECS s"
sleep "$SECS"

sample
AU_TX1="$AU_TX"
GG_RX1="$GG_RX"
GG_UDP1="$GG_UDP"

echo
echo "=== counters over $SECS s ==="
printf 'AU     sdio0 TX  %s B  (%s KB/s)\n' "$((AU_TX1 - AU_TX0))" "$(((AU_TX1 - AU_TX0) / SECS / 1024))"
printf 'goggle sdio0 RX  %s B  (%s KB/s)\n' "$((GG_RX1 - GG_RX0))" "$(((GG_RX1 - GG_RX0) / SECS / 1024))"
printf 'goggle UDP in    %s datagrams  (%s/s)\n' "$((GG_UDP1 - GG_UDP0))" "$(((GG_UDP1 - GG_UDP0) / SECS))"

echo
echo "=== air-video.log ==="
sshg "tail -12 /tmp/air-video.log" </dev/null

echo
echo "=== goggle ml-pipeline ==="
goggle "tail -60 /var/log/ml-pipeline.log 2>/dev/null | grep -E 'composed|prof|latraw|drop=|rx=' | tail -10" </dev/null

echo
echo "=== goggle codec health ==="
goggle "dmesg | grep -iE 'watchdog|syserr|wave5.*fail|vpu' | tail -8" </dev/null

echo
echo "ml-air-video is still running on the air unit. Stop it with: STOP=1 $0"
