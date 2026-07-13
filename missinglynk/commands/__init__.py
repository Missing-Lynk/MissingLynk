"""CLI subcommand modules. Each exposes `register(subparsers)`."""
from __future__ import annotations

import argparse

from . import capture, component, vendor

# registration order = help-listing order
_MODULES = (capture, vendor, component)


def register_all(subparsers: argparse._SubParsersAction) -> None:
    for module in _MODULES:
        module.register(subparsers)
