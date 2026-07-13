#!/usr/bin/env bash
# uboot.sh - shared U-Boot helpers for the RAM-boot scripts. Source after ssh-opts.sh.
#
# Provides ub() (drive uboot_boot.py), drop_to_uboot_retry() (reach the => prompt), and
# ML_BOOTARGS_DEFAULT (the board's full mtdparts cmdline). drop_to_uboot_retry() calls the
# caller-defined sshg() for the between-attempt reachability wait, so define that first.

_UBOOT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ML_UBOOT_PY="$_UBOOT_LIB_DIR/../../.venv/bin/python3"
_UBOOT_DRIVER="$_UBOOT_LIB_DIR/../boot/uboot_boot.py"
_UBOOT_DROP="$_UBOOT_LIB_DIR/../boot/drop-to-uboot.sh"

# bootm does not get partitions from the dtb (unlike an SPL flash boot), so supply the full
# static mtdparts here. ubi.mtd=18 = userapp1 (slot B rootfs).
ML_BOOTARGS_DEFAULT="earlycon keep_bootcon ignore_loglevel console=ttyS0,1152000 mem=148m ubi.mtd=18 root=ubi:rootfs rootfstype=ubifs rw mtdparts=spi32766.1:256k@0(spl0),256k(spl1),256k(spl2),256k(spl3),256k(gpt0),256k(gpt1),512K(vendor),6M(factory),384K(env0),384K(env1),768K(uboot0),768K(uboot1),6M(kernel0),6M(kernel1),384K(dtb0),384K(dtb1),45M(userapp0),45M(userapp1),6M(usr_data),6M(usr_log)"

# Drive uboot_boot.py (load/cmd/...) with the repo venv python.
ub() {
    "$ML_UBOOT_PY" "$_UBOOT_DRIVER" "$@"
}

# Reach the U-Boot => prompt, retrying (the wdt fire / serial catch can race). Returns 1 if
# all three attempts miss. Requires sshg() for the between-attempt reachability wait.
drop_to_uboot_retry() {
    local attempt i
    echo "[*] dropping to U-Boot..."
    for attempt in 1 2 3; do
        if "$_UBOOT_DROP" >/dev/null 2>&1; then
            return 0
        fi

        echo "[*] drop attempt $attempt missed (serial race); waiting for the goggle to re-settle..."
        for i in $(seq 1 20); do
            sshg true 2>/dev/null && break
            sleep 2
        done
    done

    echo "[!] could not reach U-Boot after 3 tries - likely a wedged serial adapter; re-plug it and re-run." >&2
    return 1
}
