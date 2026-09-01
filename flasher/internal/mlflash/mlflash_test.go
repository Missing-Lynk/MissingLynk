package mlflash

import (
	"errors"
	"io"
	"strings"
	"testing"
)

// fakeRunner stands in for a connected device. Replies match by substring in
// registration order; anything unmatched returns the zero reply.
type fakeRunner struct {
	replies []reply
	ran     []string
	pushed  map[string][]byte
	pushErr error
}

type reply struct {
	match string
	out   string
	err   error
}

func newFakeRunner() *fakeRunner {
	return &fakeRunner{pushed: map[string][]byte{}}
}

// on registers a reply for any command containing match. First match wins.
func (f *fakeRunner) on(match, out string, err error) *fakeRunner {
	f.replies = append(f.replies, reply{match: match, out: out, err: err})
	return f
}

func (f *fakeRunner) Run(cmd string) (string, error) {
	f.ran = append(f.ran, cmd)
	for _, r := range f.replies {
		if strings.Contains(cmd, r.match) {
			return r.out, r.err
		}
	}

	return "", nil
}

func (f *fakeRunner) RunStream(cmd string, onLine func(string)) error {
	out, err := f.Run(cmd)
	for _, line := range strings.Split(out, "\n") {
		onLine(line)
	}

	return err
}

func (f *fakeRunner) Push(content io.Reader, remotePath, mode string) error {
	if f.pushErr != nil {
		return f.pushErr
	}

	body, err := io.ReadAll(content)
	if err != nil {
		return err
	}

	f.pushed[remotePath] = body
	f.ran = append(f.ran, "push "+remotePath+" mode="+mode)

	return nil
}

func (f *fakeRunner) didRun(match string) bool {
	for _, cmd := range f.ran {
		if strings.Contains(cmd, match) {
			return true
		}
	}

	return false
}

// newTool wires a Tool to a fake and collects the progress lines it emits.
func newTool(runner *fakeRunner) (*Tool, *[]string) {
	var lines []string
	tool := New(runner, func(line string) { lines = append(lines, line) })

	return tool, &lines
}

const slotsJSON = `{"running":"A","gpt_active":"A","consistent":true,` +
	`"target_slot":"B","target_content":"open","target_model":"open","target_complete":true}`

const preflightJSON = `{"running":"A","gpt_active":"A","consistent":true,"flash_slot":"B",` +
	`"targets":[{"name":"kernel1","status":"ok","mtd":14,"bytes":6291456},` +
	`{"name":"userapp1","status":"missing","mtd":-1,"bytes":0}],"targets_resolved":false}`

// The reports come back with every field the device sent, whatever mode asked.
func TestReportsCarryWhatTheDeviceSaid(t *testing.T) {
	runner := newFakeRunner().
		on("--slots", slotsJSON, nil).
		on("--preflight", preflightJSON, nil).
		on("--record", `{"present":true,"boots":3,"digests_recorded":true,"verified":true}`, nil)
	tool, _ := newTool(runner)

	slots, err := tool.Slots()
	if err != nil {
		t.Fatalf("Slots() = %v, want no error", err)
	}

	if slots.Running != "A" || slots.GptActive != "A" || !slots.Consistent ||
		slots.TargetSlot != "B" || slots.TargetContent != "open" || !slots.TargetComplete {
		t.Errorf("Slots() = %+v, want the reported slot state", slots)
	}

	pre, err := tool.Preflight()
	if err != nil {
		t.Fatalf("Preflight() = %v, want no error", err)
	}

	if pre.FlashSlot != "B" || pre.TargetsResolved || len(pre.Targets) != 2 {
		t.Errorf("Preflight() = %+v, want the reported gate state", pre)
	}

	if pre.Targets[1].Name != "userapp1" || pre.Targets[1].Status != "missing" ||
		pre.Targets[1].Mtd != -1 {
		t.Errorf("Preflight().Targets[1] = %+v, want the unresolved partition verbatim", pre.Targets[1])
	}

	proof, err := tool.Record("b")
	if err != nil {
		t.Fatalf("Record() = %v, want no error", err)
	}

	if !proof.Present || proof.Boots != 3 || !proof.DigestsRecorded || !proof.Verified {
		t.Errorf("Record() = %+v, want the reported boot proof", proof)
	}
}

// The contract every read-only mode is built on, and the one nothing pinned before:
// mlflash prints its report and THEN exits non-zero when it could not determine
// everything. The report is the answer; the exit status is not a failure.
func TestValidJSONWinsOverANonZeroExit(t *testing.T) {
	exit1 := errors.New("Process exited with status 1")
	runner := newFakeRunner().
		on("--slots", `{"running":"A","gpt_active":"unknown","consistent":false}`, exit1).
		on("--preflight", `{"running":"unknown","gpt_active":"unknown","consistent":false,`+
			`"flash_slot":"unknown","targets":[],"targets_resolved":false}`, exit1).
		on("--record", `{"present":false}`, exit1)
	tool, _ := newTool(runner)

	slots, err := tool.Slots()
	if err != nil {
		t.Fatalf("Slots() = %v, want the report to win over the exit status", err)
	}

	if slots.GptActive != "unknown" {
		t.Errorf("Slots().GptActive = %q, want the undetermined slot reported", slots.GptActive)
	}

	pre, err := tool.Preflight()
	if err != nil {
		t.Fatalf("Preflight() = %v, want the report to win over the exit status", err)
	}

	if pre.Running != "unknown" || pre.TargetsResolved {
		t.Errorf("Preflight() = %+v, want the undetermined state reported", pre)
	}

	proof, err := tool.Record("a")
	if err != nil {
		t.Fatalf("Record() = %v, want the report to win over the exit status", err)
	}

	if proof.Present {
		t.Error("Record() reported a record that the device said was absent")
	}
}

// When the JSON does not parse there is no answer, and the failure named is the one
// that actually happened: the run's own error where there was one, the malformed
// output where there was not.
func TestAnUnparseableReportIsAnError(t *testing.T) {
	t.Run("the run failed", func(t *testing.T) {
		runner := newFakeRunner().on("--slots", "sh: /tmp/mlflash: not found", errors.New("exit 127"))
		tool, _ := newTool(runner)

		if _, err := tool.Slots(); err == nil || !strings.Contains(err.Error(), "exit 127") {
			t.Errorf("Slots() = %v, want the run's own failure named", err)
		}
	})

	t.Run("the run succeeded but printed nothing usable", func(t *testing.T) {
		runner := newFakeRunner().on("--slots", "not json at all", nil)
		tool, _ := newTool(runner)

		_, err := tool.Slots()
		if err == nil {
			t.Fatal("Slots() = nil error for unparseable output")
		}

		if !strings.Contains(err.Error(), "not json at all") {
			t.Errorf("Slots() = %v, want the offending output quoted", err)
		}
	})
}

// The binary is a megabyte over a USB gadget link. It goes up on the first call that
// needs it, and every later call on the same Tool reuses it.
func TestTheBinaryIsUploadedOncePerTool(t *testing.T) {
	runner := newFakeRunner().
		on("--slots", slotsJSON, nil).
		on("--preflight", preflightJSON, nil)
	tool, lines := newTool(runner)

	for range 3 {
		if _, err := tool.Slots(); err != nil {
			t.Fatalf("Slots() = %v, want no error", err)
		}
	}

	if _, err := tool.Preflight(); err != nil {
		t.Fatalf("Preflight() = %v, want no error", err)
	}

	if err := tool.Flip(); err != nil {
		t.Fatalf("Flip() = %v, want no error", err)
	}

	if got := len(runner.pushed); got != 1 {
		t.Errorf("pushed %d paths, want just the binary", got)
	}

	if _, ok := runner.pushed[remotePath]; !ok {
		t.Errorf("pushed %v, want the binary at %s", runner.pushed, remotePath)
	}

	uploads := 0
	for _, line := range *lines {
		if strings.Contains(line, "Uploading mlflash") {
			uploads++
		}
	}

	if uploads != 1 {
		t.Errorf("announced %d uploads across 5 calls, want 1", uploads)
	}

	// A second Tool is a second connection, which may be a device that rebooted out
	// of its tmpfs, so it uploads again.
	second, _ := newTool(runner)
	if _, err := second.Slots(); err != nil {
		t.Fatalf("Slots() on a second Tool = %v, want no error", err)
	}

	if len(runner.ran) < 2 || !runner.didRun("push "+remotePath) {
		t.Error("a fresh Tool did not upload the binary")
	}
}

// A device that will not take the binary cannot answer anything, and no mode may
// pretend otherwise by running a command that is not there.
func TestNoModeRunsWhenTheUploadFails(t *testing.T) {
	runner := newFakeRunner()
	runner.pushErr = errors.New("no space left on device")
	tool, _ := newTool(runner)

	calls := map[string]func() error{
		"Slots":     func() error { _, err := tool.Slots(); return err },
		"Preflight": func() error { _, err := tool.Preflight(); return err },
		"Record":    func() error { _, err := tool.Record("b"); return err },
		"Inspect":   func() error { return tool.Inspect("/tmp/x.mlimg") },
		"DryRun":    func() error { return tool.DryRun("/tmp/x.mlimg") },
		"Flash":     func() error { return tool.Flash("/tmp/x.mlimg") },
		"Flip":      tool.Flip,
	}

	for name, call := range calls {
		err := call()
		if err == nil || !strings.Contains(err.Error(), "no space left") {
			t.Errorf("%s() = %v, want the upload failure surfaced", name, err)
		}
	}

	if len(runner.ran) != 0 {
		t.Errorf("ran %v with no binary on the device", runner.ran)
	}
}

// Arguments cross a remote /bin/sh, and a slot letter arrives from a device report
// rather than from a literal.
func TestArgumentsAreQuotedForTheRemoteShell(t *testing.T) {
	runner := newFakeRunner().on("--record", `{"present":false}`, nil)
	tool, _ := newTool(runner)

	if _, err := tool.Record("b; rm -rf /"); err != nil {
		t.Fatalf("Record() = %v, want no error", err)
	}

	var cmd string
	for _, ran := range runner.ran {
		if strings.Contains(ran, "--record") {
			cmd = ran
		}
	}

	if want := remotePath + " '--record' '--slot' 'b; rm -rf /'"; cmd != want {
		t.Errorf("ran %q, want %q", cmd, want)
	}
}

// The writing modes report as they work, so the user sees mlflash's own per-component
// messages. ubiformat redraws a per-eraseblock counter hundreds of times; that is
// noise, and so are the empty tokens a "\r\n" pair leaves behind.
func TestWritingModesRelayOutputWithoutTheProgressCounter(t *testing.T) {
	runner := newFakeRunner().on("--flash",
		"flash: kernel1 -> /dev/mtd14\n"+
			"libscan: scanning eraseblock 12 -- 40 % complete\n"+
			"\n"+
			"   \n"+
			"flash: userapp1 written\n", nil)
	tool, lines := newTool(runner)

	if err := tool.Flash("/tmp/image.mlimg"); err != nil {
		t.Fatalf("Flash() = %v, want no error", err)
	}

	var relayed []string
	for _, line := range *lines {
		if !strings.Contains(line, "Uploading mlflash") {
			relayed = append(relayed, line)
		}
	}

	want := []string{"flash: kernel1 -> /dev/mtd14", "flash: userapp1 written"}
	if len(relayed) != len(want) {
		t.Fatalf("relayed %q, want %q", relayed, want)
	}

	for i := range want {
		if relayed[i] != want[i] {
			t.Errorf("relayed[%d] = %q, want %q", i, relayed[i], want[i])
		}
	}
}

// A write that fails must say so. mlflash's own diagnosis still reaches the user.
func TestAFailedWriteSurfacesTheError(t *testing.T) {
	runner := newFakeRunner().on("--flash",
		"flash: refusing to write slot A without --force-a\n", errors.New("exit 1"))
	tool, lines := newTool(runner)

	if err := tool.Flash("/tmp/image.mlimg"); err == nil {
		t.Fatal("Flash() = nil error, want the failure surfaced")
	}

	joined := strings.Join(*lines, "\n")
	if !strings.Contains(joined, "refusing to write slot A") {
		t.Errorf("relayed %q, want mlflash's own diagnosis", joined)
	}
}

// Each mode reaches for its own flag and no other.
func TestEachModeRunsItsOwnFlag(t *testing.T) {
	tests := []struct {
		flag string
		call func(*Tool) error
	}{
		{"--inspect", func(t *Tool) error { return t.Inspect("/tmp/i.mlimg") }},
		{"--dry-run", func(t *Tool) error { return t.DryRun("/tmp/i.mlimg") }},
		{"--flash", func(t *Tool) error { return t.Flash("/tmp/i.mlimg") }},
		{"--flip", func(t *Tool) error { return t.Flip() }},
	}

	for _, tt := range tests {
		t.Run(tt.flag, func(t *testing.T) {
			runner := newFakeRunner()
			tool, _ := newTool(runner)
			if err := tt.call(tool); err != nil {
				t.Fatalf("%s = %v, want no error", tt.flag, err)
			}

			if !runner.didRun(remotePath + " '" + tt.flag + "'") {
				t.Errorf("ran %v, want %s", runner.ran, tt.flag)
			}
		})
	}
}

// A Tool with no progress sink still works; the lines are simply discarded.
func TestANilProgressSinkIsAccepted(t *testing.T) {
	runner := newFakeRunner().on("--slots", slotsJSON, nil)
	tool := New(runner, nil)

	if _, err := tool.Slots(); err != nil {
		t.Fatalf("Slots() = %v, want no error", err)
	}
}
