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
	"fyne.io/fyne/v2/layout"
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
	switchButton  *widget.Button

	logView    *widget.Label
	logScroll  *container.Scroll
	copyButton *widget.Button

	logBuilder    strings.Builder
	selectedImage string
	flashable     bool
	flashing      bool
	scanning      bool
	switchable    bool
	switchToOpen  bool // switch direction: true = activate the open slot, false = back to stock
	switching     bool
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
		fyne.CurrentApp().Clipboard().SetContent(u.logBuilder.String())
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
		u.switchable = false
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
			u.switchable = false

		case info.AlreadyOpen:
			name := info.Name
			if name == "" {
				name = "Device"
			}
			u.deviceState.SetText(name)
			u.deviceStatus.SetText(withDetail(info.Note, info.Detail))
			u.flashable = false
			u.switchable = info.Switchable
			u.switchToOpen = false

		default:
			title := info.Product
			if title == "" {
				title = info.Unit
			}
			if info.Firmware != "" || info.Hardware != "" {
				title = fmt.Sprintf("%s   (firmware %s, hardware %s)", title, info.Firmware, info.Hardware)
			}
			u.deviceState.SetText(title)
			u.deviceStatus.SetText(withDetail(info.Note, info.Detail))
			u.flashable = info.Flashable
			u.switchable = info.Switchable
			u.switchToOpen = true
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

// confirmFlash offers the two flash modes. "Flash and switch" (default) writes the
// inactive slot, activates it, and reboots. "Flash only" writes the inactive slot
// and stops, leaving the device on its current slot; the written slot can be
// activated later with Switch slot (after proving it, e.g. by RAM-boot). The
// confirm button for each mode is a distinct button so the choice is explicit.
func (u *ui) confirmFlash() {
	if u.selectedImage == "" || u.flashing {
		return
	}

	message := widget.NewLabel(
		"This writes the open firmware to the device's inactive slot. The stock firmware on the " +
			"other slot is left untouched.\n\n" +
			"Flash and switch: activate the newly written slot and reboot into it now.\n\n" +
			"Flash only: leave the device on its current slot. The new slot is written but not " +
			"activated; use Switch slot to boot it once you are ready.")
	message.Wrapping = fyne.TextWrapWord

	var confirmDialog *dialog.CustomDialog
	cancelButton := widget.NewButton("Cancel", func() { confirmDialog.Hide() })
	flashOnlyButton := widget.NewButton("Flash only", func() {
		confirmDialog.Hide()
		u.startFlash(true)
	})
	flashAndSwitchButton := widget.NewButtonWithIcon("Flash and switch", theme.DownloadIcon(), func() {
		confirmDialog.Hide()
		u.startFlash(false)
	})
	flashAndSwitchButton.Importance = widget.HighImportance

	confirmDialog = dialog.NewCustomWithoutButtons("Flash open firmware?", message, u.win)
	confirmDialog.SetButtons([]fyne.CanvasObject{cancelButton, flashOnlyButton, flashAndSwitchButton})
	confirmDialog.Show()
	confirmDialog.Resize(fyne.NewSize(520, 0))
}

func (u *ui) startFlash(flashOnly bool) {
	u.flashing = true
	u.refresh()
	u.logBuilder.Reset()
	u.logView.SetText("")
	u.setBusy(true)

	image := u.selectedImage
	go func() {
		err := flow.Flash(context.Background(), flow.Options{ImagePath: image, FlashOnly: flashOnly}, u.onEvent)
		fyne.Do(func() {
			u.flashing = false
			u.setBusy(false)
			u.refresh()
			if err == nil {
				if flashOnly {
					// The device is still on its old slot; the new slot is written
					// but not active. Re-scan so the card offers Switch slot.
					dialog.ShowInformation("Flash complete",
						"The open firmware is written to the inactive slot. The device is still "+
							"running its current slot; use Switch slot to activate it.", u.win)
				} else {
					// Flash already waited for the device to reboot onto the open
					// firmware; confirm it.
					dialog.ShowInformation("Flash complete",
						"The device is now running the MissingLynk open firmware.", u.win)
				}
				go u.scan()
			}
		})
	}()
}

// --- switch slot -----------------------------------------------------------

// confirmSwitch shows the switch-slot confirmation. The confirm button stays
// disabled until the understanding checkbox is ticked, so a reflexive click
// cannot pass it; the wording spells out the direction-specific risk.
func (u *ui) confirmSwitch() {
	if !u.switchable || u.flashing || u.switching {
		return
	}

	text := "This makes the other slot (stock firmware) the active boot slot and reboots into it. " +
		"That slot is the untouched factory install, so this is the low-risk direction. " +
		"You can switch back to the MissingLynk firmware the same way afterwards."
	if u.switchToOpen {
		text = "This makes the other slot (MissingLynk open firmware) the active boot slot and reboots " +
			"into it, WITHOUT rewriting or re-verifying it. If that slot no longer boots, the device " +
			"will not start until the boot slot is recovered. Only proceed if this tool flashed the " +
			"open firmware onto this device before and it booted."
	}

	message := widget.NewLabel(text)
	message.Wrapping = fyne.TextWrapWord
	acknowledge := widget.NewCheck("I understand what switching the boot slot does", nil)

	var confirmDialog *dialog.CustomDialog
	confirmButton := widget.NewButtonWithIcon("Switch", theme.ConfirmIcon(), func() {
		confirmDialog.Hide()
		u.startSwitch()
	})
	confirmButton.Importance = widget.HighImportance
	confirmButton.Disable()
	acknowledge.OnChanged = func(checked bool) { setEnabled(confirmButton, checked) }
	cancelButton := widget.NewButton("Cancel", func() { confirmDialog.Hide() })

	confirmDialog = dialog.NewCustomWithoutButtons("Switch boot slot?",
		container.NewVBox(message, acknowledge), u.win)
	confirmDialog.SetButtons([]fyne.CanvasObject{cancelButton, confirmButton})
	confirmDialog.Show()
	confirmDialog.Resize(fyne.NewSize(520, 0))
}

func (u *ui) startSwitch() {
	u.switching = true
	u.refresh()
	u.logBuilder.Reset()
	u.logView.SetText("")
	u.setBusy(true)

	switchToOpen := u.switchToOpen
	go func() {
		err := flow.SwitchSlot(context.Background(), flow.Options{}, switchToOpen, u.onEvent)
		fyne.Do(func() {
			u.switching = false
			u.setBusy(false)
			u.refresh()
			if err == nil {
				// SwitchSlot already waited for the device to reboot onto the other
				// slot; confirm it and re-scan to refresh the device card.
				dialog.ShowInformation("Switch complete",
					"The device is now running the firmware from the other slot.", u.win)
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
	busy := u.scanning || u.flashing || u.switching
	setEnabled(u.rescanButton, !busy)
	setEnabled(u.chooseButton, u.flashable && !busy)
	setEnabled(u.flashButton, u.flashable && !busy && u.selectedImage != "")
	setEnabled(u.switchButton, u.switchable && !busy)
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
	} else {
		button.Disable()
	}
}
