package flow

import (
	"context"
	"strings"
	"testing"
)

// A scan that finds nothing must say what the host did see. Without it the log reads
// the same whether the device is unplugged or plugged in with no driver bound, which
// are opposite problems.
func TestDetectReportsTheHostViewWhenNothingIsFound(t *testing.T) {
	h := (&harness{backend: &fakeBackend{diagnosis: []string{
		"Windows reports 1 network adapter(s):",
		`  "Ethernet" - Intel(R) I219-V [Up]`,
	}}}).install(t)
	h.reachableIPs = map[string]bool{}

	emit, events := collect()
	if _, err := Detect(context.Background(), Options{}, emit); err == nil {
		t.Fatal("Detect() with no candidates = nil error, want a failure")
	}

	log := logOf(events)
	for _, want := range []string{"Intel(R) I219-V", "no device found"} {
		if !strings.Contains(log, want) {
			t.Errorf("Detect() log = %q, want it to contain %q", log, want)
		}
	}
}

// A device that answers on its own is not a failure, so the host report (which exists
// to explain a failure) has no place in that log.
func TestDetectSkipsTheHostViewWhenTheDeviceAnswers(t *testing.T) {
	(&harness{backend: &fakeBackend{diagnosis: []string{"host report"}}}).install(t)

	emit, events := collect()
	if _, err := Detect(context.Background(), Options{}, emit); err != nil {
		t.Fatalf("Detect() = %v, want the reachable device to be accepted", err)
	}

	if log := logOf(events); strings.Contains(log, "host report") {
		t.Errorf("Detect() log = %q, want no host report when the device was reached", log)
	}
}
