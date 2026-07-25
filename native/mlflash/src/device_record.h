/**
 * @file device_record.h
 * @brief The per-unit device record /usrdata/missinglynk/device.json: the slot-independent
 *        identity of the physical unit, written at flash time and re-verified at switch time.
 *
 * The record lives on the shared usr_data volume both slots mount, so it survives reflashes and
 * describes the open image installed on the inactive slot (only slot B is ever written). It pairs
 * with /etc/ml-release (the in-slot image identity): ml-release answers "what image is this" from
 * inside a slot; device.json answers "which unit is this, what is installed, and has it proven it
 * boots" from either slot or the host flasher.
 */
#ifndef MLFLASH_DEVICE_RECORD_H
#define MLFLASH_DEVICE_RECORD_H

#include "mlimg.h"

/**
 * @brief Write device.json after a successful flash of `target` (0=A, 1=B).
 *
 * Captures the vendor serial from the stock slot's sdk_version.json, records the installed image
 * version + flash time, resets `boots` to 0 (this image has not proven it boots yet), and stores
 * the whole-partition SHA-256 of the just-written kernel and dtb (bound so a stale count cannot
 * vouch for these bytes). Preserves an existing `vendor` block when sdk_version.json cannot be
 * read (e.g. running on the open slot).
 *
 * Best-effort: the flash has already succeeded when this runs, so a failure is warned and returns
 * -1 without undoing anything. `devpath[i]` is the resolved /dev path of component `m->comp[i]`.
 *
 * @return 0 on success, -1 on any error (message already printed).
 */
int device_record_write_flash(const struct manifest *m, char devpath[][32], int target);

/**
 * @brief Read device.json, re-hash slot `slot`'s (0=A, 1=B) kernel and dtb partitions, and print
 *        the boot-proof verdict as one JSON object on stdout for the host flasher. Nothing is
 *        written.
 *
 * The recorded kernel/dtb digests are bound to the exact bytes that were flashed, so a match plus a
 * non-zero boot count means "these bytes came up healthy and still read back identical". A digest
 * mismatch (the slot was re-flashed outside the tool, or the record describes the other slot, or the
 * bytes degraded) or a zero count reads as unproven regardless of the stored count. The verdict is
 * advisory: it informs the host's switch decision, it never gates it.
 *
 * `digests_recorded` separates "this record never carried digests" from "the digests differ": only a
 * flash by this tool records them, so a slot installed another way is unverifiable rather than
 * changed, and the two must not be reported the same way.
 *
 * @return 0 when the record was present and parsed; 1 when it is absent or unparseable (the JSON
 *         object still prints, with "present":false).
 */
int device_record_report(int slot);

#endif
