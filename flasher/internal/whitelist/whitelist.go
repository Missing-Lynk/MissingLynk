// Package whitelist is the list of devices ml-flasher is allowed to flash, and
// the single place to edit it.
//
// TO ADD A DEVICE: append a Device to Devices below, with the exact values from
// its /usr/usrdata/sdk_version.json. A connected device whose (hardware,
// software, product) triple is not listed here is detected and reported, but
// never written to - an unknown or newer stock version may have changed the
// partition map or blown a one-way fuse that would brick the open kernel.
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
