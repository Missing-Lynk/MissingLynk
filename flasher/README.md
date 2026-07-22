# ml-flasher - host-side open-firmware flasher

A native-window GUI (Go + Fyne) that flashes the MissingLynk open firmware onto a supported Artosyn device over its USB gadget network and SSH. It drives the on-device `mlflash` binary (`native/mlflash/`), which owns every byte-level decision; this tool orchestrates and never touches partitions, GPT, or UBI directly. It writes only the inactive slot, so the stock firmware in the other slot stays intact. Runs on Linux and Windows; ships as one self-contained binary (links only the ubiquitous `libGL`/`libX11` at runtime).

## How it works

1. Detects the connected device over the USB-ethernet gadget (device at `192.168.3.100`; host takes `192.168.3.222/24`, assigned by the tool since stock firmware serves no DHCP).
2. Reads `sdk_version.json` and gates on the firmware whitelist (see Supported devices).
3. Streams the embedded `mlflash` and the chosen `.mlimg` to `/tmp` over the SSH channel (the device has no scp/sftp).
4. Runs `mlflash`: `--inspect` (verify hashes) -> `--flash` (write the inactive slot, readback-verified) -> `--flip` (set it active) -> watchdog reboot, then waits for the device to return on the open firmware.

The Flash button offers two modes. "Flash and switch" runs the full sequence above. "Flash only" stops after `--flash`: the inactive slot is written but not activated, and the device stays on its current slot. Use it to write a slot without committing to it (for example to prove the new slot by RAM-boot first); activate it later with the Switch slot button.

## Switching slots without reflashing

Detection also probes the inactive slot (`mlflash --slots`, read-only): the dtb model string identifies the installed image, and the kernel and rootfs magics confirm it is complete. When the other slot holds a complete recognized image, the "Switch slot" button activates it without writing any image data (only the GPT active bit changes) and reboots into it. This covers both directions: a device switched back to stock returns to the MissingLynk firmware without a reflash, and a device on the MissingLynk firmware returns to stock the same way. The switch requires confirming a dialog; switching to the MissingLynk slot warns that the slot is activated without re-verification, so a slot that no longer boots leaves the device unbootable until recovered.

## Build

Built reproducibly in a container; the host needs only Docker. The Fyne cgo toolchain (OpenGL, X11 and Wayland headers) lives inside the image, so nothing beyond Docker is installed on the host.

```
make native      # produces native/build/mlflash (once), which the flasher embeds
make flasher     # builds in golang:1.26-bookworm, extracts flasher/build/ml-flasher
```

## Running

```
./flasher/build/ml-flasher
```

The window scans on open and shows the detected device. Choose an `.mlimg`, then Flash. Run it as your normal user: configuring the host IP on a fresh gadget interface needs privileges, which the tool requests via a graphical prompt (`pkexec`) only when needed - against an already-reachable interface no prompt appears.

## Supported devices

The whitelist lives in `internal/whitelist` (edit `Devices` there to add one); a device on a version not listed is reported and left untouched.

| Device | product_version | hardware | firmware |
|--------|-----------------|----------|----------|
| BetaFPV VR04 HD goggle | `P1_GND_VR04` | `v2.0` | `1.0.44.rel` |
