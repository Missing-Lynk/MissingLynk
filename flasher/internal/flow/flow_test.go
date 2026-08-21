package flow

import "testing"

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
