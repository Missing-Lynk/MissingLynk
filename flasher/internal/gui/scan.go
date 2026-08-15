// The device-scan phase: flow.Detect, rendered into the device card and switch button.
package gui

import (
	"context"
	"fmt"

	"fyne.io/fyne/v2"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/flow"
)

// scan runs the detection phase, streaming progress to the log and summarising
// the result in the status area. Runs in a goroutine.
func (u *ui) scan() {
	fyne.Do(func() {
		u.scanning = true
		u.deviceState.SetText("Scanning for devices...")
		u.deviceStatus.SetText("")
		u.resetLog()
		u.setBusy(true)
		u.flashable = false
		u.clearSwitch()
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
			u.clearSwitch()

		case info.AlreadyOpen:
			name := info.Name
			if name == "" {
				name = "Device"
			}
			u.deviceState.SetText(name)
			u.deviceStatus.SetText(withDetail(info.Note, info.Detail))
			u.flashable = false
			u.setSwitch(info)

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
			u.setSwitch(info)
		}

		u.refresh()
	})
}

// setSwitch records the switch a scan found: which slot it activates, what that
// slot holds, and whether the device is in a flash-boot (running slot != active
// slot). The direction comes from the device's real active slot, so it is whatever
// the scan reported rather than an assumption from the running firmware.
func (u *ui) setSwitch(info *flow.DeviceInfo) {
	u.switchable = info.Switchable
	u.switchTarget = info.SwitchTarget()
	u.flashboot = info.RunningSlot != "" && info.ActiveSlot != "" && info.RunningSlot != info.ActiveSlot
	u.provenNote = info.ProvenNote
}

// clearSwitch drops the recorded switch, for when no device (or no usable slot
// state) was found.
func (u *ui) clearSwitch() {
	u.switchable = false
	u.switchTarget = flow.SwitchTarget{}
	u.flashboot = false
	u.provenNote = ""
}
