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
echo "linkd_banners=$(grep -c "role=air" /var/log/ml-linkd.log 2>/dev/null || echo 0)"
echo "linkd_procs=$(grep -lx ml-linkd /proc/[0-9]*/comm 2>/dev/null | wc -l)"
echo "video_procs=$(grep -lx ml-air-video /proc/[0-9]*/comm 2>/dev/null | wc -l)"
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
sleep SAMPLE_WINDOW
echo "vif_b=$(awk "/ar-vif/ {print \$2}" /proc/interrupts)"
echo "tx_b=$(awk "/sdio0/ {print \$10}" /proc/net/dev)"
echo "rx_b=$(awk "/sdio0/ {print \$2}" /proc/net/dev)"
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
