package flow

import (
	"archive/tar"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/device"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/manifest"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/mlflash"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/netcfg"
)

// fakeClient stands in for a connected device. Commands match by substring in
// registration order; anything unmatched returns the zero reply.
type fakeClient struct {
	mu sync.Mutex

	sdk    *device.SDKVersion
	sdkErr error

	handlers []handler

	// What reached the device, and in what order.
	pushed map[string][]byte
	ran    []string

	closed bool
}

type handler struct {
	match string
	out   string
	err   error
}

// fakeBackend reports one gadget interface and never touches the host network.
type fakeBackend struct {
	candidates []netcfg.Candidate
	assigned   []string
}

// harness swaps the package's device and network entry points for one test. The zero
// value reaches a default fakeClient at the stock address.
type harness struct {
	client *fakeClient

	// reachableIPs are the addresses that answer; nil means every address answers.
	reachableIPs map[string]bool

	// dialErr, when set, fails every dial.
	dialErr error

	// onDial is called before each dial, for tests that need to observe or block.
	onDial func(ctx context.Context, ip string)

	backend *fakeBackend
}

func newFakeClient() *fakeClient {
	return &fakeClient{
		sdk: &device.SDKVersion{
			HardwareVersion: "v2.0",
			SoftwareVersion: "1.0.44.rel",
			ProductVersion:  "P1_GND_VR04",
		},
		pushed: map[string][]byte{},
	}
}

// on registers a reply for any command containing match. First match wins.
func (f *fakeClient) on(match, out string, err error) *fakeClient {
	f.handlers = append(f.handlers, handler{match: match, out: out, err: err})
	return f
}

func (f *fakeClient) Run(cmd string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ran = append(f.ran, cmd)

	for _, h := range f.handlers {
		if strings.Contains(cmd, h.match) {
			return h.out, h.err
		}
	}

	return defaultReply(cmd), nil
}

// defaultReply answers the commands every flow runs on the way to what a test is
// actually about, so only the command under test needs registering. A test that cares
// registers its own handler, which wins: handlers are consulted first.
func defaultReply(cmd string) string {
	if strings.Contains(cmd, "--preflight") {
		return preflightJSON
	}

	return ""
}

func (f *fakeClient) RunStream(cmd string, onLine func(string)) error {
	out, err := f.Run(cmd)
	for _, line := range strings.Split(out, "\n") {
		if line != "" {
			onLine(line)
		}
	}

	return err
}

func (f *fakeClient) Push(content io.Reader, remotePath, mode string) error {
	body, err := io.ReadAll(content)
	if err != nil {
		return err
	}

	f.mu.Lock()
	defer f.mu.Unlock()
	f.pushed[remotePath] = body

	return nil
}

func (f *fakeClient) ReadSDKVersion() (*device.SDKVersion, error) {
	if f.sdkErr != nil {
		return nil, f.sdkErr
	}

	return f.sdk, nil
}

func (f *fakeClient) Close() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.closed = true

	return nil
}

// commands returns every command run so far.
func (f *fakeClient) commands() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.ran...)
}

// didRun reports whether any command so far contained match.
func (f *fakeClient) didRun(match string) bool {
	for _, cmd := range f.commands() {
		if strings.Contains(cmd, match) {
			return true
		}
	}

	return false
}

// pushedPaths returns the remote paths written.
func (f *fakeClient) pushedPaths() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	paths := make([]string, 0, len(f.pushed))
	for p := range f.pushed {
		paths = append(paths, p)
	}

	return paths
}

func (b *fakeBackend) Candidates() ([]netcfg.Candidate, error) { return b.candidates, nil }

func (b *fakeBackend) Assign(iface, hostCIDR string) (func() error, error) {
	b.assigned = append(b.assigned, iface)
	return func() error { return nil }, nil
}

// install swaps in the fakes and registers the restore. Required by any test that
// touches Detect, Flash or SwitchSlot.
func (h *harness) install(t *testing.T) *harness {
	t.Helper()

	if h.client == nil {
		h.client = newFakeClient()
	}

	if h.backend == nil {
		h.backend = &fakeBackend{candidates: []netcfg.Candidate{{Name: "enxtest", MAC: "02:00:00:00:00:01"}}}
	}

	oldDial, oldReachable, oldBackend := dialDevice, reachable, newBackend
	t.Cleanup(func() { dialDevice, reachable, newBackend = oldDial, oldReachable, oldBackend })

	reachable = func(ctx context.Context, ip string, timeout time.Duration) bool {
		if ctx.Err() != nil {
			return false
		}

		if h.reachableIPs == nil {
			return true
		}

		return h.reachableIPs[ip]
	}

	dialDevice = func(ctx context.Context, ip, user, password string, timeout time.Duration) (deviceClient, error) {
		if h.onDial != nil {
			h.onDial(ctx, ip)
		}

		if err := ctx.Err(); err != nil {
			return nil, err
		}

		if h.dialErr != nil {
			return nil, h.dialErr
		}

		return h.client, nil
	}

	newBackend = func() netcfg.Backend { return h.backend }
	return h
}

// collect returns an Emit that records every event, and the slice it fills.
func collect() (Emit, *[]Event) {
	var events []Event
	var mu sync.Mutex
	return func(e Event) {
		mu.Lock()
		defer mu.Unlock()
		events = append(events, e)
	}, &events
}

// logOf renders the events as one string, to assert on what the user saw.
func logOf(events *[]Event) string {
	var b strings.Builder
	for _, e := range *events {
		b.WriteString(e.Msg)
		b.WriteByte('\n')
	}

	return b.String()
}

// The device reports these tests hand to the fake, built from the module's own types
// so the wire spelling reaches them through the code rather than through a literal
// copied into this package. The literal wire format is pinned in the mlflash package's
// own tests, where it is the contract under test rather than a fixture.
func mustReport(report any) string {
	body, err := json.Marshal(report)
	if err != nil {
		panic("marshalling a test fixture: " + err.Error())
	}

	return string(body)
}

// slotBTargets is what every slot-B partition looks like when the flash slot resolves.
func slotBTargets() []mlflash.Target {
	return []mlflash.Target{
		{Name: "uboot1", Status: mlflash.StatusOK, Mtd: 12, Bytes: 786432},
		{Name: "env1", Status: mlflash.StatusOK, Mtd: 10, Bytes: 393216},
		{Name: "kernel1", Status: mlflash.StatusOK, Mtd: 14, Bytes: 6291456},
		{Name: "dtb1", Status: mlflash.StatusOK, Mtd: 16, Bytes: 393216},
		{Name: "userapp1", Status: mlflash.StatusOK, Mtd: 18, Bytes: 47185920},
	}
}

// slotATargets is the same for slot A, which is what a unit booted on B would report.
func slotATargets() []mlflash.Target {
	return []mlflash.Target{
		{Name: "uboot0", Status: mlflash.StatusOK, Mtd: 11, Bytes: 786432},
		{Name: "env0", Status: mlflash.StatusOK, Mtd: 9, Bytes: 393216},
		{Name: "kernel0", Status: mlflash.StatusOK, Mtd: 13, Bytes: 6291456},
		{Name: "dtb0", Status: mlflash.StatusOK, Mtd: 15, Bytes: 393216},
		{Name: "userapp0", Status: mlflash.StatusOK, Mtd: 17, Bytes: 47185920},
	}
}

// A stock unit on slot A with a complete open image on B: the switchable state.
var slotsJSON = mustReport(mlflash.SlotReport{
	Running: "A", GptActive: "A", Consistent: true,
	TargetSlot: "B", TargetContent: "open", TargetModel: "open", TargetComplete: true,
})

// The same unit's flash gate: running slot A, agreeing with the GPT, every slot-B
// partition resolved. This is the only state the tool will flash from.
var preflightJSON = mustReport(mlflash.PreflightReport{
	Running: "A", GptActive: "A", Consistent: true, FlashSlot: "B",
	Targets: slotBTargets(), TargetsResolved: true,
})

// preflightOnSlotB is the same report from a unit booted on slot B: a flash from here
// would target slot A, which the gate refuses.
var preflightOnSlotB = mustReport(mlflash.PreflightReport{
	Running: "B", GptActive: "B", Consistent: true, FlashSlot: "A",
	Targets: slotATargets(), TargetsResolved: true,
})

// writeBundle writes a .mlimg-shaped tar: manifest.json first, uncompressed.
func writeBundle(t *testing.T, targetDevice string) string {
	t.Helper()

	body := []byte("kernel payload")
	digest := sha256.Sum256(body)
	m := manifest.Manifest{
		FormatVersion: manifest.FormatVersion,
		TargetDevice:  targetDevice,
		Version:       "test-1.0",
		Components: []manifest.Component{{
			Name: "kernel", Role: "open", Target: "kernel", Method: "mtdtool-raw", File: "kernel.bin",
			SHA256: hex.EncodeToString(digest[:]), Bytes: int64(len(body)),
			StoredSHA256: hex.EncodeToString(digest[:]), StoredBytes: int64(len(body)),
		}},
	}

	manifestBody, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("marshalling the test manifest: %v", err)
	}

	path := filepath.Join(t.TempDir(), "test.mlimg")
	file, err := os.Create(path)
	if err != nil {
		t.Fatalf("creating the test bundle: %v", err)
	}

	defer file.Close()
	writer := tar.NewWriter(file)
	for _, member := range []struct {
		name string
		data []byte
	}{{"manifest.json", manifestBody}, {"kernel.bin", body}} {
		if err := writer.WriteHeader(&tar.Header{Name: member.name, Mode: 0o644, Size: int64(len(member.data))}); err != nil {
			t.Fatalf("writing tar header: %v", err)
		}

		if _, err := writer.Write(member.data); err != nil {
			t.Fatalf("writing tar body: %v", err)
		}
	}

	if err := writer.Close(); err != nil {
		t.Fatalf("closing the test bundle: %v", err)
	}

	return path
}

// corrupt breaks a component digest while leaving the tar structure readable.
func corrupt(t *testing.T, path string) {
	t.Helper()

	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading the bundle to corrupt it: %v", err)
	}

	// Near the end lands in the payload rather than a header.
	body[len(body)-1024] ^= 0xff
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatalf("writing the corrupted bundle: %v", err)
	}
}

// sha256Of is the digest a device-side sha256sum would report for path.
func sha256Of(t *testing.T, path string) string {
	t.Helper()

	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("hashing %s: %v", path, err)
	}

	digest := sha256.Sum256(body)
	return hex.EncodeToString(digest[:])
}

// A busybox `df -k /tmp` reply with room to spare.
var stockDF = fmt.Sprintf("Filesystem  1K-blocks  Used Available Use%%  Mounted on\ntmpfs %d 0 %d 0%% /tmp\n",
	1<<20, 1<<20)
