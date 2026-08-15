# ml-flasher - host-side open-firmware flasher

A native-window GUI (Go + Fyne) that flashes a validated MissingLynk release image onto a supported Artosyn device over its USB gadget network and SSH. It drives the on-device `mlflash` binary (`native/mlflash/`), which owns every byte-level decision; this tool orchestrates and never touches partitions, GPT, or UBI directly. It writes only the inactive slot, so the firmware in the running slot stays intact. Runs on Linux and Windows; ships as one self-contained binary (links only the ubiquitous `libGL`/`libX11` at runtime).

## How it works

1. Detects the connected device over the USB-ethernet gadget (device at `192.168.3.100`; host takes `192.168.3.222/24`, assigned by the tool since stock firmware serves no DHCP).
2. Reads `sdk_version.json` and gates on the firmware whitelist (see Supported devices).
3. Streams the embedded `mlflash` to `/tmp` and the chosen `.mlimg` to the device over the SSH channel. A mounted SD card is preferred for the image, because it keeps a large bundle out of RAM on the goggle; devices without an SD card path fall back to `/tmp` only when enough free tmpfs space is available.
4. Runs `mlflash`: `--inspect` (verify hashes) -> `--flash` (write the inactive slot, readback-verified) -> `--flip` (set it active) -> watchdog reboot, then waits for the device to return on the open firmware.

The GUI is the end-user path: it is intended for release `.mlimg` bundles that were already proven on matching hardware, so "Flash and switch" activates the newly written slot after readback verification. Users do not need a serial adapter or RAM-boot setup. "Flash only" stops after `--flash`: the inactive slot is written but not activated, and the device stays on its current slot. Use it for development images, lab verification, or any bundle whose bootability has not already been signed off; activate it later with the Switch slot button or the manual flash ladder.

## Switching slots without reflashing

Detection also probes the slot state (`mlflash --slots`, read-only): the dtb model string identifies the installed image, and the kernel and rootfs magics confirm it is complete. When the slot that is not active holds a complete recognized image, the switch button activates it without writing any image data (only the GPT active bit changes) and reboots into it. This covers both directions: a device switched back to stock returns to the MissingLynk firmware without a reflash, and a device on the MissingLynk firmware returns to stock the same way. The switch requires confirming a dialog; switching to the MissingLynk slot warns that the slot is activated without re-verification, so a slot that no longer boots leaves the device unbootable until recovered.

The direction comes from the device's real active slot (the GPT active bit), never from the firmware that happens to be running, and the button names it: "Switch to slot B" when A is active, "Switch to slot A" when B is. Those differ during a flash-boot, where the flashed slot runs from a host-loaded kernel while the other slot is still the active one - the tool then offers to activate the slot whose firmware is running, which is the flip step of the flash -> flashboot -> flip workflow. The device card names that state so the offered direction is never a surprise.

## Build

Built reproducibly in a container; the host needs only Docker. The Fyne cgo toolchain (OpenGL, X11 and Wayland headers) lives inside the image, so nothing beyond Docker is installed on the host.

```
make native      # produces native/build/mlflash (once), which the flasher embeds
make flasher     # builds in golang:1.26-bookworm, extracts flasher/build/ml-flasher
```

## CI builds and releases

`.github/workflows/flasher-linux.yml` and `.github/workflows/flasher-windows.yml` build one binary each through the same make targets as above and keep it as a workflow artifact. Neither runs automatically: dispatch one from the Actions tab, picking the branch to build, or pass a `ref` (`refs/pull/<n>/head`) to build a PR that lives in a fork. The binary is named after the tag it was built from, or after the short commit hash when it was not built from a tag (`ml-flasher-341bc86-linux-amd64`). The artifact round-trip does not preserve the executable bit, so a downloaded Linux build needs a `chmod +x`.

Pushing a `v*` tag runs `.github/workflows/release.yml`, which calls both build workflows at the tagged commit and publishes a GitHub release with `ml-flasher-<tag>-linux-amd64`, `ml-flasher-<tag>-windows-amd64.exe` and a `SHA256SUMS` attached. A tag carrying a suffix (`v1.2.0-rc1`) is published as a prerelease.

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
| BetaFPV VR04 HD air unit | `P1_SKY` | `v1.0` | `1.0.44.rel` |
