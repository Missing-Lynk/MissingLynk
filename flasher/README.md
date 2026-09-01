# ml-flasher - host-side open-firmware flasher

A native-window GUI (Go + Fyne) that flashes a validated MissingLynk release image onto a supported Artosyn device over its USB gadget network and SSH. It drives the on-device `mlflash` binary (`native/mlflash/`), which owns every byte-level decision; this tool orchestrates and never touches partitions, GPT, or UBI directly. Everything about reaching that binary - where it is uploaded to, its flag grammar, its shell quoting, and the contract where its read-only modes print JSON and still exit non-zero - lives in `internal/mlflash`. It writes only the inactive slot, so the firmware in the running slot stays intact. Runs on Linux and Windows; ships as one self-contained binary (links only the ubiquitous `libGL`/`libX11` at runtime).

## How it works

1. Detects the connected device over the USB-ethernet gadget (device at `192.168.3.100`; host takes `192.168.3.222/24`, assigned by the tool since stock firmware serves no DHCP).
2. Reads `sdk_version.json` and gates on the firmware whitelist (see Supported devices).
3. Streams the embedded `mlflash` to `/tmp` and runs `mlflash --preflight` (read-only), gating on the device's state: see Flash gating below. Choosing an image is disabled until it passes. The binary goes up once per connection and every later call reuses it.
4. Streams the chosen `.mlimg` to the device over the SSH channel. A mounted SD card is preferred, because it keeps a large bundle out of RAM on the goggle; devices without an SD card path fall back to `/tmp` only when enough free tmpfs space is available.
5. Runs `mlflash`: `--dry-run` (verify every component hash and resolve each to the partition it would be written to) -> `--flash` (write the inactive slot, readback-verified) -> `--flip` (set it active) -> watchdog reboot, then waits for the device to return on the open firmware.

The GUI is the end-user path: it is intended for release `.mlimg` bundles that were already proven on matching hardware, so "Flash and switch" activates the newly written slot after readback verification. Users do not need a serial adapter or RAM-boot setup. "Flash only" stops after `--flash`: the inactive slot is written but not activated, and the device stays on its current slot. Use it for development images, lab verification, or any bundle whose bootability has not already been signed off; activate it later with the Switch slot button or the manual flash ladder.

## Flash gating

A flash may run only from **slot A**, with slot A also the GPT-active slot, and with every slot-B partition resolving to its own usable MTD device. The tool assumes slot A holds the recommended version of the vendor firmware, so that there is a safe slot to fall back to if a flashed slot B does not boot; it does not verify this, and never probes slot A's partitions. On that assumption the rule is positional: `mlflash` writes the slot that is *not* running, so a flash from slot B would target slot A. The tool refuses that rather than relying on `mlflash`'s own slot-A guard, which only fires after the whole bundle has been uploaded.

The gate splits in two, because the checks that need the image cannot decide whether the user may pick one:

- **`mlflash --preflight`** (read-only, no image) runs on every scan and again immediately before the upload, since a device can be switched between the scan and the click. It reports the running slot, the GPT-active slot, whether they agree, the slot a flash would write, and the guard verdict for every partition that slot owns. The host classifies that into a single blocker; `mlflash` reports facts and applies no policy.
- **`mlflash --dry-run <image>`** runs after the upload and before any write. It verifies every component hash, matches the manifest's `target_device` against the board, resolves each component to its target partition, and re-checks the slot state with the bundle's own sizes in hand. It supersedes the older `--inspect` step.

While the gate is shut, both **Choose image** and **Flash** are disabled: offering a file picker to a device that cannot be flashed only invites the refusal later. **Switch slot** stays enabled, because on a device booted from slot B it is the step that opens the gate. The device card states what is wrong and the one action that fixes it:

| Device state | What the card says to do |
|---|---|
| Running slot B, stock firmware intact on A | Switch to slot A, then flash |
| Running slot B, nothing complete on A | The device needs recovery; the switch is not offered either |
| Running slot differs from the active slot (flash-boot) | Power-cycle so it boots its active slot, then re-scan |
| Running slot or GPT active bit unreadable | Power-cycle and re-scan |
| A slot-B partition missing, aliased to its slot-A sibling, or resolving to mtd0 | The device needs recovery |

A consequence worth knowing: a device already running the MissingLynk firmware (slot B) cannot be flashed in one step. Switch it to slot A first, then flash. That was already the behaviour; the gate now says so instead of stopping silently.

The second row is the state a vendor updater leaves behind if it writes and activates slot B while slot A is stale, and this tool has nothing to offer it: restoring slot A is `glue/docs/clone-a-slot.md` by hand, whose rootfs step has no tooling yet.

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
