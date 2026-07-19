// Package gui is the native-window front end: a Fyne app over the flow engine.
// The window opens, scans for a device, and flashes an image the user picks - no
// command line. A single Border layout (status on top, log filling the centre,
// action buttons across the bottom) suits this short linear flow; Fyne links only
// the ubiquitous system GL/X11 libraries, so the binary is self-contained in
// practice (no webkit/WebView2 runtime).
package gui

import (
	"context"
	"errors"
	"fmt"
	"image/color"
	"path/filepath"
	"strings"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/canvas"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/storage"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"
	"github.com/ncruces/zenity"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/flow"
)

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

	logView    *widget.Label
	logScroll  *container.Scroll
	copyButton *widget.Button

	logBuilder    strings.Builder
	selectedImage string
	flashable     bool
	flashing      bool
	scanning      bool
}

func newUI(win fyne.Window) *ui {
	u := &ui{win: win}

	u.deviceState = widget.NewLabelWithStyle("Scanning for devices...", fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	u.deviceStatus = widget.NewLabel("")
	u.deviceStatus.Truncation = fyne.TextTruncateEllipsis // stay one line, so the slot height is fixed
	u.activity = widget.NewProgressBarInfinite()

	u.selectedLabel = widget.NewLabelWithStyle("No image selected", fyne.TextAlignCenter, fyne.TextStyle{Italic: true})
	u.rescanButton = widget.NewButtonWithIcon("Re-scan", theme.ViewRefreshIcon(), func() { go u.scan() })
	u.chooseButton = widget.NewButtonWithIcon("Choose image", theme.FolderOpenIcon(), u.chooseImage)
	u.flashButton = widget.NewButtonWithIcon("Flash", theme.DownloadIcon(), u.confirmFlash)
	u.flashButton.Importance = widget.HighImportance
	u.chooseButton.Disable()
	u.flashButton.Disable()

	// The log is a label inside a scroll: unlike an entry, a Scroll can be reliably
	// pinned to the bottom (ScrollToBottom) as lines arrive. A label is not
	// selectable, so a "Copy log" button provides copy-for-debugging.
	u.logView = widget.NewLabel("")
	u.logView.Wrapping = fyne.TextWrapWord
	u.logView.TextStyle = fyne.TextStyle{Monospace: true}
	u.logScroll = container.NewVScroll(u.logView)
	u.copyButton = widget.NewButtonWithIcon("Copy log", theme.ContentCopyIcon(), func() {
		fyne.CurrentApp().Clipboard().SetContent(u.logBuilder.String())
	})

	// The status line and the busy bar share one fixed-height slot: a transparent
	// spacer holds the height constant, and only one of the two is visible at a
	// time (see setBusy), so swapping between them never shifts the layout.
	slotHeight := u.deviceStatus.MinSize().Height
	if h := u.activity.MinSize().Height; h > slotHeight {
		slotHeight = h
	}
	spacer := canvas.NewRectangle(color.Transparent)
	spacer.SetMinSize(fyne.NewSize(0, slotHeight))
	statusSlot := container.NewStack(spacer, u.deviceStatus, u.activity)
	u.setBusy(false)

	// Top: device status. Centre: the log, filling. Bottom: full-width actions.
	top := container.NewVBox(u.deviceState, statusSlot, widget.NewSeparator())
	buttons := container.NewGridWithColumns(3, u.rescanButton, u.chooseButton, u.flashButton)
	bottom := container.NewVBox(
		container.NewBorder(nil, nil, nil, u.copyButton, u.selectedLabel),
		buttons,
	)

	u.root = container.NewPadded(container.NewBorder(top, bottom, nil, nil, u.logScroll))
	return u
}

// setBusy shows the activity bar (hiding the status line) while a phase runs, or
// the reverse when idle. They share one slot, so exactly one shows at a time.
func (u *ui) setBusy(busy bool) {
	if busy {
		u.deviceStatus.Hide()
		u.activity.Show()
	} else {
		u.activity.Hide()
		u.deviceStatus.Show()
	}
}

// --- device scan -----------------------------------------------------------

// scan runs the detection phase, streaming progress to the log and summarising
// the result in the status area. Runs in a goroutine.
func (u *ui) scan() {
	fyne.Do(func() {
		u.scanning = true
		u.deviceState.SetText("Scanning for devices...")
		u.deviceStatus.SetText("")
		u.logBuilder.Reset()
		u.logView.SetText("")
		u.setBusy(true)
		u.flashable = false
		u.refresh()
	})

	info, err := flow.Detect(context.Background(), flow.Options{}, u.onEvent)

	fyne.Do(func() {
		u.scanning = false
		u.setBusy(false)
		switch {
		case err != nil:
			u.deviceState.SetText("No device found")
			u.deviceStatus.SetText("Connect one device over USB, power it on, then Re-scan.")
			u.flashable = false

		case info.AlreadyOpen:
			name := info.Name
			if name == "" {
				name = "Device"
			}
			u.deviceState.SetText(name)
			u.deviceStatus.SetText("Already running the MissingLynk firmware.")
			u.flashable = false

		default:
			title := info.Product
			if title == "" {
				title = info.Unit
			}
			u.deviceState.SetText(title)
			u.deviceStatus.SetText(fmt.Sprintf("firmware %s   hardware %s\n%s", info.Firmware, info.Hardware, info.Note))
			u.flashable = info.Flashable
		}

		u.refresh()
	})
}

// --- flash -----------------------------------------------------------------

// chooseImage opens the native OS file picker (zenity: the real GTK/KDE dialog on
// Linux, the Win32 dialog on Windows). It runs off the UI thread and marshals the
// result back. If no native picker is available it falls back to Fyne's in-app one.
func (u *ui) chooseImage() {
	go func() {
		path, err := zenity.SelectFile(
			zenity.Title("Select the MissingLynk firmware image"),
			zenity.FileFilters{{Name: "Firmware image", Patterns: []string{"*.mlimg", "*.tar"}, CaseFold: true}},
		)

		switch {
		case errors.Is(err, zenity.ErrCanceled):
			return

		case err != nil:
			fyne.Do(u.chooseImageFallback)

		default:
			fyne.Do(func() { u.setImage(path) })
		}
	}()
}

// chooseImageFallback is Fyne's in-app file dialog, used when the native picker is
// unavailable.
func (u *ui) chooseImageFallback() {
	fileDialog := dialog.NewFileOpen(func(reader fyne.URIReadCloser, err error) {
		if err != nil || reader == nil {
			return
		}

		defer reader.Close()
		u.setImage(reader.URI().Path())
	}, u.win)
	fileDialog.SetFilter(storage.NewExtensionFileFilter([]string{".mlimg", ".tar"}))

	// Resize must come after Show: the dialog's widgets are not built until then,
	// so resizing earlier dereferences a nil internal (Fyne v2.8).
	fileDialog.Show()
	fileDialog.Resize(fyne.NewSize(760, 540))
}

// setImage records the chosen image and updates the UI (UI thread only).
func (u *ui) setImage(path string) {
	u.selectedImage = path
	u.selectedLabel.SetText(filepath.Base(path))
	u.refresh()
}

func (u *ui) confirmFlash() {
	if u.selectedImage == "" || u.flashing {
		return
	}

	dialog.ShowConfirm("Flash open firmware?",
		"This writes the open firmware to the device's inactive slot and makes it active. "+
			"The stock firmware on the other slot is left untouched.",
		func(confirmed bool) {
			if confirmed {
				u.startFlash()
			}
		}, u.win)
}

func (u *ui) startFlash() {
	u.flashing = true
	u.refresh()
	u.logBuilder.Reset()
	u.logView.SetText("")
	u.setBusy(true)

	image := u.selectedImage
	go func() {
		err := flow.Flash(context.Background(), flow.Options{ImagePath: image}, u.onEvent)
		fyne.Do(func() {
			u.flashing = false
			u.setBusy(false)
			u.refresh()
			if err == nil {
				// Flash already waited for the device to reboot onto the open
				// firmware; confirm it and re-scan to refresh the device card.
				dialog.ShowInformation("Flash complete",
					"The device is now running the MissingLynk open firmware.", u.win)
				go u.scan()
			}
		})
	}()
}

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

func (u *ui) appendLog(line string) {
	u.logBuilder.WriteString(line)
	u.logBuilder.WriteByte('\n')
	u.logView.SetText(u.logBuilder.String())
	u.logScroll.ScrollToBottom()
}

// refresh updates the enabled state of the action buttons from the current flags.
// Must run on the UI thread.
func (u *ui) refresh() {
	busy := u.scanning || u.flashing
	setEnabled(u.rescanButton, !busy)
	setEnabled(u.chooseButton, u.flashable && !busy)
	setEnabled(u.flashButton, u.flashable && !busy && u.selectedImage != "")
}

func setEnabled(button *widget.Button, enabled bool) {
	if enabled {
		button.Enable()
	} else {
		button.Disable()
	}
}
