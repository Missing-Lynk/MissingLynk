/*
 * mtdtool: raw-NAND erase/write + A/B slot flip for the Artosyn goggle/air boot flash.
 *
 * The on-device BusyBox has neither flash_erase/nandwrite nor the UBI applets (the open slot-B
 * rootfs builds without them, and mtd-utils is not installed), and three things need raw-NAND
 * or UBI-control access:
 *   - writing raw partitions that are not UBI volumes (e.g. gpt0, kernel0/1, dtb0/1),
 *   - flipping the active boot slot, which lives in the GPT (gpt0) attribute bits, and
 *   - attaching a UBI device, which the kernel only does at boot for the ubi.mtd= bootargs.
 *
 * Commands:
 *   mtdtool info    <target>            show MTD geometry
 *   mtdtool erase   <target>            erase the whole partition (-> 0xff)
 *   mtdtool write   <target> <image>    erase covering blocks, then write the image
 *   mtdtool setslot <target> a|b        flip the GPT active slot (reads, edits, writes back)
 *   mtdtool attach  <mtdnum> [ubinum]   attach an MTD as a UBI device (prints the ubi number)
 *   mtdtool detach  <ubinum>            detach a UBI device
 *
 * <target> is normally /dev/mtdN. For testing, setslot/write also accept a plain file (the
 * MTD ioctls are skipped and the file is edited in place), so the slot flip can be verified
 * offline against glue/flash/gpt_setactive.py.
 *
 * Safety: on NAND, this ABORTS on a bad block in range rather than skipping it. Skipping
 * would shift data off its offset and corrupt a fixed-layout partition such as a GPT.
 * Verify a write by reading /dev/mtdblockN (the ECC-corrected path) and comparing md5.
 *
 * Static aarch64 build, see native/build.sh. MTD ioctls and the CRC32 are defined inline so
 * the build needs no extra headers or libraries.
 */
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

#define GPT_ACTIVE_BIT (1ULL << 47)

static uint32_t rd32(const unsigned char *src)
{
    return (uint32_t)src[0] | (uint32_t)src[1] << 8 |
           (uint32_t)src[2] << 16 | (uint32_t)src[3] << 24;
}

static uint64_t rd64(const unsigned char *src)
{
    return (uint64_t)rd32(src) | (uint64_t)rd32(src + 4) << 32;
}

static void wr32(unsigned char *dst, uint32_t value)
{
    dst[0] = value;
    dst[1] = value >> 8;
    dst[2] = value >> 16;
    dst[3] = value >> 24;
}

static void wr64(unsigned char *dst, uint64_t value)
{
    wr32(dst, (uint32_t)value);
    wr32(dst + 4, (uint32_t)(value >> 32));
}

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

static bool is_bad_block(int fd, uint64_t off)
{
    int64_t offset = (int64_t)off;

    return ioctl(fd, MEMGETBADBLOCK, &offset) > 0;
}

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

static int write_image(int fd, const struct mtd_info_user *mi,
                       const unsigned char *buf, long len)
{
    uint32_t eb = mi->erasesize;
    uint32_t ws = mi->writesize ? mi->writesize : 1;
    long pos = 0;
    uint32_t off = 0;

    if (erase_range(fd, mi, (uint32_t)len)) {
        return -1;
    }

    while (pos < len) {
        if (is_bad_block(fd, off)) {
            fprintf(stderr, "BAD block at 0x%x during write, aborting\n", off);
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

        if (write(fd, wb, wlen) != (ssize_t)wlen) {
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

static unsigned char *read_all(const char *path, long *out_len)
{
    FILE *file = fopen(path, "rb");
    if (!file) {
        perror(path);
        return NULL;
    }

    fseek(file, 0, SEEK_END);
    long len = ftell(file);
    fseek(file, 0, SEEK_SET);

    if (len <= 0) {
        fprintf(stderr, "%s: empty or unreadable\n", path);
        fclose(file);
        return NULL;
    }

    unsigned char *buf = malloc(len);
    if (!buf || fread(buf, 1, len, file) != (size_t)len) {
        fprintf(stderr, "%s: read failed\n", path);
        free(buf);
        fclose(file);
        return NULL;
    }

    fclose(file);
    *out_len = len;

    return buf;
}

/* True if `name` is one of the A/B dual partitions; sets *is_b for the '1' member.
 */
static bool is_pair_member(const char *name, int *is_b)
{
    static const char *bases[] = { "env", "uboot", "kernel", "dtb", "userapp", NULL };
    size_t len = strlen(name);

    if (len < 2) {
        return 0;
    }

    char last = name[len - 1];
    if (last != '0' && last != '1') {
        return 0;
    }

    for (int i = 0; bases[i]; i++) {
        if (strlen(bases[i]) == len - 1 && strncmp(name, bases[i], len - 1) == 0) {
            *is_b = (last == '1');
            return 1;
        }
    }

    return 0;
}

/* Edit the GPT in `buf` so the target slot's dual partitions carry the active bit, then
 * recompute the entry-array and header CRC32s. Mirrors glue/flash/gpt_setactive.py.
 */
static int gpt_set_slot(unsigned char *buf, long size, int want_b)
{
    long hdr_off = -1;
    for (long i = 0; i + 8 <= size; i++) {
        if (memcmp(buf + i, "EFI PART", 8) == 0) {
            hdr_off = i;
            break;
        }
    }

    if (hdr_off < 0) {
        fprintf(stderr, "no GPT header (EFI PART) found\n");
        return -1;
    }

    uint32_t hsize = rd32(buf + hdr_off + 12);
    uint64_t pte_lba = rd64(buf + hdr_off + 72);
    uint32_t num = rd32(buf + hdr_off + 80);
    uint32_t psz = rd32(buf + hdr_off + 84);
    long base = (long)pte_lba * 512;

    if (base < 0 || base + (long)num * psz > size || hdr_off + hsize > size) {
        fprintf(stderr, "GPT entries/header out of range\n");
        return -1;
    }

    for (uint32_t i = 0; i < num; i++) {
        unsigned char *entry = buf + base + (long)i * psz;
        int empty = 1;

        for (int k = 0; k < 16; k++) {
            if (entry[k]) {
                empty = 0;
                break;
            }
        }

        if (empty) {
            continue;
        }

        char name[40];
        int j = 0;

        for (int k = 0; k < 72 && j < (int)sizeof(name) - 1; k += 2) {
            if (entry[56 + k] == 0 && entry[56 + k + 1] == 0) {
                break;
            }
            name[j++] = (char)entry[56 + k];
        }

        name[j] = 0;
        int is_b;
        if (is_pair_member(name, &is_b)) {
            uint64_t attr = rd64(entry + 48);

            if (is_b == want_b) {
                attr |= GPT_ACTIVE_BIT;
            } else {
                attr &= ~GPT_ACTIVE_BIT;
            }

            wr64(entry + 48, attr);
        }
    }

    wr32(buf + hdr_off + 88, crc32_buf(buf + base, (size_t)num * psz));
    wr32(buf + hdr_off + 16, 0);
    wr32(buf + hdr_off + 16, crc32_buf(buf + hdr_off, hsize));

    return 0;
}

/* Read the currently-active slot from the GPT in `buf`: 0 = A, 1 = B, -1 if undetermined.
 */
static int gpt_get_slot(const unsigned char *buf, long size)
{
    long hdr_off = -1;
    for (long i = 0; i + 8 <= size; i++) {
        if (memcmp(buf + i, "EFI PART", 8) == 0) {
            hdr_off = i;
            break;
        }
    }

    if (hdr_off < 0) {
        return -1;
    }

    uint64_t pte_lba = rd64(buf + hdr_off + 72);
    uint32_t num = rd32(buf + hdr_off + 80);
    uint32_t psz = rd32(buf + hdr_off + 84);
    long base = (long)pte_lba * 512;

    if (base < 0 || base + (long)num * psz > size) {
        return -1;
    }

    for (uint32_t i = 0; i < num; i++) {
        const unsigned char *entry = buf + base + (long)i * psz;
        int empty = 1;

        for (int k = 0; k < 16; k++) {
            if (entry[k]) {
                empty = 0;
                break;
            }
        }

        if (empty) {
            continue;
        }

        char name[40];
        int j = 0;

        for (int k = 0; k < 72 && j < (int)sizeof(name) - 1; k += 2) {
            if (entry[56 + k] == 0 && entry[56 + k + 1] == 0) {
                break;
            }
            name[j++] = (char)entry[56 + k];
        }

        name[j] = 0;
        int is_b;
        if (is_pair_member(name, &is_b) && (rd64(entry + 48) & GPT_ACTIVE_BIT)) {
            return is_b;
        }
    }

    return -1;
}

/* Open `path` for read/write. If it is an MTD char device, fill *mi and set *is_mtd=1 and
 * *size to the partition size; otherwise treat it as a plain file (*is_mtd=0).
 */
static int open_target(const char *path, struct mtd_info_user *mi, int *is_mtd, long *size)
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

static int cmd_write(int fd, int is_mtd, const struct mtd_info_user *mi, const char *image)
{
    long len = 0;
    unsigned char *buf = read_all(image, &len);

    if (!buf) {
        return 1;
    }

    int rc;
    if (is_mtd) {
        if ((uint32_t)len > mi->size) {
            fprintf(stderr, "image %ld bytes does not fit partition 0x%x\n", len, mi->size);
            free(buf);
            return 1;
        }

        rc = write_image(fd, mi, buf, len);
    } else {
        rc = (lseek(fd, 0, SEEK_SET) == 0 && write(fd, buf, len) == (ssize_t)len) ? 0 : -1;
    }

    free(buf);

    if (rc == 0) {
        fprintf(stderr, "wrote %ld bytes\n", len);
    }

    return rc ? 1 : 0;
}

static int cmd_setslot(int fd, int is_mtd, const struct mtd_info_user *mi,
                       long size, const char *slot)
{
    unsigned char *buf = malloc(size);
    if (!buf) {
        fprintf(stderr, "out of memory\n");
        return 1;
    }

    if (lseek(fd, 0, SEEK_SET) != 0 || read(fd, buf, size) != (ssize_t)size) {
        fprintf(stderr, "read of target failed\n");
        free(buf);
        return 1;
    }

    int want_b;
    if (!strcmp(slot, "a") || !strcmp(slot, "A")) {
        want_b = 0;
    } else if (!strcmp(slot, "b") || !strcmp(slot, "B")) {
        want_b = 1;
    } else if (!strcmp(slot, "toggle") || !strcmp(slot, "other")) {
        /* read the active slot, flip to the other
         */
        int cur = gpt_get_slot(buf, size);
        if (cur < 0) {
            fprintf(stderr, "could not determine current slot\n");
            free(buf);
            return 1;
        }
        want_b = !cur;
    } else {
        fprintf(stderr, "slot must be 'a', 'b', or 'toggle'\n");
        free(buf);
        return 1;
    }

    if (gpt_set_slot(buf, size, want_b) != 0) {
        free(buf);
        return 1;
    }

    int rc;

    if (is_mtd) {
        rc = write_image(fd, mi, buf, size);
    } else {
        rc = (lseek(fd, 0, SEEK_SET) == 0 && write(fd, buf, size) == (ssize_t)size) ? 0 : -1;
    }

    free(buf);

    if (rc == 0) {
        fprintf(stderr, "active slot set to %s\n", want_b ? "B" : "A");
    }

    return rc ? 1 : 0;
}

/* UBI control ioctls (include/uapi/mtd/ubi-user.h), defined inline so the build needs no
 * extra headers. The attach request is 24 bytes; the kernel returns the assigned ubi number.
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

/* Attach mtd_num as a UBI device. ubi_num < 0 lets the kernel pick the next free one. Attaching
 * an already-attached MTD fails with EEXIST, which the caller treats as success (idempotent).
 */
static int cmd_attach(int mtd_num, int ubi_num)
{
    int fd = open("/dev/ubi_ctrl", O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "open /dev/ubi_ctrl: %s\n", strerror(errno));
        return 1;
    }

    struct ubi_attach_req req;
    memset(&req, 0, sizeof req);
    req.ubi_num = ubi_num;
    req.mtd_num = mtd_num;
    req.vid_hdr_offset = 0;
    req.max_beb_per1024 = 0;

    int rc = ioctl(fd, UBI_IOCATT, &req);
    int err = errno;
    close(fd);

    if (rc < 0) {
        fprintf(stderr, "attach mtd%d: %s\n", mtd_num, strerror(err));
        return err == EEXIST ? 0 : 1;
    }

    /* The ioctl's return carries the assigned ubi number only when the kernel picked it; with an
     * explicit request it is 0 on success, so report what was asked for rather than that 0.
     */
    printf("%d\n", ubi_num >= 0 ? ubi_num : rc);
    return 0;
}

static int cmd_detach(int ubi_num)
{
    int fd = open("/dev/ubi_ctrl", O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "open /dev/ubi_ctrl: %s\n", strerror(errno));
        return 1;
    }

    int32_t num = ubi_num;
    int rc = ioctl(fd, UBI_IOCDET, &num);
    int err = errno;
    close(fd);

    if (rc < 0) {
        fprintf(stderr, "detach ubi%d: %s\n", ubi_num, strerror(err));
        return 1;
    }

    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr,
                "usage: mtdtool info|erase|write|setslot <target> [image | a|b]\n"
                "       mtdtool attach <mtdnum> [ubinum]\n"
                "       mtdtool detach <ubinum>\n");
        return 2;
    }

    const char *cmd = argv[1];

    /* attach/detach take numbers, not an MTD path: dispatch before open_target(). */
    if (!strcmp(cmd, "attach")) {
        return cmd_attach(atoi(argv[2]), argc >= 4 ? atoi(argv[3]) : -1);
    }

    if (!strcmp(cmd, "detach")) {
        return cmd_detach(atoi(argv[2]));
    }

    const char *target = argv[2];
    struct mtd_info_user mi;
    int is_mtd = 0;
    long size = 0;
    int fd = open_target(target, &mi, &is_mtd, &size);

    if (fd < 0) {
        return 1;
    }

    if (is_mtd) {
        fprintf(stderr, "%s: type=%u size=0x%x erasesize=0x%x writesize=0x%x\n",
                target, mi.type, mi.size, mi.erasesize, mi.writesize);
    } else {
        fprintf(stderr, "%s: plain file, %ld bytes (MTD ioctls skipped)\n", target, size);
    }

    if (!strcmp(cmd, "info")) {
        return 0;
    }

    if (!strcmp(cmd, "erase")) {
        if (!is_mtd) {
            fprintf(stderr, "erase needs an MTD device\n");
            return 2;
        }

        return erase_range(fd, &mi, 0) ? 1 : 0;
    }

    if (!strcmp(cmd, "write")) {
        if (argc < 4) {
            fprintf(stderr, "write needs an image path\n");
            return 2;
        }

        return cmd_write(fd, is_mtd, &mi, argv[3]);
    }

    if (!strcmp(cmd, "setslot")) {
        if (argc < 4) {
            fprintf(stderr, "setslot needs a slot (a|b)\n");
            return 2;
        }

        return cmd_setslot(fd, is_mtd, &mi, size, argv[3]);
    }

    fprintf(stderr, "unknown command: %s\n", cmd);
    return 2;
}
