"""Shared helpers for the CLI subcommand modules."""
from __future__ import annotations

import argparse
import os

from ..connection import Goggle

# firmware/bin at the repo root (dump-firmware / fetch-blobs default destination base)
FIRMWARE_BIN: str = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "firmware", "bin")


def connect(args: argparse.Namespace) -> Goggle:
    return Goggle(ip=args.ip, password=args.password, port=args.port)
