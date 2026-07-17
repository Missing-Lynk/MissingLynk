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

#endif
