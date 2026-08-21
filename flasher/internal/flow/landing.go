// Where a reboot lands: which firmware fires the reset, which firmware answers
// afterwards, and at what address. Nothing here talks to the device.
package flow

import (
	"fmt"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/devconf"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/device"
)

// The slot-content classifications mlflash reports for the slot a flip would
// activate, as carried on DeviceInfo.TargetContent. "empty" and anything
// unrecognized are neither firmware.
const (
	ContentOpen   = "open"
	ContentVendor = "vendor"
)

// firmware is one of the two stacks a slot can hold. How to reset it, which
// password answers on it and whether it serves DHCP are properties of the
// firmware rather than of the slot letter, so they live together here.
type firmware int

const (
	firmwareStock firmware = iota
	firmwareOpen
)

// Per-firmware reboot commands. A plain `reboot` is a no-op on this hardware
// (sysrq is out); the reliable reset is the watchdog, fired WITHOUT setting the
// SPL reboot-reason flag so the SPL Falcon-boots the GPT-active slot (setting
// that flag would instead drop to U-Boot).
const (
	// The vendor slot has ar_wdt_service: arm the watchdog for 1s and stop petting
	// it. The connection drops as the SoC resets, so the command error is ignored.
	stockRebootCmd = "sync; /usr/bin/ar_wdt_service -t 1 >/dev/null 2>&1 & sleep 1; killall ar_wdt_service"

	// The open slot ships the self-contained wdt-reset helper.
	openRebootCmd = "sync; /usr/local/bin/wdt-reset"
)

// landing is where a reboot puts the device: running is the firmware that fires
// the reset (the one live right now), activated is the firmware that answers
// afterwards, and address is where it answers. Those two firmwares are the same
// in a normal switch and different out of a flash-boot, where the flashed slot
// runs from a host-loaded kernel while the other slot is still the active one.
type landing struct {
	running   firmware
	activated firmware
	address   string

	// isSameAddress records that the activated firmware answers at the address we
	// are connected to right now (an open slot activated out of a flash-boot).
	// There, an SSH answer is not by itself proof of a reboot, so the session that
	// answers must also report a rebooted uptime.
	isSameAddress bool
}

// landingFor works out where a flip to targetContent will land. running is the
// firmware live right now, product is the unit's sdk_version.json
// product_version, and connectedIP is the address this session reached.
func landingFor(running firmware, targetContent, product, connectedIP string, opt Options) (landing, error) {
	activated, err := firmwareForContent(targetContent)
	if err != nil {
		return landing{}, err
	}

	address := opt.DeviceIP
	if activated == firmwareOpen {
		address = devconf.OpenIP[product]
		if address == "" && running == firmwareOpen {
			// Already on an open slot: both open slots answer at the same fixed address.
			address = connectedIP
		}

		if address == "" {
			return landing{}, fmt.Errorf("no open-slot IP configured for product %s", product)
		}
	}

	return landing{
		running:       running,
		activated:     activated,
		address:       address,
		isSameAddress: address == connectedIP,
	}, nil
}

// runningFirmware names the firmware this session is connected to.
func runningFirmware(isOpen bool) firmware {
	if isOpen {
		return firmwareOpen
	}

	return firmwareStock
}

// firmwareForContent maps a slot-content classification to the firmware that
// slot holds. Anything else is refused: a flip can only land on a firmware this
// tool knows how to wait for.
func firmwareForContent(content string) (firmware, error) {
	switch content {
	case ContentOpen:
		return firmwareOpen, nil

	case ContentVendor:
		return firmwareStock, nil

	default:
		return firmwareStock, fmt.Errorf("slot content %s is neither the open nor the stock firmware",
			slotContentDescription(content))
	}
}

// rebootCmd is the command that resets the SoC from this firmware.
func (f firmware) rebootCmd() string {
	if f == firmwareOpen {
		return openRebootCmd
	}

	return stockRebootCmd
}

// password is root's password on this firmware.
func (f firmware) password() string {
	if f == firmwareOpen {
		return device.OpenPassword
	}

	return device.StockPassword
}

// isDHCPServer reports whether this firmware configures the host over DHCP. The
// open slot does; the vendor slot leaves the host to assign its own address.
func (f firmware) isDHCPServer() bool {
	return f == firmwareOpen
}
