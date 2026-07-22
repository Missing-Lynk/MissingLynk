/**
 * @file probe.h
 * @brief Read-only content classification of a boot slot (dtb model string, kernel and rootfs
 *        magics), so a slot can be judged switchable without writing anything.
 */
#ifndef MLFLASH_PROBE_H
#define MLFLASH_PROBE_H

/** @brief What the dtb partition identifies the slot's installed image as. */
enum slot_content {
    SLOT_CONTENT_OPEN,    /**< the MissingLynk open firmware (open dtb model string) */
    SLOT_CONTENT_VENDOR,  /**< the stock vendor firmware */
    SLOT_CONTENT_EMPTY,   /**< erased flash (all 0xFF) */
    SLOT_CONTENT_UNKNOWN  /**< data present but not recognized */
};

/** @brief Result of probing one slot; probe_slot() fills every field. */
struct slot_probe {
    enum slot_content content; /**< classification from the dtb model property */
    char model[128];           /**< the dtb model string, sanitized to printable ASCII ("" if none) */
    int has_kernel;            /**< OTRA container magic present in the kernel partition */
    int has_rootfs;            /**< UBI magic present in the userapp partition */
    int is_complete;           /**< recognized dtb model AND kernel AND rootfs all present */
};

/**
 * @brief Probe slot 0 (A) / 1 (B): read the heads of its dtb, kernel, and userapp partitions and
 *        classify the contents. Read-only; never writes any partition.
 * @return 0 with *out filled, -1 if a partition of the slot cannot be resolved or read.
 */
int probe_slot(int slot, struct slot_probe *out);

/** @brief The wire name of a classification: "open", "vendor", "empty", or "unknown". */
const char *slot_content_name(enum slot_content content);

#endif
