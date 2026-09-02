// Package present turns what the flow engine found into what the window shows.
// Every sentence the user reads and every enable/disable rule lives here, as pure
// functions over a State, so the wording that warns before a slot flip can be
// tested without a display stack or a device.
package present

import (
	"fmt"
	"strings"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/flow"
)

// State is what the window knows right now: which phase is running, the last
// completed scan, and the image the user picked.
type State struct {
	Scanning  bool
	Flashing  bool
	Switching bool

	// Info is the last completed scan, nil before the first one finishes.
	Info *flow.DeviceInfo

	// ScanErr is set when the last scan found no device.
	ScanErr error

	// Image is the .mlimg the user chose, empty when none is selected.
	Image string
}

// DialogText is a confirmation dialog's wording.
type DialogText struct {
	Title string
	Body  string
}

// View is everything the window renders for a State. The GUI applies it verbatim:
// no decision about wording or enablement is left to the widget layer.
type View struct {
	// Title is the device-card heading and Status the line(s) below it. Status may
	// carry a second line, separated by a newline.
	Title  string
	Status string

	// IsStatusWarning marks a Status that reports a refusal, so the log can mark it
	// the same way the card does.
	IsStatusWarning bool

	// Busy hides the status text behind the activity bar while a phase runs.
	Busy bool

	RescanEnabled bool
	ChooseEnabled bool
	FlashEnabled  bool
	SwitchEnabled bool

	// SwitchLabel names the slot a switch would activate, which follows the device's
	// active slot rather than the firmware that happens to be running.
	SwitchLabel string

	FlashDialog  DialogText
	SwitchDialog DialogText
}

// Fixed wording that does not depend on what is connected.
const (
	scanningTitle = "Scanning for devices..."
	noDeviceTitle = "No device found"
	noDeviceHint  = "Connect one device over USB, power it on, then Re-scan."
	unnamedDevice = "Device"
	switchLabel   = "Switch slot"
)

// Render maps a State to everything on screen.
func Render(s State) View {
	busy := s.Scanning || s.Flashing || s.Switching
	view := View{
		Busy:          busy,
		RescanEnabled: !busy,
		SwitchLabel:   switchLabel,
		FlashDialog:   flashDialog(s.Info),
	}

	switch {
	case s.Scanning || (s.Info == nil && s.ScanErr == nil):
		view.Title = scanningTitle
		return view

	case s.ScanErr != nil:
		view.Title = noDeviceTitle
		view.Status = noDeviceHint

		return view
	}

	view.Title = title(s.Info)
	view.Status = status(s.Info)
	view.IsStatusWarning = isRefusal(s.Info.Verdict) || isGateShut(s.Info)

	// Choosing an image is gated on the same thing flashing is. Handing the user a
	// file picker for a device that cannot be flashed invites them to pick an image,
	// press Flash, and meet the refusal only then.
	flashable := s.Info.IsFlashable()
	view.ChooseEnabled = flashable && !busy
	view.FlashEnabled = flashable && !busy && s.Image != ""

	// The switch stays offered whatever the flash gate says: on a device running the
	// wrong slot it is the step that opens the gate.
	view.SwitchEnabled = s.Info.Switchable && !busy

	if s.Info.TargetSlot != "" {
		view.SwitchLabel = "Switch to slot " + s.Info.TargetSlot
	}

	if s.Info.Switchable {
		view.SwitchDialog = switchDialog(s.Info)
	}

	return view
}

// FlashDone is the message shown once a flash finishes. flashOnly wrote the
// inactive slot and left the device on its current one.
func FlashDone(flashOnly bool) DialogText {
	if flashOnly {
		return DialogText{
			Title: "Flash complete",
			Body: "The open firmware is written to the inactive slot. The device is still " +
				"running its current slot; use the switch button to activate it.",
		}
	}

	return DialogText{
		Title: "Flash complete",
		Body:  "The device is now running the MissingLynk open firmware.",
	}
}

// SwitchDone is the message shown once the device has come back on slot.
func SwitchDone(slot string) DialogText {
	return DialogText{
		Title: "Switch complete",
		Body:  fmt.Sprintf("The device is now running the firmware from slot %s.", slot),
	}
}

// IsFlashBoot reports whether this boot is running a slot other than the active
// one, which is why an offered switch can look inverted: the firmware running is
// the one on the slot being activated. Its usual cause is a flash-boot.
func IsFlashBoot(info *flow.DeviceInfo) bool {
	return info != nil && info.RunningSlot != "" && info.ActiveSlot != "" &&
		info.RunningSlot != info.ActiveSlot
}

// title is the device-card heading: the unit's own name where it has one, else the
// product with its firmware and hardware versions alongside.
func title(info *flow.DeviceInfo) string {
	if info.IsAlreadyOpen() {
		if info.Name != "" {
			return info.Name
		}

		return unnamedDevice
	}

	name := info.Product
	if name == "" {
		name = info.Unit
	}

	if info.Firmware != "" || info.Hardware != "" {
		return fmt.Sprintf("%s   (firmware %s, hardware %s)", name, info.Firmware, info.Hardware)
	}

	return name
}

// status is the summary sentence, with the switch line below it when one is offered.
func status(info *flow.DeviceInfo) string {
	lines := []string{verdictSentence(info)}
	if gate := gateSentence(info); gate != "" {
		lines = append(lines, gate)
	}

	if detail := switchDetail(info); detail != "" {
		lines = append(lines, detail)
	}

	return strings.Join(lines, "\n")
}

// verdictSentence states what the scan concluded about the unit's identity. Whether
// the device is in a state that permits a flash is gateSentence's to say.
func verdictSentence(info *flow.DeviceInfo) string {
	switch info.Verdict {
	case flow.VerdictAlreadyOpen:
		return "This device is already running the MissingLynk firmware."

	case flow.VerdictUnidentified:
		return "The connected unit could not be identified; refusing to flash."

	case flow.VerdictNotWhitelisted:
		return fmt.Sprintf("Firmware %s (hardware %s) is not on the validated list; refusing for safety.",
			info.Firmware, info.Hardware)

	case flow.VerdictReady:
		if isGateShut(info) {
			return "This device cannot be flashed as it is."
		}

		return "Ready to flash."
	}

	return ""
}

// gateSentence explains a shut flash gate and names the step that opens it. The
// explanation of what is wrong comes from the flow layer, so the log and the card
// carry the same words; only the next step is added here, because which step applies
// depends on whether the other slot can actually be switched to.
func gateSentence(info *flow.DeviceInfo) string {
	if !isGateShut(info) {
		return ""
	}

	return strings.TrimSpace(info.Preflight.Reason() + " " + nextStep(info))
}

// nextStep is the one action that moves this device towards a flashable state. A
// blocker with no step the user can take says so plainly rather than leaving them to
// guess: on this hardware a slot A that holds no complete image is a recovery job,
// not something this tool can repair.
func nextStep(info *flow.DeviceInfo) string {
	switch info.FlashBlocker() {
	case flow.BlockerNotOnSlotA:
		if info.Switchable && info.TargetSlot == flow.SlotA {
			return fmt.Sprintf("Use \"Switch to slot %s\" below, then flash.", info.TargetSlot)
		}

		return fmt.Sprintf("Slot %s does not hold a complete recognized firmware, so it cannot be "+
			"switched to; the device needs recovery before it can be flashed.", flow.SlotA)

	case flow.BlockerFlashBoot:
		return "Power-cycle the device so it boots its active slot, then re-scan."

	case flow.BlockerRunningUnknown:
		return "Power-cycle the device and re-scan."

	case flow.BlockerActiveUnknown:
		// No step is offered: power-cycling does not change which slot a device boots, and the
		// switch that would is the thing an unreadable active slot has taken away.
		return ""

	case flow.BlockerTargetUnfit:
		return "The device needs recovery before it can be flashed."
	}

	return ""
}

// isGateShut reports whether a unit that passed the identity gate is nonetheless in a
// state that forbids a flash. Only meaningful for a unit whose identity was accepted:
// one refused earlier never reached the gate, and its verdict already says why.
func isGateShut(info *flow.DeviceInfo) bool {
	return info.Verdict == flow.VerdictReady && !info.Preflight.IsGateOpen()
}

// isRefusal reports whether a verdict is a refusal to flash.
func isRefusal(verdict flow.Verdict) bool {
	return verdict == flow.VerdictUnidentified || verdict == flow.VerdictNotWhitelisted
}

// switchDetail is the device-card line for an offered switch: which slot is active
// now, which slot the switch activates, and what that slot holds, followed by the
// boot proof for an open target. A running slot that is not the active one is called
// out, because it is why the offered direction can look inverted. Empty when no
// switch is offered.
func switchDetail(info *flow.DeviceInfo) string {
	if !info.Switchable {
		return ""
	}

	content := contentDescription(info.TargetContent)
	line := fmt.Sprintf("Slot %s is active; slot %s holds %s and can be switched to.",
		info.ActiveSlot, info.TargetSlot, content)
	if IsFlashBoot(info) {
		line = fmt.Sprintf("This boot is running slot %s while slot %s is still the active one "+
			"(as after a flash-boot); switching activates slot %s, which holds %s.",
			info.RunningSlot, info.ActiveSlot, info.TargetSlot, content)
	}

	if proof := proofSentence(info); proof != "" {
		line += " " + proof
	}

	return line
}

// proofSentence says whether the OPEN switch-target slot has proven it boots, from
// the per-unit device.json record. The four outcomes are distinct and must not be
// collapsed: no record at all, proven, booted but unverifiable (the slot was
// installed outside this tool, so no digests were ever recorded), and a genuine
// digest mismatch. Only the last describes bytes that actually changed. Empty for a
// stock target: the record is written at flash time, so a slot this tool never
// installed has no record to read, whatever condition that slot is in.
func proofSentence(info *flow.DeviceInfo) string {
	if info.TargetContent != flow.ContentOpen {
		return ""
	}

	proof := info.Proof
	switch {
	case !proof.Present:
		return "This tool has no install record for this device, so it cannot confirm the target slot has ever booted."

	case proof.Verified:
		return fmt.Sprintf("The target slot booted cleanly %s and its bytes still verify.", bootCount(proof.Boots))

	case proof.Boots == 0:
		return "The target slot has an install record but has never booted successfully; it is unproven."

	case !proof.DigestsRecorded:
		return fmt.Sprintf("The target slot booted cleanly %s, but it was not installed by this tool, "+
			"so there are no recorded digests to verify its contents against.", bootCount(proof.Boots))

	default:
		return "The target slot's recorded bytes no longer match what is on it (re-flashed outside this tool, or degraded); treat it as unproven."
	}
}

// bootCount renders a healthy-boot count for a sentence ("once", "25 times").
func bootCount(boots int) string {
	if boots == 1 {
		return "once"
	}

	return fmt.Sprintf("%d times", boots)
}

// contentDescription is the human name of a slot-content classification.
func contentDescription(content string) string {
	switch content {
	case flow.ContentOpen:
		return "the MissingLynk open firmware"

	case flow.ContentVendor:
		return "the stock firmware"

	case "empty":
		return "nothing (erased)"

	default:
		return "unrecognized data"
	}
}

// switchDialog is the switch-slot confirmation. It names the slot being activated
// and, for the open direction, that the slot is activated without re-verification.
// Out of a flash-boot the firmware being activated is the one already running, which
// is worth saying, because the reboot still exercises that slot's own bootloader for
// the first time.
//
// The stock direction makes no claim about the slot's condition. A slot classifies as
// stock on its device tree's model string plus a kernel and a rootfs being present;
// that says what the slot holds, not that it is unmodified, current, or bootable.
func switchDialog(info *flow.DeviceInfo) DialogText {
	body := fmt.Sprintf("This makes slot %s (stock firmware) the active boot slot and reboots into it. "+
		"You can switch back to the MissingLynk firmware the same way afterwards.", info.TargetSlot)

	if info.TargetContent == flow.ContentOpen {
		body = fmt.Sprintf("This makes slot %s (MissingLynk open firmware) the active boot slot and reboots "+
			"into it, WITHOUT rewriting or re-verifying it. If that slot no longer boots, the device "+
			"will not start until the boot slot is recovered. Only proceed if this tool flashed the "+
			"open firmware onto this device before and it booted.", info.TargetSlot)

		if IsFlashBoot(info) {
			body = fmt.Sprintf("This makes slot %s (MissingLynk open firmware) the active boot slot and "+
				"reboots into it. This boot is already running slot %s while the other slot is still the "+
				"active one (as after a flash-boot), so the firmware being activated is the one running "+
				"right now - but that does not exercise slot %s's own bootloader, which the reboot will.",
				info.TargetSlot, info.TargetSlot, info.TargetSlot)
		}

		if proof := proofSentence(info); proof != "" {
			body += "\n\n" + proof
		}
	}

	return DialogText{
		Title: fmt.Sprintf("Switch to slot %s?", info.TargetSlot),
		Body:  body,
	}
}

// flashDialog offers the two flash modes. It names the slot being written and the
// slot being kept, from the gate that let the user get this far, so the last thing
// read before a write says which half of the device is at stake. Both slots are named
// only when the gate reported them; the dialog never guesses.
func flashDialog(info *flow.DeviceInfo) DialogText {
	written, kept := "the device's inactive slot", "the other slot"
	if info != nil && info.Preflight.IsGateOpen() {
		written = "slot " + info.Preflight.FlashSlot
		kept = "slot " + info.Preflight.Running
	}

	return DialogText{
		Title: "Flash open firmware?",
		Body: fmt.Sprintf("This writes the open firmware to %s. The stock firmware on %s, which the "+
			"device is running now, is left untouched.\n\n"+
			"Flash and switch: activate the newly written slot and reboot into it now.\n\n"+
			"Flash only: leave the device on its current slot. The new slot is written but not "+
			"activated; use the switch button to boot it once you are ready.", written, kept),
	}
}
