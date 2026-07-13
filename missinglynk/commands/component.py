"""Component-framework subcommands: install, uninstall, enable, disable, status."""
from __future__ import annotations

import argparse

from .. import components
from .common import connect


def _cmd_install(args: argparse.Namespace) -> int:
    with connect(args) as goggle:
        components.install(goggle)

    return 0


def _cmd_uninstall(args: argparse.Namespace) -> int:
    with connect(args) as goggle:
        components.uninstall(goggle)

    return 0


def _cmd_enable(args: argparse.Namespace) -> int:
    with connect(args) as goggle:
        components.set_enabled(goggle, args.component, True)

    return 0


def _cmd_disable(args: argparse.Namespace) -> int:
    with connect(args) as goggle:
        components.set_enabled(goggle, args.component, False)

    return 0


def _cmd_status(args: argparse.Namespace) -> int:
    with connect(args) as goggle:
        print(components.status(goggle))

    return 0


def register(subparsers: argparse._SubParsersAction) -> None:
    subparsers.add_parser("install",
                          help="deploy MissingLynk files + arm the boot hook"
                          ).set_defaults(func=_cmd_install)
    subparsers.add_parser("uninstall",
                          help="remove all MissingLynk files (revert to stock)"
                          ).set_defaults(func=_cmd_uninstall)

    component_names: tuple[str, ...] = tuple(c.name for c in components.COMPONENTS)
    parser = subparsers.add_parser("enable",
                                   help="enable a component (effective after power-cycle)")
    parser.add_argument("component", choices=component_names)
    parser.set_defaults(func=_cmd_enable)

    parser = subparsers.add_parser("disable",
                                   help="disable a component (effective after power-cycle)")
    parser.add_argument("component", choices=component_names)
    parser.set_defaults(func=_cmd_disable)

    subparsers.add_parser("status", help="show installed / enabled / live state"
                          ).set_defaults(func=_cmd_status)
