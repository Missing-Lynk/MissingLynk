"""
Argument parsing and target resolution in cli.main().

No command body runs: `status` is the vehicle, and the connect() it would use is replaced with a
recorder, so these assert on what the CLI decided to talk to rather than on any device behaviour.
default_target is stubbed everywhere, so no test opens a socket.
"""
from __future__ import annotations

import pytest

from missinglynk import GOGGLE_PASS, STOCK_IP, STOCK_PASS, cli
from missinglynk.commands import component as component_command

from .conftest import FakeGoggle

SUBCOMMANDS = ("install", "uninstall", "enable", "disable", "status",
               "screenshot", "identify", "dump-firmware", "fetch-blobs", "dump-partitions")


@pytest.fixture
def recorded_connect(monkeypatch: pytest.MonkeyPatch) -> list:
    """Replace the `status` path's connect() with one that records the resolved target."""
    calls: list = []

    def connect(args) -> FakeGoggle:
        calls.append(args)
        goggle = FakeGoggle(ip=args.ip)
        goggle.canned("[ -d", b"")          # reports not-installed, so status returns immediately
        return goggle

    monkeypatch.setattr(component_command, "connect", connect)
    monkeypatch.setattr(cli, "default_target", lambda port: ("192.168.3.101", GOGGLE_PASS))

    return calls


# --- parser shape ---

def test_top_level_help_exits_zero(capsys: pytest.CaptureFixture) -> None:
    with pytest.raises(SystemExit) as raised:
        cli.main(["--help"])

    assert raised.value.code == 0
    assert "missinglynk" in capsys.readouterr().out


@pytest.mark.parametrize("subcommand", SUBCOMMANDS)
def test_each_subcommand_help_exits_zero(subcommand: str) -> None:
    with pytest.raises(SystemExit) as raised:
        cli.main([subcommand, "--help"])

    assert raised.value.code == 0


def test_version_exits_zero() -> None:
    with pytest.raises(SystemExit) as raised:
        cli.main(["--version"])

    assert raised.value.code == 0


def test_no_subcommand_is_an_error() -> None:
    with pytest.raises(SystemExit) as raised:
        cli.main([])

    assert raised.value.code != 0


def test_unknown_subcommand_is_an_error() -> None:
    with pytest.raises(SystemExit) as raised:
        cli.main(["definitely-not-a-command"])

    assert raised.value.code != 0


def test_enable_rejects_an_unknown_component_name() -> None:
    """argparse choices come from COMPONENTS, so a typo fails before anything connects."""
    with pytest.raises(SystemExit) as raised:
        cli.main(["enable", "not-a-component"])

    assert raised.value.code != 0


# --- target resolution ---

def test_auto_detects_the_target_when_no_ip_is_given(recorded_connect: list) -> None:
    assert cli.main(["status"]) == 0

    args = recorded_connect[0]
    assert args.ip == "192.168.3.101"
    assert args.password == GOGGLE_PASS


def test_an_explicit_ip_skips_auto_detection(monkeypatch: pytest.MonkeyPatch,
                                             recorded_connect: list) -> None:
    def refuse(port: int) -> tuple[str, str]:
        raise AssertionError("auto-detection must not run when --ip was given")

    monkeypatch.setattr(cli, "default_target", refuse)
    cli.main(["--ip", "10.0.0.5", "status"])

    assert recorded_connect[0].ip == "10.0.0.5"


def test_the_password_follows_the_slot_the_ip_names(recorded_connect: list) -> None:
    cli.main(["--ip", STOCK_IP, "status"])
    assert recorded_connect[0].password == STOCK_PASS

    cli.main(["--ip", "192.168.3.102", "status"])
    assert recorded_connect[1].password == GOGGLE_PASS


def test_an_explicit_password_wins(recorded_connect: list) -> None:
    cli.main(["--ip", STOCK_IP, "--password", "custom", "status"])

    assert recorded_connect[0].password == "custom"


def test_the_port_reaches_the_command(recorded_connect: list) -> None:
    """The air unit is reached through the goggle relay, so --port has to be carried through."""
    cli.main(["--port", "8822", "status"])

    assert recorded_connect[0].port == 8822


def test_the_port_defaults_to_ssh(recorded_connect: list) -> None:
    cli.main(["status"])

    assert recorded_connect[0].port == 22


def test_the_port_is_passed_to_auto_detection(monkeypatch: pytest.MonkeyPatch,
                                              recorded_connect: list) -> None:
    """Probing :22 while the caller asked for the relay port would detect the wrong unit."""
    probed: list[int] = []

    def record(port: int) -> tuple[str, str]:
        probed.append(port)
        return "192.168.3.101", GOGGLE_PASS

    monkeypatch.setattr(cli, "default_target", record)
    cli.main(["--port", "8822", "status"])

    assert probed == [8822]


# --- error handling ---

def test_a_command_error_becomes_a_message_and_a_nonzero_exit(
        monkeypatch: pytest.MonkeyPatch, recorded_connect: list,
        capsys: pytest.CaptureFixture) -> None:
    def explode(args) -> FakeGoggle:
        raise RuntimeError("device fell over")

    monkeypatch.setattr(component_command, "connect", explode)

    assert cli.main(["status"]) == 1
    assert "device fell over" in capsys.readouterr().err


def test_debug_re_raises_instead_of_swallowing(monkeypatch: pytest.MonkeyPatch,
                                               recorded_connect: list) -> None:
    def explode(args) -> FakeGoggle:
        raise RuntimeError("device fell over")

    monkeypatch.setattr(component_command, "connect", explode)

    with pytest.raises(RuntimeError):
        cli.main(["--debug", "status"])
