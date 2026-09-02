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
 * @brief The GPT-active slot, plus why it could not be read.
 *
 * The five failures are distinct states of the device (no gpt0 partition, an unreadable gpt0, no
 * GPT in it, a malformed entry array, an A/B set with no active bit) and a caller that only sees
 * "unknown" cannot tell a unit needing recovery from one this tool does not understand.
 * @param why set to a static reason sentence when the slot is undetermined, NULL otherwise. Pass
 *        NULL to ignore it. The sentence is plain ASCII with no quote or backslash.
 * @return 0 = A, 1 = B, -1 if undetermined.
 */
int gpt_active_slot_why(const char **why);

/**
 * @brief Set the GPT active bit to `slot` (0/1): edit the A/B pair entries in the primary GPT of
 *        gpt0, recompute the entry-array and header CRC32, and write the partition back
 *        (byte-exact readback-verified). Mirrors mtdtool's setslot.
 *
 * This flips the boot slot - the caller must have already gated it (the --flip flag, Rule 2).
 * @return 0 on success, -1 (message printed) on any failure.
 */
int gpt_set_active(int slot);

/** @brief Why a slot-relative partition is not a usable write target. */
enum slot_target_status {
    SLOT_TARGET_OK,          /**< resolved and passes every guard */
    SLOT_TARGET_MISSING,     /**< no partition of that name in /proc/mtd */
    SLOT_TARGET_SIBLING,     /**< the 0/1 sibling resolves to the same mtd */
    SLOT_TARGET_WHOLE_FLASH, /**< resolved to mtd0, the whole-flash alias */
    SLOT_TARGET_TOO_SMALL    /**< smaller than the image it must hold */
};

/**
 * @brief Judge slot-relative `base` (e.g. "kernel") for `slot` (0/1) against the destructive-write
 *        guards, silently.
 *
 * A target is usable when the partition exists, differs from its 0/1 sibling, is not the
 * whole-flash mtd0, and is at least `min_size` bytes (pass 0 to skip the size guard, which is the
 * image-free preflight's case). `num` and `size` are filled whenever the name resolved at all, so
 * a caller can report the geometry alongside a rejection.
 * @return the status; `num`/`size` set to -1/0 when the name did not resolve.
 */
enum slot_target_status slot_target_judge(const char *base, int slot, unsigned long min_size,
                                          int *num, unsigned long *size);

/** @brief The wire name of a target status: "ok", "missing", "sibling", "whole-flash", "small". */
const char *slot_target_status_name(enum slot_target_status status);

/**
 * @brief The slot-relative partition bases every slot owns, in flash order, NULL-terminated.
 *
 * The set a complete slot image covers ("uboot", "env", "kernel", "dtb", "userapp"). The
 * image-free preflight walks it to report whether a slot is writable at all; a flash walks the
 * manifest's own component list instead, which names the same partitions.
 */
const char *const *slot_component_bases(void);

/**
 * @brief Resolve slot-relative `base` (e.g. "kernel") for `slot` (0/1) to its mtd device path,
 *        applying the destructive-write guards.
 *
 * Refuses unless slot_target_judge() passes. On success writes "/dev/mtdN" into `dev_path`.
 * @return 0 on success, -1 (message printed) on any guard failure.
 */
int slot_resolve_target(const char *base, int slot, unsigned long min_size,
            char *dev_path, size_t dev_sz);

#endif
