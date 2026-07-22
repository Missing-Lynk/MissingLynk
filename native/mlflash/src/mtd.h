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

/**
 * @brief Hex-encode the SHA-256 of a whole partition into `hex` (65 bytes incl. NUL).
 *
 * Reads the entire fixed-size partition through the ECC-corrected `/dev/mtdblockN` path (a plain
 * file is hashed directly, for offline testing), streaming so a large kernel partition costs no
 * bulk RAM. The digest covers the full partition, not just a written image prefix, so it is
 * length-free and reproducible: the writer, a healthy-boot self-heal, and a later re-verify all
 * compute the identical value over the same physical bytes.
 *
 * @return 0 on success, -1 on any error (message already printed).
 */
int mtd_partition_sha256(const char *dev_path, char hex[65]);

#endif
