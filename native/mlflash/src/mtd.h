/**
 * @file mtd.h
 * @brief Raw MTD partition write with a SHA-256 readback gate (for the non-UBI components).
 */
#ifndef MLFLASH_MTD_H
#define MLFLASH_MTD_H

#include <stddef.h>

/**
 * @brief Write `data` to the partition at `dev_path`, then read it back and verify the digest.
 *
 * On an MTD char device it erases the covered eraseblocks (aborting on a bad block, never
 * skipping - a shifted write would corrupt a fixed-layout partition), writes writesize-aligned,
 * and reads back through the ECC-corrected `/dev/mtdblockN` path. A plain-file target (for
 * offline testing) is written and read back directly, no ioctls. The readback SHA-256 must
 * equal `want_sha256_hex` or the call fails.
 *
 * @return 0 on success; -1 on any error (message already printed).
 */
int mtd_write_verify(const char *dev_path, const unsigned char *data, size_t len,
             const char *want_sha256_hex);

#endif
