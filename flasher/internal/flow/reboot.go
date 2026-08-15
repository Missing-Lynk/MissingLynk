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

// Per-slot reboot commands. A plain `reboot` is a no-op on this hardware (sysrq
// is out); the reliable reset is the watchdog, fired WITHOUT setting the SPL
// reboot-reason flag so the SPL Falcon-boots the GPT-active slot (setting that
// flag would instead drop to U-Boot).
const (
	// The vendor slot has ar_wdt_service: arm the watchdog for 1s and stop petting
	// it. The connection drops as the SoC resets, so the command error is ignored.
	stockRebootCmd = "sync; /usr/bin/ar_wdt_service -t 1 >/dev/null 2>&1 & sleep 1; killall ar_wdt_service"

	// The open slot ships the self-contained wdt-reset helper.
	openRebootCmd = "sync; /usr/local/bin/wdt-reset"
)

// rebootAndWait triggers the watchdog reboot (never `reboot`; see the reboot-
// command constants) and waits for the now-active slot to reappear as a
// reachable device that answers SSH with targetPassword. The connection drops as
// the SoC resets, so the reboot command's error is expected and ignored.
//
// The USB gadget re-enumerates on reboot with a boot-randomized MAC, so the host
// sees a NEW interface (enx<newmac>); the host IP assigned to the pre-reboot
// interface does not carry over. The slot we land on may also serve no DHCP, so
// the fresh interface can come up with no address at all and stay unreachable
// forever. This reattaches the host IP to the re-enumerated interface, which is
// what lets a switch back to the vendor slot be detected as complete.
//
// targetServesDHCP says whether the slot being booted serves DHCP (the open slot
// does, the vendor slot does not). For a DHCP slot we wait briefly for DHCP to
// configure the host before doing a static reattach, which avoids a needless
// authorization prompt; for a non-DHCP slot we reattach as soon as the interface
// appears, so the vendor slot is detected as soon as it is up.
//
// ip is the address the slot being booted answers on: the stock slot at .100, the
// open slot at the unit's fixed board.conf address (.101 goggle, .102 air). The
// slots live at different addresses, so waiting on the wrong one would never see
// the reboot complete.
//
// verifyUptime is for the one case where the firmware being booted answers at the
// address we are connected to right now (an open slot activated out of a flash-boot):
// there, an SSH answer at ip is not by itself proof of a reboot, so the session that
// answers must also report an uptime shorter than the time since the reboot command
// went out. An unreadable uptime is accepted, so this can only delay a false positive,
// never turn a real reboot into a timeout.
func rebootAndWait(ctx context.Context, opt Options, client deviceClient, rebootCmd, targetPassword, ip string,
	targetServesDHCP, verifyUptime bool, emit Emit) error {
	emit(Event{Level: LevelStep, Msg: "Rebooting into the newly activated firmware"})

	// The reboot command tears the SoC down mid-session, so this SSH call never
	// returns cleanly: it blocks on the dead transport until the host's TCP timeout
	// (up to a minute, as no SSH keepalive is set). Waiting on it would stall the
	// whole reconnect - including the host-IP reattach - for that long, so fire it
	// in the background and move straight to the wait loop. The command is delivered
	// before the SoC resets; the deferred client.Close eventually unblocks the call.
	go func() { _, _ = client.Run(rebootCmd) }()
	issued := time.Now()

	emit(Event{Level: LevelInfo, Msg: "Waiting for the device to come back (this can take a minute)"})

	// Let the SoC actually reset and drop the USB link before polling, so the old
	// interface is gone and only the re-enumerated one is a candidate.
	if err := sleep(ctx, 6*time.Second); err != nil {
		return err
	}

	backend := newBackend()
	assigned := map[string]bool{}
	lastIfaces := ""
	// A DHCP slot gets a short grace to configure the host on its own; a non-DHCP
	// slot is reattached immediately once its interface enumerates.
	reattachAfter := time.Now()
	if targetServesDHCP {
		reattachAfter = reattachAfter.Add(8 * time.Second)
	}
	deadline := time.Now().Add(180 * time.Second)
	for time.Now().Before(deadline) {
		if reachable(ctx, ip, 2*time.Second) {
			if c, err := dialDevice(ctx, ip, "root", targetPassword, 5*time.Second); err == nil {
				rebooted := !verifyUptime || hasRebooted(c, time.Since(issued))
				_ = c.Close()
				if rebooted {
					emit(Event{Level: LevelInfo, Msg: "The device is back up and reachable"})
					return nil
				}

				emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("%s still answers from the pre-reboot session", ip)})
			} else {
				emit(Event{Level: LevelInfo, Msg: fmt.Sprintf("%s answers but SSH is not ready yet", ip)})
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

		if err := sleep(ctx, 2*time.Second); err != nil {
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
