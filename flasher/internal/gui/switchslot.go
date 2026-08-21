// The switch-slot phase: confirming the slot and its contents, then flow.SwitchSlot.
package gui

import (
	"context"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/flow"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/present"
)

// confirmSwitch shows the switch-slot confirmation. The confirm button stays
// disabled until the understanding checkbox is ticked, so a reflexive click
// cannot pass it.
func (u *ui) confirmSwitch() {
	view := present.Render(u.state)
	if !view.SwitchEnabled {
		return
	}

	message := widget.NewLabel(view.SwitchDialog.Body)
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

	confirmDialog = dialog.NewCustomWithoutButtons(view.SwitchDialog.Title,
		container.NewVBox(message, acknowledge), u.win)
	confirmDialog.SetButtons([]fyne.CanvasObject{cancelButton, confirmButton})
	confirmDialog.Show()
	confirmDialog.Resize(fyne.NewSize(520, 0))
}

func (u *ui) startSwitch() {
	target := u.state.Info.SwitchTarget()
	u.state.Switching = true
	u.refresh()
	u.resetLog()

	go func() {
		err := flow.SwitchSlot(context.Background(), flow.Options{}, target, u.onEvent)
		fyne.Do(func() {
			u.state.Switching = false
			u.refresh()
			if err == nil {
				// SwitchSlot already waited for the device to reboot onto the activated
				// slot; confirm it and re-scan to refresh the device card.
				done := present.SwitchDone(target.Slot)
				dialog.ShowInformation(done.Title, done.Body, u.win)
				go u.scan()
			}
		})
	}()
}
