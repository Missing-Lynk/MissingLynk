#!/usr/bin/env bash
# au-tone-ab.sh - drive the tone selector on the air unit while watching both ends of the link.
#
# Two phases on one scene: the stock AE with tone pinned, then the same AE driving the trigger
# scalar. What it is for is not the scalar (au-tone-test.sh settles that) but the consequence: does
# the picture survive, and if it stalls, which stage stopped.
#
# A stalled picture has three candidate causes and they are only separable if both ends are sampled
# together, so this records, once a second:
#
#   air unit    sdio0 TX bytes (is it sending), ISP irq_events (is the camera producing)
#   goggle      sdio0 RX bytes (is it receiving), ml-pipeline per-thread jiffies (is it decoding
#               and compositing)
#
# A frozen image with all four still moving is a scanout problem; TX moving and RX flat is the link;
# RX moving and the decoder flat is the goggle.
#
# Both device sides run from pushed files, never from an ssh command line, so nothing is expanded by
# the host shell.
#
# Usage: glue/camera/au-tone-ab.sh [seconds-per-phase]
# Env: AU (192.168.3.102), GG (192.168.3.101), PASS (libre), OUT dir.
set -uo pipefail

AU="${AU:-192.168.3.102}"
GG="${GG:-192.168.3.101}"
PASS="${PASS:-libre}"
PHASE="${1:-45}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="${OUT:-$REPO/out/au-tone-ab}"
TUNING=/lib/firmware/artosyn/nt99235-tuning-preview-fpv.bin

SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
         -o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa
         -o Ciphers=+aes128-cbc -o ConnectTimeout=8)

au() { timeout 60 sshpass -p "$PASS" ssh "${SSHOPTS[@]}" "root@$AU" "$@" 2>/dev/null; }
gg() { timeout 60 sshpass -p "$PASS" ssh "${SSHOPTS[@]}" "root@$GG" "$@" 2>/dev/null; }

mkdir -p "$OUT"

au 'echo ok' | grep -q ok || { echo "air unit $AU unreachable" >&2; exit 1; }
gg 'echo ok' | grep -q ok || { echo "goggle $GG unreachable" >&2; exit 1; }

echo "=== staging ==="
au 'cat > /tmp/ml-aed; chmod +x /tmp/ml-aed' < "$REPO/userspace/build/ml-aed"
[ "$(au 'md5sum /tmp/ml-aed' | cut -d' ' -f1)" = "$(md5sum "$REPO/userspace/build/ml-aed" | cut -d' ' -f1)" ] \
  || { echo "pushed ml-aed hash mismatch" >&2; exit 1; }

cat > "$OUT/au-sample.sh" <<'DEVEOF'
#!/bin/sh
# air unit sampler: $1 = seconds
echo "uptime_s,tx_bytes,irq_events,tone_scalar,phase"
i=0
while [ "$i" -lt "$1" ]; do
    UP=$(cut -d' ' -f1 /proc/uptime)
    TX=$(grep sdio0 /proc/net/dev | awk '{print $10}')
    IRQ=$(cat /sys/kernel/debug/ar-isp/irq_events)
    TS=$(cat /sys/module/ar_isp/parameters/tone_scalar)
    PH=$(cat /tmp/phase 2>/dev/null || echo "?")
    echo "$UP,$TX,$IRQ,$TS,$PH"
    i=$((i + 1))
    sleep 1
done
DEVEOF

cat > "$OUT/gg-sample.sh" <<'DEVEOF'
#!/bin/sh
# goggle sampler: $1 = seconds. Per-thread jiffies for the pipeline, plus link RX.
PID=$(pgrep -f "ml-pipeline rf" | head -1)
HP=$(pgrep ml-hud | head -1)
echo "uptime_s,rx_bytes,dec_jiffies,src_jiffies,rec_jiffies,enc_jiffies,hud_jiffies"
i=0
while [ "$i" -lt "$1" ]; do
    UP=$(cut -d' ' -f1 /proc/uptime)
    RX=$(grep sdio0 /proc/net/dev | awk '{print $2}')
    DEC=0
    SRC=0
    REC=0
    ENC=0
    for T in /proc/"$PID"/task/*; do
        [ -r "$T/stat" ] || continue
        N=$(cut -d' ' -f2 "$T/stat" | tr -d '()')
        J=$(awk '{print $14 + $15}' "$T/stat")
        case "$N" in
            dec*)    DEC=$((DEC + J)) ;;
            src*)    SRC=$((SRC + J)) ;;
            recsrc*) REC=$((REC + J)) ;;
            v4l2*)   ENC=$((ENC + J)) ;;
        esac
    done
    HUD=0
    [ -r "/proc/$HP/stat" ] && HUD=$(awk '{print $14 + $15}' "/proc/$HP/stat")
    echo "$UP,$RX,$DEC,$SRC,$REC,$ENC,$HUD"
    i=$((i + 1))
    sleep 1
done
DEVEOF

cat > "$OUT/phase2.sh" <<DEVEOF
#!/bin/sh
# Switch the air unit to the tone-driven AE, and prove it took.
rc-service ml-air-ae stop >/dev/null 2>&1
killall ml-aed 2>/dev/null
sleep 1

if pgrep ml-aed >/dev/null; then
    echo "phase2 FAILED: an ml-aed survived the stop"
    exit 1
fi

echo tone > /tmp/phase
setsid /tmp/ml-aed --start-index 317 --tone --verbose \
    --tuning $TUNING > /tmp/tone.log 2>&1 < /dev/null &
sleep 3

if ! pgrep ml-aed >/dev/null; then
    echo "phase2 FAILED: ml-aed did not start"
    cat /tmp/tone.log
    exit 1
fi

SC=\$(cat /sys/module/ar_isp/parameters/tone_scalar)

if [ "\$SC" = "-1" ]; then
    echo "phase2 FAILED: tone_scalar still -1 after 3 s"
    exit 1
fi

echo "phase2 engaged: tone_scalar \$SC"
DEVEOF

au 'cat > /tmp/phase2.sh; chmod +x /tmp/phase2.sh' < "$OUT/phase2.sh"
au 'cat > /tmp/au-sample.sh; chmod +x /tmp/au-sample.sh' < "$OUT/au-sample.sh"
gg 'cat > /tmp/gg-sample.sh; chmod +x /tmp/gg-sample.sh' < "$OUT/gg-sample.sh"
echo "  samplers staged"

TOTAL=$((PHASE * 2 + 10))

echo "=== sampling ${TOTAL}s, ${PHASE}s per phase ==="
au 'echo baseline > /tmp/phase'
timeout $((TOTAL + 40)) sshpass -p "$PASS" ssh "${SSHOPTS[@]}" "root@$AU" \
    "/tmp/au-sample.sh $TOTAL" 2>/dev/null > "$OUT/au.csv" &
AUP=$!
timeout $((TOTAL + 40)) sshpass -p "$PASS" ssh "${SSHOPTS[@]}" "root@$GG" \
    "/tmp/gg-sample.sh $TOTAL" 2>/dev/null > "$OUT/gg.csv" &
GGP=$!

sleep "$PHASE"

echo "--- phase 2: tone on ---"
au '/tmp/phase2.sh' > "$OUT/phase2.out" 2>&1
cat "$OUT/phase2.out"

if ! grep -q "^phase2 engaged" "$OUT/phase2.out"; then
  echo "phase 2 did not engage; the run measures nothing about tone" >&2
  ENGAGED=0
else
  ENGAGED=1
fi

wait "$AUP" "$GGP"

echo "=== restoring ==="
au 'killall ml-aed 2>/dev/null; sleep 1; echo -1 > /sys/module/ar_isp/parameters/tone_scalar; rc-service ml-air-ae start >/dev/null 2>&1'
au 'cat /tmp/tone.log' > "$OUT/aed.log" 2>/dev/null
au 'rm -f /tmp/ml-aed /tmp/au-sample.sh /tmp/tone.log /tmp/phase'
gg 'rm -f /tmp/gg-sample.sh'

gg 'rm -f /tmp/gg-sample.sh' >/dev/null 2>&1
au 'rm -f /tmp/phase2.sh' >/dev/null 2>&1

echo "=== wrote $OUT/au.csv $OUT/gg.csv $OUT/aed.log ==="

if [ "${ENGAGED:-0}" != "1" ]; then
  echo "NOTE: phase 2 never engaged, so this run says nothing about tone" >&2
  exit 1
fi
