// Reading the A/B slot state and rendering it for the device card and switch dialog.
// Nothing here writes to the device.
package flow

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/device"
)

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

// fillSwitchTarget probes the slot state and records the offered switch on info:
// which slot is active, which slot this boot runs from, and what the slot a flip
// would activate holds. The direction follows the device's real active slot, so it
// is offered from whichever slot is running - including a flash-boot, where the
// running slot is not the active one. A failed probe is a warning, not an error:
// the device card just shows no switch line. Filling the target also fills the
// detail line and, for an open target, the boot-proof note.
func fillSwitchTarget(client deviceClient, info *DeviceInfo, emit Emit) {
	state, err := probeSlots(client, emit)
	if err != nil {
		emit(Event{Level: LevelWarn, Msg: fmt.Sprintf("slot probe failed: %v", err)})
		return
	}

	info.ActiveSlot = state.GptActive
	info.RunningSlot = state.Running
	info.TargetSlot = state.TargetSlot
	info.TargetContent = state.TargetContent
	info.Switchable = state.isSwitchTarget()
	if !info.Switchable {
		return
	}

	info.Detail = switchDetail(info)
	// Only the open slot needs a boot proof: the stock slot is the untouched factory
	// install this tool never writes.
	if info.TargetContent == "open" {
		fillProof(client, info, emit)
	}
}

// switchDetail is the device-card line for an offered switch: which slot is active
// now, which slot the switch activates, and what that slot holds. A running slot
// that is not the active one is called out, because it is why the offered direction
// can look inverted (the firmware that is running is the one on the slot being
// activated). Its usual cause is a flash-boot, which is named as an example rather
// than asserted - the same split shows up whenever a boot lands somewhere other than
// the active slot.
func switchDetail(info *DeviceInfo) string {
	content := slotContentDescription(info.TargetContent)
	if info.RunningSlot != "" && info.ActiveSlot != "" && info.RunningSlot != info.ActiveSlot {
		return fmt.Sprintf("This boot is running slot %s while slot %s is still the active one "+
			"(as after a flash-boot); switching activates slot %s, which holds %s.",
			info.RunningSlot, info.ActiveSlot, info.TargetSlot, content)
	}

	return fmt.Sprintf("Slot %s is active; slot %s holds %s and can be switched to.",
		info.ActiveSlot, info.TargetSlot, content)
}

// fillProof annotates info with the boot-proof verdict of the open switch-target
// slot (info.TargetSlot), from the per-unit device.json record. Advisory only: it
// never changes Switchable, it just tells the user whether that slot has proven it
// boots. The summary is appended to the device-card detail and exposed on info for
// the switch-confirm dialog. A missing/unreadable record degrades to the plain
// caution (empty note), never an error.
func fillProof(client deviceClient, info *DeviceInfo, emit Emit) {
	info.ProvenNote = provenSummary(probeRecord(client, info.TargetSlot))
	if info.ProvenNote != "" {
		info.Detail = strings.TrimSpace(info.Detail + " " + info.ProvenNote)
	}
}

// probeRecord runs mlflash --record for slot (the switch target) and parses the
// boot-proof verdict. mlflash is already uploaded by the preceding probeSlots, so
// this only reads. mlflash exits non-zero when the record is absent, but the JSON
// line still carries {"present":false}; an unparseable line yields a zero report,
// which provenSummary renders as the plain caution.
func probeRecord(client deviceClient, slot string) recordReport {
	out, _ := client.Run(remoteMlflash + " --record --slot " + device.ShellQuote(slot))
	var rec recordReport
	_ = json.Unmarshal([]byte(strings.TrimSpace(out)), &rec)

	return rec
}

// provenSummary turns a record verdict for the open switch-target slot into a human
// sentence for the device card and switch dialog. The four outcomes are distinct and
// must not be collapsed: no record at all, proven, booted but unverifiable (the slot
// was installed outside this tool, so no digests were ever recorded), and a genuine
// digest mismatch. Only the last describes bytes that actually changed.
func provenSummary(rec recordReport) string {
	if !rec.Present {
		return "This tool has no install record for this device, so it cannot confirm the target slot has ever booted."
	}

	if rec.Verified {
		return fmt.Sprintf("The target slot booted cleanly %s and its bytes still verify.", bootCount(rec.Boots))
	}

	if rec.Boots == 0 {
		return "The target slot has an install record but has never booted successfully; it is unproven."
	}

	if !rec.DigestsRecorded {
		return fmt.Sprintf("The target slot booted cleanly %s, but it was not installed by this tool, "+
			"so there are no recorded digests to verify its contents against.", bootCount(rec.Boots))
	}

	return "The target slot's recorded bytes no longer match what is on it (re-flashed outside this tool, or degraded); treat it as unproven."
}

// bootCount renders a healthy-boot count for a sentence ("once", "25 times").
func bootCount(boots int) string {
	if boots == 1 {
		return "once"
	}

	return fmt.Sprintf("%d times", boots)
}

// probeSlots uploads mlflash and runs its read-only --slots report. Nothing is
// written on the device beyond the mlflash binary itself (in /tmp).
func probeSlots(client deviceClient, emit Emit) (*slotState, error) {
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

// slotContentDescription is the human name of a slot-content classification, for
// the GUI's device card and dialogs.
func slotContentDescription(content string) string {
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
