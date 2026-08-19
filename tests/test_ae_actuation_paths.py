"""
Guard the sysfs and debugfs paths `ml-aed` writes against the driver that has to provide them.

Every actuation `ml-aed` performs is a write to a path spelled out as a string literal in
`ml-aed.c`. A typo, or a driver rename, produces no build error and no test failure: it fails as
`ENOENT` on the air unit, mid-session, with the camera live. These tests turn that into a host-side
failure by reading both sides and requiring them to agree.

The same applies to the harnesses under `glue/camera/`, which read the same nodes to judge a run.
"""

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "kernel" / "overlay" / "drivers" / "media" / "artosyn"
AED = ROOT / "userspace" / "ml-aed" / "ml-aed.c"
GLUE = ROOT / "glue" / "camera"

pytestmark = pytest.mark.skipif(
    not DRIVER.exists() or not AED.exists(),
    reason="kernel or userspace submodule not checked out",
)

SYSFS = re.compile(r"/sys/module/(\w+)/parameters/(\w+)")
DEBUGFS = re.compile(r"/sys/kernel/debug/ar-isp/(\w+)")


def driver_text() -> str:
    return "\n".join(p.read_text() for p in sorted(DRIVER.glob("*.c")))


def module_params(text: str, module: str) -> set[str]:
    """Parameter names the named driver exposes under /sys/module/<module>/parameters/."""
    out: set[str] = set()

    # nt99235 is one file; ar_isp is the rest of the directory. Splitting by file keeps a
    # parameter of one module from satisfying a path that names the other.
    if module == "nt99235":
        text = (DRIVER / "nt99235.c").read_text()

    # Four spellings are in use: plain, _named, _cb (the sensor's live exposure and gain)
    # and _array. All four create the same /sys/module/<m>/parameters/<name> node.
    for match in re.finditer(r"^module_param(?:_named|_cb|_array)?\(\s*(\w+)", text, re.M):
        out.add(match.group(1))

    return out


def debugfs_nodes(text: str) -> set[str]:
    """Node names created under the ar-isp debugfs directory, in any of the forms used."""
    out: set[str] = set()

    for pattern in (
        r'debugfs_create_file(?:_unsafe)?\(\s*"([^"]+)"',
        r'debugfs_create_(?:u32|u64|x32|bool|ulong)\(\s*"([^"]+)"',
    ):
        out.update(re.findall(pattern, text))

    return out


def paths_in(path: Path, pattern: re.Pattern[str]) -> set[tuple[str, ...]]:
    return {m.groups() for m in pattern.finditer(path.read_text())}


def test_ml_aed_writes_only_parameters_the_driver_exposes() -> None:
    """Each /sys/module/<m>/parameters/<p> ml-aed writes is a real module_param."""
    text = driver_text()
    missing = []

    for module, param in sorted(paths_in(AED, SYSFS)):
        if param not in module_params(text, module):
            missing.append(f"/sys/module/{module}/parameters/{param}")

    assert not missing, f"ml-aed writes parameters no driver exposes: {missing}"


def test_ml_aed_uses_only_debugfs_nodes_the_driver_creates() -> None:
    """Each /sys/kernel/debug/ar-isp/<node> ml-aed writes is really created."""
    nodes = debugfs_nodes(driver_text())
    missing = [n for (n,) in sorted(paths_in(AED, DEBUGFS)) if n not in nodes]

    assert not missing, f"ml-aed writes debugfs nodes ar-isp does not create: {missing}"


def test_the_tone_path_drives_every_stage_that_keys_on_the_scalar() -> None:
    """gamma and DRC take tone_scalar; cm and cm2 take the same scalar, so all four move together.

    Driving only gamma and DRC leaves cm/cm2 pinned at the driver default, which is a different
    operating point from the one the rest of the frame is being built at.
    """
    body = re.search(
        r"static int ae_actuate_tone\(.*?\n\}", AED.read_text(), re.S
    )
    assert body, "ae_actuate_tone not found in ml-aed.c"

    for macro in ("ISP_TONE_SCALAR", "ISP_CM_TRIGGER", "ISP_CM2_TRIGGER"):
        assert macro in body.group(0), f"ae_actuate_tone does not write {macro}"

    # cm/cm2 are packed by the ladder path, so their bank needs that hook, not the tone one.
    for hook in ("TONE_ARM_PATH", "LADDER_ARM_PATH"):
        assert hook in body.group(0), f"ae_actuate_tone does not fire {hook}"


def test_the_decision_line_records_the_scalar_it_actuated() -> None:
    """The log is the record of what was computed; a reader must not have to recompute it."""
    text = AED.read_text()
    assert "tone %d" in text, "the decision line does not carry the actuated scalar"

    loop = re.search(r"tone_q8 = .*?ae_actuate_tone\(opts, tone_q8\)", text, re.S)
    assert loop, "the logged scalar and the actuated scalar are not the same value"


@pytest.mark.skipif(not GLUE.exists(), reason="glue not present")
def test_camera_harnesses_read_only_nodes_the_driver_creates() -> None:
    """A harness that reads a renamed node reports a flat counter rather than an error."""
    nodes = debugfs_nodes(driver_text())
    missing: list[str] = []

    for script in sorted(GLUE.glob("au-*.sh")):
        for (node,) in sorted(paths_in(script, DEBUGFS)):
            if node not in nodes:
                missing.append(f"{script.name}: {node}")

    assert not missing, f"harnesses read debugfs nodes ar-isp does not create: {missing}"
