// Package devconf holds flasher-facing device configuration derived from the
// per-device manifests and rootfs profiles. devices.json is generated at build
// time from devices/<name>/device.mk and rootfs/devices/<name>/board.conf, then
// embedded into the binary, so the flasher remains a self-contained executable.
package devconf

import (
	_ "embed"
	"encoding/json"
	"fmt"
)

//go:embed devices.json
var devicesJSON []byte

// Device maps a device's sdk_version.json product_version to the fixed
// USB-gadget address of its open slot B (board.conf GADGET_IP).
type Device struct {
	Product string `json:"product"`
	OpenIP  string `json:"open_ip"`
}

var (
	// OpenIP maps product_version -> open slot B IP.
	OpenIP map[string]string

	// ProductByOpenIP is the reverse lookup, used when we connected to an
	// open slot and need to know which device it belongs to.
	ProductByOpenIP map[string]string
)

func init() {
	var devices []Device
	if err := json.Unmarshal(devicesJSON, &devices); err != nil {
		panic(fmt.Sprintf("devconf: cannot parse embedded devices.json: %v", err))
	}

	OpenIP = make(map[string]string, len(devices))
	ProductByOpenIP = make(map[string]string, len(devices))
	for _, d := range devices {
		OpenIP[d.Product] = d.OpenIP
		ProductByOpenIP[d.OpenIP] = d.Product
	}
}
