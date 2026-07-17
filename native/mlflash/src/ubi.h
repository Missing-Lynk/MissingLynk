/**
 * @file ubi.h
 * @brief UBI-volume write for the userapp (rootfs) component, via vendored mtd-utils ubiformat.
 */
#ifndef MLFLASH_UBI_H
#define MLFLASH_UBI_H

#include <stddef.h>

/**
 * @brief Flash a ubinize image (rootfs.ubi) to the MTD partition at `dev_path`.
 *
 * The rootfs is a UBI image, not a raw partition: writing it needs bad-block skipping, PEB
 * distribution, and per-eraseblock EC-header handling - ubiformat semantics, not a raw write.
 * This streams the in-memory image bytes into the vendored upstream mtd-utils ubiformat entry
 * point (`-f - -S <len>`) through a pipe, so nothing spills to the goggle's tmpfs /tmp.
 *
 * There is no SHA-256 readback: ubiformat rewrites erase counters and places PEBs around bad
 * blocks, so the on-flash bytes intentionally differ from the image. Integrity of the image
 * bytes themselves is already verified against the manifest in preflight; correctness on-flash
 * is ubiformat's own per-eraseblock write path (torture + mark-bad on write error).
 *
 * @return 0 on success; -1 on any error (message already printed).
 */
int ubi_write(const char *dev_path, const unsigned char *data, size_t len);

#endif
