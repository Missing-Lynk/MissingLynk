#!/bin/sh
# artosyn-bridge-attach.sh - enslave the Artosyn USB-ethernet gadget interface(s) into the
# br-artosyn bridge, creating the bridge (with the host address) on first use.
#
# Invoked by udev on a gadget net "add" event (99-artosyn-bridge.rules, same dir), so a device
# plug-in, reboot, or ramboot needs no manual net-up run. Idempotent; safe to run by hand.
#
# The gadget interface is renamed (usb0 -> enx<mac>) inside the same udev add event, so this
# does NOT trust the event's kernel name: it locates every Artosyn gadget interface by USB
# IDENTITY and enslaves any not already in a bridge.
#   open  gadget: 1d6b:0104 manufacturer "missinglynk"
#   stock gadget: 1d6b:0101 manufacturer "Artosyn"
BRIDGE="br-artosyn"
HOST_IP="192.168.3.222"

# Create the bridge with the host address on first use.
ensure_bridge() {
    if ! ip link show "$BRIDGE" >/dev/null 2>&1; then
        ip link add "$BRIDGE" type bridge
    fi
    ip addr add "$HOST_IP/24" dev "$BRIDGE" 2>/dev/null || true
    ip link set "$BRIDGE" up
}

# True when the interface's parent USB device is an Artosyn gadget (open or stock). The net
# device's own attributes are unreliable mid-rename, so match the parent USB device.
is_artosyn_gadget() {
    usbdev="$(readlink -f "/sys/class/net/$1/device/.." 2>/dev/null)" || return 1
    [ "$(cat "$usbdev/idVendor" 2>/dev/null)" = "1d6b" ] || return 1
    product="$(cat "$usbdev/idProduct" 2>/dev/null)"
    manufacturer="$(cat "$usbdev/manufacturer" 2>/dev/null)"
    if [ "$product" = "0104" ] && [ "$manufacturer" = "missinglynk" ]; then
        return 0
    fi
    if [ "$product" = "0101" ] && [ "$manufacturer" = "Artosyn" ]; then
        return 0
    fi
    return 1
}

# Enslave one interface into the bridge unless it is already mastered.
enslave() {
    interface="$1"
    [ -e "/sys/class/net/$interface/master" ] && return 0
    ip addr flush dev "$interface" 2>/dev/null || true
    ip link set "$interface" master "$BRIDGE"
    ip link set "$interface" up
}

ensure_bridge

# Sweep every gadget interface. A just-added interface may still be settling (mid-rename) when
# udev fires this, so retry briefly until at least one gadget interface is present.
found=0
attempt=0
while [ "$attempt" -lt 6 ]; do
    for netdev in /sys/class/net/*; do
        interface="$(basename "$netdev")"
        is_artosyn_gadget "$interface" || continue
        enslave "$interface"
        found=1
    done
    [ "$found" -eq 1 ] && break
    attempt=$((attempt + 1))
    sleep 0.3
done
