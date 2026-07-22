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
 * vouch for these bytes). Preserves an existing `nickname`, and an existing `vendor` block when
 * sdk_version.json cannot be read (e.g. running on the open slot).
 *
 * Best-effort: the flash has already succeeded when this runs, so a failure is warned and returns
 * -1 without undoing anything. `devpath[i]` is the resolved /dev path of component `m->comp[i]`.
 *
 * @return 0 on success, -1 on any error (message already printed).
 */
int device_record_write_flash(const struct manifest *m, char devpath[][32], int target);

#endif
