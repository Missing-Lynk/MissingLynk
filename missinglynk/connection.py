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

import paramiko

from . import GOGGLE_IP, GOGGLE_USER, GOGGLE_PASS
from .progress import ProgressCb

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
                 password: str = GOGGLE_PASS, port: int = 22, timeout: float = 8.0) -> None:
        self.ip: str = ip
        self.user: str = user
        self.password: str = password
        self.port: int = port
        self.timeout: float = timeout
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

    def run(self, command: str) -> tuple[bytes, bytes, int]:
        """Returns (stdout, stderr, exit_status)."""
        assert self._transport is not None, "not connected"
        channel: paramiko.Channel = self._transport.open_session(timeout=self.timeout)
        channel.exec_command(command)
        stdout: bytes = b""
        stderr: bytes = b""
        while True:
            if channel.recv_ready():
                stdout += channel.recv(65536)
                continue

            if channel.recv_stderr_ready():
                stderr += channel.recv_stderr(65536)
                continue

            if channel.exit_status_ready() and not channel.recv_ready() \
                    and not channel.recv_stderr_ready():
                break

            # block until readable (fileno() makes paramiko channels selectable)
            select.select([channel], [], [], 0.1)

        exit_status: int = channel.recv_exit_status()
        channel.close()
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
        assert self._transport is not None, "not connected"
        channel: paramiko.Channel = self._transport.open_session(timeout=self.timeout)
        channel.exec_command(f"cat > {shlex.quote(path)}")
        total: int = len(data)
        view: memoryview = memoryview(data)
        sent: int = 0

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
        channel.close()
        if exit_status != 0:
            raise IOError(f"write {path} failed (rc={exit_status})")

    def read_stream(self, command: str, expected_bytes: int | None = None,
                    on_progress: ProgressCb | None = None) -> bytes:
        """
        Run `command` and collect its stdout, reporting progress as bytes arrive.

        `on_progress(done, total)` is called as data streams in (total may be None).
        Used to pull large outputs (e.g. a slice of /dev/fb0) with a progress bar.
        """
        assert self._transport is not None, "not connected"
        channel: paramiko.Channel = self._transport.open_session(timeout=self.timeout)
        channel.exec_command(command)
        received: bytearray = bytearray()
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
        channel.close()

        return bytes(received)
