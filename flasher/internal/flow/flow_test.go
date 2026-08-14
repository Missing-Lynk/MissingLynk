package flow

import "testing"

func TestBootCount(t *testing.T) {
	tests := []struct {
		name  string
		boots int
		want  string
	}{
		{name: "once", boots: 1, want: "once"},
		{name: "many", boots: 7, want: "7 times"},
		{name: "zero", boots: 0, want: "0 times"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := bootCount(tt.boots)
			if got != tt.want {
				t.Fatalf("bootCount(%d) = %q, want %q", tt.boots, got, tt.want)
			}
		})
	}
}

func TestProvenSummary(t *testing.T) {
	tests := []struct {
		name string
		rec  recordReport
		want string
	}{
		{
			name: "absent",
			rec:  recordReport{},
			want: "This tool has no install record for this device, so it cannot confirm the target slot has ever booted.",
		},
		{
			name: "verified",
			rec:  recordReport{Present: true, Boots: 2, DigestsRecorded: true, Verified: true},
			want: "The target slot booted cleanly 2 times and its bytes still verify.",
		},
		{
			name: "recorded but never booted",
			rec:  recordReport{Present: true, Boots: 0, DigestsRecorded: true, Verified: false},
			want: "The target slot has an install record but has never booted successfully; it is unproven.",
		},
		{
			name: "booted without digests",
			rec:  recordReport{Present: true, Boots: 1, DigestsRecorded: false, Verified: false},
			want: "The target slot booted cleanly once, but it was not installed by this tool, " +
				"so there are no recorded digests to verify its contents against.",
		},
		{
			name: "digest mismatch",
			rec:  recordReport{Present: true, Boots: 1, DigestsRecorded: true, Verified: false},
			want: "The target slot's recorded bytes no longer match what is on it (re-flashed outside this tool, or degraded); treat it as unproven.",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := provenSummary(tt.rec)
			if got != tt.want {
				t.Fatalf("provenSummary(...) = %q, want %q", got, tt.want)
			}
		})
	}
}

// The switch target follows the GPT-active slot, so a flash-boot (running != active)
// must stay switchable: that is the flip step of flash -> flashboot -> flip.
func TestIsSwitchTarget(t *testing.T) {
	tests := []struct {
		name  string
		state slotState
		want  bool
	}{
		{
			name:  "stock running, open on the other slot",
			state: slotState{Running: "A", GptActive: "A", Consistent: true, TargetSlot: "B", TargetContent: "open", TargetComplete: true},
			want:  true,
		},
		{
			name:  "open running, stock on the other slot",
			state: slotState{Running: "B", GptActive: "B", Consistent: true, TargetSlot: "A", TargetContent: "vendor", TargetComplete: true},
			want:  true,
		},
		{
			name:  "flash-boot: running B while A is active",
			state: slotState{Running: "B", GptActive: "A", Consistent: false, TargetSlot: "B", TargetContent: "open", TargetComplete: true},
			want:  true,
		},
		{
			name:  "target erased",
			state: slotState{Running: "A", GptActive: "A", Consistent: true, TargetSlot: "B", TargetContent: "empty"},
			want:  false,
		},
		{
			name:  "target recognized but incomplete",
			state: slotState{Running: "A", GptActive: "A", Consistent: true, TargetSlot: "B", TargetContent: "open", TargetComplete: false},
			want:  false,
		},
		{
			name:  "no target slot (gpt0 unreadable)",
			state: slotState{Running: "A", GptActive: "unknown", TargetContent: "open", TargetComplete: true},
			want:  false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.state.isSwitchTarget(); got != tt.want {
				t.Fatalf("isSwitchTarget() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestSwitchDetail(t *testing.T) {
	tests := []struct {
		name string
		info DeviceInfo
		want string
	}{
		{
			name: "stock running, open target",
			info: DeviceInfo{ActiveSlot: "A", RunningSlot: "A", TargetSlot: "B", TargetContent: "open"},
			want: "Slot A is active; slot B holds the MissingLynk open firmware and can be switched to.",
		},
		{
			name: "open running, stock target",
			info: DeviceInfo{ActiveSlot: "B", RunningSlot: "B", TargetSlot: "A", TargetContent: "vendor"},
			want: "Slot B is active; slot A holds the stock firmware and can be switched to.",
		},
		{
			name: "flash-boot names the state",
			info: DeviceInfo{ActiveSlot: "A", RunningSlot: "B", TargetSlot: "B", TargetContent: "open"},
			want: "This boot is running slot B while slot A is still the active one (as after a flash-boot); " +
				"switching activates slot B, which holds the MissingLynk open firmware.",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			info := tt.info
			if got := switchDetail(&info); got != tt.want {
				t.Fatalf("switchDetail(...) = %q, want %q", got, tt.want)
			}
		})
	}
}
