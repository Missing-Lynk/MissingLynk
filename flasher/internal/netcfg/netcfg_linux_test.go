//go:build linux

package netcfg

import "testing"

// Wide enough for the names the kernel really produces: rejecting a VLAN or alias
// form would break a working setup.
func TestIfaceNamePattern(t *testing.T) {
	tests := []struct {
		name  string
		iface string
		want  bool
	}{
		{name: "gadget interface", iface: "enx0242ac110002", want: true},
		{name: "predictable name", iface: "enp0s20f0u1", want: true},
		{name: "legacy name", iface: "eth0", want: true},
		{name: "bridge", iface: "br-artosyn", want: true},
		{name: "vlan", iface: "eth0.100", want: true},
		{name: "alias", iface: "eth0:1", want: true},
		{name: "underscore", iface: "usb_0", want: true},

		{name: "empty", iface: "", want: false},
		{name: "quote", iface: "eth0'", want: false},
		{name: "command substitution", iface: "$(id)", want: false},
		{name: "separator", iface: "eth0; id", want: false},
		{name: "space", iface: "eth 0", want: false},
		{name: "slash", iface: "eth0/1", want: false},
		{name: "over the kernel's 15-character limit", iface: "abcdefghijklmnop", want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := ifaceNamePattern.MatchString(tt.iface); got != tt.want {
				t.Fatalf("ifaceNamePattern.MatchString(%q) = %v, want %v", tt.iface, got, tt.want)
			}
		})
	}
}

// Rejected before runPrivileged, which would prompt for a command that cannot work.
func TestAssignRejectsABadInterfaceName(t *testing.T) {
	if _, err := (linux{}).Assign("eth0; id", "192.168.3.222/24"); err == nil {
		t.Fatal("Assign() = nil error, want a rejection for an unexpected interface name")
	}
}

func TestAssignRejectsABadCIDR(t *testing.T) {
	if _, err := (linux{}).Assign("eth0", "192.168.3.222"); err == nil {
		t.Fatal("Assign() = nil error, want a rejection for an address that is not a CIDR")
	}
}
