# What gets changed on the goggle, and how to revert

**Bottom line:** the read-only rootfs (`/usr`, `/etc`, the stock binaries and `run.sh`) is **never modified**. Everything is either (a) files under the writable `/usrdata` partition (all namespaced in `/usrdata/missinglynk/`, plus a couple of boot-hook files), or (b) runtime-only state that disappears on power-cycle. Revert is one command: `missinglynk uninstall`.

## What `missinglynk install` writes

All persistent files live in the writable `/usrdata` partition. Our own files are namespaced under `/usrdata/missinglynk/`; the boot hook and its guard sit at the `/usrdata` top level (that is where `run.sh` looks for them).

| path | what |
|------|------|
| `/usrdata/missinglynk/bin/ar_lowdelay.patched` | the `rtsp` component binary (patched `ar_lowdelay`) |
| `/usrdata/missinglynk/bin/fbtext`              | the `indicator` component binary (native OSD renderer) |
| `/usrdata/missinglynk/bin/minidhcpd`           | the `dhcp` component binary (DHCP server on usb0, launched after the boot body) |
| `/usrdata/missinglynk/start.sh`                | the generated boot logic (sources config, applies enabled components, then runs the stock boot body copied verbatim from `run.sh`) |
| `/usrdata/missinglynk/config`                  | shell-sourceable config (`rtsp=on/off`, `indicator=on/off`, `dhcp=on/off`); edited by `enable`/`disable` |
| `/usrdata/run_dbg.sh`                           | the boot hook; a copy of `start.sh` that **stays in place** (`run.sh` runs it every boot) |
| `/usrdata/buildtime`                            | copy of `/usr/usrdata/buildtime`, so `run.sh` runs our hook instead of wiping `/usrdata` |

`install` deploys all of the above and arms the hook, but **enables nothing beyond the defaults** (`indicator` on, `rtsp` off). `enable`/`disable` only rewrite the `config` file; they never touch the binaries or the hook.

These files are inert on their own: the goggle only applies a component if `run_dbg.sh` exists at boot **and** that component is `on` in `config`.

## Runtime-only state (gone on any power-cycle)

| path | what |
|------|------|
| `/tmp/missinglynk.applied` | boot snapshot of what `start.sh` actually applied this boot; `status` diffs the live `config` against it to flag pending (needs-reboot) changes. In `/tmp`, so cleared on reboot. |

Plus the live runtime effects of whatever was applied:
- if `rtsp` was on: the bind-mount of `/usrdata/missinglynk/bin/ar_lowdelay.patched` over `/usr/bin/ar_lowdelay`, and the running patched `ar_lowdelay` process.
- if `indicator` was on: the running `fbtext` process drawing the HUD.

None of this survives a power-cycle; the bind-mount and the processes are gone, and the next boot re-applies from `config`.

## What is NOT changed

- The read-only squashfs rootfs, `/usr/bin/ar_lowdelay`, `/usr/usrdata/run.sh`, `/etc`, all stock. When `rtsp` is on the patched binary is **bind-mounted over** `/usr/bin/ar_lowdelay` at runtime; the underlying file is untouched.
- `cfg_rx_sys.json`, the binary patch doesn't need it, so install leaves the config alone.

## How to revert

**Run `missinglynk uninstall`, then power-cycle.** It removes the `/usrdata/missinglynk/` directory and the boot-hook files (`run_dbg.sh`, `buildtime`); the power-cycle drops any bind-mount and stops our processes, so the goggle boots bone-stock.

The boot mechanism is **persistent**: the hook (`run_dbg.sh`) stays in place and `run.sh` runs it every boot, so a power-cycle alone does **not** revert. Run `uninstall` first, then power-cycle.

### Temporary stock boot (escape hatch)

**Hold the BACK button while powering on.** The hook reads the adc-keys voltage ladder directly at the very top (ADC channel 0, `/sys/bus/iio/devices/adc/in_voltage0_input`); BACK pulls it to ~400 mV, and a 300-500 mV window means "BACK held" (idle is ~0 mV). If held it skips all components for that one boot (no bind-mount, no HUD), giving a stock boot so you can finish your session. The config is untouched, so the next normal power-on applies everything again. This needs nothing over SSH and adds no boot delay (a one-shot ADC read), handy if a component misbehaves mid-session.

### Recovery if a component breaks

The hook runs the **stock boot body copied verbatim from `run.sh`**, so the USB gadget (`usb0` = `192.168.3.100`) comes up as stock and dropbear/SSH is started independently by `/etc/init.d/start_ssh.sh`: SSH always comes up even if a component is broken (a bad `rtsp` patch only affects the FPV app, never your SSH access). `install` also `sh -n`-checks the generated hook before arming it. To recover, SSH in and run `missinglynk uninstall`. The ultimate fallback is the physical UART console (see [docs/guides/serial-and-debug-access.md](serial-and-debug-access.md)).

### Host side (your PC)

The only persistent host change is the NetworkManager keyfile:

```sh
sudo rm /etc/NetworkManager/conf.d/99-artosyn-unmanaged.conf
sudo systemctl reload NetworkManager
```

Keep it if you'll keep working with the goggle; it is harmless and only affects `enx*` USB-ethernet interfaces.

## Re-install / re-enable later

`missinglynk install`, then `missinglynk enable rtsp` (the `indicator` is on by default), then power-cycle.
