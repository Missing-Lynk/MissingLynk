#!/usr/bin/env bash
# Bring up the goggle's USB-ethernet link on this PC via DHCP. The goggle must be
# serving DHCP (the `dhcp` component / minidhcpd enabled and running), then this leases
# an address (192.168.3.123) instead of the static IP that net-up.sh assigns.
#
#   sudo bash glue/net/net-dhcp.sh
#
# Companion to net-up.sh (static). Useful once the goggle ships DHCP; the same path a
# phone would use.
set -u

DEVICE_IP="${DEVICE_IP:-192.168.3.100}"

IF=$(ip -o link 2>/dev/null | grep -oE 'enx[0-9a-f]+' | head -1)
if [ -z "$IF" ]; then
    echo "no enx* (USB-ethernet) interface found, is the goggle plugged in?"
    exit 1
fi
echo "Interface: $IF  ->  DHCP"

ip addr flush dev "$IF" 2>/dev/null
ip link set "$IF" up

if command -v dhclient >/dev/null 2>&1; then
    dhclient -1 -v "$IF"
elif command -v udhcpc >/dev/null 2>&1; then
    udhcpc -i "$IF" -n -q
else
    echo "no dhclient or udhcpc on PATH; install one (or use net-up.sh for a static IP)"
    exit 1
fi

ip -o -4 addr show "$IF"
if ping -c1 -W2 "$DEVICE_IP" >/dev/null 2>&1; then
    echo "OK: goggle $DEVICE_IP reachable"
else
    echo "leased, but goggle $DEVICE_IP not answering yet"
fi
