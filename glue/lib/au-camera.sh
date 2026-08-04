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
