#!/bin/sh
# artosyn-bridge-attach.sh <ifname> - enslave a USB-ethernet gadget interface into the
# br-artosyn bridge, creating the bridge (with the host address) on first use.
#
# Invoked by udev on every enx* add event (99-artosyn-bridge.rules, same dir), so a device
# plug-in or reboot needs no manual net-up run. Idempotent; safe to run by hand.
BRIDGE="br-artosyn"
HOST_IP="192.168.3.222"

IF="$1"
[ -n "$IF" ] || exit 1

if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
    ip link add "$BRIDGE" type bridge
fi
ip addr add "$HOST_IP/24" dev "$BRIDGE" 2>/dev/null || true
ip link set "$BRIDGE" up

ip addr flush dev "$IF"
ip link set "$IF" master "$BRIDGE"
ip link set "$IF" up
