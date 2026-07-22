/**
 * @file probe.c
 * @brief Read-only content classification of a boot slot.
 *
 * The classifier is the dtb partition's root `model` property, parsed from the flattened device
 * tree: the open firmware's DTS carries a "Artosyn Proxima-9311 (BetaFPV ..." model, the stock
 * firmware reports "Artosyn, Proxima Development Board". The kernel (OTRA container magic) and
 * userapp (UBI magic) heads are checked as well, so a half-written slot never classifies as a
 * complete image.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "probe.h"
#include "slot.h"

/* FDT header byte offsets (all fields big-endian u32) and structure-block tokens. */
#define FDT_MAGIC          0xd00dfeedu
#define FDT_OFF_MAGIC      0
#define FDT_OFF_TOTALSIZE  4
#define FDT_OFF_STRUCT     8
#define FDT_OFF_STRINGS    12
#define FDT_TOKEN_BEGIN_NODE 1
#define FDT_TOKEN_END_NODE   2
#define FDT_TOKEN_PROP       3
#define FDT_TOKEN_NOP        4
#define FDT_TOKEN_END        9

/* Largest FDT we are willing to load; a dtb partition is ~1 MiB and a real dtb far smaller. */
#define FDT_MAX_SIZE (1024 * 1024)

/* Model strings: the open firmware's DTS model prefix (goggle and air unit share it) and the
 * stock firmware's board model (constant across end products, see the carrier-board notes).
 */
static const char open_model_prefix[] = "Artosyn Proxima-9311 (BetaFPV";
static const char vendor_model[] = "Artosyn, Proxima Development Board";

/* Big-endian u32 read (the FDT wire format; rd32 in util.h is little-endian). */
static uint32_t read_be32(const unsigned char *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

/* True if the first `len` bytes are all 0xFF (erased NAND). */
static int is_erased(const unsigned char *buf, size_t len)
{
    for (size_t i = 0; i < len; i++) {
        if (buf[i] != 0xFF) {
            return 0;
        }
    }

    return 1;
}

/* Read up to `want` bytes from the head of the slot's `base` partition (via the ECC-corrected
 * mtdblock path). Returns the byte count read, or -1 if the partition cannot be resolved/opened.
 */
static long read_partition_head(const char *base, int slot, unsigned char *buf, size_t want)
{
    char name[48];
    int mtd_num = -1;
    unsigned long mtd_size = 0;

    snprintf(name, sizeof name, "%s%d", base, slot ? 1 : 0);
    if (mtd_by_name(name, &mtd_num, &mtd_size) != 0) {
        fprintf(stderr, "probe: %s not found in /proc/mtd\n", name);
        return -1;
    }

    char dev[32];
    snprintf(dev, sizeof dev, "/dev/mtdblock%d", mtd_num);
    FILE *f = fopen(dev, "rb");
    if (!f) {
        perror(dev);
        return -1;
    }

    if (want > mtd_size) {
        want = mtd_size;
    }

    size_t got = fread(buf, 1, want, f);
    fclose(f);
    return (long)got;
}

/* Copy `len` bytes of a property value into `out` as a printable ASCII string: control bytes,
 * quotes, and backslashes become '?' so the result is safe to embed in JSON unescaped.
 */
static void copy_sanitized_string(const unsigned char *value, size_t len, char *out, size_t out_sz)
{
    size_t n = 0;
    for (size_t i = 0; i < len && value[i] != 0 && n + 1 < out_sz; i++) {
        char c = (char)value[i];
        if (c < 0x20 || c > 0x7E || c == '"' || c == '\\') {
            c = '?';
        }
        out[n++] = c;
    }
    out[n] = 0;
}

/* Extract the root node's `model` property from a flattened device tree. Properties precede
 * subnodes in the FDT structure block, so the walk stops at the first nested BEGIN_NODE.
 * Returns 0 with `model` filled, -1 if the blob is malformed or has no root model.
 */
static int fdt_read_root_model(const unsigned char *fdt, size_t len, char *model, size_t model_sz)
{
    if (len < 40 || read_be32(fdt + FDT_OFF_MAGIC) != FDT_MAGIC) {
        return -1;
    }

    uint32_t struct_off = read_be32(fdt + FDT_OFF_STRUCT);
    uint32_t strings_off = read_be32(fdt + FDT_OFF_STRINGS);
    if (struct_off >= len || strings_off >= len) {
        return -1;
    }

    size_t off = struct_off;
    int depth = 0;
    while (off + 4 <= len) {
        uint32_t token = read_be32(fdt + off);
        off += 4;

        if (token == FDT_TOKEN_NOP) {
            continue;
        }

        if (token == FDT_TOKEN_END || token == FDT_TOKEN_END_NODE) {
            if (token == FDT_TOKEN_END || --depth <= 0) {
                return -1;
            }
            continue;
        }

        if (token == FDT_TOKEN_BEGIN_NODE) {
            if (++depth > 1) {
                /* Into the root's first subnode: no model property existed before it. */
                return -1;
            }

            /* Skip the NUL-terminated node name, padded to 4 bytes. */
            size_t name_end = off;
            while (name_end < len && fdt[name_end] != 0) {
                name_end++;
            }
            off = (name_end + 1 + 3) & ~(size_t)3;
            continue;
        }

        if (token == FDT_TOKEN_PROP) {
            if (off + 8 > len) {
                return -1;
            }

            uint32_t value_len = read_be32(fdt + off);
            uint32_t name_off = read_be32(fdt + off + 4);
            off += 8;
            if (off + value_len > len || strings_off + name_off >= len) {
                return -1;
            }

            const char *prop_name = (const char *)fdt + strings_off + name_off;
            if (depth == 1 && strcmp(prop_name, "model") == 0) {
                copy_sanitized_string(fdt + off, value_len, model, model_sz);
                return 0;
            }

            off = (off + value_len + 3) & ~(size_t)3;
            continue;
        }

        /* Unknown token: malformed blob. */
        return -1;
    }

    return -1;
}

/* Classify the slot's dtb partition: erased, open/vendor by model string, or unknown. */
static enum slot_content classify_dtb(int slot, char *model, size_t model_sz)
{
    unsigned char header[64];
    model[0] = 0;

    long got = read_partition_head("dtb", slot, header, sizeof header);
    if (got < (long)sizeof header) {
        return SLOT_CONTENT_UNKNOWN;
    }

    if (is_erased(header, sizeof header)) {
        return SLOT_CONTENT_EMPTY;
    }

    if (read_be32(header + FDT_OFF_MAGIC) != FDT_MAGIC) {
        return SLOT_CONTENT_UNKNOWN;
    }

    uint32_t total_size = read_be32(header + FDT_OFF_TOTALSIZE);
    if (total_size < 40 || total_size > FDT_MAX_SIZE) {
        return SLOT_CONTENT_UNKNOWN;
    }

    unsigned char *fdt = malloc(total_size);
    if (!fdt) {
        return SLOT_CONTENT_UNKNOWN;
    }

    enum slot_content content = SLOT_CONTENT_UNKNOWN;
    got = read_partition_head("dtb", slot, fdt, total_size);
    if (got == (long)total_size && fdt_read_root_model(fdt, total_size, model, model_sz) == 0) {
        if (strncmp(model, open_model_prefix, strlen(open_model_prefix)) == 0) {
            content = SLOT_CONTENT_OPEN;
        } else if (strcmp(model, vendor_model) == 0) {
            content = SLOT_CONTENT_VENDOR;
        }
    }

    free(fdt);
    return content;
}

/* True if the slot's kernel partition head carries the OTRA container magic. A kernel partition
 * on this platform always holds the vendor OTRA+uImage container the SPL boots (both the stock
 * kernel and ours, packed by mlimg.py), never a raw arm64 Image.
 */
static int has_kernel_container(int slot)
{
    unsigned char header[64];

    if (read_partition_head("kernel", slot, header, sizeof header) < (long)sizeof header) {
        return 0;
    }

    return memcmp(header, "OTRA", 4) == 0;
}

/* True if the slot's userapp partition head carries the UBI erase-counter magic ("UBI#"). */
static int has_ubi_rootfs(int slot)
{
    unsigned char header[4];

    if (read_partition_head("userapp", slot, header, sizeof header) < (long)sizeof header) {
        return 0;
    }

    return memcmp(header, "UBI#", 4) == 0;
}

int probe_slot(int slot, struct slot_probe *out)
{
    int mtd_num = -1;
    unsigned long mtd_size = 0;
    char name[48];

    /* All three partitions of the slot must exist before any classification is meaningful. */
    static const char *const bases[] = { "dtb", "kernel", "userapp" };
    for (size_t i = 0; i < sizeof bases / sizeof bases[0]; i++) {
        snprintf(name, sizeof name, "%s%d", bases[i], slot ? 1 : 0);
        if (mtd_by_name(name, &mtd_num, &mtd_size) != 0) {
            fprintf(stderr, "probe: %s not found in /proc/mtd\n", name);
            return -1;
        }
    }

    out->content = classify_dtb(slot, out->model, sizeof out->model);
    out->has_kernel = has_kernel_container(slot);
    out->has_rootfs = has_ubi_rootfs(slot);
    out->is_complete = (out->content == SLOT_CONTENT_OPEN || out->content == SLOT_CONTENT_VENDOR)
                       && out->has_kernel && out->has_rootfs;
    return 0;
}

const char *slot_content_name(enum slot_content content)
{
    switch (content) {
    case SLOT_CONTENT_OPEN:
        return "open";

    case SLOT_CONTENT_VENDOR:
        return "vendor";

    case SLOT_CONTENT_EMPTY:
        return "empty";

    default:
        return "unknown";
    }
}
