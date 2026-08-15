// Package gui is the native-window front end: a Fyne app over the flow engine.
// The window opens, scans for a device, and flashes an image the user picks - no
// command line. A single Border layout (status on top, log filling the centre,
// action buttons across the bottom) suits this short linear flow; Fyne links only
// the ubiquitous system GL/X11 libraries, so the binary is self-contained in
// practice (no webkit/WebView2 runtime).
package gui

import (
	"image/color"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/canvas"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/layout"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/flow"
)

// ui holds the widgets and the shared state. Every field is touched only on the
// UI thread (background work marshals back via fyne.Do).
type ui struct {
	win  fyne.Window
	root fyne.CanvasObject

	deviceState  *widget.Label
	deviceStatus *widget.Label
	activity     *widget.ProgressBarInfinite

	selectedLabel *widget.Label
	rescanButton  *widget.Button
	chooseButton  *widget.Button
	flashButton   *widget.Button
	switchButton  *widget.Button

	logView    *widget.Label
	logScroll  *container.Scroll
	copyButton *widget.Button

	// The log backlog, capped at maxLogLines, plus the coalesced-repaint state.
	// logTrimmed records that lines were dropped, so the rendered log says so.
	logLines   []string
	logTrimmed bool
	logPending bool

	selectedImage string
	flashable     bool
	flashing      bool
	scanning      bool
	switchable    bool
	switchTarget  flow.SwitchTarget // the slot a switch activates and what it holds
	flashboot     bool              // the running slot is not the active one
	provenNote    string            // boot-proof sentence for an open switch target (empty if unknown)
	switching     bool
}

// appID is the unique application identifier Fyne needs for its preferences and
// lifecycle APIs.
const appID = "com.missinglynk.flasher"

// Run opens the window and blocks until it is closed.
func Run() {
	application := app.NewWithID(appID)
	window := application.NewWindow("MissingLynk Flasher")

	u := newUI(window)
	window.SetContent(u.root)

	// Wide enough that the normal progress lines do not wrap.
	window.Resize(fyne.NewSize(720, 480))

	// Scan once the event loop is running, so fyne.Do always reaches a live UI thread.
	application.Lifecycle().SetOnStarted(func() { go u.scan() })
	window.ShowAndRun()
}

func newUI(win fyne.Window) *ui {
	u := &ui{win: win}

	u.deviceState = widget.NewLabelWithStyle("Scanning for devices...", fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	u.deviceStatus = widget.NewLabel("")
	u.deviceStatus.Truncation = fyne.TextTruncateEllipsis // truncate an over-long line instead of wrapping
	u.activity = widget.NewProgressBarInfinite()

	u.selectedLabel = widget.NewLabelWithStyle("No image selected", fyne.TextAlignCenter, fyne.TextStyle{Italic: true})
	u.rescanButton = widget.NewButtonWithIcon("Re-scan", theme.ViewRefreshIcon(), func() { go u.scan() })
	u.chooseButton = widget.NewButtonWithIcon("Choose image", theme.FolderOpenIcon(), u.chooseImage)
	u.flashButton = widget.NewButtonWithIcon("Flash", theme.DownloadIcon(), u.confirmFlash)
	u.flashButton.Importance = widget.HighImportance
	u.switchButton = widget.NewButtonWithIcon("Switch slot", theme.MediaReplayIcon(), u.confirmSwitch)
	u.chooseButton.Disable()
	u.flashButton.Disable()
	u.switchButton.Disable()

	// The log is a label inside a scroll: unlike an entry, a Scroll can be reliably
	// pinned to the bottom (ScrollToBottom) as lines arrive. A label is not
	// selectable, so a "Copy log" button provides copy-for-debugging.
	u.logView = widget.NewLabel("")
	u.logView.Wrapping = fyne.TextWrapWord
	u.logView.TextStyle = fyne.TextStyle{Monospace: true}
	u.logScroll = container.NewVScroll(u.logView)
	u.copyButton = widget.NewButtonWithIcon("Copy log", theme.ContentCopyIcon(), func() {
		fyne.CurrentApp().Clipboard().SetContent(u.logText())
	})

	// The status section is a fixed two-line-high slot: a transparent spacer pins
	// the height, so it is the same whether it shows the status text or the
	// progress bar. The bar overlays the text (centred), so a running phase shows
	// the bar over the status lines and never changes the section's height. Every
	// status is kept to at most two lines (firmware/hardware moves to the title),
	// so the text always fits without the section growing.
	sizer := widget.NewLabel("A\nB")
	slotHeight := sizer.MinSize().Height
	if h := u.activity.MinSize().Height; h > slotHeight {
		slotHeight = h
	}

	spacer := canvas.NewRectangle(color.Transparent)
	spacer.SetMinSize(fyne.NewSize(0, slotHeight))
	activityOverlay := container.NewVBox(layout.NewSpacer(), u.activity, layout.NewSpacer())
	statusSlot := container.NewStack(spacer, u.deviceStatus, activityOverlay)
	u.setBusy(false)

	// Top: device status (with the progress bar overlaid). Centre: the log,
	// filling. Bottom: full-width actions.
	top := container.NewVBox(u.deviceState, statusSlot, widget.NewSeparator())
	buttons := container.NewGridWithColumns(4, u.rescanButton, u.chooseButton, u.flashButton, u.switchButton)
	bottom := container.NewVBox(
		container.NewBorder(nil, nil, nil, u.copyButton, u.selectedLabel),
		buttons,
	)

	u.root = container.NewPadded(container.NewBorder(top, bottom, nil, nil, u.logScroll))
	return u
}

// setBusy swaps the status text for the activity bar while a phase runs (so the
// text does not show through the bar's translucent track). The slot's spacer pins
// the height, so hiding the text does not collapse the section or move the log.
func (u *ui) setBusy(busy bool) {
	if busy {
		u.deviceStatus.Hide()
		u.activity.Show()

		return
	}

	u.activity.Hide()
	u.deviceStatus.Show()
}

// refresh updates the action buttons from the current flags: their enabled state,
// and the switch button's label, which names the slot the switch would activate
// (that slot follows the device's active slot, so it is not always the same one).
// Must run on the UI thread.
func (u *ui) refresh() {
	busy := u.scanning || u.flashing || u.switching
	setEnabled(u.rescanButton, !busy)
	setEnabled(u.chooseButton, u.flashable && !busy)
	setEnabled(u.flashButton, u.flashable && !busy && u.selectedImage != "")
	setEnabled(u.switchButton, u.switchable && !busy)

	label := "Switch slot"
	if u.switchTarget.Slot != "" {
		label = "Switch to slot " + u.switchTarget.Slot
	}
	u.switchButton.SetText(label)
}

// withDetail appends an optional follow-on line below the summary, so the status
// area shows a one-sentence summary with any extra information on its own line
// rather than one long truncated string.
func withDetail(summary, detail string) string {
	if detail == "" {
		return summary
	}

	return summary + "\n" + detail
}

func setEnabled(button *widget.Button, enabled bool) {
	if enabled {
		button.Enable()

		return
	}

	button.Disable()
}
