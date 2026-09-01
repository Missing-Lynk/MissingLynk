//go:build windows

package netcfg

import (
	"strings"
	"testing"
)

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

// A device with no driver bound has no class and, on older builds, no problem
// property either; neither may stop it being reported.
func TestParseProblemDevices(t *testing.T) {
	one, err := parseJSONList[pnpDevice](
		`{"Name":"RNDIS","Class":null,"Status":"Error","InstanceId":"USB\\VID_1D6B&PID_0104\\6&1","Problem":28}`)
	if err != nil {
		t.Fatalf("parseJSONList(object) = %v", err)
	}

	if len(one) != 1 {
		t.Fatalf("parseJSONList(object) returned %d devices, want 1", len(one))
	}

	if one[0].Class != "" {
		t.Errorf("Class = %q, want empty for a null class", one[0].Class)
	}

	if one[0].Problem == nil || *one[0].Problem != 28 {
		t.Errorf("Problem = %v, want 28", one[0].Problem)
	}

	if one[0].InstanceID != `USB\VID_1D6B&PID_0104\6&1` {
		t.Errorf("InstanceID = %q, want the instance path", one[0].InstanceID)
	}

	none, err := parseJSONList[pnpDevice]("")
	if err != nil || none != nil {
		t.Fatalf("parseJSONList(empty) = %v, %v; want nil, nil", none, err)
	}

	missing, err := parseJSONList[pnpDevice](`{"Name":"Thing","Status":"Unknown","InstanceId":"PCI\\X"}`)
	if err != nil {
		t.Fatalf("parseJSONList(no problem key) = %v", err)
	}

	if missing[0].Problem != nil {
		t.Errorf("Problem = %v, want nil when the property was absent", missing[0].Problem)
	}
}

// The whole point of the adapter report is that a matching adapter and a list with
// nothing in it read differently.
func TestAdapterLines(t *testing.T) {
	none := adapterLines(nil)
	if len(none) != 1 || !strings.Contains(none[0], "no network adapters") {
		t.Fatalf("adapterLines(nil) = %q, want the empty-list line", none)
	}

	unmatched := adapterLines([]adapter{
		{Name: "Ethernet", InterfaceDescription: "Intel(R) I219-V", Status: "Up"},
	})
	joined := strings.Join(unmatched, "\n")
	if !strings.Contains(joined, "Intel(R) I219-V") {
		t.Errorf("adapterLines() = %q, want the adapter listed", joined)
	}

	for _, marker := range usbNetMarkers {
		if !strings.Contains(joined, marker) {
			t.Errorf("adapterLines() = %q, want it to name the marker %q it matched against", joined, marker)
		}
	}

	matched := adapterLines([]adapter{
		{Name: "Ethernet 3", InterfaceDescription: "Remote NDIS Compatible Device", Status: "Up"},
	})
	if strings.Contains(strings.Join(matched, "\n"), "No adapter description contains") {
		t.Errorf("adapterLines() = %q, want no unmatched note when one matched", matched)
	}
}

// A driverless gadget is the case this whole report exists for, so it must carry the
// fix and not just the device.
func TestProblemLines(t *testing.T) {
	clean := problemLines(nil)
	if len(clean) != 1 || !strings.Contains(clean[0], "No device is in an error state") {
		t.Fatalf("problemLines(nil) = %q, want the all-clear line", clean)
	}

	code := 28
	lines := strings.Join(problemLines([]pnpDevice{{
		Name: "RNDIS", Status: "Error", InstanceID: `USB\VID_1D6B&PID_0104\6&1`, Problem: &code,
	}}), "\n")

	for _, want := range []string{"RNDIS", "no class", "problem 28", "no driver installed", "Remote NDIS Compatible"} {
		if !strings.Contains(lines, want) {
			t.Errorf("problemLines() = %q, want it to contain %q", lines, want)
		}
	}

	other := strings.Join(problemLines([]pnpDevice{{
		Name: "Some Camera", Status: "Error", InstanceID: `USB\VID_0000&PID_0000\1`,
	}}), "\n")
	if strings.Contains(other, "Remote NDIS Compatible") {
		t.Errorf("problemLines() = %q, want no RNDIS fix for a non-network device", other)
	}

	if !strings.Contains(other, "no problem code") {
		t.Errorf("problemLines() = %q, want the absent problem code stated", other)
	}
}

// A failed device is only the gadget when it is on the USB bus and names itself as
// something networky; a driverless device has no class to go on.
func TestIsLikelyGadget(t *testing.T) {
	yes := []pnpDevice{
		{Name: "RNDIS", InstanceID: `USB\VID_1D6B&PID_0104\6&1`},
		{Name: "USB Ethernet/RNDIS Gadget", InstanceID: `usb\vid_1d6b&pid_0104\x`},
		{Name: "Artosyn Network Adapter", InstanceID: `USB\X`},
	}
	for _, device := range yes {
		if !isLikelyGadget(device) {
			t.Errorf("isLikelyGadget(%q, %q) = false, want true", device.Name, device.InstanceID)
		}
	}

	no := []pnpDevice{
		{Name: "RNDIS", InstanceID: `PCI\VEN_8086`},
		{Name: "Unknown USB Device (Device Descriptor Request Failed)", InstanceID: `USB\X`},
		{Name: "", InstanceID: `USB\X`},
	}
	for _, device := range no {
		if isLikelyGadget(device) {
			t.Errorf("isLikelyGadget(%q, %q) = true, want false", device.Name, device.InstanceID)
		}
	}
}
