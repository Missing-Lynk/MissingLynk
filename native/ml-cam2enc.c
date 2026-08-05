/**
 * @file ml-cam2enc.c
 * @brief Decide whether the camera node's buffers can be handed to the wave5 encoder untouched.
 *
 * The CVISP capture node allocates from a `no-map shared-dma-pool`. Exporting one of those
 * buffers as a dmabuf reaches dma_direct_get_sgtable(), which builds the scatterlist from
 * pfn_to_page() of memory that pfn_valid() rejects, so whether VIDIOC_EXPBUF works at all is a
 * property of this reservation and not something the V4L2 API promises. Everything downstream
 * of the recorder depends on the answer, so measure it rather than design around it.
 *
 * Three independent questions, one mode each:
 *
 *   -x  export only. REQBUFS plus EXPBUF on the capture node, no STREAMON. The chain never
 *       starts, so this costs nothing and can be repeated within one boot.
 *   -e  encoder only. Feeds the encoder dma-heap buffers laid out exactly like the camera's
 *       (three planes, luma stride 2048 for 1920 pixels), which answers whether wave5 accepts
 *       the geometry without involving the camera at all.
 *       default: both joined. Camera buffers exported, imported on the encoder's OUTPUT queue,
 *       real frames encoded. No plane is ever mapped or read.
 *
 * Two variants of the joined path narrow down where a failure comes from:
 *
 *   -s  the camera is left stopped. The same buffers, from the same reservation, holding
 *       whatever a previous stream left in them. Separates a failure caused by where the memory
 *       lives from one caused by the camera writing while the encoder reads.
 *   -k  the camera streams normally, but buffer 0 is held out of its rotation and is the only
 *       one the encoder ever sees. Separates concurrent access to a buffer from the camera
 *       streaming at all.
 *
 * Failures of the measured ioctls are results, not crashes: each is reported with its errno and
 * the run continues where continuing still means something.
 *
 * Usage: ml-cam2enc [-x|-e] [-s|-k] [-n frames] [-b bufs] [-o file] [-c h264|hevc] [-H heap] [-p]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <poll.h>
#include <signal.h>
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

#ifndef V4L2_PIX_FMT_HEVC
#define V4L2_PIX_FMT_HEVC v4l2_fourcc('H', 'E', 'V', 'C')
#endif

#define CAM_NAME    "ar-cvisp"
#define MAX_PLANES  3
#define MAX_BUFS    8
#define CODED_SIZE  (1 << 20)
#define AR_ROWS     1080                       /* luma rows the block writes */
#define AR_NOISE_MAD 40                        /* mean adjacent-pixel delta above which a plane is noise */
#define N_CAP       2                          /* encoder bitstream buffers */
#define FRAME_RATE  60                         /* the chain's fixed 1080p60 rate, for the CBR budget */

/** Geometry read from the capture node, or synthesised in encoder-only mode. */
struct geometry {
    unsigned int width;
    unsigned int height;
    unsigned int planes;
    unsigned int bytesperline[MAX_PLANES];
    unsigned int sizeimage[MAX_PLANES];
};

static int opt_frames = 60;
static int opt_bufs = 5;
static int opt_probe;
static int opt_no_streamoff;
static int opt_gop;
static int opt_bitrate;
static unsigned long opt_max_bytes;

/** SIGINT/SIGTERM: finish the loop, drain, STREAMOFF, close the file. */
static volatile sig_atomic_t g_stop;

static void on_stop_signal(int sig)
{
    (void)sig;
    g_stop = 1;
}
static int opt_static;
static int opt_hold;
static unsigned int opt_settle_us;
static int opt_verify;
static const char *opt_dump;
static int opt_dump_count = 5;
static unsigned int opt_width;
static unsigned int opt_height;
static const char *opt_out;
static const char *opt_heap;
static uint32_t opt_codec;

/** Report an infrastructure failure and stop. Measured ioctls do not come through here. */
static void fail(const char *step)
{
    fprintf(stderr, "FAIL %s: %s (errno %d)\n", step, strerror(errno), errno);
    exit(1);
}

/** Report a measured ioctl that did not work. The caller decides whether to continue. */
static void bad(const char *step)
{
    printf("  NO: %s: %s (errno %d)\n", step, strerror(errno), errno);
}

/**
 * Wait for a queue to have something to dequeue.
 *
 * A timeout and an error are reported apart. poll() returning 0 leaves errno untouched, so
 * printing it there names whatever failed last, which reads as a plausible and wrong diagnosis.
 */
static int wait_ready(int fd, short events, int ms, const char *step)
{
    struct pollfd pf = { .fd = fd, .events = events };
    int ret = poll(&pf, 1, ms);

    if (ret > 0) {
        return 1;
    }

    if (ret == 0) {
        printf("  NO: %s: timed out after %d ms\n", step, ms);
    } else if (errno != EINTR || !g_stop) {
        /* EINTR from the stop signal is the operator ending the run, not a failure. */
        bad(step);
    }

    return 0;
}

static void fourcc(uint32_t f, char out[5])
{
    out[0] = (char)(f & 0xff);
    out[1] = (char)((f >> 8) & 0xff);
    out[2] = (char)((f >> 16) & 0xff);
    out[3] = (char)((f >> 24) & 0xff);
    out[4] = '\0';
}

/**
 * Open the capture node by driver name. Probe order decides which /dev/videoN it lands on, and
 * that changed once already when ar-vif stopped registering a node of its own.
 */
static int open_camera(char *path, size_t pathlen)
{
    DIR *d = opendir("/sys/class/video4linux");
    struct dirent *de;
    int fd = -1;

    if (d == NULL) {
        fail("opendir(/sys/class/video4linux)");
    }

    while ((de = readdir(d)) != NULL) {
        char namepath[320];
        char name[64];
        FILE *f;

        if (strncmp(de->d_name, "video", 5) != 0) {
            continue;
        }

        snprintf(namepath, sizeof namepath, "/sys/class/video4linux/%s/name", de->d_name);
        f = fopen(namepath, "r");
        if (f == NULL) {
            continue;
        }

        name[0] = '\0';
        if (fgets(name, sizeof name, f) != NULL) {
            name[strcspn(name, "\r\n")] = '\0';
        }

        fclose(f);

        if (strcmp(name, CAM_NAME) != 0) {
            continue;
        }

        snprintf(path, pathlen, "/dev/%.*s", (int)pathlen - 6, de->d_name);
        fd = open(path, O_RDWR);
        break;
    }

    closedir(d);

    if (fd < 0) {
        fprintf(stderr, "FAIL: no video node named %s (are the camera modules loaded?)\n",
                CAM_NAME);
        exit(1);
    }

    return fd;
}

/** Open the wave5 M2M node whose CAPTURE side offers the wanted coded format. */
static int open_encoder(uint32_t want, uint32_t *got, char *path, size_t pathlen)
{
    for (int n = 0; n < 16; n++) {
        int fd;
        struct v4l2_fmtdesc d;
        struct v4l2_capability cap;

        snprintf(path, pathlen, "/dev/video%d", n);
        fd = open(path, O_RDWR);
        if (fd < 0) {
            continue;
        }

        memset(&cap, 0, sizeof cap);
        if (ioctl(fd, VIDIOC_QUERYCAP, &cap) == 0 && strcmp((char *)cap.driver, CAM_NAME) == 0) {
            close(fd);
            continue;
        }

        memset(&d, 0, sizeof d);
        d.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        for (d.index = 0; ioctl(fd, VIDIOC_ENUM_FMT, &d) == 0; d.index++) {
            if (d.pixelformat == want || (want == 0 && (d.pixelformat == V4L2_PIX_FMT_HEVC
                                                        || d.pixelformat == V4L2_PIX_FMT_H264))) {
                *got = d.pixelformat;
                return fd;
            }
        }

        close(fd);
    }

    fprintf(stderr, "FAIL: no encoder node found\n");
    exit(1);
}

/** Allocate one buffer from a dma-heap, preferring a named one and then anything but mmz. */
static int heap_alloc(size_t len)
{
    struct dma_heap_allocation_data a;
    char path[288];
    int hfd = -1;
    DIR *d;

    memset(&a, 0, sizeof a);
    a.len = len;
    a.fd_flags = O_RDWR | O_CLOEXEC;

    if (opt_heap != NULL) {
        snprintf(path, sizeof path, "/dev/dma_heap/%s", opt_heap);
        hfd = open(path, O_RDWR | O_CLOEXEC);
    }

    d = opendir("/dev/dma_heap");
    if (d != NULL) {
        struct dirent *de;

        /* Prefer any heap that is not mmz: mmz is the codec's own working pool. */
        while (hfd < 0 && (de = readdir(d)) != NULL) {
            if (de->d_name[0] == '.' || strcmp(de->d_name, "mmz") == 0) {
                continue;
            }

            snprintf(path, sizeof path, "/dev/dma_heap/%s", de->d_name);
            hfd = open(path, O_RDWR | O_CLOEXEC);
        }

        /* Then take whatever exists. The air unit has only mmz. */
        if (hfd < 0) {
            rewinddir(d);
            while (hfd < 0 && (de = readdir(d)) != NULL) {
                if (de->d_name[0] == '.') {
                    continue;
                }

                snprintf(path, sizeof path, "/dev/dma_heap/%s", de->d_name);
                hfd = open(path, O_RDWR | O_CLOEXEC);
            }
        }

        closedir(d);
    }

    if (hfd < 0) {
        fail("open(/dev/dma_heap)");
    }

    if (ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &a) != 0) {
        fail("DMA_HEAP_IOCTL_ALLOC");
    }

    close(hfd);
    printf("  heap buffer: %s, %zu bytes, fd %u\n", path, len, a.fd);
    return (int)a.fd;
}


/**
 * Say whether a luma plane looks like a picture or like noise, without reading all of it.
 *
 * Adjacent pixels of a real image correlate: the mean absolute difference along a row is small,
 * a few units on smooth content and rarely above about 30. Uniform random bytes average about
 * 85. Sampling a couple of KB is enough to separate the two, which matters because these buffers
 * are uncached and a full-plane pass costs more than a frame period.
 *
 * Returns the mean absolute difference, or -1 if the plane is not mapped.
 */
static int plane_roughness(const unsigned char *base, unsigned int stride, unsigned int rows)
{
    const unsigned int span = 128;
    const unsigned int samples = 16;
    unsigned long total = 0;
    unsigned long count = 0;

    if (base == NULL) {
        return -1;
    }

    for (unsigned int i = 0; i < samples; i++) {
        const unsigned char *row = base + (size_t)(rows / samples * i) * stride;

        for (unsigned int x = 0; x + 1 < span; x++) {
            int d = (int)row[x + 1] - (int)row[x];

            total += (unsigned long)(d < 0 ? -d : d);
            count++;
        }
    }

    return count ? (int)(total / count) : -1;
}


/**
 * Cheap content fingerprint over a scattered sample of a plane.
 *
 * Used to answer whether a buffer changes while userspace owns it. A plane overwritten with a
 * newer frame still looks like a picture, so a content check cannot see an ownership violation;
 * only comparing the same buffer against itself over time can.
 */
static unsigned long plane_fingerprint(const unsigned char *base, unsigned int stride,
                                       unsigned int rows)
{
    unsigned long h = 1469598103934665603UL;

    if (base == NULL) {
        return 0;
    }

    for (unsigned int i = 0; i < 64; i++) {
        const unsigned char *row = base + (size_t)(rows / 64 * i) * stride;

        for (unsigned int x = 0; x < 256; x += 4) {
            h = (h ^ row[x]) * 1099511628211UL;
        }
    }

    return h;
}

/**
 * The capture driver's buffer depth.
 *
 * It sets how many buffers the camera queue must keep under it (min_queued_buffers is depth + 1),
 * and so how many are left for the encoder to hold. Read rather than assumed: running with the
 * wrong number starves the camera silently.
 */
static int camera_depth(void)
{
    FILE *f = fopen("/sys/module/ar_cvisp/parameters/depth", "r");
    int d = 1;

    if (f != NULL) {
        if (fscanf(f, "%d", &d) != 1 || d < 1) {
            d = 1;
        }

        fclose(f);
    }

    return d;
}

/** Read the capture node's format. This is where the plane strides come from, never a constant. */
static void camera_geometry(int fd, struct geometry *g)
{
    struct v4l2_format f;

    memset(&f, 0, sizeof f);
    f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (ioctl(fd, VIDIOC_G_FMT, &f)) {
        fail("G_FMT(camera)");
    }

    g->width = f.fmt.pix_mp.width;
    g->height = f.fmt.pix_mp.height;
    g->planes = f.fmt.pix_mp.num_planes;

    if (g->planes > MAX_PLANES) {
        fprintf(stderr, "FAIL: camera reports %u planes\n", g->planes);
        exit(1);
    }

    for (unsigned int i = 0; i < g->planes; i++) {
        g->bytesperline[i] = f.fmt.pix_mp.plane_fmt[i].bytesperline;
        g->sizeimage[i] = f.fmt.pix_mp.plane_fmt[i].sizeimage;
    }

    printf("camera: %ux%u, %u planes\n", g->width, g->height, g->planes);
    for (unsigned int i = 0; i < g->planes; i++) {
        printf("  plane %u: bytesperline %u, sizeimage %u\n",
               i, g->bytesperline[i], g->sizeimage[i]);
    }
}

/**
 * Allocate capture buffers and export every plane of every one.
 *
 * Returns the number of buffers whose planes all exported. fds is filled with -1 where the
 * export failed, so the joined path can report exactly which plane the driver refused.
 */
static int camera_export(int fd, const struct geometry *g, int nbufs,
                         int fds[MAX_BUFS][MAX_PLANES], int *allocated)
{
    struct v4l2_requestbuffers rb;
    int whole = 0;

    memset(&rb, 0, sizeof rb);
    rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    rb.memory = V4L2_MEMORY_MMAP;
    rb.count = (unsigned int)nbufs;
    if (ioctl(fd, VIDIOC_REQBUFS, &rb)) {
        fail("REQBUFS(camera MMAP)");
    }

    *allocated = (int)rb.count;
    printf("  REQBUFS asked %d, got %d\n", nbufs, *allocated);

    for (int b = 0; b < *allocated && b < MAX_BUFS; b++) {
        int ok = 1;

        for (unsigned int p = 0; p < g->planes; p++) {
            struct v4l2_exportbuffer e;
            char step[64];
            off_t size;

            memset(&e, 0, sizeof e);
            e.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
            e.index = (unsigned int)b;
            e.plane = p;
            e.flags = O_RDWR | O_CLOEXEC;

            fds[b][p] = -1;

            if (ioctl(fd, VIDIOC_EXPBUF, &e)) {
                snprintf(step, sizeof step, "EXPBUF(buf %d plane %u)", b, p);
                bad(step);
                ok = 0;
                continue;
            }

            fds[b][p] = e.fd;
            size = lseek(e.fd, 0, SEEK_END);
            printf("  ok: EXPBUF buf %d plane %u -> fd %d, dmabuf size %lld (want %u)%s\n",
                   b, p, e.fd, (long long)size, g->sizeimage[p],
                   size >= (off_t)g->sizeimage[p] ? "" : "  SHORT");

            /*
             * Mapping the exported fd goes through dma_mmap_attrs() on no-map memory, which is a
             * separate question from the export itself and can fault where the export does not.
             * Opt-in only, and one word, because the pool is uncached.
             */
            if (opt_probe) {
                volatile uint32_t *m = mmap(NULL, 4096, PROT_READ, MAP_SHARED, e.fd, 0);

                if (m == MAP_FAILED) {
                    snprintf(step, sizeof step, "mmap(dmabuf buf %d plane %u)", b, p);
                    bad(step);
                } else {
                    printf("    probe: first word 0x%08x\n", m[0]);
                    munmap((void *)m, 4096);
                }
            }
        }

        if (ok) {
            whole++;
        }
    }

    return whole;
}

/** Point the encoder at the camera's geometry and report what it adjusts it to. */
static int encoder_setup(int fd, struct geometry *g, uint32_t codec)
{
    struct v4l2_format f;
    struct v4l2_requestbuffers rb;
    char cc[5];
    int accepted = 1;

    memset(&f, 0, sizeof f);
    f.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    f.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_YUV420M;
    f.fmt.pix_mp.width = g->width;
    f.fmt.pix_mp.height = g->height;
    f.fmt.pix_mp.num_planes = g->planes;
    for (unsigned int i = 0; i < g->planes; i++) {
        f.fmt.pix_mp.plane_fmt[i].bytesperline = g->bytesperline[i];
        f.fmt.pix_mp.plane_fmt[i].sizeimage = g->sizeimage[i];
    }

    if (ioctl(fd, VIDIOC_S_FMT, &f)) {
        bad("S_FMT(encoder OUTPUT YUV420M at camera geometry)");
        return 0;
    }

    fourcc(f.fmt.pix_mp.pixelformat, cc);
    printf("  ok: S_FMT OUTPUT -> %s %ux%u, %u planes\n", cc,
           f.fmt.pix_mp.width, f.fmt.pix_mp.height, f.fmt.pix_mp.num_planes);

    if (f.fmt.pix_mp.pixelformat != V4L2_PIX_FMT_YUV420M) {
        printf("    encoder substituted the pixel format\n");
        accepted = 0;
    }

    if (f.fmt.pix_mp.num_planes != g->planes) {
        printf("    encoder substituted the plane count (wanted %u)\n", g->planes);
        accepted = 0;
    }

    for (unsigned int i = 0; i < f.fmt.pix_mp.num_planes && i < MAX_PLANES; i++) {
        unsigned int bpl = f.fmt.pix_mp.plane_fmt[i].bytesperline;
        unsigned int sz = f.fmt.pix_mp.plane_fmt[i].sizeimage;

        printf("    plane %u: bytesperline %u (wanted %u), sizeimage %u (camera has %u)%s\n",
               i, bpl, g->bytesperline[i], sz, g->sizeimage[i],
               sz > g->sizeimage[i] ? "  DEMANDS MORE THAN THE CAMERA BUFFER HOLDS" : "");

        if (bpl != g->bytesperline[i] || sz > g->sizeimage[i]) {
            accepted = 0;
        }
    }

    memset(&f, 0, sizeof f);
    f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    f.fmt.pix_mp.pixelformat = codec;
    f.fmt.pix_mp.width = g->width;
    f.fmt.pix_mp.height = g->height;
    f.fmt.pix_mp.num_planes = 1;
    f.fmt.pix_mp.plane_fmt[0].sizeimage = CODED_SIZE;
    if (ioctl(fd, VIDIOC_S_FMT, &f)) {
        bad("S_FMT(encoder CAPTURE)");
        return 0;
    }

    fourcc(codec, cc);
    printf("  ok: S_FMT CAPTURE %s\n", cc);

    /* GOP length in frames; a recording wants a periodic IRAP so a lost byte range costs one
     * GOP and seeking works. Unset keeps the driver default (a single opening IRAP). */
    if (opt_gop > 0) {
        struct v4l2_control c;

        memset(&c, 0, sizeof c);
        c.id = V4L2_CID_MPEG_VIDEO_GOP_SIZE;
        c.value = opt_gop;
        if (ioctl(fd, VIDIOC_S_CTRL, &c)) {
            bad("S_CTRL(GOP_SIZE)");
        } else {
            printf("  ok: GOP %d\n", opt_gop);
        }
    }

    /* Rate control. The driver default is FRAME_RC_ENABLE=0, which encodes at the firmware's
     * constant default QP with no bitrate target and pixelates any motion; the vendor runs
     * this encoder CBR at 8 Mbps. The driver's frame_rate also defaults to 30, so S_PARM must
     * carry the real rate or the CBR budget is computed for half the frames. */
    if (opt_bitrate > 0) {
        struct v4l2_streamparm sp;
        struct v4l2_control c;

        memset(&sp, 0, sizeof sp);
        sp.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
        sp.parm.output.timeperframe.numerator = 1;
        sp.parm.output.timeperframe.denominator = FRAME_RATE;
        if (ioctl(fd, VIDIOC_S_PARM, &sp)) {
            bad("S_PARM(encoder frame rate)");
        }

        memset(&c, 0, sizeof c);
        c.id = V4L2_CID_MPEG_VIDEO_FRAME_RC_ENABLE;
        c.value = 1;
        if (ioctl(fd, VIDIOC_S_CTRL, &c)) {
            bad("S_CTRL(FRAME_RC_ENABLE)");
        }

        memset(&c, 0, sizeof c);
        c.id = V4L2_CID_MPEG_VIDEO_BITRATE;
        c.value = opt_bitrate;
        if (ioctl(fd, VIDIOC_S_CTRL, &c)) {
            bad("S_CTRL(BITRATE)");
        } else {
            printf("  ok: CBR %d bps at %d fps\n", opt_bitrate, FRAME_RATE);
        }
    }

    memset(&rb, 0, sizeof rb);
    rb.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    rb.memory = V4L2_MEMORY_DMABUF;
    rb.count = (unsigned int)opt_bufs;
    if (ioctl(fd, VIDIOC_REQBUFS, &rb)) {
        bad("REQBUFS(encoder OUTPUT DMABUF)");
        return 0;
    }

    printf("  ok: REQBUFS OUTPUT DMABUF -> %u\n", rb.count);

    /*
     * The coded picture, read back rather than assumed. S_FMT on either queue can move it: the
     * OUTPUT one re-derives it at the end of s_fmt_out, the CAPTURE one sets it directly. This
     * is the number that decides how tall the stream is, and so whether a source alignment has
     * leaked into it.
     */
    memset(&f, 0, sizeof f);
    f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (ioctl(fd, VIDIOC_G_FMT, &f) == 0) {
        printf("  coded picture: %ux%u\n", f.fmt.pix_mp.width, f.fmt.pix_mp.height);
    }

    return accepted;
}

/** Allocate and queue the encoder's bitstream buffers. */
static void encoder_capture_bufs(int fd, void *map[N_CAP], unsigned int len[N_CAP])
{
    struct v4l2_requestbuffers rb;

    memset(&rb, 0, sizeof rb);
    rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    rb.memory = V4L2_MEMORY_MMAP;
    rb.count = N_CAP;
    if (ioctl(fd, VIDIOC_REQBUFS, &rb)) {
        fail("REQBUFS(encoder CAPTURE MMAP)");
    }

    for (int i = 0; i < N_CAP; i++) {
        struct v4l2_buffer b;
        struct v4l2_plane p;

        memset(&b, 0, sizeof b);
        memset(&p, 0, sizeof p);
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        b.memory = V4L2_MEMORY_MMAP;
        b.index = (unsigned int)i;
        b.m.planes = &p;
        b.length = 1;
        if (ioctl(fd, VIDIOC_QUERYBUF, &b)) {
            fail("QUERYBUF(encoder CAPTURE)");
        }

        len[i] = p.length;
        map[i] = mmap(NULL, p.length, PROT_READ, MAP_SHARED, fd, p.m.mem_offset);
        if (map[i] == MAP_FAILED) {
            fail("mmap(encoder CAPTURE)");
        }

        if (ioctl(fd, VIDIOC_QBUF, &b)) {
            fail("QBUF(encoder CAPTURE)");
        }
    }
}

/** Queue one imported frame on the encoder's OUTPUT queue. */
static int encoder_queue(int fd, const struct geometry *g, int index, const int *fds)
{
    struct v4l2_buffer b;
    struct v4l2_plane p[MAX_PLANES];

    memset(&b, 0, sizeof b);
    memset(p, 0, sizeof p);
    b.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    b.memory = V4L2_MEMORY_DMABUF;
    b.index = (unsigned int)index;
    b.m.planes = p;
    b.length = g->planes;

    for (unsigned int i = 0; i < g->planes; i++) {
        p[i].m.fd = fds[i];
        p[i].length = g->sizeimage[i];
        p[i].bytesused = g->sizeimage[i];
        p[i].data_offset = 0;
    }

    return ioctl(fd, VIDIOC_QBUF, &b);
}

/** Dequeue a completed bitstream buffer if one is ready. Returns bytes written, or 0. */
/**
 * FNV-1a over every coded byte of the run.
 *
 * The heap-source run encodes a fixed synthetic pattern, so its bitstream is a pure function of
 * the encoder: two runs of the same build must hash the same. That makes corruption visible with
 * no decode and no file transfer, which is what a run alongside a streaming capture node needs.
 */
static unsigned long stream_hash = 1469598103934665603UL;

static unsigned int encoder_reap(int fd, void *map[N_CAP], FILE *out, int *coded)
{
    struct pollfd pf = { .fd = fd, .events = POLLIN };
    struct v4l2_buffer c;
    struct v4l2_plane cp;
    unsigned int bytes;

    if (poll(&pf, 1, 0) <= 0 || !(pf.revents & POLLIN)) {
        return 0;
    }

    memset(&c, 0, sizeof c);
    memset(&cp, 0, sizeof cp);
    c.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    c.memory = V4L2_MEMORY_MMAP;
    c.m.planes = &cp;
    c.length = 1;
    if (ioctl(fd, VIDIOC_DQBUF, &c)) {
        return 0;
    }

    bytes = cp.bytesused;
    if (out != NULL && bytes > 0) {
        fwrite(map[c.index], 1, bytes, out);
    }

    for (unsigned int i = 0; i < bytes; i++) {
        stream_hash = (stream_hash ^ ((const uint8_t *)map[c.index])[i]) * 1099511628211UL;
    }

    if (*coded < 5) {
        const uint8_t *d = map[c.index];

        printf("  coded frame %d: %u bytes, starts %02x %02x %02x %02x %02x\n",
               *coded, bytes, d[0], d[1], d[2], d[3], d[4]);
    }

    (*coded)++;

    if (ioctl(fd, VIDIOC_QBUF, &c)) {
        bad("re-QBUF(encoder CAPTURE)");
    }

    return bytes;
}

/**
 * Encoder-only run: dma-heap buffers at the camera's exact layout, so a refusal here is about
 * the geometry and nothing else.
 *
 * The source is a fixed synthetic pattern written once, so the bitstream depends on nothing but
 * the encoder. Repeat the run and the STREAM hash must repeat with it. Run it while the capture
 * node streams and a changed hash says the encoder is disturbed by concurrent capture rather
 * than by anything about the camera's buffers, which this mode never touches.
 */
static int run_encoder_only(uint32_t codec)
{
    struct geometry g;
    int fds[2][MAX_PLANES];
    void *cap_map[N_CAP];
    unsigned int cap_len[N_CAP];
    char path[64];
    uint32_t got;
    FILE *out = NULL;
    int fd;
    int type;
    int coded = 0;
    unsigned long total = 0;

    /*
     * The camera's shipped geometry, restated here because the camera is not opened. The plane
     * sizes carry ar-cvisp's row padding (1080 rounded to the encoder's 16-row step), which is
     * what the capture node reports through G_FMT.
     */
    g.width = opt_width ? opt_width : 1920;
    g.height = opt_height ? opt_height : 1080;
    g.planes = 3;

    if (opt_width) {
        /*
         * A geometry given on the command line is packed, the layout the RF transmitter's tiles
         * use: stride equals the width, and the allocation covers the encoder's 16-row step.
         */
        unsigned int rows = (g.height + 15) & ~15u;

        g.bytesperline[0] = g.width;
        g.sizeimage[0] = g.width * rows;
        g.bytesperline[1] = g.width / 2;
        g.sizeimage[1] = (g.width / 2) * (rows / 2);
        g.bytesperline[2] = g.bytesperline[1];
        g.sizeimage[2] = g.sizeimage[1];
    } else {
        g.bytesperline[0] = 2048;
        g.sizeimage[0] = 2048 * 1088;
        g.bytesperline[1] = 1024;
        g.sizeimage[1] = 1024 * 544;
        g.bytesperline[2] = 1024;
        g.sizeimage[2] = 1024 * 544;
    }

    fd = open_encoder(codec, &got, path, sizeof path);
    printf("encoder: %s\n", path);

    opt_bufs = 2;
    if (!encoder_setup(fd, &g, got)) {
        printf("RESULT: the encoder does not take the camera's geometry as-is\n");
        return 1;
    }

    encoder_capture_bufs(fd, cap_map, cap_len);

    for (int b = 0; b < 2; b++) {
        for (unsigned int p = 0; p < g.planes; p++) {
            uint8_t *m;

            fds[b][p] = heap_alloc(g.sizeimage[p]);
            m = mmap(NULL, g.sizeimage[p], PROT_READ | PROT_WRITE, MAP_SHARED, fds[b][p], 0);
            if (m == MAP_FAILED) {
                fail("mmap(heap source)");
            }

            if (p == 0) {
                for (unsigned int y = 0; y < g.height; y++) {
                    memset(m + (size_t)y * g.bytesperline[0], (int)((y + (unsigned)b * 32) & 0xff),
                           g.bytesperline[0]);
                }
            } else {
                memset(m, 128, g.sizeimage[p]);
            }

            munmap(m, g.sizeimage[p]);
        }
    }

    if (opt_out != NULL) {
        out = fopen(opt_out, "wb");
    }

    type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    if (ioctl(fd, VIDIOC_STREAMON, &type)) {
        bad("STREAMON(encoder OUTPUT)");
        return 1;
    }

    type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (ioctl(fd, VIDIOC_STREAMON, &type)) {
        bad("STREAMON(encoder CAPTURE)");
        return 1;
    }

    for (int n = 0; n < opt_frames; n++) {
        if (n >= 2) {
            struct pollfd pf = { .fd = fd, .events = POLLOUT };
            struct v4l2_buffer d;
            struct v4l2_plane dp[MAX_PLANES];

            memset(&d, 0, sizeof d);
            memset(dp, 0, sizeof dp);
            d.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
            d.memory = V4L2_MEMORY_DMABUF;
            d.m.planes = dp;
            d.length = g.planes;
            if (poll(&pf, 1, 2000) <= 0 || ioctl(fd, VIDIOC_DQBUF, &d)) {
                bad("DQBUF(encoder OUTPUT)");
                break;
            }
        }

        if (encoder_queue(fd, &g, n % 2, fds[n % 2])) {
            bad("QBUF(encoder OUTPUT DMABUF)");
            break;
        }

        total += encoder_reap(fd, cap_map, out, &coded);

        /* Paced, the run doubles as a long-lived background instance holder. */
        if (opt_settle_us) {
            usleep(opt_settle_us);
        }
    }

    /* Drain, so the hash covers the same frame count on every run and stays comparable. */
    for (int i = 0; i < 16 && coded < opt_frames; i++) {
        struct pollfd pf = { .fd = fd, .events = POLLIN };

        if (poll(&pf, 1, 200) <= 0) {
            break;
        }

        total += encoder_reap(fd, cap_map, out, &coded);
    }

    /*
     * Instances alternate strictly between a full stream and one that codes nothing, and the
     * only thing that changed when that started was this pair of STREAMOFFs. -S leaves them out
     * and closes the fd instead, which is what the runs that never alternated did.
     */
    if (!opt_no_streamoff) {
        type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
        ioctl(fd, VIDIOC_STREAMOFF, &type);
        type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        ioctl(fd, VIDIOC_STREAMOFF, &type);
    }

    close(fd);

    if (out != NULL) {
        fclose(out);
    }

    printf("STREAM: %d coded, %lu bytes, hash %016lx\n", coded, total, stream_hash);
    printf(coded > 0 ? "RESULT: encoder accepts the camera geometry, %d coded frames\n"
                     : "RESULT: encoder took the format but produced no coded frame\n", coded);
    return coded > 0 ? 0 : 1;
}

/** Joined run: camera buffers exported and imported straight into the encoder. */
static int run_joined(uint32_t codec)
{
    struct geometry g;
    int fds[MAX_BUFS][MAX_PLANES];
    void *cap_map[N_CAP];
    unsigned int cap_len[N_CAP];
    char campath[64];
    char encpath[64];
    uint32_t got;
    FILE *out = NULL;
    int cam;
    int enc;
    int allocated = 0;
    int whole;
    int type;
    int inflight = 0;
    int max_inflight;
    int depth;
    void *luma[MAX_BUFS] = { NULL };
    int rough_image = 0;
    int rough_noise = 0;
    int changed = 0;
    int coded = 0;
    unsigned long total = 0;
    int dropped = 0;

    cam = open_camera(campath, sizeof campath);
    printf("camera node: %s\n", campath);
    camera_geometry(cam, &g);

    whole = camera_export(cam, &g, opt_bufs, fds, &allocated);
    if (whole < 2) {
        printf("RESULT: only %d of %d buffers exported whole, cannot import into the encoder\n",
               whole, allocated);
        return 1;
    }

    /*
     * Map luma only, and only to sample it. This is the one place the rule against touching a
     * capture buffer is relaxed: the question is whether the plane already holds noise BEFORE
     * the encoder sees it, and that cannot be answered from outside the buffer.
     */
    if (opt_verify) {
        for (int b = 0; b < allocated && b < MAX_BUFS; b++) {
            struct v4l2_buffer q;
            struct v4l2_plane qp[MAX_PLANES];

            memset(&q, 0, sizeof q);
            memset(qp, 0, sizeof qp);
            q.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
            q.memory = V4L2_MEMORY_MMAP;
            q.index = (unsigned int)b;
            q.m.planes = qp;
            q.length = g.planes;
            if (ioctl(cam, VIDIOC_QUERYBUF, &q)) {
                bad("QUERYBUF(camera verify)");
                break;
            }

            luma[b] = mmap(NULL, qp[0].length, PROT_READ, MAP_SHARED, cam, qp[0].m.mem_offset);
            if (luma[b] == MAP_FAILED) {
                bad("mmap(camera luma)");
                luma[b] = NULL;
            }
        }
    }

    enc = open_encoder(codec, &got, encpath, sizeof encpath);
    printf("encoder: %s\n", encpath);

    opt_bufs = allocated;
    if (!encoder_setup(enc, &g, got)) {
        printf("RESULT: EXPBUF works, but the encoder will not take the camera's geometry\n");
        return 1;
    }

    encoder_capture_bufs(enc, cap_map, cap_len);

    if (opt_out != NULL) {
        out = fopen(opt_out, "wb");
        if (out == NULL) {
            fail("fopen(output)");
        }
    }

    /*
     * The camera queue must keep min_queued_buffers, which is depth + 1, under it or it runs dry
     * and drops frames, so the encoder may never hold more than the rest.
     *
     * The hold variant keeps buffer 0 out of the camera's rotation entirely and encodes only
     * that one. The camera streams normally on the others, so the encoder is reading a buffer of
     * the same reservation that the block is not touching. That separates a failure caused by
     * concurrent access to the buffer from one caused by the camera streaming at all.
     */
    depth = camera_depth();
    max_inflight = allocated - (depth + 1) - (opt_hold ? 1 : 0);
    if (max_inflight < 1) {
        max_inflight = 1;
    }

    /*
     * The static variant never starts the camera. The same buffers, from the same reservation,
     * are fed to the encoder holding whatever the last stream left in them. It separates a
     * failure caused by where the memory lives from one caused by the camera writing it while
     * the encoder reads.
     */
    if (!opt_static) {
        for (int b = opt_hold ? 1 : 0; b < allocated; b++) {
            struct v4l2_buffer q;
            struct v4l2_plane qp[MAX_PLANES];

            memset(&q, 0, sizeof q);
            memset(qp, 0, sizeof qp);
            q.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
            q.memory = V4L2_MEMORY_MMAP;
            q.index = (unsigned int)b;
            q.m.planes = qp;
            q.length = g.planes;
            if (ioctl(cam, VIDIOC_QBUF, &q)) {
                fail("QBUF(camera)");
            }
        }
    }

    type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    if (ioctl(enc, VIDIOC_STREAMON, &type)) {
        bad("STREAMON(encoder OUTPUT)");
        return 1;
    }

    type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (ioctl(enc, VIDIOC_STREAMON, &type)) {
        bad("STREAMON(encoder CAPTURE)");
        return 1;
    }

    if (!opt_static) {
        type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        if (ioctl(cam, VIDIOC_STREAMON, &type)) {
            bad("STREAMON(camera)");
            return 1;
        }
    }

    printf("%s: %d frames, up to %d buffers in the encoder\n",
           opt_static ? "static, camera not streaming" : "streaming",
           opt_frames, max_inflight);

    for (int n = 0; (n < opt_frames || opt_frames == 0) && !g_stop; n++) {
        struct v4l2_buffer b;
        struct v4l2_plane p[MAX_PLANES];

        if (opt_max_bytes && total >= opt_max_bytes) {
            printf("byte cap reached (%lu), stopping\n", total);
            break;
        }

        /* Reclaim before taking another frame, so the camera never starves. */
        while (inflight >= max_inflight) {
            struct v4l2_buffer d;
            struct v4l2_plane dp[MAX_PLANES];
            struct v4l2_buffer r;
            struct v4l2_plane rp[MAX_PLANES];

            if (!wait_ready(enc, POLLOUT, 2000, "encoder OUTPUT reclaim")) {
                goto done;
            }

            memset(&d, 0, sizeof d);
            memset(dp, 0, sizeof dp);
            d.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
            d.memory = V4L2_MEMORY_DMABUF;
            d.m.planes = dp;
            d.length = g.planes;
            if (ioctl(enc, VIDIOC_DQBUF, &d)) {
                bad("DQBUF(encoder OUTPUT)");
                goto done;
            }

            inflight--;

            if (opt_static || opt_hold) {
                continue;
            }

            memset(&r, 0, sizeof r);
            memset(rp, 0, sizeof rp);
            r.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
            r.memory = V4L2_MEMORY_MMAP;
            r.index = d.index;
            r.m.planes = rp;
            r.length = g.planes;
            if (ioctl(cam, VIDIOC_QBUF, &r)) {
                bad("re-QBUF(camera)");
                goto done;
            }
        }

        memset(&b, 0, sizeof b);
        memset(p, 0, sizeof p);

        if (opt_static) {
            b.index = (unsigned int)(n % allocated);
        } else {
            if (!wait_ready(cam, POLLIN, 2000, "camera frame")) {
                goto done;
            }

            b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
            b.memory = V4L2_MEMORY_MMAP;
            b.m.planes = p;
            b.length = g.planes;
            if (ioctl(cam, VIDIOC_DQBUF, &b)) {
                bad("DQBUF(camera)");
                goto done;
            }

            if (b.flags & V4L2_BUF_FLAG_ERROR) {
                dropped++;
            }

            /*
             * The held buffer is the only one the encoder ever sees, so the camera's own
             * buffers go straight back and keep the stream paced at frame rate.
             */
            if (opt_hold) {
                if (ioctl(cam, VIDIOC_QBUF, &b)) {
                    bad("re-QBUF(camera, hold)");
                    goto done;
                }

                b.index = 0;
            }
        }

        /*
         * Let the block finish with the buffer before the encoder reads it. The driver already
         * holds it for depth ticks; this adds wall-clock slack on top, so a failure that goes
         * away here is a write that had not drained rather than anything about the encoder.
         */
        if (opt_settle_us) {
            usleep(opt_settle_us);
        }

        if (opt_verify && opt_settle_us) {
            /*
             * Ownership, with the encoder attached. The camera-only check cannot cover the case
             * that matters: under a slow consumer the camera queue runs dry, and a dry tick
             * takes a different path.
             */
            unsigned long f0 = plane_fingerprint(luma[b.index], g.bytesperline[0], AR_ROWS);
            unsigned long f1;

            usleep(opt_settle_us);
            f1 = plane_fingerprint(luma[b.index], g.bytesperline[0], AR_ROWS);

            if (f0 != f1) {
                changed++;
                if (changed <= 5) {
                    printf("  frame %d, buffer %u: CHANGED while userspace owned it\n",
                           n, b.index);
                }
            }
        }

        if (opt_verify) {
            int rough = plane_roughness(luma[b.index], g.bytesperline[0], AR_ROWS);

            if (rough >= 0) {
                if (rough > AR_NOISE_MAD) {
                    rough_noise++;
                    if (rough_noise <= 5) {
                        printf("  buffer %u NOISE before the encoder, roughness %d\n",
                               b.index, rough);
                    }
                } else {
                    rough_image++;
                }
            }
        }

        if (encoder_queue(enc, &g, (int)b.index, fds[b.index])) {
            char step[64];

            snprintf(step, sizeof step, "QBUF(encoder OUTPUT, camera buffer %u)", b.index);
            bad(step);
            goto done;
        }

        inflight++;
        total += encoder_reap(enc, cap_map, out, &coded);
    }

done:
    /* Drain whatever the encoder still holds before judging the run. */
    for (int i = 0; i < 8 && (opt_frames == 0 || coded < opt_frames); i++) {
        struct pollfd pf = { .fd = enc, .events = POLLIN };

        if (poll(&pf, 1, 200) <= 0) {
            break;
        }

        total += encoder_reap(enc, cap_map, out, &coded);
    }

    if (!opt_static) {
        type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        ioctl(cam, VIDIOC_STREAMOFF, &type);
    }

    type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    ioctl(enc, VIDIOC_STREAMOFF, &type);
    type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    ioctl(enc, VIDIOC_STREAMOFF, &type);

    if (out != NULL) {
        fclose(out);
    }

    if (opt_verify) {
        printf("before the encoder: %d frames looked like image, %d looked like noise, "
               "%d CHANGED while held\n", rough_image, rough_noise, changed);
    }

    printf("%d coded frames, %lu bytes, %d camera buffers flagged error\n", coded, total, dropped);
    printf("STREAM: %d coded, %lu bytes, hash %016lx\n", coded, total, stream_hash);

    /*
     * A returned buffer is not an encoded frame. The encoder hands its bitstream buffers back
     * with bytesused 0 when the picture failed, so bytes are the test and the count is not.
     */
    printf(total > 0 ? "RESULT: zero-copy camera to encoder works\n"
                     : "RESULT: buffers came back empty, nothing was encoded\n");
    return total > 0 ? 0 : 1;
}


/**
 * Stream the camera and judge each completed buffer, with no encoder anywhere.
 *
 * The baseline the joined runs lacked: if buffers already hold noise here, the encoder is a
 * bystander and the fault is in the capture path. If every buffer looks like a picture here but
 * half the encoded frames are noise, then something about the encoder reading them is what
 * breaks, and the capture path hands out sound data.
 */
static int run_verify_only(void)
{
    struct geometry g;
    void *luma[MAX_BUFS] = { NULL };
    char campath[64];
    int allocated = 0;
    int type;
    int image = 0;
    int noise = 0;
    int next_dump = 0;
    int changed = 0;
    int stable = 0;
    /*
     * Offset by one so the spacing is not a multiple of the buffer count. An even split of 3600
     * over 5 lands on frame 0, 720, 1440 and so on, and with five buffers rotating in order every
     * one of those is buffer 0: five dumps of the same buffer, which looks like coverage and is
     * not.
     */
    int spacing = opt_frames / (opt_dump_count > 0 ? opt_dump_count : 1) + 1;
    int cam = open_camera(campath, sizeof campath);
    struct v4l2_requestbuffers rb;

    printf("camera node: %s\n", campath);
    camera_geometry(cam, &g);

    memset(&rb, 0, sizeof rb);
    rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    rb.memory = V4L2_MEMORY_MMAP;
    rb.count = (unsigned int)opt_bufs;
    if (ioctl(cam, VIDIOC_REQBUFS, &rb)) {
        fail("REQBUFS(camera)");
    }

    allocated = (int)rb.count;
    printf("  %d buffers\n", allocated);

    for (int b = 0; b < allocated && b < MAX_BUFS; b++) {
        struct v4l2_buffer q;
        struct v4l2_plane qp[MAX_PLANES];

        memset(&q, 0, sizeof q);
        memset(qp, 0, sizeof qp);
        q.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        q.memory = V4L2_MEMORY_MMAP;
        q.index = (unsigned int)b;
        q.m.planes = qp;
        q.length = g.planes;
        if (ioctl(cam, VIDIOC_QUERYBUF, &q)) {
            fail("QUERYBUF(camera)");
        }

        luma[b] = mmap(NULL, qp[0].length, PROT_READ, MAP_SHARED, cam, qp[0].m.mem_offset);
        if (luma[b] == MAP_FAILED) {
            luma[b] = NULL;
            bad("mmap(camera luma)");
        }

        if (ioctl(cam, VIDIOC_QBUF, &q)) {
            fail("QBUF(camera)");
        }
    }

    type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (ioctl(cam, VIDIOC_STREAMON, &type)) {
        bad("STREAMON(camera)");
        return 1;
    }

    for (int n = 0; n < opt_frames; n++) {
        struct v4l2_buffer b;
        struct v4l2_plane p[MAX_PLANES];
        int rough;

        if (!wait_ready(cam, POLLIN, 2000, "camera frame")) {
            break;
        }

        memset(&b, 0, sizeof b);
        memset(p, 0, sizeof p);
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        b.memory = V4L2_MEMORY_MMAP;
        b.m.planes = p;
        b.length = g.planes;
        if (ioctl(cam, VIDIOC_DQBUF, &b)) {
            bad("DQBUF(camera)");
            break;
        }

        /*
         * Luma only. A full frame is 3.34 MB across three planes and /tmp is a 32 MB tmpfs, so
         * five of them leaves almost nothing; luma alone is 2.2 MB and is all that is needed to
         * tell a picture from noise.
         */
        if (opt_dump != NULL && luma[b.index] != NULL && next_dump < opt_dump_count
            && n >= next_dump * spacing) {
            char path[256];
            FILE *f;

            snprintf(path, sizeof path, "%s.%02d.0", opt_dump, next_dump);
            f = fopen(path, "wb");
            if (f != NULL) {
                fwrite(luma[b.index], 1, (size_t)g.bytesperline[0] * AR_ROWS, f);
                fclose(f);
                printf("  dumped %s from buffer %u at frame %d\n", path, b.index, n);
            } else {
                bad("fopen(dump)");
            }

            next_dump++;
        }

        /*
         * Ownership check. The buffer is ours between DQBUF and QBUF, so nothing should touch
         * it. Two fingerprints across that window disagreeing means the block wrote a buffer it
         * had already handed back, which no content check can see because the overwrite is a
         * valid picture too.
         */
        if (opt_settle_us) {
            unsigned long a = plane_fingerprint(luma[b.index], g.bytesperline[0], AR_ROWS);
            unsigned long c;

            usleep(opt_settle_us);
            c = plane_fingerprint(luma[b.index], g.bytesperline[0], AR_ROWS);

            if (a != c) {
                changed++;
                if (changed <= 5) {
                    printf("  frame %d, buffer %u: CHANGED while userspace owned it\n",
                           n, b.index);
                }
            } else {
                stable++;
            }
        }

        rough = plane_roughness(luma[b.index], g.bytesperline[0], AR_ROWS);
        if (rough > AR_NOISE_MAD) {
            noise++;
            if (noise <= 5) {
                printf("  frame %d, buffer %u: NOISE, roughness %d\n", n, b.index, rough);
            }
        } else if (rough >= 0) {
            image++;
        }

        if (ioctl(cam, VIDIOC_QBUF, &b)) {
            bad("re-QBUF(camera)");
            break;
        }
    }

    type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    ioctl(cam, VIDIOC_STREAMOFF, &type);

    if (opt_settle_us) {
        printf("ownership: %d buffers stable while held, %d CHANGED under us\n",
               stable, changed);
    }

    printf("%d frames looked like image, %d looked like noise\n", image, noise);
    printf(noise == 0 ? "RESULT: the capture path hands out sound buffers\n"
                      : "RESULT: the capture path itself produces noise\n");
    return noise == 0 ? 0 : 1;
}


/**
 * Camera and encoder both on heap dmabufs: the capture node imports them too.
 *
 * The one remaining difference between a bridge that works and one that does not. Heap buffers
 * drive the encoder perfectly; buffers the capture node allocated from its `no-map` reservation
 * do not, even though their contents are verified sound on the way in. Both regions are no-map,
 * so the suspect is not the memory but the export: vb2-dma-contig builds its scatterlist with
 * dma_get_sgtable() over pages the kernel does not really have, while the heap exports its own.
 *
 * Here the capture queue imports heap dmabufs instead of allocating, so every buffer the encoder
 * sees came from the same exporter the goggle's working recorder uses.
 */
static int run_heap_bridge(uint32_t codec)
{
    struct geometry g;
    int fds[MAX_BUFS][MAX_PLANES];
    void *cap_map[N_CAP];
    unsigned int cap_len[N_CAP];
    char campath[64];
    char encpath[64];
    uint32_t got;
    struct v4l2_requestbuffers rb;
    int cam;
    int enc;
    int type;
    int coded = 0;
    unsigned long total = 0;
    int nbufs = opt_bufs;

    cam = open_camera(campath, sizeof campath);
    printf("camera node: %s\n", campath);
    camera_geometry(cam, &g);

    memset(&rb, 0, sizeof rb);
    rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    rb.memory = V4L2_MEMORY_DMABUF;
    rb.count = (unsigned int)nbufs;
    if (ioctl(cam, VIDIOC_REQBUFS, &rb)) {
        bad("REQBUFS(camera DMABUF)");
        return 1;
    }

    nbufs = (int)rb.count;
    printf("  camera queue takes %d imported buffers\n", nbufs);

    for (int b = 0; b < nbufs && b < MAX_BUFS; b++) {
        for (unsigned int p = 0; p < g.planes; p++) {
            fds[b][p] = heap_alloc(g.sizeimage[p]);
        }
    }

    for (int b = 0; b < nbufs && b < MAX_BUFS; b++) {
        struct v4l2_buffer q;
        struct v4l2_plane qp[MAX_PLANES];

        memset(&q, 0, sizeof q);
        memset(qp, 0, sizeof qp);
        q.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        q.memory = V4L2_MEMORY_DMABUF;
        q.index = (unsigned int)b;
        q.m.planes = qp;
        q.length = g.planes;
        for (unsigned int p = 0; p < g.planes; p++) {
            qp[p].m.fd = fds[b][p];
            qp[p].length = g.sizeimage[p];
        }

        if (ioctl(cam, VIDIOC_QBUF, &q)) {
            bad("QBUF(camera imported)");
            return 1;
        }
    }

    enc = open_encoder(codec, &got, encpath, sizeof encpath);
    printf("encoder: %s\n", encpath);

    opt_bufs = nbufs;
    if (!encoder_setup(enc, &g, got)) {
        printf("RESULT: the encoder will not take the geometry\n");
        return 1;
    }

    encoder_capture_bufs(enc, cap_map, cap_len);

    type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    if (ioctl(enc, VIDIOC_STREAMON, &type)) {
        bad("STREAMON(encoder OUTPUT)");
        return 1;
    }

    type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (ioctl(enc, VIDIOC_STREAMON, &type)) {
        bad("STREAMON(encoder CAPTURE)");
        return 1;
    }

    type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (ioctl(cam, VIDIOC_STREAMON, &type)) {
        bad("STREAMON(camera)");
        return 1;
    }

    for (int n = 0; n < opt_frames; n++) {
        struct v4l2_buffer b;
        struct v4l2_plane p[MAX_PLANES];
        struct v4l2_buffer d;
        struct v4l2_plane dp[MAX_PLANES];

        if (!wait_ready(cam, POLLIN, 2000, "camera frame")) {
            break;
        }

        memset(&b, 0, sizeof b);
        memset(p, 0, sizeof p);
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        b.memory = V4L2_MEMORY_DMABUF;
        b.m.planes = p;
        b.length = g.planes;
        if (ioctl(cam, VIDIOC_DQBUF, &b)) {
            bad("DQBUF(camera)");
            break;
        }

        if (encoder_queue(enc, &g, (int)b.index, fds[b.index])) {
            bad("QBUF(encoder OUTPUT)");
            break;
        }

        if (!wait_ready(enc, POLLOUT, 2000, "encoder OUTPUT reclaim")) {
            break;
        }

        memset(&d, 0, sizeof d);
        memset(dp, 0, sizeof dp);
        d.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
        d.memory = V4L2_MEMORY_DMABUF;
        d.m.planes = dp;
        d.length = g.planes;
        if (ioctl(enc, VIDIOC_DQBUF, &d)) {
            bad("DQBUF(encoder OUTPUT)");
            break;
        }

        for (unsigned int q = 0; q < g.planes; q++) {
            p[q].m.fd = fds[b.index][q];
            p[q].length = g.sizeimage[q];
        }

        if (ioctl(cam, VIDIOC_QBUF, &b)) {
            bad("re-QBUF(camera)");
            break;
        }

        total += encoder_reap(enc, cap_map, NULL, &coded);
    }

    type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    ioctl(cam, VIDIOC_STREAMOFF, &type);
    type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    ioctl(enc, VIDIOC_STREAMOFF, &type);
    type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    ioctl(enc, VIDIOC_STREAMOFF, &type);

    printf("%d coded frames, %lu bytes\n", coded, total);
    return total > 0 ? 0 : 1;
}

/** Export-only run. Nothing streams, so this costs no bring-up. */
static int run_export_only(void)
{
    struct geometry g;
    int fds[MAX_BUFS][MAX_PLANES];
    char path[64];
    int allocated = 0;
    int whole;
    int cam = open_camera(path, sizeof path);

    printf("camera node: %s\n", path);
    camera_geometry(cam, &g);

    whole = camera_export(cam, &g, opt_bufs, fds, &allocated);

    printf(whole == allocated && allocated > 0
           ? "RESULT: EXPBUF works on the no-map pool, %d of %d buffers exported whole\n"
           : "RESULT: EXPBUF is not usable here, %d of %d buffers exported whole\n",
           whole, allocated);
    return whole == allocated && allocated > 0 ? 0 : 1;
}

int main(int argc, char **argv)
{
    /* Line-buffered even into a file, so a backgrounded run's log is current. */
    setvbuf(stdout, NULL, _IOLBF, 0);

    /* No SA_RESTART: a pending stop has to break poll() out, not restart it. */
    {
        struct sigaction sa;

        memset(&sa, 0, sizeof sa);
        sa.sa_handler = on_stop_signal;
        sigaction(SIGINT, &sa, NULL);
        sigaction(SIGTERM, &sa, NULL);
    }

    int mode = 0;                              /* 0 joined, 1 export only, 2 encoder only */
    int c;

    while ((c = getopt(argc, argv, "xeskvVMn:b:o:c:H:g:w:D:N:phSG:m:R:")) != -1) {
        switch (c) {
        case 'x': {
            mode = 1;
        } break;

        case 'e': {
            mode = 2;
        } break;

        case 's': {
            opt_static = 1;
        } break;

        case 'k': {
            opt_hold = 1;
        } break;

        case 'v': {
            opt_verify = 1;
        } break;

        case 'V': {
            mode = 3;
            opt_verify = 1;
        } break;

        case 'M': {
            mode = 4;
        } break;

        case 'D': {
            opt_dump = optarg;
            mode = 3;
        } break;

        case 'N': {
            opt_dump_count = atoi(optarg);
        } break;

        case 'w': {
            opt_settle_us = (unsigned int)atoi(optarg) * 1000u;
        } break;

        case 'g': {
            if (sscanf(optarg, "%ux%u", &opt_width, &opt_height) != 2) {
                fprintf(stderr, "-g wants WIDTHxHEIGHT\n");
                return 2;
            }
        } break;

        case 'n': {
            opt_frames = atoi(optarg);
        } break;

        case 'b': {
            opt_bufs = atoi(optarg);
        } break;

        case 'o': {
            opt_out = optarg;
        } break;

        case 'c': {
            opt_codec = strcmp(optarg, "h264") == 0 ? V4L2_PIX_FMT_H264 : V4L2_PIX_FMT_HEVC;
        } break;

        case 'H': {
            opt_heap = optarg;
        } break;

        case 'p': {
            opt_probe = 1;
        } break;

        case 'S': {
            opt_no_streamoff = 1;
        } break;

        case 'G': {
            opt_gop = atoi(optarg);
        } break;

        case 'm': {
            opt_max_bytes = (unsigned long)atoi(optarg) << 20;
        } break;

        case 'R': {
            opt_bitrate = atoi(optarg);
        } break;

        default: {
            fprintf(stderr, "usage: ml-cam2enc [-x|-e] [-s|-k] [-n frames (0=until signal)] "
                            "[-b bufs] [-o file] [-c h264|hevc] [-H heap] [-G gop] [-m MB] "
                            "[-R bps (CBR; default constant-QP)] [-p] [-S]\n");
            return 2;
        } break;
        }
    }

    if (opt_bufs < 2 || opt_bufs > MAX_BUFS) {
        fprintf(stderr, "buffer count must be 2..%d\n", MAX_BUFS);
        return 2;
    }

    if (mode == 1) {
        return run_export_only();
    }

    if (mode == 2) {
        return run_encoder_only(opt_codec);
    }

    if (mode == 3) {
        return run_verify_only();
    }

    if (mode == 4) {
        return run_heap_bridge(opt_codec);
    }

    return run_joined(opt_codec);
}
