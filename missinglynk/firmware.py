"""Copy vendor binaries / raw partitions off a unit (goggle or air)."""
from __future__ import annotations

import gzip
import hashlib
import os
import re
import shlex
import shutil

from .connection import Goggle
from .progress import printer

# enough to build the patch
CORE: tuple[str, ...] = ("/usr/bin/ar_lowdelay",)
# extra libraries only needed for reverse-engineering
ANALYSIS: tuple[str, ...] = (
    "/usr/lib/libar_minirtsp.so",
    "/usr/lib/libmpi_venc.so",
    "/usr/lib/libmpp_service.so",
)


def dump(goggle: Goggle, dest_dir: str, include_analysis: bool = False) -> list[str]:
    paths: tuple[str, ...] = CORE + (ANALYSIS if include_analysis else ())
    os.makedirs(dest_dir, exist_ok=True)
    written: list[str] = []

    for path in paths:
        size: int | None = _remote_size(goggle, path)
        data: bytes = goggle.read_stream(f"cat {shlex.quote(path)}", expected_bytes=size,
                                         on_progress=printer(f"  {os.path.basename(path)}"))
        dest_path: str = os.path.join(dest_dir, os.path.basename(path))

        with open(dest_path, "wb") as f:
            f.write(data)

        written.append(dest_path)

    return written


def identify(goggle: Goggle) -> str:
    """
    Return the unit's product id (P1_GND = goggle, P1_SKY = air), or 'unknown'.

    `sdk_version.json` carries P1_GND/P1_SKY on both units (the goggle's product/config.json
    only has "version":"FPV_GND"). Fall back to the running link daemon's role flag
    (`ar_lowdelay ... -t 0` = ground/goggle, `-t 1` = sky/air).
    """
    unit_id: str = goggle.run(
        "grep -hoE 'P1_(GND|SKY)' /usr/usrdata/sdk_version.json "
        "/usr/usrdata/product/config.json 2>/dev/null | head -1")[0].decode(errors="replace").strip()
    if unit_id:
        return unit_id

    daemon_cmdline: str = goggle.run(
        "ps 2>/dev/null | grep -oE 'ar_lowdelay .* -t [01]' | head -1")[0].decode().strip()

    if daemon_cmdline.endswith("-t 1"):
        return "P1_SKY"

    if daemon_cmdline.endswith("-t 0"):
        return "P1_GND"

    return "unknown"


# --- vendor blobs the open slot-B stack needs (ported from glue/fetch/fetch-vendor-blobs.sh) ---
#
# Selected by unit identity: the RF firmware/config file names embed the unit role
# ("gnd" for the goggle P1_GND, "sky" for the air unit P1_SKY). The codec firmware and
# the MPI libs live at the same paths on both. Requiring a known identity also guards
# against running on the open Alpine slot B (which identifies as "unknown", no vendor files).
_AR813X = "/usr/usrdata/ar813x"
_ROLE: dict[str, str] = {"P1_GND": "gnd", "P1_SKY": "sky"}


def _blob_manifest(role: str) -> dict[str, tuple[str, ...]]:
    """Return the required/optional remote paths for a unit role ("gnd" | "sky")."""
    return {
        "rf_required": (
            f"{_AR813X}/bb_demo_{role}_d.img",     # RF baseband firmware (debug build)
            f"{_AR813X}/bb_config_{role}.json",    # base RF config
            f"{_AR813X}/usr_cfg.json",             # bound-peer config (role-independent name)
        ),
        "rf_optional": (
            f"{_AR813X}/bb_demo_{role}.img",
            f"{_AR813X}/bb_config_{role}_5m.json",
            f"{_AR813X}/ar8030_pwr.json",
            f"{_AR813X}/chan_valid_bmp.json",
            f"{_AR813X}/chan_fast_valid_bmp.json",
        ),

        # the merged config is generated at boot by auto_merge; its name embeds the role
        "merged_name": (f"bb_config_{role}.json.usr_cfg.json",),

        # only the .gz exist on the device; the decompressed .bin is derived locally
        # (see _stage_codec_fw), so it is never a fetch target.
        "codec_required": ("/usr/bin/chagall.bin.gz",),
        "codec_optional": ("/usr/bin/chagall_lowmem.bin.gz",),

        # Analysis / dev extras (only with include_analysis)
        # vendor MPI libs: only userspace/libre/tools/ml-codec-probe links these; the static
        # wave5/gstreamer runtime does NOT need them. libmpp_service.so alone is 5 MB.
        "mpi_analysis": tuple(f"/usr/lib/{lib}" for lib in (
            "libmpi_sys.so", "libmpi_venc.so", "libmpi_vdec.so",
            "libmpi_vb.so", "libmpi_scaler.so", "libmpp_service.so")),

        # vendor RF ref client for Path A (run daemon+cmd_dbg on Alpine); its glibc
        # runtime is resolved+fetched separately. Not the production ml-linkd path.
        "path_a": (f"{_AR813X}/cmd_dbg", f"{_AR813X}/daemon"),
    }


def _remote_size(goggle: Goggle, path: str) -> int | None:
    stdout, _, _ = goggle.run(
        f"stat -c %s {shlex.quote(path)} 2>/dev/null || wc -c < {shlex.quote(path)}")
    text: str = stdout.decode(errors="replace").strip()
    return int(text) if text.isdigit() else None


def fetch_vendor_blobs(goggle: Goggle, dest_dir: str,
                       include_analysis: bool = False) -> tuple[list[str], list[str], list[str]]:
    """
    Pull the vendor blobs the open slot-B stack needs off a live STOCK slot A into
    dest_dir, mirroring device paths, md5-verifying each transfer. Read-only on the device.

    By default fetches only the runtime core (RF firmware + configs + merged config +
    Wave521C codec fw). include_analysis adds the dev/RE extras: the vendor MPI libs
    (ml-codec-probe) and the Path-A RF ref client (daemon/cmd_dbg + its glibc runtime).

    The manifest is chosen by unit identity (goggle vs air unit). Returns
    (written, missing_required, missing_optional). Refuses on a non-vendor system.
    """
    unit_id: str = identify(goggle)
    role: str | None = _ROLE.get(unit_id)
    if role is None:
        raise RuntimeError(
            f"cannot fetch vendor blobs: unit identified as '{unit_id}', not a stock goggle "
            "(P1_GND) or air unit (P1_SKY). The blobs (and the boot-merged RF config) only "
            "exist on a running stock slot A; the open Alpine slot B has none.")

    manifest: dict[str, tuple[str, ...]] = _blob_manifest(role)
    written: list[str] = []
    missing_required: list[str] = []
    missing_optional: list[str] = []

    def fetch(remote_path: str, required: bool) -> str | None:
        _, _, exit_status = goggle.run(f"test -f {shlex.quote(remote_path)}")
        if exit_status != 0:
            (missing_required if required else missing_optional).append(remote_path)
            print(f"[{'!' if required else '-'}] missing"
                  f"{' (required)' if required else ' (optional)'}: {remote_path}")
            return None

        size: int | None = _remote_size(goggle, remote_path)
        data: bytes = goggle.read_stream(
            f"cat {shlex.quote(remote_path)}", expected_bytes=size,
            on_progress=printer(f"  {os.path.basename(remote_path)}"))
        md5_fields: list[str] = goggle.run(
            f"md5sum {shlex.quote(remote_path)}")[0].decode(errors="replace").split()
        remote_md5: str = md5_fields[0] if md5_fields else ""
        local_md5: str = hashlib.md5(data).hexdigest()
        if not remote_md5 or remote_md5 != local_md5:
            raise IOError(f"md5 mismatch for {remote_path} "
                          f"(remote={remote_md5} local={local_md5})")

        local_path: str = os.path.join(dest_dir, remote_path.lstrip("/"))
        os.makedirs(os.path.dirname(local_path), exist_ok=True)
        with open(local_path, "wb") as f:
            f.write(data)

        written.append(local_path)
        print(f"[+] {remote_path}  ({len(data)} B, md5 ok)")
        return local_path

    print(f"[*] unit: {unit_id} (role {role}); RF firmware + configs ({_AR813X})")
    for path in manifest["rf_required"]:
        fetch(path, True)

    for path in manifest["rf_optional"]:
        fetch(path, False)

    # the merged RF config exists only on a running slot A (auto_merge output); locate it live.
    merged_name: str = manifest["merged_name"][0]
    found: str = goggle.run(
        f"find {_AR813X} /usr/usrdata/product/ar813x /tmp /usrdata "
        f"-maxdepth 3 -name {shlex.quote(merged_name)} 2>/dev/null | head -1")[0].decode().strip()
    print("[*] merged RF config (boot-generated by auto_merge)")
    if found:
        fetch(found, True)
    else:
        missing_required.append(merged_name)
        print(f"[!] missing (required): {merged_name} "
              "(auto_merge output; has the RF stack started this boot?)")

    print("[*] Wave521C codec firmware (/usr/bin)")
    for path in manifest["codec_required"]:
        fetch(path, True)

    for path in manifest["codec_optional"]:
        fetch(path, False)

    if include_analysis:
        print("[*] vendor MPI libraries (/usr/lib, for ml-codec-probe)")
        for path in manifest["mpi_analysis"]:
            fetch(path, True)

        print("[*] Path-A RF ref client + glibc runtime (dev fallback)")
        for path in manifest["path_a"]:
            fetch(path, False)

        for lib_path in _resolve_runtime_libs(goggle, manifest["path_a"]):
            fetch(lib_path, False)

    _stage_codec_fw(dest_dir)
    return written, missing_required, missing_optional


def _resolve_runtime_libs(goggle: Goggle, binaries: tuple[str, ...]) -> list[str]:
    """ldd the Path-A binaries on-device and return the absolute lib paths they need."""
    quoted_binaries: str = " ".join(shlex.quote(b) for b in binaries)
    # awk picks tokens that start with '/' (the resolved absolute lib paths)
    command: str = (f'for b in {quoted_binaries}; do [ -f "$b" ] && ldd "$b" 2>/dev/null; done '
                    '| awk \'{for(i=1;i<=NF;i++) if(substr($i,1,1)=="/") print $i}\' | sort -u')
    output: str = goggle.run(command)[0].decode(errors="replace")
    return sorted({line for line in output.split() if line.startswith("/")})


def _stage_codec_fw(dest_dir: str) -> None:
    """Decompress fetched chagall*.bin.gz (keep the .gz) and stage the wave5-driver copy."""
    bin_dir: str = os.path.join(dest_dir, "usr", "bin")
    if not os.path.isdir(bin_dir):
        return

    for name in os.listdir(bin_dir):
        if not (name.startswith("chagall") and name.endswith(".bin.gz")):
            continue

        gz_path: str = os.path.join(bin_dir, name)
        bin_path: str = gz_path[:-3]  # drop .gz
        with gzip.open(gz_path, "rb") as gz_file, open(bin_path, "wb") as bin_file:
            shutil.copyfileobj(gz_file, bin_file)
        print(f"[+] decompressed {name} -> {os.path.basename(bin_path)} "
              f"({os.path.getsize(bin_path)} B)")

    # the full chagall.bin, staged at the exact path/name the open wave5 V4L2 driver requests
    chagall: str = os.path.join(bin_dir, "chagall.bin")
    if os.path.isfile(chagall):
        cnm_dir: str = os.path.join(dest_dir, "lib", "firmware", "cnm")
        os.makedirs(cnm_dir, exist_ok=True)
        shutil.copyfile(chagall, os.path.join(cnm_dir, "wave521c_k3_codec_fw.bin"))
        print("[+] staged lib/firmware/cnm/wave521c_k3_codec_fw.bin "
              "(what the open wave5 driver requests)")


# the whole-flash MTD alias (a view over all the named partitions); skip it
_WHOLE_FLASH = "spi32766.1"


def dump_partitions(goggle: Goggle, dest_dir: str, include_large: bool = False,
                    large_threshold: int = 8 * 1024 * 1024) -> tuple[list[str], str]:
    """
    Dump every MTD partition (and the root UBI squashfs) off the connected unit.

    Works on the goggle (P1_GND) or the air unit (P1_SKY): it reads /proc/mtd live. Output
    goes to dest_dir/<P1_GND|P1_SKY>/. Large partitions (e.g. the 45 MB userapp slots) are
    skipped unless include_large, since the legacy-SSH link is slow.
    """
    unit_id: str = identify(goggle)
    unit_dir: str = os.path.join(dest_dir, unit_id)
    os.makedirs(unit_dir, exist_ok=True)

    proc_mtd: str = goggle.run("cat /proc/mtd")[0].decode(errors="replace")
    with open(os.path.join(unit_dir, "proc_mtd.txt"), "w") as f:
        f.write(proc_mtd)
    layout: str = goggle.run(
        "cat /proc/mounts; echo '--- ubi volumes ---'; "
        "for d in /sys/class/ubi/ubi*; do echo \"$d mtd=$(cat $d/mtd_num 2>/dev/null)\"; "
        "done 2>/dev/null")[0].decode(errors="replace")
    with open(os.path.join(unit_dir, "layout.txt"), "w") as f:
        f.write(layout)

    written: list[str] = []
    for line in proc_mtd.splitlines():
        match: re.Match[str] | None = re.match(
            r'(mtd\d+):\s+([0-9a-fA-F]+)\s+[0-9a-fA-F]+\s+"([^"]+)"', line)
        if not match:
            continue

        mtd_dev, size_hex, name = match.group(1), match.group(2), match.group(3)
        size: int = int(size_hex, 16)
        mtd_index: str = mtd_dev[3:]
        if name == _WHOLE_FLASH:
            continue

        if size > large_threshold and not include_large:
            print(f"  skip {mtd_dev} {name} ({size // (1024 * 1024)} MB; pass --full to include)")
            continue

        data: bytes = goggle.read_stream(f"cat /dev/mtdblock{mtd_index}", expected_bytes=size,
                                         on_progress=printer(f"  {mtd_dev} {name}"))
        dest_path: str = os.path.join(unit_dir, f"{mtd_dev}-{name}.bin")
        with open(dest_path, "wb") as f:
            f.write(data)

        written.append(dest_path)

    # the root filesystem itself (squashfs on a UBI block device)
    sector_count: str = goggle.run(
        "cat /sys/class/block/ubiblock0_0/size 2>/dev/null")[0].decode().strip()
    size_bytes: int | None = int(sector_count) * 512 if sector_count.isdigit() else None
    data = goggle.read_stream("cat /dev/ubiblock0_0", expected_bytes=size_bytes,
                              on_progress=printer("  ubiblock0_0 rootfs"))
    if data:
        dest_path = os.path.join(unit_dir, "ubiblock0_0-rootfs.squashfs")
        with open(dest_path, "wb") as f:
            f.write(data)

        written.append(dest_path)

    return written, unit_dir
