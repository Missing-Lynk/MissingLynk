"""Vendor-blob + unit subcommands: identify, dump-firmware, fetch-blobs, dump-partitions."""
from __future__ import annotations

import argparse
import os
import sys

from .. import firmware
from .common import FIRMWARE_BIN, connect

_UNIT_LABELS: dict[str, str] = {
    "P1_GND": "goggle",
    "P1_SKY": "air unit",
}


def _cmd_identify(args: argparse.Namespace) -> int:
    with connect(args) as goggle:
        unit_id: str = firmware.identify(goggle)

    label: str = _UNIT_LABELS.get(unit_id, "unknown unit")
    print(f"{label} ({unit_id})")

    return 0


def _cmd_dump_firmware(args: argparse.Namespace) -> int:
    dest: str = args.dest or FIRMWARE_BIN
    with connect(args) as goggle:
        written: list[str] = firmware.dump(goggle, dest, include_analysis=args.all)

    print(f"dumped {len(written)} file(s) to {dest}")
    print("next: python3 firmware/patches/apply-patches.py")

    return 0


def _cmd_fetch_blobs(args: argparse.Namespace) -> int:
    dest: str = args.dest or os.path.join(FIRMWARE_BIN, "slot-a")
    with connect(args) as goggle:
        written, missing_required, missing_optional = firmware.fetch_vendor_blobs(
            goggle, dest, include_analysis=args.all)

    print(f"\nfetched {len(written)} file(s) to {dest}")
    if missing_optional:
        print(f"optional not found: "
              f"{', '.join(os.path.basename(p) for p in missing_optional)}",
              file=sys.stderr)

    if missing_required:
        print(f"REQUIRED not found: {', '.join(missing_required)}", file=sys.stderr)
        return 1

    return 0


def _cmd_dump_partitions(args: argparse.Namespace) -> int:
    dest: str = args.dest or "out"
    with connect(args) as goggle:
        unit_id: str = firmware.identify(goggle)
        print(f"unit: {unit_id} ({_UNIT_LABELS.get(unit_id, '?')})")
        written, unit_dir = firmware.dump_partitions(goggle, dest, include_large=args.full)

    print(f"dumped {len(written)} partition(s) to {unit_dir}")
    return 0


def register(subparsers: argparse._SubParsersAction) -> None:
    subparsers.add_parser("identify",
                          help="name the connected unit (goggle P1_GND / air P1_SKY)"
                          ).set_defaults(func=_cmd_identify)

    parser = subparsers.add_parser(
        "dump-firmware", help="copy vendor binaries off the goggle into firmware/bin/")
    parser.add_argument("--all", action="store_true",
                        help="also dump the libraries used for reverse-engineering")
    parser.add_argument("--dest", help=f"destination dir (default {FIRMWARE_BIN})")
    parser.set_defaults(func=_cmd_dump_firmware)

    parser = subparsers.add_parser(
        "fetch-blobs",
        help="pull the open-stack vendor blobs off stock slot A into firmware/bin/slot-a/")
    parser.add_argument("--all", action="store_true",
                        help="also fetch dev/RE extras: vendor MPI libs (ml-codec-probe) "
                             "+ Path-A ref client")
    parser.add_argument("--dest",
                        help=f"destination dir (default {os.path.join(FIRMWARE_BIN, 'slot-a')})")
    parser.set_defaults(func=_cmd_fetch_blobs)

    parser = subparsers.add_parser(
        "dump-partitions",
        help="dump every MTD partition + the root squashfs (goggle or air)")
    parser.add_argument("--full", action="store_true",
                        help="also dump large partitions (userapp ~45MB; slow over legacy SSH)")
    parser.add_argument("--dest",
                        help="destination dir (default out/; goes under <P1_GND|P1_SKY>/)")
    parser.set_defaults(func=_cmd_dump_partitions)
