package flow

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/mlflash"
)

// Every way a device can be in a state that forbids a flash, and the one way it can
// be in a state that permits one. classify names a single blocker, so the ordering
// cases (several wrong at once) assert which one wins.
func TestClassifyPicksTheBlocker(t *testing.T) {
	tests := []struct {
		name   string
		report Preflight
		want   Blocker
	}{
		{
			name: "on slot A, agreeing, every target resolved",
			report: Preflight{Running: "A", Active: "A", Consistent: true, FlashSlot: "B",
				TargetsResolved: true},
			want: BlockerNone,
		},
		{
			name: "booted on slot B, where a flash would write slot A",
			report: Preflight{Running: "B", Active: "B", Consistent: true, FlashSlot: "A",
				TargetsResolved: true},
			want: BlockerNotOnSlotA,
		},
		{
			name: "running a slot that is not the active one",
			report: Preflight{Running: "A", Active: "B", Consistent: false, FlashSlot: "B",
				TargetsResolved: true},
			want: BlockerFlashBoot,
		},
		{
			name:   "the running slot could not be read",
			report: Preflight{Running: "unknown", Active: "A", FlashSlot: "unknown"},
			want:   BlockerSlotUnknown,
		},
		{
			name:   "the GPT active bit could not be read",
			report: Preflight{Running: "A", Active: "unknown", FlashSlot: "B"},
			want:   BlockerSlotUnknown,
		},
		{
			name: "a partition of the flash slot is unusable",
			report: Preflight{Running: "A", Active: "A", Consistent: true, FlashSlot: "B",
				TargetsResolved: false},
			want: BlockerTargetUnfit,
		},
		{
			// An unreadable slot state hides everything under it: there is no point naming
			// a partition layout when the slot it belongs to is a guess.
			name: "an unknown slot outranks an unfit target",
			report: Preflight{Running: "unknown", Active: "unknown", TargetsResolved: false,
				FlashSlot: "unknown"},
			want: BlockerSlotUnknown,
		},
		{
			// The user's next step is the reboot, not the slot switch that would follow it.
			name: "a flash-boot outranks running the wrong slot",
			report: Preflight{Running: "B", Active: "A", Consistent: false, FlashSlot: "A",
				TargetsResolved: true},
			want: BlockerFlashBoot,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tt.report.classify()
			if tt.report.Blocker != tt.want {
				t.Errorf("Blocker = %v, want %v", tt.report.Blocker, tt.want)
			}

			if open := tt.report.IsGateOpen(); open != (tt.want == BlockerNone) {
				t.Errorf("IsGateOpen() = %v for blocker %v", open, tt.report.Blocker)
			}
		})
	}
}

// The gate fails closed. A report nobody filled in and a report that was never
// fetched must both refuse, because BlockerNone is the only value that means the
// device answered and answered well.
func TestGateFailsClosed(t *testing.T) {
	var zero Preflight
	if zero.Blocker != BlockerUnprobed {
		t.Errorf("the zero Preflight has blocker %v, want BlockerUnprobed", zero.Blocker)
	}

	if zero.IsGateOpen() {
		t.Error("an unfilled Preflight opened the gate")
	}

	var missing *Preflight
	if missing.IsGateOpen() {
		t.Error("a nil Preflight opened the gate")
	}

	if (&DeviceInfo{Verdict: VerdictReady}).IsFlashable() {
		t.Error("a unit whose gate was never probed reported itself flashable")
	}
}

// The refusal has to name the partitions, or the user is told their layout is wrong
// with no way to see which part of it.
func TestReasonNamesTheUnfitPartitions(t *testing.T) {
	report := Preflight{
		Running: "A", Active: "A", Consistent: true, FlashSlot: "B",
		Targets: []PreflightTarget{
			{Name: "kernel1", Status: mlflash.StatusOK, Mtd: 14, Bytes: 6291456},
			{Name: "dtb1", Status: mlflash.StatusMissing, Mtd: -1},
			{Name: "userapp1", Status: mlflash.StatusSibling, Mtd: 17, Bytes: 47185920},
		},
		TargetsResolved: false,
	}
	report.classify()

	reason := report.Reason()
	for _, want := range []string{"dtb1", "missing", "userapp1"} {
		if !strings.Contains(reason, want) {
			t.Errorf("Reason() = %q, want it to mention %q", reason, want)
		}
	}

	if strings.Contains(reason, "kernel1") {
		t.Errorf("Reason() = %q, want it to name only the partitions that failed", reason)
	}
}

// Detect must report the gate, not just the identity: a whitelisted unit on the
// wrong slot is not flashable.
func TestDetectShutsTheGateOnSlotB(t *testing.T) {
	h := (&harness{}).install(t)
	h.client.on("--preflight", preflightOnSlotB, nil).on("--slots", slotsJSON, nil)

	info, err := Detect(context.Background(), Options{}, collectEmit())
	if err != nil {
		t.Fatalf("Detect() = %v, want no error", err)
	}

	if info.Verdict != VerdictReady {
		t.Errorf("Verdict = %v, want VerdictReady: the unit itself is fine", info.Verdict)
	}

	if info.IsFlashable() {
		t.Error("a unit running slot B reported itself flashable")
	}

	if info.FlashBlocker() != BlockerNotOnSlotA {
		t.Errorf("FlashBlocker() = %v, want BlockerNotOnSlotA", info.FlashBlocker())
	}
}

// The gate is the reason a flash stops, and it stops before the image is uploaded.
func TestFlashRefusesFromSlotB(t *testing.T) {
	h := (&harness{}).install(t)
	h.client.on("--preflight", preflightOnSlotB, nil).on("df -k", stockDF, nil)

	emit, events := collect()
	err := Flash(context.Background(), Options{ImagePath: writeBundle(t, "P1_GND_VR04")}, emit)
	if err == nil {
		t.Fatal("Flash() = nil error, want a refusal from slot B")
	}

	if !strings.Contains(err.Error(), "running slot B") {
		t.Errorf("Flash() error = %q, want it to name the slot the device is on", err)
	}

	if h.client.didRun("--flash") || h.client.didRun("--dry-run") {
		t.Errorf("commands %v, want the run stopped at the gate", h.client.commands())
	}

	if contains(h.client.pushedPaths(), "/tmp/test.mlimg") {
		t.Errorf("pushed %v, want the image never uploaded", h.client.pushedPaths())
	}

	if !strings.Contains(logOf(events), "running slot B") {
		t.Error("the user was not told which slot the device is on")
	}
}

// A device that came back from the scan on slot A but was switched before the click
// must be caught by the re-check, not by mlflash after a full upload.
func TestFlashRefusesAFlashBoot(t *testing.T) {
	h := (&harness{}).install(t)
	h.client.on("--preflight", mustReport(mlflash.PreflightReport{
		Running: "A", GptActive: "B", Consistent: false, FlashSlot: "B",
		Targets: slotBTargets(), TargetsResolved: true,
	}), nil).on("df -k", stockDF, nil)

	emit, _ := collect()
	err := Flash(context.Background(), Options{ImagePath: writeBundle(t, "P1_GND_VR04")}, emit)
	if err == nil {
		t.Fatal("Flash() = nil error, want a refusal during a flash-boot")
	}

	if !strings.Contains(err.Error(), "flash-boot") {
		t.Errorf("Flash() error = %q, want it to name the flash-boot", err)
	}

	if h.client.didRun("--flash") {
		t.Error("wrote a slot while the running and active slots disagreed")
	}
}

// --dry-run is the image half of the gate: it must run, and it must run before the
// write, so a blocker it finds still leaves the device untouched.
func TestFlashDryRunsBeforeWriting(t *testing.T) {
	h := (&harness{}).install(t)
	h.client.on("df -k", stockDF, nil)

	emit, _ := collect()
	if err := Flash(context.Background(), Options{ImagePath: writeBundle(t, "P1_GND_VR04"),
		FlashOnly: true}, emit); err != nil {
		t.Fatalf("Flash() = %v, want no error", err)
	}

	dryRun, flash := -1, -1
	for i, cmd := range h.client.commands() {
		if strings.Contains(cmd, "--dry-run") && dryRun < 0 {
			dryRun = i
		}

		if strings.Contains(cmd, "--flash") && flash < 0 {
			flash = i
		}
	}

	if dryRun < 0 {
		t.Fatalf("commands %v, want a --dry-run before the write", h.client.commands())
	}

	if flash < 0 || dryRun > flash {
		t.Errorf("--dry-run at %d, --flash at %d; want the dry run first", dryRun, flash)
	}
}

// A dry run that finds blockers stops the flash, whatever the host already checked.
func TestFlashStopsWhenTheDryRunFails(t *testing.T) {
	h := (&harness{}).install(t)
	h.client.on("df -k", stockDF, nil).
		on("--dry-run", "=> dry-run found blockers (no writes performed)",
			errors.New("exit status 1"))

	emit, _ := collect()
	err := Flash(context.Background(), Options{ImagePath: writeBundle(t, "P1_GND_VR04")}, emit)
	if err == nil {
		t.Fatal("Flash() = nil error, want the dry run to stop the flash")
	}

	if h.client.didRun("--flash") {
		t.Error("wrote a slot after the dry run found blockers")
	}
}

// collectEmit is a discarding Emit, for tests that assert on the returned info
// rather than on what the user saw.
func collectEmit() Emit {
	emit, _ := collect()
	return emit
}

// The gate and the slot probe both need mlflash on the device, and a scan runs both.
// The upload is a megabyte over a USB gadget link, so it must happen once.
func TestScanUploadsMlflashOnce(t *testing.T) {
	h := (&harness{}).install(t)
	h.client.on("--slots", slotsJSON, nil)

	emit, events := collect()
	if _, err := Detect(context.Background(), Options{}, emit); err != nil {
		t.Fatalf("Detect() = %v, want no error", err)
	}

	if got := strings.Count(logOf(events), "Uploading mlflash"); got != 1 {
		t.Errorf("uploaded mlflash %d times during one scan, want 1", got)
	}

	if !h.client.didRun("--preflight") || !h.client.didRun("--slots") {
		t.Errorf("commands %v, want both reports run off that one upload", h.client.commands())
	}
}

// Running slot B, the only report in hand describes slot B: nothing has looked inside
// the slot a flash would write. What that slot holds is an assumption, and the refusal
// has to say so, because the switch line right below it does check and can report the
// opposite.
func TestTheRefusalMarksTheFallbackSlotAsAnAssumption(t *testing.T) {
	report := Preflight{Running: "B", Active: "B", Consistent: true, FlashSlot: "A",
		TargetsResolved: true}
	report.classify()

	reason := strings.ToLower(report.Reason())
	for _, claim := range []string{"stock", "vendor", "factory", "untouched", "recognized"} {
		if strings.Contains(reason, claim) && !strings.Contains(reason, "assume") {
			t.Errorf("Reason() states %q about a slot nothing probed, without marking it an "+
				"assumption:\n%s", claim, reason)
		}
	}

	if !strings.Contains(reason, "slot a") || !strings.Contains(reason, "running slot b") {
		t.Errorf("Reason() = %q, want it to name both slots", reason)
	}
}
