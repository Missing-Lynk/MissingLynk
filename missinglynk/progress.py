"""
Tiny terminal progress bar (stderr, in-place). Callback shape (done, total)
matches both our SSH stream reader and paramiko's SFTP callback.
"""
from __future__ import annotations

import sys
from collections.abc import Callable
from typing import Optional, TextIO

# (done_bytes, total_bytes_or_None) -> None
ProgressCb = Callable[[int, Optional[int]], None]


def printer(label: str, stream: TextIO = sys.stderr) -> ProgressCb:
    width: int = 28
    is_tty: bool = getattr(stream, "isatty", lambda: False)()

    def callback(done: int, total: int | None) -> None:
        if not is_tty:
            # avoid \r spam when piped/captured: only a single completion line
            if total and done >= total:
                stream.write(f"{label}: {total/1e6:.1f} MB\n")
                stream.flush()

            return

        if total:
            fraction: float = min(1.0, done / total)
            filled: int = int(fraction * width)
            bar: str = "#" * filled + "-" * (width - filled)
            stream.write(f"\r{label} [{bar}] {fraction*100:3.0f}% "
                         f"({done/1e6:.1f}/{total/1e6:.1f} MB)")
            if done >= total:
                stream.write("\n")
        else:
            stream.write(f"\r{label} {done/1e6:.1f} MB")
        stream.flush()

    return callback
