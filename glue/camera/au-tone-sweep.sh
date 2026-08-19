#!/usr/bin/env bash
# au-tone-sweep.sh - the one device session the tone selector still owes.
#
# Three questions in one run, on one scene, so nothing has to be compared across power cycles:
#
#   1 the image      does driving the trigger scalar change the picture, and toward the vendor
#   2 the registers  do gamma, DRC, cm and cm2 all reproduce their derived values once driven
#   3 the freeze     does the parameter hold what ml-aed computed, for every decision
#
# Question 3 needs no timestamp pairing. ml-aed logs the scalar it acted on in the decision line,
# so the log is the record of what was computed and the sampled parameter is the record of what
# landed. Two counts and one final comparison separate "the producer moved and the write did not"
# from "the producer did not move".
#
# Both legs record through the goggle's DVR with glue/capture/ab-record.sh, so both carry the same
# receive and re-encode path and everything that differs came from the air side.
#
# Leg order is deliberate: tone OFF first. The off leg is the current shipped behaviour, so if the
# session dies early the run still produced the baseline rather than only the experiment.
#
# Device sides run from pushed files, never an ssh command line, so nothing is expanded by the
# host shell.
#
# Usage: glue/camera/au-tone-sweep.sh [seconds-per-leg]
# Env: AU (192.168.3.102), GG (192.168.3.101), PASS (libre), OUT dir, SKIP_RECORD=1 to run the
#      register and freeze halves without the DVR legs.
set -uo pipefail

AU="${AU:-192.168.3.102}"
GG="${GG:-192.168.3.101}"
PASS="${PASS:-libre}"
LEG="${1:-40}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="${OUT:-$REPO/out/au-tone-sweep}"
TUNING=/lib/firmware/artosyn/nt99235-tuning-preview-fpv.bin
START_INDEX="${START_INDEX:-317}"

SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
         -o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa
         -o Ciphers=+aes128-cbc -o ConnectTimeout=8)

au() { timeout 120 sshpass -p "$PASS" ssh "${SSHOPTS[@]}" "root@$AU" "$@" 2>/dev/null; }
gg() { timeout 120 sshpass -p "$PASS" ssh "${SSHOPTS[@]}" "root@$GG" "$@" 2>/dev/null; }

mkdir -p "$OUT"

echo "=== preflight ==="
[ "$(au 'echo ok')" = ok ] || { echo "air unit $AU unreachable" >&2; exit 1; }
[ "$(gg 'echo ok')" = ok ] || { echo "goggle $GG unreachable" >&2; exit 1; }

# The camera has to be producing before either leg means anything: a still ISP gives two
# identical recordings and a register dump of a bank nothing is re-arming.
IRQ0=$(au 'cat /sys/kernel/debug/ar-isp/irq_events')
sleep 3
IRQ1=$(au 'cat /sys/kernel/debug/ar-isp/irq_events')
if [ "$IRQ0" = "$IRQ1" ]; then
    echo "ISP irq_events flat at $IRQ0: the camera is not producing, nothing here would mean anything" >&2
    exit 1
fi
echo "  camera producing ($(( (IRQ1 - IRQ0) / 3 )) irq/s)"

# A stale binary is the one failure this whole session exists to avoid, and `make ml-aed` is a
# silent no-op because ml-aed/ is a directory: the target is `make aed`. Rebuild through the real
# target and refuse to stage anything older than its own sources.
BIN="$REPO/userspace/build/ml-aed"
make -C "$REPO/userspace" aed >/dev/null 2>&1 || { echo "ml-aed build failed" >&2; exit 1; }

for src in "$REPO"/userspace/ml-aed/*.c "$REPO"/userspace/ml-aed/*.h; do
    if [ "$src" -nt "$BIN" ]; then
        echo "$BIN is older than $(basename "$src"): the build did not take" >&2
        exit 1
    fi
done

# The scalar is only readable from the log if this binary carries the field. grep -c rather
# than -q: under `set -o pipefail` a -q exits on the first match, strings takes SIGPIPE, and the
# pipeline reports 141 even though it matched.
if [ "$(strings "$BIN" | grep -c "tone %d")" -eq 0 ]; then
    echo "staged ml-aed does not log the actuated scalar; the freeze question stays unanswerable" >&2
    exit 1
fi

au 'cat > /tmp/ml-aed; chmod +x /tmp/ml-aed' < "$BIN"
[ "$(au 'md5sum /tmp/ml-aed' | cut -d' ' -f1)" = "$(md5sum "$BIN" | cut -d' ' -f1)" ] \
  || { echo "pushed ml-aed hash mismatch" >&2; exit 1; }
echo "  ml-aed rebuilt and staged"

# The goggle carries the DMA interrupt race unless it is running the cfg_lock fix. If the engine
# is already wedged the DVR legs record a 0.24 fps crawl and the session is wasted, so this is
# checked before any of it rather than discovered in the recordings.
D0=$(gg 'grep dw_axi /proc/interrupts | awk "{s+=\$2} END {print s}"')
sleep 2
D1=$(gg 'grep dw_axi /proc/interrupts | awk "{s+=\$2} END {print s}"')

if [ -n "$D0" ] && [ "$D0" = "$D1" ]; then
    echo "goggle dw_axi_dmac interrupts frozen at $D0: the DMA engine is wedged" >&2
    echo "  recover live with: rw32 0x08800010 0x3   (or reboot onto the cfg_lock fix)" >&2
    exit 1
fi
echo "  goggle DMA engine live"

cat > "$OUT/dump-banks.sh" <<'DEVEOF'
#!/bin/sh
# Every derived bank the driver can compare, plus the scalar that selected them. $1 = label.
D=/sys/kernel/debug/ar-isp
echo "# label $1"
echo "# tone_scalar $(cat /sys/module/ar_isp/parameters/tone_scalar)"
echo "# cm_trigger $(cat /sys/module/ar_isp/parameters/cm_trigger)"
echo "# cm2_trigger $(cat /sys/module/ar_isp/parameters/cm2_trigger)"
echo "# gamma_curve $(cat /sys/module/ar_isp/parameters/gamma_curve)"
echo "# drc_profile $(cat /sys/module/ar_isp/parameters/drc_profile)"
echo "# irq_events $(cat $D/irq_events)"
cat $D/ladder_banks
DEVEOF

cat > "$OUT/scal-sample.sh" <<'DEVEOF'
#!/bin/sh
# The parameter as it actually reads, 4 Hz. $1 = seconds.
P=/sys/module/ar_isp/parameters/tone_scalar
echo "uptime_s,tone_scalar,cm_trigger,cm2_trigger"
i=0
N=$(( $1 * 4 ))
while [ "$i" -lt "$N" ]; do
    echo "$(cut -d' ' -f1 /proc/uptime),$(cat $P),$(cat /sys/module/ar_isp/parameters/cm_trigger),$(cat /sys/module/ar_isp/parameters/cm2_trigger)"
    i=$((i + 1))
    usleep 250000 2>/dev/null || sleep 1
done
DEVEOF

cat > "$OUT/tone-on.sh" <<DEVEOF
#!/bin/sh
# Swap the service AE for the tone-driven one, and prove the swap took.
rc-service ml-air-ae stop >/dev/null 2>&1
killall ml-aed 2>/dev/null
sleep 1

if pgrep ml-aed >/dev/null; then
    echo "FAILED: an ml-aed survived the stop"
    exit 1
fi

setsid /tmp/ml-aed --start-index $START_INDEX --tone --verbose \\
    --tuning $TUNING > /tmp/tone.log 2>&1 < /dev/null &
sleep 3

if ! pgrep ml-aed >/dev/null; then
    echo "FAILED: ml-aed did not start"
    cat /tmp/tone.log
    exit 1
fi

SC=\$(cat /sys/module/ar_isp/parameters/tone_scalar)

if [ "\$SC" = "-1" ]; then
    echo "FAILED: tone_scalar still -1 after 3 s"
    exit 1
fi

echo "engaged: tone_scalar \$SC"
DEVEOF

cat > "$OUT/restore.sh" <<'DEVEOF'
#!/bin/sh
# The stop is not redundant. A bare killall leaves OpenRC believing the service is started (it
# reports "crashed"), and `start` from that state is a no-op, which silently leaves the baseline
# leg running with no AE at all.
killall ml-aed 2>/dev/null
sleep 1
echo -1 > /sys/module/ar_isp/parameters/tone_scalar
# cm/cm2 do not take -1: that leaves the replayed bank, which is early-table state rather than a
# vendor operating point. Their rest position is the pinned default, not "off".
echo 74496 > /sys/module/ar_isp/parameters/cm_trigger
echo 74496 > /sys/module/ar_isp/parameters/cm2_trigger
rc-service ml-air-ae stop >/dev/null 2>&1
rc-service ml-air-ae start >/dev/null 2>&1
sleep 3

if ! pgrep ml-aed >/dev/null; then
    echo "FAILED: no ml-aed after restore, a baseline leg would carry no AE"
    exit 1
fi

echo "restored: service ml-aed running"
DEVEOF

for f in dump-banks.sh scal-sample.sh tone-on.sh restore.sh; do
    au "cat > /tmp/$f; chmod +x /tmp/$f" < "$OUT/$f"
done
echo "  device scripts staged"

record_leg() {
    local label="$1"
    if [ -n "${SKIP_RECORD:-}" ]; then
        echo "  (SKIP_RECORD set, sleeping ${LEG}s instead of recording)"
        sleep "$LEG"
        return 0
    fi
    "$REPO/glue/capture/ab-record.sh" open --secs "$LEG" \
        --note "tone-$label" --out "$OUT/$label" || {
        echo "  ab-record.sh failed for leg $label" >&2
        return 1
    }
}

echo
echo "=== leg A: tone OFF (shipped behaviour) ==="
au '/tmp/restore.sh' | tee "$OUT/restore-a.out"
if ! grep -q "^restored" "$OUT/restore-a.out"; then
    echo "the baseline leg would run without AE; refusing to record it" >&2
    exit 1
fi
au '/tmp/dump-banks.sh tone-off' > "$OUT/banks-tone-off.txt"
echo "  banks dumped ($(grep -vc '^#' "$OUT/banks-tone-off.txt") registers)"
record_leg off || exit 1

echo
echo "=== leg B: tone ON ==="
au '/tmp/tone-on.sh' > "$OUT/engage.out" 2>&1
cat "$OUT/engage.out"
if ! grep -q "^engaged" "$OUT/engage.out"; then
    echo "tone never engaged; this run says nothing about tone" >&2
    au '/tmp/restore.sh'
    exit 1
fi

timeout $((LEG + 60)) sshpass -p "$PASS" ssh "${SSHOPTS[@]}" "root@$AU" \
    "/tmp/scal-sample.sh $LEG" 2>/dev/null > "$OUT/scal.csv" &
SAMP=$!

record_leg on
RC=$?

wait "$SAMP"
au '/tmp/dump-banks.sh tone-on' > "$OUT/banks-tone-on.txt"
echo "  banks dumped ($(grep -vc '^#' "$OUT/banks-tone-on.txt") registers)"

au 'cat /tmp/tone.log' > "$OUT/aed.log" 2>/dev/null
echo "  decision log: $(grep -c '^seq ' "$OUT/aed.log") decisions"

echo
echo "=== restoring ==="
au '/tmp/restore.sh'
au 'rm -f /tmp/ml-aed /tmp/dump-banks.sh /tmp/scal-sample.sh /tmp/tone-on.sh /tmp/restore.sh /tmp/tone.log'

echo
echo "=== wrote $OUT ==="
ls -1 "$OUT"

echo
echo "=== analysis ==="
"$REPO/glue/camera/au-tone-sweep-report.py" "$OUT"

exit $RC
