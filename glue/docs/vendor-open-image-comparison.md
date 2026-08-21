# Comparing our image against the vendor's

The procedure behind `glue/capture/ab-record.sh` and `glue/capture/ab-image-diff.py`.

## What the method is

Record the same scene twice through the **same goggle**: once with a stock vendor air unit, once with ours. The goggle receives, decodes and re-encodes for the DVR, so that whole path is common to both legs and every difference between the two files came from the air side. Then measure the two files against each other offline.

**The air side is not only the ISP and the AE loop.** It is also the encoder bitrate, and the two stacks do not set it the same way. The vendor's `AR_8030_TX_GetBitRate` derives its target from live RF throughput (`throughput * Ar803xThroutputRate`, capped at `ArMaxBitRate`, falling back to 8000 kbps when throughput reads zero) and re-applies it on every MCS change; ours ran the fixed `ML_AIR_BITRATE`, 4 Mbps per tile across two tiles, which matches the vendor's fallback rather than its steady state. **Since 2026-08-21 the open air derives the rate the same way** (`RATE_MODE=adapt`, the shipped default, hardware-validated against a forced modulation index), so a leg recorded on a current image no longer carries a fixed-rate handicap. `fixed` remains selectable, and an image or a unit left on it reintroduces exactly the gap described here. A leg recorded at the higher rate hands the goggle a more detailed picture, so its re-encode spends more bits, and that lands in the report as gradient energy and noise. `ab-record.sh` measures the downlink rate over each recording window and writes it to the leg's metadata. **Compare those two numbers before reading anything into sharpness, noise or bitrate differences**; if they differ materially, the pair measures the encoders as much as the ISPs.

Recording on the goggle rather than pulling frames off each air unit is the point of the method: there is no way to run our capture tooling on a bone-stock vendor air unit without changing what it is, and two different capture paths would put the difference we are trying to measure into the measuring instrument.

The vendor air unit is not touched at all. On the goggle the recorder stages one small helper (`ml-rec`, the same control message the HUD's record button sends) and, only when OSD burn-in is enabled, edits `settings.json` and restarts `ml-hud`, restoring both on exit.

## Cost of the method, stated up front

- **Both legs are re-encoded by the goggle.** Gradient energy and the noise floors therefore carry a compression component. They are comparable between the legs; they are not absolute.
- **The two legs are separate flights of the scene.** Anything that moved between them, including the sun, is charged to the air side by construction. Scene control is not optional, it is the method's only real requirement.
- **Which stack the air unit booted is operator-asserted.** Nothing in the script can see the air unit's slot; `vendor` and `open` are labels you supply, and the metadata file records them as asserted. Mislabelling the legs inverts every conclusion in the report.

## Running it

Scene control first, because it is what the numbers rest on:

- The camera does not move between the legs. A tripod or a clamp, not a hand.
- The light does not change between the legs. Indoors under artificial light, or outdoors within a few minutes under a clear or a uniformly overcast sky. Not partial cloud.
- The scene contains all of: a large flat area (for the noise floor), fine detail (for the gradient energy), a deep shadow and a bright highlight (for the tone curve), and something neutral grey or white (for the channel ratios). A colour chart is ideal and a sheet of paper plus a textured surface is enough.
- Nothing in the scene moves. Not leaves, not a screen, not a person.
- Run the two legs back to back, changing only the air unit.

Then, per leg:

```sh
# air unit on stock slot A, goggle showing video
glue/capture/ab-record.sh vendor --secs 30 --note "bench, 3 pm overcast, chart at 1.5 m"

# swap to the air unit on our slot B, same scene, same light
glue/capture/ab-record.sh open --secs 30 --note "same scene"
```

Each leg lands in `out/au-ab/<leg>/` as the recording, the SRT sidecar if the HUD wrote one, and a `.meta.txt` recording the goggle kernel, the pinned format, the burn-in state, and the pipeline tail for the run.

Then compare:

```sh
glue/capture/ab-image-diff.py out/au-ab/vendor/vendor-*.mp4 out/au-ab/open/open-*.mp4 \
    -o out/au-ab/report
```

That writes `report.md`, `samples.csv`, `timeline.csv`, `timeline.png`, `tone.png` and a `stills/` directory of side-by-side pairs, vendor left, ours right. The report also includes a ranked "Suggested next work" table. It is a triage tool: use its first row as the next question to answer, then confirm with the register/provenance evidence before changing a stage.

## Reading the report

Each measurement is chosen for what it is diagnostic of, and the report's own table names it:

| measurement | what a difference points at |
|---|---|
| mean luma | the AE operating point: sensor exposure and gain |
| p1, p5 | black level (BLC) and the shadow end of the tone curve |
| p50 | midtone placement, so gamma |
| p95, p99 | the shoulder, so DRC and the highlight end of the tone curve |
| tone transfer curve | gamma, DRC and BLC together, as a shape |
| R/G and B/G overall, midtones and highlights | static WB/CCM state or gain-keyed `cm/cm2` |
| R/G and B/G in shadows | black level or shading before colour-row work |
| chroma magnitude | saturation: `cm/cm2` gain against a desaturating denoise stage |
| gradient energy | sharpening against the denoise stages (lnr, de3d, cnf) |
| local contrast | LTM/CLAHE after global tone has been accounted for |
| spatial and temporal noise | denoise strength |
| clipped fractions | highlights and shadows that no tone curve recovers |
| timeline, std of mean luma | AE dynamics: convergence, overshoot, hunting |

The tone transfer curve is the most diagnostic single output. It is recovered by matching the two legs' cumulative luma histograms, so it needs no pixel correspondence between the files, only that both framed the same scene. Read it together with the exposure row: a leg that is simply exposed darker moves the curve too, and the two causes are not separable from the curve alone.

The suggested-work table intentionally ranks by measured delta, not by certainty. The expected landing order after a clean static-scene run is:

1. Mean-luma or timeline difference: re-check AE operating point, target, convergence and anti-flicker. Mind the banding toggle: `/usrdata/missinglynk/banding` at 50 moves the open leg 0.74 stops darker than a vendor leg running the default off, which would read as an AE difference.
2. p50/p95/p99 or tone-transfer difference with similar mean luma: the gamma/DRC tone-table selector, shipped and driven by default since 2026-08-19; the question becomes whether its scalar tracks the vendor's on this scene, not whether the pages reach the pixels (that is proven).
3. Gradient, noise, chroma, saturation, or luma-band channel-ratio difference: the gain-keyed ladders. All five (`rnr/lnr/de3d/cfa/cnf`) plus `cm/cm2` reproduce their recomputation on hardware across the gate abscissas (2026-08-19 sweep), so a delta here points at the blob transforms or the abscissa itself, not the appliers. AWB is gated off in the shipped tuning, so an AWB estimator is beyond vendor parity.
4. A remaining raw-domain temporal-noise signature after that gate: re-check `raw_3dnr`, which is currently classified disabled for the shipped path.
5. Local-contrast mismatch that survives the above: LTM/CLAHE, the one enabled stage still running a stand-in (identity ramp) on our side.

## Forced tone sweep

If the first report points at p50/p95/p99 or the tone-transfer curve while mean luma is close, spend the next open leg as a forced gamma/DRC sweep before writing selector code. The open driver already has `gamma_curve` and `drc_profile` module parameters, so the sweep can answer whether the visible gap is inside the existing blob-derived pages or in some later tone stage.

Use the smallest grid that brackets the two vendor operating points already recovered:

| point | `gamma_curve` | `drc_profile` | purpose |
|---|---:|---:|---|
| pinned default | 3 | 3 | current open baseline |
| vendor session A candidate | 2 | 3 | lower scalar interval `[210,250]` |
| vendor session B candidate | 3 | 4 | upper scalar interval `[290,330]` |
| crossed control | 2 | 4 | separates gamma midtones from DRC shoulder |

Run the vendor leg once, then run one open recording for each point without moving the scene. For each open point, bring the air-unit camera chain up with the point's selectors before starting the transmitter and the goggle recording:

```sh
GAMMA_CURVE=3 DRC_PROFILE=3 CVDEPTH=3 glue/camera/au-v4l2-chain.sh
GAMMA_CURVE=2 DRC_PROFILE=3 CVDEPTH=3 glue/camera/au-v4l2-chain.sh
GAMMA_CURVE=3 DRC_PROFILE=4 CVDEPTH=3 glue/camera/au-v4l2-chain.sh
GAMMA_CURVE=2 DRC_PROFILE=4 CVDEPTH=3 glue/camera/au-v4l2-chain.sh
```

Keep the AE starting conditions the same for each open leg: cold bring-up if the boot budget allows it, or at least restart `ml-aed` at the same `--start-index` and wait for the decision log to settle before recording. Compare every open point against the same vendor file:

```sh
glue/capture/ab-image-diff.py out/au-ab/vendor/vendor-*.mp4 out/au-ab/open/open-g3-d3.mp4 \
    -o out/au-ab/report-g3-d3 --open-label open-g3-d3
glue/capture/ab-image-diff.py out/au-ab/vendor/vendor-*.mp4 out/au-ab/open/open-g2-d3.mp4 \
    -o out/au-ab/report-g2-d3 --open-label open-g2-d3
glue/capture/ab-image-diff.py out/au-ab/vendor/vendor-*.mp4 out/au-ab/open/open-g3-d4.mp4 \
    -o out/au-ab/report-g3-d4 --open-label open-g3-d4
glue/capture/ab-image-diff.py out/au-ab/vendor/vendor-*.mp4 out/au-ab/open/open-g2-d4.mp4 \
    -o out/au-ab/report-g2-d4 --open-label open-g2-d4
```

Summarise the sweep:

```sh
glue/capture/ab-sweep-summary.py \
    out/au-ab/report-g3-d3 out/au-ab/report-g2-d3 \
    out/au-ab/report-g3-d4 out/au-ab/report-g2-d4 \
    -o out/au-ab/tone-sweep.md
```

Read the sweep narrowly. If one forced point pulls the tone-transfer curve and p50/p95/p99 toward the vendor while mean luma stays close, implement `plans/done/isp-tone-selector.md` next. If all four points leave the same local-contrast error, move the tone selector behind LTM/CLAHE. If all four points leave the same luma-banded colour, chroma, gradient or noise residual, take the shared `cfa/cnf/cm/cm2` gate before selector integration.

## Adding an AE event

The static-scene run measures the settled operating point. To measure the loop instead, run a leg with a scripted light change: start the recording, hold the scene for ten seconds, cover the lens for ten, uncover for the rest. Do the same thing at the same times in the other leg. The timeline plot then shows both convergence directions, and `timeline.csv` carries the numbers for the step response: how long each leg takes to settle, how far it overshoots, and whether it hunts once settled.

## Where this does not reach

The comparison sees the finished picture. It says a stage is wrong; it does not say which register. Pair it with the source-side comparison against the reverse-engineered vendor implementation (`handoffs/`, and the register diff in `glue/camera/diff-live-registers.py`) which sees the configuration but not the image. Neither half is sufficient alone: the register diff compares only at one operating point and only over registers our driver already writes, and this one cannot name a cause.
