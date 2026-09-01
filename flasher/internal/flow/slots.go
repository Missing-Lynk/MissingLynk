// Reading the A/B slot state for the device card and the switch dialog. Nothing
// here writes to the device, and nothing here words a sentence for the user.
package flow

import (
	"fmt"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/mlflash"
)

// fillSwitchTarget probes the slot state and records the offered switch on info:
// which slot is active, which slot this boot runs from, and what the slot a flip
// would activate holds. The direction follows the device's real active slot, so it
// is offered from whichever slot is running - including a flash-boot, where the
// running slot is not the active one. A failed probe is a warning, not an error:
// the device card just shows no switch line.
func fillSwitchTarget(tool *mlflash.Tool, info *DeviceInfo, emit Emit) {
	state, err := tool.Slots()
	if err != nil {
		emit(Event{Level: LevelWarn, Msg: fmt.Sprintf("slot probe failed: %v", err)})
		return
	}

	info.ActiveSlot = state.GptActive
	info.RunningSlot = state.Running
	info.TargetSlot = state.TargetSlot
	info.TargetContent = state.TargetContent
	info.Switchable = isSwitchTarget(state)
	if !info.Switchable {
		return
	}

	// Only the open slot can have a boot proof: the record is written by this tool at
	// flash time, so a slot it never installed has nothing to report.
	if info.TargetContent == ContentOpen {
		info.Proof = probeRecord(tool, info.TargetSlot)
	}
}

// probeRecord reads the boot-proof verdict for slot (the switch target). mlflash
// reports an absent record as a present:false verdict rather than as a failure, so a
// read that does fail is the same nothing-is-known answer: a zero report, which the
// caller renders as the plain caution.
func probeRecord(tool *mlflash.Tool, slot string) BootProof {
	report, err := tool.Record(slot)
	if err != nil {
		return BootProof{}
	}

	return BootProof(report)
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
