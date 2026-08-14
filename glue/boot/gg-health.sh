#!/usr/bin/env bash
# gg-health.sh - read-only health sweep of a booted open slot-B GOGGLE.
#
# The goggle-side counterpart to au-health.sh: answers "is this boot good?" in one round trip over
# the goggle's USB gadget. Everything it reads is a file or a counter; it loads nothing, writes
# nothing, and pokes no registers, so it is safe to run at any point in a session including while
# video is on the panel.
#
# The goggle's failure modes are display-and-receive shaped, where the air unit's are
# capture-and-transmit shaped, so the checks differ from au-health.sh even where the structure
# matches:
#
#   - The AR8030's SDIO device id. The chip can power up enumerating garbage (0x2a22 seen), the
#     driver's id_table then never matches, and nothing downstream exists to complain: no probe, no
#     firmware upload, no /dev/artosyn_sdio. Only a battery-out cold cycle clears it, so naming the
#     state is the whole value of the check.
#   - Panel refresh from the artosyn-vo interrupt count. A boot that comes up with a dead panel
#     leaves every process running and every log clean; the vsync counter is what separates it from
#     a live one.
#   - The pipeline's DRM sink actually bound, and the tile blit landed on the DMA engine. A CPU-only
#     blit runs, and runs too slowly, which shows up as judder nobody can attribute later.
#   - Exactly one ml-linkd. Two on /dev/artosyn_sdio wedge the RF chip permanently.
#
# Downlink liveness (sdio0 RX, decoder interrupts) is reported as WARN, not FAIL: a goggle with no
# air unit powered is a legitimate state, and on a bench that is most of the time.
#
# Usage:
#   glue/boot/gg-health.sh                 # sweep, 5 s counter window
#   SAMPLE=10 glue/boot/gg-health.sh       # longer window for a steadier rate
#
# Env: GG_IP (default 192.168.3.101), GG_PASS (libre), SAMPLE (seconds, default 5).
#
# Exit status: 0 when every check passed, 1 when any FAIL. WARN never fails the run - it marks
# something that is legitimate in some sessions (no air unit linked, no SD card inserted) and wrong
# in others.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/ssh-opts.sh"

GG_IP="${GG_IP:-192.168.3.101}"
GG_PASS="${GG_PASS:-libre}"
SAMPLE="${SAMPLE:-5}"

# The device side only measures and prints key=value; every judgement is made on the host, where it
# is readable and where changing a threshold does not mean editing a quoted remote script.
#
# shellcheck disable=SC2016  # single-quoted on purpose: every $() here must run on the device
REMOTE='
echo "kernel=$(uname -r)"
echo "cmdline=$(cat /proc/cmdline)"
echo "modules=$(lsmod | awk "NR>1 {printf \"%s \", \$1}")"
echo "installed=$(sed -n "s/.*\"version\":[^\"]*\"\([^\"]*\)\".*/\1/p" /usrdata/missinglynk/device.json 2>/dev/null | head -1)"
echo "boots=$(sed -n "s/.*\"boots\":[^0-9]*\([0-9]*\).*/\1/p" /usrdata/missinglynk/device.json 2>/dev/null | head -1)"
echo "sdio_devid=$(cat /sys/bus/sdio/devices/*/device 2>/dev/null | tr "\n" " " | sed "s/ *$//")"
echo "sdio_addr=$(ip -o -4 addr show sdio0 2>/dev/null | awk "{print \$4}")"
echo "rf_fw=$(dmesg | grep -m1 -o "bb_[a-z_0-9]*\.img")"
echo "linkd_banners=$(grep -c "bring-up done" /var/log/ml-linkd.log 2>/dev/null || echo 0)"
echo "vpu_faults=$(dmesg | grep -E "video-codec" | grep -ciE "watchdog|syserr|fail")"
echo "drm_card=$([ -e /dev/dri/card0 ] && echo yes || echo no)"
echo "connector=$(cat /sys/class/drm/*/status 2>/dev/null | head -1)"
echo "overlay=$(grep -c "overlay plane .* enabled" /var/log/ml-hud.log 2>/dev/null || echo 0)"
echo "drm_sink=$(grep -c "DRM output connector" /var/log/ml-pipeline.log 2>/dev/null || echo 0)"
echo "tile_blit=$(sed -n "s/.*tile blit = //p" /var/log/ml-pipeline.log 2>/dev/null | head -1)"
echo "sockets=$(ls /run/missinglynk/ 2>/dev/null | tr "\n" " ")"
echo "usrdata=$(awk "\$2 == \"/usrdata\" {print \$4}" /proc/mounts | cut -d, -f1)"
echo "sdcard=$(awk "\$2 == \"/mnt/sdcard\" {print \$3}" /proc/mounts)"
echo "persist=$([ -x /usr/local/bin/ml-rf-persist ] && echo yes || echo no)"
echo "cma_free=$(awk "/CmaFree/ {print \$2}" /proc/meminfo)"
echo "mem_avail=$(awk "/MemAvailable/ {print \$2}" /proc/meminfo)"
for d in /sys/bus/iio/devices/iio:device*
do
    [ "$(cat "$d/name" 2>/dev/null)" = temperature ] || continue
    echo "temp_c=$(cat "$d/in_temp_scale")"
done
for p in ml-pipeline ml-hud ml-linkd ml-drmfd ml-ledd ml-logd
do
    echo "proc_$p=$(grep -lx "$p" /proc/[0-9]*/comm 2>/dev/null | wc -l)"
done

# Counter pairs around one window. The vo count is the panel refresh, the sdio0 byte count is what
# the radio actually received and the vpu count is what the decoder was actually handed; all three
# are meaningless as absolutes and exact as deltas.
echo "vo_a=$(awk "/artosyn-vo/ {print \$2}" /proc/interrupts)"
echo "vpu_a=$(awk "/vpu_irq/ {print \$2}" /proc/interrupts)"
echo "rx_a=$(awk "/sdio0/ {print \$2}" /proc/net/dev)"
echo "tx_a=$(awk "/sdio0/ {print \$10}" /proc/net/dev)"
sleep SAMPLE_WINDOW
echo "vo_b=$(awk "/artosyn-vo/ {print \$2}" /proc/interrupts)"
echo "vpu_b=$(awk "/vpu_irq/ {print \$2}" /proc/interrupts)"
echo "rx_b=$(awk "/sdio0/ {print \$2}" /proc/net/dev)"
echo "tx_b=$(awk "/sdio0/ {print \$10}" /proc/net/dev)"
'

report="$(device_ssh "$GG_PASS" "$GG_IP" "${REMOTE/SAMPLE_WINDOW/$SAMPLE}")" || {
    echo "gg-health: $GG_IP unreachable (open slot B, root/$GG_PASS)" >&2
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

check INFO "flashed image" "$(field installed), boot #$(field boots)"

# --- modules -------------------------------------------------------------------------------
# artosyn_gpio is in the list because card0 does not appear without it, which reads as a display
# fault rather than a missing module.
modules="$(field modules)"
missing=""
for m in artosyn_sdio artosyn_vo artosyn_dsi artosyn_gpio panel_qy45043a0 drm wave5 ml_mmzheap ml_dmablit ar_scaler
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
    check PASS "display, codec and RF modules loaded"
else
    check FAIL "display, codec and RF modules loaded" "missing:$missing"
fi

# --- the RF chip enumerated as itself --------------------------------------------------------
# 0x8030 is the pre-firmware id, 0x8031 the post-upload one; anything else is the corrupt power-up
# state, where nothing downstream exists to report a fault.
devid="$(field sdio_devid)"
case "$devid" in
    *0x8031*|*0x8030*)
        check PASS "AR8030 SDIO id" "$devid, fw $(field rf_fw)"
        ;;
    "")
        check FAIL "AR8030 SDIO id" "no SDIO device - the chip never enumerated"
        ;;
    *)
        check FAIL "AR8030 SDIO id" "$devid is the corrupt power-up id - needs a battery-out cold cycle"
        ;;
esac

addr="$(field sdio_addr)"
if [ -n "$addr" ]
then
    check PASS "sdio0 up" "$addr"
else
    check FAIL "sdio0 up" "no address - RF bring-up did not complete"
fi

# Two ml-linkd on /dev/artosyn_sdio wedge the chip permanently. The banner count catches a restart
# that the process count cannot.
procs="$(field proc_ml-linkd)"
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

# --- the rest of the daemon set ----------------------------------------------------------------
absent=""
extra=""
for p in ml-pipeline ml-hud ml-drmfd ml-ledd ml-logd
do
    n="$(field "proc_$p")"
    case "${n:-0}" in
        1)  ;;
        0)  absent="$absent $p" ;;
        *)  extra="$extra $p(${n})" ;;
    esac
done
if [ -z "$absent" ] && [ -z "$extra" ]
then
    check PASS "one each of the ml daemons"
elif [ -n "$absent" ]
then
    check FAIL "one each of the ml daemons" "not running:$absent"
else
    check FAIL "one each of the ml daemons" "duplicated:$extra"
fi

sockets="$(field sockets)"
missing=""
for s in ctrl.sock drm.sock led.sock link.sock osd.sock telemetry.sock
do
    case " $sockets " in
        *" $s "*)
            ;;
        *)
            missing="$missing $s"
            ;;
    esac
done
if [ -z "$missing" ]
then
    check PASS "IPC sockets published"
else
    check FAIL "IPC sockets published" "missing:$missing"
fi

# --- the panel is alive --------------------------------------------------------------------------
if [ "$(field drm_card)" = yes ] && [ "$(field connector)" = connected ]
then
    check PASS "card0 present, panel connected"
else
    check FAIL "card0 present, panel connected" "card0=$(field drm_card) connector=$(field connector)"
fi

# A dead-panel boot leaves every process running and every log clean, so the vsync counter is the
# only thing that separates it from a live one.
vo_a="$(field vo_a)"
vo_b="$(field vo_b)"
if [ -n "$vo_a" ] && [ -n "$vo_b" ]
then
    hz=$(( (vo_b - vo_a) / SAMPLE ))
    if [ "$hz" -ge 55 ] && [ "$hz" -le 70 ]
    then
        check PASS "panel scanning out" "${hz} Hz from artosyn-vo IRQs"
    elif [ "$hz" -gt 0 ]
    then
        check WARN "panel scanning out" "${hz} Hz - expected ~60"
    else
        check FAIL "panel scanning out" "no artosyn-vo interrupts in ${SAMPLE}s - the panel is dark"
    fi
else
    check FAIL "panel scanning out" "no artosyn-vo interrupt line"
fi

if [ "$(field drm_sink)" -ge 1 ] 2>/dev/null
then
    check PASS "pipeline bound its DRM output"
else
    check FAIL "pipeline bound its DRM output" "no 'DRM output connector' line - the sink never came up"
fi

blit="$(field tile_blit)"
case "$blit" in
    DMA*)
        check PASS "tile blit on the DMA engine" "$blit"
        ;;
    "")
        check WARN "tile blit on the DMA engine" "no tile blit line"
        ;;
    *)
        check FAIL "tile blit on the DMA engine" "$blit"
        ;;
esac

if [ "$(field overlay)" -ge 1 ] 2>/dev/null
then
    check PASS "HUD overlay plane enabled"
else
    check FAIL "HUD overlay plane enabled" "no 'overlay plane enabled' line - the OSD has no plane"
fi

# --- codec ----------------------------------------------------------------------------------------
faults="$(field vpu_faults)"
if [ "${faults:-0}" -eq 0 ]
then
    check PASS "no codec watchdog or syserr"
else
    check FAIL "no codec watchdog or syserr" "$faults matching dmesg lines"
fi

# --- what the radio received -------------------------------------------------------------------------
# WARN rather than FAIL throughout: a bench goggle with no air unit powered is a legitimate state.
rx_a="$(field rx_a)"
rx_b="$(field rx_b)"
if [ -n "$rx_a" ] && [ -n "$rx_b" ]
then
    kbps=$(( (rx_b - rx_a) * 8 / SAMPLE / 1000 ))
    tx_delta=$(( $(field tx_b) - $(field tx_a) ))
    if [ "$kbps" -gt 0 ]
    then
        check PASS "downlink arriving" "${kbps} kbit/s, TX ${tx_delta} B in ${SAMPLE}s"
    else
        check WARN "downlink arriving" "sdio0 RX idle - no air unit linked (TX ${tx_delta} B)"
    fi
fi

vpu_a="$(field vpu_a)"
vpu_b="$(field vpu_b)"
if [ -n "$vpu_a" ] && [ -n "$vpu_b" ]
then
    vpu_rate=$(( (vpu_b - vpu_a) / SAMPLE ))
    if [ "$vpu_rate" -gt 0 ]
    then
        check PASS "decoder running" "${vpu_rate} vpu IRQ/s"
    else
        check WARN "decoder running" "no vpu interrupts - nothing to decode"
    fi
fi

# --- storage ---------------------------------------------------------------------------------------
case "$(field usrdata)" in
    rw)
        check PASS "/usrdata mounted rw" "settings and RF config persist"
        ;;
    "")
        check FAIL "/usrdata mounted rw" "not mounted - settings and a bind are lost on power-off"
        ;;
    *)
        check FAIL "/usrdata mounted rw" "mounted $(field usrdata)"
        ;;
esac

sdcard="$(field sdcard)"
if [ -n "$sdcard" ]
then
    check PASS "SD card mounted" "$sdcard at /mnt/sdcard"
else
    check WARN "SD card mounted" "no card at /mnt/sdcard - DVR has nowhere to write"
fi

if [ "$(field persist)" = yes ]
then
    check PASS "ml-rf-persist present" "a bind can survive a power cycle"
else
    check FAIL "ml-rf-persist present" "a bind would be runtime-only and lost on power-off"
fi

check INFO "junction temperature" "$(field temp_c) C"
check INFO "CMA free" "$(field cma_free) kB, MemAvailable $(field mem_avail) kB"

echo
if [ "$fails" -eq 0 ]
then
    echo "gg-health: all checks passed"
else
    echo "gg-health: $fails check(s) FAILED"
fi

exit $(( fails > 0 ))
