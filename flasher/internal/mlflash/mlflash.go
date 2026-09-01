// Package mlflash drives the on-device flasher binary of the same name.
//
// mlflash is a static aarch64 program (native/mlflash/) that owns every byte-level
// decision about writing a boot slot. Reaching it means knowing a set of facts that
// are all about mlflash and nothing about the caller: where the binary is uploaded to,
// its flag grammar, that its arguments cross a remote /bin/sh, that it must be on the
// device before the first call, that its read-only modes print one JSON object on
// stdout, and that those modes still exit non-zero while that JSON is good. This
// package is where those facts live, so a caller only has to know which question it is
// asking.
//
// It reports what mlflash said and judges none of it. What a slot state means, and
// whether it permits a flash, is the caller's.
package mlflash

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/device"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/payload"
)

// remotePath is where the binary is uploaded to. /tmp is a small tmpfs on both slots,
// which the roughly 1 MiB binary fits in and a firmware image would not.
const remotePath = "/tmp/mlflash"

// debugReports relays every read-only mode's raw stdout and exit status to the progress
// sink. A report that parses is normally silent, so a device whose answer the host
// cannot explain (an unknown slot, an unresolved target) leaves nothing to read; this
// is the switch that shows what mlflash actually printed. Set ML_FLASHER_DEBUG to turn
// it on, since the tool has no command line.
var debugReports = os.Getenv("ML_FLASHER_DEBUG") != ""

// Runner is the device-side surface this package needs: run a command, run one and
// watch its output arrive, and stream a file up. *device.Client satisfies it.
type Runner interface {
	Run(cmd string) (string, error)
	RunStream(cmd string, onLine func(string)) error
	Push(content io.Reader, remotePath, mode string) error
}

// Progress receives one line at a time: mlflash's own output during a write, and this
// package's note that it uploaded the binary. Lines carry no severity - what to make
// of them is the caller's.
type Progress func(line string)

// Tool is mlflash on one device, reached over one connection.
//
// The binary is uploaded on the first call that needs it and reused after that, which
// is why a Tool is worth holding rather than making per call: the upload is a megabyte
// over a USB gadget link and a run asks several questions before it writes anything.
// The reuse is scoped to this value on purpose - a new connection may be a device that
// rebooted out of its tmpfs, so it gets a new Tool and a fresh upload.
//
// Not safe for concurrent use.
type Tool struct {
	runner   Runner
	progress Progress
	uploaded bool
}

// New returns a Tool that drives mlflash over runner, reporting to progress. progress
// may be nil, which discards the lines.
func New(runner Runner, progress Progress) *Tool {
	return &Tool{runner: runner, progress: progress}
}

// SlotReport is what `mlflash --slots` prints: the running slot, the GPT-active slot,
// whether they agree, and a read-only classification of the slot a flip would activate
// - the complement of the ACTIVE slot, since that is the bit a flip moves. The Target
// fields are absent when gpt0 could not be read, leaving a flip with no direction.
type SlotReport struct {
	Running        string `json:"running"`
	GptActive      string `json:"gpt_active"`
	Consistent     bool   `json:"consistent"`
	TargetSlot     string `json:"target_slot"`
	TargetContent  string `json:"target_content"`
	TargetModel    string `json:"target_model"`
	TargetComplete bool   `json:"target_complete"`
}

// PreflightReport is what `mlflash --preflight` prints: the same slot state, plus the
// slot a flash would write - the complement of the RUNNING slot, which is the one
// --flash picks - and the guard verdict for every partition that slot owns. Targets is
// empty when the flash slot is unknown, since there is then no partition to name.
type PreflightReport struct {
	Running         string   `json:"running"`
	GptActive       string   `json:"gpt_active"`
	Consistent      bool     `json:"consistent"`
	FlashSlot       string   `json:"flash_slot"`
	Targets         []Target `json:"targets"`
	TargetsResolved bool     `json:"targets_resolved"`
}

// The slot letters mlflash prints, and the per-partition verdicts it prints alongside
// them. This is its vocabulary, mirroring slot_letter() and slot_target_status_name()
// in native/mlflash/src/slot.c; a caller matches against these rather than against a
// literal of its own.
const (
	SlotA       = "A"
	SlotB       = "B"
	SlotUnknown = "unknown"

	StatusOK         = "ok"          // resolved and passes every guard
	StatusMissing    = "missing"     // no partition of that name in /proc/mtd
	StatusSibling    = "sibling"     // the 0/1 sibling resolves to the same mtd
	StatusWholeFlash = "whole-flash" // resolved to mtd0, the whole-flash alias
	StatusTooSmall   = "small"       // smaller than the image it must hold
)

// Target is one partition of the flash slot as mlflash judged it. Mtd is -1 and Bytes
// 0 when the name did not resolve.
type Target struct {
	Name   string `json:"name"`
	Status string `json:"status"`
	Mtd    int    `json:"mtd"`
	Bytes  int64  `json:"bytes"`
}

// BootProof is what `mlflash --record` prints for a slot: whether a per-unit record
// exists, the healthy-boot count, whether the record carries kernel/dtb digests at
// all, and whether those digests still match the live partitions.
type BootProof struct {
	Present         bool `json:"present"`
	Boots           int  `json:"boots"`
	DigestsRecorded bool `json:"digests_recorded"`
	Verified        bool `json:"verified"`
}

// Slots reports the A/B slot state and what the flip target holds. Read-only.
func (tool *Tool) Slots() (*SlotReport, error) {
	var report SlotReport
	if err := tool.readReport(&report, "--slots"); err != nil {
		return nil, err
	}

	return &report, nil
}

// Preflight reports whether the inactive slot can be written at all, with no image in
// hand. Read-only.
func (tool *Tool) Preflight() (*PreflightReport, error) {
	var report PreflightReport
	if err := tool.readReport(&report, "--preflight"); err != nil {
		return nil, err
	}

	return &report, nil
}

// Record reports the boot proof recorded for slot ("a" or "b"). Read-only. A slot with
// no record is not an error: the report comes back with Present false.
func (tool *Tool) Record(slot string) (BootProof, error) {
	var proof BootProof
	err := tool.readReport(&proof, "--record", "--slot", slot)

	return proof, err
}

// Inspect re-verifies every component hash in the bundle at remoteImage against its
// manifest. Writes nothing, and needs no device state.
func (tool *Tool) Inspect(remoteImage string) error {
	return tool.stream("--inspect", remoteImage)
}

// DryRun plans the flash of the bundle at remoteImage: slot state, board identity,
// every component resolved to the partition it would be written to, every hash
// verified. Writes nothing, and returns an error when it found blockers.
func (tool *Tool) DryRun(remoteImage string) error {
	return tool.stream("--dry-run", remoteImage)
}

// Flash writes the bundle at remoteImage to the inactive slot, behind mlflash's own
// preflight, and leaves the active slot alone. Call Flip separately to activate it.
func (tool *Tool) Flash(remoteImage string) error {
	return tool.stream("--flash", remoteImage)
}

// Flip makes the non-active slot the active one. It writes gpt0 and no component.
func (tool *Tool) Flip() error {
	return tool.stream("--flip")
}

// readReport runs a read-only mode and unmarshals its one JSON line into out.
//
// mlflash prints its report and *then* exits non-zero when it could not determine
// everything it was asked for, so a report that parses is the answer whatever the exit
// status said: every one of those exit conditions is also visible in the JSON, as an
// unknown slot or an unresolved target. The exit status only decides which failure to
// report when the JSON did not parse at all.
func (tool *Tool) readReport(out any, args ...string) error {
	if err := tool.ensureUploaded(); err != nil {
		return err
	}

	stdout, runErr := tool.runner.Run(command(args...))
	line := strings.TrimSpace(stdout)
	if debugReports {
		tool.say(fmt.Sprintf("debug: mlflash %s printed %q", strings.Join(args, " "), line))
		if runErr != nil {
			tool.say(fmt.Sprintf("debug: mlflash %s exited: %v", strings.Join(args, " "), runErr))
		}
	}

	if err := json.Unmarshal([]byte(line), out); err != nil {
		if runErr != nil {
			return fmt.Errorf("mlflash %s failed: %w", args[0], runErr)
		}

		return fmt.Errorf("parsing mlflash %s output %q: %w", args[0], line, err)
	}

	return nil
}

// stream runs a mode that reports as it works, relaying its output line by line.
func (tool *Tool) stream(args ...string) error {
	if err := tool.ensureUploaded(); err != nil {
		return err
	}

	return tool.runner.RunStream(command(args...), func(line string) {
		// ubiformat and libscan redraw a per-eraseblock "... N % complete" counter
		// hundreds of times; drop it, and drop the empty tokens left by "\r\n" pairs.
		// The phase summary lines still come through.
		line = strings.TrimRight(line, " ")
		if line == "" || strings.Contains(line, "% complete") {
			return
		}

		tool.say(line)
	})
}

// ensureUploaded puts the binary on the device, once per Tool.
func (tool *Tool) ensureUploaded() error {
	if tool.uploaded {
		return nil
	}

	binary, size := payload.Mlflash()
	tool.say(fmt.Sprintf("Uploading mlflash (%d KiB)", size/1024))
	if err := tool.runner.Push(binary, remotePath, "755"); err != nil {
		return fmt.Errorf("uploading mlflash: %w", err)
	}

	tool.uploaded = true

	return nil
}

// say relays one line to the caller's progress sink.
func (tool *Tool) say(line string) {
	if tool.progress != nil {
		tool.progress(line)
	}
}

// command builds the remote command line. Every argument is quoted: they cross a
// remote /bin/sh, and a slot letter reaches this from a device report rather than from
// a literal.
func command(args ...string) string {
	cmd := remotePath
	for _, arg := range args {
		cmd += " " + device.ShellQuote(arg)
	}

	return cmd
}
