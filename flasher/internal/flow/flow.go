// Package flow is the headless engine behind the GUI: detect the connected
// device, then (on demand) flash an image onto it. It splits into two phases so
// the GUI can show the device first and flash only when the user chooses an image
// and clicks Flash. It emits typed progress events; the GUI renders them. No flash
// logic lives here - every byte-level decision is mlflash's on the device.
package flow

import (
	"context"
	"encoding/json"
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

// Per-slot reboot commands. A plain `reboot` is a no-op on this hardware (sysrq
// is out); the reliable reset is the watchdog, fired WITHOUT setting the SPL
// reboot-reason flag so the SPL Falcon-boots the GPT-active slot (setting that
// flag would instead drop to U-Boot).
const (
	// The vendor slot has ar_wdt_service: arm the watchdog for 1s and stop petting
	// it. The connection drops as the SoC resets, so the command error is ignored.
	stockRebootCmd = "sync; /usr/bin/ar_wdt_service -t 1 >/dev/null 2>&1 & sleep 1; killall ar_wdt_service"

	// The open slot ships the self-contained wdt-reset helper.
	openRebootCmd = "sync; /usr/local/bin/wdt-reset"
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

	// FlashOnly writes the inactive slot but does not flip the active slot or
	// reboot. The device keeps running its current slot; the newly written slot
	// can be activated later with the switch-slot action (or proven by RAM-boot
	// first). This is the Rule 2 safety valve: never flip to an unproven slot.
	FlashOnly bool
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
	Note        string `json:"note"`        // one-sentence status summary
	Detail      string `json:"detail"`      // optional follow-on line (e.g. the switch-slot hint)

	// The inactive slot's contents (from mlflash --slots), for the switch-slot
	// feature. OtherContent is "open", "vendor", "empty", or "unknown"; Switchable
	// is true only when that slot holds a complete recognized image the device can
	// be switched to.
	OtherSlot    string `json:"otherSlot"`
	OtherContent string `json:"otherContent"`
	Switchable   bool   `json:"switchable"`
}

// slotState mirrors the JSON object mlflash --slots prints.
type slotState struct {
	Running       string `json:"running"`
	GptActive     string `json:"gpt_active"`
	Consistent    bool   `json:"consistent"`
	OtherSlot     string `json:"other_slot"`
	OtherContent  string `json:"other_content"`
	OtherModel    string `json:"other_model"`
	OtherComplete bool   `json:"other_complete"`
}

// isSwitchTarget reports whether the inactive slot holds a complete recognized
// image (ours or the vendor's) and the slot bookkeeping is sane, so flipping to
// it is offerable.
func (s *slotState) isSwitchTarget() bool {
	return s.Consistent && s.OtherComplete &&
		(s.OtherContent == "open" || s.OtherContent == "vendor")
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

		// The inactive slot should be the untouched stock firmware; if it is, offer
		// switching back to it. Goggle only (the device-tree model names the unit),
		// matching the gate on the stock branch.
		if strings.Contains(strings.ToLower(info.Name), "goggle") {
			fillOtherSlot(client, info, "vendor", emit)
		}
		if info.Switchable {
			info.Detail = "The stock firmware is on the other slot; it can be switched back."
		}

		emitSummary(emit, info)
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

	// A previously flashed open image may still be intact on the inactive slot; if
	// it is (goggle only), the device can be switched to it without reflashing.
	if sdk.Identify() == device.UnitGoggle {
		fillOtherSlot(client, info, "open", emit)
		if info.Switchable {
			info.Detail = "The MissingLynk firmware is on the other slot; it can be switched to directly."
		}
	}

	// Close out the scan log with the outcome, so it does not just stop.
	if info.Flashable {
		emitSummary(emit, info)
	} else {
		emit(Event{Level: LevelWarn, Msg: info.Note})
		if info.Detail != "" {
			emit(Event{Level: LevelDone, Msg: info.Detail})
		}
	}

	return info, nil
}

// emitSummary logs the status summary and, when present, the follow-on detail as
// a separate line so the log mirrors the two-line device card. Both go out as
// LevelDone so the detail sits flush-left under the summary rather than indented
// like a step's sub-detail.
func emitSummary(emit Emit, info *DeviceInfo) {
	emit(Event{Level: LevelDone, Msg: info.Note})
	if info.Detail != "" {
		emit(Event{Level: LevelDone, Msg: info.Detail})
	}
}

// fillOtherSlot probes the inactive slot and records what it holds on info.
// Switchable is set only when that slot carries a complete image of the expected
// kind (wantContent), i.e. the opposite of what is running. A failed probe is a
// warning, not an error: the device card just shows no other-slot line.
func fillOtherSlot(client *device.Client, info *DeviceInfo, wantContent string, emit Emit) {
	state, err := probeSlots(client, emit)
	if err != nil {
		emit(Event{Level: LevelWarn, Msg: fmt.Sprintf("inactive-slot probe failed: %v", err)})
		return
	}

	info.OtherSlot = state.OtherSlot
	info.OtherContent = state.OtherContent
	info.Switchable = state.isSwitchTarget() && state.OtherContent == wantContent
}

// probeSlots uploads mlflash and runs its read-only --slots report. Nothing is
// written on the device beyond the mlflash binary itself (in /tmp).
func probeSlots(client *device.Client, emit Emit) (*slotState, error) {
	if err := pushMlflash(client, emit); err != nil {
		return nil, err
	}

	out, err := client.Run(remoteMlflash + " --slots")
	// mlflash exits non-zero when the probe could not complete, but the JSON line
	// still carries what it determined, so parse before judging the exit status.
	var state slotState
	if jsonErr := json.Unmarshal([]byte(strings.TrimSpace(out)), &state); jsonErr != nil {
		if err != nil {
			return nil, fmt.Errorf("mlflash --slots failed: %w", err)
		}

		return nil, fmt.Errorf("parsing mlflash --slots output %q: %w", strings.TrimSpace(out), jsonErr)
	}

	return &state, nil
}

// OtherSlotDescription is the human name of an inactive-slot classification, for
// the GUI's device card and dialogs.
func OtherSlotDescription(content string) string {
	switch content {
	case "open":
		return "the MissingLynk open firmware"

	case "vendor":
		return "the stock firmware"

	case "empty":
		return "nothing (erased)"

	default:
		return "unrecognized data"
	}
}

// SwitchSlot makes the inactive slot the active boot slot without writing any
// image data (gpt0 is the only partition written) and reboots into it. Detect
// must have reported Switchable; the slot state is re-verified here right before
// the flip (defence in depth, mirroring how Flash re-verifies identity).
// switchToOpen is the direction the user consented to (true = activate the open
// slot); if the device's actual state implies the other direction, the switch is
// refused, so the consent dialog the user saw always matches what happens.
func SwitchSlot(ctx context.Context, opt Options, switchToOpen bool, emit Emit) error {
	opt.applyDefaults()

	emit(Event{Level: LevelStep, Msg: "Preparing"})
	if err := ensureLink(ctx, opt, emit); err != nil {
		return err
	}

	client, runningOpen, err := connect(opt.DeviceIP)
	if err != nil {
		return fail(emit, fmt.Errorf("SSH connect to %s failed: %w", opt.DeviceIP, err))
	}

	defer client.Close()
	if !runningOpen != switchToOpen {
		return fail(emit, fmt.Errorf("the device's firmware changed since the scan "+
			"(the confirmed switch direction no longer applies); re-scan and try again"))
	}

	emit(Event{Level: LevelStep, Msg: "Re-checking the slots"})
	state, err := probeSlots(client, emit)
	if err != nil {
		return fail(emit, err)
	}

	wantContent := "open"
	if runningOpen {
		wantContent = "vendor"
	}

	if !state.isSwitchTarget() || state.OtherContent != wantContent {
		return fail(emit, fmt.Errorf("slot %s does not hold a complete image of %s (found: %s); refusing to switch",
			state.OtherSlot, OtherSlotDescription(wantContent), OtherSlotDescription(state.OtherContent)))
	}

	emit(Event{Level: LevelStep, Msg: fmt.Sprintf("Making slot %s the active boot slot", state.OtherSlot)})
	if err := runMlflash(client, emit, "--flip"); err != nil {
		return fail(emit, fmt.Errorf("mlflash --flip failed: %w", err))
	}

	// The reboot mechanism and the password of the firmware we land on differ by
	// direction.
	rebootCmd, targetPassword := stockRebootCmd, device.OpenPassword
	doneMsg := "Done - the device is now running the MissingLynk open firmware."
	if runningOpen {
		rebootCmd, targetPassword = openRebootCmd, device.StockPassword
		doneMsg = "Done - the device is now running the stock firmware."
	}

	// The open slot serves DHCP; the vendor slot does not. runningOpen means we are
	// switching to the vendor slot, so the target serves DHCP only when NOT runningOpen.
	if err := rebootAndWait(ctx, opt, client, rebootCmd, targetPassword, !runningOpen, emit); err != nil {
		return fail(emit, err)
	}

	emit(Event{Level: LevelDone, Msg: doneMsg})
	return nil
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

	if opt.FlashOnly {
		emit(Event{Level: LevelDone, Msg: "Done - the open firmware is written to the inactive slot. " +
			"The device is still running its current slot; use Switch slot to activate the new firmware " +
			"once you are ready."})
		return nil
	}

	emit(Event{Level: LevelStep, Msg: "Activating the new firmware"})
	if err := runMlflash(client, emit, "--flip"); err != nil {
		return fail(emit, fmt.Errorf("mlflash --flip failed: %w", err))
	}

	// Flashing lands on the open slot, which serves DHCP.
	if err := rebootAndWait(ctx, opt, client, stockRebootCmd, device.OpenPassword, true, emit); err != nil {
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

// pushMlflash uploads the embedded on-device flasher to /tmp on the device.
func pushMlflash(client *device.Client, emit Emit) error {
	mlflashBin, mlflashSize := payload.Mlflash()
	emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("Uploading mlflash (%d KiB)", mlflashSize/1024)})
	if err := client.Push(mlflashBin, remoteMlflash, "755"); err != nil {
		return fmt.Errorf("uploading mlflash: %w", err)
	}

	return nil
}

// pushPayload uploads the embedded mlflash and the image over cat streams and
// returns the remote image path.
func pushPayload(client *device.Client, imagePath string, emit Emit) (string, error) {
	if err := pushMlflash(client, emit); err != nil {
		return "", err
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

// rebootAndWait triggers the watchdog reboot (never `reboot`; see the reboot-
// command constants) and waits for the now-active slot to reappear as a
// reachable device that answers SSH with targetPassword. The connection drops as
// the SoC resets, so the reboot command's error is expected and ignored.
//
// The USB gadget re-enumerates on reboot with a boot-randomized MAC, so the host
// sees a NEW interface (enx<newmac>); the host IP assigned to the pre-reboot
// interface does not carry over. The slot we land on may also serve no DHCP, so
// the fresh interface can come up with no address at all and stay unreachable
// forever. This reattaches the host IP to the re-enumerated interface, which is
// what lets a switch back to the vendor slot be detected as complete.
//
// targetServesDHCP says whether the slot being booted serves DHCP (the open slot
// does, the vendor slot does not). For a DHCP slot we wait briefly for DHCP to
// configure the host before doing a static reattach, which avoids a needless
// authorization prompt; for a non-DHCP slot we reattach as soon as the interface
// appears, so the vendor slot is detected as soon as it is up.
func rebootAndWait(ctx context.Context, opt Options, client *device.Client, rebootCmd, targetPassword string, targetServesDHCP bool, emit Emit) error {
	ip := opt.DeviceIP
	emit(Event{Level: LevelStep, Msg: "Rebooting into the newly activated firmware"})

	// The reboot command tears the SoC down mid-session, so this SSH call never
	// returns cleanly: it blocks on the dead transport until the host's TCP timeout
	// (up to a minute, as no SSH keepalive is set). Waiting on it would stall the
	// whole reconnect - including the host-IP reattach - for that long, so fire it
	// in the background and move straight to the wait loop. The command is delivered
	// before the SoC resets; the deferred client.Close eventually unblocks the call.
	go func() { _, _ = client.Run(rebootCmd) }()

	emit(Event{Level: LevelInfo, Msg: "Waiting for the device to come back (this can take a minute)"})

	// Let the SoC actually reset and drop the USB link before polling, so the old
	// interface is gone and only the re-enumerated one is a candidate.
	if !sleepCtx(ctx, 6*time.Second) {
		return ctx.Err()
	}

	backend := netcfg.New()
	assigned := map[string]bool{}
	lastIfaces := ""
	// A DHCP slot gets a short grace to configure the host on its own; a non-DHCP
	// slot is reattached immediately once its interface enumerates.
	reattachAfter := time.Now()
	if targetServesDHCP {
		reattachAfter = reattachAfter.Add(8 * time.Second)
	}
	deadline := time.Now().Add(180 * time.Second)
	for time.Now().Before(deadline) {
		if device.Reachable(ip, 2*time.Second) {
			if c, err := device.Dial(ip, "root", targetPassword, 5*time.Second); err == nil {
				_ = c.Close()
				emit(Event{Level: LevelInfo, Msg: "The device is back up and reachable"})
				return nil
			}

			emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("%s answers but SSH is not ready yet", ip)})
		} else if time.Now().After(reattachAfter) {
			// Not reachable and no DHCP took hold: reattach the host IP to the
			// re-enumerated gadget interface. Each interface name is assigned once,
			// so a boot-randomized MAC is picked up without repeating the prompt.
			ifaces := candidateNames(backend)
			if joined := strings.Join(ifaces, ", "); joined != lastIfaces {
				lastIfaces = joined
				if joined == "" {
					emit(Event{Level: LevelInfo, Msg: "Waiting for the re-enumerated USB gadget interface"})
				} else {
					emit(Event{Level: LevelInfo, Msg: "Gadget interface(s): " + joined})
				}
			}

			for _, iface := range ifaces {
				if assigned[iface] {
					continue
				}

				emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("Reattaching the host network to %s", iface)})
				if _, err := backend.Assign(iface, opt.HostCIDR); err != nil {
					emit(Event{Level: LevelWarn, Msg: fmt.Sprintf("reattaching the host network to %s failed: %v", iface, err)})
				} else {
					assigned[iface] = true
				}

				break
			}
		}

		if !sleepCtx(ctx, 2*time.Second) {
			return ctx.Err()
		}
	}

	return fmt.Errorf("the device did not come back on the newly activated firmware within the timeout; " +
		"the slot flip itself is already committed, so power-cycle the device to (re)try booting " +
		"the newly activated slot (the stock firmware slot is never modified)")
}

// candidateNames returns the names of every USB gadget interface currently
// enumerated, for reattach and progress logging.
func candidateNames(backend netcfg.Backend) []string {
	candidates, err := backend.Candidates()
	if err != nil {
		return nil
	}

	names := make([]string, len(candidates))
	for i, candidate := range candidates {
		names[i] = candidate.Name
	}

	return names
}

// sleepCtx sleeps for d, returning false if ctx is cancelled first.
func sleepCtx(ctx context.Context, d time.Duration) bool {
	select {
	case <-ctx.Done():
		return false
	case <-time.After(d):
		return true
	}
}

// fail emits an error event and returns the error.
func fail(emit Emit, err error) error {
	emit(Event{Level: LevelError, Msg: err.Error()})
	return err
}
