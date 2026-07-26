/*
 * mtdtool: UBI attach/detach via the control node, so a slot's rootfs volume can be reached
 * outside the ubi.mtd= attach the kernel does at boot.
 */
#include "mtdtool.h"

/* Attach mtd_num as a UBI device. ubi_num < 0 lets the kernel pick the next free one. Attaching
 * an already-attached MTD fails with EEXIST, which the caller treats as success (idempotent).
 */
int cmd_attach(int mtd_num, int ubi_num)
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

int cmd_detach(int ubi_num)
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
