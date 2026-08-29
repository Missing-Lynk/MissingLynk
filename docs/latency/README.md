# Latency breakdown

This document summarizes the current measured latency pieces for the MissingLynk video path. It
separates the RF/network transport benchmark from the goggle-local receive/decode/display timing.

## Where the measurements live

Every goggle-side measurement is published here, one directory per run, named `<capture time>-<build>` so a listing reads in order. The build comes from the device's own `/etc/ml-release` rather than the host checkout, because the goggle can be running an older bundle than the tree and it is the flashed bytes that produced the numbers. `-unknown` marks a run taken before captures recorded a build.

A run holds `identity.txt` (the build and the `ML_*` knobs the measured pipeline was started with) and, where one was written, `RESULT.md`. Each capture under it holds `ml-pipeline.log`, `summary.json` and `goggle-latency-timeline.svg`.

The log is the primary artefact and is why it is kept at full size: every table, graph and summary is derived from it, and a published run whose log is gone can never be re-read with a question the summary did not anticipate. It is stored as plain text so it stays greppable, diffable and reviewable; compressing it would save about 4 percent of packed size and give that up.

Nothing else is published. The clock trace's scalars are folded into each leg's summary as `pixclk_hz_*` and `dsi_int_st1`, the run identity is one set of facts rather than one per leg, and the harness's own stdout only reports whether a run completed, which a published run already did.

### If this directory outgrows its usefulness

A run costs roughly 500 kB per leg, and 98 percent of that is the `latraw` lines, one per flip. Dropping them takes a leg's log from 514,653 bytes to 12,183 and costs exactly five summary fields: `pair_issue`, `issue_submit`, `submit_event`, `pair_event` and `raw_frames`. Those are the per-flip decomposition the timeline's lower half draws, so a pruned run keeps every median in the comparison table and loses the breakdown behind them. Prune old runs, not new ones.

Tabulate the whole history:

```sh
glue/capture/latency-compare.py docs/latency/*/
```

The first columns are the conditions, not the results. Two rows only compare when `source`, `src fps`, `pixclk` and `pace` agree, and they are printed left of the medians so a mismatch is seen before the numbers are read rather than after a conclusion has been drawn from them.

- `source` is `air` or `replay`. The replayer plays a captured dump at its own cadence, so its frame rate and tile spacing are its own and not the link's.
- `src fps` is what the panel had to keep up with. A 60 fps source against a 60.00 Hz panel beats at nothing; a 56.6 fps source against the same panel repeats a frame three times a second.
- `pixclk` is the panel rate the leaf held, and `pace` carries a value when the servo was steering it. A paced run's `sub2flip` is a swept figure rather than a held one, so it is not comparable with an unpaced run's even when everything else matches.

A row reading `PHASE-FORCED <n> us, NOT A LATENCY RESULT` was taken with the vblank phase injector armed, which holds the tile-0 submit back by up to a full vsync. Every wait on that row is inflated and it is not comparable with anything.

Publish a run once it is captured:

```sh
glue/capture/latency-publish.sh out/pinned-clock-latency/<run>
```

Re-render a published run's timeline and summary from its log:

```sh
glue/capture/goggle-latency-plot.py docs/latency/<run>/<capture>/ml-pipeline.log \
  -o docs/latency/<run>/<capture>/goggle-latency-timeline.svg
```

## Reproducing the air-unit graph

Air-unit latency instrumentation is opt-in in `ml-air-video`:

```sh
EXTRA_ENV='ML_AIR_LATSTATS=1 ML_AIR_LATRAW=1' TX=1 glue/camera/au-cam-tx.sh
SECS=60 glue/capture/air-latency-capture.sh
```

`ML_AIR_LATSTATS=1` emits one-second p50/p99 summaries. `ML_AIR_LATRAW=1` also emits one line per
transmitted access unit, suitable for a timeline plotter.

The current marks are:

| Mark | Meaning |
|---|---|
| `capts` | V4L2 capture-buffer timestamp from the camera node |
| `capdq` | userspace time after `VIDIOC_DQBUF` on the capture node |
| `encq` | userspace time after queueing the capture buffer into the encoder OUTPUT queue |
| `encdone` | userspace time after dequeuing the encoded access unit from the encoder CAPTURE queue |
| `tx` | userspace time after a successful UDP `sendto` on `:10001` |

This measures capture-completion-to-transmit and userspace-visible queue/encode/transmit stages. It
does not by itself measure photon-to-buffer time; that needs a sensor/frame-start hardware mark or
an external optical setup.

## Reproducing the goggle graph

Arm the baseline knob set first (see "The measurement baseline" below); the capture script is
read-only on the device and fails rather than enabling anything itself. Then capture with:

```sh
SECS=60 glue/capture/goggle-latency-capture.sh
```

That creates `out/goggle-latency/<stamp>-<build>/` containing `ml-pipeline.log`, `metadata.txt`, `summary.json` and a generated `goggle-latency-timeline.svg`.

To measure at more than one pixel-clock rate back to back on one boot, which is what separates a panel-rate effect from everything else, use:

```sh
SECS=90 glue/capture/pinned-clock-latency.sh 148500000 153646640
```

It sets each rate, verifies the leaf landed, samples the leaf and the DSI `INT_ST1` latch through each leg, and restores the mode rate on exit. It refuses to run while the pacing servo is armed, because the servo walks the leaf off the set rate within seconds.

Render an existing captured log with:

```sh
python3 glue/capture/goggle-latency-plot.py \
  path/to/ml-pipeline.log \
  -o path/to/goggle-latency-timeline.svg
```

## Goggle-local latency

The goggle-local total is `rx2flip`: first UDP video datagram for a frame in `rf_rx` through the DRM
flip event, which is the scanout latch. Panel scanout to a specific row and LCD response happen
after that point and are outside the figure.

It decomposes into four terms, and only the last is display-refresh quantization rather than work:

| Term | What it covers |
|---|---|
| `rx2dec` tile 0 | the frame's first datagram through tile 0 leaving the decoder's appsink |
| `rx2dec` tile 1 | the same for tile 1, which is what the pair waits on |
| `pair -> submit` | osd burn-in, the latency counter, the dmabuf flush and the flip ioctl |
| `sub2flip` | the wait for the next latch, which the pacing servo's margin sets |

`sub2flip` is a policy choice, not a cost: the servo holds a deliberate margin so frame-ready jitter
cannot clip the latch, and that margin is the whole of the goggle-side latency the loop can still
remove. `glue/capture/pace-curve.py` reads the trade out of a run's own log, because the servo
random-walks its margin and a run of a few minutes has already swept it.

Two things a reader of an old capture should know before comparing it with anything:

- **A sweeping phase flatters the median.** `rx2flip` p50 near 20.5 ms appears in captures taken
  before the servo locked, because a phase sweeping across the refresh period averages half a
  period. The tail and the repeat rate stay high. Those captures are not comparable with a paced
  run, and the pre-fix ones also ran a 56.6 fps replay source against a 60 Hz panel.
- **The per-second `rep` counter does not see the artefact that matters.** When a frame misses its
  latch the pipeline parks one frame behind, where the wait pins at a full period until the servo
  hauls it out, about four seconds later. That counts as one repeat in one second. Count those from
  the `pace` trace instead, as a `lo` crossing back above 12000 us.

### The measurement baseline

Comparable runs need the same knob set, and three of the four flag files are absent after a flash,
so a fresh unit measures nothing and a capture taken without arming them silently differs from the
runs it is compared against. Arm it, with the air unit off, then power the air unit:

```sh
glue/capture/latency-baseline.sh          # arms the set and restarts ml-video
glue/capture/latency-baseline.sh --check  # reports the state, changes nothing
```

The set is `latstats`, `latraw`, `pace-dbg` and `seam=2`, at the mode pixel clock of 148,500,000 Hz
with the pacing servo at its default. `ML_SEAM` unset means seam handling is OFF, so `seam=2` is not
the flashed default and has to be written. `pmsg` is on unless `no-pmsg` exists, so its per-frame
cost is inside every published figure. Recording is off; it is a separate configuration measured on
its own. With the codec clock at 500 MHz its decode cost is zero (`rx2dec` is identical with and
without the encoder); what recording costs is vsync phase, because the pacing servo holds
`sub2flip` above its target while the encoder runs.

### The current baseline

`20260829T210626Z-604e67c` is the reference run every later run compares against: image `604e67c`
flashed, the codec clock at 500 MHz as board policy in the DTB, the pacing servo on by default, DVR
H.264 fixed QP. Base leg `rx2flip` p50 21.2 / p99 23.8 ms; recording leg 28.2 / 33.7 ms, where the
whole gap is servo phase (`sub2flip` 14.6 against a 9 ms target) and a same-boot re-run read
26.2 / 31.4.

## RF network benchmark

The production-critical direction is air unit -> goggle. The benchmark used UDP `iperf3` traffic
over the AR8030 IP tunnel while video transmission was stopped on the air unit. The RF netdev MTU
was 4096 bytes on both ends; the sweep varied UDP payload size, so payloads above 4096 bytes were
fragmented below the application.

Baseband identity for the BetaFPV VR04 HD run:

| End | Baseband image | SHA-256 |
|---|---|---|
| goggle | `/lib/firmware/bb_demo_gnd_d.img` | `8993aea4617351afb214518e060c2444897dded8710009fc9097ea409c1a8b00` |
| air | `/lib/firmware/bb_demo_air_d.img` | `fa80c8d72af34c8b25830b34124b0b08e0073b2d6d1dc7eb530cec42eaf4f12f` |

MCS/SNR note: this historical RF matrix did not capture explicit per-trial MCS/SNR samples. Treat
the numbers as the measured BetaFPV downlink ceiling for that bench setup, not as a standalone
channel-quality comparison. Current `glue/capture/rf-net-bench.sh` writes `raw/link-*.txt`
snapshots with goggle-side `Get1V1Info` SNR/PHY capacity and, when air SSH is available, air-side
`GET_MCS` MCS/throughput log samples around each iperf trial.

Fresh-battery validation, shown as `received Mbit/s / UDP loss / concurrent ping avg/max ms`:

| Payload | 16M offered | 20M offered | 24M offered |
|---:|---|---|---|
| 1024 | 16.00 / 0.00% / 66.1/106.1 | 20.00 / 0.35% / 50.7/54.0 | 20.52 / 0.00% / 84.4/101.3 |
| 2048 | 16.00 / 0.00% / 50.9/54.3 | 20.00 / 0.00% / 78.0/165.9 | 20.84 / 0.73% / 82.7/103.5 |
| 3584 | 16.00 / 0.00% / 51.4/54.2 | 20.00 / 0.00% / 55.0/78.5 | 20.91 / 0.29% / 96.6/126.8 |
| 4096 | 16.00 / 0.00% / 51.1/53.6 | 20.00 / 0.00% / 73.6/167.9 | 20.73 / 0.10% / 82.3/103.4 |
| 8192 | 16.00 / 0.00% / 50.5/53.1 | 20.00 / 0.00% / 51.5/54.4 | 20.82 / 0.04% / 82.8/104.0 |
| 11000 | 16.00 / 0.00% / 50.4/53.1 | 20.01 / 0.00% / 53.2/63.6 | 20.89 / 0.16% / 87.3/111.3 |
| 16000 | 16.01 / 0.00% / 51.4/56.0 | 20.00 / 0.00% / 53.5/57.5 | 20.86 / 0.00% / 87.0/110.1 |
| 19000 | 16.01 / 0.00% / 52.1/56.1 | 20.00 / 0.66% / 95.7/157.7 | 20.82 / 0.00% / 81.1/98.2 |

Interpretation:

- The measured downlink ceiling is about 20.0-20.6 Mbit/s on these BetaFPV baseband blobs.
- Offering 24M saturates the link: delivered throughput remains near the same ceiling while ping
  latency rises.
- 8192-byte UDP payloads were the best validated general-purpose point across 16M and 20M on both
  batteries.
- 11000 and 16000 bytes are still plausible production-size candidates, but need a full repeated
  matrix before replacing 8192 as the conservative default.

Full RF protocol, metadata requirements, plots, and raw-run references are in
`datasheets/rf-throughput-benchmark.md`.
