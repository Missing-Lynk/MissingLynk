#!/usr/bin/env bash
# au-camera.sh - transport prologue for the air-unit camera scripts under glue/camera.
#
# Source it INSTEAD of ssh-opts.sh:
#   . "$(dirname "${BASH_SOURCE[0]}")/../lib/au-camera.sh"
#
# Sources ssh-opts.sh (and through it device.sh), so sshg, device_push, device_push_as and
# device_pull already target the active device: board.conf gives GADGET_IP 192.168.3.102 and
# ROOT_PASS libre, the slot-B pair these scripts used to hardcode. Adds three things on top:
# the AU_IP / AU_PASS / AU_PORT overrides, an air-unit assertion, and au_stock_slot_a.

# Both overrides go in BEFORE ssh-opts.sh: it freezes PASS from ROOT_PASS ahead of board.conf,
# and treats an already-set DEVICE_IP as the caller's.
if [ -n "${AU_IP:-}" ]; then
    DEVICE_IP="$AU_IP"
fi

if [ -n "${AU_PASS:-}" ]; then
    ROOT_PASS="$AU_PASS"
fi

if [ -n "${AU_PORT:-}" ]; then
    # shellcheck disable=SC2034  # read by the transport helpers in ssh-opts.sh
    DEVICE_PORT="$AU_PORT"
fi

_AU_CAMERA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_AU_CAMERA_LIB_DIR/ssh-opts.sh"

# Every script here loads air-unit camera modules and reads air-unit register blocks, and the
# address now follows the active device, so a goggle profile would aim one at the wrong board.
# RF_ROLE is board.conf's role field (air = TX side).
if [ "${RF_ROLE:-}" != "air" ]; then
    if [ -n "${AU_IP:-}" ]; then
        echo "[*] active device '$DEVICE' is not an air unit; using the explicit AU_IP=$AU_IP" >&2
    else
        echo "refusing: glue/camera is air-unit-only and the active device is '$DEVICE'" >&2
        echo "  Run: make setup DEVICE=betafpv-vr04-air   (or set DEVICE= / AU_IP= for this run)" >&2
        exit 1
    fi
fi

# The goggle's address on the RF link, which is what the AU reaches over sdio0 once the chip has
# associated. ml-air-video sends video to port 10001 there.
AU_RF_PEER="${AU_RF_PEER:-10.0.0.1}"

# au_require_rf_link - refuse to continue unless sdio0 is up, and print what it is.
#
# A link-down run still looks healthy from the AU side: sendto() fails per frame, but the frame
# counters count encoder output, so a bench reports its full rate while nothing reaches the
# goggle. A run costs a battery on both boards, so it is cheaper to refuse than to re-read.
au_require_rf_link() {
    if sshg "ip -br addr show sdio0 2>/dev/null | grep -q UP" </dev/null; then
        sshg "ip -br addr show sdio0; ip route get $AU_RF_PEER 2>&1 | head -1" </dev/null
        return 0
    fi

    echo "sdio0 is not up: ml-air-link brings RF up at boot, so this is a link failure" >&2
    echo "  check: rc-service ml-air-link status; dmesg | grep -i artosyn_sdio" >&2
    echo "  never warm-reload artosyn_sdio; RF does not recover its TX credit. Re-boot." >&2
    exit 1
}

# au_stock_slot_a - retarget at the STOCK vendor system, ML_STOCK_IP/ML_STOCK_PASS. AU_IP and
# AU_PASS still win. No probe: the callers gate on their own first command. Where the wrong slot
# is destructive rather than useless (the flashers) use ensure_stock_slot_a from ssh-opts.sh.
# shellcheck disable=SC2034  # DEVICE_IP/PASS/ROOT_PASS are read by the helpers in ssh-opts.sh
au_stock_slot_a() {
    if [ -z "${AU_IP:-}" ]; then
        DEVICE_IP="$ML_STOCK_IP"
    fi

    if [ -z "${AU_PASS:-}" ]; then
        PASS="$ML_STOCK_PASS"
        ROOT_PASS="$PASS"
    fi
}

# au_require_cvisp [min-depth] - refuse unless ar_cvisp is loaded, and unless its hold depth is
# at least min-depth when one is given. Loaded proves only the boot auto-load, not a configured
# chain; callers that need the tuning blob check for that separately. Leaves the depth it read
# in AU_CVISP_DEPTH for callers that report it.
au_require_cvisp() {
    local min="${1:-}"

    if ! sshg 'lsmod | grep -q "^ar_cvisp "' </dev/null; then
        echo "ar_cvisp is not loaded: run CVDEPTH=${min:-3} glue/camera/au-v4l2-chain.sh first" >&2
        exit 1
    fi

    if [ -n "$min" ]; then
        AU_CVISP_DEPTH=$(sshg 'cat /sys/module/ar_cvisp/parameters/depth' </dev/null | tr -d '\r\n')
        if [ "${AU_CVISP_DEPTH:-0}" -lt "$min" ]; then
            echo "cvisp depth is ${AU_CVISP_DEPTH:-unknown}, this needs $min: run CVDEPTH=$min glue/camera/au-v4l2-chain.sh" >&2
            exit 1
        fi
    fi
}

# au_find_cvisp_node - print the /dev/videoN whose driver name is ar-cvisp, or nothing. The
# index depends on probe order, so it is read from sysfs rather than assumed; v4l2-ctl is not
# on the slim rootfs, and the driver's own vdev name is what identifies the node.
au_find_cvisp_node() {
    # shellcheck disable=SC2016  # runs on the device, must not expand here
    sshg 'for p in /sys/class/video4linux/video*; do
	[ "$(cat "$p/name" 2>/dev/null)" = ar-cvisp ] || continue
	echo "/dev/${p##*/}"
	break
done' </dev/null | tr -d '\r\n'
}

# au_require_num <label> <value> - exit unless value is a plain number. A dropped ssh returns an
# empty sample, and shell arithmetic reads empty as 0, which would present a whole lifetime
# counter as one window's traffic. Every counter sample goes through this.
au_require_num() {
    case "$2" in
    '' | *[!0-9]*)
        echo "$1 came back as '$2': the counter read failed" >&2
        exit 1
        ;;
    esac
}

# au_air_video_running - is ml-air-video alive on the unit? pgrep/pkill -f match their own
# command line on this busybox, so ask killall what it would find instead.
au_air_video_running() {
    sshg "killall -0 ml-air-video 2>/dev/null" </dev/null
}

# au_refuse_air_video_running - refuse when an instance is live: its encoder instance pair is
# this boot's only usable one, so starting a second encodes garbage or watchdogs the firmware.
au_refuse_air_video_running() {
    if au_air_video_running; then
        echo >&2
        echo "ml-air-video is already running on the air unit." >&2
        echo "  Its encoder instance pair is this boot's only usable one, so starting a second" >&2
        echo "  encodes garbage or watchdogs the firmware. Reboot and re-run." >&2
        exit 1
    fi
}

# au_ensure_wave5 - refuse to measure against the wrong wave5.ko. The module cannot be reloaded
# warm: probing loads firmware into the VPU, and a second probe without a hardware reset returns
# -16 from vpu_init_with_bitcode, leaving the codec unbound for the rest of the boot. So the
# driver must already be in the booted rootfs; this verifies the installed module against the
# staged build (reads $REPO), installs the build on mismatch, and exits 2: reboot and re-run.
au_ensure_wave5() {
    local ko="$REPO/kernel/build/kernel-repro-6.18.36/ml-modules/rootfs/lib/modules/6.18.36/kernel/wave5.ko"
    local dev_ko=/lib/modules/6.18.36/kernel/wave5.ko
    local want have

    [ -f "$ko" ] || return 0

    want=$(md5sum "$ko" | cut -d' ' -f1)
    have=$(sshg "md5sum $dev_ko 2>/dev/null | cut -d' ' -f1" </dev/null | tr -d '\r\n')
    if [ "$want" = "$have" ]; then
        return 0
    fi

    echo "$dev_ko is not the build under test; installing it"
    echo "  device $have"
    echo "  build  $want"
    device_push "$ko" || exit 1
    sshg "cp /tmp/wave5.ko $dev_ko && sync && md5sum $dev_ko"
    echo
    echo "installed into the rootfs. REBOOT and re-run: the running kernel still has the old"
    echo "module and wave5 cannot be reloaded warm (probe loads firmware; a second probe"
    echo "returns -16 and unbinds the codec for the rest of the boot)."
    exit 2
}

# One access unit goes in one UDP datagram, so the per-frame ceiling is a hard protocol limit.
AU_UDP_PAYLOAD_MAX=65507
AU_VPH_HEADER=36
AU_VPH_TAIL=4

# au_derive_vbv <bitrate> - set AU_LIMIT (datagram payload ceiling in bytes) and VBV (window in
# ms; a caller-set VBV wins). VBV is the lever that sets the per-frame byte ceiling: a window of
# vbv ms permits vbv * bitrate / 8000 bytes. Derived from the bitrate rather than fixed, because
# a value that is safe at one bitrate is not at another. 3/4 of the exact ceiling leaves room
# for the header overhead the window does not model.
au_derive_vbv() {
    local bitrate="$1" vbv_max

    AU_LIMIT=$(( AU_UDP_PAYLOAD_MAX - AU_VPH_HEADER - AU_VPH_TAIL ))
    vbv_max=$(( AU_LIMIT * 8000 * 3 / 4 / bitrate ))
    [ "$vbv_max" -lt 10 ] && vbv_max=10
    [ "$vbv_max" -gt 3000 ] && vbv_max=3000
    VBV="${VBV:-$vbv_max}"
}

# au_enc_controls_env - append the encoder element string to ENV_ARGS. The one source for the
# knob set both the bench and the camera run pass, so a knob added to one cannot silently miss
# the other and unpair the two measurements. Reads GOP, BITRATE, MINQP, MAXQP, IQP, MBRC, VBV.
# shellcheck disable=SC2153  # BITRATE is the caller's knob, not a misspelling of bitrate above
au_enc_controls_env() {
    ENV_ARGS="$ENV_ARGS ML_AIR_ENC=\"v4l2h265enc output-io-mode=dmabuf-import"
    ENV_ARGS="$ENV_ARGS extra-controls=\\\"controls,video_gop_size=$GOP,frame_level_rate_control_enable=1"
    ENV_ARGS="$ENV_ARGS,video_bitrate=$BITRATE,video_bitrate_mode=1"
    ENV_ARGS="$ENV_ARGS,hevc_minimum_qp_value=$MINQP,hevc_maximum_qp_value=$MAXQP"
    ENV_ARGS="$ENV_ARGS,hevc_i_frame_qp_value=$IQP"
    ENV_ARGS="$ENV_ARGS,h264_mb_level_rate_control=$MBRC"
    ENV_ARGS="$ENV_ARGS,vbv_buffer_size=$VBV\\\"\""
}

# au_encoder_health - the closing dmesg sweep for anything the encoder or capture path logged.
au_encoder_health() {
    echo
    echo "=== encoder health ==="
    sshg "dmesg | grep -iE 'watchdog|syserr|enc instance|PIC_RUN|vdi pool|cvisp' | tail -15" </dev/null
}
