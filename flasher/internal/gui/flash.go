// The flash phase: choosing an image, confirming the mode, and driving flow.Flash.
package gui

import (
	"context"
	"errors"
	"path/filepath"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/storage"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"
	"github.com/ncruces/zenity"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/flow"
)

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
// activated later with the switch button (after proving it, e.g. by RAM-boot). The
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
			"activated; use the switch button to boot it once you are ready.")
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
	u.resetLog()
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
					// but not active. Re-scan so the card offers the switch.
					dialog.ShowInformation("Flash complete",
						"The open firmware is written to the inactive slot. The device is still "+
							"running its current slot; use the switch button to activate it.", u.win)
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
