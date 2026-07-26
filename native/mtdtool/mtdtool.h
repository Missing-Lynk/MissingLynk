/*
 * mtdtool: shared types, on-disk layout constants, and the interfaces the modules export.
 *
 * The MTD and UBI ioctls are declared here rather than pulled from kernel headers so the static
 * aarch64 build needs no headers or libraries beyond libc.
 */
#ifndef MTDTOOL_H
#define MTDTOOL_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <linux/ioctl.h>

struct mtd_info_user {
    uint8_t  type;
    uint32_t flags;
    uint32_t size;
    uint32_t erasesize;
    uint32_t writesize;
    uint32_t oobsize;
    uint64_t padding;
};

struct erase_info_user {
    uint32_t start;
    uint32_t length;
};

#define MEMGETINFO     _IOR('M', 1, struct mtd_info_user)
#define MEMERASE       _IOW('M', 2, struct erase_info_user)
#define MEMGETBADBLOCK _IOW('M', 11, int64_t)

/* UBI control ioctls (include/uapi/mtd/ubi-user.h). The attach request is 24 bytes; the kernel
 * returns the assigned ubi number.
 */
#define UBI_CTRL_IOC_MAGIC 'o'
#define UBI_IOCATT         _IOW(UBI_CTRL_IOC_MAGIC, 64, struct ubi_attach_req)
#define UBI_IOCDET         _IOW(UBI_CTRL_IOC_MAGIC, 65, int32_t)

struct ubi_attach_req {
    int32_t ubi_num;
    int32_t mtd_num;
    int32_t vid_hdr_offset;
    int16_t max_beb_per1024;
    int8_t  padding[10];
};

/* GPT on-disk layout (UEFI spec): byte offsets into the header and each partition entry. */
#define GPT_SIG          "EFI PART"
#define GPT_SIG_LEN      8
#define GPT_LBA_SIZE     512
#define GPT_HDR_SIZE     12          /* u32: header size in bytes (CRC covers this many) */
#define GPT_HDR_CRC      16          /* u32: header CRC32 (computed with this field zeroed) */
#define GPT_HDR_PTE_LBA  72          /* u64: starting LBA of the partition-entry array */
#define GPT_HDR_NUM_ENT  80          /* u32: number of entries */
#define GPT_HDR_ENT_SIZE 84          /* u32: bytes per entry */
#define GPT_HDR_PTE_CRC  88          /* u32: CRC32 of the partition-entry array */
#define GPT_ENT_ATTR     48          /* u64: attribute flags */
#define GPT_ENT_NAME     56          /* UTF-16LE partition name */
#define GPT_ENT_NAME_LEN 72          /* name field length in bytes (36 UTF-16 code units) */
#define GPT_ACTIVE_BIT   (1ULL << 47)

/* Where partition names are resolved from, and the flag that waives the slot-A refusal.
 * MTD_PROC_PATH is overridable at compile time so the guard can be exercised against a fixture.
 */
#ifndef MTD_PROC_PATH
#define MTD_PROC_PATH "/proc/mtd"
#endif
#define ALLOW_SLOT_A_FLAG "--allow-slot-a"

/* io.c - transfers that always move the whole length */
int read_full(int fd, unsigned char *buf, size_t len);
int write_full(int fd, const unsigned char *buf, size_t len);
int write_plain_file(int fd, const unsigned char *buf, size_t len);
unsigned char *read_all(const char *path, long *out_len);

/* mtd.c - the device */
int check_block_writable(int fd, uint64_t off);
int erase_range(int fd, const struct mtd_info_user *mi, uint32_t len);
int write_image(int fd, const struct mtd_info_user *mi, const unsigned char *buf, long len);
int mtd_partition_name(int fd, char *out, size_t out_sz);
int open_target(const char *path, struct mtd_info_user *mi, int *is_mtd, long *size);

/* gpt.c - buffer transforms on the partition table */
uint32_t rd32(const unsigned char *src);
uint64_t rd64(const unsigned char *src);
void wr32(unsigned char *dst, uint32_t value);
void wr64(unsigned char *dst, uint64_t value);
uint32_t crc32_buf(const unsigned char *buf, size_t n);
long find_gpt_header(const unsigned char *buf, long size);
void gpt_entry_name(const unsigned char *entry, char *out, size_t out_sz);
int gpt_set_slot(unsigned char *buf, long size, int want_b);
int gpt_get_slot(const unsigned char *buf, long size);

/* slot.c - A/B policy */
bool is_pair_member(const char *name, int *is_b);
int refuse_slot_a(int fd, const char *target, const char *command);

/* ubi.c - UBI control */
int cmd_attach(int mtd_num, int ubi_num);
int cmd_detach(int ubi_num);

#endif /* MTDTOOL_H */
