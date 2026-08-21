// The device-scan phase: flow.Detect, rendered into the device card and switch button.
package gui

import (
	"context"
	"strings"

	"fyne.io/fyne/v2"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/flow"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/present"
)

// scan runs the detection phase, streaming progress to the log and summarising
// the result in the status area. Runs in a goroutine.
func (u *ui) scan() {
	fyne.Do(func() {
		u.state.Scanning = true
		u.state.Info = nil
		u.state.ScanErr = nil
		u.resetLog()
		u.refresh()
	})

	info, err := flow.Detect(context.Background(), flow.Options{}, u.onEvent)

	fyne.Do(func() {
		u.state.Scanning = false
		u.state.Info = info
		u.state.ScanErr = err
		u.refresh()
		u.logSummary()
	})
}

// logSummary closes the scan log with the same summary the device card shows, so a
// copied log carries the outcome instead of just stopping. A refusal is marked the
// way the card marks it.
func (u *ui) logSummary() {
	if u.state.Info == nil {
		return
	}

	view := present.Render(u.state)
	for i, line := range strings.Split(view.Status, "\n") {
		if i == 0 && view.IsStatusWarning {
			u.appendLog("warning: " + line)
			continue
		}

		u.appendLog(line)
	}
}
