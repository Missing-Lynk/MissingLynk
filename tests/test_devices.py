"""
The device-manifest reader, and the shape of the real manifests it reads.

devices/<name>/device.mk is the single source of truth the Makefile, this package, and the glue
scripts all read, so the well-formedness checks here run against the manifests actually in the
tree: a new device whose manifest omits a key the tooling needs fails at `make check-python`
rather than mid-flash.
"""
from __future__ import annotations

import pytest

from missinglynk import devices

# Keys every device must declare. DEV_MTDPARTS in particular feeds the RAM-boot cmdline, the
# flashed-slot offsets, and the kernel-slot size check.
REQUIRED_KEYS = ("DEV_NAME", "DEV_CLASS", "DEV_PRODUCT", "DEV_RF_ROLE", "DEV_DTB",
                 "DEV_KADDR", "DEV_RDADDR", "DEV_DTADDR", "DEV_MTDPARTS")


def test_parse_mk_reads_values_and_strips_comments(tmp_path) -> None:
    manifest = tmp_path / "device.mk"
    manifest.write_text(
        "# a comment line\n"
        "\n"
        "DEV_NAME           = example\n"
        "DEV_DTB            = board.dtb        # the built basename\n"
        "not a setting\n")

    assert devices._parse_mk(manifest) == {"DEV_NAME": "example", "DEV_DTB": "board.dtb"}


def test_parse_mk_keeps_the_full_value_of_a_line_with_equals_signs(tmp_path) -> None:
    """mtdparts values contain no '=', but a make assignment splits on the FIRST one regardless."""
    manifest = tmp_path / "device.mk"
    manifest.write_text("DEV_ARGS = root=ubi:rootfs rw\n")

    assert devices._parse_mk(manifest) == {"DEV_ARGS": "root=ubi:rootfs rw"}


def test_short_product_extracts_the_unit_id() -> None:
    assert devices._short_product("P1_GND_VR04") == "P1_GND"
    assert devices._short_product("P1_SKY") == "P1_SKY"
    assert devices._short_product("something-else") is None
    assert devices._short_product("") is None


def test_load_manifests_finds_the_devices_in_the_tree() -> None:
    manifests = devices.load_manifests()

    assert manifests, "no devices/<name>/device.mk found"
    for name, manifest in manifests.items():
        assert manifest.get("DEV_NAME") == name, f"{name}: DEV_NAME does not match its directory"


@pytest.mark.parametrize("name", sorted(devices.load_manifests()))
def test_each_manifest_declares_every_key_the_tooling_reads(name: str) -> None:
    manifest = devices.load_manifests()[name]
    missing = [key for key in REQUIRED_KEYS if not manifest.get(key)]

    assert not missing, f"{name} is missing {missing}"


@pytest.mark.parametrize("name", sorted(devices.load_manifests()))
def test_each_partition_table_has_both_slots_and_no_duplicate_names(name: str) -> None:
    """The A/B tooling addresses partitions by name; a duplicate or missing slot is a mis-flash."""
    table = devices.load_manifests()[name]["DEV_MTDPARTS"]
    partition_names = [entry.split("(", 1)[1].rstrip(")")
                       for entry in table.split(":", 1)[1].split(",")]

    assert len(set(partition_names)) == len(partition_names)
    for base in ("kernel", "dtb", "userapp", "env", "uboot"):
        assert f"{base}0" in partition_names, f"{name}: no {base}0"
        assert f"{base}1" in partition_names, f"{name}: no {base}1"


def test_role_map_keys_on_the_short_id_the_device_reports() -> None:
    """firmware.identify() returns P1_GND / P1_SKY, so the map has to be keyed the same way."""
    roles = devices.role_map()

    assert roles.get("P1_GND") == "gnd"
    assert roles.get("P1_SKY") == "air"
    assert all(key.startswith("P1_") for key in roles)


def test_load_manifests_is_empty_when_there_is_no_devices_dir(
        monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    monkeypatch.setattr(devices, "_DEVICES_DIR", tmp_path / "nothing-here")

    assert devices.load_manifests() == {}
