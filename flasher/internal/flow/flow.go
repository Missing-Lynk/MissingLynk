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
	"strconv"
	"strings"
	"time"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/device"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/devconf"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/netcfg"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/payload"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/whitelist"
)

// Defaults for the fixed gadget link.
const (
	DefaultDeviceIP = device.DefaultIP // stock/unflashed (.100)
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

// defaultOpenIPs returns every known open-slot address, sorted for stable probing.
func defaultOpenIPs() []string {
	seen := map[string]bool{}
	for _, ip := range devconf.OpenIP {
		seen[ip] = true
	}

	ips := make([]string, 0, len(seen))
	for ip := range seen {
		ips = append(ips, ip)
	}

	return ips
}

// productFromOpenIP maps a connected open-slot address back to the device's
// product_version. The open slot's IP is fixed per device by board.conf, so
// this is reliable even when the vendor sdk_version.json is absent (open slot B).
func productFromOpenIP(ip string) string {
	return devconf.ProductByOpenIP[ip]
}

// imageSize returns the byte size of path, or 0 if unavailable.
func imageSize(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}

	return info.Size()
}

// stageDir returns a writable directory on the device large enough to hold the
// flash image. It prefers a removable card when one is mounted, because /tmp is
// tmpfs and staging there spends RAM the flash itself needs. Where no card is
// mounted it falls back to /tmp, which is accepted only when the free space
// there covers the image plus a margin. Both branches are reached on any device;
// which one a given unit takes is a property of that unit and its card, so it is
// decided here by looking rather than by knowing the model.
func stageDir(client *device.Client, imagePath string, emit Emit) (string, error) {
	if sd, err := sdCardDir(client); err != nil {
		return "", err
	} else if sd != "" {
		return sd, nil
	}

	needed := imageSize(imagePath)
	if needed == 0 {
		return "", fmt.Errorf("cannot read image size for staging")
	}

	// Safety margin for tmpfs metadata and whatever else is in /tmp.
	needed += 20 * 1024 * 1024

	dir, err := tmpStageDir(client, needed)
	if err == nil {
		emit(Event{Level: LevelWarn,
			Msg: "No card mounted; staging the image in /tmp. " +
				"Make sure the device has enough free RAM or the flash may fail mid-write."})
	}

	return dir, err
}

// tmpStageDir checks /tmp free space and returns "/tmp" if it can hold minBytes.
// BusyBox df on the vendor slot does not support -B1, so we use -k (1024-byte
// blocks) and scale the result.
func tmpStageDir(client *device.Client, minBytes int64) (string, error) {
	out, err := client.Run("df -k /tmp")
	if err != nil {
		return "", fmt.Errorf("checking /tmp free space: %w", err)
	}

	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) < 2 {
		return "", fmt.Errorf("unexpected df output: %s", out)
	}

	fields := strings.Fields(lines[1])
	if len(fields) < 4 {
		return "", fmt.Errorf("unexpected df output: %s", out)
	}

	kb, err := strconv.ParseInt(fields[3], 10, 64)
	if err != nil {
		return "", fmt.Errorf("parsing df output: %w", err)
	}

	available := kb * 1024
	if available < minBytes {
		return "", fmt.Errorf("/tmp has only %d MiB free; need %d MiB. Free RAM on the device, "+
			"or mount a card for the image to stage on", available/(1024*1024), minBytes/(1024*1024))
	}

	return "/tmp", nil
}

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
	DeviceIP  string // stock-slot address, default DefaultDeviceIP (.100)
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

	// The A/B slot state (from mlflash --slots), for the switch-slot feature.
	// ActiveSlot is the slot the device actually boots (the GPT active bit) and
	// RunningSlot is the slot this boot is running from; they differ in a flash-boot,
	// where the flashed slot runs from a host-loaded kernel while the other slot is
	// still the active one. TargetSlot is the slot a switch would activate - always
	// the complement of ActiveSlot, never of RunningSlot - and TargetContent is what
	// it holds ("open", "vendor", "empty", "unknown"). Switchable is true only when
	// the target holds a complete recognized image.
	ActiveSlot    string `json:"activeSlot"`
	RunningSlot   string `json:"runningSlot"`
	TargetSlot    string `json:"targetSlot"`
	TargetContent string `json:"targetContent"`
	Switchable    bool   `json:"switchable"`

	// ProvenNote is a ready-to-show sentence about whether the OPEN switch-target
	// slot has proven it boots, from the per-unit device.json record (mlflash
	// --record). Advisory only: it never changes Switchable, it just tells the user
	// what is known about that slot. Empty when no record could be read (then the
	// caller keeps the plain caution).
	ProvenNote string `json:"provenNote"`
}

// SwitchTarget names the slot a switch activates and what the scan found in it.
// The user consents to exactly this pair (the dialog names both), and SwitchSlot
// re-verifies both against a fresh probe right before the flip, so what the user
// confirmed is always what happens.
type SwitchTarget struct {
	Slot    string // "A" or "B"
	Content string // "open" or "vendor"
}

// SwitchTarget is the slot switch this scan found, for the caller to hand back to
// SwitchSlot.
func (i *DeviceInfo) SwitchTarget() SwitchTarget {
	return SwitchTarget{Slot: i.TargetSlot, Content: i.TargetContent}
}

// recordReport captures the fields of the mlflash --record JSON that the boot-proof
// summary needs: whether a record exists, the healthy-boot count, whether the record
// carries kernel/dtb digests at all, and the verdict (boots > 0 AND those digests
// still match the live partitions, computed on the device). DigestsRecorded splits
// "never had digests" (a slot installed outside this tool) from "digests differ",
// which are different things to tell the user. Other keys are ignored.
type recordReport struct {
	Present         bool `json:"present"`
	Boots           int  `json:"boots"`
	DigestsRecorded bool `json:"digests_recorded"`
	Verified        bool `json:"verified"`
}

// slotState mirrors the JSON object mlflash --slots prints. Target* describes the
// slot a flip would activate: the complement of the GPT-active slot, which is not
// the complement of the running slot during a flash-boot. Consistent reports
// whether the running and active slots agree (false = flash-boot).
type slotState struct {
	Running        string `json:"running"`
	GptActive      string `json:"gpt_active"`
	Consistent     bool   `json:"consistent"`
	TargetSlot     string `json:"target_slot"`
	TargetContent  string `json:"target_content"`
	TargetModel    string `json:"target_model"`
	TargetComplete bool   `json:"target_complete"`
}

// isSwitchTarget reports whether the slot a flip would activate holds a complete
// recognized image (ours or the vendor's), so offering the switch makes sense. It
// deliberately does not require Consistent: a flash-boot is exactly the state the
// flip step of flash -> flashboot -> flip runs in. mlflash only names a target slot
// when it could read the GPT active bit, so a resolved TargetSlot is the guarantee
// that the flip has a defined direction.
func (s *slotState) isSwitchTarget() bool {
	return s.TargetSlot != "" && s.TargetSlot != "unknown" && s.TargetComplete &&
		(s.TargetContent == "open" || s.TargetContent == "vendor")
}

func (o *Options) applyDefaults() {
	if o.DeviceIP == "" {
		o.DeviceIP = DefaultDeviceIP
	}

	if len(o.OpenIPs) == 0 {
		o.OpenIPs = defaultOpenIPs()
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
	client, alreadyOpen, _, err := connect(opt.DeviceIP, opt.OpenIPs)
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

	unit := sdk.Identify()
	info := &DeviceInfo{
		Unit:     string(unit),
		Product:  sdk.ProductVersion,
		Firmware: sdk.SoftwareVersion,
		Hardware: sdk.HardwareVersion,
	}

	switch {
	case unit == device.UnitUnknown:
		info.Note = "The connected unit could not be identified; refusing to flash."

	case !whitelist.Allowed(sdk.HardwareVersion, sdk.SoftwareVersion, sdk.ProductVersion) && !opt.AllowUnknownVersion:
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
func fillSwitchTarget(client *device.Client, info *DeviceInfo, emit Emit) {
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
	content := SlotContentDescription(info.TargetContent)
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
func fillProof(client *device.Client, info *DeviceInfo, emit Emit) {
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
func probeRecord(client *device.Client, slot string) recordReport {
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

// SlotContentDescription is the human name of a slot-content classification, for
// the GUI's device card and dialogs.
func SlotContentDescription(content string) string {
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
	opt.applyDefaults()

	emit(Event{Level: LevelStep, Msg: "Preparing"})
	if err := ensureLink(ctx, opt, emit); err != nil {
		return err
	}

	client, runningOpen, connectedIP, err := connect(opt.DeviceIP, opt.OpenIPs)
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
			"refusing to switch", state.TargetSlot, SlotContentDescription(state.TargetContent)))
	}

	if !strings.EqualFold(state.TargetSlot, target.Slot) || state.TargetContent != target.Content {
		return fail(emit, fmt.Errorf("the device's slot state changed since the scan (the switch is now "+
			"slot %s holding %s, not slot %s holding %s as confirmed); re-scan and try again",
			state.TargetSlot, SlotContentDescription(state.TargetContent),
			target.Slot, SlotContentDescription(target.Content)))
	}

	emit(Event{Level: LevelStep, Msg: fmt.Sprintf("Making slot %s the active boot slot", state.TargetSlot)})
	if err := runMlflash(client, emit, "--flip"); err != nil {
		return fail(emit, fmt.Errorf("mlflash --flip failed: %w", err))
	}

	// The reboot command belongs to the firmware that is RUNNING (the vendor slot has
	// ar_wdt_service, the open slot ships wdt-reset), while the address, password and
	// DHCP behaviour belong to the slot being ACTIVATED. Those two are the same slot in
	// a normal switch and different ones out of a flash-boot, so they are decided apart.
	rebootCmd := stockRebootCmd
	if runningOpen {
		rebootCmd = openRebootCmd
	}

	targetOpen := state.TargetContent == "open"
	targetPassword, targetIP := device.StockPassword, opt.DeviceIP
	doneMsg := "Done - the device is now running the stock firmware."
	if targetOpen {
		targetIP = devconf.OpenIP[product]
		if targetIP == "" && runningOpen {
			// Already on an open slot: both open slots answer at the same fixed address.
			targetIP = connectedIP
		}

		if targetIP == "" {
			return fail(emit, fmt.Errorf("no open-slot IP configured for product %s", product))
		}

		targetPassword = device.OpenPassword
		doneMsg = "Done - the device is now running the MissingLynk open firmware."
	}

	// The open slot serves DHCP; the vendor slot does not. When the activated slot
	// answers at the address we are already connected to (an open slot activated out of
	// a flash-boot), reachability alone cannot tell the old session from the new one, so
	// the reconnect additionally has to see a rebooted uptime.
	if err := rebootAndWait(ctx, opt, client, rebootCmd, targetPassword, targetIP,
		targetOpen, targetIP == connectedIP, emit); err != nil {
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

	client, alreadyOpen, _, err := connect(opt.DeviceIP, opt.OpenIPs)
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

	unit := sdk.Identify()
	if unit == device.UnitUnknown {
		return fail(emit, fmt.Errorf("connected unit could not be identified; refusing to flash"))
	}

	if !whitelist.Allowed(sdk.HardwareVersion, sdk.SoftwareVersion, sdk.ProductVersion) && !opt.AllowUnknownVersion {
		return fail(emit, fmt.Errorf("firmware %s (hardware %s) is not on the validated whitelist; refusing to flash",
			sdk.SoftwareVersion, sdk.HardwareVersion))
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

	// Flashing lands on the open slot, which answers at the device's fixed open IP and serves DHCP.
	openIP := devconf.OpenIP[sdk.ProductVersion]
	if openIP == "" {
		return fail(emit, fmt.Errorf("no open-slot IP configured for product %s", sdk.ProductVersion))
	}
	if err := rebootAndWait(ctx, opt, client, stockRebootCmd, device.OpenPassword, openIP, true, false, emit); err != nil {
		return fail(emit, err)
	}

	emit(Event{Level: LevelDone, Msg: "Done - the device is now running the open firmware."})
	return nil
}

// connect finds the device on whichever slot it is running. The stock slot answers
// at stockIP with the stock password; the open slot answers at one of the open IPs
// with the open password (board.conf gives each device its own IP). Only addresses
// whose SSH port actually answers are dialled, so slots that are not running cost
// one short probe each instead of a full dial timeout. The returned connectedIP is
// the address we actually reached, and alreadyOpen reports whether it is an open
// slot.
func connect(stockIP string, openIPs []string) (client *device.Client, alreadyOpen bool, connectedIP string, err error) {
	var attempts []struct {
		ip       string
		password string
		open     bool
	}
	attempts = append(attempts, struct {
		ip       string
		password string
		open     bool
	}{stockIP, device.StockPassword, false})

	for _, ip := range openIPs {
		attempts = append(attempts, struct {
			ip       string
			password string
			open     bool
		}{ip, device.OpenPassword, true})
	}

	var firstErr error
	for _, attempt := range attempts {
		if !device.Reachable(attempt.ip, 2*time.Second) {
			continue
		}

		cli, dialErr := device.Dial(attempt.ip, "root", attempt.password, 10*time.Second)
		if dialErr == nil {
			return cli, attempt.open, attempt.ip, nil
		}

		if firstErr == nil {
			firstErr = fmt.Errorf("%s: %w", attempt.ip, dialErr)
		}
	}

	if firstErr != nil {
		return nil, false, "", firstErr
	}

	return nil, false, "", fmt.Errorf("no device answered SSH at %s or %v", stockIP, openIPs)
}

// firstReachable returns the first address whose SSH port answers within timeout,
// or "" if none do. The device sits at the stock address on slot A and the open
// address on slot B, so link checks probe both.
func firstReachable(ips []string, timeout time.Duration) string {
	for _, ip := range ips {
		if device.Reachable(ip, timeout) {
			return ip
		}
	}

	return ""
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
		if firstReachable(deviceAddrs(opt), 2*time.Second) != "" {
			emit(Event{Level: LevelWarn, Msg: "no USB gadget interface detected, but the device is reachable; continuing"})
			return nil
		}

		return fail(emit, fmt.Errorf("no device found - is it plugged in over USB and powered on?"))
	}

	candidate := candidates[0]
	emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("Found gadget interface %s (%s)", candidate.Name, candidate.MAC)})

	if firstReachable(deviceAddrs(opt), 2*time.Second) != "" {
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
		if firstReachable(deviceAddrs(opt), 2*time.Second) != "" {
			emit(Event{Level: LevelInfo, Msg: "Device reachable"})
			return nil
		}

		select {
		case <-ctx.Done():
			return fail(emit, ctx.Err())
		case <-time.After(1 * time.Second):
		}
	}

	return fail(emit, fmt.Errorf("device did not become reachable at %s or %v after configuring the link",
		opt.DeviceIP, opt.OpenIPs))
}

// deviceAddrs are the addresses the device may answer on, stock first: the stock
// slot at DeviceIP (.100) and the open slot at any of the OpenIPs. The running
// slot determines which one is live, so link checks probe all candidates.
func deviceAddrs(opt Options) []string {
	addrs := []string{opt.DeviceIP}
	return append(addrs, opt.OpenIPs...)
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

// pushPayload uploads the embedded mlflash (to /tmp) and the image (to stageDir,
// an SD-card mount) over cat streams and returns the remote image path.
func pushPayload(client *device.Client, imagePath, stageDir string, emit Emit) (string, error) {
	if err := pushMlflash(client, emit); err != nil {
		return "", err
	}

	imageFile, err := os.Open(imagePath)
	if err != nil {
		return "", err
	}

	defer imageFile.Close()
	stat, _ := imageFile.Stat()
	emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("Uploading %s (%d MiB) to %s", filepath.Base(imagePath), stat.Size()/(1024*1024), stageDir)})

	remoteImg := path.Join(stageDir, filepath.Base(imagePath))
	if err := client.Push(imageFile, remoteImg, "644"); err != nil {
		return "", fmt.Errorf("uploading image: %w", err)
	}

	return remoteImg, nil
}

// sdCardDir returns the mount path of an inserted SD card on the device (a
// writable FAT/exFAT filesystem on a block device), or "" if none is mounted.
// The flash image is staged there rather than in the tmpfs /tmp, which a
// low-memory unit cannot spare.
func sdCardDir(client *device.Client) (string, error) {
	out, err := client.Run("mount")
	if err != nil {
		return "", fmt.Errorf("listing device mounts: %w", err)
	}

	for _, line := range strings.Split(out, "\n") {
		// e.g. "/dev/mmcblk2 on /tmp/sdcard type exfat (rw,relatime,...)"
		fields := strings.Fields(line)
		if len(fields) < 6 || fields[1] != "on" || fields[3] != "type" {
			continue
		}

		source, mountpoint, fstype, options := fields[0], fields[2], fields[4], fields[5]
		if !strings.HasPrefix(source, "/dev/mmcblk") && !strings.HasPrefix(source, "/dev/sd") {
			continue
		}

		if !isFatFilesystem(fstype) || !strings.HasPrefix(options, "(rw") {
			continue
		}

		return mountpoint, nil
	}

	return "", nil
}

// isFatFilesystem reports whether fstype is a removable-media FAT variant, the
// signature of an SD card (as opposed to the device's ubifs/squashfs partitions).
func isFatFilesystem(fstype string) bool {
	switch fstype {
	case "vfat", "exfat", "msdos", "fat", "fuseblk":
		return true

	default:
		return false
	}
}

// removeRemote best-effort deletes a remote path (the staged image after flashing).
func removeRemote(client *device.Client, remotePath string) {
	_, _ = client.Run("rm -f " + device.ShellQuote(remotePath))
}

// runMlflash runs the on-device flasher with args and relays its output as info
// events, so the user sees mlflash's own per-component messages.
func runMlflash(client *device.Client, emit Emit, args ...string) error {
	cmd := remoteMlflash
	for _, a := range args {
		cmd += " " + device.ShellQuote(a)
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
//
// ip is the address the slot being booted answers on: the stock slot at .100, the
// open slot at the unit's fixed board.conf address (.101 goggle, .102 air). The
// slots live at different addresses, so waiting on the wrong one would never see
// the reboot complete.
//
// verifyUptime is for the one case where the firmware being booted answers at the
// address we are connected to right now (an open slot activated out of a flash-boot):
// there, an SSH answer at ip is not by itself proof of a reboot, so the session that
// answers must also report an uptime shorter than the time since the reboot command
// went out. An unreadable uptime is accepted, so this can only delay a false positive,
// never turn a real reboot into a timeout.
func rebootAndWait(ctx context.Context, opt Options, client *device.Client, rebootCmd, targetPassword, ip string,
	targetServesDHCP, verifyUptime bool, emit Emit) error {
	emit(Event{Level: LevelStep, Msg: "Rebooting into the newly activated firmware"})

	// The reboot command tears the SoC down mid-session, so this SSH call never
	// returns cleanly: it blocks on the dead transport until the host's TCP timeout
	// (up to a minute, as no SSH keepalive is set). Waiting on it would stall the
	// whole reconnect - including the host-IP reattach - for that long, so fire it
	// in the background and move straight to the wait loop. The command is delivered
	// before the SoC resets; the deferred client.Close eventually unblocks the call.
	go func() { _, _ = client.Run(rebootCmd) }()
	issued := time.Now()

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
				rebooted := !verifyUptime || hasRebooted(c, time.Since(issued))
				_ = c.Close()
				if rebooted {
					emit(Event{Level: LevelInfo, Msg: "The device is back up and reachable"})
					return nil
				}

				emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("%s still answers from the pre-reboot session", ip)})
			} else {
				emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("%s answers but SSH is not ready yet", ip)})
			}
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

// hasRebooted reports whether the session on the far end of client came up after the
// reboot command went out, by comparing /proc/uptime with how long ago that was. A
// device that ignored the reboot has been up for its whole pre-reboot session, which
// is longer than sinceReboot; a rebooted one has not. slack absorbs the reboot command's
// own delay and the poll interval. An unreadable or unparseable uptime counts as
// rebooted: this check only exists to catch a device that is still the old session, and
// must never strand a reconnect that has genuinely succeeded.
func hasRebooted(client *device.Client, sinceReboot time.Duration) bool {
	out, err := client.Run("cat /proc/uptime")
	if err != nil {
		return true
	}

	fields := strings.Fields(strings.TrimSpace(out))
	if len(fields) == 0 {
		return true
	}

	uptime, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return true
	}

	const slack = 15 * time.Second
	return time.Duration(uptime*float64(time.Second)) < sinceReboot+slack
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
