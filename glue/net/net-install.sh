#!/bin/sh
# net-install.sh - install the host-side auto-networking for Artosyn units (Linux/systemd).
#
# After this, a device plug-in / reboot / ramboot brings the host side up automatically, with
# no manual net-up.sh:
#   - 99-artosyn-bridge.rules   -> /etc/udev/rules.d/            (udev auto-enslave rule)
#   - artosyn-bridge-attach.sh  -> /usr/local/lib/              (the enslave script it runs)
#   - 99-artosyn-unmanaged.conf -> /etc/NetworkManager/conf.d/  (keep NM off enx*/br-artosyn)
#
# Also removes the superseded non-bridge autonet (the 90-artosyn-libre udev rule + its systemd
# oneshot), which assigned an IP straight to the interface and races the bridge model.
#
# Re-run any time; idempotent. Needs sudo.
set -e
here="$(cd "$(dirname "$0")" && pwd)"

sudo install -m755 "$here/artosyn-bridge-attach.sh"  /usr/local/lib/artosyn-bridge-attach.sh
sudo install -m644 "$here/99-artosyn-bridge.rules"   /etc/udev/rules.d/99-artosyn-bridge.rules
sudo install -m644 "$here/99-artosyn-unmanaged.conf" /etc/NetworkManager/conf.d/99-artosyn-unmanaged.conf

# Remove the superseded non-bridge autonet, if a previous setup left it behind.
if [ -e /etc/systemd/system/artosyn-libre-autonet.service ]; then
    sudo systemctl disable --now artosyn-libre-autonet.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/artosyn-libre-autonet.service
    sudo systemctl daemon-reload
fi

sudo rm -f /etc/udev/rules.d/90-artosyn-libre-autonet.rules
sudo rm -f /usr/local/sbin/artosyn-libre-autonet.sh

sudo udevadm control --reload
sudo systemctl reload NetworkManager 2>/dev/null || true

echo "net-install: done. Plug in or reboot a unit and it auto-attaches to br-artosyn."
