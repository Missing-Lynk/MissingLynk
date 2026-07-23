#!/usr/bin/env bash
# device.sh - resolve the active device and load its config into the environment, so glue
# scripts stay device-agnostic.
#
# Source AFTER ssh-opts.sh:
#   . "$(dirname "${BASH_SOURCE[0]}")/../lib/device.sh"
#
# Active device: $DEVICE if already set (the Makefile targets export it), else the name in
# .device (written by `make setup DEVICE=<name>`), else the goggle. The device's manifest
# (devices/<name>/device.mk) and rootfs profile (rootfs/devices/<name>/board.conf) are the
# single source of truth; this reads from them:
#   DEV_DTB, DEV_KADDR, DEV_RDADDR, DEV_DTADDR   (device.mk - dtb basename + RAM load map)
#   PARTITION, ROOT_PASS                         (board.conf - slot-B partition + open password)
# A value already in the environment always wins (explicit per-invocation override).

_DEVICE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ML_REPO="${ML_REPO:-$(cd "$_DEVICE_LIB_DIR/../.." && pwd)}"

# Explicit $DEVICE wins; else the persisted selection; else warn and use the compiled default so
# an operator RAM-booting an un-set-up unit sees they may get the wrong load map / dtb.
if [ -n "${DEVICE:-}" ]; then
    :
elif [ -f "$ML_REPO/.device" ]; then
    DEVICE="$(cat "$ML_REPO/.device")"
else
    DEVICE="betafpv-vr04-goggle"
    echo "[device.sh] no DEVICE set and no .device - defaulting to $DEVICE. If this is another" >&2
    echo "            unit, its load map/dtb will be wrong; run: make setup DEVICE=<name>" >&2
fi

_ML_DEV_MK="$ML_REPO/devices/$DEVICE/device.mk"
_ML_BOARD_CONF="$ML_REPO/rootfs/devices/$DEVICE/board.conf"
[ -f "$_ML_DEV_MK" ] || { echo "[device.sh] no manifest for device '$DEVICE' ($_ML_DEV_MK)" >&2; exit 1; }

# dev_mk <KEY> - value of a `KEY = VALUE` line in device.mk (strips inline # comment + spaces).
dev_mk() {
    sed -n "s/^$1[[:space:]]*=[[:space:]]*\([^#]*\).*/\1/p" "$_ML_DEV_MK" | sed 's/[[:space:]]*$//' | head -1
}

DEV_DTB="${DEV_DTB:-$(dev_mk DEV_DTB)}"
DEV_KADDR="${DEV_KADDR:-$(dev_mk DEV_KADDR)}"
DEV_RDADDR="${DEV_RDADDR:-$(dev_mk DEV_RDADDR)}"
DEV_DTADDR="${DEV_DTADDR:-$(dev_mk DEV_DTADDR)}"

# board.conf (shell) carries PARTITION (slot-B UBI target, resolved by NAME on the device) and
# ROOT_PASS (open-slot password). Sourcing it also sets the USB-gadget vars, harmlessly. NOTE:
# board.conf sets ROOT_PASS="libre" unconditionally, so scripts that need the slot-A vendor
# password (artosyn) must capture PASS BEFORE sourcing this (ssh-opts.sh freezes PASS first).
if [ -f "$_ML_BOARD_CONF" ]; then
    # shellcheck source=/dev/null
    . "$_ML_BOARD_CONF"
fi

# ML_UBI_PARTITION: the slot-B rootfs partition NAME for the kernel cmdline (ubi.mtd=<name>);
# device-agnostic because the kernel resolves the MTD by name from the DTB partition table.
ML_UBI_PARTITION="${ML_UBI_PARTITION:-${PARTITION:-userapp1}}"

# DEVICE_IP: if ssh-opts.sh only applied its compiled fallback (no explicit caller value), the
# active device's gadget address from board.conf is the real target.
if [ -n "${_ML_DEVICE_IP_DEFAULTED:-}" ] && [ -n "${GADGET_IP:-}" ]; then
    DEVICE_IP="$GADGET_IP"
fi

# Every STOCK (vendor slot-A) unit uses this gadget address regardless of device; scripts that
# may start from a stock boot fall back to it when DEVICE_IP does not answer.
ML_STOCK_IP="192.168.3.100"
