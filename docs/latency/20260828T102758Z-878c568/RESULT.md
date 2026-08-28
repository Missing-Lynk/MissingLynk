# Clean build 878c568, live air unit, three pixel-clock legs

First run on a bundle whose tar name, manifest and `/etc/ml-release` all agree, with the capture
instrumentation recording its own conditions. Source is the AU camera over RF at 60 fps.

| leg | leaf rate | `rx2flip` | `dec` t0/t1 | pair | `pair_issue` | `sub2flip` | jud | rep |
|---|---|---|---|---|---|---|---:|---:|
| 1 | 148,500,000 | 34.9 | 6.6 / 16.8 | 10.4 | 1.15 | 14.5 | 1 | 1 |
| 2 | 153,646,640 | 29.2 | 6.5 / 16.7 | 10.4 | 1.14 | 8.8 | 195 | 193 |
| 3 | 148,500,000 | 35.2 | 6.7 / 16.8 | 10.4 | 1.17 | 14.7 | 4 | 0 |

Legs 1 and 3 are the same condition, run either side of leg 2 as a control: they agree to 0.3 ms,
so the difference at leg 2 is the clock and not drift or warm-up. Leg 2 alone changes the pixel
clock, to the rate the SPL leaves and the panel ran at before `ar_vo_pipe_enable` applied
`mode->clock`.

## The cross-fade costs nothing measurable

`pair_issue` is the window holding `seam_blend_band()`, and it reads 1.15 ms here. A control capture
taken in the same boot with the cross-fade off (`ML_SEAM=1`) read **1.83 ms** on the same stages
(`dec` 6.5/16.7, pair 10.4, `rx2flip` 36.4), so turning the blend off made nothing faster. The blend
costs nothing measurable. That control is not kept: the goggle always runs with blending, so the row
is not comparable with anything we will measure again.

The 9.91 ms this window read on the 2026-08-28T08:19 run was not a property of that build. Within
that same run its three legs read 9.91, 1.14 and 5.09, and the kernel bytes were identical to this
one's. Whatever produced it was specific to that pipeline generation, which had been restarted by
hand out of a half-supervised state after the forced-phase injector was disarmed.

## At the matched rate the phase locks per pipeline generation

`sub2flip` is a held figure at 148.5 MHz and a swept one at 153.6 MHz. Held, it lands somewhere and
stays: 16.4 and 16.2 on the earlier boot, 14.5 and 14.7 here, 16.3 after the seam restart within
this boot. So it re-locks on every ml-video generation, not only on every boot, and the value is
whatever phase that generation happens to start at. Observed range 14.5 to 16.4 against a 16.7 ms
period.

The consequence for comparison is that `sub2flip`, and therefore `rx2flip`, cannot be compared
across pipeline generations at the matched rate. The mismatched rate averages over the sweep and
does compare: 29.7 on the earlier boot against 29.2 here.

## What the pixel-clock fix costs and buys, measured

Against leg 2 in the same boot: 193 repeats per 5580 frames become 1, and `rx2flip` rises 29.2 to
34.9. The rise is entirely `sub2flip` and is therefore a property of where the phase locked, not a
fixed price.

## The open regression is tile 1, and it is completely stable

Against the 2026-08-25 capture, `dec` t1 is 8.2 -> 16.8 and pair skew 3.6 -> 10.4. Both hold to a
tenth of a millisecond across every leg here, both boots, both seam modes and both clock rates,
which rules out the compositor, the clock, the cross-fade and queueing behind a slow handler. 16.8 ms
is one frame period at 60 fps.

`pair_issue` at 1.15 ms says the compositor is not slow, so the earlier suggestion that `rx2dec` was
inflated by backpressure from a slow handler does not hold either.

The next measurement is the air side, `glue/capture/air-latency-capture.sh`, whose `capts`/`capdq`/
`encq`/`encdone`/`tx` marks are per tile and would show directly whether tile 1 leaves the air unit
late.
