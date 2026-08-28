# Pinned pixel clock against a live air unit, three legs on one boot

Source: AU camera over RF, 60 fps. Pacing off. Forced vblank-phase injector disarmed (it was armed
from the soak and had to be cleared first; see below). Build identity in `identity.txt`.

| leg | leaf rate | `rx2flip` p50/p99 | `rx2dec` t0/t1 | pair | `sub2flip` | `fdt` p50/p99 | jud | rep |
|---|---|---|---|---|---|---|---:|---:|
| 1 | 148,500,000 | 45.3 / 48.3 | 6.6 / 16.8 | 10.4 | 16.4 | 16.7 / 17.0 | 4 | **0** |
| 2 | 153,646,640 | 29.7 / 39.3 | 6.6 / 16.9 | 10.4 | 9.1 | 16.1 / 32.3 | 198 | **193** |
| 3 | 148,500,000 | 40.2 / 43.9 | 6.5 / 16.7 | 10.3 | 16.2 | 16.7 / 18.4 | 6 | **0** |

93 s and ~5584 frames per leg. Leg 3 reproduces leg 1, so the effect is the clock and not drift.

## The air unit delivers exactly 60 fps

`n=60` in every second of all three legs. This settles the open question and contradicts the
2026-08-25 capture's 56.6 fps arrival figure.

## The pinned clock buys a perfect rate lock and costs a frame of phase

At 148.5 MHz the panel period is 16.7 ms against a 16.667 ms source, and the result is **zero
repeats in 5584 frames** with `fdt` p99 equal to p50. The pre-fix rate produces 193 repeats over the
same interval, the 62.08 - 60 Hz beat.

The cost is `sub2flip`. Matched rates stop the phase sweeping and **lock** it, and it has locked at
16.2-16.4 ms of a 16.7 ms period: the frame misses the latch by a few hundred microseconds and
waits a whole period. The mismatched clock reads lower only because a sweeping phase averages half
a period rather than sitting at the bad end.

That offset is now static rather than drifting, so nulling it needs a constant phase offset, not a
control loop. At `sub2flip` near zero this leg would read about 29 ms `rx2flip` with zero repeats,
better than either leg measured here.

## The regression is goggle-side and predates this run

The air unit is unchanged from the 2026-08-25 baseline. Last night's soak gives the control that
separates build from source: **the same goggle build and pinned clock as today, driven by the
55.4 fps replayer with no air unit involved.**

| when | source | `dec` t0/t1 | pair | `sub2flip` | `rx2flip` |
|---|---|---|---:|---:|---:|
| 2026-08-25 | air unit 56.6 fps, pacing on | 4.6 / 8.2 | 3.6 | 8.9 | 20.5 |
| last night, soak | replayer 55.4 fps, pinned | 9.0 / 11.4 | 3.6 | 13.2 | ~43 |
| today, leg 1 | air unit 60 fps, pinned | 6.6 / 16.8 | 10.4 | 16.4 | 45.3 |

**+22.5 ms of the +24.8 ms was already there last night**, against a slower source than the
baseline's and with the air unit out of the picture entirely. Today's air unit adds +2.3 ms. The
regression is a goggle-side change between 2026-08-25 and the current build, not a measurement
artefact and not the air unit.

Pair skew is the one quantity that does track the source: 3.6 ms on the replayer, 10.4 ms on the
air unit at 60 fps, with the same goggle build. The air unit's two tiles arrive further apart at 60
than at 56.6 fps.

Of the goggle-side +22.5 ms, `sub2flip` accounts for +4.3 and tile-1 decode for +3.2. The remaining
~15 ms is in the pairing, compose and submit path and is unattributed.

Caveat on the middle row: the soak saved no `ml-pipeline.log`, so its figures are eight summary
lines read live during the run rather than a 93-second median. The gap is far larger than that
sampling error, but the row is not a capture.

## A debug knob silently invalidated the first capture

The run began with `/usrdata/missinglynk/phase-force` = 1250 still armed from the soak, which
injects a forced vblank phase. Under it the pipeline read ~2.6 s of `rx2flip`, growing, with
`fdt` p99 spikes to 5.2 s and `n` between 0 and 60. Nothing in the latency numbers said why.

`capture_identity` in `glue/lib/capture-identity.sh` now records the build and the ML_* environment
the measured process actually started with, so a capture names its own conditions.
