/*
 * mtdtool: GPT parsing and editing (little-endian readers, CRC32, the active-slot attribute
 * bit). Pure buffer transforms, no device access. Mirrors glue/flash/gpt_setactive.py.
 */
#include "mtdtool.h"

uint32_t rd32(const unsigned char *src)
{
    return (uint32_t)src[0] | (uint32_t)src[1] << 8 |
           (uint32_t)src[2] << 16 | (uint32_t)src[3] << 24;
}

uint64_t rd64(const unsigned char *src)
{
    return (uint64_t)rd32(src) | (uint64_t)rd32(src + 4) << 32;
}

void wr32(unsigned char *dst, uint32_t value)
{
    dst[0] = value;
    dst[1] = value >> 8;
    dst[2] = value >> 16;
    dst[3] = value >> 24;
}

void wr64(unsigned char *dst, uint64_t value)
{
    wr32(dst, (uint32_t)value);
    wr32(dst + 4, (uint32_t)(value >> 32));
}

uint32_t crc32_buf(const unsigned char *buf, size_t n)
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

/* Offset of the "EFI PART" header in `buf`, or -1 if not present.
 */
long find_gpt_header(const unsigned char *buf, long size)
{
    for (long i = 0; i + GPT_SIG_LEN <= size; i++) {
        if (memcmp(buf + i, GPT_SIG, GPT_SIG_LEN) == 0) {
            return i;
        }
    }

    return -1;
}

/* Copy a GPT entry's UTF-16LE name into `out` as ASCII (low byte only, best-effort). An unused
 * entry has an all-zero name, which yields "" and is rejected by is_pair_member.
 */
void gpt_entry_name(const unsigned char *entry, char *out, size_t out_sz)
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

/* Edit the GPT in `buf` so the target slot's dual partitions carry the active bit, then
 * recompute the entry-array and header CRC32s. Mirrors glue/flash/gpt_setactive.py.
 */
int gpt_set_slot(unsigned char *buf, long size, int want_b)
{
    long hdr_off = find_gpt_header(buf, size);
    if (hdr_off < 0) {
        fprintf(stderr, "no GPT header (EFI PART) found\n");
        return -1;
    }

    uint32_t hsize = rd32(buf + hdr_off + GPT_HDR_SIZE);
    uint64_t pte_lba = rd64(buf + hdr_off + GPT_HDR_PTE_LBA);
    uint32_t num = rd32(buf + hdr_off + GPT_HDR_NUM_ENT);
    uint32_t psz = rd32(buf + hdr_off + GPT_HDR_ENT_SIZE);

    long base = (long)pte_lba * GPT_LBA_SIZE;
    if (base < 0 || base + (long)num * psz > size || hdr_off + hsize > size) {
        fprintf(stderr, "GPT entries/header out of range\n");
        return -1;
    }

    for (uint32_t i = 0; i < num; i++) {
        unsigned char *entry = buf + base + (long)i * psz;
        char name[40];
        gpt_entry_name(entry, name, sizeof name);

        int is_b;
        if (is_pair_member(name, &is_b)) {
            uint64_t attr = rd64(entry + GPT_ENT_ATTR);
            if (is_b == want_b) {
                attr |= GPT_ACTIVE_BIT;
            } else {
                attr &= ~GPT_ACTIVE_BIT;
            }

            wr64(entry + GPT_ENT_ATTR, attr);
        }
    }

    wr32(buf + hdr_off + GPT_HDR_PTE_CRC, crc32_buf(buf + base, (size_t)num * psz));
    wr32(buf + hdr_off + GPT_HDR_CRC, 0);
    wr32(buf + hdr_off + GPT_HDR_CRC, crc32_buf(buf + hdr_off, hsize));

    return 0;
}

/* Read the currently-active slot from the GPT in `buf`: 0 = A, 1 = B, -1 if undetermined.
 */
int gpt_get_slot(const unsigned char *buf, long size)
{
    long hdr_off = find_gpt_header(buf, size);
    if (hdr_off < 0) {
        return -1;
    }

    uint64_t pte_lba = rd64(buf + hdr_off + GPT_HDR_PTE_LBA);
    uint32_t num = rd32(buf + hdr_off + GPT_HDR_NUM_ENT);
    uint32_t psz = rd32(buf + hdr_off + GPT_HDR_ENT_SIZE);

    long base = (long)pte_lba * GPT_LBA_SIZE;
    if (base < 0 || base + (long)num * psz > size) {
        return -1;
    }

    for (uint32_t i = 0; i < num; i++) {
        const unsigned char *entry = buf + base + (long)i * psz;
        char name[40];
        gpt_entry_name(entry, name, sizeof name);

        int is_b;
        if (is_pair_member(name, &is_b) && (rd64(entry + GPT_ENT_ATTR) & GPT_ACTIVE_BIT)) {
            return is_b;
        }
    }

    return -1;
}
