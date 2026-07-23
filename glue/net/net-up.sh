#!/usr/bin/env bash
# Bring up the host side of the USB-ethernet link to the Artosyn units (Linux).
#
# All devices share one L2 segment: every enx* (USB-ethernet gadget) interface is enslaved into
# the br-artosyn bridge, which carries the single host address for the whole device subnet. Each
# open-stack device has a unique fixed MAC pair and a unique IP derived from its device index NN
# (rootfs/devices/<name>/board.conf):
#   host-visible MAC AA:AA:<NN as 4 bytes> -> ifname enxaaaa<nn>, device IP 192.168.3.(100+NN)
#   goggle NN=0 -> 192.168.3.100, air unit NN=1 -> 192.168.3.101
# Devices can be plugged in together or alone; the bridge needs no per-device knowledge. A stock
# (vendor slot-A) unit randomizes its MAC each boot and is always 192.168.3.100, so plug in at
# most one stock unit at a time (it collides with the goggle's address).
#
# Run whenever a unit is plugged in or rebooted (idempotent). Install 99-artosyn-unmanaged.conf
# (same dir) FIRST, or NetworkManager will keep flushing the bridge. See
# glue/docs/host-network-setup.md.
#
# It calls sudo for the `ip` commands. Env overrides:
#   BRIDGE=br-artosyn HOST_IP=192.168.3.222 ./glue/net/net-up.sh
set -euo pipefail

_NET_UP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ML_REPO="${ML_REPO:-$(cd "$_NET_UP_DIR/../.." && pwd)}"

BRIDGE="${BRIDGE:-br-artosyn}"
HOST_IP="${HOST_IP:-192.168.3.222}"

# Known devices for the reachability report, sourced from the device profiles (the single source
# of truth): each rootfs/devices/<name>/board.conf carries the device's GADGET_IP. Sorted by
# directory name so goggle (NN=0) reports before the air unit (NN=1).
UNITS=()
for conf in "$ML_REPO"/rootfs/devices/*/board.conf; do
    [ -f "$conf" ] || continue
    name="$(basename "$(dirname "$conf")")"
    ip="$(sed -n 's/^GADGET_IP=["'\'']*\([0-9.]*\).*/\1/p' "$conf" | head -1)"
    [ -n "$ip" ] || continue
    UNITS+=("$ip $name")
done
IFS=$'\n' UNITS=($(sort <<<"${UNITS[*]}")); unset IFS

# Bridge: create once, address once, up.
if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
    echo "Creating bridge $BRIDGE ($HOST_IP/24)"
    sudo ip link add "$BRIDGE" type bridge
fi
if ! sudo ip addr add "$HOST_IP/24" dev "$BRIDGE" 2>/dev/null; then
    :
fi
sudo ip link set "$BRIDGE" up

# Enslave every gadget interface not already in the bridge.
FOUND=0
for IF in $(ip -br link | awk '/enx/{print $1}'); do
    FOUND=1
    if [ -e "/sys/class/net/$IF/master" ]; then
        echo "Interface: $IF (already in $BRIDGE)"
    else
        echo "Interface: $IF -> $BRIDGE"
        sudo ip addr flush dev "$IF"
        sudo ip link set "$IF" master "$BRIDGE"
    fi
    sudo ip link set "$IF" up
done

if [ "$FOUND" = 0 ]; then
    echo "No enx* (USB-ethernet) interface - is a unit plugged in & powered?" >&2
    exit 1
fi

# Report only the units that answer (usually just the one plugged in). When the CLI is on PATH,
# name the unit that answered.
sleep 2
REACHED=0
for entry in "${UNITS[@]}"; do
    UNIT_IP="${entry%% *}"
    LABEL="${entry#* }"
    ping -c1 -W2 "$UNIT_IP" >/dev/null 2>&1 || continue
    REACHED=1
    dev=""
    if command -v missinglynk >/dev/null 2>&1; then
        dev="$(missinglynk --ip "$UNIT_IP" identify 2>/dev/null)"
    fi
    echo "OK: ${dev:-$LABEL} reachable at $UNIT_IP"
done

if [ "$REACHED" = 0 ]; then
    echo "No known unit answered (bridge is up; is one plugged in & booted?)" >&2
fi
