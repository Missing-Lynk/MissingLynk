/**
 * @file slot.c
 * @brief A/B boot-slot detection: mtd-name resolution, the running slot, the GPT active bit.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "slot.h"
#include "util.h"

/* GPT on-disk layout (UEFI spec): byte offsets into the header and each partition entry. */
#define GPT_SIG           "EFI PART"
#define GPT_SIG_LEN       8
#define GPT_LBA_SIZE      512
#define GPT_HDR_PTE_LBA   72          /* u64: starting LBA of the partition-entry array */
#define GPT_HDR_NUM_ENT   80          /* u32: number of entries */
#define GPT_HDR_ENT_SIZE  84          /* u32: bytes per entry */
#define GPT_ENT_ATTR      48          /* u64: attribute flags */
#define GPT_ENT_NAME      56          /* UTF-16LE partition name */
#define GPT_ENT_NAME_LEN  72          /* name field length in bytes (36 UTF-16 code units) */
#define GPT_ACTIVE_BIT    (1ULL << 47)   /* attribute bit that marks the active A/B slot */

int mtd_by_name(const char *name, int *num, unsigned long *size)
{
    FILE *f = fopen("/proc/mtd", "r");
    if (!f) {
        perror("/proc/mtd");
        return -1;
    }

    char line[256];
    int found = -1;
    while (fgets(line, sizeof line, f)) {
        int n;
        unsigned long sz, es;
        char nm[64];
        /* "mtd12: 00a00000 00020000 "uboot1"" */
        if (sscanf(line, "mtd%d: %lx %lx \"%63[^\"]\"", &n, &sz, &es, nm) == 4) {
            if (strcmp(nm, name) == 0) {
                *num = n;
                *size = sz;
                found = 0;
                break;
            }
        }
    }

    fclose(f);
    return found;
}

int running_slot(void)
{
    size_t cmdline_len = 0;
    unsigned char *cmdline = read_all("/proc/cmdline", &cmdline_len);
    if (!cmdline) {
        return -1;
    }

    int mtd_num = -1;
    const char *p = strstr((char *)cmdline, "ubi.mtd=");
    if (p) {
        p += strlen("ubi.mtd=");
        mtd_num = atoi(p);
    }
    free(cmdline);

    if (mtd_num < 0) {
        return -1;
    }

    int a_num = -1, b_num = -1;
    unsigned long part_size;
    mtd_by_name("userapp0", &a_num, &part_size);
    mtd_by_name("userapp1", &b_num, &part_size);

    if (mtd_num == a_num) {
        return 0;
    }

    if (mtd_num == b_num) {
        return 1;
    }

    return -1;
}

/* Copy a GPT entry's UTF-16LE name into `out` as ASCII (low byte only, best-effort). */
static void gpt_entry_name(const unsigned char *entry, char *out, size_t out_sz)
{
    size_t n = 0;
    for (size_t off = 0; off < GPT_ENT_NAME_LEN && n + 1 < out_sz; off += 2) {
        if (entry[GPT_ENT_NAME + off] == 0 && entry[GPT_ENT_NAME + off + 1] == 0) {
            break;
        }
        out[n++] = (char)entry[GPT_ENT_NAME + off];
    }
    out[n] = 0;
}

/* True if `name` is an A/B slot-pair partition (userapp0/1 or kernel0/1); sets *slot to 0/1. */
static int gpt_pair_slot(const char *name, int *slot)
{
    size_t len = strlen(name);
    if (len < 2) {
        return 0;
    }

    char digit = name[len - 1];
    if (digit != '0' && digit != '1') {
        return 0;
    }

    if (strncmp(name, "userapp", len - 1) != 0 && strncmp(name, "kernel", len - 1) != 0) {
        return 0;
    }

    *slot = (digit == '1') ? 1 : 0;
    return 1;
}

int gpt_active_slot(void)
{
    int mtd_num = -1;
    unsigned long mtd_size = 0;
    if (mtd_by_name("gpt0", &mtd_num, &mtd_size) != 0) {
        return -1;
    }

    char dev[32];
    snprintf(dev, sizeof dev, "/dev/mtdblock%d", mtd_num);

    size_t len = 0;
    unsigned char *buf = read_all(dev, &len);
    if (!buf) {
        return -1;
    }

    int active = -1;
    for (size_t i = 0; i + GPT_SIG_LEN <= len; i++) {
        if (memcmp(buf + i, GPT_SIG, GPT_SIG_LEN) != 0) {
            continue;
        }

        const unsigned char *header = buf + i;
        uint64_t pte_lba = rd64(header + GPT_HDR_PTE_LBA);
        uint32_t num_entries = rd32(header + GPT_HDR_NUM_ENT);
        uint32_t entry_size = rd32(header + GPT_HDR_ENT_SIZE);
        long array_off = (long)pte_lba * GPT_LBA_SIZE;
        if (array_off < 0 || array_off + (long)num_entries * entry_size > (long)len) {
            break;
        }

        for (uint32_t e = 0; e < num_entries && active < 0; e++) {
            const unsigned char *entry = buf + array_off + (long)e * entry_size;
            char name[GPT_ENT_NAME_LEN / 2 + 1];
            gpt_entry_name(entry, name, sizeof name);

            int slot;
            if (gpt_pair_slot(name, &slot) && (rd64(entry + GPT_ENT_ATTR) & GPT_ACTIVE_BIT)) {
                active = slot;
            }
        }

        break;
    }

    free(buf);
    return active;
}
