// The log pane. Appends are buffered and repainted on a timer: a Label re-lays-out
// its whole text on every SetText, so one repaint per line is quadratic.
package gui

import (
	"fmt"
	"strings"
	"time"

	"fyne.io/fyne/v2"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/flow"
)

const (
	// A whole flash is normally a few hundred lines (flow.runMlflash already drops
	// ubiformat's per-eraseblock counter); this only bounds a run that goes wrong.
	maxLogLines = 5000

	// Short enough to read as live, long enough that a burst costs one layout pass.
	logRepaintInterval = 100 * time.Millisecond
)

// onEvent appends a flow event to the log (marshalled onto the UI thread). Used
// by both the scan and flash phases.
func (u *ui) onEvent(e flow.Event) {
	fyne.Do(func() {
		switch e.Level {
		case flow.LevelStep:
			u.appendLog("-> " + e.Msg)

		case flow.LevelWarn:
			u.appendLog("warning: " + e.Msg)

		case flow.LevelError:
			u.appendLog("error: " + e.Msg)

		case flow.LevelDone:
			u.appendLog(e.Msg)

		default:
			u.appendLog("   " + e.Msg)
		}
	})
}

// appendLog adds one line. It does NOT repaint; flushLog does, on a timer. The
// backlog is capped at maxLogLines. Must run on the UI thread.
func (u *ui) appendLog(line string) {
	u.logLines = append(u.logLines, line)
	if excess := len(u.logLines) - maxLogLines; excess > 0 {
		// Copy down rather than reslice, so the backing array stays bounded.
		u.logLines = append(u.logLines[:0], u.logLines[excess:]...)
		u.logTrimmed = true
	}

	if u.logPending {
		return
	}

	u.logPending = true
	time.AfterFunc(logRepaintInterval, func() { fyne.Do(u.flushLog) })
}

// resetLog clears the log, repainting at once so the old run does not linger until
// the next flush. UI thread only.
func (u *ui) resetLog() {
	u.logLines = nil
	u.logTrimmed = false
	u.logView.SetText("")
}

// flushLog renders the backlog: one repaint per logRepaintInterval. UI thread only.
func (u *ui) flushLog() {
	u.logPending = false
	u.logView.SetText(u.logText())
	u.logScroll.ScrollToBottom()
}

// logText is the rendered log, marked where lines were dropped so a copied log is
// never mistaken for the whole run.
func (u *ui) logText() string {
	if !u.logTrimmed {
		return strings.Join(u.logLines, "\n")
	}

	return fmt.Sprintf("[earlier lines dropped; showing the last %d]\n%s",
		maxLogLines, strings.Join(u.logLines, "\n"))
}
