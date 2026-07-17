/**
 * @file slot.c
 * @brief A/B boot-slot detection: mtd-name resolution, the running slot, the GPT active bit.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>

#include "slot.h"
#include "util.h"
#include "mtd.h"

/* GPT on-disk layout (UEFI spec): byte offsets into the header and each partition entry. */
#define GPT_SIG           "EFI PART"
#define GPT_SIG_LEN       8
#define GPT_LBA_SIZE      512
#define GPT_HDR_SIZE      12          /* u32: header size in bytes (CRC covers this many) */
#define GPT_HDR_CRC       16          /* u32: header CRC32 (computed with this field zeroed) */
#define GPT_HDR_PTE_LBA   72          /* u64: starting LBA of the partition-entry array */
#define GPT_HDR_NUM_ENT   80          /* u32: number of entries */
#define GPT_HDR_ENT_SIZE  84          /* u32: bytes per entry */
#define GPT_HDR_PTE_CRC   88          /* u32: CRC32 of the partition-entry array */
#define GPT_ENT_ATTR      48          /* u64: attribute flags */
#define GPT_ENT_NAME      56          /* UTF-16LE partition name */
#define GPT_ENT_NAME_LEN  72          /* name field length in bytes (36 UTF-16 code units) */
#define GPT_ACTIVE_BIT    (1ULL << 47)   /* attribute bit that marks the active A/B slot */

/* CRC32 (IEEE 802.3, reflected) over `buf` - the GPT header and entry-array checksum. */
static uint32_t crc32_buf(const unsigned char *buf, size_t n)
{
    uint32_t crc = 0xFFFFFFFFu;

    for (size_t i = 0; i < n; i++) {
        crc ^= buf[i];
        for (int bit = 0; bit < 8; bit++) {
            uint32_t mask = -(crc & 1u);
            crc = (crc >> 1) ^ (0xEDB88320u & mask);
        }
    }

    return ~crc;
}

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
    /* /proc/cmdline is a procfs file: it reports size 0 to stat/ftell, so read it into a fixed
     * buffer (read_all sizes from ftell and would see it as empty).
     */
    char cmdline[4096];
    FILE *f = fopen("/proc/cmdline", "r");
    if (!f) {
        return -1;
    }

    size_t n = fread(cmdline, 1, sizeof cmdline - 1, f);
    fclose(f);
    cmdline[n] = 0;

    const char *p = strstr(cmdline, "ubi.mtd=");
    if (!p) {
        return -1;
    }

    p += strlen("ubi.mtd=");

    /* The value is either a partition NAME ("userapp1") or an mtd NUMBER ("18"), and may be
     * followed by ",<vid_hdr_offset>" or another arg - stop at the first separator.
     */
    char val[64];
    size_t i = 0;
    while (p[i] && p[i] != ' ' && p[i] != ',' && p[i] != '\n' && i < sizeof val - 1) {
        val[i] = p[i];
        i++;
    }
    val[i] = 0;

    unsigned long part_size;
    int mtd_num;
    if (val[0] >= '0' && val[0] <= '9') {
        mtd_num = atoi(val);
    } else if (mtd_by_name(val, &mtd_num, &part_size) != 0) {
        return -1;
    }

    int a_num = -1, b_num = -1;
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

/* True if `name` is an A/B slot-pair partition (<base>0 / <base>1 for one of the boot bases);
 * sets *slot to 0/1. The base must match in full - "user0" is not "userapp". Mirrors mtdtool's
 * is_pair_member: every base here must carry the active bit for a flip to be consistent.
 */
static int gpt_pair_slot(const char *name, int *slot)
{
    static const char *const bases[] = { "env", "uboot", "kernel", "dtb", "userapp", NULL };
    size_t len = strlen(name);
    if (len < 2) {
        return 0;
    }

    char digit = name[len - 1];
    if (digit != '0' && digit != '1') {
        return 0;
    }

    for (int i = 0; bases[i]; i++) {
        if (strlen(bases[i]) == len - 1 && strncmp(name, bases[i], len - 1) == 0) {
            *slot = (digit == '1') ? 1 : 0;
            return 1;
        }
    }

    return 0;
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

/* Edit the primary GPT in `buf` so the active bit marks slot `slot`: set it on that slot's A/B
 * pair partitions, clear it on the other's, then recompute the entry-array and header CRC32.
 * Only the primary GPT is touched (as mtdtool does); the SPL boots from it. Returns 0 on success,
 * -1 (message printed) on a malformed or pairless GPT.
 */
static int gpt_edit_active(unsigned char *buf, size_t len, int slot)
{
    long hdr = -1;
    for (size_t i = 0; i + GPT_SIG_LEN <= len; i++) {
        if (memcmp(buf + i, GPT_SIG, GPT_SIG_LEN) == 0) {
            hdr = (long)i;
            break;
        }
    }

    if (hdr < 0) {
        fprintf(stderr, "flip: no GPT header (EFI PART) in gpt0\n");
        return -1;
    }

    uint32_t hsize = rd32(buf + hdr + GPT_HDR_SIZE);
    uint64_t pte_lba = rd64(buf + hdr + GPT_HDR_PTE_LBA);
    uint32_t num = rd32(buf + hdr + GPT_HDR_NUM_ENT);
    uint32_t psz = rd32(buf + hdr + GPT_HDR_ENT_SIZE);
    long base = (long)pte_lba * GPT_LBA_SIZE;
    if (base < 0 || base + (long)num * psz > (long)len || hdr + hsize > (long)len) {
        fprintf(stderr, "flip: GPT entries/header out of range\n");
        return -1;
    }

    int touched = 0;
    for (uint32_t e = 0; e < num; e++) {
        unsigned char *entry = buf + base + (long)e * psz;
        char name[GPT_ENT_NAME_LEN / 2 + 1];
        gpt_entry_name(entry, name, sizeof name);

        int pair_slot;
        if (!gpt_pair_slot(name, &pair_slot)) {
            continue;
        }

        uint64_t attr = rd64(entry + GPT_ENT_ATTR);
        if (pair_slot == slot) {
            attr |= GPT_ACTIVE_BIT;
        } else {
            attr &= ~GPT_ACTIVE_BIT;
        }
        wr64(entry + GPT_ENT_ATTR, attr);
        touched++;
    }
    if (touched == 0) {
        fprintf(stderr, "flip: no A/B pair partitions in GPT; refusing\n");
        return -1;
    }

    wr32(buf + hdr + GPT_HDR_PTE_CRC, crc32_buf(buf + base, (size_t)num * psz));
    wr32(buf + hdr + GPT_HDR_CRC, 0);
    wr32(buf + hdr + GPT_HDR_CRC, crc32_buf(buf + hdr, hsize));

    return 0;
}

int gpt_set_active(int slot)
{
    int mtd_num = -1;
    unsigned long mtd_size = 0;
    if (mtd_by_name("gpt0", &mtd_num, &mtd_size) != 0) {
        fprintf(stderr, "flip: gpt0 not found in /proc/mtd\n");
        return -1;
    }

    char block[32];
    snprintf(block, sizeof block, "/dev/mtdblock%d", mtd_num);
    size_t len = 0;
    unsigned char *buf = read_all(block, &len);
    if (!buf) {
        return -1;
    }

    int rc = gpt_edit_active(buf, len, slot);
    if (rc == 0) {
        char dev[32];
        snprintf(dev, sizeof dev, "/dev/mtd%d", mtd_num);
        char hex[65];
        sha256_hex(buf, len, hex);
        rc = mtd_write_verify(dev, buf, len, hex);
        if (rc != 0) {
            fprintf(stderr, "flip: gpt0 write/verify failed\n");
        }
    }

    free(buf);
    return rc;
}

int slot_resolve_target(const char *base, int slot, unsigned long min_size,
                        char *dev_path, size_t dev_sz)
{
    char name[48], sibling[48];
    int num, sib_num;
    unsigned long size, sib_size;

    snprintf(name, sizeof name, "%s%d", base, slot ? 1 : 0);
    if (mtd_by_name(name, &num, &size) != 0) {
        fprintf(stderr, "flash: target %s not found in /proc/mtd\n", name);
        return -1;
    }

    /* Never let the target collide with its 0/1 sibling (a partition-table surprise). */
    snprintf(sibling, sizeof sibling, "%s%d", base, slot ? 0 : 1);
    if (mtd_by_name(sibling, &sib_num, &sib_size) == 0 && sib_num == num) {
        fprintf(stderr, "flash: %s and %s both resolve to mtd%d - refusing\n",
                name, sibling, num);
        return -1;
    }

    /* Never the whole-flash device alias. */
    if (num == 0) {
        fprintf(stderr, "flash: %s resolved to mtd0 (whole flash) - refusing\n", name);
        return -1;
    }

    /* The partition must hold the image. */
    if (size < min_size) {
        fprintf(stderr, "flash: %s is %lu B, image needs %lu B\n", name, size, min_size);
        return -1;
    }

    snprintf(dev_path, dev_sz, "/dev/mtd%d", num);
    return 0;
}
