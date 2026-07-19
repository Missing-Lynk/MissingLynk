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

// New returns the Windows backend.
func New() Backend { return windows{} }

type windows struct{}

// adapter mirrors the Get-NetAdapter fields we care about.
type adapter struct {
	Name                 string
	InterfaceDescription string
	MacAddress           string
}

// Candidates lists network adapters whose driver description marks them as a USB
// gadget (RNDIS on stock, CDC-Ethernet on the open slot). The stock gadget shows
// up as "Remote NDIS Compatible Device".
func (windows) Candidates() ([]Candidate, error) {
	out, err := powershell("Get-NetAdapter | Select-Object Name,InterfaceDescription,MacAddress | ConvertTo-Json -Compress")
	if err != nil {
		return nil, fmt.Errorf("Get-NetAdapter failed: %v", err)
	}

	adapters, err := parseAdapters(out)
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

// isUSBNet reports whether an adapter's driver description marks it as a USB
// network gadget.
func isUSBNet(description string) bool {
	d := strings.ToLower(description)
	for _, marker := range []string{"rndis", "remote ndis", "usb ethernet", "usb-ethernet", "cdc ethernet"} {
		if strings.Contains(d, marker) {
			return true
		}
	}

	return false
}

// parseAdapters decodes Get-NetAdapter -Compress JSON, which is an object for a
// single adapter and an array for several.
func parseAdapters(out string) ([]adapter, error) {
	out = strings.TrimSpace(out)
	if out == "" {
		return nil, nil
	}

	var many []adapter
	if err := json.Unmarshal([]byte(out), &many); err == nil {
		return many, nil
	}

	var one adapter
	if err := json.Unmarshal([]byte(out), &one); err != nil {
		return nil, fmt.Errorf("parsing Get-NetAdapter output: %w", err)
	}

	return []adapter{one}, nil
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
func netshElevated(args string) (string, error) {
	script := fmt.Sprintf(
		`$p = Start-Process -FilePath 'netsh' -Verb RunAs -PassThru -Wait -ArgumentList '%s'; exit $p.ExitCode`,
		args)
	return powershell(script)
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
