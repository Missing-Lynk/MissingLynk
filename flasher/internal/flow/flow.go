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
	"path/filepath"
	"strings"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/device"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/manifest"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/whitelist"
)

// gateResult is the outcome of the identity + whitelist gate that both Detect and
// Flash apply. Flash re-runs it right before writing as defence in depth, so keeping
// the decision in one place is what stops the two checks from drifting (a scan that
// says "ready" while the flash refuses, or the reverse).
type gateResult int

const (
	gateOK             gateResult = iota
	gateUnidentified              // product_version matched no known unit
	gateNotWhitelisted            // recognized unit, but its firmware is not on the validated list
)

// gateDevice classifies a device by its sdk_version. opt.AllowUnknownVersion bypasses
// only the whitelist gate; an unidentifiable unit is always refused.
func gateDevice(sdk *device.SDKVersion, opt Options) gateResult {
	if sdk.Identify() == device.UnitUnknown {
		return gateUnidentified
	}

	if !whitelist.Allowed(sdk.HardwareVersion, sdk.SoftwareVersion, sdk.ProductVersion) && !opt.AllowUnknownVersion {
		return gateNotWhitelisted
	}

	return gateOK
}

// Detect brings the link up, connects, and reports what is attached. It never
// writes anything. A nil error with info.Flashable == false means a device was
// found but cannot/should not be flashed (with the reason in info.Note).
func Detect(ctx context.Context, opt Options, emit Emit) (*DeviceInfo, error) {
	if err := opt.applyDefaults(); err != nil {
		return nil, fail(emit, err)
	}

	emit(Event{Level: LevelStep, Msg: "Looking for a connected device"})
	if err := ensureLink(ctx, opt, emit); err != nil {
		return nil, err
	}

	emit(Event{Level: LevelStep, Msg: "Reading the device"})
	client, alreadyOpen, _, err := connect(ctx, opt.DeviceIP, opt.OpenIPs)
	if err != nil {
		return nil, fail(emit, fmt.Errorf("SSH connect failed: %w", err))
	}

	defer client.Close()
	if alreadyOpen {
		info := &DeviceInfo{
			AlreadyOpen: true, Flashable: false,
			Name: deviceName(client),
			Note: "This device is already running the MissingLynk firmware.",
		}

		fillSwitchTarget(client, info, emit)
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

	switch gateDevice(sdk, opt) {
	case gateUnidentified:
		info.Note = "The connected unit could not be identified; refusing to flash."

	case gateNotWhitelisted:
		info.Note = fmt.Sprintf("Firmware %s (hardware %s) is not on the validated list; refusing for safety.",
			sdk.SoftwareVersion, sdk.HardwareVersion)

	default:
		info.Flashable = true
		info.Note = "Ready to flash."
	}

	// A previously flashed open image may still be intact on the non-active slot; if
	// it is, the device can be switched to it without reflashing.
	if info.Flashable {
		fillSwitchTarget(client, info, emit)
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

// SwitchSlot makes the device's non-active slot the active boot slot without
// writing any image data (gpt0 is the only partition written) and reboots into it.
// Detect must have reported Switchable; the slot state is re-verified here right
// before the flip (defence in depth, mirroring how Flash re-verifies identity).
//
// target is the slot and content the user consented to. The direction follows the
// device's real active slot rather than the firmware that happens to be running, so
// the switch works from either slot and from a flash-boot (where the running slot is
// not the active one). If a fresh probe no longer names that slot and content as the
// target, the switch is refused, so the dialog the user saw always matches what
// happens.
func SwitchSlot(ctx context.Context, opt Options, target SwitchTarget, emit Emit) error {
	if err := opt.applyDefaults(); err != nil {
		return fail(emit, err)
	}

	emit(Event{Level: LevelStep, Msg: "Preparing"})
	if err := ensureLink(ctx, opt, emit); err != nil {
		return err
	}

	client, runningOpen, connectedIP, err := connect(ctx, opt.DeviceIP, opt.OpenIPs)
	if err != nil {
		return fail(emit, fmt.Errorf("SSH connect failed: %w", err))
	}

	defer client.Close()

	// The open slot has no sdk_version.json, so infer the product from its IP.
	product := productFromOpenIP(connectedIP)
	if !runningOpen {
		sdk, err := client.ReadSDKVersion()
		if err != nil {
			return fail(emit, fmt.Errorf("reading device firmware version: %w", err))
		}

		product = sdk.ProductVersion
	}

	emit(Event{Level: LevelStep, Msg: "Re-checking the slots"})
	state, err := probeSlots(client, emit)
	if err != nil {
		return fail(emit, err)
	}

	if !state.isSwitchTarget() {
		return fail(emit, fmt.Errorf("slot %s does not hold a complete recognized image (found: %s); "+
			"refusing to switch", state.TargetSlot, slotContentDescription(state.TargetContent)))
	}

	if !strings.EqualFold(state.TargetSlot, target.Slot) || state.TargetContent != target.Content {
		return fail(emit, fmt.Errorf("the device's slot state changed since the scan (the switch is now "+
			"slot %s holding %s, not slot %s holding %s as confirmed); re-scan and try again",
			state.TargetSlot, slotContentDescription(state.TargetContent),
			target.Slot, slotContentDescription(target.Content)))
	}

	emit(Event{Level: LevelStep, Msg: fmt.Sprintf("Making slot %s the active boot slot", state.TargetSlot)})
	if err := runMlflash(client, emit, "--flip"); err != nil {
		return fail(emit, fmt.Errorf("mlflash --flip failed: %w", err))
	}

	land, err := landingFor(runningFirmware(runningOpen), state.TargetContent, product, connectedIP, opt)
	if err != nil {
		return fail(emit, err)
	}

	if err := rebootAndWait(ctx, opt, client, land, emit); err != nil {
		return fail(emit, err)
	}

	doneMsg := "Done - the device is now running the stock firmware."
	if land.activated == firmwareOpen {
		doneMsg = "Done - the device is now running the MissingLynk open firmware."
	}

	emit(Event{Level: LevelDone, Msg: doneMsg})
	return nil
}

// Flash performs the real slot-B write and the active-slot flip for opt.ImagePath.
// mlflash writes only the inactive slot and never slot A, so a failed slot B still
// reverts to intact stock firmware.
func Flash(ctx context.Context, opt Options, emit Emit) error {
	if err := opt.applyDefaults(); err != nil {
		return fail(emit, err)
	}

	if opt.ImagePath == "" {
		return fail(emit, fmt.Errorf("no image selected"))
	}

	if _, err := os.Stat(opt.ImagePath); err != nil {
		return fail(emit, fmt.Errorf("image %s: %w", opt.ImagePath, err))
	}

	// Read the manifest before touching the device: a wrong or corrupt image can then
	// be rejected without spending an upload on it, and the check below has the
	// bundle's target_device in hand by the time the device names itself.
	emit(Event{Level: LevelStep, Msg: "Checking the image"})
	image, err := manifest.Read(opt.ImagePath)
	if err != nil {
		return fail(emit, err)
	}

	emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("%s targets %s, version %s",
		filepath.Base(opt.ImagePath), image.TargetDevice, image.Version)})

	emit(Event{Level: LevelInfo, Msg: "Verifying the image contents"})
	if err := image.Verify(opt.ImagePath); err != nil {
		return fail(emit, fmt.Errorf("%w; re-download the image", err))
	}

	emit(Event{Level: LevelStep, Msg: "Preparing"})
	if err := ensureLink(ctx, opt, emit); err != nil {
		return err
	}

	client, alreadyOpen, connectedIP, err := connect(ctx, opt.DeviceIP, opt.OpenIPs)
	if err != nil {
		return fail(emit, fmt.Errorf("SSH connect failed: %w", err))
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

	switch gateDevice(sdk, opt) {
	case gateUnidentified:
		return fail(emit, fmt.Errorf("connected unit could not be identified; refusing to flash"))

	case gateNotWhitelisted:
		return fail(emit, fmt.Errorf("firmware %s (hardware %s) is not on the validated whitelist; refusing to flash",
			sdk.SoftwareVersion, sdk.HardwareVersion))
	}

	// The board gate, run here rather than only on the device: mlflash rejects a
	// mismatched image too (board_matches, verbatim string compare against the same
	// product_version), but only after the whole bundle has been uploaded.
	if !image.MatchesDevice(sdk.ProductVersion) {
		return fail(emit, fmt.Errorf("this image is built for %s but the connected device is %s; "+
			"refusing to flash. Select the image built for this device",
			image.TargetDevice, sdk.ProductVersion))
	}

	// Stage on a mounted card where there is one, otherwise in /tmp. The image must
	// not live in RAM on low-memory units, so /tmp is only accepted when it has
	// enough free space.
	stage, err := stageDir(client, opt.ImagePath, emit)
	if err != nil {
		return fail(emit, err)
	}

	emit(Event{Level: LevelStep, Msg: "Uploading flasher and image"})
	remoteImg, err := pushPayload(client, opt.ImagePath, stage, emit)
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

	// Remove the staged image now, while the SSH connection is still live (after a
	// flip+reboot the client is dead). Best-effort: a leftover image is harmless.
	removeRemote(client, remoteImg)

	if opt.FlashOnly {
		emit(Event{Level: LevelDone, Msg: "Done - the open firmware is written to the inactive slot. " +
			"The device is still running its current slot; use the switch button to activate the new firmware " +
			"once you are ready."})
		return nil
	}

	emit(Event{Level: LevelStep, Msg: "Activating the new firmware"})
	if err := runMlflash(client, emit, "--flip"); err != nil {
		return fail(emit, fmt.Errorf("mlflash --flip failed: %w", err))
	}

	// The flip above made the newly written slot the active one, so this reboot lands
	// on the open firmware, fired from the stock firmware this flash connected to.
	land, err := landingFor(firmwareStock, contentOpen, sdk.ProductVersion, connectedIP, opt)
	if err != nil {
		return fail(emit, err)
	}

	if err := rebootAndWait(ctx, opt, client, land, emit); err != nil {
		return fail(emit, err)
	}

	emit(Event{Level: LevelDone, Msg: "Done - the device is now running the open firmware."})
	return nil
}
