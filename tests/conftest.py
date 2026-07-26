"""
Shared fixtures. FakeGoggle stands in for a connected unit so the tests run with no device.

It replaces connection.Goggle at the same seam every caller uses: run() / read_file() /
write_file() / read_stream(). Behind those it keeps an in-memory filesystem and interprets the
small shell vocabulary the package actually issues (cat, md5sum, mkdir, cp, rm, cmp, test, sh -n,
[ -d ]), so a test can assert on what ended up on the device rather than on a call transcript.
Anything outside that vocabulary (grep, ps, find, ldd) is answered from canned responses the test
registers with canned(); an unregistered command raises, so a test can never silently pass on a
command the fake did not understand.
"""
from __future__ import annotations

import hashlib
import shlex

import pytest


class FakeGoggle:
    """An in-memory stand-in for connection.Goggle."""

    def __init__(self, ip: str = "192.168.3.100") -> None:
        self.ip: str = ip
        self.files: dict[str, bytes] = {}
        self.dirs: set[str] = {"/", "/tmp", "/usr", "/usr/bin", "/usrdata"}
        self.commands: list[str] = []

        # (substring, (stdout, exit_status)) consulted before the built-in verbs
        self._canned: list[tuple[str, tuple[bytes, int]]] = []

        # exit status returned by `sh -n` (set to non-zero to fake a bad generated script)
        self.sh_n_status: int = 0

    def canned(self, substring: str, stdout: bytes = b"", exit_status: int = 0) -> None:
        """Answer any command containing `substring` with this output, instead of running it."""
        self._canned.append((substring, (stdout, exit_status)))

    def add_file(self, path: str, data: bytes) -> None:
        self.files[path] = data
        self.dirs.add(path.rsplit("/", 1)[0] or "/")

    def run(self, command: str) -> tuple[bytes, bytes, int]:
        self.commands.append(command)

        for substring, (stdout, exit_status) in self._canned:
            if substring in command:
                return stdout, b"", exit_status

        stdout = b""
        exit_status = 0
        for segment in command.split(";"):
            if segment.strip():
                stdout, exit_status = self._run_segment(segment)

        return stdout, b"", exit_status

    def read_file(self, path: str) -> bytes:
        stdout, _, exit_status = self.run(f"cat {shlex.quote(path)}")
        if exit_status != 0:
            raise OSError(f"cat {path} failed (rc={exit_status})")

        return stdout

    def write_file(self, path: str, data: bytes, on_progress=None) -> None:
        self.add_file(path, data)
        if on_progress:
            on_progress(len(data), len(data))

    def read_stream(self, command: str, expected_bytes: int | None = None,
                    on_progress=None) -> bytes:
        stdout, _, _ = self.run(command)
        if on_progress:
            on_progress(len(stdout), expected_bytes)

        return stdout

    def __enter__(self) -> FakeGoggle:
        return self

    def __exit__(self, *exc: object) -> None:
        pass

    def _run_segment(self, segment: str) -> tuple[bytes, int]:
        """One `;`-free command, with `&& echo WORD` and stderr redirections handled here."""
        tail: str = ""
        if "&&" in segment:
            segment, _, tail = segment.partition("&&")

        tokens: list[str] = [t for t in shlex.split(segment)
                             if not t.startswith("2>") and not t.startswith(">/dev/null")]
        stdout, exit_status = self._run_tokens(tokens)
        if tail.strip() and exit_status == 0:
            stdout, exit_status = self._run_tokens(shlex.split(tail))

        return stdout, exit_status

    def _run_tokens(self, tokens: list[str]) -> tuple[bytes, int]:
        if not tokens:
            return b"", 0

        verb: str = tokens[0]
        arguments: list[str] = tokens[1:]

        if verb == "echo":
            return " ".join(arguments).encode() + b"\n", 0

        if verb in ("true", "chmod", "killall"):
            return b"", 0

        if verb == "cat":
            output = b""
            for path in arguments:
                if path not in self.files:
                    return b"", 1
                output += self.files[path]

            return output, 0

        if verb == "mkdir":
            for path in arguments:
                if path != "-p":
                    self.dirs.add(path)

            return b"", 0

        if verb == "cp":
            source, destination = arguments[-2], arguments[-1]
            if source not in self.files:
                return b"", 1
            self.add_file(destination, self.files[source])

            return b"", 0

        if verb == "rm":
            for path in arguments:
                if path.startswith("-"):
                    continue

                self.files.pop(path, None)
                for existing in [f for f in self.files if f.startswith(path + "/")]:
                    del self.files[existing]
                self.dirs.discard(path)

            return b"", 0

        if verb == "md5sum":
            path = arguments[0]
            if path not in self.files:
                return b"", 1

            return f"{hashlib.md5(self.files[path]).hexdigest()}  {path}\n".encode(), 0

        if verb == "cmp":
            left, right = arguments[-2], arguments[-1]
            if left not in self.files or right not in self.files:
                return b"", 1

            return b"", 0 if self.files[left] == self.files[right] else 1

        if verb == "sh" and "-n" in arguments:
            return b"", self.sh_n_status

        if verb == "stat":
            path = arguments[-1]
            if path not in self.files:
                return b"", 1

            return f"{len(self.files[path])}\n".encode(), 0

        if verb in ("[", "test"):
            flag: str = arguments[0]
            path = arguments[1]
            if flag == "-d":
                return b"", 0 if path in self.dirs else 1
            if flag == "-f":
                return b"", 0 if path in self.files else 1

        raise AssertionError(f"FakeGoggle got an uninterpreted command: {tokens!r}. "
                             "Register it with canned() or teach the fake the verb.")


@pytest.fixture
def goggle() -> FakeGoggle:
    return FakeGoggle()
