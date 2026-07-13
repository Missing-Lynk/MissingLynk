#!/usr/bin/env bash
# Bring up the host side of the USB-ethernet link to the OPEN "artosyn-libre" system
# (our custom open kernel + Alpine rootfs). This is a SEPARATE script from net-up.sh
# on purpose: it does NOT touch the stock-goggle infrastructure.
#
# The interface is located by the gadget's USB IDENTITY (idVendor 1d6b / idProduct 0104 /
# manufacturer "missinglynk", set in rootfs/skeleton/etc/init.d/usb-gadget), so it is found
# regardless of the ECM
# host_addr (no dependency on a particular MAC / enx* name). It still relies on the existing
# 99-artosyn-unmanaged.conf (that marks all enx* unmanaged, so this interface is covered
# too) - no new NetworkManager file needed.
#
# Optional internet sharing so `apk` works on the goggle: pass NAT=1 to enable
# IPv4 forwarding + masquerade out the host's default-route interface.
#   NAT=1 ./glue/net/net-up-libre.sh
#
# Override defaults via env (DEVICE_IP, HOST_IP, IF, ROOT_PASS). Calls sudo for ip/iptables.
set -euo pipefail

DEVICE_IP="${DEVICE_IP:-192.168.3.100}"
HOST_IP="${HOST_IP:-192.168.3.222}"
ROOT_PASS="${ROOT_PASS:-libre}"
IF="${IF:-}"

# Locate the open gadget by its USB identity (idVendor 1d6b / idProduct 0104 / manufacturer
# "missinglynk"); fall back to the first enx* if the walk turns up nothing.
if [ -z "$IF" ] || ! ip link show "$IF" >/dev/null 2>&1; then
    for d in /sys/class/net/*; do
        usbdev="$(readlink -f "$d/device/.." 2>/dev/null)" || continue
        [ "$(cat "$usbdev/idVendor" 2>/dev/null)" = "1d6b" ] || continue
        [ "$(cat "$usbdev/idProduct" 2>/dev/null)" = "0104" ] || continue
        [ "$(cat "$usbdev/manufacturer" 2>/dev/null)" = "missinglynk" ] || continue
        IF="$(basename "$d")"
        break
    done
fi

if [ -z "${IF:-}" ] || ! ip link show "$IF" >/dev/null 2>&1; then
    IF="$(ip -br link | awk '/enx/{print $1; exit}')"
fi

if [ -z "${IF:-}" ] || ! ip link show "$IF" >/dev/null 2>&1; then
    echo "No open-gadget USB-ethernet interface found - is the open goggle plugged in & booted?" >&2
    exit 1
fi

echo "Interface: $IF  ->  $HOST_IP/24"
if ! sudo ip addr add "$HOST_IP/24" dev "$IF" 2>/dev/null; then
    echo "  (address already present)"
fi

sudo ip link set "$IF" up
sleep 2

if [ "${NAT:-0}" = "1" ]; then
    WAN="$(ip route show default | awk '/default/{print $5; exit}')"
    if [ -n "$WAN" ] && [ "$WAN" != "$IF" ]; then
        echo "NAT: sharing internet $IF -> $WAN (for apk)"
        sudo sysctl -q net.ipv4.ip_forward=1
        sudo iptables -t nat -C POSTROUTING -o "$WAN" -j MASQUERADE 2>/dev/null \
            || sudo iptables -t nat -A POSTROUTING -o "$WAN" -j MASQUERADE
        sudo iptables -C FORWARD -i "$IF" -o "$WAN" -j ACCEPT 2>/dev/null \
            || sudo iptables -A FORWARD -i "$IF" -o "$WAN" -j ACCEPT
        sudo iptables -C FORWARD -i "$WAN" -o "$IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
            || sudo iptables -A FORWARD -i "$WAN" -o "$IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
    else
        echo "NAT: no separate WAN interface found, skipping"
    fi
fi

if ! ping -c1 -W2 "$DEVICE_IP" >/dev/null 2>&1; then
    echo "Not reachable yet - the open system may still be booting"
    exit 0
fi

# Confirm it is the open system (hostname artosyn-libre). Modern Alpine dropbear,
# so no legacy crypto needed (unlike the stock goggle).
if command -v sshpass >/dev/null 2>&1; then
    . "$(dirname "$0")/../lib/ssh-opts.sh"
    info="$(SSHPASS="$ROOT_PASS" sshpass -e ssh \
        -o ConnectTimeout=6 "${SSH_OPTS_LIBRE[@]}" root@"$DEVICE_IP" 'uname -sr; hostname' 2>/dev/null)" || true
    if [ -n "$info" ]; then
        echo "OK: open system reachable at $DEVICE_IP"
        echo "$info" | sed 's/^/  /'
    else
        echo "OK: reachable at $DEVICE_IP (SSH not up yet, give it a moment)"
    fi
else
    echo "OK: reachable at $DEVICE_IP (install sshpass to auto-identify; password: $ROOT_PASS)"
fi
