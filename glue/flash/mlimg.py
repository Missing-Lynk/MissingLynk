#!/usr/bin/env python3
"""
Build and inspect an .mlimg bundle: one flashable slot image (everything a vendor slot
carries except the SPL) as a plain, inspectable tar.

An .mlimg holds five components plus a manifest:
  manifest.json
  uboot.bin     stock vendor uboot bytes (role=vendor, from the user's own dump)
  env.bin       stock vendor env bytes   (role=vendor, from the user's own dump)
  kernel.otra   our kernel Image ALREADY packed into the OTRA+uImage+LZ4 container (role=open)
  dtb.dtb       our raw dtb, written as-is (role=open)
  rootfs.ubi    the open Alpine rootfs UBI image (role=open)

Manifest targets are slot-RELATIVE names (uboot/env/kernel/dtb/userapp); the flasher resolves
them to the *0/*1 partition of the chosen slot at flash time. This tool never touches a device
and never writes a slot: it only assembles and verifies the bundle on the host.

Kernel packing happens here, at build time, so the flasher never needs to read an OTRA template
off the target. The template (a stock kernel-partition dump) shapes only the non-load-bearing
OTRA +0x20 field (see mkkernel.py); it is not the flashed payload.

Usage:
  mlimg.py build   [-o OUT.tar] [--version V] [--image IMG] [--dtb DTB] [--rootfs UBI]
                   [--blobs-dir DIR] [--uboot F] [--env F] [--otra-template F]
  mlimg.py inspect <bundle.tar>          # print manifest, re-verify every component hash
"""
from __future__ import annotations

import sys
import os
import io
import json
import time
import glob
import hashlib
import argparse
import tarfile
import subprocess
from typing import Optional, TypedDict

# mkkernel.py lives beside this file; reuse its container packing rather than reimplement it.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mkkernel


class Component(TypedDict):
    """One flashable payload in the bundle, and the manifest entry that describes it."""

    name: str          # logical component name (uboot/env/kernel/dtb/rootfs)
    role: str          # "open" (our reproducible payload) or "vendor" (stock dump bytes)
    target: str        # slot-relative partition; the flasher resolves it to *0/*1 at flash time
    method: str        # how the flasher writes it ("mtdtool-raw" | "ubiformat")
    file: str          # member name inside the tar
    sha256: str        # hex digest of the member bytes
    bytes: int         # member byte length


class Manifest(TypedDict):
    """The bundle's manifest.json contents."""

    format_version: int
    target_device: str
    version: str
    provenance: dict[str, object]
    components: list[Component]


FORMAT_VERSION = 1
# Must equal the target device's sdk_version.json "product_version": mlflash's board gate compares
# target_device to that field verbatim. "P1_GND_VR04" is the goggle; the air unit is P1_SKY.
DEFAULT_DEVICE = "P1_GND_VR04"

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

# Slot-relative component layout. `file` is the member name inside the tar; `target` is the
# slot-relative partition the flasher resolves to *0/*1; `method` is how it gets written.
KERNEL_FILE = "kernel.otra"
DTB_FILE = "dtb.dtb"
ROOTFS_FILE = "rootfs.ubi"
UBOOT_FILE = "uboot.bin"
ENV_FILE = "env.bin"


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def pin_env(var: str) -> Optional[str]:
    """
    Read a variable from kernel/scripts/pin.env by sourcing it, so our defaults come from the
    single source of truth the shell flashers use instead of a reimplementation that can drift
    (KERNEL_BUILD_DEFAULT is computed relative to the kernel/ submodule, not the wrapper repo).
    """
    pin = os.path.join(REPO, "kernel", "scripts", "pin.env")
    if not os.path.isfile(pin):
        return None

    try:
        result = subprocess.run(["bash", "-c", f'source "{pin}" && printf "%s" "${{{var}}}"'],
                                capture_output=True, text=True, timeout=10)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass

    return None


def kernel_version() -> Optional[str]:
    """KERNEL_VERSION from pin.env, used as the fallback bundle-version label."""
    return pin_env("KERNEL_VERSION")


def default_build_dir() -> Optional[str]:
    """pin.env's KERNEL_BUILD_DEFAULT ($BUILD_DIR override wins, same as the shell tools)."""
    if os.environ.get("BUILD_DIR"):
        return os.environ["BUILD_DIR"]

    return pin_env("KERNEL_BUILD_DEFAULT")


def git_describe(repo_path: str) -> Optional[str]:
    """`git describe`-style provenance for a submodule; None if unavailable."""
    try:
        result = subprocess.run(["git", "-C", repo_path, "describe", "--tags", "--always", "--dirty"],
                                capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            return result.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass

    return None


def resolve_blob(explicit: Optional[str], blobs_dir: str, patterns: list[str], label: str) -> str:
    """
    Locate a vendor blob: an explicit path wins; else the first match of `patterns` (in order)
    searched recursively under blobs_dir. Raises with a clear message if nothing is found.
    """
    if explicit:
        if not os.path.isfile(explicit):
            raise SystemExit(f"error: {label}: no such file: {explicit}")

        return explicit

    for pattern in patterns:
        matches = sorted(glob.glob(os.path.join(blobs_dir, "**", pattern), recursive=True))
        if matches:
            return matches[0]

    raise SystemExit(
        f"error: {label}: none of {patterns} found under {blobs_dir}. "
        f"Populate it from your device with `missinglynk dump-partitions --dest firmware/bin` "
        f"(or pass --blobs-dir / an explicit path).")


def pack_kernel(image_path: str, otra_template: str) -> bytes:
    """Pack the kernel Image into the OTRA+uImage+LZ4 container; gate it against the 6 MiB slot."""
    image = open(image_path, "rb").read()
    container, _payload = mkkernel.build_container(image, otra_template)
    margin, fits = mkkernel.slot_margin(len(container))
    print(f"[*] kernel: Image {len(image):,} B -> container {len(container):,} B ({margin})")

    if not fits:
        raise SystemExit("error: packed kernel exceeds the 6 MiB kernel slot; cannot flash.")

    return container


def build(args: argparse.Namespace) -> int:
    build_dir = args.build_dir or default_build_dir()
    image_path = args.image or (os.path.join(build_dir, "linux/arch/arm64/boot/Image")
                                if build_dir else None)
    dtb_path = args.dtb or (os.path.join(build_dir, "linux/arch/arm64/boot/proxima-9311.dtb")
                            if build_dir else None)
    rootfs_path = args.rootfs or os.path.join(REPO, "rootfs", "build", "rootfs.ubi")
    blobs_dir = args.blobs_dir or os.path.join(REPO, "firmware", "bin")

    for label, path in (("kernel Image", image_path), ("dtb", dtb_path), ("rootfs", rootfs_path)):
        if not path or not os.path.isfile(path):
            raise SystemExit(f"error: {label} not found: {path or '(no build dir)'}. "
                             f"Build it (`make kernel` / `make rootfs`) or pass an explicit path.")

    # Vendor blobs: prefer the slot-A (*0) stock dump. Slot A is never written, so *0 bytes are
    # always stock and the built image is stable and reproducible regardless of what is on slot B
    # (whose *1 kernel may be our own build). An explicit --uboot/--env/--otra-template wins.
    uboot_path = resolve_blob(args.uboot, blobs_dir,
                              ["uboot.bin", "*uboot0.bin", "*uboot1.bin"], "uboot")
    env_path = resolve_blob(args.env, blobs_dir,
                            ["env.bin", "*env0.bin", "*env1.bin"], "env")
    template_path = resolve_blob(args.otra_template, blobs_dir,
                                 ["kernel-otra-template.bin", "*kernel0.bin", "*kernel1.bin"],
                                 "OTRA template (a stock kernel-partition dump)")

    with open(template_path, "rb") as template_fh:
        if template_fh.read(4) != mkkernel.OTRA_MAGIC:
            raise SystemExit(f"error: OTRA template {template_path} has no OTRA magic; "
                             f"it must be a raw stock kernel-partition dump.")

    # Assemble every component's bytes in memory (all small enough; rootfs is ~34 MiB).
    kernel_bytes = pack_kernel(image_path, template_path)
    dtb_bytes = open(dtb_path, "rb").read()
    rootfs_bytes = open(rootfs_path, "rb").read()
    uboot_bytes = open(uboot_path, "rb").read()
    env_bytes = open(env_path, "rb").read()

    kernel_ver = kernel_version()
    provenance: dict[str, object] = {
        "kernel_version": kernel_ver,
        "kernel_git": git_describe(os.path.join(REPO, "kernel")),
        "rootfs_git": git_describe(os.path.join(REPO, "rootfs")),
        "uboot_source": os.path.relpath(uboot_path, REPO),
        "env_source": os.path.relpath(env_path, REPO),
        "otra_template_source": os.path.relpath(template_path, REPO),
        "build_time": int(time.time()),
    }

    components: list[Component] = [
        {"name": "uboot", "role": "vendor", "target": "uboot", "method": "mtdtool-raw",
         "file": UBOOT_FILE, "sha256": sha256_bytes(uboot_bytes), "bytes": len(uboot_bytes)},
        {"name": "env", "role": "vendor", "target": "env", "method": "mtdtool-raw",
         "file": ENV_FILE, "sha256": sha256_bytes(env_bytes), "bytes": len(env_bytes)},
        {"name": "kernel", "role": "open", "target": "kernel", "method": "mtdtool-raw",
         "file": KERNEL_FILE, "sha256": sha256_bytes(kernel_bytes), "bytes": len(kernel_bytes)},
        {"name": "dtb", "role": "open", "target": "dtb", "method": "mtdtool-raw",
         "file": DTB_FILE, "sha256": sha256_bytes(dtb_bytes), "bytes": len(dtb_bytes)},
        {"name": "rootfs", "role": "open", "target": "userapp", "method": "ubiformat",
         "file": ROOTFS_FILE, "sha256": sha256_bytes(rootfs_bytes), "bytes": len(rootfs_bytes)},
    ]

    device = args.device
    version = args.version or provenance["kernel_git"] or kernel_ver or "dev"
    manifest: Manifest = {
        "format_version": FORMAT_VERSION,
        "target_device": device,
        "version": version,
        "provenance": provenance,
        "components": components,
    }

    out_path = args.output or os.path.join(REPO, f"mlimg-{device}-{version}.tar")
    payloads: dict[str, bytes] = {
        UBOOT_FILE: uboot_bytes,
        ENV_FILE: env_bytes,
        KERNEL_FILE: kernel_bytes,
        DTB_FILE: dtb_bytes,
        ROOTFS_FILE: rootfs_bytes,
    }
    write_tar(out_path, manifest, payloads)

    total_bytes = sum(component["bytes"] for component in components)
    print(f"[+] wrote {out_path} ({total_bytes:,} B across {len(components)} components)")
    print(f"    device {device}, version {version}")
    for component in components:
        print(f"    {component['name']:7s} {component['role']:6s} -> {component['target']:8s} "
              f"{component['bytes']:>12,} B  {component['sha256'][:16]}  ({component['method']})")

    return 0


def write_tar(out_path: str, manifest: Manifest, payloads: dict[str, bytes]) -> None:
    """
    Write manifest.json first, then each component, with fixed member metadata so the tar is
    reproducible given identical inputs (only the manifest's build_time varies).
    """
    def add(tar: tarfile.TarFile, name: str, data: bytes) -> None:
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mtime = 0
        info.mode = 0o644
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        tar.addfile(info, io.BytesIO(data))

    manifest_bytes = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    with tarfile.open(out_path, "w") as tar:
        add(tar, "manifest.json", manifest_bytes)
        for component in manifest["components"]:
            add(tar, component["file"], payloads[component["file"]])


def inspect(args: argparse.Namespace) -> int:
    path = args.bundle
    if not os.path.isfile(path):
        raise SystemExit(f"error: no such bundle: {path}")

    with tarfile.open(path, "r") as tar:
        try:
            manifest = json.loads(tar.extractfile("manifest.json").read())
        except KeyError:
            raise SystemExit("error: bundle has no manifest.json")

        print(f"mlimg: {path}")
        print(f"  format {manifest.get('format_version')}  device {manifest.get('target_device')}"
              f"  version {manifest.get('version')}")
        provenance = manifest.get("provenance", {})
        for key in ("kernel_version", "kernel_git", "rootfs_git", "build_time"):
            value = provenance.get(key)
            if value is not None:
                if key == "build_time":
                    value = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(value))
                print(f"  {key}: {value}")

        all_ok = True
        print("  components:")
        for component in manifest.get("components", []):
            try:
                data = tar.extractfile(component["file"]).read()
            except KeyError:
                print(f"    {component['name']:7s} MISSING member {component['file']}")
                all_ok = False
                continue

            digest = sha256_bytes(data)
            size_ok = len(data) == component["bytes"]
            hash_ok = digest == component["sha256"]

            status = "OK" if (size_ok and hash_ok) else "FAIL"
            if status != "OK":
                all_ok = False

            print(f"    {component['name']:7s} {component['role']:6s} -> {component['target']:8s} "
                  f"{len(data):>12,} B  {digest[:16]}  [{status}]")

        # Kernel container sanity: OTRA + uImage magic + data CRC, without unpacking to disk.
        kernel_comp = next((c for c in manifest.get("components", []) if c["name"] == "kernel"), None)
        if kernel_comp:
            try:
                kernel_data = tar.extractfile(kernel_comp["file"]).read()
                offset = 0x40 if kernel_data[:4] == mkkernel.OTRA_MAGIC else 0
                uimage = mkkernel.parse_uimage(kernel_data[offset:offset + 64])
                container_ok = uimage["magic"] == mkkernel.UIMG_MAGIC and offset == 0x40
                print(f"  kernel container: OTRA+uImage {'OK' if container_ok else 'FAIL'} "
                      f"(load 0x{uimage['load']:08x}, {uimage['size']:,} B payload)")
                all_ok = all_ok and container_ok
            except Exception as exc:  # report a malformed container, do not crash inspect
                print(f"  kernel container: FAIL ({exc})")
                all_ok = False

    print(f"  => {'all components verified' if all_ok else 'VERIFICATION FAILED'}")
    return 0 if all_ok else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Build/inspect an .mlimg slot bundle.")
    subparsers = parser.add_subparsers(dest="cmd", required=True)

    build_parser = subparsers.add_parser(
        "build", help="assemble an .mlimg from the current builds + vendor blobs")
    build_parser.add_argument("-o", "--output",
                              help="output tar path (default: repo/mlimg-<device>-<version>.tar)")
    build_parser.add_argument("--device", default=DEFAULT_DEVICE,
                              help=f"target device string, part of the filename (default: {DEFAULT_DEVICE})")
    build_parser.add_argument("--version", help="bundle version label (default: kernel git describe)")
    build_parser.add_argument("--build-dir", help="kernel build tree (default: pin.env KERNEL_BUILD_DEFAULT)")
    build_parser.add_argument("--image", help="kernel Image (default: <build-dir>/linux/arch/arm64/boot/Image)")
    build_parser.add_argument("--dtb", help="dtb (default: <build-dir>/.../proxima-9311.dtb)")
    build_parser.add_argument("--rootfs", help="rootfs UBI (default: rootfs/build/rootfs.ubi)")
    build_parser.add_argument("--blobs-dir", help="dir searched for vendor blobs (default: firmware/bin)")
    build_parser.add_argument("--uboot", help="explicit stock uboot blob")
    build_parser.add_argument("--env", help="explicit stock env blob")
    build_parser.add_argument("--otra-template", help="explicit stock kernel-partition dump (OTRA template)")

    inspect_parser = subparsers.add_parser(
        "inspect", help="print the manifest and re-verify every component hash")
    inspect_parser.add_argument("bundle")

    args = parser.parse_args()
    if args.cmd == "build":
        return build(args)

    if args.cmd == "inspect":
        return inspect(args)

    return 2


if __name__ == "__main__":
    sys.exit(main())
