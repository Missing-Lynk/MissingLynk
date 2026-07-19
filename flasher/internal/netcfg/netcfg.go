// Package netcfg is the only platform-specific code: it finds the USB-ethernet
// gadget interface(s) an Artosyn unit presents and assigns the host-side static
// IP the stock firmware needs (it runs no DHCP). One Backend per OS.
package netcfg

// Candidate is a host network interface that could be an Artosyn USB gadget.
type Candidate struct {
	// Name is the OS interface name (Linux "enx<mac>"; Windows adapter name).
	Name string
	// MAC is the interface hardware address, for display.
	MAC string
}

// Backend brings the host side of the gadget link up on one OS.
type Backend interface {
	// Candidates returns every USB-ethernet interface that could be an Artosyn device.
	// Discovery counts these to enforce the single-device rule.
	Candidates() ([]Candidate, error)

	// Assign puts hostCIDR (e.g. "192.168.3.222/24") on iface and brings it up,
	// returning a cleanup that removes the address again. An address that is
	// already present is not an error.
	Assign(iface, hostCIDR string) (cleanup func() error, err error)
}
