#!/usr/bin/env bash
# uboot.sh - shared U-Boot helpers for the RAM-boot scripts. Source after ssh-opts.sh.
#
# Provides ub() (drive uboot_boot.py), drop_to_uboot_retry() (reach the => prompt), and
# ML_BOOTARGS_DEFAULT (the RAM-boot cmdline, built from the active device's partition table and
# slot-B rootfs partition). drop_to_uboot_retry() calls the caller-defined sshg() for the
# between-attempt reachability wait, so define that first.

_UBOOT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ML_UBOOT_PY="$_UBOOT_LIB_DIR/../../.venv/bin/python3"
_UBOOT_DRIVER="$_UBOOT_LIB_DIR/../boot/uboot_boot.py"
_UBOOT_DROP="$_UBOOT_LIB_DIR/../boot/drop-to-uboot.sh"

# The cmdline's partition facts both come from the active device profile: ML_UBI_PARTITION (the
# slot-B rootfs partition NAME, set by device.sh from board.conf's PARTITION) and DEV_MTDPARTS
# (the flash partition table, from device.mk). The kernel resolves ubi.mtd= against the mtdparts
# names, so the cmdline carries no partition index. Sourced here for callers that reach uboot.sh
# directly (ramboot-at-uboot.sh); re-sourcing device.sh after ssh-opts.sh already pulled it in is
# idempotent.
if [ -z "${ML_UBI_PARTITION:-}" ] || [ -z "${DEV_MTDPARTS:-}" ]; then
    # shellcheck source=/dev/null
    . "$_UBOOT_LIB_DIR/device.sh"
fi

[ -n "${DEV_MTDPARTS:-}" ] || {
    echo "[uboot.sh] no DEV_MTDPARTS for device '${DEVICE:-?}' - add the flash partition table to" >&2
    echo "           devices/${DEVICE:-?}/device.mk; bootm gets no partitions from the dtb." >&2
    exit 1
}

# bootm does not get partitions from the dtb (unlike an SPL flash boot), so supply the device's
# full mtdparts table here.
# No mem= cap: kernel RAM is bounded by the DTB (truthful 256 MiB memory node + no-map mmz
# carveout). These args therefore REQUIRE a DTB with that memory node; an older DTB whose
# memory node claims 1 GiB would let the kernel run into nonexistent RAM - pass
# BOOTARGS="... mem=148m ..." explicitly if you must boot one (e.g. an old flashed dtb1
# via ram-boot-flashed-b.sh).
# shellcheck disable=SC2034  # read by sourcing scripts (ram-boot.sh, ram-boot-flashed-b.sh,
# ramboot-at-uboot.sh), which pass it to bootm as the default kernel command line.
ML_BOOTARGS_DEFAULT="earlycon keep_bootcon ignore_loglevel console=ttyS0,1152000 ubi.mtd=$ML_UBI_PARTITION root=ubi:rootfs rootfstype=ubifs rw mtdparts=$DEV_MTDPARTS"

# Drive uboot_boot.py (load/cmd/...) with the repo venv python.
ub() {
    "$ML_UBOOT_PY" "$_UBOOT_DRIVER" "$@"
}

# Reach the U-Boot => prompt, retrying (the wdt fire / serial catch can race). Returns 1 if
# all three attempts miss. Requires sshg() for the between-attempt reachability wait.
drop_to_uboot_retry() {
    local attempt _
    echo "[*] dropping to U-Boot..."
    for attempt in 1 2 3; do
        if "$_UBOOT_DROP" >/dev/null 2>&1; then
            return 0
        fi

        echo "[*] drop attempt $attempt missed (serial race); waiting for the goggle to re-settle..."
        for _ in $(seq 1 20); do
            sshg true 2>/dev/null && break
            sleep 2
        done
    done

    echo "[!] could not reach U-Boot after 3 tries - likely a wedged serial adapter; re-plug it and re-run." >&2
    return 1
}
