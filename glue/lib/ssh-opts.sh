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
# DEVICE_IP / PASS before sourcing).
: "${DEVICE_IP:=192.168.3.100}"
: "${PASS:=${ROOT_PASS:-libre}}"   # libre = open slot B; ROOT_PASS=artosyn for stock slot A

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
