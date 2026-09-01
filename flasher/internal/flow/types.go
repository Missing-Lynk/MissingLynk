// The types crossing this package's boundary, plus the JSON shapes mlflash prints.
package flow

import (
	"fmt"
	"net"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/device"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/mlflash"
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
	ImagePath string   // .mlimg bundle to flash (required by Flash)
	DeviceIP  string   // stock-slot address, default DefaultDeviceIP (.100)
	OpenIPs   []string // open-slot addresses to probe (default: all known device open IPs)
	HostCIDR  string   // default DefaultHostCIDR

	// AllowUnknownVersion bypasses the firmware whitelist (developer use).
	AllowUnknownVersion bool

	// FlashOnly writes the inactive slot but does not flip the active slot or
	// reboot. The device keeps running its current slot; the newly written slot
	// can be activated later with the switch-slot action (or proven by RAM-boot
	// first). This is the Rule 2 safety valve: never flip to an unproven slot.
	FlashOnly bool
}

// Verdict is what a scan concluded about the connected unit.
type Verdict int

const (
	VerdictReady          Verdict = iota // identified, whitelisted, ready to flash
	VerdictUnidentified                  // product_version matched no known unit
	VerdictNotWhitelisted                // recognized unit, firmware not on the validated list
	VerdictAlreadyOpen                   // already running our open firmware
)

// BootProof is what the per-unit device.json record (mlflash --record) says about a
// slot: whether a record exists, the healthy-boot count, whether the record carries
// kernel/dtb digests at all, and the verdict (boots > 0 AND those digests still match
// the live partitions, computed on the device). DigestsRecorded splits "never had
// digests" (a slot installed outside this tool) from "digests differ", which are
// different things to tell the user. Other keys of the record are ignored.
type BootProof struct {
	Present         bool `json:"present"`
	Boots           int  `json:"boots"`
	DigestsRecorded bool `json:"digests_recorded"`
	Verified        bool `json:"verified"`
}

// DeviceInfo is what Detect learns about the connected unit: facts, and no rendered
// sentences.
type DeviceInfo struct {
	Unit     string // "P1_GND" (goggle), "P1_SKY" (air), "unknown"
	Product  string // product_version
	Firmware string // software_version
	Hardware string // hardware_version
	Name     string // human device name (device-tree model) for an already-open unit

	Verdict Verdict

	// The A/B slot state (from mlflash --slots), for the switch-slot feature.
	// ActiveSlot is the slot the device actually boots (the GPT active bit) and
	// RunningSlot is the slot this boot is running from; they differ in a flash-boot,
	// where the flashed slot runs from a host-loaded kernel while the other slot is
	// still the active one. TargetSlot is the slot a switch would activate - always
	// the complement of ActiveSlot, never of RunningSlot - and TargetContent is what
	// it holds (ContentOpen, ContentVendor, "empty", "unknown"). Switchable is true
	// only when the target holds a complete recognized image.
	ActiveSlot    string
	RunningSlot   string
	TargetSlot    string
	TargetContent string
	Switchable    bool

	// Proof is the boot record of the OPEN switch-target slot. Advisory only: it
	// never changes Switchable, it just says what is known about that slot. A zero
	// value means no record could be read.
	Proof BootProof

	// Preflight is the image-free flash gate (mlflash --preflight): whether the
	// device, as it stands, may be flashed at all. nil when the scan never got far
	// enough to ask, which keeps the gate shut.
	Preflight *Preflight
}

// IsFlashable reports whether this unit may be written to: a whitelisted unit AND a
// device state that permits a flash. Both halves must hold, so a stock unit running
// the wrong slot is not offered an image to flash at it.
func (i *DeviceInfo) IsFlashable() bool {
	return i.Verdict == VerdictReady && i.Preflight.IsGateOpen()
}

// FlashBlocker is why this device may not be flashed as it stands, BlockerNone when
// nothing is in the way. A device the scan refused before it ever reached the gate
// reports BlockerUnprobed, which the card never shows: its verdict already says why.
func (i *DeviceInfo) FlashBlocker() Blocker {
	if i.Preflight == nil {
		return BlockerUnprobed
	}

	return i.Preflight.Blocker
}

// IsAlreadyOpen reports whether the unit is already running our open firmware.
func (i *DeviceInfo) IsAlreadyOpen() bool { return i.Verdict == VerdictAlreadyOpen }

// SwitchTarget names the slot a switch activates and what the scan found in it.
// The user consents to exactly this pair (the dialog names both), and SwitchSlot
// re-verifies both against a fresh probe right before the flip, so what the user
// confirmed is always what happens.
type SwitchTarget struct {
	Slot    string // "A" or "B"
	Content string // "open" or "vendor"
}

// Defaults for the fixed gadget link.
const (
	DefaultDeviceIP = device.DefaultIP // stock/unflashed (.100)
	DefaultHostCIDR = "192.168.3.222/24"
)

// SwitchTarget is the slot switch this scan found, for the caller to hand back to
// SwitchSlot.
func (i *DeviceInfo) SwitchTarget() SwitchTarget {
	return SwitchTarget{Slot: i.TargetSlot, Content: i.TargetContent}
}

// isSwitchTarget reports whether the slot a flip would activate holds a complete
// recognized image (ours or the vendor's), so offering the switch makes sense. It
// deliberately does not require Consistent: a flash-boot is exactly the state the
// flip step of flash -> flashboot -> flip runs in. mlflash only names a target slot
// when it could read the GPT active bit, so a resolved TargetSlot is the guarantee
// that the flip has a defined direction.
func isSwitchTarget(report *mlflash.SlotReport) bool {
	return report.TargetSlot != "" && report.TargetSlot != mlflash.SlotUnknown && report.TargetComplete &&
		(report.TargetContent == ContentOpen || report.TargetContent == ContentVendor)
}

// applyDefaults fills the unset options and rejects malformed ones. The addresses
// reach dial targets and privileged `ip addr` command lines, so a typo is better
// caught here than as an opaque OS error deeper in.
func (o *Options) applyDefaults() error {
	if o.DeviceIP == "" {
		o.DeviceIP = DefaultDeviceIP
	}

	if net.ParseIP(o.DeviceIP) == nil {
		return fmt.Errorf("device address %q is not a valid IP address", o.DeviceIP)
	}

	if len(o.OpenIPs) == 0 {
		o.OpenIPs = defaultOpenIPs()
	}

	for _, ip := range o.OpenIPs {
		if net.ParseIP(ip) == nil {
			return fmt.Errorf("open-slot address %q is not a valid IP address", ip)
		}
	}

	if o.HostCIDR == "" {
		o.HostCIDR = DefaultHostCIDR
	}

	if _, _, err := net.ParseCIDR(o.HostCIDR); err != nil {
		return fmt.Errorf("host address %q is not a valid CIDR (want e.g. %s): %w",
			o.HostCIDR, DefaultHostCIDR, err)
	}

	return nil
}
