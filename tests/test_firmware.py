"""
Unit identification, the vendor-blob manifest, and the partition dump.

identify() picks the blob manifest and names the output directory, so getting it wrong fetches the
wrong unit's RF firmware. The md5 check is the other load-bearing part: a silently truncated blob
would only show up as a device that will not link.
"""
from __future__ import annotations

import gzip
import json

import pytest

from missinglynk import firmware

from .conftest import FakeGoggle

# /proc/mtd as the goggle reports it: the whole-flash alias, two small slots, one 45 MB slot.
PROC_MTD = (
    b'dev:    size   erasesize  name\n'
    b'mtd0: 0a000000 00020000 "spi32766.1"\n'
    b'mtd1: 00600000 00020000 "kernel1"\n'
    b'mtd2: 00060000 00020000 "dtb1"\n'
    b'mtd3: 02d00000 00020000 "userapp1"\n'
)


@pytest.fixture
def dumpable_goggle(goggle: FakeGoggle) -> FakeGoggle:
    goggle.canned("grep -hoE", b"P1_GND\n")
    goggle.canned("ubi volumes", b"/dev/root / ubifs rw 0 0\n")
    goggle.add_file("/proc/mtd", PROC_MTD)
    for index, size in ((1, 0x600000), (2, 0x60000), (3, 0x2d00000)):
        goggle.add_file(f"/dev/mtdblock{index}", b"\xff" * min(size, 4096))

    return goggle


# --- identify ---

def test_identify_reads_the_sdk_version_file(goggle: FakeGoggle) -> None:
    goggle.canned("grep -hoE", b"P1_SKY\n")

    assert firmware.identify(goggle) == "P1_SKY"


def test_identify_falls_back_to_the_link_daemon_role_flag(goggle: FakeGoggle) -> None:
    """A unit whose version file is missing is still identifiable from `ar_lowdelay -t <role>`."""
    goggle.canned("grep -hoE", b"")
    goggle.canned("ar_lowdelay", b"ar_lowdelay -c /usr/usrdata -t 1\n")

    assert firmware.identify(goggle) == "P1_SKY"


def test_identify_maps_the_ground_role_flag_to_the_goggle(goggle: FakeGoggle) -> None:
    goggle.canned("grep -hoE", b"")
    goggle.canned("ar_lowdelay", b"ar_lowdelay -c /usr/usrdata -t 0\n")

    assert firmware.identify(goggle) == "P1_GND"


def test_identify_reports_unknown_rather_than_guessing(goggle: FakeGoggle) -> None:
    """The open slot B answers neither way; blob fetching keys off this to refuse."""
    goggle.canned("grep -hoE", b"")
    goggle.canned("ar_lowdelay", b"")

    assert firmware.identify(goggle) == "unknown"


# --- on-device metadata ---

def test_read_ml_release_strips_quotes(goggle: FakeGoggle) -> None:
    goggle.add_file("/etc/ml-release", b'# open image\nML_VERSION="0.4.2"\nML_FLAVOR=slim\n')

    assert firmware.read_ml_release(goggle) == {"ML_VERSION": "0.4.2", "ML_FLAVOR": "slim"}


def test_read_ml_release_is_empty_on_a_vendor_unit(goggle: FakeGoggle) -> None:
    assert firmware.read_ml_release(goggle) == {}


def test_read_device_record_parses_the_json(goggle: FakeGoggle) -> None:
    record = json.dumps({"flashed": 1700000000}).encode()
    goggle.add_file("/usrdata/missinglynk/device.json", record)

    assert firmware.read_device_record(goggle) == {"flashed": 1700000000}


def test_read_device_record_survives_a_corrupt_file(goggle: FakeGoggle) -> None:
    goggle.add_file("/usrdata/missinglynk/device.json", b"{ truncated")

    assert firmware.read_device_record(goggle) == {}


def test_read_device_record_rejects_json_that_is_not_an_object(goggle: FakeGoggle) -> None:
    goggle.add_file("/usrdata/missinglynk/device.json", b"[1, 2, 3]")

    assert firmware.read_device_record(goggle) == {}


def test_read_device_record_is_empty_when_the_file_is_absent(goggle: FakeGoggle) -> None:
    assert firmware.read_device_record(goggle) == {}


# --- blob manifest ---

@pytest.mark.parametrize("role", ["gnd", "air"])
def test_the_blob_manifest_embeds_the_role_in_the_rf_file_names(role: str) -> None:
    manifest = firmware._blob_manifest(role)

    assert f"/usr/usrdata/ar813x/bb_demo_{role}_d.img" in manifest["rf_required"]
    assert f"/usr/usrdata/ar813x/bb_config_{role}.json" in manifest["rf_required"]
    assert manifest["merged_name"] == (f"bb_config_{role}.json.usr_cfg.json",)


def test_the_blob_manifest_asks_only_for_the_compressed_codec_firmware() -> None:
    """The .bin is derived locally by _stage_codec_fw; only the .gz exists on the device."""
    manifest = firmware._blob_manifest("gnd")

    assert all(path.endswith(".gz") for path in manifest["codec_required"])


def test_fetch_vendor_blobs_refuses_an_unidentified_unit(goggle: FakeGoggle, tmp_path) -> None:
    """Running this against the open slot B would fetch nothing and report success."""
    goggle.canned("grep -hoE", b"")
    goggle.canned("ar_lowdelay", b"")

    with pytest.raises(RuntimeError, match="not a stock goggle"):
        firmware.fetch_vendor_blobs(goggle, str(tmp_path))


def test_fetch_vendor_blobs_rejects_a_blob_whose_md5_does_not_match(
        goggle: FakeGoggle, tmp_path) -> None:
    goggle.canned("grep -hoE", b"P1_GND\n")
    goggle.add_file("/usr/usrdata/ar813x/bb_demo_gnd_d.img", b"firmware bytes")
    goggle.canned("md5sum", b"0000000000000000000000000000dead  blob\n")

    with pytest.raises(OSError, match="md5 mismatch"):
        firmware.fetch_vendor_blobs(goggle, str(tmp_path))


# --- codec firmware staging ---

def test_stage_codec_fw_decompresses_and_places_the_driver_copy(tmp_path) -> None:
    """The open wave5 driver requests one exact path/name; staging it wrong means no decode."""
    bin_dir = tmp_path / "usr" / "bin"
    bin_dir.mkdir(parents=True)
    payload = b"codec firmware" * 100
    with gzip.open(bin_dir / "chagall.bin.gz", "wb") as archive:
        archive.write(payload)

    firmware._stage_codec_fw(str(tmp_path))

    assert (bin_dir / "chagall.bin").read_bytes() == payload
    assert (bin_dir / "chagall.bin.gz").exists()   # the .gz is kept
    staged = tmp_path / "lib" / "firmware" / "cnm" / "wave521c_k3_codec_fw.bin"
    assert staged.read_bytes() == payload


def test_stage_codec_fw_does_nothing_without_a_fetched_binary(tmp_path) -> None:
    firmware._stage_codec_fw(str(tmp_path))

    assert not (tmp_path / "lib").exists()


# --- partition dump ---

def test_dump_partitions_writes_into_a_per_unit_directory(
        dumpable_goggle: FakeGoggle, tmp_path) -> None:
    _, unit_dir = firmware.dump_partitions(dumpable_goggle, str(tmp_path))

    assert unit_dir.endswith("P1_GND")
    assert (tmp_path / "P1_GND" / "proc_mtd.txt").read_bytes() == PROC_MTD
    assert (tmp_path / "P1_GND" / "layout.txt").exists()


def test_dump_partitions_skips_the_whole_flash_alias(
        dumpable_goggle: FakeGoggle, tmp_path) -> None:
    """spi32766.1 is a view over every other partition; dumping it doubles the transfer."""
    written, _ = firmware.dump_partitions(dumpable_goggle, str(tmp_path))

    assert not any("spi32766" in path for path in written)


def test_dump_partitions_skips_large_slots_by_default(
        dumpable_goggle: FakeGoggle, tmp_path) -> None:
    written, _ = firmware.dump_partitions(dumpable_goggle, str(tmp_path))
    names = [path.rsplit("/", 1)[1] for path in written]

    assert "mtd1-kernel1.bin" in names
    assert "mtd2-dtb1.bin" in names
    assert not any("userapp1" in name for name in names)


def test_dump_partitions_includes_large_slots_when_asked(
        dumpable_goggle: FakeGoggle, tmp_path) -> None:
    written, _ = firmware.dump_partitions(dumpable_goggle, str(tmp_path), include_large=True)

    assert any("userapp1" in path for path in written)


def test_dump_reads_the_core_binaries_into_the_destination(goggle: FakeGoggle, tmp_path) -> None:
    for path in firmware.CORE:
        goggle.add_file(path, b"\x7fELF vendor binary")

    written = firmware.dump(goggle, str(tmp_path))

    assert len(written) == len(firmware.CORE)
    for path in written:
        with open(path, "rb") as dumped:
            assert dumped.read() == b"\x7fELF vendor binary"


def test_dump_adds_the_analysis_libraries_when_asked(goggle: FakeGoggle, tmp_path) -> None:
    for path in firmware.CORE + firmware.ANALYSIS:
        goggle.add_file(path, b"\x7fELF vendor binary")

    written = firmware.dump(goggle, str(tmp_path), include_analysis=True)

    assert len(written) == len(firmware.CORE) + len(firmware.ANALYSIS)
