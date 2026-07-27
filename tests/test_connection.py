"""
connection.Goggle: target auto-detection, algorithm promotion, and channel lifetime.

No paramiko transport is involved. Goggle._transport is replaced with a stub that hands out a
scripted channel, which is the whole surface run() / read_stream() / write_file() touch. The
wedged-device cases matter most: every one of them used to be able to hang the CLI forever.
"""
from __future__ import annotations

import os
import time

import pytest

from missinglynk import GOGGLE_IP, GOGGLE_PASS, STOCK_IP, STOCK_PASS
from missinglynk import connection as connection_module
from missinglynk.connection import Goggle, _promote, default_target


class FakeChannel:
    """A channel that answers once with canned data and then reports the command finished."""

    def __init__(self, stdout: bytes = b"", stderr: bytes = b"", exit_status: int = 0) -> None:
        self._stdout = stdout
        self._stderr = stderr
        self._exit_status = exit_status
        self.closed = False
        self.command: str | None = None
        self.timeout: float | None = None
        self.sent = bytearray()
        self.write_shutdown = False

    def exec_command(self, command: str) -> None:
        self.command = command

    def settimeout(self, seconds: float) -> None:
        self.timeout = seconds

    def recv_ready(self) -> bool:
        return bool(self._stdout)

    def recv_stderr_ready(self) -> bool:
        return bool(self._stderr)

    def recv(self, size: int) -> bytes:
        chunk, self._stdout = self._stdout[:size], self._stdout[size:]
        return chunk

    def recv_stderr(self, size: int) -> bytes:
        chunk, self._stderr = self._stderr[:size], self._stderr[size:]
        return chunk

    def exit_status_ready(self) -> bool:
        return True

    def recv_exit_status(self) -> int:
        return self._exit_status

    def send(self, view: memoryview) -> int:
        self.sent += bytes(view)
        return len(view)

    def shutdown_write(self) -> None:
        self.write_shutdown = True

    def close(self) -> None:
        self.closed = True


class SilentChannel(FakeChannel):
    """Never ready, never exits: what a wedged device looks like to run()."""

    def __init__(self) -> None:
        super().__init__()
        # run() selects on the channel, so it needs a real fd. A pipe's read end is never
        # readable while nothing writes to it, which is exactly a device that stopped talking.
        self._read_fd, self._write_fd = os.pipe()

    def recv_ready(self) -> bool:
        return False

    def recv_stderr_ready(self) -> bool:
        return False

    def exit_status_ready(self) -> bool:
        return False

    def fileno(self) -> int:
        return self._read_fd

    def close(self) -> None:
        super().close()
        os.close(self._read_fd)
        os.close(self._write_fd)


class StallingChannel(FakeChannel):
    """Moves `chunks` chunks, then behaves like a device that stopped talking mid-transfer."""

    def __init__(self, chunks: int = 1, stall_on_send: bool = False) -> None:
        super().__init__()
        self._left = chunks
        self._stall_on_send = stall_on_send

    def recv(self, size: int) -> bytes:
        if self._left > 0:
            self._left -= 1
            return b"data"

        raise TimeoutError("timed out")

    def send(self, view: memoryview) -> int:
        if self._stall_on_send and self._left <= 0:
            raise TimeoutError("timed out")

        self._left -= 1
        return len(view)


class NeverExitsChannel(FakeChannel):
    """Accepts the data, then never reports an exit status: the gadget dying after a push."""

    def exit_status_ready(self) -> bool:
        return False


class FakeTransport:
    def __init__(self, channel: FakeChannel) -> None:
        self.channel = channel

    def open_session(self, timeout: float | None = None) -> FakeChannel:
        return self.channel


def connected(channel: FakeChannel, idle_timeout: float = 120.0) -> Goggle:
    goggle = Goggle(idle_timeout=idle_timeout)
    goggle._transport = FakeTransport(channel)
    return goggle


# --- auto-detection ---

def test_default_target_prefers_a_reachable_stock_unit(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(connection_module, "_tcp_open", lambda ip, port, **kw: ip == STOCK_IP)
    assert default_target() == (STOCK_IP, STOCK_PASS)


def test_default_target_falls_back_to_the_open_scan(monkeypatch: pytest.MonkeyPatch) -> None:
    """With no stock unit, the first open address that answers wins, with the open password."""
    monkeypatch.setattr(connection_module, "_tcp_open",
                        lambda ip, port, **kw: ip == "192.168.3.103")
    assert default_target() == ("192.168.3.103", GOGGLE_PASS)


def test_default_target_returns_a_real_candidate_when_nothing_answers(
        monkeypatch: pytest.MonkeyPatch) -> None:
    """Nothing reachable still yields an address, so the caller fails with a connect error."""
    monkeypatch.setattr(connection_module, "_tcp_open", lambda ip, port, **kw: False)
    assert default_target() == (GOGGLE_IP, GOGGLE_PASS)


def test_default_target_probes_a_bounded_number_of_addresses(
        monkeypatch: pytest.MonkeyPatch) -> None:
    """The scan must terminate: one stock probe plus a fixed open window, and no more."""
    probed: list[str] = []

    def record(ip: str, port: int, **kw: object) -> bool:
        probed.append(ip)
        return False

    monkeypatch.setattr(connection_module, "_tcp_open", record)
    default_target()

    assert probed[0] == STOCK_IP
    assert len(probed) == 1 + connection_module._OPEN_SCAN_COUNT
    assert len(set(probed)) == len(probed)


def test_tcp_open_reports_a_refused_port_as_unreachable() -> None:
    """The probe swallows OSError rather than propagating it (port 1 on localhost is closed)."""
    assert connection_module._tcp_open("127.0.0.1", 1, timeout=0.2) is False


# --- algorithm promotion ---

def test_promote_puts_the_legacy_algorithms_first_without_dropping_any() -> None:
    promoted = _promote(("modern-a", "modern-b"), ("legacy-a",))

    assert promoted[0] == "legacy-a"
    assert set(promoted) == {"legacy-a", "modern-a", "modern-b"}


def test_promote_does_not_duplicate_an_already_offered_algorithm() -> None:
    promoted = _promote(("modern", "legacy"), ("legacy",))

    assert promoted == ("legacy", "modern")


# --- run / read / write ---

def test_run_returns_stdout_stderr_and_status_and_closes_the_channel() -> None:
    channel = FakeChannel(stdout=b"hello", stderr=b"warn", exit_status=3)

    assert connected(channel).run("echo hello") == (b"hello", b"warn", 3)
    assert channel.closed


def test_read_file_shell_quotes_the_path() -> None:
    channel = FakeChannel(stdout=b"contents")
    connected(channel).read_file("/tmp/a b'c")

    assert channel.command == "cat '/tmp/a b'\"'\"'c'"


def test_read_file_raises_on_a_nonzero_status() -> None:
    channel = FakeChannel(stderr=b"No such file", exit_status=1)

    with pytest.raises(OSError, match="cat /nope failed"):
        connected(channel).read_file("/nope")


def test_read_stream_collects_the_output_and_closes() -> None:
    channel = FakeChannel(stdout=b"x" * 10)

    assert connected(channel).read_stream("cat /dev/thing") == b"x" * 10
    assert channel.closed


def test_read_stream_closes_the_channel_when_the_progress_callback_raises() -> None:
    """The channel is closed in a finally:, so a mid-transfer error cannot leak it."""
    channel = FakeChannel(stdout=b"x" * 10)

    def explode(done: int, total: int | None) -> None:
        raise RuntimeError("progress blew up")

    with pytest.raises(RuntimeError):
        connected(channel).read_stream("cat /dev/thing", on_progress=explode)

    assert channel.closed


def test_write_file_sends_the_payload_then_shuts_down_and_closes() -> None:
    channel = FakeChannel()
    connected(channel).write_file("/tmp/f", b"payload")

    assert bytes(channel.sent) == b"payload"
    assert channel.write_shutdown
    assert channel.closed


def test_write_file_raises_and_closes_on_a_nonzero_status() -> None:
    channel = FakeChannel(exit_status=1)

    with pytest.raises(OSError, match="write /tmp/f failed"):
        connected(channel).write_file("/tmp/f", b"payload")

    assert channel.closed


# --- wedged-device deadlines: each of these could otherwise hang the CLI forever ---

def test_run_aborts_when_the_device_goes_silent() -> None:
    channel = SilentChannel()
    started = time.monotonic()

    with pytest.raises(TimeoutError) as raised:
        connected(channel, idle_timeout=0.5).run("sleep forever")

    assert 0.4 < time.monotonic() - started < 3.0
    assert "sleep forever" in str(raised.value)
    assert GOGGLE_IP in str(raised.value)
    assert channel.closed


def test_run_is_not_cut_off_while_output_keeps_arriving() -> None:
    """The deadline is an inactivity window, not a total runtime limit."""
    channel = FakeChannel(stdout=b"tick")

    assert connected(channel, idle_timeout=0.5).run("echo tick")[0] == b"tick"


def test_read_stream_aborts_when_the_device_stops_sending() -> None:
    channel = StallingChannel(chunks=1)

    with pytest.raises(TimeoutError, match="cat /dev/wedged"):
        connected(channel, idle_timeout=0.5).read_stream("cat /dev/wedged")

    assert channel.closed
    assert channel.timeout == 0.5   # _session pushed the deadline onto the channel


def test_write_file_aborts_when_the_device_stops_accepting() -> None:
    channel = StallingChannel(chunks=0, stall_on_send=True)

    with pytest.raises(TimeoutError):
        connected(channel, idle_timeout=0.5).write_file("/tmp/f", b"payload")

    assert channel.closed


def test_write_file_aborts_when_the_exit_status_never_arrives() -> None:
    """paramiko's own recv_exit_status() has no timeout; _wait_exit_status supplies one."""
    channel = NeverExitsChannel()

    with pytest.raises(TimeoutError):
        connected(channel, idle_timeout=0.5).write_file("/tmp/f", b"payload")

    assert channel.closed


def test_read_stream_aborts_when_the_exit_status_never_arrives() -> None:
    channel = NeverExitsChannel(stdout=b"done")

    with pytest.raises(TimeoutError):
        connected(channel, idle_timeout=0.5).read_stream("cat /dev/thing")

    assert channel.closed
