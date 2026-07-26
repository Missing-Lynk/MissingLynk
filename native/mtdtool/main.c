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
 *   --allow-slot-a                      override the slot-A refusal (any position)
 *
 * <target> is normally /dev/mtdN. For testing, setslot/write also accept a plain file (the
 * MTD ioctls are skipped and the file is edited in place), so the slot flip can be verified
 * offline against glue/flash/gpt_setactive.py.
 *
 * Safety, three rules, all failing closed:
 *   - erase/write/setslot REFUSE a slot-A partition (kernel0/dtb0/env0/userapp0/uboot0),
 *     resolved by name from /proc/mtd via the target's own device minor. Slot A is the stock
 *     firmware every recovery path depends on. Pass --allow-slot-a to override, and note that
 *     a target whose name cannot be resolved is refused too.
 *   - on NAND, this ABORTS on a bad block in range rather than skipping it. Skipping would
 *     shift data off its offset and corrupt a fixed-layout partition such as a GPT. A block
 *     the kernel cannot classify counts as bad.
 *   - reads and writes loop until the full length has moved, so a short transfer is never
 *     mistaken for either failure or completion.
 * Verify a write by reading /dev/mtdblockN (the ECC-corrected path) and comparing md5.
 *
 * Static aarch64 build, see native/build.sh. MTD ioctls and the CRC32 are defined inline so
 * the build needs no extra headers or libraries.
 */
#include "mtdtool.h"

int cmd_write(int fd, int is_mtd, const struct mtd_info_user *mi, const char *image)
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
        rc = write_plain_file(fd, buf, (size_t)len);
    }

    free(buf);

    if (rc == 0) {
        fprintf(stderr, "wrote %ld bytes\n", len);
    }

    return rc ? 1 : 0;
}

int cmd_setslot(int fd, int is_mtd, const struct mtd_info_user *mi,
                       long size, const char *slot)
{
    unsigned char *buf = malloc(size);
    if (!buf) {
        fprintf(stderr, "out of memory\n");
        return 1;
    }

    if (lseek(fd, 0, SEEK_SET) != 0 || read_full(fd, buf, (size_t)size)) {
        fprintf(stderr, "read of target failed: %s\n", strerror(errno));
        free(buf);
        return 1;
    }

    int want_b;
    if (!strcmp(slot, "a") || !strcmp(slot, "A")) {
        want_b = 0;
    } else if (!strcmp(slot, "b") || !strcmp(slot, "B")) {
        want_b = 1;
    } else if (!strcmp(slot, "toggle") || !strcmp(slot, "other")) {
        /* read the active slot, flip to the other */
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
        rc = write_plain_file(fd, buf, (size_t)size);
    }

    free(buf);

    if (rc == 0) {
        fprintf(stderr, "active slot set to %s\n", want_b ? "B" : "A");
    }

    return rc ? 1 : 0;
}

int main(int argc, char **argv)
{
    /* Strip the slot-A override wherever it appears, so it composes with any command's
     * positional arguments.
     */
    bool allow_slot_a = false;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], ALLOW_SLOT_A_FLAG)) {
            continue;
        }

        allow_slot_a = true;

        for (int j = i; j < argc - 1; j++) {
            argv[j] = argv[j + 1];
        }

        argc--;
        i--;
    }

    if (argc < 3) {
        fprintf(stderr,
                "usage: mtdtool info|erase|write|setslot <target> [image | a|b] [%s]\n"
                "       mtdtool attach <mtdnum> [ubinum]\n"
                "       mtdtool detach <ubinum>\n",
                ALLOW_SLOT_A_FLAG);
        return 2;
    }

    /* attach/detach take numbers, not an MTD path: dispatch before open_target(). */
    const char *cmd = argv[1];
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

    /* Everything past this point mutates the target. */
    if (is_mtd && !allow_slot_a && refuse_slot_a(fd, target, cmd)) {
        return 1;
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
