// The image-free flash gate: whether this device, in the state it is in right now,
// may be flashed at all. Nothing here writes to the device.
//
// Reason() states what is wrong in one sentence, which both a refused flash and the
// device card use, so the log and the card carry the same words. It does not name the
// step that fixes it: that depends on what else the scan found.
package flow

import (
	"fmt"
	"strings"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/mlflash"
)

// SlotA is the slot a flash must run from.
//
// This rests on an assumption the tool does not verify: that slot A holds the
// recommended version of the vendor firmware, so that there is a safe slot to fall
// back to when a flashed slot B does not boot. A's partitions are never probed. What
// passing this gate does establish is narrower - that the device booted A and
// answered, plus, for a unit that also reached VerdictReady, that the sdk_version read
// from it is on the whitelist.
//
// Given the assumption, the rule is positional: a flash writes the slot that is not
// running, so running A is what keeps the write off A. mlflash enforces the same rule
// on the device, refusing an A target outright.
const SlotA = mlflash.SlotA

// Blocker is the one reason a device may not be flashed as it stands.
//
// BlockerUnprobed is the zero value, so a report that was never filled in reads as
// shut rather than clear: the gate can only be opened by a device that answered.
// The rest are ordered as classify() tests them, most fundamental first - an
// undetermined slot state hides everything below it, and a device on the wrong slot
// is worth reporting before the partition layout of a slot it will not write yet.
type Blocker int

const (
	BlockerUnprobed    Blocker = iota // the gate was never run
	BlockerSlotUnknown                // the running or active slot could not be determined
	BlockerFlashBoot                  // the running slot is not the active slot
	BlockerNotOnSlotA                 // the device is running slot B
	BlockerTargetUnfit                // a partition of the slot a flash would write is unusable
	BlockerNone                       // nothing is in the way
)

// PreflightTarget is one partition of the slot a flash would write, as mlflash judged
// it. Mtd is -1 and Bytes 0 when the name did not resolve at all.
type PreflightTarget struct {
	Name   string
	Status string
	Mtd    int
	Bytes  int64
}

// Preflight is what mlflash --preflight reported, plus the Blocker derived from it.
// It answers only the image-free half of "can this be flashed": slot state and the
// writability of the target partitions. The image-specific half (manifest hashes,
// per-component sizes, board identity) is mlflash --dry-run's, which needs the bundle
// and therefore cannot gate choosing one.
type Preflight struct {
	Running         string
	Active          string
	Consistent      bool
	FlashSlot       string
	Targets         []PreflightTarget
	TargetsResolved bool

	// Blocker is the first reason this device may not be flashed, BlockerNone when it
	// may. Derived by classify(), never sent by the device: mlflash reports facts and
	// the host owns the policy.
	Blocker Blocker
}

// IsGateOpen reports whether a flash may proceed. Only an explicit BlockerNone opens
// it, so a nil report and an unfilled one both keep it shut.
func (p *Preflight) IsGateOpen() bool {
	return p != nil && p.Blocker == BlockerNone
}

// unfitTargets lists the partitions that failed a guard, for the message naming what
// is wrong with the flash slot. Empty unless Blocker is BlockerTargetUnfit.
func (p *Preflight) unfitTargets() []PreflightTarget {
	if p == nil {
		return nil
	}

	var unfit []PreflightTarget
	for _, target := range p.Targets {
		if target.Status != mlflash.StatusOK {
			unfit = append(unfit, target)
		}
	}

	return unfit
}

// classify picks the one blocker to report, most fundamental first. A device can hold
// several at once (running B during a flash-boot with an unresolvable layout); naming
// them all would bury the one step the user has to take next.
func (p *Preflight) classify() {
	switch {
	case p.Running == "" || p.Running == mlflash.SlotUnknown || p.Active == "" || p.Active == mlflash.SlotUnknown:
		p.Blocker = BlockerSlotUnknown

	case !p.Consistent:
		p.Blocker = BlockerFlashBoot

	case !strings.EqualFold(p.Running, SlotA):
		p.Blocker = BlockerNotOnSlotA

	case !p.TargetsResolved:
		p.Blocker = BlockerTargetUnfit

	default:
		p.Blocker = BlockerNone
	}
}

// Reason states what is wrong with the device's state, in one sentence, for both the
// error a refused flash raises and the line the device card shows. It says what was
// found and why that forbids a flash; what the user should do about it depends on
// facts this type does not hold (whether the other slot can be switched to), so the
// card appends that itself.
func (p *Preflight) Reason() string {
	if p == nil {
		return "The device's boot slot was never read, so this tool cannot tell which slot a flash " +
			"would write."
	}

	switch p.Blocker {
	case BlockerNone:
		return ""

	case BlockerUnprobed:
		return "The device's boot slot was never read, so this tool cannot tell which slot a flash " +
			"would write."

	case BlockerSlotUnknown:
		return "The device did not report which boot slot it is running, so this tool cannot tell " +
			"which slot a flash would write."

	case BlockerFlashBoot:
		return fmt.Sprintf("This boot is running slot %s while slot %s is the active one (as after a "+
			"flash-boot). A flash from here would write a slot the device is not actually booting.",
			p.Running, p.Active)

	case BlockerNotOnSlotA:
		// Nothing here has looked inside the flash slot - running B, the only report in
		// hand describes B - so the fallback slot is named as an assumption, not as a
		// finding. The switch line below this one does check, and can contradict it.
		return fmt.Sprintf("This device is running slot %s. Flashing writes the slot that is not "+
			"running, so from slot %s it would write slot %s, which this tool assumes holds the "+
			"vendor firmware you would fall back to if the flash left slot %s unbootable.",
			p.Running, p.Running, p.FlashSlot, p.Running)

	case BlockerTargetUnfit:
		return fmt.Sprintf("Slot %s cannot be written: %s. The device's partition layout is not what "+
			"this tool expects.", p.FlashSlot, unfitSummary(p.unfitTargets()))
	}

	return "This device cannot be flashed in its current state."
}

// unfitSummary lists the failed partitions and what is wrong with each, as a clause
// for Reason ("kernel1 is missing, dtb1 is too small").
func unfitSummary(unfit []PreflightTarget) string {
	if len(unfit) == 0 {
		return "a partition could not be resolved"
	}

	clauses := make([]string, 0, len(unfit))
	for _, target := range unfit {
		clauses = append(clauses, target.Name+" "+statusClause(target.Status))
	}

	return strings.Join(clauses, ", ")
}

// statusClause is the predicate half of a sentence about one partition.
func statusClause(status string) string {
	switch status {
	case mlflash.StatusMissing:
		return "is missing from the partition table"

	case mlflash.StatusSibling:
		return "and its slot-A counterpart are the same partition"

	case mlflash.StatusWholeFlash:
		return "resolves to the whole flash device"

	case mlflash.StatusTooSmall:
		return "is too small for the image"
	}

	return "is unusable"
}

// blockerError is the error a refused flash raises. It carries the same sentence the
// card shows, so a user reading the log and a user reading the card are told the same
// thing.
func blockerError(report *Preflight) error {
	return fmt.Errorf("%s Refusing to flash", strings.TrimRight(report.Reason(), "."))
}

// runPreflight reads the flash gate off the device and classifies it.
func runPreflight(tool *mlflash.Tool) (*Preflight, error) {
	wire, err := tool.Preflight()
	if err != nil {
		return nil, err
	}

	report := &Preflight{
		Running:         wire.Running,
		Active:          wire.GptActive,
		Consistent:      wire.Consistent,
		FlashSlot:       wire.FlashSlot,
		TargetsResolved: wire.TargetsResolved,
	}

	for _, target := range wire.Targets {
		report.Targets = append(report.Targets, PreflightTarget(target))
	}

	report.classify()

	return report, nil
}

// fillPreflight probes the flash gate and records it on info. A failed probe is not a
// warning that can be waved through: without a report the tool does not know which
// slot it is on, so the gate stays shut and the card says so.
func fillPreflight(tool *mlflash.Tool, info *DeviceInfo, emit Emit) {
	report, err := runPreflight(tool)
	if err != nil {
		emit(Event{Level: LevelWarn, Msg: fmt.Sprintf("flash preflight failed: %v", err)})
		info.Preflight = &Preflight{Blocker: BlockerSlotUnknown}

		return
	}

	info.Preflight = report
}
