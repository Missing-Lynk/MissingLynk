/**
 * @file enc-import-test.c
 * @brief Standalone wave5 H.264 encoder DMABUF-import exerciser.
 *
 * Drives the encoder's V4L2 import path with raw ioctls, bypassing GStreamer entirely:
 * allocate a dma-heap buffer laid out like the ml-pipeline composite (I420 1920x1080
 * content in a 16-row-aligned allocation), import it on the OUTPUT queue with
 * V4L2_MEMORY_DMABUF, stream a few frames through, and report every step's errno.
 *
 * Splits the zero-copy DVR investigation: success proves the kernel path (driver,
 * buffer sizing, heap export) end to end, isolating any remaining failure to
 * GStreamer's buffer-pool layer; failure names the exact ioctl and errno.
 *
 * Usage: enc-import-test [heap-name]   (default: default_cma_region; e.g. mmz)
 * Safe to run alongside live video (the VPU multiplexes instances; the DVR does the same).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/videodev2.h>

/* dma-heap alloc UAPI, inlined: the build container's kernel headers predate it. */
struct dma_heap_allocation_data {
    uint64_t len;
    uint32_t fd;
    uint32_t fd_flags;
    uint64_t heap_flags;
};
#define DMA_HEAP_IOCTL_ALLOC _IOWR('H', 0x0, struct dma_heap_allocation_data)

#define WIDTH        1920
#define HEIGHT       1080
#define HALIGN       1088                      /* encoder sizeimage height (16-row aligned) */
#define LSTRIDE      WIDTH
#define CONTENT_SIZE (WIDTH * HEIGHT * 3 / 2)  /* I420 payload */
#define ALLOC_SIZE   (WIDTH * HALIGN * 3 / 2)  /* what the encoder's sizeimage demands */
#define CODED_SIZE   (1 << 20)                 /* capture (bitstream) buffer */
#define FRAMES       10

#define N_OUT 2                                /* OUTPUT (raw in) buffers, imported */
#define N_CAP 2                                /* CAPTURE (coded out) buffers, MMAP */

/** @brief Fail hard with the step name and errno. */
static void die(const char *step)
{
    fprintf(stderr, "FAIL %s: %s (errno %d)\n", step, strerror(errno), errno);
    exit(1);
}

static void ok(const char *step)
{
    printf("  ok: %s\n", step);
}

/** @brief Find the wave5 M2M node whose CAPTURE side offers H.264 (the encoder). */
static int open_encoder(void)
{
    char path[32];

    for (int n = 0; n < 8; n++) {
        int fd;
        struct v4l2_fmtdesc d;

        snprintf(path, sizeof path, "/dev/video%d", n);
        fd = open(path, O_RDWR);
        if (fd < 0) {
            continue;
        }

        memset(&d, 0, sizeof d);
        d.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        for (d.index = 0; ioctl(fd, VIDIOC_ENUM_FMT, &d) == 0; d.index++) {
            if (d.pixelformat == V4L2_PIX_FMT_H264) {
                printf("encoder: %s\n", path);
                return fd;
            }
        }
        close(fd);
    }

    fprintf(stderr, "FAIL: no encoder node found\n");
    exit(1);
}

/** @brief Allocate one buffer from the named dma-heap. */
static int heap_alloc(const char *heap, size_t len)
{
    char path[64];
    struct dma_heap_allocation_data a = { .len = len, .fd_flags = O_RDWR | O_CLOEXEC };
    int hfd;

    snprintf(path, sizeof path, "/dev/dma_heap/%s", heap);
    hfd = open(path, O_RDWR);
    if (hfd < 0) {
        die("open dma_heap");
    }

    if (ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &a)) {
        die("DMA_HEAP_IOCTL_ALLOC");
    }

    close(hfd);
    return a.fd;
}

int main(int argc, char **argv)
{
    const char *heap = argc > 1 ? argv[1] : "default_cma_region";
    int fd = open_encoder();
    int src_fd[N_OUT];
    void *cap_map[N_CAP];
    struct v4l2_format f;
    struct v4l2_requestbuffers rb;
    int type;

    printf("heap: %s, alloc %d (content %d)\n", heap, ALLOC_SIZE, CONTENT_SIZE);

    /* OUTPUT format: single-plane (contiguous) I420, the composite layout. */
    memset(&f, 0, sizeof f);
    f.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    f.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_YUV420;
    f.fmt.pix_mp.width = WIDTH;
    f.fmt.pix_mp.height = HEIGHT;
    f.fmt.pix_mp.num_planes = 1;
    f.fmt.pix_mp.plane_fmt[0].bytesperline = LSTRIDE;
    if (ioctl(fd, VIDIOC_S_FMT, &f)) {
        die("S_FMT(OUTPUT YUV420 1920x1080)");
    }

    printf("  ok: S_FMT OUTPUT -> %dx%d planes=%d bytesperline=%u sizeimage=%u\n",
           f.fmt.pix_mp.width, f.fmt.pix_mp.height, f.fmt.pix_mp.num_planes,
           f.fmt.pix_mp.plane_fmt[0].bytesperline, f.fmt.pix_mp.plane_fmt[0].sizeimage);

    /* CAPTURE format: H.264 coded stream. */
    memset(&f, 0, sizeof f);
    f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    f.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_H264;
    f.fmt.pix_mp.width = WIDTH;
    f.fmt.pix_mp.height = HEIGHT;
    f.fmt.pix_mp.num_planes = 1;
    f.fmt.pix_mp.plane_fmt[0].sizeimage = CODED_SIZE;
    if (ioctl(fd, VIDIOC_S_FMT, &f)) {
        die("S_FMT(CAPTURE H264)");
    }

    ok("S_FMT CAPTURE H264");

    /* OUTPUT queue: DMABUF import. */
    memset(&rb, 0, sizeof rb);
    rb.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    rb.memory = V4L2_MEMORY_DMABUF;
    rb.count = N_OUT;
    if (ioctl(fd, VIDIOC_REQBUFS, &rb)) {
        die("REQBUFS(OUTPUT DMABUF)");
    }

    printf("  ok: REQBUFS OUTPUT DMABUF -> %u\n", rb.count);

    /* CAPTURE queue: MMAP. */
    memset(&rb, 0, sizeof rb);
    rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    rb.memory = V4L2_MEMORY_MMAP;
    rb.count = N_CAP;
    if (ioctl(fd, VIDIOC_REQBUFS, &rb)) {
        die("REQBUFS(CAPTURE MMAP)");
    }

    ok("REQBUFS CAPTURE MMAP");

    /* Map + queue every capture buffer. */
    for (int i = 0; i < N_CAP; i++) {
        struct v4l2_buffer b;
        struct v4l2_plane p;

        memset(&b, 0, sizeof b);
        memset(&p, 0, sizeof p);
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        b.memory = V4L2_MEMORY_MMAP;
        b.index = i;
        b.m.planes = &p;
        b.length = 1;
        if (ioctl(fd, VIDIOC_QUERYBUF, &b)) {
            die("QUERYBUF(CAPTURE)");
        }

        cap_map[i] = mmap(NULL, p.length, PROT_READ, MAP_SHARED, fd, p.m.mem_offset);
        if (cap_map[i] == MAP_FAILED) {
            die("mmap(CAPTURE)");
        }

        if (ioctl(fd, VIDIOC_QBUF, &b)) {
            die("QBUF(CAPTURE)");
        }
    }

    ok("capture buffers mapped + queued");

    /* Source frames: dma-heap buffers with a moving gradient (deterministic, compresses fine). */
    for (int i = 0; i < N_OUT; i++) {
        uint8_t *m;

        src_fd[i] = heap_alloc(heap, ALLOC_SIZE);
        m = mmap(NULL, CONTENT_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, src_fd[i], 0);
        if (m == MAP_FAILED) {
            die("mmap(src)");
        }

        for (int y = 0; y < HEIGHT; y++) {
            memset(m + (size_t)y * LSTRIDE, (y + i * 32) & 0xff, LSTRIDE);
        }

        memset(m + (size_t)LSTRIDE * HEIGHT, 128, CONTENT_SIZE - (size_t)LSTRIDE * HEIGHT);
        munmap(m, CONTENT_SIZE);
    }

    ok("source dmabufs allocated + filled");

    type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    if (ioctl(fd, VIDIOC_STREAMON, &type)) {
        die("STREAMON(OUTPUT)");
    }

    type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (ioctl(fd, VIDIOC_STREAMON, &type)) {
        die("STREAMON(CAPTURE)");
    }

    ok("streaming");

    /* Encode: queue the imported source, reap coded frames. */
    int coded = 0;
    for (int n = 0; n < FRAMES; n++) {
        struct v4l2_buffer b;
        struct v4l2_plane p;
        struct pollfd pf = { .fd = fd, .events = POLLIN | POLLOUT };

        memset(&b, 0, sizeof b);
        memset(&p, 0, sizeof p);
        b.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
        b.memory = V4L2_MEMORY_DMABUF;
        b.index = n % N_OUT;
        b.m.planes = &p;
        b.length = 1;
        p.m.fd = src_fd[n % N_OUT];
        p.length = ALLOC_SIZE;
        p.bytesused = CONTENT_SIZE;

        /* After the first cycle the slot is still queued until its DQBUF below. */
        if (n >= N_OUT) {
            struct v4l2_buffer d;
            struct v4l2_plane dp;

            memset(&d, 0, sizeof d);
            memset(&dp, 0, sizeof dp);
            d.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
            d.memory = V4L2_MEMORY_DMABUF;
            d.m.planes = &dp;
            d.length = 1;
            if (poll(&pf, 1, 2000) <= 0) {
                die("poll(src reclaim)");
            }

            if (ioctl(fd, VIDIOC_DQBUF, &d)) {
                die("DQBUF(OUTPUT)");
            }
        }

        if (ioctl(fd, VIDIOC_QBUF, &b)) {
            fprintf(stderr, "FAIL QBUF(OUTPUT DMABUF) frame %d: %s (errno %d)\n",
                    n, strerror(errno), errno);
            exit(1);
        }

        /* Reap any ready coded frame. */
        pf.events = POLLIN;
        if (poll(&pf, 1, 2000) > 0 && (pf.revents & POLLIN)) {
            struct v4l2_buffer c;
            struct v4l2_plane cp;

            memset(&c, 0, sizeof c);
            memset(&cp, 0, sizeof cp);
            c.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
            c.memory = V4L2_MEMORY_MMAP;
            c.m.planes = &cp;
            c.length = 1;
            if (ioctl(fd, VIDIOC_DQBUF, &c) == 0) {
                const uint8_t *d = cap_map[c.index];

                printf("  coded frame %d: %u bytes, starts %02x %02x %02x %02x %02x\n",
                       coded, cp.bytesused, d[0], d[1], d[2], d[3], d[4]);
                coded++;
                if (ioctl(fd, VIDIOC_QBUF, &c)) {
                    die("re-QBUF(CAPTURE)");
                }
            }
        }
    }

    printf(coded > 0 ? "SUCCESS: %d coded frames via DMABUF import\n"
                     : "FAIL: streamed %d frames, no coded output\n", coded);

    return coded > 0 ? 0 : 1;
}
