package flow

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// The gate must run BEFORE the upload, so the assertion is not just that Flash
// fails but that nothing was pushed.
func TestFlashRejectsAnImageForAnotherDevice(t *testing.T) {
	h := (&harness{}).install(t)
	h.client.on("--slots", slotsJSON, nil).on("df -k", stockDF, nil)

	emit, events := collect()
	err := Flash(context.Background(), Options{ImagePath: writeBundle(t, "P1_SKY")}, emit)
	if err == nil {
		t.Fatal("Flash() = nil error, want a device-mismatch rejection")
	}

	if !strings.Contains(err.Error(), "P1_SKY") || !strings.Contains(err.Error(), "P1_GND_VR04") {
		t.Errorf("Flash() error = %q, want it to name both the image target and the device", err)
	}

	if paths := h.client.pushedPaths(); len(paths) != 0 {
		t.Errorf("uploaded %v; the mismatch must be caught before any upload", paths)
	}

	if h.client.didRun("--flash") {
		t.Error("ran mlflash --flash despite the device mismatch")
	}

	if !strings.Contains(logOf(events), "P1_SKY") {
		t.Error("the mismatch was not reported to the user")
	}
}

// Caught on the host, before the link is even brought up.
func TestFlashRejectsACorruptBundle(t *testing.T) {
	h := (&harness{}).install(t)

	path := writeBundle(t, "P1_GND_VR04")
	corrupt(t, path)

	emit, _ := collect()
	err := Flash(context.Background(), Options{ImagePath: path}, emit)
	if err == nil {
		t.Fatal("Flash() = nil error, want a corruption rejection")
	}

	if !strings.Contains(err.Error(), "re-download") {
		t.Errorf("Flash() error = %q, want it to tell the user to re-download", err)
	}

	if paths := h.client.pushedPaths(); len(paths) != 0 {
		t.Errorf("uploaded %v; a corrupt bundle must be caught before any upload", paths)
	}
}

func TestFlashRefusesAnUnidentifiableUnit(t *testing.T) {
	h := (&harness{}).install(t)
	h.client.sdk.ProductVersion = "SOMETHING_ELSE"

	emit, _ := collect()
	err := Flash(context.Background(), Options{ImagePath: writeBundle(t, "P1_GND_VR04")}, emit)
	if err == nil {
		t.Fatal("Flash() = nil error, want a refusal for an unidentifiable unit")
	}

	if !strings.Contains(err.Error(), "could not be identified") {
		t.Errorf("Flash() error = %q, want the identification refusal", err)
	}

	if len(h.client.pushedPaths()) != 0 {
		t.Error("uploaded to a unit that could not be identified")
	}
}

func TestFlashRefusesFirmwareOffTheWhitelist(t *testing.T) {
	h := (&harness{}).install(t)
	h.client.sdk.SoftwareVersion = "9.9.9.rel"

	emit, _ := collect()
	err := Flash(context.Background(), Options{ImagePath: writeBundle(t, "P1_GND_VR04")}, emit)
	if err == nil {
		t.Fatal("Flash() = nil error, want a whitelist refusal")
	}

	if !strings.Contains(err.Error(), "whitelist") {
		t.Errorf("Flash() error = %q, want the whitelist refusal", err)
	}

	if len(h.client.pushedPaths()) != 0 {
		t.Error("uploaded to a unit whose firmware is not whitelisted")
	}
}

// AllowUnknownVersion bypasses the whitelist only. Whether the bytes match the
// hardware is a separate question from which firmware revisions are validated.
func TestAllowUnknownVersionDoesNotBypassTheBoardGate(t *testing.T) {
	h := (&harness{}).install(t)
	h.client.sdk.SoftwareVersion = "9.9.9.rel"

	emit, _ := collect()
	err := Flash(context.Background(), Options{
		ImagePath:           writeBundle(t, "P1_SKY"),
		AllowUnknownVersion: true,
	}, emit)
	if err == nil {
		t.Fatal("Flash() = nil error, want the board gate to still refuse")
	}

	if !strings.Contains(err.Error(), "P1_SKY") {
		t.Errorf("Flash() error = %q, want the board mismatch, not the whitelist", err)
	}
}

// FlashOnly is the Rule 2 safety valve: written, never flipped.
func TestFlashOnlyWritesButNeverFlips(t *testing.T) {
	h := (&harness{}).install(t)
	path := writeBundle(t, "P1_GND_VR04")
	h.client.
		on("mount", "", nil).
		on("df -k", stockDF, nil).
		on("sha256sum", sha256Of(t, path)+"  /tmp/.test.mlimg.part", nil)

	emit, _ := collect()
	if err := Flash(context.Background(), Options{ImagePath: path, FlashOnly: true}, emit); err != nil {
		t.Fatalf("Flash() = %v, want no error", err)
	}

	if !h.client.didRun("--flash") {
		t.Error("did not run mlflash --flash")
	}

	if h.client.didRun("--flip") {
		t.Error("ran mlflash --flip despite FlashOnly")
	}
}

// Renamed into place only after the transfer verifies, so an interrupted run leaves
// nothing at the final name.
func TestUploadStagesThroughAPartialName(t *testing.T) {
	h := (&harness{}).install(t)
	path := writeBundle(t, "P1_GND_VR04")
	h.client.
		on("mount", "", nil).
		on("df -k", stockDF, nil).
		on("sha256sum", sha256Of(t, path)+"  /tmp/.test.mlimg.part", nil)

	emit, _ := collect()
	if err := Flash(context.Background(), Options{ImagePath: path, FlashOnly: true}, emit); err != nil {
		t.Fatalf("Flash() = %v, want no error", err)
	}

	pushed := h.client.pushedPaths()
	if !contains(pushed, "/tmp/.test.mlimg.part") {
		t.Errorf("pushed %v, want the image streamed to the .part name", pushed)
	}

	if contains(pushed, "/tmp/test.mlimg") {
		t.Errorf("pushed %v, want the final name reached only by rename", pushed)
	}

	if !h.client.didRun("mv '/tmp/.test.mlimg.part' '/tmp/test.mlimg'") {
		t.Errorf("commands %v, want the .part renamed into place", h.client.commands())
	}
}

// A mismatch must stop the run before mlflash writes, and clean up the partial.
func TestUploadRejectsAMismatchedRemoteDigest(t *testing.T) {
	h := (&harness{}).install(t)
	path := writeBundle(t, "P1_GND_VR04")
	h.client.
		on("mount", "", nil).
		on("df -k", stockDF, nil).
		on("sha256sum", strings.Repeat("a", 64)+"  /tmp/.test.mlimg.part", nil)

	emit, _ := collect()
	err := Flash(context.Background(), Options{ImagePath: path}, emit)
	if err == nil {
		t.Fatal("Flash() = nil error, want an upload-digest rejection")
	}

	if !strings.Contains(err.Error(), "corrupted") {
		t.Errorf("Flash() error = %q, want it to name the corrupted transfer", err)
	}

	if h.client.didRun("--flash") {
		t.Error("ran mlflash --flash after a failed upload check")
	}

	if !h.client.didRun("rm -f '/tmp/.test.mlimg.part'") {
		t.Errorf("commands %v, want the partial cleaned up", h.client.commands())
	}
}

// The vendor busybox may ship neither applet. Warn and continue: mlflash still
// verifies every component before writing.
func TestUploadContinuesWhenTheDeviceHasNoDigestTool(t *testing.T) {
	h := (&harness{}).install(t)
	path := writeBundle(t, "P1_GND_VR04")
	h.client.
		on("mount", "", nil).
		on("df -k", stockDF, nil).
		on("sha256sum", "", errors.New("sha256sum: applet not found")).
		on("md5sum", "", errors.New("md5sum: applet not found"))

	emit, events := collect()
	if err := Flash(context.Background(), Options{ImagePath: path, FlashOnly: true}, emit); err != nil {
		t.Fatalf("Flash() = %v, want the flash to continue without a digest tool", err)
	}

	if !strings.Contains(logOf(events), "no digest tool") {
		t.Error("the skipped upload check was not reported to the user")
	}

	if !h.client.didRun("--flash") {
		t.Error("did not run mlflash --flash")
	}
}

// md5sum is the fallback when sha256sum is absent.
func TestUploadFallsBackToMD5(t *testing.T) {
	h := (&harness{}).install(t)
	path := writeBundle(t, "P1_GND_VR04")
	h.client.
		on("mount", "", nil).
		on("df -k", stockDF, nil).
		on("sha256sum", "", errors.New("applet not found")).
		on("md5sum", md5Of(t, path)+"  /tmp/.test.mlimg.part", nil)

	emit, events := collect()
	if err := Flash(context.Background(), Options{ImagePath: path, FlashOnly: true}, emit); err != nil {
		t.Fatalf("Flash() = %v, want no error", err)
	}

	if !strings.Contains(logOf(events), "Upload verified") {
		t.Errorf("log = %q, want the md5 fallback to have verified the upload", logOf(events))
	}
}

// SwitchSlot re-probes before the flip, so the dialog always matches what happens.
func TestSwitchSlotRefusesWhenTheSlotStateChanged(t *testing.T) {
	h := (&harness{}).install(t)
	// The scan offered slot B holding the open firmware; the device now reports the
	// other direction, as it would after something else flipped the slot in between.
	h.client.on("--slots", `{"running":"B","gpt_active":"B","consistent":true,`+
		`"target_slot":"A","target_content":"vendor","target_complete":true}`, nil)

	emit, _ := collect()
	err := SwitchSlot(context.Background(), Options{}, SwitchTarget{Slot: "B", Content: "open"}, emit)
	if err == nil {
		t.Fatal("SwitchSlot() = nil error, want a refusal after the state changed")
	}

	if !strings.Contains(err.Error(), "changed since the scan") {
		t.Errorf("SwitchSlot() error = %q, want it to name the changed state", err)
	}

	if h.client.didRun("--flip") {
		t.Error("flipped the slot despite the state having changed")
	}
}

// An incomplete target is refused whatever the user confirmed.
func TestSwitchSlotRefusesAnIncompleteTarget(t *testing.T) {
	h := (&harness{}).install(t)
	h.client.on("--slots", `{"running":"A","gpt_active":"A","consistent":true,`+
		`"target_slot":"B","target_content":"empty","target_complete":false}`, nil)

	emit, _ := collect()
	err := SwitchSlot(context.Background(), Options{}, SwitchTarget{Slot: "B", Content: "empty"}, emit)
	if err == nil {
		t.Fatal("SwitchSlot() = nil error, want a refusal for an incomplete target")
	}

	if h.client.didRun("--flip") {
		t.Error("flipped to a slot holding no complete image")
	}
}

// Without a context the worst case is (1 + open IPs) x (probe + dial).
func TestConnectAbortsOnCancellation(t *testing.T) {
	h := &harness{}
	dialed := make(chan string, 8)
	h.onDial = func(ctx context.Context, ip string) { dialed <- ip }
	h.install(t)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, _, _, err := connect(ctx, DefaultDeviceIP, []string{"192.168.3.101", "192.168.3.102"})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("connect() = %v, want context.Canceled", err)
	}

	if len(dialed) != 0 {
		t.Errorf("dialled %d addresses after cancellation, want 0", len(dialed))
	}
}

// Cancellation partway through stops the sweep there.
func TestConnectStopsMidSweepOnCancellation(t *testing.T) {
	h := &harness{}
	ctx, cancel := context.WithCancel(context.Background())

	var dialed []string
	h.dialErr = errors.New("no answer")
	h.onDial = func(_ context.Context, ip string) {
		dialed = append(dialed, ip)
		cancel()
	}
	h.install(t)

	_, _, _, err := connect(ctx, DefaultDeviceIP, []string{"192.168.3.101", "192.168.3.102"})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("connect() = %v, want context.Canceled", err)
	}

	if len(dialed) != 1 {
		t.Errorf("dialled %v, want the sweep to stop after the first attempt", dialed)
	}
}

func TestApplyDefaults(t *testing.T) {
	tests := []struct {
		name    string
		opt     Options
		wantErr string
	}{
		{name: "empty takes the defaults", opt: Options{}},
		{name: "valid values pass", opt: Options{DeviceIP: "10.0.0.1", HostCIDR: "10.0.0.2/24"}},
		{name: "bad device IP", opt: Options{DeviceIP: "192.168.3"}, wantErr: "device address"},
		{name: "bad host CIDR", opt: Options{HostCIDR: "192.168.3.222"}, wantErr: "host address"},
		{name: "bad open IP", opt: Options{OpenIPs: []string{"nope"}}, wantErr: "open-slot address"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			opt := tt.opt
			err := opt.applyDefaults()
			switch {
			case tt.wantErr == "" && err != nil:
				t.Fatalf("applyDefaults() = %v, want no error", err)

			case tt.wantErr != "" && err == nil:
				t.Fatalf("applyDefaults() = nil, want an error naming %q", tt.wantErr)

			case tt.wantErr != "" && !strings.Contains(err.Error(), tt.wantErr):
				t.Fatalf("applyDefaults() = %q, want it to name %q", err, tt.wantErr)
			}

			if err == nil && opt.HostCIDR == "" {
				t.Error("applyDefaults() left HostCIDR empty")
			}
		})
	}
}

// Rejected before anything touches the device or the host network.
func TestFlashRejectsAMalformedAddress(t *testing.T) {
	h := (&harness{}).install(t)

	emit, _ := collect()
	err := Flash(context.Background(), Options{
		ImagePath: writeBundle(t, "P1_GND_VR04"),
		DeviceIP:  "not-an-ip",
	}, emit)
	if err == nil {
		t.Fatal("Flash() = nil error, want a rejection for a malformed address")
	}

	if len(h.backend.assigned) != 0 {
		t.Error("configured the host network despite the malformed address")
	}
}

// The open slot carries no sdk_version.json.
func TestDetectReportsAnAlreadyOpenUnit(t *testing.T) {
	h := &harness{reachableIPs: map[string]bool{"192.168.3.101": true}}
	h.install(t)
	h.client.on("/proc/device-tree/model", "Artosyn Proxima-9311 (test)\x00", nil).
		on("--slots", slotsJSON, nil)

	emit, _ := collect()
	info, err := Detect(context.Background(), Options{OpenIPs: []string{"192.168.3.101"}}, emit)
	if err != nil {
		t.Fatalf("Detect() = %v, want no error", err)
	}

	if !info.AlreadyOpen {
		t.Error("AlreadyOpen = false, want true for a unit answering on the open address")
	}

	if info.Flashable {
		t.Error("Flashable = true, want false for a unit already running the open firmware")
	}

	if info.Name != "Artosyn Proxima-9311 (test)" {
		t.Errorf("Name = %q, want the device-tree model with the NUL trimmed", info.Name)
	}
}

func contains(values []string, want string) bool {
	for _, v := range values {
		if v == want {
			return true
		}
	}

	return false
}

// md5Of is the digest a device-side md5sum would report for path.
func md5Of(t *testing.T, path string) string {
	t.Helper()

	digest, err := localDigest(path, digestApplets[1].local())
	if err != nil {
		t.Fatalf("hashing %s: %v", path, err)
	}

	return digest
}

// md5Of indexes the table, so its order is load-bearing.
func TestDigestAppletOrder(t *testing.T) {
	if len(digestApplets) != 2 || digestApplets[0].name != "sha256sum" || digestApplets[1].name != "md5sum" {
		t.Fatalf("digestApplets = %v, want sha256sum then md5sum", digestApplets)
	}
}
