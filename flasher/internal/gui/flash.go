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
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/present"
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
	u.state.Image = path
	u.selectedLabel.SetText(filepath.Base(path))
	u.refresh()
}

// confirmFlash offers the two flash modes. The confirm button for each mode is a
// distinct button so the choice is explicit.
func (u *ui) confirmFlash() {
	if u.state.Image == "" || u.state.Flashing {
		return
	}

	text := present.Render(u.state).FlashDialog
	message := widget.NewLabel(text.Body)
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

	confirmDialog = dialog.NewCustomWithoutButtons(text.Title, message, u.win)
	confirmDialog.SetButtons([]fyne.CanvasObject{cancelButton, flashOnlyButton, flashAndSwitchButton})
	confirmDialog.Show()
	confirmDialog.Resize(fyne.NewSize(520, 0))
}

func (u *ui) startFlash(flashOnly bool) {
	u.state.Flashing = true
	u.refresh()
	u.resetLog()

	image := u.state.Image
	go func() {
		err := flow.Flash(context.Background(), flow.Options{ImagePath: image, FlashOnly: flashOnly}, u.onEvent)
		fyne.Do(func() {
			u.state.Flashing = false
			u.refresh()
			if err == nil {
				// Flash has already waited for whatever it started: a reboot onto the
				// open firmware, or nothing at all for a flash-only run. Re-scan so the
				// card reflects where the device ended up.
				done := present.FlashDone(flashOnly)
				dialog.ShowInformation(done.Title, done.Body, u.win)
				go u.scan()
			}
		})
	}()
}
