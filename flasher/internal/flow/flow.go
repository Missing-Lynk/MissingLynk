// Package flow is the headless engine behind the GUI: detect the connected
// device, then (on demand) flash an image onto it. It splits into two phases so
// the GUI can show the device first and flash only when the user chooses an image
// and clicks Flash. It emits typed progress events; the GUI renders them. No flash
// logic lives here - every byte-level decision is mlflash's on the device.
package flow

import (
	"context"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/device"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/netcfg"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/payload"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/whitelist"
)

// Defaults for the fixed gadget link.
const (
	DefaultDeviceIP = device.DefaultIP
	DefaultHostCIDR = "192.168.3.222/24"
	remoteDir       = "/tmp"
	remoteMlflash   = "/tmp/mlflash"
)

// Level classifies an event for rendering.
type Level int

const (
	LevelStep Level = iota // a major step starting
	LevelInfo              // detail / relayed device output
	LevelWarn
	LevelError
	LevelDone
)

// Event is one progress update.
type Event struct {
	Level Level  `json:"level"`
	Msg   string `json:"msg"`
}

// Emit receives events as a phase runs.
type Emit func(Event)

// Options configure the connection and gating. The GUI fills only ImagePath (via
// the file picker); the rest keep their defaults.
type Options struct {
	ImagePath string // .mlimg bundle to flash (required by Flash)
	DeviceIP  string // default DefaultDeviceIP
	HostCIDR  string // default DefaultHostCIDR

	// AllowUnknownVersion bypasses the firmware whitelist (developer use).
	AllowUnknownVersion bool
}

// DeviceInfo is what Detect learns about the connected unit, for display and to
// decide whether flashing is allowed.
type DeviceInfo struct {
	Unit        string `json:"unit"`     // "P1_GND" (goggle), "P1_SKY" (air), "unknown"
	Product     string `json:"product"`  // product_version
	Firmware    string `json:"firmware"` // software_version
	Hardware    string `json:"hardware"` // hardware_version
	Name        string `json:"name"`     // human device name (device-tree model) for an already-open unit
	Flashable   bool   `json:"flashable"`
	AlreadyOpen bool   `json:"alreadyOpen"` // already running our open firmware
	Note        string `json:"note"`        // why not flashable / status detail
}

func (o *Options) applyDefaults() {
	if o.DeviceIP == "" {
		o.DeviceIP = DefaultDeviceIP
	}

	if o.HostCIDR == "" {
		o.HostCIDR = DefaultHostCIDR
	}
}

// Detect brings the link up, connects, and reports what is attached. It never
// writes anything. A nil error with info.Flashable == false means a device was
// found but cannot/should not be flashed (with the reason in info.Note).
func Detect(ctx context.Context, opt Options, emit Emit) (*DeviceInfo, error) {
	opt.applyDefaults()

	emit(Event{Level: LevelStep, Msg: "Looking for a connected device"})
	if err := ensureLink(ctx, opt, emit); err != nil {
		return nil, err
	}

	emit(Event{Level: LevelStep, Msg: "Reading the device"})
	client, alreadyOpen, err := connect(opt.DeviceIP)
	if err != nil {
		return nil, fail(emit, fmt.Errorf("SSH connect to %s failed: %w", opt.DeviceIP, err))
	}

	defer client.Close()
	if alreadyOpen {
		info := &DeviceInfo{
			AlreadyOpen: true, Flashable: false,
			Name: deviceName(client),
			Note: "This device is already running the MissingLynk firmware.",
		}

		emit(Event{Level: LevelDone, Msg: info.Note})
		return info, nil
	}

	sdk, err := client.ReadSDKVersion()
	if err != nil {
		return nil, fail(emit, fmt.Errorf("reading device firmware version: %w", err))
	}

	info := &DeviceInfo{
		Unit:     string(sdk.Identify()),
		Product:  sdk.ProductVersion,
		Firmware: sdk.SoftwareVersion,
		Hardware: sdk.HardwareVersion,
	}

	switch {
	case sdk.Identify() != device.UnitGoggle:
		info.Note = fmt.Sprintf("The connected unit (%s) is not compatible with this image.", sdk.Identify())

	case !whitelist.Allowed(sdk.HardwareVersion, sdk.SoftwareVersion, sdk.ProductVersion) && !opt.AllowUnknownVersion:
		info.Note = fmt.Sprintf("Firmware %s (hardware %s) is not on the validated list; refusing for safety.",
			sdk.SoftwareVersion, sdk.HardwareVersion)

	default:
		info.Flashable = true
		info.Note = "Ready to flash."
	}

	// Close out the scan log with the outcome, so it does not just stop.
	if info.Flashable {
		emit(Event{Level: LevelDone, Msg: info.Note})
	} else {
		emit(Event{Level: LevelWarn, Msg: info.Note})
	}

	return info, nil
}

// Flash performs the real slot-B write and the active-slot flip for opt.ImagePath.
// mlflash writes only the inactive slot and never slot A, so a failed slot B still
// reverts to intact stock firmware.
func Flash(ctx context.Context, opt Options, emit Emit) error {
	opt.applyDefaults()
	if opt.ImagePath == "" {
		return fail(emit, fmt.Errorf("no image selected"))
	}

	if _, err := os.Stat(opt.ImagePath); err != nil {
		return fail(emit, fmt.Errorf("image %s: %w", opt.ImagePath, err))
	}

	emit(Event{Level: LevelStep, Msg: "Preparing"})
	if err := ensureLink(ctx, opt, emit); err != nil {
		return err
	}

	client, alreadyOpen, err := connect(opt.DeviceIP)
	if err != nil {
		return fail(emit, fmt.Errorf("SSH connect to %s failed: %w", opt.DeviceIP, err))
	}

	defer client.Close()
	if alreadyOpen {
		emit(Event{Level: LevelDone, Msg: "This device is already running the open firmware - nothing to do."})
		return nil
	}

	// Re-verify identity + version gate right before writing (defence in depth).
	sdk, err := client.ReadSDKVersion()
	if err != nil {
		return fail(emit, fmt.Errorf("reading device firmware version: %w", err))
	}

	if sdk.Identify() != device.UnitGoggle {
		return fail(emit, fmt.Errorf("connected unit %q is not compatible with this image; refusing", sdk.Identify()))
	}

	if !whitelist.Allowed(sdk.HardwareVersion, sdk.SoftwareVersion, sdk.ProductVersion) && !opt.AllowUnknownVersion {
		return fail(emit, fmt.Errorf("firmware %s (hardware %s) is not on the validated whitelist; refusing to flash",
			sdk.SoftwareVersion, sdk.HardwareVersion))
	}

	emit(Event{Level: LevelStep, Msg: "Uploading flasher and image"})
	remoteImg, err := pushPayload(client, opt.ImagePath, emit)
	if err != nil {
		return fail(emit, err)
	}

	emit(Event{Level: LevelStep, Msg: "Verifying image"})
	if err := runMlflash(client, emit, "--inspect", remoteImg); err != nil {
		return fail(emit, fmt.Errorf("mlflash --inspect failed: %w", err))
	}

	emit(Event{Level: LevelStep, Msg: "Flashing open firmware to the inactive slot"})
	if err := runMlflash(client, emit, "--flash", remoteImg); err != nil {
		return fail(emit, fmt.Errorf("mlflash --flash failed: %w", err))
	}

	emit(Event{Level: LevelStep, Msg: "Activating the new firmware"})
	if err := runMlflash(client, emit, "--flip"); err != nil {
		return fail(emit, fmt.Errorf("mlflash --flip failed: %w", err))
	}

	if err := rebootAndWait(client, opt.DeviceIP, emit); err != nil {
		return fail(emit, err)
	}

	emit(Event{Level: LevelDone, Msg: "Done - the device is now running the open firmware."})
	return nil
}

// connect dials as root on the stock slot. If stock auth fails but the open-slot
// password works, the unit is already flashed: it returns that open-slot client
// with alreadyOpen == true (the caller closes it).
func connect(ip string) (client *device.Client, alreadyOpen bool, err error) {
	client, err = device.Dial(ip, "root", device.StockPassword, 10*time.Second)
	if err == nil {
		return client, false, nil
	}

	if isAuthError(err) {
		if openCli, openErr := device.Dial(ip, "root", device.OpenPassword, 10*time.Second); openErr == nil {
			return openCli, true, nil
		}
	}

	return nil, false, err
}

// deviceName reads the human device name from the device-tree model (e.g.
// "Artosyn Proxima-9311 (BetaFPV VR04 goggle)"), which our DTB carries and is
// present on the open slot. Falls back to the vendor product_version, then the
// hostname. Empty if none can be read.
func deviceName(client *device.Client) string {
	if out, err := client.Run("cat /proc/device-tree/model 2>/dev/null"); err == nil {
		// The device-tree property is NUL-terminated; trim NULs and whitespace.
		if model := strings.TrimSpace(strings.Trim(out, "\x00")); model != "" {
			return model
		}
	}

	if sdk, err := client.ReadSDKVersion(); err == nil && sdk.ProductVersion != "" {
		return sdk.ProductVersion
	}

	if out, err := client.Run("cat /etc/hostname 2>/dev/null"); err == nil {
		if host := strings.TrimSpace(out); host != "" {
			return host
		}
	}

	return ""
}

// ensureLink enforces the single-device rule and makes the device reachable,
// assigning the host IP if it is not already up.
func ensureLink(ctx context.Context, opt Options, emit Emit) error {
	backend := netcfg.New()
	candidates, err := backend.Candidates()
	if err != nil {
		return fail(emit, fmt.Errorf("scanning network interfaces: %w", err))
	}

	switch {
	case len(candidates) > 1:
		names := make([]string, len(candidates))
		for i, candidate := range candidates {
			names[i] = candidate.Name
		}
		return fail(emit, fmt.Errorf(
			"found %d candidate USB devices (%v); connect exactly one device and unplug the rest",
			len(candidates), names))

	case len(candidates) == 0:
		if device.Reachable(opt.DeviceIP, 2*time.Second) {
			emit(Event{Level: LevelWarn, Msg: "no USB gadget interface detected, but the device is reachable; continuing"})
			return nil
		}
		return fail(emit, fmt.Errorf("no device found - is it plugged in over USB and powered on?"))
	}

	candidate := candidates[0]
	emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("Found gadget interface %s (%s)", candidate.Name, candidate.MAC)})

	if device.Reachable(opt.DeviceIP, 2*time.Second) {
		emit(Event{Level: LevelInfo, Msg: "Device already reachable; network is up"})
		return nil
	}

	emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("Assigning %s to %s (may prompt for authorization)", opt.HostCIDR, candidate.Name)})
	cleanup, err := backend.Assign(candidate.Name, opt.HostCIDR)
	if err != nil {
		return fail(emit, fmt.Errorf("configuring the network on %s failed: %w", candidate.Name, err))
	}
	_ = cleanup // the address is left in place for the duration of the session

	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if device.Reachable(opt.DeviceIP, 2*time.Second) {
			emit(Event{Level: LevelInfo, Msg: "Device reachable"})
			return nil
		}

		select {
		case <-ctx.Done():
			return fail(emit, ctx.Err())
		case <-time.After(1 * time.Second):
		}
	}

	return fail(emit, fmt.Errorf("device %s did not become reachable after configuring the link", opt.DeviceIP))
}

// isAuthError reports whether err is an SSH authentication failure (transport
// worked, password rejected) rather than a connection/handshake problem.
func isAuthError(err error) bool {
	return err != nil && strings.Contains(err.Error(), "unable to authenticate")
}

// pushPayload uploads the embedded mlflash and the image over cat streams and
// returns the remote image path.
func pushPayload(client *device.Client, imagePath string, emit Emit) (string, error) {
	mlflashBin, mlflashSize := payload.Mlflash()
	emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("Uploading mlflash (%d KiB)", mlflashSize/1024)})
	if err := client.Push(mlflashBin, remoteMlflash, "755"); err != nil {
		return "", fmt.Errorf("uploading mlflash: %w", err)
	}

	imageFile, err := os.Open(imagePath)
	if err != nil {
		return "", err
	}

	defer imageFile.Close()
	stat, _ := imageFile.Stat()
	emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("Uploading %s (%d MiB)", filepath.Base(imagePath), stat.Size()/(1024*1024))})

	remoteImg := path.Join(remoteDir, filepath.Base(imagePath))
	if err := client.Push(imageFile, remoteImg, "644"); err != nil {
		return "", fmt.Errorf("uploading image: %w", err)
	}

	return remoteImg, nil
}

// runMlflash runs the on-device flasher with args and relays its output as info
// events, so the user sees mlflash's own per-component messages.
func runMlflash(client *device.Client, emit Emit, args ...string) error {
	cmd := remoteMlflash
	for _, a := range args {
		cmd += " " + a
	}

	return client.RunStream(cmd, func(line string) {
		// ubiformat/libscan redraw a per-eraseblock "... N % complete" counter
		// hundreds of times; drop it (the activity bar shows progress) and skip the
		// empty tokens left by "\r\n" pairs. The phase summary lines still come through.
		line = strings.TrimRight(line, " ")
		if line == "" || strings.Contains(line, "% complete") {
			return
		}

		emit(Event{Level: LevelInfo, Msg: line})
	})
}

// rebootAndWait triggers the watchdog reboot (never `reboot`) and waits for the
// open slot B to reappear as a reachable, SSH-answering device.
func rebootAndWait(client *device.Client, ip string, emit Emit) error {
	emit(Event{Level: LevelStep, Msg: "Rebooting into the open firmware"})
	// A plain `reboot` is a no-op here (sysrq is out); force the PMIC watchdog the
	// vendor way - arm it for 1s and stop petting - which resets WITHOUT setting the
	// SPL reboot-reason flag, so the SPL Falcon-boots the now-active slot B (setting
	// that flag would instead drop to U-Boot). Runs on the vendor slot A we flashed
	// from, which has ar_wdt_service. The connection drops as the SoC resets, so the
	// error is expected and ignored.
	_, _ = client.Run("sync; /usr/bin/ar_wdt_service -t 1 >/dev/null 2>&1 & sleep 1; killall ar_wdt_service")

	emit(Event{Level: LevelInfo, Msg: "Waiting for the device to come back (this can take a minute)"})
	deadline := time.Now().Add(120 * time.Second)
	for time.Now().Before(deadline) {
		time.Sleep(3 * time.Second)
		if device.Reachable(ip, 2*time.Second) {
			if c, err := device.Dial(ip, "root", device.OpenPassword, 5*time.Second); err == nil {
				_ = c.Close()
				emit(Event{Level: LevelInfo, Msg: "Open firmware is up and reachable"})
				return nil
			}
		}
	}

	return fmt.Errorf("the device did not come back on the open firmware within the timeout; " +
		"stock firmware on slot A is untouched - power-cycle and it will boot as before")
}

// fail emits an error event and returns the error.
func fail(emit Emit, err error) error {
	emit(Event{Level: LevelError, Msg: err.Error()})
	return err
}
