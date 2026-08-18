"""
Prove `glue/camera/flicker-metric.py` measures mains banding and not whatever else moved.

The metric exists to settle an argument that was previously settled by eye, so its own failure
mode matters: a number that rises for any moving scene would confirm an anti-flicker leg that did
nothing. These tests drive it with synthesised clips whose banding is known exactly, including two
that move without banding, and require it to separate them.

Clips are generated with ffmpeg's geq filter, which evaluates an expression per pixel with the
frame number available, so the injected wave is specified in the same terms the metric predicts:
cycles over the image height, and cycles of phase advance per frame.
"""

import importlib.util
import math
import shutil
import subprocess
import types
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
METRIC = ROOT / "glue" / "camera" / "flicker-metric.py"

pytestmark = pytest.mark.skipif(
    shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None,
    reason="ffmpeg and ffprobe are needed to synthesise the clips",
)

# 1080 active lines at 14815 ns under 50 Hz mains, the air unit's 1080p60 operating point.
CYCLES_50 = 1.600
DRIFT_50 = (2.0 * 50.0 / 60.0) % 1.0   # 0.667 cycles of phase per frame

HEIGHT = 1080
SECONDS = 4


def load_metric() -> types.ModuleType:
    """Import the script by path: it is a tool with a hyphen in its name, not a module."""
    spec = importlib.util.spec_from_file_location("flicker_metric", METRIC)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    return module


def render(path: Path, expression: str) -> Path:
    """One gray clip whose luma is `expression`, encoded losslessly so nothing is attenuated."""
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y",
         "-f", "lavfi", "-i", f"color=c=gray:s=160x{HEIGHT}:r=60:d={SECONDS},format=gray",
         "-vf", f"geq=lum='{expression}'",
         "-c:v", "libx264", "-crf", "0", "-pix_fmt", "gray", str(path)],
        check=True, capture_output=True)

    return path


def measure(module: types.ModuleType, path: Path, mains: float = 50.0) -> dict[str, float]:
    clip = module.Clip(path)

    return module.analyse(clip, module.row_profiles(clip, 1800), mains, 1080, 14815, 60.0)


@pytest.fixture(scope="module")
def metric() -> types.ModuleType:
    return load_metric()


def test_predicted_cycles_matches_the_readout_time(metric: types.ModuleType) -> None:
    """The spatial frequency is the readout time of the active rows, not the frame period.

    1080 rows at 14.815 us is 16.000 ms, which is 1.600 periods of a 100 Hz ripple. Using the
    frame period instead (1125 rows, 16.667 ms) would predict 1.667 and put the projection off
    the peak.
    """
    assert metric.predicted_cycles(1080, 14815, 50.0) == pytest.approx(1.600, abs=0.001)
    assert metric.predicted_cycles(1080, 14815, 60.0) == pytest.approx(1.920, abs=0.001)


def test_projection_returns_the_injected_amplitude(metric: types.ModuleType) -> None:
    """The windowed spatial projection is normalised to the sinusoid, not to the window.

    Checked in isolation because a wrong constant here scales every reported percentage and would
    still leave the comparison between legs looking sensible.
    """
    numpy = pytest.importorskip("numpy")
    rows = numpy.arange(HEIGHT)
    frames = numpy.asarray([
        30.0 * numpy.sin(2 * math.pi * (CYCLES_50 * rows / HEIGHT + DRIFT_50 * n))
        for n in range(120)
    ])

    amplitude = float(numpy.abs(metric.project(frames, CYCLES_50)).mean())

    assert amplitude == pytest.approx(30.0, rel=0.02)


def test_lock_in_preserves_the_amplitude_through_the_second_axis(
        metric: types.ModuleType) -> None:
    """The temporal stage must not rescale what the spatial stage measured.

    Its normalisation differs from the spatial one (the per-frame series is already complex and
    one-sided, so 1/sum(window) rather than 2/sum(window)), which is exactly the sort of factor
    that goes unnoticed while leg-to-leg ratios still look right.
    """
    numpy = pytest.importorskip("numpy")
    rows = numpy.arange(HEIGHT)
    frames = numpy.asarray([
        30.0 * numpy.sin(2 * math.pi * (CYCLES_50 * rows / HEIGHT + DRIFT_50 * n))
        for n in range(600)
    ])
    amps = metric.project(frames, CYCLES_50)

    assert metric.lock_in(amps, DRIFT_50) == pytest.approx(30.0, rel=0.05)


def test_banding_is_detected_at_the_predicted_cell(
        metric: types.ModuleType, tmp_path: Path) -> None:
    """A clip carrying the real signature reads on depth, coherence and both peak positions."""
    clip = render(tmp_path / "band.mp4",
                  f"128+30*sin(2*PI*({CYCLES_50}*Y/H + {DRIFT_50}*N))")
    stats = measure(metric, clip)

    assert stats["snr"] > 20.0
    assert stats["amplitude_pct"] > 15.0
    assert stats["peak_cycles"] == pytest.approx(CYCLES_50, abs=0.1)
    assert stats["peak_drift"] == pytest.approx(DRIFT_50, abs=0.02)


def test_a_shallow_band_survives_strong_scene_energy_at_the_same_frequency(
        metric: types.ModuleType, tmp_path: Path) -> None:
    """The case that made a real measurement read as null, and the reason for the second axis.

    Here a small band sits underneath scene structure at the SAME spatial frequency, six times
    deeper, drifting at an unrelated rate. Filtering only on the spatial axis reports the scene
    and calls the band absent, which is what happened on hardware: an uncorrected leg whose band
    was plainly visible measured 2.4% spatially, nearly all of it scene, against a true depth of
    0.6%. Filtering on both axes recovers the band because only it is coherent.
    """
    clip = render(tmp_path / "buried.mp4",
                  f"128+36*sin(2*PI*({CYCLES_50}*Y/H + 0.071*N))"
                  f"+6*sin(2*PI*({CYCLES_50}*Y/H + {DRIFT_50}*N))")
    stats = measure(metric, clip)

    assert stats["snr"] > 20.0, "the coherent band was lost under the scene"
    assert stats["peak_drift"] == pytest.approx(DRIFT_50, abs=0.02)

    # The recovered depth is the band's, not the interferer's: 6 on a mean of 128, carried through
    # the same limited-to-full range expansion the encoder applies. This is also where the metric
    # is pinned as monotonic in band depth, which matters because the sensor's quantised gain codes
    # mean a real correction leaves a residual band rather than nulling it, and a partial
    # correction has to read as partial rather than as none.
    assert stats["amplitude_pct"] == pytest.approx(100.0 * 6 / 128, rel=0.35)


def test_a_moving_scene_is_not_mistaken_for_banding(
        metric: types.ModuleType, tmp_path: Path) -> None:
    """Vertical motion at the wrong rate must be rejected even when it is strong.

    A pattern scrolling up the frame produces a large residual at a spatial frequency the search
    band contains, so depth alone cannot reject it. The coherence is what does.
    """
    clip = render(tmp_path / "scroll.mp4",
                  f"128+40*sin(2*PI*({CYCLES_50}*Y/H + 0.13*N))")
    stats = measure(metric, clip)

    assert stats["residual_rms_pct"] > 5.0
    assert stats["snr"] < 10.0
