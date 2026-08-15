// The switch-slot phase: confirming the slot and its contents, then flow.SwitchSlot.
package gui

import (
	"context"
	"fmt"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/flow"
)

// confirmSwitch shows the switch-slot confirmation. The confirm button stays
// disabled until the understanding checkbox is ticked, so a reflexive click
// cannot pass it; the wording names the slot being activated and spells out the
// direction-specific risk.
func (u *ui) confirmSwitch() {
	if !u.switchable || u.flashing || u.switching {
		return
	}

	text := fmt.Sprintf("This makes slot %s (stock firmware) the active boot slot and reboots into it. "+
		"That slot is the untouched factory install, so this is the low-risk direction. "+
		"You can switch back to the MissingLynk firmware the same way afterwards.", u.switchTarget.Slot)
	if u.switchTarget.Content == "open" {
		text = fmt.Sprintf("This makes slot %s (MissingLynk open firmware) the active boot slot and reboots "+
			"into it, WITHOUT rewriting or re-verifying it. If that slot no longer boots, the device "+
			"will not start until the boot slot is recovered. Only proceed if this tool flashed the "+
			"open firmware onto this device before and it booted.", u.switchTarget.Slot)
		if u.flashboot {
			text = fmt.Sprintf("This makes slot %s (MissingLynk open firmware) the active boot slot and "+
				"reboots into it. This boot is already running slot %s while the other slot is still the "+
				"active one (as after a flash-boot), so the firmware being activated is the one running "+
				"right now - but that does not exercise slot %s's own bootloader, which the reboot will.",
				u.switchTarget.Slot, u.switchTarget.Slot, u.switchTarget.Slot)
		}

		if u.provenNote != "" {
			text += "\n\n" + u.provenNote
		}
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

	confirmDialog = dialog.NewCustomWithoutButtons(fmt.Sprintf("Switch to slot %s?", u.switchTarget.Slot),
		container.NewVBox(message, acknowledge), u.win)
	confirmDialog.SetButtons([]fyne.CanvasObject{cancelButton, confirmButton})
	confirmDialog.Show()
	confirmDialog.Resize(fyne.NewSize(520, 0))
}

func (u *ui) startSwitch() {
	u.switching = true
	u.refresh()
	u.resetLog()
	u.setBusy(true)

	target := u.switchTarget
	go func() {
		err := flow.SwitchSlot(context.Background(), flow.Options{}, target, u.onEvent)
		fyne.Do(func() {
			u.switching = false
			u.setBusy(false)
			u.refresh()
			if err == nil {
				// SwitchSlot already waited for the device to reboot onto the activated
				// slot; confirm it and re-scan to refresh the device card.
				dialog.ShowInformation("Switch complete",
					fmt.Sprintf("The device is now running the firmware from slot %s.", target.Slot), u.win)
				go u.scan()
			}
		})
	}()
}
