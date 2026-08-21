// Rebooting into the newly activated slot and waiting for it to come back, including
// the host-side reattach the re-enumerated gadget needs.
package flow

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// The post-reboot poll cadence, as one value so tests can shrink it (like
// dialDevice and reachable) and drive the whole wait loop in milliseconds.
var waitTimings = struct {
	// settle lets the SoC reset and drop the USB link before the first poll, so
	// the old interface is gone and only the re-enumerated one is a candidate.
	settle time.Duration

	// poll is the gap between reachability attempts.
	poll time.Duration

	// dhcpGrace is how long a DHCP-serving firmware gets to configure the host on
	// its own before the host IP is reattached statically.
	dhcpGrace time.Duration

	// deadline bounds the whole wait.
	deadline time.Duration
}{
	settle:    6 * time.Second,
	poll:      2 * time.Second,
	dhcpGrace: 8 * time.Second,
	deadline:  180 * time.Second,
}

// rebootAndWait triggers the watchdog reboot (never `reboot`; see the reboot-
// command constants) and waits for land to come back: the activated firmware
// answering SSH at land.address with its own password. The connection drops as
// the SoC resets, so the reboot command's error is expected and ignored.
//
// The reboot command belongs to the firmware that is RUNNING, while the address,
// password and DHCP behaviour belong to the firmware being ACTIVATED; landingFor
// is what keeps those two apart. Waiting on the wrong address would never see the
// reboot complete: the stock slot answers at .100 and an open slot at the unit's
// fixed board.conf address (.101 goggle, .102 air).
//
// The USB gadget re-enumerates on reboot with a boot-randomized MAC, so the host
// sees a NEW interface (enx<newmac>); the host IP assigned to the pre-reboot
// interface does not carry over. The firmware we land on may also serve no DHCP,
// so the fresh interface can come up with no address at all and stay unreachable
// forever. This reattaches the host IP to the re-enumerated interface, which is
// what lets a switch back to the vendor slot be detected as complete. A
// DHCP-serving firmware gets waitTimings.dhcpGrace to configure the host first,
// which avoids a needless authorization prompt; anything else is reattached as
// soon as its interface appears.
func rebootAndWait(ctx context.Context, opt Options, client deviceClient, land landing, emit Emit) error {
	emit(Event{Level: LevelStep, Msg: "Rebooting into the newly activated firmware"})

	// The reboot command tears the SoC down mid-session, so this SSH call never
	// returns cleanly: it blocks on the dead transport until the host's TCP timeout
	// (up to a minute, as no SSH keepalive is set). Waiting on it would stall the
	// whole reconnect - including the host-IP reattach - for that long, so fire it
	// in the background and move straight to the wait loop. The command is delivered
	// before the SoC resets; the deferred client.Close eventually unblocks the call.
	go func() { _, _ = client.Run(land.running.rebootCmd()) }()
	issued := time.Now()

	emit(Event{Level: LevelInfo, Msg: "Waiting for the device to come back (this can take a minute)"})

	if err := sleep(ctx, waitTimings.settle); err != nil {
		return err
	}

	backend := newBackend()
	assigned := map[string]bool{}
	lastIfaces := ""
	reattachAfter := time.Now()

	if land.activated.isDHCPServer() {
		reattachAfter = reattachAfter.Add(waitTimings.dhcpGrace)
	}

	deadline := time.Now().Add(waitTimings.deadline)
	for time.Now().Before(deadline) {
		if reachable(ctx, land.address, 2*time.Second) {
			if c, err := dialDevice(ctx, land.address, "root", land.activated.password(), 5*time.Second); err == nil {
				rebooted := !land.isSameAddress || hasRebooted(c, time.Since(issued))
				_ = c.Close()
				if rebooted {
					emit(Event{Level: LevelInfo, Msg: "The device is back up and reachable"})
					return nil
				}

				emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("%s still answers from the pre-reboot session", land.address)})
			} else {
				emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("%s answers but SSH is not ready yet", land.address)})
			}
		} else if time.Now().After(reattachAfter) {
			// Not reachable and no DHCP took hold: reattach the host IP to the
			// re-enumerated gadget interface. Each interface name is assigned once,
			// so a boot-randomized MAC is picked up without repeating the prompt.
			ifaces := candidateNames(backend)
			if joined := strings.Join(ifaces, ", "); joined != lastIfaces {
				lastIfaces = joined
				if joined == "" {
					emit(Event{Level: LevelInfo, Msg: "Waiting for the re-enumerated USB gadget interface"})
				} else {
					emit(Event{Level: LevelInfo, Msg: "Gadget interface(s): " + joined})
				}
			}

			for _, iface := range ifaces {
				if assigned[iface] {
					continue
				}

				emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("Reattaching the host network to %s", iface)})
				if _, err := backend.Assign(iface, opt.HostCIDR); err != nil {
					emit(Event{Level: LevelWarn, Msg: fmt.Sprintf("reattaching the host network to %s failed: %v", iface, err)})
				} else {
					assigned[iface] = true
				}

				break
			}
		}

		if err := sleep(ctx, waitTimings.poll); err != nil {
			return err
		}
	}

	return fmt.Errorf("the device did not come back on the newly activated firmware within the timeout; " +
		"the slot flip itself is already committed, so power-cycle the device to (re)try booting " +
		"the newly activated slot (the stock firmware slot is never modified)")
}

// hasRebooted reports whether the session on the far end of client came up after the
// reboot command went out, by comparing /proc/uptime with how long ago that was. A
// device that ignored the reboot has been up for its whole pre-reboot session, which
// is longer than sinceReboot; a rebooted one has not. slack absorbs the reboot command's
// own delay and the poll interval. An unreadable or unparseable uptime counts as
// rebooted: this check only exists to catch a device that is still the old session, and
// must never strand a reconnect that has genuinely succeeded.
func hasRebooted(client deviceClient, sinceReboot time.Duration) bool {
	out, err := client.Run("cat /proc/uptime")
	if err != nil {
		return true
	}

	fields := strings.Fields(strings.TrimSpace(out))
	if len(fields) == 0 {
		return true
	}

	uptime, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return true
	}

	const slack = 15 * time.Second
	return time.Duration(uptime*float64(time.Second)) < sinceReboot+slack
}

// sleep waits for d, or returns ctx's error if cancelled first. An error rather than
// a bool, so the polarity is not left to the reader.
func sleep(ctx context.Context, d time.Duration) error {
	select {
	case <-ctx.Done():
		return ctx.Err()

	case <-time.After(d):
		return nil
	}
}

// fail emits an error event and returns the error.
func fail(emit Emit, err error) error {
	emit(Event{Level: LevelError, Msg: err.Error()})
	return err
}
