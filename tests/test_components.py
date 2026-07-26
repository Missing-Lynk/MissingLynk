"""
The component framework: config round-trips, boot-hook generation, install, uninstall, status.

install() is exercised end-to-end against FakeGoggle with a substitute COMPONENTS list, so the
test does not depend on which build artifacts happen to exist. The generated boot hook is checked
with the host's own `sh -n`: it is the file that runs in place of the stock run.sh, so a syntax
error in it is a bricked boot, and that check must not rely on reaching a device.
"""
from __future__ import annotations

import shutil
import subprocess

import pytest

from missinglynk import components
from missinglynk.components import (
    APPLIED,
    BUILDTIME,
    CONFIG,
    ML_BIN,
    ML_DIR,
    RUN_DBG,
    RUN_SH,
    START_SH,
    STOCK_BUILDTIME,
    Component,
)

from .conftest import FakeGoggle

# A stock run.sh: the marker _extract_body splits on (with the `fi` that immediately follows it,
# which the split drops), then the three services the extracted body must contain.
STOCK_RUN_SH = b"""#!/bin/sh
if [ -f /usrdata/run_dbg.sh ]; then
    /usrdata/run_dbg.sh
    exit 0
else
echo "run normal..."
fi
usb_gadget_configfs.sh
ar_lowdelay &
servicemanager &
"""


@pytest.fixture
def installed_goggle(goggle: FakeGoggle) -> FakeGoggle:
    """A unit that looks stock and ready for install: run.sh present, buildtime present."""
    goggle.add_file(RUN_SH, STOCK_RUN_SH)
    goggle.add_file(STOCK_BUILDTIME, b"20240101\n")
    return goggle


@pytest.fixture
def two_components(tmp_path, monkeypatch: pytest.MonkeyPatch) -> list[Component]:
    """Replace COMPONENTS with two locally-backed ones, so install() has real files to push."""
    binary = tmp_path / "fbtext"
    binary.write_bytes(b"\x7fELF fake")

    substitute = [
        Component(name="rtsp", summary="patched stream server", default_on=False,
                  files=[(str(binary), "ar_lowdelay.patched")],
                  bind_mount=("ar_lowdelay.patched", "/usr/bin/ar_lowdelay"),
                  hud_label="RTSP"),
        Component(name="indicator", summary="on-screen HUD", default_on=True,
                  files=[(str(binary), "fbtext")]),
    ]
    monkeypatch.setattr(components, "COMPONENTS", substitute)
    monkeypatch.setattr(components, "ALWAYS_FILES", [])

    return substitute


# --- the real component table ---

def test_every_component_is_well_formed() -> None:
    for component in components.COMPONENTS:
        assert component.name and component.name.islower()
        assert component.summary
        assert isinstance(component.default_on, bool)
        for local, remote in component.files:
            assert local and remote
            assert "/" not in remote   # a bare basename; install() prefixes ML_BIN


def test_component_names_are_unique() -> None:
    names = [component.name for component in components.COMPONENTS]

    assert len(set(names)) == len(names)


def test_a_bind_mounted_component_declares_the_file_it_mounts() -> None:
    """The hook mounts $ML/bin/<basename>, so that basename has to be one the component pushes."""
    for component in components.COMPONENTS:
        if component.bind_mount is None:
            continue

        pushed = {remote for _, remote in component.files}
        assert component.bind_mount[0] in pushed, component.name


def test_a_component_with_no_local_artifact_still_says_how_to_build_it() -> None:
    for component in components.COMPONENTS:
        if component.files:
            assert component.build_hint, component.name


def test_lookup_of_an_unknown_component_names_the_known_ones() -> None:
    with pytest.raises(ValueError, match="unknown component 'nope'"):
        components._component("nope")


# --- config file ---

def test_parse_kv_ignores_comments_and_blank_lines() -> None:
    parsed = components._parse_kv("# header\n\nrtsp=on\n  indicator = off \nnonsense\n")

    assert parsed == {"rtsp": "on", "indicator": "off"}


def test_write_config_then_read_config_round_trips(goggle: FakeGoggle) -> None:
    components.write_config(goggle, {"rtsp": "on"})

    config = components.read_config(goggle)
    assert config["rtsp"] == "on"
    # every known component gets a line, so a fresh CLI never reads a missing key
    assert set(config) == {component.name for component in components.COMPONENTS}


def test_write_config_defaults_an_unnamed_component_to_off(goggle: FakeGoggle) -> None:
    components.write_config(goggle, {})

    assert set(components.read_config(goggle).values()) == {"off"}


def test_read_config_on_an_uninstalled_unit_says_so(goggle: FakeGoggle) -> None:
    with pytest.raises(RuntimeError, match="not installed"):
        components.read_config(goggle)


def test_set_enabled_flips_only_the_named_component(goggle: FakeGoggle) -> None:
    components.write_config(goggle, {"rtsp": "off", "indicator": "off"})
    components.set_enabled(goggle, "rtsp", True)

    config = components.read_config(goggle)
    assert config["rtsp"] == "on"
    assert config["indicator"] == "off"


def test_set_enabled_rejects_an_unknown_component(goggle: FakeGoggle) -> None:
    components.write_config(goggle, {})

    with pytest.raises(ValueError):
        components.set_enabled(goggle, "nope", True)


# --- boot hook generation ---

def test_extract_body_rejects_a_run_sh_it_cannot_parse() -> None:
    with pytest.raises(RuntimeError, match="no 'run normal' marker"):
        components._extract_body("#!/bin/sh\nexit 0\n")


def test_extract_body_refuses_a_body_missing_a_stock_service() -> None:
    """The body is copied verbatim into our hook; losing a service there breaks USB/SSH."""
    truncated = STOCK_RUN_SH.decode().replace("servicemanager &", "")

    with pytest.raises(RuntimeError, match="servicemanager"):
        components._extract_body(truncated)


def test_extract_body_keeps_the_stock_services() -> None:
    body = components._extract_body(STOCK_RUN_SH.decode())

    assert "usb_gadget_configfs.sh" in body
    assert "servicemanager" in body
    assert 'echo "run normal..."' not in body


def test_render_template_rejects_a_placeholder_with_no_value() -> None:
    with pytest.raises(KeyError, match="RUN_SH"):
        components._render_template("boot-hook.sh", {})


@pytest.mark.skipif(shutil.which("sh") is None, reason="needs a POSIX sh to syntax-check")
def test_generated_hook_passes_a_shell_syntax_check(tmp_path) -> None:
    """`sh -n` on the host, so a hook that will not parse is caught before a device sees it."""
    hook = components._gen_hook(components._extract_body(STOCK_RUN_SH.decode()))
    hook_path = tmp_path / "run_dbg.sh"
    hook_path.write_text(hook)

    result = subprocess.run(["sh", "-n", str(hook_path)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


def test_generated_hook_covers_every_component_and_runs_the_stock_body() -> None:
    hook = components._gen_hook(components._extract_body(STOCK_RUN_SH.decode()))

    for component in components.COMPONENTS:
        assert f"{component.name}=" in hook, component.name
        if component.bind_mount:
            assert component.bind_mount[1] in hook

    assert "usb_gadget_configfs.sh" in hook
    assert "servicemanager" in hook


def test_generated_hook_keeps_the_escape_hatch(two_components: list[Component]) -> None:
    """Holding BACK at power-on must still be able to skip us, whatever the component list is."""
    hook = components._gen_hook(components._extract_body(STOCK_RUN_SH.decode()))

    assert components.SKIP_ADC in hook
    assert str(components.SKIP_MV_MIN) in hook
    assert str(components.SKIP_MV_MAX) in hook


# --- install / uninstall / status ---

def test_install_pushes_files_writes_the_config_and_arms_the_hook(
        installed_goggle: FakeGoggle, two_components: list[Component]) -> None:
    components.install(installed_goggle)

    assert f"{ML_BIN}/ar_lowdelay.patched" in installed_goggle.files
    assert f"{ML_BIN}/fbtext" in installed_goggle.files
    assert CONFIG in installed_goggle.files
    assert START_SH in installed_goggle.files
    # the hook is armed by copying it to the path run.sh actually executes
    assert installed_goggle.files[RUN_DBG] == installed_goggle.files[START_SH]


def test_install_matches_the_buildtime_so_the_next_boot_does_not_wipe_usrdata(
        installed_goggle: FakeGoggle, two_components: list[Component]) -> None:
    components.install(installed_goggle)

    assert installed_goggle.files[BUILDTIME] == installed_goggle.files[STOCK_BUILDTIME]


def test_install_applies_the_declared_defaults_on_a_fresh_unit(
        installed_goggle: FakeGoggle, two_components: list[Component]) -> None:
    components.install(installed_goggle)

    config = components.read_config(installed_goggle)
    assert config == {"rtsp": "off", "indicator": "on"}


def test_reinstall_preserves_what_the_operator_had_enabled(
        installed_goggle: FakeGoggle, two_components: list[Component]) -> None:
    components.install(installed_goggle)
    components.set_enabled(installed_goggle, "rtsp", True)
    components.set_enabled(installed_goggle, "indicator", False)
    components.install(installed_goggle)

    config = components.read_config(installed_goggle)
    assert config == {"rtsp": "on", "indicator": "off"}


def test_install_refuses_when_a_declared_artifact_is_missing(
        installed_goggle: FakeGoggle, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(components, "COMPONENTS", [
        Component(name="rtsp", summary="patched stream server", default_on=False,
                  files=[("/nonexistent/ar_lowdelay", "ar_lowdelay.patched")],
                  build_hint="build it first")])
    monkeypatch.setattr(components, "ALWAYS_FILES", [])

    with pytest.raises(FileNotFoundError, match="build it first"):
        components.install(installed_goggle)

    assert START_SH not in installed_goggle.files


def test_install_does_not_arm_a_hook_that_fails_its_syntax_check(
        installed_goggle: FakeGoggle, two_components: list[Component]) -> None:
    """A hook that will not parse must never reach run_dbg.sh: that boot would not come back."""
    installed_goggle.sh_n_status = 1

    with pytest.raises(OSError, match="failed syntax check"):
        components.install(installed_goggle)

    assert START_SH not in installed_goggle.files
    assert RUN_DBG not in installed_goggle.files


def test_uninstall_removes_everything_it_installed(
        installed_goggle: FakeGoggle, two_components: list[Component]) -> None:
    components.install(installed_goggle)
    installed_goggle.add_file(APPLIED, b"rtsp=on\n")

    components.uninstall(installed_goggle)

    assert RUN_DBG not in installed_goggle.files
    assert BUILDTIME not in installed_goggle.files
    assert APPLIED not in installed_goggle.files
    assert not [path for path in installed_goggle.files if path.startswith(ML_DIR + "/")]


def test_uninstall_leaves_the_stock_boot_untouched(
        installed_goggle: FakeGoggle, two_components: list[Component]) -> None:
    components.install(installed_goggle)
    components.uninstall(installed_goggle)

    assert installed_goggle.files[RUN_SH] == STOCK_RUN_SH


def test_status_on_an_uninstalled_unit(goggle: FakeGoggle) -> None:
    assert components.status(goggle) == "MissingLynk: not installed"


def test_status_flags_a_config_change_that_needs_a_reboot(
        installed_goggle: FakeGoggle, two_components: list[Component]) -> None:
    components.install(installed_goggle)
    installed_goggle.add_file(APPLIED, b"rtsp=off\nindicator=on\n")
    components.set_enabled(installed_goggle, "rtsp", True)

    report = components.status(installed_goggle)
    assert "needs reboot to apply" in report
    assert "[active]" in report      # indicator: configured on and applied on


def test_status_warns_on_a_buildtime_mismatch(
        installed_goggle: FakeGoggle, two_components: list[Component]) -> None:
    """A mismatch means run.sh wipes /usrdata on the next boot; that has to be loud."""
    components.install(installed_goggle)
    installed_goggle.add_file(BUILDTIME, b"different\n")

    assert "buildtime mismatch" in components.status(installed_goggle)


def test_status_shows_the_stream_url_only_when_rtsp_is_live(
        installed_goggle: FakeGoggle, two_components: list[Component]) -> None:
    components.install(installed_goggle)
    installed_goggle.add_file(APPLIED, b"rtsp=off\n")
    assert "rtsp://" not in components.status(installed_goggle)

    installed_goggle.add_file(APPLIED, b"rtsp=on\n")
    assert f"rtsp://{installed_goggle.ip}:554/" in components.status(installed_goggle)
