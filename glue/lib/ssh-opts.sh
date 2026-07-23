#!/usr/bin/env bash
# ssh-opts.sh - shared SSH client options for the goggle and air unit.
#
# Source from a glue script (adjust ../ depth to reach glue/lib):
#   . "$(dirname "${BASH_SOURCE[0]}")/../lib/ssh-opts.sh"
#
# SSH_OPTS_LIBRE:  open slot-B sshd (Alpine, modern crypto)
# SSH_OPTS_LEGACY: superset adding the legacy algorithms the vendor Dropbear
#                  (stock slot A, air unit) needs; the '+' additions are
#                  harmless against the open sshd, so scripts that may talk
#                  to either stack use this one
#
# Both skip host-key persistence (slot hops change the key) and silence the
# resulting per-connection "Permanently added" notice. OpenSSH keeps the FIRST
# value it sees for an option, so per-script overrides go before the array:
#   ssh -o ConnectTimeout=25 "${SSH_OPTS_LEGACY[@]}" ...
#
# Also provides sshg() (run a root command on $DEVICE_IP with $PASS), device_ssh() (same, with
# explicit pass+ip args), and device_ssh_timeout() (sshg wrapped in `timeout`), so scripts stop
# redefining that one-liner.

SSH_OPTS_LIBRE=(
    -o StrictHostKeyChecking=no
    -o LogLevel=ERROR
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=8
)

SSH_OPTS_LEGACY=(
    -o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1
    -o HostKeyAlgorithms=+ssh-rsa,ssh-dss
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o Ciphers=+aes128-ctr,aes128-cbc,3des-cbc
    -o MACs=+hmac-sha1
    "${SSH_OPTS_LIBRE[@]}"
)

# Default device coordinates for sshg. Override by exporting DEVICE_IP / ROOT_PASS (or setting
# DEVICE_IP / PASS before sourcing). _ML_DEVICE_IP_DEFAULTED marks the placeholder so device.sh
# (sourced just below) replaces it with the active device's GADGET_IP from board.conf; an
# explicit caller-set DEVICE_IP is left untouched.
if [ -z "${DEVICE_IP:-}" ]; then
    DEVICE_IP="192.168.3.100"
    _ML_DEVICE_IP_DEFAULTED=1
fi
: "${PASS:=${ROOT_PASS:-libre}}"   # libre = open slot B; ROOT_PASS=artosyn for stock slot A
                                   # (freeze PASS BEFORE device.sh sources board.conf's ROOT_PASS)

# Resolve DEVICE_IP from the active device profile (the single source of truth): device.sh reads
# DEVICE / .device -> devices/<name>/board.conf and, via the placeholder flag above, sets
# DEVICE_IP to that device's GADGET_IP (goggle by default, with device.sh's own warning). Sourced
# here so every glue script that pulls in ssh-opts.sh follows the active device without also
# having to source device.sh. Re-sourcing device.sh later (ram-boot) is idempotent.
_SSH_OPTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_SSH_OPTS_LIB_DIR/device.sh" ]; then
    # shellcheck source=/dev/null
    . "$_SSH_OPTS_LIB_DIR/device.sh"
fi

# sshg <cmd...> - run a command on the device as root over the legacy-compatible transport.
# Reads $DEVICE_IP and $PASS (defaulted above). For a one-off host/password (a credential probe,
# or the air unit) use device_ssh with explicit args instead.
sshg() {
    sshpass -p "$PASS" ssh "${SSH_OPTS_LEGACY[@]}" root@"$DEVICE_IP" "$@"
}

# device_ssh <pass> <ip> <cmd...> - explicit-credential variant of sshg (no globals).
device_ssh() {
    local pass="$1" ip="$2"
    shift 2
    sshpass -p "$pass" ssh "${SSH_OPTS_LEGACY[@]}" root@"$ip" "$@"
}

# device_ssh_timeout <secs> <cmd...> - sshg bounded by `timeout <secs>`. A caller cannot write
# `timeout N sshg ...` because timeout execs a program and sshg is a shell function; this keeps
# the transport spelling in one place. Reads $DEVICE_IP and $PASS like sshg.
device_ssh_timeout() {
    local secs="$1"
    shift
    timeout "$secs" sshpass -p "$PASS" ssh "${SSH_OPTS_LEGACY[@]}" root@"$DEVICE_IP" "$@"
}

# ensure_device_reachable - confirm the target answers SSH as root/$PASS. If the open slot-B
# address is silent but the unit is sitting on stock slot A ($ML_STOCK_IP, root/$STOCK_PASS,
# default artosyn), retarget DEVICE_IP/PASS/ROOT_PASS to it so a drop can still proceed from
# stock. Exports DEVICE_IP/ROOT_PASS so drop children (drop-to-uboot.sh) inherit them. Returns
# nonzero (after printing why) if neither the open nor the stock address answers.
ensure_device_reachable() {
    if ! sshg true 2>/dev/null; then
        # Auto-fallback to stock slot A only when the ACTIVE device legitimately owns the stock
        # address: every unit's stock slot boots at $ML_STOCK_IP, so on the shared br-artosyn
        # bridge this is unambiguous ONLY for the device whose GADGET_IP is $ML_STOCK_IP (the
        # goggle, NN=0). For any other device, retargeting to $ML_STOCK_IP could silently hit a
        # different unit, so fail and let the operator target stock explicitly.
        if [ "${GADGET_IP:-}" = "$ML_STOCK_IP" ] && device_ssh "${STOCK_PASS:-artosyn}" "$ML_STOCK_IP" true 2>/dev/null; then
            echo "[*] $DEVICE_IP not answering; unit is on stock slot A at $ML_STOCK_IP - using that for the drop"
            DEVICE_IP="$ML_STOCK_IP"
            PASS="${STOCK_PASS:-artosyn}"
            ROOT_PASS="$PASS"
        else
            echo "[!] cannot SSH $DEVICE_IP as root/$PASS - is the unit up and reachable? (on stock slot A, target $ML_STOCK_IP as root/artosyn)"
            return 1
        fi
    fi
    export DEVICE_IP ROOT_PASS
}
