/*
 * mtdtool: the MTD device itself - bad-block classification, erase, write, opening a target,
 * and resolving a target's partition name.
 */
#include "mtdtool.h"

/* Returns 0 when the eraseblock at `off` may be written, -1 when it is bad OR when the kernel
 * could not classify it. MEMGETBADBLOCK answers >0 for bad and 0 for good, but -1 on error, so
 * a plain "> 0 means bad" test erases and programs blocks whose state is unknown. A device with
 * no bad-block concept at all (NOR, a plain file behind an MTD emulation) reports EOPNOTSUPP or
 * ENOTTY, which is not an error: there is simply nothing to check.
 */
int check_block_writable(int fd, uint64_t off)
{
    int64_t offset = (int64_t)off;
    int rc = ioctl(fd, MEMGETBADBLOCK, &offset);
    if (rc > 0) {
        fprintf(stderr, "BAD block at 0x%llx, aborting (fixed-layout partition)\n",
                (unsigned long long)off);
        return -1;
    }

    if (rc < 0 && errno != EOPNOTSUPP && errno != ENOTTY) {
        fprintf(stderr, "MEMGETBADBLOCK at 0x%llx: %s - block state unknown, aborting\n",
                (unsigned long long)off, strerror(errno));
        return -1;
    }

    return 0;
}

int erase_range(int fd, const struct mtd_info_user *mi, uint32_t len)
{
    uint32_t eb = mi->erasesize;
    uint32_t end = len ? ((len + eb - 1) / eb) * eb : mi->size;
    if (end > mi->size) {
        fprintf(stderr, "length 0x%x exceeds partition 0x%x\n", end, mi->size);
        return -1;
    }

    for (uint32_t off = 0; off < end; off += eb) {
        if (check_block_writable(fd, off)) {
            return -1;
        }

        struct erase_info_user ei = { off, eb };
        if (ioctl(fd, MEMERASE, &ei)) {
            fprintf(stderr, "MEMERASE at 0x%x: %s\n", off, strerror(errno));
            return -1;
        }
    }

    return 0;
}

int write_image(int fd, const struct mtd_info_user *mi,
                       const unsigned char *buf, long len)
{
    uint32_t eb = mi->erasesize;
    uint32_t ws = mi->writesize ? mi->writesize : 1;
    uint32_t off = 0;

    if (erase_range(fd, mi, (uint32_t)len)) {
        return -1;
    }

    long pos = 0;
    while (pos < len) {
        if (check_block_writable(fd, off)) {
            return -1;
        }

        uint32_t chunk = (len - pos) < (long)eb ? (uint32_t)(len - pos) : eb;
        uint32_t wlen = ((chunk + ws - 1) / ws) * ws;
        unsigned char *wb = malloc(wlen);
        if (!wb) {
            fprintf(stderr, "out of memory\n");
            return -1;
        }

        memset(wb, 0xff, wlen);
        memcpy(wb, buf + pos, chunk);

        if (lseek(fd, off, SEEK_SET) != (off_t)off) {
            perror("lseek");
            free(wb);
            return -1;
        }

        if (write_full(fd, wb, wlen)) {
            fprintf(stderr, "write at 0x%x: %s\n", off, strerror(errno));
            free(wb);
            return -1;
        }

        free(wb);
        pos += chunk;
        off += eb;
    }

    return 0;
}

/* Partition name of an open MTD char device, from /proc/mtd (the same source every host script
 * resolves partitions with). The device's own minor number identifies the line to read, so a
 * symlink or an unusual path cannot point the lookup at the wrong partition: /dev/mtdN is minor
 * N*2, /dev/mtdNro is N*2+1. Returns 0 on success.
 */
int mtd_partition_name(int fd, char *out, size_t out_sz)
{
    struct stat st;
    if (fstat(fd, &st) != 0) {
        return -1;
    }

    unsigned mtd_num = minor(st.st_rdev) / 2;
    FILE *proc = fopen(MTD_PROC_PATH, "r");
    if (!proc) {
        return -1;
    }

    int found = -1;
    char line[256];
    while (fgets(line, sizeof(line), proc)) {
        unsigned num;
        char name[128];

        /* dev:    size   erasesize  name  ->  mtd18: 02d00000 00020000 "userapp1" */
        if (sscanf(line, "mtd%u: %*x %*x \"%127[^\"]\"", &num, name) == 2 && num == mtd_num) {
            snprintf(out, out_sz, "%s", name);
            found = 0;
            break;
        }
    }

    fclose(proc);

    return found;
}

/* Open `path` for read/write. If it is an MTD char device, fill *mi and set *is_mtd=1 and
 * *size to the partition size; otherwise treat it as a plain file (*is_mtd=0).
 */
int open_target(const char *path, struct mtd_info_user *mi, int *is_mtd, long *size)
{
    int fd = open(path, O_RDWR);
    if (fd < 0) {
        perror("open");
        return -1;
    }

    if (ioctl(fd, MEMGETINFO, mi) == 0) {
        *is_mtd = 1;
        *size = mi->size;
    } else {
        struct stat st;
        if (fstat(fd, &st) != 0) {
            perror("fstat");
            close(fd);
            return -1;
        }

        *is_mtd = 0;
        *size = st.st_size;
    }

    return fd;
}
