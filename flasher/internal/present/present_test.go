package present

import (
	"errors"
	"strings"
	"testing"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/flow"
)

// readyGoggle is a whitelisted unit on slot A with a complete open image on B.
func readyGoggle() *flow.DeviceInfo {
	return &flow.DeviceInfo{
		Unit:          "P1_GND",
		Product:       "P1_GND_VR04",
		Firmware:      "1.0.44.rel",
		Hardware:      "v2.0",
		Verdict:       flow.VerdictReady,
		ActiveSlot:    "A",
		RunningSlot:   "A",
		TargetSlot:    "B",
		TargetContent: flow.ContentOpen,
		Switchable:    true,
		Proof:         flow.BootProof{Present: true, Boots: 3, DigestsRecorded: true, Verified: true},
	}
}

func TestRenderTitle(t *testing.T) {
	tests := []struct {
		name  string
		state State
		want  string
	}{
		{"before the first scan", State{}, scanningTitle},
		{"while scanning", State{Scanning: true, Info: readyGoggle()}, scanningTitle},
		{"no device", State{ScanErr: errors.New("nothing answered")}, noDeviceTitle},
		{
			"a stock unit carries its versions",
			State{Info: readyGoggle()},
			"P1_GND_VR04   (firmware 1.0.44.rel, hardware v2.0)",
		},
		{
			"an open unit is named by its device tree",
			State{Info: &flow.DeviceInfo{Verdict: flow.VerdictAlreadyOpen, Name: "BetaFPV VR04 goggle"}},
			"BetaFPV VR04 goggle",
		},
		{
			"an unnamed open unit still has a heading",
			State{Info: &flow.DeviceInfo{Verdict: flow.VerdictAlreadyOpen}},
			unnamedDevice,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := Render(tt.state).Title; got != tt.want {
				t.Errorf("title = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestRenderStatusReportsTheVerdict(t *testing.T) {
	tests := []struct {
		name      string
		info      *flow.DeviceInfo
		want      string
		isWarning bool
	}{
		{
			name: "ready", info: &flow.DeviceInfo{Verdict: flow.VerdictReady},
			want: "Ready to flash.",
		},
		{
			name: "unidentified",
			info: &flow.DeviceInfo{Verdict: flow.VerdictUnidentified},
			want: "could not be identified", isWarning: true,
		},
		{
			name: "off the whitelist",
			info: &flow.DeviceInfo{Verdict: flow.VerdictNotWhitelisted, Firmware: "1.0.99.rel", Hardware: "v3.0"},
			want: "Firmware 1.0.99.rel (hardware v3.0) is not on the validated list", isWarning: true,
		},
		{
			name: "already open",
			info: &flow.DeviceInfo{Verdict: flow.VerdictAlreadyOpen},
			want: "already running the MissingLynk firmware",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			view := Render(State{Info: tt.info})
			if !strings.Contains(view.Status, tt.want) {
				t.Errorf("status = %q, want it to contain %q", view.Status, tt.want)
			}

			if view.IsStatusWarning != tt.isWarning {
				t.Errorf("IsStatusWarning = %v, want %v", view.IsStatusWarning, tt.isWarning)
			}
		})
	}
}

// The button rules: what a phase in flight disables, and what an unflashable unit
// never enables in the first place.
func TestRenderEnablesActions(t *testing.T) {
	ready := State{Info: readyGoggle(), Image: "/tmp/test.mlimg"}

	tests := []struct {
		name                                    string
		state                                   State
		rescan, choose, flash, switchTo, isBusy bool
	}{
		{"ready with an image", ready, true, true, true, true, false},
		{"ready without an image", State{Info: readyGoggle()}, true, true, false, true, false},
		{
			"flashing", State{Info: readyGoggle(), Image: "/tmp/test.mlimg", Flashing: true},
			false, false, false, false, true,
		},
		{
			"switching", State{Info: readyGoggle(), Image: "/tmp/test.mlimg", Switching: true},
			false, false, false, false, true,
		},
		{"scanning", State{Scanning: true}, false, false, false, false, true},
		{"no device", State{ScanErr: errors.New("nothing answered")}, true, false, false, false, false},
		{
			"already open: no flash, but a switch back",
			State{Info: &flow.DeviceInfo{
				Verdict: flow.VerdictAlreadyOpen, ActiveSlot: "B", RunningSlot: "B",
				TargetSlot: "A", TargetContent: flow.ContentVendor, Switchable: true,
			}},
			true, false, false, true, false,
		},
		{
			"off the whitelist: nothing but a re-scan",
			State{Info: &flow.DeviceInfo{Verdict: flow.VerdictNotWhitelisted}, Image: "/tmp/test.mlimg"},
			true, false, false, false, false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			view := Render(tt.state)
			for _, check := range []struct {
				what      string
				got, want bool
			}{
				{"rescan", view.RescanEnabled, tt.rescan},
				{"choose", view.ChooseEnabled, tt.choose},
				{"flash", view.FlashEnabled, tt.flash},
				{"switch", view.SwitchEnabled, tt.switchTo},
				{"busy", view.Busy, tt.isBusy},
			} {
				if check.got != check.want {
					t.Errorf("%s = %v, want %v", check.what, check.got, check.want)
				}
			}
		})
	}
}

func TestRenderSwitchLabelNamesTheTargetSlot(t *testing.T) {
	if got := Render(State{Info: readyGoggle()}).SwitchLabel; got != "Switch to slot B" {
		t.Errorf("label = %q, want the target slot named", got)
	}

	if got := Render(State{}).SwitchLabel; got != switchLabel {
		t.Errorf("label with no device = %q, want %q", got, switchLabel)
	}
}

// The card's switch line names which slot is active, which one a switch activates,
// and what that slot holds.
func TestSwitchDetailNamesBothSlots(t *testing.T) {
	tests := []struct {
		name string
		info *flow.DeviceInfo
		want string
	}{
		{
			name: "stock running, open target",
			info: &flow.DeviceInfo{
				Verdict: flow.VerdictReady, ActiveSlot: "A", RunningSlot: "A",
				TargetSlot: "B", TargetContent: flow.ContentOpen, Switchable: true,
				Proof: flow.BootProof{Present: true, Boots: 2, DigestsRecorded: true, Verified: true},
			},
			want: "Slot A is active; slot B holds the MissingLynk open firmware and can be switched to. " +
				"The target slot booted cleanly 2 times and its bytes still verify.",
		},
		{
			name: "open running, stock target",
			info: &flow.DeviceInfo{
				Verdict: flow.VerdictAlreadyOpen, ActiveSlot: "B", RunningSlot: "B",
				TargetSlot: "A", TargetContent: flow.ContentVendor, Switchable: true,
			},
			want: "Slot B is active; slot A holds the stock firmware and can be switched to.",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := switchDetail(tt.info); got != tt.want {
				t.Errorf("switch detail = %q, want %q", got, tt.want)
			}
		})
	}
}

// The switch dialog must name the direction-specific risk. Activating the open slot
// warns that it is not re-verified; activating the stock slot says the opposite.
func TestSwitchDialogWarnsPerDirection(t *testing.T) {
	open := Render(State{Info: readyGoggle()}).SwitchDialog
	if open.Title != "Switch to slot B?" {
		t.Errorf("title = %q, want the target slot named", open.Title)
	}

	if !strings.Contains(open.Body, "WITHOUT rewriting or re-verifying it") {
		t.Errorf("the open-slot dialog does not warn about re-verification:\n%s", open.Body)
	}

	vendor := readyGoggle()
	vendor.TargetSlot = "A"
	vendor.TargetContent = flow.ContentVendor
	vendor.ActiveSlot = "B"
	vendor.RunningSlot = "B"
	body := Render(State{Info: vendor}).SwitchDialog.Body
	if !strings.Contains(body, "low-risk direction") {
		t.Errorf("the stock-slot dialog does not name the low-risk direction:\n%s", body)
	}

	if strings.Contains(body, "WITHOUT rewriting") {
		t.Errorf("the stock-slot dialog carries the open-slot warning:\n%s", body)
	}
}

// Out of a flash-boot the firmware being activated is the one already running, and
// both the card and the dialog have to say so, because the offered direction
// otherwise looks inverted.
func TestFlashBootIsCalledOut(t *testing.T) {
	info := readyGoggle()
	info.RunningSlot = "B"
	info.ActiveSlot = "A"
	info.TargetSlot = "B"

	if !IsFlashBoot(info) {
		t.Fatal("a boot running a slot other than the active one is a flash-boot")
	}

	view := Render(State{Info: info})
	if !strings.Contains(view.Status, "as after a flash-boot") {
		t.Errorf("the card does not name the flash-boot:\n%s", view.Status)
	}

	if !strings.Contains(view.SwitchDialog.Body, "does not exercise slot B's own bootloader") {
		t.Errorf("the dialog does not name what the reboot still exercises:\n%s", view.SwitchDialog.Body)
	}
}

// The four boot-proof outcomes are distinct and must not be collapsed: only the
// last describes bytes that actually changed.
func TestProofSentencePerOutcome(t *testing.T) {
	tests := []struct {
		name  string
		proof flow.BootProof
		want  string
	}{
		{"no record", flow.BootProof{}, "no install record for this device"},
		{
			"proven", flow.BootProof{Present: true, Boots: 1, DigestsRecorded: true, Verified: true},
			"booted cleanly once and its bytes still verify",
		},
		{
			"never booted", flow.BootProof{Present: true, DigestsRecorded: true},
			"never booted successfully; it is unproven",
		},
		{
			"installed elsewhere", flow.BootProof{Present: true, Boots: 4},
			"no recorded digests to verify its contents against",
		},
		{
			"digests differ", flow.BootProof{Present: true, Boots: 4, DigestsRecorded: true},
			"no longer match what is on it",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			info := readyGoggle()
			info.Proof = tt.proof
			if got := proofSentence(info); !strings.Contains(got, tt.want) {
				t.Errorf("proof = %q, want it to contain %q", got, tt.want)
			}
		})
	}
}

// A stock target is the untouched factory install, so it carries no boot proof.
func TestProofSentenceIsOnlyForTheOpenSlot(t *testing.T) {
	info := readyGoggle()
	info.TargetContent = flow.ContentVendor
	if got := proofSentence(info); got != "" {
		t.Errorf("proof for a stock target = %q, want none", got)
	}
}

// A unit with no switch on offer shows the verdict alone, on one line.
func TestStatusHasNoSwitchLineWithoutASwitch(t *testing.T) {
	info := readyGoggle()
	info.Switchable = false
	status := Render(State{Info: info}).Status
	if strings.Contains(status, "\n") {
		t.Errorf("status = %q, want a single line", status)
	}
}

func TestCompletionMessages(t *testing.T) {
	if body := FlashDone(true).Body; !strings.Contains(body, "still") {
		t.Errorf("the flash-only message does not say the device stayed put: %q", body)
	}

	if body := FlashDone(false).Body; !strings.Contains(body, "now running") {
		t.Errorf("the flash-and-switch message does not report the new firmware: %q", body)
	}

	if body := SwitchDone("A").Body; !strings.Contains(body, "slot A") {
		t.Errorf("the switch message does not name the slot: %q", body)
	}
}
