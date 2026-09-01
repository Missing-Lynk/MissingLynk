// Finding the device and connecting to it: the seam over the device and netcfg
// packages, host-link bring-up, and the sweep that locates the running slot.
package flow

import (
	"context"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/devconf"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/device"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/netcfg"
)

// deviceClient is the device-side surface these flows use, as an interface so tests
// can substitute a fake. *device.Client is the only production implementation.
//
// RunStream has no caller in this package: it is here because a deviceClient is handed
// to mlflash.New, and mlflash streams a write's output as it arrives. Dropping it
// stops this package satisfying mlflash.Runner.
type deviceClient interface {
	Run(cmd string) (string, error)
	RunStream(cmd string, onLine func(string)) error
	Push(content io.Reader, remotePath, mode string) error
	ReadSDKVersion() (*device.SDKVersion, error)
	Close() error
}

// Entry points as variables so tests can substitute them. rebootAndWait drives all
// three, so all three must be replaceable to exercise its loop without hardware.
var (
	dialDevice = func(ctx context.Context, ip, user, password string, timeout time.Duration) (deviceClient, error) {
		client, err := device.DialContext(ctx, ip, user, password, timeout)
		if err != nil {
			return nil, err // a typed nil pointer here would make a non-nil interface
		}

		return client, nil
	}

	reachable = device.ReachableContext

	newBackend = netcfg.New
)

// defaultOpenIPs returns every known open-slot address, sorted for stable probing.
func defaultOpenIPs() []string {
	seen := map[string]bool{}
	for _, ip := range devconf.OpenIP {
		seen[ip] = true
	}

	ips := make([]string, 0, len(seen))
	for ip := range seen {
		ips = append(ips, ip)
	}

	return ips
}

// productFromOpenIP maps a connected open-slot address back to the device's
// product_version. The open slot's IP is fixed per device by board.conf, so
// this is reliable even when the vendor sdk_version.json is absent (open slot B).
func productFromOpenIP(ip string) string {
	return devconf.ProductByOpenIP[ip]
}

// connect finds the device on whichever slot it is running. The stock slot answers
// at stockIP with the stock password; the open slot answers at one of the open IPs
// with the open password (board.conf gives each device its own IP). Only addresses
// whose SSH port actually answers are dialled, so slots that are not running cost
// one short probe each instead of a full dial timeout. The returned connectedIP is
// the address we actually reached, and alreadyOpen reports whether it is an open
// slot.
func connect(ctx context.Context, stockIP string, openIPs []string) (client deviceClient, alreadyOpen bool, connectedIP string, err error) {
	type attempt struct {
		ip       string
		password string
		open     bool
	}

	attempts := []attempt{{stockIP, device.StockPassword, false}}
	for _, ip := range openIPs {
		attempts = append(attempts, attempt{ip, device.OpenPassword, true})
	}

	var firstErr error
	for _, a := range attempts {
		// One probe plus one dial per known address, so cancellation is checked between
		// attempts rather than only after the last.
		if err := ctx.Err(); err != nil {
			return nil, false, "", err
		}

		if !reachable(ctx, a.ip, 2*time.Second) {
			continue
		}

		cli, dialErr := dialDevice(ctx, a.ip, "root", a.password, 10*time.Second)
		if dialErr == nil {
			return cli, a.open, a.ip, nil
		}

		if firstErr == nil {
			firstErr = fmt.Errorf("%s: %w", a.ip, dialErr)
		}
	}

	if err := ctx.Err(); err != nil {
		return nil, false, "", err
	}

	if firstErr != nil {
		return nil, false, "", firstErr
	}

	return nil, false, "", fmt.Errorf("no device answered SSH at %s or %v", stockIP, openIPs)
}

// firstReachable returns the first address whose SSH port answers within timeout,
// or "" if none do. The device sits at the stock address on slot A and the open
// address on slot B, so link checks probe both.
func firstReachable(ctx context.Context, ips []string, timeout time.Duration) string {
	for _, ip := range ips {
		if reachable(ctx, ip, timeout) {
			return ip
		}
	}

	return ""
}

// deviceName reads the human device name from the device-tree model (e.g.
// "Artosyn Proxima-9311 (BetaFPV VR04 goggle)"), which our DTB carries and is
// present on the open slot. Falls back to the vendor product_version, then the
// hostname. Empty if none can be read.
func deviceName(client deviceClient) string {
	if out, err := client.Run("cat /proc/device-tree/model 2>/dev/null"); err == nil {
		// The device-tree property is NUL-terminated; trim NULs and whitespace.
		if model := strings.TrimSpace(strings.Trim(out, "\x00")); model != "" {
			return model
		}
	}

	if sdk, err := client.ReadSDKVersion(); err == nil && sdk.ProductVersion != "" {
		return sdk.ProductVersion
	}

	if out, err := client.Run("cat /etc/hostname 2>/dev/null"); err == nil {
		if host := strings.TrimSpace(out); host != "" {
			return host
		}
	}

	return ""
}

// ensureLink enforces the single-device rule and makes the device reachable,
// assigning the host IP if it is not already up.
func ensureLink(ctx context.Context, opt Options, emit Emit) error {
	backend := newBackend()
	candidates, err := backend.Candidates()
	if err != nil {
		return fail(emit, fmt.Errorf("scanning network interfaces: %w", err))
	}

	switch {
	case len(candidates) > 1:
		names := make([]string, len(candidates))
		for i, candidate := range candidates {
			names[i] = candidate.Name
		}

		return fail(emit, fmt.Errorf(
			"found %d candidate USB devices (%v); connect exactly one device and unplug the rest",
			len(candidates), names))

	case len(candidates) == 0:
		if firstReachable(ctx, deviceAddrs(opt), 2*time.Second) != "" {
			emit(Event{Level: LevelWarn, Msg: "no USB gadget interface detected, but the device is reachable; continuing"})
			return nil
		}

		return fail(emit, fmt.Errorf("no device found - is it plugged in over USB and powered on?"))
	}

	candidate := candidates[0]
	emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("Found gadget interface %s (%s)", candidate.Name, candidate.MAC)})

	if firstReachable(ctx, deviceAddrs(opt), 2*time.Second) != "" {
		emit(Event{Level: LevelInfo, Msg: "Device already reachable; network is up"})
		return nil
	}

	emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("Assigning %s to %s (may prompt for authorization)", opt.HostCIDR, candidate.Name)})
	cleanup, err := backend.Assign(candidate.Name, opt.HostCIDR)
	if err != nil {
		return fail(emit, fmt.Errorf("configuring the network on %s failed: %w", candidate.Name, err))
	}
	_ = cleanup // the address is left in place for the duration of the session

	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if firstReachable(ctx, deviceAddrs(opt), 2*time.Second) != "" {
			emit(Event{Level: LevelInfo, Msg: "Device reachable"})
			return nil
		}

		select {
		case <-ctx.Done():
			return fail(emit, ctx.Err())
		case <-time.After(1 * time.Second):
		}
	}

	return fail(emit, fmt.Errorf("device did not become reachable at %s or %v after configuring the link",
		opt.DeviceIP, opt.OpenIPs))
}

// deviceAddrs are the addresses the device may answer on, stock first: the stock
// slot at DeviceIP (.100) and the open slot at any of the OpenIPs. The running
// slot determines which one is live, so link checks probe all candidates.
func deviceAddrs(opt Options) []string {
	addrs := []string{opt.DeviceIP}
	return append(addrs, opt.OpenIPs...)
}

// candidateNames returns the names of every USB gadget interface currently
// enumerated, for reattach and progress logging.
func candidateNames(backend netcfg.Backend) []string {
	candidates, err := backend.Candidates()
	if err != nil {
		return nil
	}

	names := make([]string, len(candidates))
	for i, candidate := range candidates {
		names[i] = candidate.Name
	}

	return names
}
