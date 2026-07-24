// Package whitelist is the list of devices ml-flasher is allowed to flash, and
// the single place to edit it.
//
// This is a SAFETY GATE, deliberately hand-maintained and deliberately separate
// from the device manifests (devices/<name>/device.mk). A manifest says "this
// device exists / here is its identity"; membership here says "we have VALIDATED
// that flashing this device is safe". The identity values below are the same
// (hardware/software/product) triple the manifest carries - copy them from the
// device's /usr/usrdata/sdk_version.json (or its device.mk DEV_HW/FW/PRODUCT) -
// but a device is added here only after its flash path is proven, so this list is
// intentionally NOT auto-populated from the manifests. A connected device whose
// triple is not listed is detected and reported, but never written to - an
// unknown or newer stock version may have changed the partition map or blown a
// one-way fuse that would brick the open kernel.
//
// TO ADD A DEVICE: prove its flash path first, then append its triple below.
// (The air unit P1_SKY is intentionally absent: its flash path is not yet
// validated.)
package whitelist

// Device is one validated firmware identity, matched exactly against the
// device's sdk_version.json.
type Device struct {
	Name            string // human-readable, for docs and the UI
	ProductVersion  string // sdk_version.json "product_version"
	HardwareVersion string // sdk_version.json "hardware_version"
	SoftwareVersion string // sdk_version.json "software_version"
}

// Devices is the whitelist. Add validated entries here.
var Devices = []Device{
	{
		Name:            "BetaFPV VR04 HD goggle",
		ProductVersion:  "P1_GND_VR04",
		HardwareVersion: "v2.0",
		SoftwareVersion: "1.0.44.rel",
	},
}

// Allowed reports whether the given sdk_version.json identity is whitelisted.
func Allowed(hardware, software, product string) bool {
	for _, d := range Devices {
		if d.HardwareVersion == hardware && d.SoftwareVersion == software && d.ProductVersion == product {
			return true
		}
	}

	return false
}
