/**
 * @file slot.h
 * @brief A/B boot-slot detection on the device (mtd names, running slot, GPT active bit).
 */
#ifndef MLFLASH_SLOT_H
#define MLFLASH_SLOT_H

/**
 * @brief Resolve an mtd partition NAME (e.g. "userapp1") via /proc/mtd.
 * @param num,size set to the mtdN index and the partition byte size.
 * @return 0 if found, -1 otherwise.
 */
int mtd_by_name(const char *name, int *num, unsigned long *size);

/**
 * @brief The RUNNING slot, from /proc/cmdline `ubi.mtd=` matched to userapp0/1 (authoritative).
 * @return 0 = A, 1 = B, -1 if undetermined.
 */
int running_slot(void);

/**
 * @brief The GPT-active slot, read from the gpt0 partition.
 * @return 0 = A, 1 = B, -1 if undetermined.
 */
int gpt_active_slot(void);

/**
 * @brief Set the GPT active bit to `slot` (0/1): edit the A/B pair entries in the primary GPT of
 *        gpt0, recompute the entry-array and header CRC32, and write the partition back
 *        (byte-exact readback-verified). Mirrors mtdtool's setslot.
 *
 * This flips the boot slot - the caller must have already gated it (the --flip flag, Rule 2).
 * @return 0 on success, -1 (message printed) on any failure.
 */
int gpt_set_active(int slot);

/**
 * @brief Resolve slot-relative `base` (e.g. "kernel") for `slot` (0/1) to its mtd device path,
 *        applying the destructive-write guards.
 *
 * Refuses unless the partition exists, differs from its 0/1 sibling, is not the whole-flash
 * mtd0, and is at least `min_size` bytes. On success writes "/dev/mtdN" into `dev_path`.
 * @return 0 on success, -1 (message printed) on any guard failure.
 */
int slot_resolve_target(const char *base, int slot, unsigned long min_size,
            char *dev_path, size_t dev_sz);

#endif
