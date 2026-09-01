//go:build windows

package netcfg

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"os/exec"
	"strings"
	"unicode/utf16"
)

type windows struct{}

// adapter mirrors the Get-NetAdapter fields we care about.
type adapter struct {
	Name                 string
	InterfaceDescription string
	MacAddress           string
	Status               string
}

// pnpDevice mirrors the Get-PnpDevice fields Diagnose reports. Class is empty and
// Problem nil for a device Windows never bound a driver to, which is exactly the
// device this looks for, so neither may be required.
type pnpDevice struct {
	Name       string
	Class      string
	Status     string
	InstanceID string `json:"InstanceId"`
	Problem    *int
}

// usbNetMarkers are the substrings of a driver description that mark an adapter as a
// USB gadget. Diagnose names them when nothing matched, so the list it prints and the
// list isUSBNet tests are the same one.
var usbNetMarkers = []string{"rndis", "remote ndis", "usb ethernet", "usb-ethernet", "cdc ethernet"}

// New returns the Windows backend.
func New() Backend { return windows{} }

// Candidates lists network adapters whose driver description marks them as a USB
// gadget (RNDIS on stock, CDC-Ethernet on the open slot). The stock gadget shows
// up as "Remote NDIS Compatible Device".
//
// Get-NetAdapter lists an adapter only once Windows has bound and started a network
// driver for it. A gadget sitting in Device Manager with no driver is therefore
// absent from this list entirely rather than present and rejected, which is what
// Diagnose exists to say.
func (windows) Candidates() ([]Candidate, error) {
	adapters, err := listAdapters()
	if err != nil {
		return nil, err
	}

	var candidates []Candidate
	for _, a := range adapters {
		if isUSBNet(a.InterfaceDescription) {
			candidates = append(candidates, Candidate{Name: a.Name, MAC: a.MacAddress})
		}
	}

	return candidates, nil
}

// Diagnose reports the two host-side states that hide a plugged-in device: an adapter
// list that holds nothing matching a gadget, and a device Windows enumerated but could
// not start (the yellow warning in Device Manager). Each probe is reported whether or
// not it succeeded, so a failed probe is visible rather than read as "nothing found".
func (windows) Diagnose() []string {
	var lines []string

	adapters, err := listAdapters()
	if err != nil {
		lines = append(lines, fmt.Sprintf("Could not list network adapters: %v", err))
	} else {
		lines = append(lines, adapterLines(adapters)...)
	}

	devices, err := listProblemDevices()
	if err != nil {
		lines = append(lines, fmt.Sprintf("Could not list Device Manager problems: %v", err))
	} else {
		lines = append(lines, problemLines(devices)...)
	}

	return lines
}

// Assign sets a static IPv4 address on the adapter via netsh, elevated through a
// UAC prompt (Start-Process -Verb RunAs) so the GUI itself stays unprivileged.
func (windows) Assign(iface, hostCIDR string) (func() error, error) {
	ip, mask, err := cidrToIPMask(hostCIDR)
	if err != nil {
		return nil, err
	}

	set := fmt.Sprintf(`interface ip set address name="%s" static %s %s`, iface, ip, mask)
	if _, err := netshElevated(set); err != nil {
		return nil, fmt.Errorf("setting the IP on %q failed: %v", iface, err)
	}

	cleanup := func() error {
		_, err := netshElevated(fmt.Sprintf(`interface ip set address name="%s" dhcp`, iface))
		return err
	}

	return cleanup, nil
}

// listAdapters reads every network adapter Windows has a started driver for.
func listAdapters() ([]adapter, error) {
	out, err := powershell("Get-NetAdapter | Select-Object Name,InterfaceDescription,MacAddress,Status | ConvertTo-Json -Compress")
	if err != nil {
		return nil, fmt.Errorf("Get-NetAdapter failed: %v", err)
	}

	return parseAdapters(out)
}

// listProblemDevices reads every present device whose status is not OK, with the
// Device Manager problem code for each. The code comes from a per-device property
// query because the Problem field of Get-PnpDevice is absent on older builds.
func listProblemDevices() ([]pnpDevice, error) {
	const script = `Get-PnpDevice -PresentOnly -ErrorAction Stop |
		Where-Object { $_.Status -ne 'OK' } |
		ForEach-Object {
			[pscustomobject]@{
				Name = $_.FriendlyName
				Class = $_.Class
				Status = [string]$_.Status
				InstanceId = $_.InstanceId
				Problem = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue).Data
			}
		} | ConvertTo-Json -Compress`

	out, err := powershell(script)
	if err != nil {
		return nil, fmt.Errorf("Get-PnpDevice failed: %v", err)
	}

	return parseJSONList[pnpDevice](out)
}

// adapterLines reports the adapter list discovery worked from: every adapter it saw,
// and, when none of them matched, the descriptions it was matching against.
func adapterLines(adapters []adapter) []string {
	if len(adapters) == 0 {
		return []string{"Windows reports no network adapters at all."}
	}

	lines := []string{fmt.Sprintf("Windows reports %d network adapter(s):", len(adapters))}
	matched := false
	for _, a := range adapters {
		mark := ""
		if isUSBNet(a.InterfaceDescription) {
			mark = "  <- matches a USB gadget"
			matched = true
		}

		lines = append(lines, fmt.Sprintf("  %q - %s [%s]%s",
			a.Name, a.InterfaceDescription, a.Status, mark))
	}

	if !matched {
		lines = append(lines, fmt.Sprintf(
			"No adapter description contains any of: %s. A gadget with no driver bound is not an "+
				"adapter at all and is listed below instead.", strings.Join(usbNetMarkers, ", ")))
	}

	return lines
}

// problemLines reports the devices Windows could not start, and names the fix for a
// USB gadget left without a driver, which is what a stock unit looks like on a Windows
// that did not bind RNDIS to it.
func problemLines(devices []pnpDevice) []string {
	if len(devices) == 0 {
		return []string{"No device is in an error state in Device Manager."}
	}

	lines := []string{fmt.Sprintf("%d device(s) Windows could not start:", len(devices))}
	gadget := false
	for _, d := range devices {
		lines = append(lines, "  "+problemLine(d))
		if isLikelyGadget(d) {
			gadget = true
		}
	}

	if gadget {
		lines = append(lines,
			"One of those is a USB network device with no working driver, which is how the stock "+
				"gadget appears when Windows did not bind RNDIS to it. Fix it in Device Manager: "+
				"right-click the device, Update driver, Browse my computer for drivers, Let me pick "+
				"from a list, Network adapters, manufacturer Microsoft, model Remote NDIS Compatible "+
				"Device. Then re-scan.")
	}

	return lines
}

// problemLine renders one failed device: what it calls itself, the class Windows put
// it in, and the problem code with its meaning.
func problemLine(device pnpDevice) string {
	name := device.Name
	if name == "" {
		name = "(unnamed device)"
	}

	class := device.Class
	if class == "" {
		class = "no class"
	}

	problem := "no problem code"
	if device.Problem != nil {
		problem = fmt.Sprintf("problem %d (%s)", *device.Problem, problemDescription(*device.Problem))
	}

	return fmt.Sprintf("%s [%s] %s, %s - %s", name, class, device.Status, problem, device.InstanceID)
}

// problemDescription is the Device Manager meaning of a CM_PROB_* code. Only the
// codes a USB gadget realistically lands on are named; the rest are reported as the
// bare number, which is what a search needs anyway.
func problemDescription(code int) string {
	switch code {
	case 1:
		return "not configured correctly"

	case 10:
		return "cannot start"

	case 18:
		return "the drivers need reinstalling"

	case 19:
		return "its registry configuration is damaged"

	case 22:
		return "disabled"

	case 24:
		return "not present, not working, or missing a driver"

	case 28:
		return "no driver installed"

	case 31:
		return "Windows cannot load its drivers"

	case 37:
		return "the driver returned a failure"

	case 39:
		return "the driver is corrupted or missing"

	case 43:
		return "the device reported a problem"

	case 45:
		return "not currently connected"

	case 52:
		return "the driver's signature could not be verified"
	}

	return "see the Device Manager code"
}

// isLikelyGadget reports whether a failed device is a USB device that was trying to be
// a network interface. The instance ID settles the bus; the name is all there is to go
// on for the function, since a device with no driver has no class.
func isLikelyGadget(device pnpDevice) bool {
	if !strings.HasPrefix(strings.ToUpper(device.InstanceID), `USB\`) {
		return false
	}

	name := strings.ToLower(device.Name)
	for _, marker := range append([]string{"ndis", "ethernet", "network", "gadget"}, usbNetMarkers...) {
		if strings.Contains(name, marker) {
			return true
		}
	}

	return false
}

// isUSBNet reports whether an adapter's driver description marks it as a USB
// network gadget.
func isUSBNet(description string) bool {
	d := strings.ToLower(description)
	for _, marker := range usbNetMarkers {
		if strings.Contains(d, marker) {
			return true
		}
	}

	return false
}

// parseAdapters decodes Get-NetAdapter -Compress JSON, which is an object for a
// single adapter and an array for several.
func parseAdapters(out string) ([]adapter, error) {
	return parseJSONList[adapter](out)
}

// parseJSONList decodes ConvertTo-Json -Compress output, which is an object for a
// single item, an array for several, and empty for none.
func parseJSONList[T any](out string) ([]T, error) {
	out = strings.TrimSpace(out)
	if out == "" {
		return nil, nil
	}

	var many []T
	if err := json.Unmarshal([]byte(out), &many); err == nil {
		return many, nil
	}

	var one T
	if err := json.Unmarshal([]byte(out), &one); err != nil {
		return nil, fmt.Errorf("parsing PowerShell output: %w", err)
	}

	return []T{one}, nil
}

// cidrToIPMask splits "192.168.3.222/24" into the host IP and a dotted netmask,
// the form netsh wants.
func cidrToIPMask(cidr string) (ip, mask string, err error) {
	host, network, err := net.ParseCIDR(cidr)
	if err != nil {
		return "", "", err
	}

	m := network.Mask
	if len(m) != net.IPv4len {
		return "", "", fmt.Errorf("expected an IPv4 CIDR, got %q", cidr)
	}

	return host.String(), fmt.Sprintf("%d.%d.%d.%d", m[0], m[1], m[2], m[3]), nil
}

// netshElevated runs `netsh <args>` elevated. Start-Process -Verb RunAs shows the
// UAC prompt; -Wait -PassThru lets us surface netsh's exit code as this process's.
//
// args carries the adapter name, which is user-renamable and may contain an
// apostrophe ("Chris's USB"). Spaces need no handling: -ArgumentList gets one string,
// passed through verbatim, and the name already carries the double quotes netsh wants.
func netshElevated(args string) (string, error) {
	script := fmt.Sprintf(
		`$p = Start-Process -FilePath 'netsh' -Verb RunAs -PassThru -Wait -ArgumentList '%s'; exit $p.ExitCode`,
		psQuote(args))
	return powershell(script)
}

// psQuote escapes a value for a single-quoted PowerShell string: apostrophes double.
func psQuote(s string) string {
	return strings.ReplaceAll(s, "'", "''")
}

// powershell runs a script via -EncodedCommand (base64 of UTF-16LE), which avoids
// all shell-quoting of the script text. stdout and stderr are captured separately:
// merging them lets PowerShell's CLIXML error/progress preamble (which starts with
// "#< CLIXML") corrupt the stdout we parse as JSON. stderr is folded into the error
// instead. A leading $ProgressPreference stops progress records being emitted at all.
func powershell(script string) (string, error) {
	script = "$ProgressPreference='SilentlyContinue';" + script

	units := utf16.Encode([]rune(script))
	buf := make([]byte, len(units)*2)
	for i, u := range units {
		buf[i*2] = byte(u)
		buf[i*2+1] = byte(u >> 8)
	}
	encoded := base64.StdEncoding.EncodeToString(buf)

	cmd := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if err != nil {
		if msg := strings.TrimSpace(stderr.String()); msg != "" {
			err = fmt.Errorf("%v: %s", err, msg)
		}
	}

	return stdout.String(), err
}
