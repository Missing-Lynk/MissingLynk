//go:build linux

package netcfg

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
)

// New returns the Linux backend.
func New() Backend { return linux{} }

type linux struct{}

// Candidates enumerates non-loopback USB-ethernet interfaces. The stock gadget
// is RNDIS with a boot-randomized MAC (so it cannot be matched by OUI); the
// reliable signal is that the interface's underlying device sits on the USB bus.
// The "enx"/"usb" name prefixes are a fallback for setups without sysfs.
func (linux) Candidates() ([]Candidate, error) {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}

	var candidates []Candidate
	for _, iface := range ifaces {
		if iface.Flags&net.FlagLoopback != 0 {
			continue
		}

		if !isUSBNet(iface.Name) {
			continue
		}

		candidates = append(candidates, Candidate{Name: iface.Name, MAC: iface.HardwareAddr.String()})
	}

	return candidates, nil
}

// Assign puts hostCIDR on iface and brings it up. It needs root (CAP_NET_ADMIN):
// if the tool is not already root it runs the change through pkexec, which shows a
// graphical authorization prompt, so the GUI itself stays unprivileged. Both steps
// go in one privileged invocation (one prompt); `addr replace` is idempotent, so a
// re-run or a pre-configured interface is not an error.
func (linux) Assign(iface, hostCIDR string) (func() error, error) {
	ipCmd, err := exec.LookPath("ip")
	if err != nil {
		return nil, fmt.Errorf("`ip` command not found: %w", err)
	}

	assign := fmt.Sprintf("%s addr replace %s dev %s && %s link set %s up",
		ipCmd, hostCIDR, iface, ipCmd, iface)
	if out, err := runPrivileged(assign); err != nil {
		return nil, fmt.Errorf("%v: %s", err, strings.TrimSpace(out))
	}

	cleanup := func() error {
		_, err := runPrivileged(fmt.Sprintf("%s addr del %s dev %s", ipCmd, hostCIDR, iface))
		return err
	}

	return cleanup, nil
}

// runPrivileged runs a /bin/sh command line as root: directly when already root,
// otherwise via pkexec (a graphical polkit prompt). pkexec needs an absolute
// program path and does not search PATH.
func runPrivileged(cmdline string) (string, error) {
	if os.Geteuid() == 0 {
		return run("sh", "-c", cmdline)
	}

	if _, err := exec.LookPath("pkexec"); err != nil {
		return "", fmt.Errorf("need root to configure the network, but pkexec is unavailable; " +
			"run the tool as root or bring the link up first with: sudo glue/net/net-up.sh")
	}

	return run("pkexec", "/bin/sh", "-c", cmdline)
}

// isUSBNet reports whether the named interface is backed by a USB device.
func isUSBNet(name string) bool {
	if target, err := os.Readlink("/sys/class/net/" + name + "/device"); err == nil {
		if strings.Contains(target, "usb") {
			return true
		}
	}

	return strings.HasPrefix(name, "enx") || strings.HasPrefix(name, "usb")
}

func run(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).CombinedOutput()
	return string(out), err
}
