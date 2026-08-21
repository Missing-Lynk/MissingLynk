package flow

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/Missing-Lynk/MissingLynk/flasher/internal/devconf"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/device"
	"github.com/Missing-Lynk/MissingLynk/flasher/internal/netcfg"
)

// anOpenDevice returns a product that has an open-slot address, and that address.
func anOpenDevice(t *testing.T) (product, ip string) {
	t.Helper()

	for product, ip := range devconf.OpenIP {
		return product, ip
	}

	t.Skip("the embedded devconf lists no devices")
	return "", ""
}

// fastWait shrinks the post-reboot poll cadence so a whole wait runs in
// milliseconds, and restores it afterwards.
func fastWait(t *testing.T, dhcpGrace, deadline time.Duration) {
	t.Helper()

	old := waitTimings
	t.Cleanup(func() { waitTimings = old })
	waitTimings.settle = time.Millisecond
	waitTimings.poll = time.Millisecond
	waitTimings.dhcpGrace = dhcpGrace
	waitTimings.deadline = deadline
}

// uptimeReply is what `cat /proc/uptime` prints after the device has been up for d.
func uptimeReply(d time.Duration) string {
	return fmt.Sprintf("%.2f 0.00\n", d.Seconds())
}

// waitForCommand waits for the fake device to receive a command containing match.
// The reboot command is fired in a goroutine, so it lands asynchronously.
func waitForCommand(t *testing.T, client *fakeClient, match string) {
	t.Helper()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if client.didRun(match) {
			return
		}

		time.Sleep(time.Millisecond)
	}

	t.Fatalf("the device never received a command containing %q; got %v", match, client.commands())
}

func TestLandingForNamesTheActivatedFirmware(t *testing.T) {
	product, openIP := anOpenDevice(t)
	opt := Options{}
	if err := opt.applyDefaults(); err != nil {
		t.Fatalf("applying defaults: %v", err)
	}

	tests := []struct {
		name          string
		running       firmware
		content       string
		connectedIP   string
		wantAddress   string
		wantActivated firmware
		wantRebootCmd string
		wantPassword  string
		wantDHCP      bool
		wantSame      bool
	}{
		{
			name: "stock running, flip to the open slot", running: firmwareStock, content: contentOpen,
			connectedIP: DefaultDeviceIP, wantAddress: openIP, wantActivated: firmwareOpen,
			wantRebootCmd: stockRebootCmd, wantPassword: device.OpenPassword, wantDHCP: true,
		},
		{
			name: "open running, flip back to the vendor slot", running: firmwareOpen, content: contentVendor,
			connectedIP: openIP, wantAddress: DefaultDeviceIP, wantActivated: firmwareStock,
			wantRebootCmd: openRebootCmd, wantPassword: device.StockPassword, wantDHCP: false,
		},
		{
			name: "open running, flip to the open slot answering where we are", running: firmwareOpen,
			content: contentOpen, connectedIP: openIP, wantAddress: openIP, wantActivated: firmwareOpen,
			wantRebootCmd: openRebootCmd, wantPassword: device.OpenPassword, wantDHCP: true, wantSame: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			land, err := landingFor(tt.running, tt.content, product, tt.connectedIP, opt)
			if err != nil {
				t.Fatalf("landingFor: %v", err)
			}

			if land.address != tt.wantAddress {
				t.Errorf("address = %q, want %q", land.address, tt.wantAddress)
			}

			if land.activated != tt.wantActivated {
				t.Errorf("activated firmware = %v, want %v", land.activated, tt.wantActivated)
			}

			if got := land.running.rebootCmd(); got != tt.wantRebootCmd {
				t.Errorf("reboot command = %q, want %q", got, tt.wantRebootCmd)
			}

			if got := land.activated.password(); got != tt.wantPassword {
				t.Errorf("password = %q, want %q", got, tt.wantPassword)
			}

			if got := land.activated.isDHCPServer(); got != tt.wantDHCP {
				t.Errorf("isDHCPServer = %v, want %v", got, tt.wantDHCP)
			}

			if land.isSameAddress != tt.wantSame {
				t.Errorf("isSameAddress = %v, want %v", land.isSameAddress, tt.wantSame)
			}
		})
	}
}

func TestRunningFirmwareFollowsTheConnectedSlot(t *testing.T) {
	if got := runningFirmware(true); got != firmwareOpen {
		t.Errorf("an open connection reported firmware %v, want the open firmware", got)
	}

	if got := runningFirmware(false); got != firmwareStock {
		t.Errorf("a stock connection reported firmware %v, want the stock firmware", got)
	}
}

// An open target on an unnamed product has no address to wait on, unless we are
// already connected to an open slot (both open slots answer at the same address).
func TestLandingForRejectsAnUnknownProduct(t *testing.T) {
	opt := Options{}
	if err := opt.applyDefaults(); err != nil {
		t.Fatalf("applying defaults: %v", err)
	}

	if _, err := landingFor(firmwareStock, contentOpen, "P1_NOT_A_PRODUCT", DefaultDeviceIP, opt); err == nil {
		t.Fatal("expected an error for a product with no open-slot address")
	}

	land, err := landingFor(firmwareOpen, contentOpen, "P1_NOT_A_PRODUCT", "192.168.3.199", opt)
	if err != nil {
		t.Fatalf("an open slot should fall back to the connected address: %v", err)
	}

	if land.address != "192.168.3.199" || !land.isSameAddress {
		t.Errorf("address = %q (same = %v), want the connected address", land.address, land.isSameAddress)
	}
}

func TestLandingForRefusesAnUnrecognizedSlot(t *testing.T) {
	opt := Options{}
	if err := opt.applyDefaults(); err != nil {
		t.Fatalf("applying defaults: %v", err)
	}

	for _, content := range []string{"empty", "unknown", ""} {
		if _, err := landingFor(firmwareStock, content, "P1_GND_VR04", DefaultDeviceIP, opt); err == nil {
			t.Errorf("slot content %q was accepted as a landing", content)
		}
	}
}

func TestRebootAndWaitReturnsWhenTheActivatedFirmwareAnswers(t *testing.T) {
	product, openIP := anOpenDevice(t)
	fastWait(t, 0, 2*time.Second)

	h := (&harness{reachableIPs: map[string]bool{openIP: true}}).install(t)
	emit, events := collect()
	opt := Options{}
	if err := opt.applyDefaults(); err != nil {
		t.Fatalf("applying defaults: %v", err)
	}

	land, err := landingFor(firmwareStock, contentOpen, product, DefaultDeviceIP, opt)
	if err != nil {
		t.Fatalf("landingFor: %v", err)
	}

	if err := rebootAndWait(context.Background(), opt, h.client, land, emit); err != nil {
		t.Fatalf("rebootAndWait: %v", err)
	}

	waitForCommand(t, h.client, "ar_wdt_service")
	if h.client.didRun("wdt-reset") {
		t.Error("the open slot's reboot command was used to reset the stock firmware")
	}

	if !strings.Contains(logOf(events), "back up and reachable") {
		t.Errorf("the log never reported the device back:\n%s", logOf(events))
	}
}

// The firmware being activated answers where we are already connected, so an SSH
// answer alone is not proof of a reboot: the session must also report a fresh uptime.
func TestRebootAndWaitRejectsThePreRebootSession(t *testing.T) {
	_, openIP := anOpenDevice(t)
	fastWait(t, 0, 150*time.Millisecond)

	client := newFakeClient().on("/proc/uptime", uptimeReply(9*time.Hour), nil)
	h := (&harness{client: client, reachableIPs: map[string]bool{openIP: true}}).install(t)
	emit, events := collect()

	land := landing{running: firmwareOpen, activated: firmwareOpen, address: openIP, isSameAddress: true}
	err := rebootAndWait(context.Background(), Options{HostCIDR: DefaultHostCIDR}, h.client, land, emit)
	if err == nil {
		t.Fatal("a device that never rebooted was accepted as back")
	}

	if !strings.Contains(logOf(events), "still answers from the pre-reboot session") {
		t.Errorf("the stale session was not reported:\n%s", logOf(events))
	}
}

func TestRebootAndWaitAcceptsARebootedUptime(t *testing.T) {
	_, openIP := anOpenDevice(t)
	fastWait(t, 0, 2*time.Second)

	client := newFakeClient().on("/proc/uptime", uptimeReply(3*time.Second), nil)
	h := (&harness{client: client, reachableIPs: map[string]bool{openIP: true}}).install(t)
	emit, _ := collect()

	land := landing{running: firmwareOpen, activated: firmwareOpen, address: openIP, isSameAddress: true}
	if err := rebootAndWait(context.Background(), Options{HostCIDR: DefaultHostCIDR}, h.client, land, emit); err != nil {
		t.Fatalf("a rebooted session was not accepted: %v", err)
	}
}

// A firmware that serves no DHCP leaves the re-enumerated gadget interface with no
// address, so the host IP is reattached to it as soon as it appears.
func TestRebootAndWaitReattachesTheHostIPForANonDHCPFirmware(t *testing.T) {
	fastWait(t, 0, 150*time.Millisecond)

	backend := &fakeBackend{candidates: []netcfg.Candidate{{Name: "enxrebooted", MAC: "02:00:00:00:00:09"}}}
	h := (&harness{reachableIPs: map[string]bool{}, backend: backend}).install(t)
	emit, events := collect()

	land := landing{running: firmwareOpen, activated: firmwareStock, address: DefaultDeviceIP}
	if err := rebootAndWait(context.Background(), Options{HostCIDR: DefaultHostCIDR}, h.client, land, emit); err == nil {
		t.Fatal("an unreachable device was reported as back")
	}

	if !contains(backend.assigned, "enxrebooted") {
		t.Errorf("the host IP was never reattached; assigned = %v", backend.assigned)
	}

	if strings.Count(logOf(events), "Reattaching the host network") != 1 {
		t.Errorf("the interface should be assigned exactly once:\n%s", logOf(events))
	}
}

// A DHCP-serving firmware gets its grace period first, so no authorization prompt
// is raised for an interface DHCP is about to configure.
func TestRebootAndWaitWaitsOutDHCPBeforeReattaching(t *testing.T) {
	fastWait(t, time.Hour, 150*time.Millisecond)

	backend := &fakeBackend{candidates: []netcfg.Candidate{{Name: "enxrebooted", MAC: "02:00:00:00:00:09"}}}
	h := (&harness{reachableIPs: map[string]bool{}, backend: backend}).install(t)
	emit, _ := collect()

	land := landing{running: firmwareStock, activated: firmwareOpen, address: "192.168.3.101"}
	if err := rebootAndWait(context.Background(), Options{HostCIDR: DefaultHostCIDR}, h.client, land, emit); err == nil {
		t.Fatal("an unreachable device was reported as back")
	}

	if len(backend.assigned) != 0 {
		t.Errorf("the host IP was reattached during the DHCP grace period; assigned = %v", backend.assigned)
	}
}

func TestRebootAndWaitAbortsOnCancellation(t *testing.T) {
	fastWait(t, 0, time.Hour)

	h := (&harness{reachableIPs: map[string]bool{}}).install(t)
	emit, _ := collect()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	land := landing{running: firmwareStock, activated: firmwareOpen, address: "192.168.3.101"}
	err := rebootAndWait(ctx, Options{HostCIDR: DefaultHostCIDR}, h.client, land, emit)
	if err == nil {
		t.Fatal("a cancelled wait returned success")
	}

	if !strings.Contains(err.Error(), context.Canceled.Error()) {
		t.Errorf("error = %v, want the cancellation", err)
	}
}
