"""
SSH connection to the goggle's legacy-crypto Dropbear, via paramiko.

The goggle only speaks old algorithms (KEX diffie-hellman-group1-sha1 /
group14-sha1, host key ssh-rsa, ciphers aes128-cbc / 3des-cbc).

Modern SSH stacks disable these by default. paramiko still implements them; we
just have to put them at the front of the negotiated lists so the connection
succeeds. Pure Python = cross-platform.
"""
from __future__ import annotations

import select
import shlex
import socket
import time
from collections.abc import Iterator
from contextlib import contextmanager

import paramiko

from . import GOGGLE_IP, GOGGLE_USER, GOGGLE_PASS, STOCK_IP, STOCK_PASS
from .progress import ProgressCb


def _tcp_open(ip: str, port: int, timeout: float = 1.0) -> bool:
    """True if a TCP connection to ip:port succeeds within timeout (a cheap reachability probe)."""
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except OSError:
        return False


# Open-slot devices sit at 192.168.3.101 and up (index NN, IP = 100 + NN). The auto-detect scan
# probes the stock address, then these in order, taking the first that answers.
_SUBNET: str = STOCK_IP.rsplit(".", 1)[0] + "."   # "192.168.3."
_OPEN_FIRST_OCTET: int = 101                       # 192.168.3.101 = open device index 1
_OPEN_SCAN_COUNT: int = 8                          # probe .101 .. .108 for a connected open device


def default_target(port: int = 22) -> tuple[str, str]:
    """
    Auto-detect the connected unit and return its (ip, password). Probes the stock address
    first (most commands act on the stock slot), then the open addresses .101 and up, taking the
    first that answers. The password follows the slot: artosyn for stock, libre for the open slot.
    Realistically one unit is connected, so this targets whichever it is; when none answers it
    returns the first open address, so a command fails with a clear connect error to a real
    candidate.
    """
    if _tcp_open(STOCK_IP, port):
        return STOCK_IP, STOCK_PASS

    for octet in range(_OPEN_FIRST_OCTET, _OPEN_FIRST_OCTET + _OPEN_SCAN_COUNT):
        ip: str = f"{_SUBNET}{octet}"
        if _tcp_open(ip, port):
            return ip, GOGGLE_PASS

    return GOGGLE_IP, GOGGLE_PASS

# How long a command may produce nothing at all - no stdout, no stderr, no exit status - before
# run() gives up. It bounds a wedged device (a hung command, a link that dropped without closing
# the channel), which otherwise polls forever. It is an INACTIVITY limit, not a total runtime
# limit, so a slow command that keeps producing output is never cut off. Generous by design: the
# quietest commands the CLI issues (md5sum over a few MB, cp between partitions) answer in
# seconds. Override per connection with Goggle(idle_timeout=...).
IDLE_TIMEOUT: float = 120.0

# Algorithms the goggle requires, promoted to the front of paramiko's lists.
_KEX: tuple[str, ...] = ("diffie-hellman-group1-sha1", "diffie-hellman-group14-sha1")
_CIPHERS: tuple[str, ...] = ("aes128-cbc", "3des-cbc")
_HOSTKEYS: tuple[str, ...] = ("ssh-rsa",)


def _promote(preferred: tuple[str, ...], wanted: tuple[str, ...]) -> tuple[str, ...]:
    """
    Force `wanted` to the front of the offered list (dedup, preserve order).

    The legacy algorithms are implemented in paramiko 3.5.x but NOT in its default
    preferred lists, so we must prepend them explicitly (not just reorder). The
    SecurityOptions setter validates names against the implemented set, raising
    ValueError on an unsupported paramiko (>=4), caught in __enter__ with a hint.
    """
    return tuple(dict.fromkeys(tuple(wanted) + tuple(preferred)))


class Goggle:
    """A live SSH connection to the goggle. Use as a context manager."""

    def __init__(self, ip: str = GOGGLE_IP, user: str = GOGGLE_USER,
                 password: str = GOGGLE_PASS, port: int = 22, timeout: float = 8.0,
                 idle_timeout: float = IDLE_TIMEOUT) -> None:
        self.ip: str = ip
        self.user: str = user
        self.password: str = password
        self.port: int = port
        self.timeout: float = timeout
        self.idle_timeout: float = idle_timeout
        self._transport: paramiko.Transport | None = None

    def __enter__(self) -> "Goggle":
        transport: paramiko.Transport = paramiko.Transport((self.ip, self.port))
        transport.banner_timeout = self.timeout
        options = transport.get_security_options()

        try:
            options.kex = _promote(options.kex, _KEX)
            options.ciphers = _promote(options.ciphers, _CIPHERS)
            options.key_types = _promote(options.key_types, _HOSTKEYS)
        except ValueError as e:
            transport.close()
            raise RuntimeError(
                "This paramiko lacks the goggle's legacy SSH algorithms "
                f"({e}). Install paramiko 3.5.x (pip install 'paramiko>=3.5,<4')."
            ) from e

        transport.connect(username=self.user, password=self.password)
        self._transport = transport

        return self

    def __exit__(self, *exc: object) -> None:
        if self._transport is not None:
            self._transport.close()
            self._transport = None

    @contextmanager
    def _session(self, command: str) -> Iterator[paramiko.Channel]:
        """
        Open a channel, start `command` on it, and close it however the caller leaves.

        Every remote call goes through here: closing only on the success path leaks the
        channel whenever a transfer raises partway (a read error, a progress callback that
        throws, a KeyboardInterrupt), and the leak lasts until the whole transport closes.
        """
        assert self._transport is not None, "not connected"
        channel: paramiko.Channel = self._transport.open_session(timeout=self.timeout)

        try:
            channel.exec_command(command)
            yield channel
        finally:
            channel.close()

    def run(self, command: str) -> tuple[bytes, bytes, int]:
        """
        Returns (stdout, stderr, exit_status).

        Raises TimeoutError if the command goes silent for longer than self.idle_timeout: the
        loop runs only while the channel is still alive in that sense, so a wedged device ends
        the call instead of polling forever. Every byte received, on either stream, is activity.
        """
        stdout: bytes = b""
        stderr: bytes = b""
        finished: bool = False
        last_activity: float = time.monotonic()

        with self._session(command) as channel:
            while time.monotonic() - last_activity < self.idle_timeout:
                if channel.recv_ready():
                    stdout += channel.recv(65536)
                    last_activity = time.monotonic()
                    continue

                if channel.recv_stderr_ready():
                    stderr += channel.recv_stderr(65536)
                    last_activity = time.monotonic()
                    continue

                if channel.exit_status_ready() and not channel.recv_ready() \
                        and not channel.recv_stderr_ready():
                    finished = True
                    break

                # block until readable (fileno() makes paramiko channels selectable)
                select.select([channel], [], [], 0.1)

            if finished:
                exit_status: int = channel.recv_exit_status()

        if not finished:
            raise TimeoutError(
                f"no output and no exit status from `{command}` for {self.idle_timeout:g}s "
                f"on {self.ip} - the device or the command is wedged"
            )

        return stdout, stderr, exit_status

    def read_file(self, path: str) -> bytes:
        stdout, stderr, exit_status = self.run(f"cat {shlex.quote(path)}")
        if exit_status != 0:
            raise IOError(f"cat {path} failed (rc={exit_status}): "
                          f"{stderr.decode(errors='replace')}")

        return stdout

    def write_file(self, path: str, data: bytes,
                   on_progress: ProgressCb | None = None) -> None:
        # This Dropbear has no SFTP subsystem, so stream the bytes to `cat > path`.
        total: int = len(data)
        view: memoryview = memoryview(data)
        sent: int = 0

        with self._session(f"cat > {shlex.quote(path)}") as channel:
            if on_progress:
                on_progress(0, total)

            while sent < total:
                sent_now: int = channel.send(view[sent:sent + 65536])
                if sent_now == 0:
                    raise IOError("connection closed during write")
                sent += sent_now
                if on_progress:
                    on_progress(sent, total)

            channel.shutdown_write()
            exit_status: int = channel.recv_exit_status()

        if exit_status != 0:
            raise IOError(f"write {path} failed (rc={exit_status})")

    def read_stream(self, command: str, expected_bytes: int | None = None,
                    on_progress: ProgressCb | None = None) -> bytes:
        """
        Run `command` and collect its stdout, reporting progress as bytes arrive.

        `on_progress(done, total)` is called as data streams in (total may be None).
        Used to pull large outputs (e.g. a slice of /dev/fb0) with a progress bar.
        """
        received: bytearray = bytearray()

        with self._session(command) as channel:
            if on_progress:
                on_progress(0, expected_bytes)

            while True:
                chunk: bytes = channel.recv(65536)
                if not chunk:
                    break

                received += chunk
                if on_progress:
                    on_progress(len(received), expected_bytes)

            channel.recv_exit_status()

        return bytes(received)
