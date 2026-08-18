#!/usr/bin/env bash
# au-flicker-test.sh - drive the air unit's AE with each anti-flicker setting and record the result.
#
# Mains-driven light ripples at twice the mains frequency. An exposure that is not a whole number
# of half-periods integrates a different amount of light on each row, and a rolling shutter turns
# that into horizontal bands. At 1080p60 a full-frame exposure is 1/60 s, which is two 60 Hz
# half-periods exactly and 1.667 of a 50 Hz one, so on 50 Hz mains the unit bands through its whole
# dim-light range, which is every evening indoors.
#
# ml-aed --banding snaps the exposure down to a whole number of half-periods and raises gain to
# match. This runs one leg per setting on one scene so the three are comparable, and records each
# so the effect is visible rather than inferred.
#
# Recording goes through the goggle's RTSP restream onto the host, not through the goggle DVR. The
# restream's branch is permanent, so a leg starts nothing on the goggle and the three legs differ
# only in what the air unit sent; the DVR path instead starts and stops the encoder per leg and
# writes to the SD card. RECORDER=dvr selects the old path for a question about the DVR itself.
#
# What each leg proves: the sampler shows what the AE actually drove into the sensor, so a leg that
# changed nothing is distinguishable from a leg that had no visual effect, and
# glue/camera/flicker-metric.py then measures the band depth in each recording, so whether the
# banding is gone is a number rather than an impression.
#
# The correction costs light. At 50 Hz it drops 1125 lines to 674 and needs 1.67x the gain, which
# the sensor runs out of near the bottom of the exposure table: expect the darkest scenes to come
# out up to 0.74 stops darker with the correction on. That is inherent, not a bug.
#
# Device sides run from pushed files, never an ssh command line.
#
# Usage: glue/camera/au-flicker-test.sh [seconds-per-leg]
# Env: AU, GG, PASS, OUT dir, LEGS ("0 50 60"), RECORDER (rtsp|dvr), MAINS (50),
#      SKIP_RECORD=1 for the sampler half only.
set -uo pipefail

AU="${AU:-192.168.3.102}"
GG="${GG:-192.168.3.101}"
PASS="${PASS:-libre}"
LEG="${1:-30}"
LEGS="${LEGS:-0 50 60}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="${OUT:-$REPO/out/au-flicker}"
TUNING=/lib/firmware/artosyn/nt99235-tuning-preview-fpv.bin
START_INDEX="${START_INDEX:-317}"
RECORDER="${RECORDER:-rtsp}"
# The mains frequency the scene is actually lit by, which is what flicker-metric.py predicts
# against. It is NOT the leg: the 0 and 60 legs are filmed under the same lamp as the 50 leg.
MAINS="${MAINS:-50}"

SSHOPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
         -o KexAlgorithms=+diffie-hellman-group1-sha1 -o HostKeyAlgorithms=+ssh-rsa
         -o Ciphers=+aes128-cbc -o ConnectTimeout=8)

au() { timeout 120 sshpass -p "$PASS" ssh "${SSHOPTS[@]}" "root@$AU" "$@" 2>/dev/null; }
gg() { timeout 120 sshpass -p "$PASS" ssh "${SSHOPTS[@]}" "root@$GG" "$@" 2>/dev/null; }

mkdir -p "$OUT"

echo "=== preflight ==="
[ "$(au 'echo ok')" = ok ] || { echo "air unit $AU unreachable" >&2; exit 1; }

IRQ0=$(au 'cat /sys/kernel/debug/ar-isp/irq_events')
sleep 3
IRQ1=$(au 'cat /sys/kernel/debug/ar-isp/irq_events')
[ "$IRQ0" != "$IRQ1" ] || { echo "ISP irq_events flat: the camera is not producing" >&2; exit 1; }
echo "  camera producing"

# A stale binary would silently test the old behaviour, and `make ml-aed` is a no-op because
# ml-aed/ is a directory: the target is `make aed`.
BIN="$REPO/userspace/build/ml-aed"
make -C "$REPO/userspace" aed >/dev/null 2>&1 || { echo "ml-aed build failed" >&2; exit 1; }

for src in "$REPO"/userspace/ml-aed/*.c "$REPO"/userspace/ml-aed/*.h; do
    if [ "$src" -nt "$BIN" ]; then
        echo "$BIN is older than $(basename "$src"): the build did not take" >&2
        exit 1
    fi
done

if [ "$(strings "$BIN" | grep -c -- "--banding")" -eq 0 ]; then
    echo "staged ml-aed has no --banding option; nothing here would mean anything" >&2
    exit 1
fi

au 'cat > /tmp/ml-aed; chmod +x /tmp/ml-aed' < "$BIN"
[ "$(au 'md5sum /tmp/ml-aed' | cut -d' ' -f1)" = "$(md5sum "$BIN" | cut -d' ' -f1)" ] \
  || { echo "pushed ml-aed hash mismatch" >&2; exit 1; }
echo "  ml-aed rebuilt and staged"

cat > "$OUT/leg.sh" <<DEVEOF
#!/bin/sh
# Run one banding setting. \$1 = 0|50|60
rc-service ml-air-ae stop >/dev/null 2>&1
killall ml-aed 2>/dev/null
sleep 1

if pgrep ml-aed >/dev/null; then
    echo "FAILED: an ml-aed survived the stop"
    exit 1
fi

setsid /tmp/ml-aed --start-index $START_INDEX --banding "\$1" --verbose \\
    --tuning $TUNING > /tmp/flick.log 2>&1 < /dev/null &
sleep 3

if ! pgrep ml-aed >/dev/null; then
    echo "FAILED: ml-aed did not start with --banding \$1"
    cat /tmp/flick.log
    exit 1
fi

echo "engaged: banding \$1"
DEVEOF

cat > "$OUT/sample.sh" <<'DEVEOF'
#!/bin/sh
# What the AE actually drove into the sensor. $1 = seconds.
E=/sys/module/nt99235/parameters/exposure
G=/sys/module/nt99235/parameters/gain
echo "uptime_s,exposure_lines,gain_code,index"
i=0
while [ "$i" -lt "$1" ]; do
    IDX=$(tail -1 /tmp/flick.log 2>/dev/null | sed -n 's/.* index \([0-9]*\) .*/\1/p')
    echo "$(cut -d' ' -f1 /proc/uptime),$(cat $E),$(cat $G),${IDX:--1}"
    i=$((i + 1))
    sleep 1
done
DEVEOF

cat > "$OUT/restore.sh" <<'DEVEOF'
#!/bin/sh
killall ml-aed 2>/dev/null
sleep 1
# A bare killall leaves OpenRC believing the service is started, and `start` is then a no-op.
rc-service ml-air-ae stop >/dev/null 2>&1
rc-service ml-air-ae start >/dev/null 2>&1
sleep 3
pgrep ml-aed >/dev/null && echo "restored: service ml-aed running" || echo "FAILED: no ml-aed after restore"
DEVEOF

for f in leg.sh sample.sh restore.sh; do
    au "cat > /tmp/$f; chmod +x /tmp/$f" < "$OUT/$f"
done
echo "  device scripts staged"

# ---- the restream, once for the whole session -------------------------------------------------
# Enabled here rather than inside each leg because turning it on costs an ml-hud restart: the HUD
# reads dvr.rtsp_stream at startup and reconciles the pipeline against it at 1 Hz, so a per-leg
# toggle would restart the HUD three times and change the goggle between the legs being compared.
# The previous values are read first and put back at the end, so the goggle leaves the session in
# the state it arrived in.
RTSP_WAS=""
OSD_WAS=""

restore_goggle() {
    if [ -n "$RTSP_WAS" ] && [ -n "$OSD_WAS" ]; then
        echo "=== restoring the goggle: rtsp_stream=$RTSP_WAS record_osd=$OSD_WAS ==="
        GOGGLE_IP="$GG" GOGGLE_PASS="$PASS" \
            "$REPO/glue/capture/rtsp-stream.sh" set "$RTSP_WAS" "$OSD_WAS" || true
    fi
}

if [ "$RECORDER" = rtsp ] && [ -z "${SKIP_RECORD:-}" ]; then
    [ "$(gg 'echo ok')" = ok ] || { echo "goggle $GG unreachable" >&2; exit 1; }

    STATUS="$(GOGGLE_IP="$GG" GOGGLE_PASS="$PASS" "$REPO/glue/capture/rtsp-stream.sh" status)"
    RTSP_WAS="$(printf '%s\n' "$STATUS" | sed -n 's/^rtsp_stream=//p')"
    OSD_WAS="$(printf '%s\n' "$STATUS" | sed -n 's/^record_osd=//p')"
    # An absent key is a false the HUD has never written; putting back "false" is the same state.
    [ "$RTSP_WAS" = absent ] && RTSP_WAS=false
    [ "$OSD_WAS" = absent ] && OSD_WAS=false
    trap restore_goggle EXIT

    GOGGLE_IP="$GG" GOGGLE_PASS="$PASS" "$REPO/glue/capture/rtsp-stream.sh" on \
        || { echo "the restream did not come up; nothing would be recorded" >&2; exit 1; }
fi

for hz in $LEGS; do
    echo
    echo "=== leg: banding $hz ==="
    au "/tmp/leg.sh $hz" > "$OUT/engage-$hz.out" 2>&1
    cat "$OUT/engage-$hz.out"

    if ! grep -q "^engaged" "$OUT/engage-$hz.out"; then
        echo "leg $hz did not engage; skipping it" >&2
        continue
    fi

    # < /dev/null is not cosmetic: a backgrounded ssh inherits the script's stdin and reads from
    # it, so it competes for the same descriptor with every ssh the recorder runs in the
    # foreground. That is the standing suspect for the first run's three silent recorder failures.
    timeout $((LEG + 60)) sshpass -p "$PASS" ssh "${SSHOPTS[@]}" "root@$AU" \
        "/tmp/sample.sh $LEG" < /dev/null 2>/dev/null > "$OUT/sample-$hz.csv" &
    SAMP=$!

    if [ -z "${SKIP_RECORD:-}" ]; then
        # Keep the output: a silenced recorder that fails leaves three empty leg directories and
        # no way to say why, which is what happened the first time this ran.
        if [ "$RECORDER" = rtsp ]; then
            GOGGLE_IP="$GG" GOGGLE_PASS="$PASS" \
                "$REPO/glue/capture/rtsp-record.sh" --secs "$LEG" \
                --note "banding-$hz" --out "$OUT/leg-$hz.mp4" \
                > "$OUT/record-$hz.log" 2>&1 \
                || echo "  rtsp-record.sh failed for leg $hz, see $OUT/record-$hz.log" >&2
        else
            "$REPO/glue/capture/ab-record.sh" open --secs "$LEG" \
                --note "banding-$hz" --out "$OUT/leg-$hz" > "$OUT/record-$hz.log" 2>&1 \
                || echo "  ab-record.sh failed for leg $hz, see $OUT/record-$hz.log" >&2
        fi
    else
        sleep "$LEG"
    fi

    wait "$SAMP"

    # The gain-keyed ladders must NOT follow the flicker compensation: the vendor's routine reads
    # the exposure-table entry for a rounding decision and never writes it, so the abscissa stays
    # on the table gain while only the sensor-bound pair moves. Dumping the banks per leg is what
    # proves that on hardware rather than by reading our own source.
    au 'cat /sys/kernel/debug/ar-isp/ladder_banks' > "$OUT/banks-$hz.txt" 2>/dev/null
    au 'cat /tmp/flick.log' > "$OUT/aed-$hz.log" 2>/dev/null
    echo "  $(grep -c '^seq ' "$OUT/aed-$hz.log") decisions, $(($(wc -l < "$OUT/sample-$hz.csv") - 1)) samples, $(grep -c '^flicker ' "$OUT/aed-$hz.log") flicker corrections"
done

echo
echo "=== restoring ==="
au '/tmp/restore.sh'
au 'rm -f /tmp/ml-aed /tmp/leg.sh /tmp/sample.sh /tmp/restore.sh /tmp/flick.log'

echo
echo "=== what each setting drove into the sensor ==="
printf '%-10s %10s %10s %10s %10s\n' banding samples "lines(med)" "gain(med)" "index(med)"

for hz in $LEGS; do
    f="$OUT/sample-$hz.csv"
    [ -s "$f" ] || continue
    python3 - "$f" "$hz" <<'PYEOF'
import csv, statistics, sys

rows = list(csv.reader(open(sys.argv[1])))[1:]
rows = [r for r in rows if len(r) >= 4]

if rows:
    lines = [int(r[1]) for r in rows]
    gain = [int(r[2]) for r in rows]
    idx = [int(r[3]) for r in rows]
    print("%-10s %10d %10d %10d %10d" % (sys.argv[2], len(rows),
          statistics.median(lines), statistics.median(gain), statistics.median(idx)))
PYEOF
done

echo
echo "=== did the gain-keyed ladders stay on the table gain? ==="

for hz in $LEGS; do
    b="$OUT/banks-$hz.txt"
    [ -s "$b" ] || continue
    printf '%-10s %s\n' "$hz" "$(grep -c ' ok$' "$b") of $(grep -cE '^(rnr|lnr|de3d|cfa|cnf|cm|cm2) ' "$b") registers agree with the model"
done

echo "The counts must match across legs. A leg where they drop means the flicker compensation"
echo "leaked into the ladder abscissa, which is not what the vendor does."

echo
echo "=== how deep is the band in each recording? ==="

# Measured rather than eyeballed. The legs share a scene and a lamp, so the only thing that can
# move the band depth between them is what the AE drove into the sensor. MAINS is the frequency
# the room is lit at, which is the same in all three legs; the leg label is what ml-aed was told.
CLIPS=""

for hz in $LEGS; do
    [ -s "$OUT/leg-$hz.mp4" ] && CLIPS="$CLIPS $OUT/leg-$hz.mp4"
done

if [ "$RECORDER" = rtsp ] && [ -n "$CLIPS" ]; then
    # shellcheck disable=SC2086  # CLIPS is a deliberately word-split list of paths.
    "$REPO/glue/camera/flicker-metric.py" $CLIPS --mains "$MAINS" | tee "$OUT/flicker-metric.txt"
else
    echo "  (no host-side recordings; run with RECORDER=rtsp and without SKIP_RECORD)"
fi

echo
echo "wrote $OUT"
if [ -z "${SKIP_RECORD:-}" ]; then
    for f in "$OUT"/leg-*.mp4 "$OUT"/leg-*/; do
        [ -e "$f" ] && echo "recording: $f"
    done
fi
echo "A leg whose exposure did not move had nothing to correct at that light level."
