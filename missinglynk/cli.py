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

Connection defaults to root@192.168.3.100:22 (override with --ip/--port/--password).
Run host network setup first so the link is reachable (see docs/05). To reach the
air unit (P1_SKY), start the goggle relay (ml-tcprelay 8822 10.0.0.100 22) and pass
--port 8822 --password artosyn.

Subcommands live in the `missinglynk.commands` package (one module per theme);
this file only wires argparse and dispatches to each command's `func`.
"""
from __future__ import annotations

import argparse
import sys

from . import GOGGLE_IP, GOGGLE_PASS, __version__, commands


def main(argv: list[str] | None = None) -> int:
    parser: argparse.ArgumentParser = argparse.ArgumentParser(
        prog="missinglynk", description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version", action="version", version=f"missinglynk {__version__}")
    parser.add_argument("--ip", default=GOGGLE_IP, help=f"goggle IP (default {GOGGLE_IP})")
    parser.add_argument("--port", type=int, default=22,
                        help="SSH port (default 22; use the goggle relay port, e.g. 8822, "
                             "to reach the air unit)")
    parser.add_argument("--password", default=GOGGLE_PASS, help="root password")
    parser.add_argument("--debug", action="store_true", help="show full tracebacks")
    subparsers = parser.add_subparsers(dest="cmd", required=True)

    commands.register_all(subparsers)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Exception as e:
        if args.debug:
            raise
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
