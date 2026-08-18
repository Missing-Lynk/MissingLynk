"""
Guard the host-side RTSP capture path against the goggle sources it depends on.

`glue/capture/rtsp-record.sh` records the restream onto the host instead of driving the goggle's
DVR, which makes it the recorder for any multi-leg image comparison. Everything it needs from the
goggle is a string literal on both sides: the mount path, the settings keys that gate the stream,
and the log line the pipeline prints when the server comes up. None of those produce a build error
when one side is renamed. They fail as an empty recording, mid-session, with the unit powered.

These read both sides and require them to agree.
"""

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
CAPTURE = ROOT / "glue" / "capture"
CAMERA = ROOT / "glue" / "camera"
PIPELINE = ROOT / "userspace" / "gstreamer" / "src" / "ml-pipeline" / "mlp-rtsp.c"
HUD = ROOT / "userspace" / "ml-hud" / "src" / "hud.c"

RECORD = CAPTURE / "rtsp-record.sh"
STREAM = CAPTURE / "rtsp-stream.sh"
FLICKER = CAMERA / "au-flicker-test.sh"

pytestmark = pytest.mark.skipif(
    not PIPELINE.exists() or not HUD.exists(),
    reason="userspace submodule not checked out",
)


def test_the_mount_path_matches_what_the_pipeline_serves() -> None:
    """The URL is built by hand host-side and registered by hand in the pipeline."""
    served = re.search(r'gst_rtsp_mount_points_add_factory\(mounts,\s*"([^"]+)"',
                       PIPELINE.read_text())
    assert served, "mlp-rtsp.c no longer registers a mount point in the expected shape"

    mount = served.group(1)

    for script in (RECORD, STREAM):
        assert mount in script.read_text(), f"{script.name} does not use the served mount {mount}"


def test_the_serving_log_line_is_the_one_the_pipeline_prints() -> None:
    """Both helpers detect the stream by grepping the pipeline's own announcement."""
    text = PIPELINE.read_text()
    assert 'RTSP serving rtsp://0.0.0.0:%s/venc8/stream (%s)' in text, \
        "the announcement mlp-rtsp.c prints changed shape; the greps below will not match it"

    for script in (RECORD, STREAM):
        assert "RTSP serving" in script.read_text(), \
            f"{script.name} no longer looks for the pipeline's announcement"


def test_the_recorder_refuses_a_codec_it_cannot_record() -> None:
    """H.265 only, and it has to check rather than assume.

    ML_DVR_CODEC can select H.264. Recording that through an h265 depayloader yields a valid MP4
    containing no frames, which is indistinguishable from a dead link, so the recorder must reject
    the case rather than carry a second pipeline for a build nothing ships.
    """
    text = RECORD.read_text()

    assert "rtph265depay" in text
    assert re.search(r'\[ "\$CODEC" != h265 \]', text), \
        "rtsp-record.sh no longer checks the codec it was given"


def test_the_settings_keys_are_the_ones_the_hud_reads() -> None:
    """rtsp-stream.sh writes the intent the HUD reconciles against; a rename silently does nothing.

    record_osd is in here because the burn-in gate treats the restream as the recording's twin, so
    leaving it on burns OSD glyphs into every frame a measurement is taken from.
    """
    hud = HUD.read_text()
    stream = STREAM.read_text()

    for section, key in (("dvr", "rtsp_stream"), ("dvr", "record_osd")):
        assert re.search(rf'settings_get_bool_in\([^,]+,\s*"{section}",\s*"{key}"', hud), \
            f"the HUD no longer reads {section}.{key}"
        assert key in stream, f"rtsp-stream.sh no longer writes {key}"


def test_the_flicker_harness_addresses_the_goggle_it_was_given() -> None:
    """Both goggle-side helpers resolve their target from the device profile unless told otherwise.

    The harness takes the goggle address in GG, so it has to pass that through. Without it the
    helpers talk to whatever the active device profile names, which is the right unit by accident
    on a default setup and the wrong one as soon as GG is overridden.
    """
    text = FLICKER.read_text()
    called = [line for line in text.splitlines()
              if "rtsp-stream.sh" in line or "rtsp-record.sh" in line]
    invocations = [line for line in called
                   if line.lstrip().startswith(("\"$REPO", "GOGGLE_IP"))]

    assert invocations, "the harness no longer calls the goggle-side helpers"

    passed = len(re.findall(r'GOGGLE_IP="\$GG" GOGGLE_PASS="\$PASS"', text))

    assert passed >= len(invocations), (
        f"{len(invocations)} helper invocations but only {passed} carry GOGGLE_IP/GOGGLE_PASS")
