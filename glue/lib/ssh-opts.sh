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

# shellcheck disable=SC2054  # the commas separate values WITHIN one ssh option argument
# (KexAlgorithms=a,b), they are not array element separators.
SSH_OPTS_LEGACY=(
    -o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1
    -o HostKeyAlgorithms=+ssh-rsa,ssh-dss
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o Ciphers=+aes128-ctr,aes128-cbc,3des-cbc
    -o MACs=+hmac-sha1
    "${SSH_OPTS_LIBRE[@]}"
)

# DEVICE_IP is resolved from the active device profile by device.sh (sourced just below). When the
# caller left it unset, flag that so device.sh fills it with the active device's GADGET_IP from
# board.conf; an explicit caller-set DEVICE_IP / ROOT_PASS wins.
if [ -z "${DEVICE_IP:-}" ]; then
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
# address is silent but the unit is sitting on stock slot A ($ML_STOCK_IP, root/$ML_STOCK_PASS),
# retarget DEVICE_IP/PASS/ROOT_PASS to it so a drop can still proceed from stock. Exports
# DEVICE_IP/ROOT_PASS so drop children (drop-to-uboot.sh) inherit them. Returns nonzero (after
# printing why) if neither the open nor the stock address answers.
ensure_device_reachable() {
    if ! sshg true 2>/dev/null; then
        # $ML_STOCK_IP identifies the stock unit currently plugged in (one stock unit at a time,
        # per net-up.sh). When the active device's open-slot address is silent, assume that device
        # is on stock slot A and retarget to $ML_STOCK_IP with the stock password, warning about
        # the assumption.
        if device_ssh "$ML_STOCK_PASS" "$ML_STOCK_IP" true 2>/dev/null; then
            echo "[*] $DEVICE_IP silent; assuming the stock unit at $ML_STOCK_IP is $DEVICE - using it for the drop (root/$ML_STOCK_PASS)"
            DEVICE_IP="$ML_STOCK_IP"
            PASS="$ML_STOCK_PASS"
            ROOT_PASS="$PASS"
        else
            echo "[!] cannot SSH $DEVICE_IP as root/$PASS - is the unit up and reachable? (on stock slot A, target $ML_STOCK_IP as root/$ML_STOCK_PASS)"
            return 1
        fi
    fi
    # Children (drop-to-uboot.sh) re-derive PASS from ROOT_PASS, and board.conf sourcing may have
    # overwritten ROOT_PASS since PASS was frozen - export the password that actually answered.
    ROOT_PASS="$PASS"
    export DEVICE_IP ROOT_PASS
}

# ensure_stock_slot_a - confirm the target is running the STOCK vendor system (slot A) and point
# DEVICE_IP/PASS/ROOT_PASS at it, so sshg talks to it. For the slot-B flashers: writing a slot
# while that slot is the one running is destructive, so they must drive the flash from slot A.
#
# A stock unit always answers at $ML_STOCK_IP, so that is the target unless the caller set
# DEVICE_IP explicitly. When it stays silent, the active device's own open-slot address
# ($GADGET_IP) is probed with the open password: an answer there means the unit is booted on
# slot B, which is a refusal with the way back to A rather than a bare connection error.
#
# Returns nonzero (after printing why) if the unit is on slot B or answers nowhere.
ensure_stock_slot_a() {
    local open_ip="${GADGET_IP:-}" open_pass="${ROOT_PASS:-libre}"

    if [ -n "${_ML_DEVICE_IP_DEFAULTED:-}" ]; then
        DEVICE_IP="$ML_STOCK_IP"
    fi
    PASS="$ML_STOCK_PASS"

    echo "[*] checking $DEVICE_IP is booted on slot A (stock vendor)..."
    if sshg true 2>/dev/null; then
        echo "[+] confirmed: slot A (root/$PASS)"
        ROOT_PASS="$PASS"
        export DEVICE_IP ROOT_PASS
        return 0
    fi

    if [ -n "$open_ip" ] && device_ssh "$open_pass" "$open_ip" true 2>/dev/null; then
        echo "refusing: $DEVICE ($open_ip) is on slot B (open Alpine), not slot A." >&2
        echo "  Run: glue/boot/flip-slot.sh a   (then re-run this script once it's back up)" >&2
        return 1
    fi

    echo "cannot SSH to $DEVICE_IP as root/$PASS - is it booted and on slot A?" >&2
    return 1
}
