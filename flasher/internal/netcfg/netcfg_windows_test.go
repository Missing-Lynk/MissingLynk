//go:build windows

package netcfg

import "testing"

// An apostrophe in an adapter name terminates the single-quoted PowerShell string
// netshElevated splices it into.
func TestPSQuote(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{name: "plain", in: `interface ip set address name="Ethernet 2" dhcp`,
			want: `interface ip set address name="Ethernet 2" dhcp`},
		{name: "apostrophe is doubled", in: `name="Chris's USB"`, want: `name="Chris''s USB"`},
		{name: "several", in: `a'b'c`, want: `a''b''c`},
		{name: "empty", in: "", want: ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := psQuote(tt.in); got != tt.want {
				t.Fatalf("psQuote(%q) = %q, want %q", tt.in, got, tt.want)
			}
		})
	}
}

// ConvertTo-Json emits an object for one adapter and an array for several. The
// single-adapter case is the normal one here.
func TestParseAdapters(t *testing.T) {
	one, err := parseAdapters(`{"Name":"Ethernet 3","InterfaceDescription":"Remote NDIS Compatible Device","MacAddress":"02-00-00-00-00-01"}`)
	if err != nil {
		t.Fatalf("parseAdapters(object) = %v", err)
	}

	if len(one) != 1 || one[0].Name != "Ethernet 3" {
		t.Fatalf("parseAdapters(object) = %+v, want the single adapter", one)
	}

	many, err := parseAdapters(`[{"Name":"A"},{"Name":"B"}]`)
	if err != nil {
		t.Fatalf("parseAdapters(array) = %v", err)
	}

	if len(many) != 2 {
		t.Fatalf("parseAdapters(array) returned %d adapters, want 2", len(many))
	}

	if _, err := parseAdapters("not json"); err == nil {
		t.Fatal("parseAdapters(garbage) = nil error, want a parse failure")
	}
}

func TestCIDRToIPMask(t *testing.T) {
	ip, mask, err := cidrToIPMask("192.168.3.222/24")
	if err != nil {
		t.Fatalf("cidrToIPMask() = %v", err)
	}

	if ip != "192.168.3.222" || mask != "255.255.255.0" {
		t.Fatalf("cidrToIPMask() = %q, %q; want 192.168.3.222, 255.255.255.0", ip, mask)
	}

	if _, _, err := cidrToIPMask("192.168.3.222"); err == nil {
		t.Fatal("cidrToIPMask(non-CIDR) = nil error, want a parse failure")
	}
}

// The driver description is what separates the gadget from real adapters.
func TestIsUSBNet(t *testing.T) {
	for _, description := range []string{
		"Remote NDIS Compatible Device",
		"USB Ethernet Adapter",
		"Some CDC Ethernet thing",
	} {
		if !isUSBNet(description) {
			t.Errorf("isUSBNet(%q) = false, want true", description)
		}
	}

	for _, description := range []string{
		"Intel(R) Ethernet Connection I219-V",
		"Realtek PCIe GbE Family Controller",
		"",
	} {
		if isUSBNet(description) {
			t.Errorf("isUSBNet(%q) = true, want false", description)
		}
	}
}
