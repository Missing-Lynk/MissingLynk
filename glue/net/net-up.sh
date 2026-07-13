#!/usr/bin/env bash
# Bring up the host side of the USB-ethernet link to an Artosyn unit (Linux).
#
# Works for BOTH the goggle (P1_GND) and the air unit (P1_SKY): each exposes the
# same USB gadget at 192.168.3.100 (root/artosyn), so plug in either one.
#
# Assigns the static host IP to the gadget interface and brings it up, then SSHes
# in to identify which unit it is.
#
# Run once per boot: the gadget re-randomizes its MAC each boot, so the host
# interface name (enx<mac>) changes and the IP must be re-applied.
#
# Install 99-artosyn-unmanaged.conf (same dir) FIRST, or NetworkManager will keep
# flushing this address. See glue/docs/host-network-setup.md.
#
# It calls sudo for the `ip` commands. Override defaults via env, e.g.
#   UNIT_IP=192.168.3.100 HOST_IP=192.168.3.222 ./glue/net/net-up.sh
set -euo pipefail

# UNIT_IP: the goggle or air unit (same gadget address for either).
UNIT_IP="${UNIT_IP:-192.168.3.100}"
HOST_IP="${HOST_IP:-192.168.3.222}"

IF="$(ip -br link | awk '/enx/{print $1; exit}')"
if [ -z "$IF" ]; then
    echo "No enx* (USB-ethernet) interface - is the goggle or air unit plugged in & powered?" >&2
    exit 1
fi

echo "Interface: $IF  ->  $HOST_IP/24"
if ! sudo ip addr add "$HOST_IP/24" dev "$IF" 2>/dev/null; then
    echo "  (address already present)"
fi

sudo ip link set "$IF" up
sleep 2

if ! ping -c1 -W2 "$UNIT_IP" >/dev/null 2>&1; then
    echo "Not reachable yet - the unit may still be booting"
    exit 0
fi

# Name the unit that answered. The CLI owns the identity (paramiko, same legacy
# crypto as the rest of the stack, no sshpass); this script just prints what it
# returns. Only available when the .venv is on PATH; otherwise report reachable.
dev=""
if command -v missinglynk >/dev/null 2>&1; then
    dev="$(missinglynk --ip "$UNIT_IP" identify 2>/dev/null)"
fi

if [ -n "$dev" ]; then
    echo "OK: $dev reachable at $UNIT_IP"
else
    echo "OK: a unit is reachable at $UNIT_IP (activate the .venv for 'missinglynk identify' to name it)"
fi
