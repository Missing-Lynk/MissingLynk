/**
 * @file mtd.c
 * @brief Raw MTD partition write + SHA-256 readback verify. Erase/write logic mirrors mtdtool.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <linux/ioctl.h>

#include "mtd.h"
#include "util.h"

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

static int is_bad_block(int fd, uint64_t off)
{
    int64_t offset = (int64_t)off;

    return ioctl(fd, MEMGETBADBLOCK, &offset) > 0;
}

/* Erase the eraseblocks covering `len` bytes. Aborts (does not skip) on a bad block. */
static int erase_range(int fd, const struct mtd_info_user *mi, uint32_t len)
{
    uint32_t eb = mi->erasesize;
    uint32_t end = len ? ((len + eb - 1) / eb) * eb : mi->size;

    if (end > mi->size) {
        fprintf(stderr, "length 0x%x exceeds partition 0x%x\n", end, mi->size);
        return -1;
    }

    for (uint32_t off = 0; off < end; off += eb) {
        if (is_bad_block(fd, off)) {
            fprintf(stderr, "BAD block at 0x%x, aborting (fixed-layout partition)\n", off);
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

/* Erase then write `data`, writesize-aligned, aborting on a bad block in range. */
static int write_image(int fd, const struct mtd_info_user *mi,
               const unsigned char *data, size_t len)
{
    uint32_t eb = mi->erasesize;
    uint32_t ws = mi->writesize ? mi->writesize : 1;
    size_t pos = 0;
    uint32_t off = 0;

    if (erase_range(fd, mi, (uint32_t)len))
        return -1;

    while (pos < len) {
        if (is_bad_block(fd, off)) {
            fprintf(stderr, "BAD block at 0x%x during write, aborting\n", off);
            return -1;
        }

        uint32_t chunk = (len - pos) < (size_t)eb ? (uint32_t)(len - pos) : eb;
        uint32_t wlen = ((chunk + ws - 1) / ws) * ws;
        unsigned char *wb = malloc(wlen);

        if (!wb) {
            fprintf(stderr, "out of memory\n");
            return -1;
        }

        memset(wb, 0xff, wlen);
        memcpy(wb, data + pos, chunk);

        if (lseek(fd, off, SEEK_SET) != (off_t)off ||
            write(fd, wb, wlen) != (ssize_t)wlen) {
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

/* Read `len` bytes back from a written partition to verify. For an MTD char device this is the
 * ECC-corrected /dev/mtdblockN; for a plain file it is the file itself. Caller frees.
 */
static unsigned char *readback(const char *dev_path, int is_mtd, size_t len)
{
    char rb_path[64];

    if (is_mtd) {
        /* /dev/mtdN -> /dev/mtdblockN (ECC-corrected read path). */
        const char *base = strrchr(dev_path, '/');
        base = base ? base + 1 : dev_path;
        if (strncmp(base, "mtd", 3) != 0) {
            fprintf(stderr, "cannot derive mtdblock path from %s\n", dev_path);
            return NULL;
        }

        snprintf(rb_path, sizeof rb_path, "/dev/mtdblock%s", base + 3);
    } else {
        snprintf(rb_path, sizeof rb_path, "%s", dev_path);
    }

    int fd = open(rb_path, O_RDONLY);
    if (fd < 0) {
        perror(rb_path);
        return NULL;
    }

    unsigned char *buf = malloc(len);
    if (!buf) {
        fprintf(stderr, "out of memory\n");
        close(fd);
        return NULL;
    }

    if (read(fd, buf, len) != (ssize_t)len) {
        fprintf(stderr, "%s: readback short read\n", rb_path);
        free(buf);
        close(fd);
        return NULL;
    }

    close(fd);
    return buf;
}

int mtd_write_verify(const char *dev_path, const unsigned char *data, size_t len,
             const char *want_sha256_hex)
{
    struct mtd_info_user mi;
    int is_mtd = 0;

    int fd = open(dev_path, O_RDWR);
    if (fd < 0) {
        perror(dev_path);
        return -1;
    }

    if (ioctl(fd, MEMGETINFO, &mi) == 0) {
        is_mtd = 1;
        if (len > mi.size) {
            fprintf(stderr, "%s: image %zu B does not fit partition 0x%x\n",
                dev_path, len, mi.size);
            close(fd);
            return -1;
        }
    }

    int rc;
    if (is_mtd) {
        rc = write_image(fd, &mi, data, len);
    } else {
        rc = (lseek(fd, 0, SEEK_SET) == 0 &&
              write(fd, data, len) == (ssize_t)len) ? 0 : -1;
        if (rc)
            perror(dev_path);
    }
    close(fd);

    if (rc)
        return -1;

    unsigned char *back = readback(dev_path, is_mtd, len);
    if (!back)
        return -1;

    char hex[65];
    sha256_hex(back, len, hex);
    free(back);

    if (strcmp(hex, want_sha256_hex) != 0) {
        fprintf(stderr, "%s: readback sha256 mismatch (wrote %s, read %.16s)\n",
            dev_path, want_sha256_hex, hex);
        return -1;
    }

    return 0;
}
