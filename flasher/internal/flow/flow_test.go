package flow

import (
	"testing"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/mlflash"
)

func TestIsSwitchTarget(t *testing.T) {
	tests := []struct {
		name  string
		state mlflash.SlotReport
		want  bool
	}{
		{
			name:  "stock running, open on the other slot",
			state: mlflash.SlotReport{Running: "A", GptActive: "A", Consistent: true, TargetSlot: "B", TargetContent: "open", TargetComplete: true},
			want:  true,
		},
		{
			name:  "open running, stock on the other slot",
			state: mlflash.SlotReport{Running: "B", GptActive: "B", Consistent: true, TargetSlot: "A", TargetContent: "vendor", TargetComplete: true},
			want:  true,
		},
		{
			name:  "flash-boot: running B while A is active",
			state: mlflash.SlotReport{Running: "B", GptActive: "A", Consistent: false, TargetSlot: "B", TargetContent: "open", TargetComplete: true},
			want:  true,
		},
		{
			name:  "target erased",
			state: mlflash.SlotReport{Running: "A", GptActive: "A", Consistent: true, TargetSlot: "B", TargetContent: "empty"},
			want:  false,
		},
		{
			name:  "target recognized but incomplete",
			state: mlflash.SlotReport{Running: "A", GptActive: "A", Consistent: true, TargetSlot: "B", TargetContent: "open", TargetComplete: false},
			want:  false,
		},
		{
			name:  "no target slot (gpt0 unreadable)",
			state: mlflash.SlotReport{Running: "A", GptActive: "unknown", TargetContent: "open", TargetComplete: true},
			want:  false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isSwitchTarget(&tt.state); got != tt.want {
				t.Fatalf("isSwitchTarget() = %v, want %v", got, tt.want)
			}
		})
	}
}
