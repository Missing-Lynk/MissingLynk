"""
missinglynk command-line interface.

  missinglynk install                   deploy all our files + arm the boot hook
  missinglynk enable|disable <comp>     toggle a component (rtsp, indicator)
  missinglynk status                    show installed / enabled / live state
  missinglynk uninstall                 remove everything (revert to stock)
  missinglynk screenshot [-o NAME]      pull + decode the OSD framebuffer -> PNG
  missinglynk dump-firmware [--all]     copy vendor binaries off the goggle
  missinglynk fetch-blobs               pull the open-stack vendor blobs off stock slot A
  missinglynk dump-partitions [--full]  dump every MTD partition + the root squashfs
  missinglynk identify                  name the connected unit (goggle / air)

By default the connected unit is auto-detected: a stock/unflashed unit at 192.168.3.100
(root/artosyn) if one answers, else the first open device found scanning 192.168.3.101 and up
(root/libre). Override with --ip/--port/--password. Run host network setup first so the link is
reachable (see docs/05). To reach the air unit (P1_SKY), start the goggle relay
(ml-tcprelay 8822 10.0.0.100 22) and pass --port 8822 --password artosyn.

Subcommands live in the `missinglynk.commands` package (one module per theme);
this file only wires argparse and dispatches to each command's `func`.
"""
from __future__ import annotations

import argparse
import sys

from . import GOGGLE_IP, GOGGLE_PASS, STOCK_IP, STOCK_PASS, __version__, commands
from .connection import default_target


def main(argv: list[str] | None = None) -> int:
    parser: argparse.ArgumentParser = argparse.ArgumentParser(
        prog="missinglynk", description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version", action="version", version=f"missinglynk {__version__}")
    parser.add_argument("--ip", default=None,
                        help=f"device IP (default: auto-detect - a stock unit at {STOCK_IP} if "
                             f"reachable, else the first open device found at {GOGGLE_IP} and up)")
    parser.add_argument("--port", type=int, default=22,
                        help="SSH port (default 22; use the goggle relay port, e.g. 8822, "
                             "to reach the air unit)")
    parser.add_argument("--password", default=None,
                        help=f"root password (default: {STOCK_PASS} for a stock unit, "
                             f"{GOGGLE_PASS} for the open slot)")
    parser.add_argument("--debug", action="store_true", help="show full tracebacks")
    subparsers = parser.add_subparsers(dest="cmd", required=True)

    commands.register_all(subparsers)

    args = parser.parse_args(argv)

    # Resolve the default target when the caller gave no --ip: auto-detect (stock first, then the
    # open addresses .101 and up). The password follows the resolved slot; an explicit --password
    # wins.
    if args.ip is None:
        args.ip, resolved_pass = default_target(args.port)
    else:
        resolved_pass = STOCK_PASS if args.ip == STOCK_IP else GOGGLE_PASS
    if args.password is None:
        args.password = resolved_pass

    try:
        return args.func(args)
    except Exception as e:
        if args.debug:
            raise
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
