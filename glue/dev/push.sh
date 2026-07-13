#!/usr/bin/env bash
# push.sh - copy a file or directory to the open slot-B goggle over SSH.
#
# The slot-B open kernel's SSH server has NO sftp subsystem and there is no `scp` binary
# on the device, so scp is a non-starter. Instead we stream bytes over a plain ssh channel:
#   - a file: `cat local | ssh 'cat > /tmp/<name>'`, then restore its exec bit
#   - a dir : `tar c local | ssh 'tar x -C /tmp'` (gzip'd; busybox tar on the device)
#
# Target dir is /tmp: the open rootfs mounts a 32 MB exec-allowed tmpfs there
# (rootfs/skeleton/etc/fstab), so pushed binaries both fit and can execute. (/run at 27 MB
# also works; /dev/shm is bigger but mounted noexec.)
#
# Usage:
#   push.sh <file-or-dir> [more...]        # each lands at /tmp/<basename>
#   push.sh kernel/test_tools/build/button_test
#   DEST=/dev/shm push.sh big.bin          # override the target dir (noexec there!)
#
# Env overrides: DEVICE_IP (192.168.3.100), ROOT_PASS (libre),
# DEST (/tmp).
# Preconditions: the device is on the OPEN slot-B Alpine (root/libre) and reachable at DEVICE_IP.
set -euo pipefail

DEVICE_IP="${DEVICE_IP:-192.168.3.100}"
PASS="${ROOT_PASS:-libre}"
DEST="${DEST:-/tmp}"

[ "$#" -ge 1 ] || { sed -n '2,/^set -/p' "$0" | sed 's/^# \?//; s/^set -.*//'; exit 2; }
command -v sshpass >/dev/null || { echo "[!] sshpass not installed"; exit 1; }

. "$(dirname "$0")/../lib/ssh-opts.sh"
SSHOPTS=("${SSH_OPTS_LEGACY[@]}")
sshg() { sshpass -p "$PASS" ssh "${SSHOPTS[@]}" root@"$DEVICE_IP" "$@"; }

sshg true 2>/dev/null || { echo "[!] cannot SSH $DEVICE_IP as root/$PASS — is the device on the open slot-B Alpine?"; exit 1; }
sshg "mkdir -p '$DEST'" 2>/dev/null

for SRC in "$@"; do
  [ -e "$SRC" ] || { echo "[!] no such file/dir: $SRC" >&2; exit 1; }
  base="$(basename "$SRC")"

  if [ -d "$SRC" ]; then
    echo "[*] dir  $SRC -> $DEST/$base/ ..."
    tar -C "$(dirname "$SRC")" -czf - "$base" | sshg "tar -xzf - -C '$DEST'"
    echo "[+] $DEST/$base/  ($(sshg "find '$DEST/$base' -type f | wc -l") files)"
  else
    echo "[*] file $SRC -> $DEST/$base ..."

    # Keep the local exec bit so pushed binaries/scripts run as-is.
    mode=755; [ -x "$SRC" ] || mode=644
    sshg "cat > '$DEST/$base' && chmod $mode '$DEST/$base'" < "$SRC"
    echo "[+] $DEST/$base  ($(sshg "stat -c%s '$DEST/$base'") B, mode $mode)"
  fi
done
