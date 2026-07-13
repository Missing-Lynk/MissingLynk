# Serial / debug access

For day-to-day use you do **not** need any of this: the goggle already runs an SSH server (below). This covers the SSH login and the physical UART console, the guaranteed root access.

> **Scope:** worked out on the **BetaFPV HD systems** (VR04 HD / ArtLynk goggle and the matching air unit). Other Artosyn-based hardware may differ in specifics but most likely exposes the **same access points** (default SSH on the USB gadget, physical UART console), since they share the SoC and firmware lineage. Treat non-BetaFPV units as "probably the same, verify before relying on it."

## TL;DR, the easy way (no case opening)

The goggle runs **dropbear SSH by default** on the USB-ethernet gadget, no serial, trigger, or button combo needed. Connect the goggle's USB-C to your PC (the host gets an `enx*` interface), then:

```sh
sudo ip addr add 192.168.3.222/24 dev <enx>
sudo ip link set <enx> up
ssh -o HostKeyAlgorithms=+ssh-rsa,ssh-dss -o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1 -o Ciphers=+aes128-cbc,3des-cbc root@192.168.3.100
```

The root password is **`artosyn`** (same across GND and SKY units). You land at `uid=0(root)`, a `root@art_sirius` prompt: the same Linux that decodes the video, drives the screen, and records to the SD card (init scripts under `/etc/init.d`, config in `/factory`). For passwordless access, drop your public key into `/root/.ssh/authorized_keys`. This is what the `missinglynk` tooling uses.

## Physical UART debug console

A debug UART is exposed on PCB pads (case must be opened), 8N1. It gives a guaranteed root shell independent of SSH.

Two baud rates across a single boot, this is the main gotcha:

- **BootROM** prints at **115200** for the first ~1 s (banner `V1.4`, a boot menu).
- **After BootROM the U-Boot + Linux console runs at 1152000** (1.152 Mbaud; 1228800 also works). Reading one stage at the other's rate is pure framing-error garbage.

Many cheap USB-serial adapters cannot reach 1152000:

- A dedicated **FT232RL** is the recommended adapter (handles the 1152000 console reliably); CH340 / CH343 / CP2102N (>=1.5 M) also work.
- A **Silicon Labs CP2102 (non-N, `10c4:ea60`) is hard-capped at 1 Mbaud** and cannot read the console.
- Fallback without a dedicated adapter: an **RP2040 (Raspberry Pi Pico)** flashed with `pico-uart-bridge`.
- Custom baud on Linux is set via the `TCSETS2` / `BOTHER` ioctl.

The console has an **askfirst getty**: press **Enter** for a busybox **root shell, no password** (`uid=0`).

## System facts (from the console)

- Kernel **Linux 4.9.38 aarch64**, SoC **`artosyn,proxima-9311`**, hostname `art_sirius`. Firmware **P1 v1.0.44** (built 2026-01-22, git `09de6e7`).
- rootfs = **squashfs on `ubiblock0_0`** (`ubi.mtd=17`, userapp0). `/proc/mtd`: factory=`mtd8`, kernel0=`mtd13`, userapp0=`mtd17` (~45 MB rootfs), usr_data=`mtd19`, usr_log=`mtd20`.
- `/factory/` is writable; boot reads `/factory/start.conf` if present (sets log level + interface name/mac).
