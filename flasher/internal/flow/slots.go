// Reading the A/B slot state for the device card and the switch dialog. Nothing
// here writes to the device, and nothing here words a sentence for the user.
package flow

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/device"
)

// fillSwitchTarget probes the slot state and records the offered switch on info:
// which slot is active, which slot this boot runs from, and what the slot a flip
// would activate holds. The direction follows the device's real active slot, so it
// is offered from whichever slot is running - including a flash-boot, where the
// running slot is not the active one. A failed probe is a warning, not an error:
// the device card just shows no switch line.
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

	// Only the open slot needs a boot proof: the stock slot is the untouched factory
	// install this tool never writes.
	if info.TargetContent == ContentOpen {
		info.Proof = probeRecord(client, info.TargetSlot)
	}
}

// probeRecord runs mlflash --record for slot (the switch target) and parses the
// boot-proof verdict. mlflash is already uploaded by the preceding probeSlots, so
// this only reads. mlflash exits non-zero when the record is absent, but the JSON
// line still carries {"present":false}; an unparseable line yields a zero report,
// which the caller renders as the plain caution.
func probeRecord(client deviceClient, slot string) BootProof {
	out, _ := client.Run(remoteMlflash + " --record --slot " + device.ShellQuote(slot))
	var proof BootProof
	_ = json.Unmarshal([]byte(strings.TrimSpace(out)), &proof)

	return proof
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
// the errors this package raises. The device card and dialogs word it themselves.
func slotContentDescription(content string) string {
	switch content {
	case ContentOpen:
		return "the MissingLynk open firmware"

	case ContentVendor:
		return "the stock firmware"

	case "empty":
		return "nothing (erased)"

	default:
		return "unrecognized data"
	}
}
