# Host network setup (the connection gotchas)

A stable link to the goggle needs two host-side fixes; a third behaviour is device-side, not a host problem.

## The link is a USB-ethernet gadget

Plugging the goggle into the PC's USB creates a USB-ethernet interface `enx<mac>`. The goggle is **`192.168.3.100`**; the host uses **`192.168.3.222/24`**. The stock goggle runs **no DHCP server**, so the host IP must be set statically (`glue/net/net-up.sh`). Once the `dhcp` component (minidhcpd) is enabled the goggle can lease the host an address instead (`glue/net/net-dhcp.sh`).

## Gotcha 1, NetworkManager flushes the static IP (the big one)

Symptom: the connection "randomly dies" every ~30 s; re-adding the IP fixes it briefly. Root cause is **NetworkManager**, not the goggle:

- NM manages the `enx*` device but has **no connection profile** for it, so it keeps it in state `disconnected` (its only auto-attempt, DHCP, fails, no server).
- When you `ip addr add` manually, NM sees a "foreign" address on a device it thinks should be down, and on its next reconcile (a carrier blip, periodic check, etc.) **flushes the address**.
- Proof: `nmcli device status` shows the iface `disconnected` while `/sys/class/net/enx*/carrier` reads **1** (link physically up). So the goggle's link is fine, NM is tearing down our config.

**Fix (one-time):** mark the gadget unmanaged.
```sh
sudo install -m644 glue/net/99-artosyn-unmanaged.conf /etc/NetworkManager/conf.d/
sudo systemctl reload NetworkManager
nmcli device status | grep enx     # should now read: unmanaged
```
The keyfile is just:
```ini
[keyfile]
unmanaged-devices=interface-name:enx*
```
Only matches `enx*` (USB-ethernet); your normal NIC (`enp*`/`wlp*`) is untouched. After this, a manually-added IP **sticks**. Revert by deleting the file + reload.

## Gotcha 2, the gadget renames every boot

The gadget **re-randomizes its MAC on each goggle boot**, so the interface name (`enx<mac>`) changes and the IP is gone after every reboot/replug. Re-apply per boot:
```sh
IF=$(ip -br link | awk '/enx/{print $1; exit}')
sudo ip addr add 192.168.3.222/24 dev "$IF"; sudo ip link set "$IF" up
```
`glue/net/net-up.sh` does exactly this (auto-detecting the name). For a fully hands-off setup, a udev rule keyed on `SUBSYSTEM==net, NAME=="enx*"` could assign the IP on appearance (not implemented here).

## Device behaviour, RF link resets (not a host issue)

The **air/Tx side resets the RF link** intermittently (`Tx maybe reboot`, `reset pipeline` in `/tmp/usrlog/Video*.log`). That causes feed dropouts (and the DVR/venc to restart), independent of the host network. When the feed is solid, the video and RTSP are stable.

## SSH

Dropbear, **root / `artosyn`**, legacy crypto only. `missinglynk/connection.py` handles this (paramiko with the legacy algorithms re-enabled). For a manual ssh client, re-enable the same algorithms:
```
-o HostKeyAlgorithms=+ssh-rsa,ssh-dss
-o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1
-o Ciphers=+aes128-cbc,3des-cbc
-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
```
