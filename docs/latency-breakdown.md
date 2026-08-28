# Latency breakdown

This document summarizes the current measured latency pieces for the MissingLynk video path. It
separates the RF/network transport benchmark from the goggle-local receive/decode/display timing.

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

Capture a new goggle-side latency run with:

```sh
SECS=60 glue/capture/goggle-latency-capture.sh
```

That creates a timestamped directory under `out/goggle-latency/` containing `ml-pipeline.log`,
`metadata.txt`, and a generated `goggle-latency-timeline.svg`.

Render an existing captured log with:

```sh
python3 glue/capture/goggle-latency-plot.py \
  path/to/ml-pipeline.log \
  -o path/to/goggle-latency-timeline.svg
```

## Goggle-local latency

![Goggle-side latency timeline](assets/goggle-latency-timeline-20260825.svg)

The goggle-local total is `rx2flip`: first UDP video datagram for a frame in `rf_rx` through the DRM
flip event, which is the scanout latch.

| Metric | Value |
|---|---:|
| Frames parsed | 3567 |
| `rx2flip` p50 | 20.5 ms |
| `rx2flip` p99 | 29.6 ms |
| tile 0 `rx2dec` p50 | 4.6 ms |
| tile 1 `rx2dec` p50 | 8.2 ms |
| tile skew / pair p50 | 3.6 ms |
| pair complete -> flip ioctl entered p50 | 1.1 ms |
| flip ioctl entered -> returned p50 | 0.2 ms |
| flip returned -> latch event p50 | 8.9 ms |
| pair complete -> latch event p50 | 10.2 ms |

The `scanout latch` wait is display-refresh quantization, not active compute. One refresh period is 16.675 ms here, so a submitted frame waits anywhere from near 0 ms to one period for the next safe latch point. Where in that range it lands is set by the phase between frame completion and the refresh edge, which the pixel-clock pacing servo controls (`userspace/docs/video-latency.md`).

### Display and source cadence in this capture

Derived from the per-frame `latraw` marks rather than the summary lines:

| Quantity | Value |
|---|---:|
| Panel period, grid fit over 1200 flip events | 16.675 ms (59.97 Hz) |
| Source period, median of consecutive `pair` marks | 17.40-17.50 ms (57.2 Hz) |
| Arrival rate over the run, FrameIds contiguous throughout | 56.6 fps |
| Per-flip submit-to-latch p05 / p50 / p95 | 1.19 / 8.91 / 16.26 ms |
| Median change in submit-to-latch wait per frame | -0.80 ms |

Pacing was enabled for this run, and the servo was still acquiring throughout it. The submit-to-latch p50 of 8.9 ms is half a refresh period, the signature of a sweeping phase, so it is a free-running figure rather than a paced one. Read `rx2flip` p50 20.5 ms the same way. The 2.8 Hz beat between the two rates accounts for all 213 repeated intervals in the capture.

The PTS carried through the pipeline is synthesised from the FrameId at a fixed 60 fps (`RF_FPS`, `ml-pipeline.h`), so any PTS-derived rate reads 60 fps regardless of the wire rate. The 56.6 fps figure above comes from wall-clock marks.

The measurement stops at latch. Panel scanout to a specific row and LCD response happen after this
point and are not included in `rx2flip`.

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
