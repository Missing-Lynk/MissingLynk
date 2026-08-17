#!/usr/bin/env bash
# au-health.sh - read-only health sweep of a booted open slot-B AIR UNIT.
#
# Answers "is this boot good?" in one round trip, over the AU's own USB gadget. Everything it
# reads is a file or a counter; it loads nothing, writes nothing, and pokes no registers, so it is
# safe to run at any point in a session including while video is flowing.
#
# The checks are the ones that have actually caught something, which is why they are these and not
# a longer list:
#
#   - ISP tables "built" vs "seeded". An ISP running unconfigured produces horizontal-streak
#     garbage that still encodes, transmits and decodes with every counter healthy, so no other
#     signal distinguishes it. This one word does.
#   - Frame rate from the ar-vif interrupt count, not from a log line. The capture rate is a
#     hardware fact; a userspace stats line can be stale, gated behind a verbose flag, or absent.
#   - Exactly two encoder instance opens. wave5 encoder state survives DESTROY_INSTANCE, so a
#     third open in one boot means something restarted the video and the rest of the session's
#     evidence is suspect.
#   - Exactly one ml-linkd. Two on /dev/artosyn_sdio wedge the RF chip permanently, and a restart
#     nobody asked for has been observed once and never explained.
#   - Any crashed service, from rc-status. ml-air-ae started and died on every boot for a whole
#     session while video, OSD, telemetry and every counter above read healthy; exposure was
#     frozen and nothing else said so.
#   - Auto exposure, by the hold rate and the EAGAIN signature rather than by the log tail.
#     ml-aed prints only when the index moves, so a settled loop and a dead one produce the same
#     last line. Two things that look like faults and are not: a quiet log is convergence, and
#     sensor exposure pinned at 1125 is the 1080p60 frame-time ceiling with gain doing the work.
#
# Usage:
#   glue/boot/au-health.sh                 # sweep, 5 s counter window
#   SAMPLE=10 glue/boot/au-health.sh       # longer window for a steadier rate
#
# Env: AU_IP (default 192.168.3.102), AU_PORT (22), AU_PASS (libre), SAMPLE (seconds, default 5).
#
# Exit status: 0 when every check passed, 1 when any FAIL. WARN never fails the run - it marks
# something that is legitimate in some sessions (no camera running, say) and wrong in others.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/ssh-opts.sh"

AU_IP="${AU_IP:-192.168.3.102}"
AU_PORT="${AU_PORT:-22}"
AU_PASS="${AU_PASS:-libre}"
SAMPLE="${SAMPLE:-5}"

# The device side only measures and prints key=value; every judgement is made on the host, where it
# is readable and where changing a threshold does not mean editing a quoted remote script.
#
# shellcheck disable=SC2016  # single-quoted on purpose: every $() here must run on the device
REMOTE='
echo "kernel=$(uname -r)"
echo "cmdline=$(cat /proc/cmdline)"
echo "modules=$(lsmod | awk "NR>1 {printf \"%s \", \$1}")"
echo "isp_tables=$(dmesg | grep -m1 "isp: tables:" | sed "s/.*tables: //")"
echo "enc_opens=$(dmesg | grep -c "enc instance open")"
echo "vpu_faults=$(dmesg | grep -E "video-codec" | grep -ciE "watchdog|syserr|fail")"
echo "sdio_addr=$(ip -o -4 addr show sdio0 2>/dev/null | awk "{print \$4}")"
echo "rf_attempts=$(tail -n 1 /usrdata/missinglynk/rf-bringup.log 2>/dev/null | grep -o "attempts=[0-9]*" | cut -d= -f2)"
echo "rf_retried_boots=$(grep -c "attempts=[2-9]" /usrdata/missinglynk/rf-bringup.log 2>/dev/null || echo 0)"
echo "rf_ledger_boots=$(grep -c "result=" /usrdata/missinglynk/rf-bringup.log 2>/dev/null || echo 0)"
echo "linkd_banners=$(grep -c "role=air" /var/log/ml-linkd.log 2>/dev/null || echo 0)"
echo "linkd_procs=$(grep -lx ml-linkd /proc/[0-9]*/comm 2>/dev/null | wc -l)"
echo "video_procs=$(grep -lx ml-air-video /proc/[0-9]*/comm 2>/dev/null | wc -l)"
echo "svc_crashed=$(rc-status 2>/dev/null | grep crashed | awk "{printf \"%s \", \$1}")"
echo "ae_procs=$(grep -lx ml-aed /proc/[0-9]*/comm 2>/dev/null | wc -l)"
echo "ae_eagain=$(grep -c "Resource temporarily" /var/log/ml-air-ae.log 2>/dev/null || echo 0)"
echo "ae_err=$(tail -200 /var/log/ml-air-ae.log 2>/dev/null | awk "{d += \$4 - \$6; n++} END {if (n) printf \"%.1f\", d / n}")"
echo "persist=$([ -x /usr/local/bin/ml-rf-persist ] && echo yes || echo no)"
echo "cma_free=$(awk "/CmaFree/ {print \$2}" /proc/meminfo)"
for d in /sys/bus/iio/devices/iio:device*
do
    [ "$(cat "$d/name" 2>/dev/null)" = temperature ] || continue
    echo "temp_c=$(cat "$d/in_temp_scale")"
done

# Counter pairs around one window. The IRQ count is the capture rate and the sdio0 byte count is
# what actually left the radio; both are meaningless as absolutes and exact as deltas.
echo "vif_a=$(awk "/ar-vif/ {print \$2}" /proc/interrupts)"
echo "tx_a=$(awk "/sdio0/ {print \$10}" /proc/net/dev)"
echo "rx_a=$(awk "/sdio0/ {print \$2}" /proc/net/dev)"
echo "flips_a=$(cat /sys/kernel/debug/ar-isp/stats_flips 2>/dev/null || echo 0)"
echo "ae_moves_a=$(wc -l < /var/log/ml-air-ae.log 2>/dev/null || echo 0)"
sleep SAMPLE_WINDOW
echo "vif_b=$(awk "/ar-vif/ {print \$2}" /proc/interrupts)"
echo "tx_b=$(awk "/sdio0/ {print \$10}" /proc/net/dev)"
echo "rx_b=$(awk "/sdio0/ {print \$2}" /proc/net/dev)"
echo "flips_b=$(cat /sys/kernel/debug/ar-isp/stats_flips 2>/dev/null || echo 0)"
echo "ae_moves_b=$(wc -l < /var/log/ml-air-ae.log 2>/dev/null || echo 0)"
'

report="$(device_ssh "$AU_PASS" "$AU_IP" "${REMOTE/SAMPLE_WINDOW/$SAMPLE}")" || {
    echo "au-health: $AU_IP unreachable (open slot B, root/$AU_PASS)" >&2
    exit 1
}

field() {
    printf '%s\n' "$report" | sed -n "s/^$1=//p" | head -1
}

fails=0

check() {
    local verdict="$1" what="$2" detail="${3:-}"

    printf '%-6s %-34s %s\n' "$verdict" "$what" "$detail"
    [ "$verdict" = FAIL ] && fails=$((fails + 1))

    return 0
}

# --- identity ------------------------------------------------------------------------------
kernel="$(field kernel)"
case "$(field cmdline)" in
    *ubi.mtd=userapp1*)
        check PASS "booted slot B rootfs" "kernel $kernel"
        ;;
    *)
        check FAIL "booted slot B rootfs" "cmdline has no ubi.mtd=userapp1 - this is not our rootfs"
        ;;
esac

# --- modules -------------------------------------------------------------------------------
modules="$(field modules)"
missing=""
for m in nt99235 ar_csi2 ar_vif ar_isp ar_cvisp wave5 artosyn_sdio ml_mmzheap
do
    case " $modules " in
        *" $m "*)
            ;;
        *)
            missing="$missing $m"
            ;;
    esac
done
if [ -z "$missing" ]
then
    check PASS "camera, codec and RF modules loaded"
else
    check FAIL "camera, codec and RF modules loaded" "missing:$missing"
fi

# --- the ISP tuning blob actually reached the ISP -------------------------------------------
# "built" means generated from the tuning blob; "seeded" means it was not found, and the picture
# is streak garbage that every counter downstream reports as healthy.
tables="$(field isp_tables)"
if [ -z "$tables" ]
then
    check WARN "ISP tables built from the blob" "no ar-isp tables line - camera never brought up?"
elif printf '%s' "$tables" | grep -q seeded
then
    check FAIL "ISP tables built from the blob" "$tables"
else
    check PASS "ISP tables built from the blob" "$tables"
fi

# --- capture rate, from the interrupt counter ------------------------------------------------
vif_a="$(field vif_a)"
vif_b="$(field vif_b)"
if [ -n "$vif_a" ] && [ -n "$vif_b" ]
then
    fps=$(( (vif_b - vif_a) / SAMPLE ))
    if [ "$fps" -ge 55 ] && [ "$fps" -le 65 ]
    then
        check PASS "capture running at 60 fps" "${fps}/s from ar-vif IRQs"
    elif [ "$fps" -gt 0 ]
    then
        check WARN "capture running at 60 fps" "${fps}/s - expected ~60"
    else
        check FAIL "capture running at 60 fps" "no ar-vif interrupts in ${SAMPLE}s"
    fi
else
    check WARN "capture running at 60 fps" "no ar-vif interrupt line - camera not up"
fi

# --- crashed services --------------------------------------------------------------------------
# A service that started and then died leaves every other signal healthy. ml-air-ae did exactly
# that for a whole session: video, OSD, telemetry and every counter read fine while exposure sat
# frozen, because nothing here asked OpenRC what it thought.
crashed="$(field svc_crashed)"
if [ -z "$crashed" ]
then
    check PASS "no crashed services" "rc-status clean"
else
    check FAIL "no crashed services" "crashed:$crashed"
fi

# --- auto exposure ------------------------------------------------------------------------------
# Judge AE by the actuator and the hold rate, never by the log tail: ml-aed prints only when the
# index moves, so a converged loop and a dead one look identical from the last line. The specific
# regression to catch is the daemon exiting on EAGAIN before the first flip.
ae_procs="$(field ae_procs)"
ae_eagain="$(field ae_eagain)"
flips_a="$(field flips_a)"
flips_b="$(field flips_b)"
moves_a="$(field ae_moves_a)"
moves_b="$(field ae_moves_b)"
ae_err="$(field ae_err)"

if [ "${ae_eagain:-0}" -gt 0 ]
then
    check FAIL "ml-aed survived stream-on" "$ae_eagain EAGAIN exit(s) in ml-air-ae.log - AE died at boot"
else
    check PASS "ml-aed survived stream-on" "no EAGAIN exits logged"
fi

case "$ae_procs" in
    1)
        check PASS "exactly one ml-aed" ;;
    0)
        check FAIL "exactly one ml-aed" "auto exposure is not running - the camera streams at a fixed exposure" ;;
    *)
        check FAIL "exactly one ml-aed" "$ae_procs running - they would fight over the operating point" ;;
esac

# Hold rate: decisions the loop declined to act on, as a share of the frames it saw. A healthy
# settled loop holds nearly all of them; a loop that moves on every frame is hunting.
#
# Only meaningful while a daemon is actually running. A dead ml-aed makes no moves at all, which
# arithmetically reads as a perfect 100% hold, so the running check has to gate this one or the
# worst case reports as the best.
if [ "$ae_procs" != 1 ]
then
    check WARN "AE settled" "no single ml-aed running - hold rate would read 100% for a dead loop"
elif [ -n "$flips_a" ] && [ -n "$flips_b" ] && [ "$flips_b" -gt "$flips_a" ]
then
    decisions=$(( flips_b - flips_a ))
    moves=$(( moves_b - moves_a ))
    hold=$(( 100 - (moves * 100 / decisions) ))
    if [ "$hold" -ge 50 ]
    then
        check PASS "AE settled" "held ${hold}% of $decisions decisions, mean luma error ${ae_err:-?}"
    else
        check WARN "AE settled" "held only ${hold}% of $decisions decisions - hunting, or the scene is moving"
    fi
else
    check WARN "AE settled" "stats_flips not advancing - no statistics, so no decisions to judge"
fi

# --- encoders --------------------------------------------------------------------------------
opens="$(field enc_opens)"
case "$opens" in
    2)
        check PASS "one encoder instance pair" "2 opens, one per tile"
        ;;
    0)
        check WARN "one encoder instance pair" "no encoder opened - video not running"
        ;;
    *)
        check FAIL "one encoder instance pair" "$opens opens: the pair was reopened in this boot"
        ;;
esac

faults="$(field vpu_faults)"
if [ "${faults:-0}" -eq 0 ]
then
    check PASS "no codec watchdog or syserr"
else
    check FAIL "no codec watchdog or syserr" "$faults matching dmesg lines"
fi

# --- RF ---------------------------------------------------------------------------------------
addr="$(field sdio_addr)"
if [ -n "$addr" ]
then
    check PASS "sdio0 up" "$addr"
else
    check FAIL "sdio0 up" "no address - RF bring-up did not complete"
fi

# The bring-up has failed at boot and then succeeded on an identical manual run, so a boot that
# needed its retry is the signal worth counting: it looks healthy afterwards and leaves no other
# trace. The ledger is per boot and persistent (/usrdata), unlike /var/log.
attempts="$(field rf_attempts)"
retried="$(field rf_retried_boots)"
ledger="$(field rf_ledger_boots)"
if [ -z "$ledger" ] || [ "${ledger:-0}" -eq 0 ]
then
    check INFO "RF bring-up ledger" "empty - predates this rootfs, or /usrdata is not mounted"
elif [ "${attempts:-1}" -gt 1 ]
then
    check FAIL "RF bring-up first try" "THIS boot needed $attempts attempts ($retried of $ledger boots)"
elif [ "${retried:-0}" -gt 0 ]
then
    check INFO "RF bring-up first try" "this boot ok; $retried of $ledger boots needed a retry"
else
    check PASS "RF bring-up first try" "$ledger boots, none retried"
fi

# Two ml-linkd on /dev/artosyn_sdio wedge the chip permanently, and a restart nobody asked for has
# been seen once. The banner count catches a restart that the process count cannot.
procs="$(field linkd_procs)"
banners="$(field linkd_banners)"
if [ "${procs:-0}" -eq 1 ] && [ "${banners:-0}" -eq 1 ]
then
    check PASS "exactly one ml-linkd, started once"
elif [ "${procs:-0}" -ne 1 ]
then
    check FAIL "exactly one ml-linkd, started once" "$procs running"
else
    check FAIL "exactly one ml-linkd, started once" "$banners startup banners: it restarted"
fi

# --- what left the radio -----------------------------------------------------------------------
tx_a="$(field tx_a)"
tx_b="$(field tx_b)"
if [ -n "$tx_a" ] && [ -n "$tx_b" ]
then
    kbps=$(( (tx_b - tx_a) * 8 / SAMPLE / 1000 ))
    rx_delta=$(( $(field rx_b) - $(field rx_a) ))
    check INFO "sdio0 TX" "${kbps} kbit/s, RX ${rx_delta} B in ${SAMPLE}s"
fi

check INFO "junction temperature" "$(field temp_c) C"
check INFO "CMA free" "$(field cma_free) kB"

if [ "$(field persist)" = yes ]
then
    check PASS "ml-rf-persist present" "a bind can survive a power cycle"
else
    check FAIL "ml-rf-persist present" "a bind would be runtime-only and lost on power-off"
fi

echo
if [ "$fails" -eq 0 ]
then
    echo "au-health: all checks passed"
else
    echo "au-health: $fails check(s) FAILED"
fi

exit $(( fails > 0 ))
