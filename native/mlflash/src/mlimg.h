/**
 * @file mlimg.h
 * @brief The .mlimg bundle: its tar container and manifest model.
 */
#ifndef MLFLASH_MLIMG_H
#define MLFLASH_MLIMG_H

#include <stddef.h>

#define MAX_COMPONENTS 16

/** @brief One flashable payload described by the manifest. */
struct component {
    char name[32];      /**< logical name (uboot/env/kernel/dtb/rootfs) */
    char role[16];      /**< "open" or "vendor" */
    char target[32];    /**< slot-relative partition, resolved to the 0/1 slot at flash time */
    char method[24];    /**< "mtdtool-raw" | "ubiformat" */
    char file[64];      /**< member name inside the tar */
    char sha256[65];    /**< hex digest of the member bytes */
    long long bytes;    /**< member byte length */
};

/** @brief Parsed manifest.json. */
struct manifest {
    long long format_version;
    char target_device[64];
    char version[128];
    struct component comp[MAX_COMPONENTS];
    int ncomp;
};

/**
 * @brief Locate member `name` in the in-memory tar `img`.
 * @param out,out_len set to the member's bytes (a pointer into img, not a copy).
 * @return 0 if found, -1 otherwise.
 */
int tar_find(const unsigned char *img, size_t img_len, const char *name,
             const unsigned char **out, size_t *out_len);

/** @brief Parse manifest.json bytes into `m`. Returns 0 on success. */
int manifest_parse(const unsigned char *data, size_t len, struct manifest *m);

#endif
