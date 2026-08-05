/**
 * @file ml-v4l2grab.c
 * @brief Capture frames from a V4L2 capture device and write them to a file.
 *
 * A minimal grabber for camera bring-up: it reports what the device offers, captures a
 * requested number of frames using memory-mapped buffers, and writes the last one out. It
 * exists because the device rootfs carries no v4l2 utilities, and because a bring-up tool
 * should print enough about each step to show where a capture stops.
 *
 * The captured data is whatever the device produces, with no conversion. For a raw Bayer
 * sensor that is unprocessed sensor data, which is debayered on a host.
 *
 * Single-planar and multiplanar devices are both handled; which one is used is decided from
 * the device's own capabilities rather than a flag, so a caller does not have to know. A
 * single-planar frame is written to the output path as it is. A multiplanar frame is written
 * one file per plane, <path>.0, <path>.1 and so on, which is the layout glue/camera/planes2png.py
 * already renders because ml-isploop's --dump writes the same shape.
 *
 * Build: see build.sh (static, aarch64).
 * Use:   ml-v4l2grab [-d device] [-n frames] [-o file] [-t timeout_seconds]
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <unistd.h>

#include <linux/videodev2.h>

/** Number of buffers to request from the driver. */
#define BUFFER_COUNT 4

/**
 * Capacity of the buffer array.
 *
 * A driver may hand back MORE buffers than were asked for: vb2 raises the count to
 * min_queued_buffers + 1, and on the CVISP node that minimum tracks the capture depth. Asking
 * for BUFFER_COUNT and indexing the array by the returned count is how this tool wrote past the
 * end of a stack array and then queued a buffer it had never mapped.
 */
#define MAX_BUFFERS 8

/** Default number of frames to capture before stopping. */
#define DEFAULT_FRAME_COUNT 5

/** Default seconds to wait for a single frame before giving up. */
#define DEFAULT_TIMEOUT_SECONDS 5

/** Most planes any format handled here uses: Y, U and V. */
#define MAX_PLANES 3

/** One memory-mapped plane. */
struct capture_plane {
    void *start;
    size_t length;
};

/** One memory-mapped capture buffer, single-planar being the one-plane case. */
struct capture_buffer {
    struct capture_plane plane[MAX_PLANES];
    unsigned int planes;
};

/** Which of the two V4L2 capture interfaces the open device speaks. */
struct capture_device {
    int fd;
    enum v4l2_buf_type type;
    int multiplanar;
    int mark;
    int quiet;
    unsigned int stride[MAX_PLANES];
};

/**
 * @brief Monotonic seconds, for rate reporting.
 *
 * @return seconds since an unspecified epoch.
 */
static double now_seconds(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);

    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/**
 * @brief Fill a plane with a position-keyed pattern.
 *
 * Written before the buffer is queued, so anything the hardware did not write is still
 * recognisable afterwards. Keyed to the offset rather than a constant byte: every constant
 * byte value also occurs in image data, so a run of 0x00 or 0xff in a dark or blown-out frame
 * would read as not written.
 *
 * @param plane mapped plane to fill.
 */
static void mark_plane(struct capture_plane *plane)
{
    uint32_t *words = (uint32_t *)plane->start;
    size_t count = plane->length / sizeof(uint32_t);
    size_t index;

    for (index = 0; index < count; index++) {
        words[index] = (uint32_t)index ^ 0xa5a5a5a5u;
    }
}

/**
 * @brief Report how much of a marked plane the hardware actually overwrote.
 *
 * Decides two things: how many rows the block writes, and so whether a driver's plane extents
 * are geometry or padding, and whether a completed buffer is finished, and so whether its hold
 * depth is long enough. A fully written plane reports its last row as the last row it has.
 *
 * @param plane  mapped plane to examine.
 * @param stride bytes per row, for reporting the result in rows.
 * @param label  plane name for the printout.
 */
static void report_plane_coverage(const struct capture_plane *plane, unsigned int stride,
                                  const char *label)
{
    const uint32_t *words = (const uint32_t *)plane->start;
    size_t count = plane->length / sizeof(uint32_t);
    size_t written = 0;
    size_t last = 0;
    size_t index;
    int found = 0;

    for (index = 0; index < count; index++) {
        if (words[index] != ((uint32_t)index ^ 0xa5a5a5a5u)) {
            written++;
            last = index;
            found = 1;
        }
    }

    if (!found) {
        printf("  %s: NOTHING written, the whole plane still holds the marker\n", label);
        return;
    }

    printf("  %s: %zu of %zu words written, last at byte %zu", label, written, count,
           last * sizeof(uint32_t));

    if (stride != 0) {
        printf(", row %zu of %zu", (last * sizeof(uint32_t)) / stride,
               plane->length / stride);
    }

    printf("\n");
}

/**
 * @brief Repeat an ioctl while it is interrupted by a signal.
 *
 * @param fd      open file descriptor.
 * @param request ioctl request code.
 * @param argument ioctl argument.
 *
 * @return 0 on success, -1 on failure with errno set.
 */
static int ioctl_retry(int fd, unsigned long request, void *argument)
{
    int result;

    do {
        result = ioctl(fd, request, argument);
    } while (result == -1 && errno == EINTR);

    return result;
}

/**
 * @brief Decide which capture interface the device speaks, and print what it offers.
 *
 * The choice comes from the reported capabilities rather than a command-line flag: a caller
 * bringing a new node up should not have to know, and getting it wrong fails at REQBUFS with
 * an EINVAL that says nothing about why.
 *
 * @param device receives the open descriptor and the buffer type to use.
 */
static void report_device(struct capture_device *device)
{
    struct v4l2_capability capability;
    struct v4l2_fmtdesc description;
    struct v4l2_format format;
    unsigned int capabilities;
    unsigned int index;

    memset(&capability, 0, sizeof(capability));
    if (ioctl_retry(device->fd, VIDIOC_QUERYCAP, &capability) == 0) {
        capabilities = (capability.capabilities & V4L2_CAP_DEVICE_CAPS)
                           ? capability.device_caps
                           : capability.capabilities;

        device->multiplanar = (capabilities & V4L2_CAP_VIDEO_CAPTURE_MPLANE) ? 1 : 0;

        printf("driver: %s  card: %s  interface: %s\n", capability.driver, capability.card,
               device->multiplanar ? "multiplanar" : "single-planar");
    }

    device->type = device->multiplanar ? V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE
                                       : V4L2_BUF_TYPE_VIDEO_CAPTURE;

    for (index = 0;; index++) {
        memset(&description, 0, sizeof(description));
        description.index = index;
        description.type = device->type;

        if (ioctl_retry(device->fd, VIDIOC_ENUM_FMT, &description) != 0) {
            break;
        }

        printf("format %u: %c%c%c%c\n", index,
               (char)(description.pixelformat & 0xff),
               (char)((description.pixelformat >> 8) & 0xff),
               (char)((description.pixelformat >> 16) & 0xff),
               (char)((description.pixelformat >> 24) & 0xff));
    }

    memset(&format, 0, sizeof(format));
    format.type = device->type;

    if (ioctl_retry(device->fd, VIDIOC_G_FMT, &format) != 0) {
        return;
    }

    if (device->multiplanar) {
        printf("current: %ux%u, %u planes\n", format.fmt.pix_mp.width,
               format.fmt.pix_mp.height, format.fmt.pix_mp.num_planes);

        for (index = 0; index < format.fmt.pix_mp.num_planes && index < MAX_PLANES;
             index++) {
            device->stride[index] = format.fmt.pix_mp.plane_fmt[index].bytesperline;

            printf("  plane %u: %u bytes per line, %u bytes\n", index,
                   format.fmt.pix_mp.plane_fmt[index].bytesperline,
                   format.fmt.pix_mp.plane_fmt[index].sizeimage);
        }
    } else {
        device->stride[0] = format.fmt.pix.bytesperline;

        printf("current: %ux%u, %u bytes per line, %u bytes per frame\n",
               format.fmt.pix.width, format.fmt.pix.height, format.fmt.pix.bytesperline,
               format.fmt.pix.sizeimage);
    }
}

/**
 * @brief Map one plane of one buffer.
 *
 * @param fd     open capture device.
 * @param plane  entry to fill.
 * @param length plane length in bytes.
 * @param offset mmap cookie the driver returned.
 *
 * @return 0 on success, 1 on failure.
 */
static int map_plane(int fd, struct capture_plane *plane, size_t length, off_t offset)
{
    plane->length = length;
    plane->start = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, offset);

    if (plane->start == MAP_FAILED) {
        fprintf(stderr, "ml-v4l2grab: mmap: %s\n", strerror(errno));
        return 1;
    }

    return 0;
}

/**
 * @brief Request and memory-map the capture buffers.
 *
 * @param device      open capture device.
 * @param buffers     array of at least BUFFER_COUNT entries to fill.
 * @param count_out   receives the number of buffers actually mapped.
 *
 * @return 0 on success, 1 on failure.
 */
static int map_buffers(const struct capture_device *device, struct capture_buffer *buffers,
                       unsigned int *count_out)
{
    struct v4l2_requestbuffers request;
    unsigned int index;

    memset(&request, 0, sizeof(request));
    request.count = BUFFER_COUNT;
    request.type = device->type;
    request.memory = V4L2_MEMORY_MMAP;

    if (ioctl_retry(device->fd, VIDIOC_REQBUFS, &request) != 0) {
        fprintf(stderr, "ml-v4l2grab: REQBUFS: %s\n", strerror(errno));
        return 1;
    }

    printf("allocated %u buffers\n", request.count);

    if (request.count > MAX_BUFFERS) {
        fprintf(stderr, "ml-v4l2grab: driver returned %u buffers, this tool holds %u\n",
                request.count, MAX_BUFFERS);
        return 1;
    }

    for (index = 0; index < request.count; index++) {
        struct v4l2_plane planes[MAX_PLANES];
        struct v4l2_buffer buffer;
        unsigned int p;

        memset(planes, 0, sizeof(planes));
        memset(&buffer, 0, sizeof(buffer));
        buffer.type = device->type;
        buffer.memory = V4L2_MEMORY_MMAP;
        buffer.index = index;

        if (device->multiplanar) {
            buffer.m.planes = planes;
            buffer.length = MAX_PLANES;
        }

        if (ioctl_retry(device->fd, VIDIOC_QUERYBUF, &buffer) != 0) {
            fprintf(stderr, "ml-v4l2grab: QUERYBUF %u: %s\n", index, strerror(errno));
            return 1;
        }

        if (!device->multiplanar) {
            buffers[index].planes = 1;

            if (map_plane(device->fd, &buffers[index].plane[0], buffer.length,
                          (off_t)buffer.m.offset) != 0) {
                return 1;
            }

            continue;
        }

        if (buffer.length > MAX_PLANES) {
            fprintf(stderr, "ml-v4l2grab: %u planes, only %u handled\n", buffer.length,
                    MAX_PLANES);
            return 1;
        }

        buffers[index].planes = buffer.length;

        for (p = 0; p < buffer.length; p++) {
            if (map_plane(device->fd, &buffers[index].plane[p], planes[p].length,
                          (off_t)planes[p].m.mem_offset) != 0) {
                return 1;
            }
        }
    }

    *count_out = request.count;

    return 0;
}

/**
 * @brief Summarise a frame's content so an obviously blank capture is visible immediately.
 *
 * @param data   frame data.
 * @param length number of bytes to examine.
 */
static void report_frame_content(const uint8_t *data, size_t length)
{
    size_t histogram[256];
    size_t distinct = 0;
    size_t nonzero = 0;
    size_t index;

    memset(histogram, 0, sizeof(histogram));

    for (index = 0; index < length; index++) {
        histogram[data[index]]++;

        if (data[index] != 0) {
            nonzero++;
        }
    }

    for (index = 0; index < 256; index++) {
        if (histogram[index] != 0) {
            distinct++;
        }
    }

    printf("  content: %zu distinct byte values, %.1f%% non-zero\n", distinct,
           100.0 * (double)nonzero / (double)length);

    if (distinct < 4) {
        printf("  the frame is flat: the capture ran but no image data arrived\n");
    }
}

/**
 * @brief Write one captured buffer out.
 *
 * A single-planar frame goes to @p path unchanged, so existing callers see no difference. A
 * multiplanar frame goes to <path>.0, <path>.1 and so on, which is what ml-isploop --dump
 * writes and what glue/camera/planes2png.py renders.
 *
 * @param buffer mapped buffer to write.
 * @param path   destination, or its stem for a multiplanar frame.
 *
 * @return 0 on success, 1 on failure.
 */
static int write_buffer(const struct capture_buffer *buffer, const char *path)
{
    unsigned int p;

    for (p = 0; p < buffer->planes; p++) {
        char plane_path[512];
        FILE *output;

        if (buffer->planes == 1) {
            snprintf(plane_path, sizeof(plane_path), "%s", path);
        } else {
            snprintf(plane_path, sizeof(plane_path), "%s.%u", path, p);
        }

        report_frame_content(buffer->plane[p].start, buffer->plane[p].length);

        output = fopen(plane_path, "wb");
        if (output == NULL) {
            fprintf(stderr, "ml-v4l2grab: open %s: %s\n", plane_path, strerror(errno));
            return 1;
        }

        fwrite(buffer->plane[p].start, 1, buffer->plane[p].length, output);
        fclose(output);
        printf("wrote %zu bytes to %s\n", buffer->plane[p].length, plane_path);
    }

    return 0;
}

/**
 * @brief Capture frames and write the first and last ones to a file.
 *
 * @param device        open capture device.
 * @param buffers       mapped buffers.
 * @param buffer_count  number of mapped buffers.
 * @param frame_count   number of frames to capture.
 * @param timeout       seconds to wait for each frame.
 * @param path          destination file for the frames written.
 *
 * @return 0 on success, 1 on failure.
 */
static int capture_frames(const struct capture_device *device, struct capture_buffer *buffers,
                          unsigned int buffer_count, unsigned int frame_count,
                          unsigned int timeout, const char *path)
{
    enum v4l2_buf_type type = device->type;
    unsigned int index;
    unsigned int captured;
    double started;
    double elapsed;
    int result = 1;

    for (index = 0; index < buffer_count; index++) {
        struct v4l2_plane planes[MAX_PLANES];
        struct v4l2_buffer buffer;

        memset(planes, 0, sizeof(planes));
        memset(&buffer, 0, sizeof(buffer));
        buffer.type = device->type;
        buffer.memory = V4L2_MEMORY_MMAP;
        buffer.index = index;

        if (device->multiplanar) {
            buffer.m.planes = planes;
            buffer.length = buffers[index].planes;
        }

        if (device->mark) {
            unsigned int p;

            for (p = 0; p < buffers[index].planes; p++) {
                mark_plane(&buffers[index].plane[p]);
            }
        }

        if (ioctl_retry(device->fd, VIDIOC_QBUF, &buffer) != 0) {
            fprintf(stderr, "ml-v4l2grab: QBUF %u: %s\n", index, strerror(errno));
            return 1;
        }
    }

    printf("starting the stream\n");

    if (ioctl_retry(device->fd, VIDIOC_STREAMON, &type) != 0) {
        fprintf(stderr, "ml-v4l2grab: STREAMON: %s\n", strerror(errno));
        return 1;
    }

    started = now_seconds();

    for (captured = 0; captured < frame_count; captured++) {
        struct v4l2_plane planes[MAX_PLANES];
        struct v4l2_buffer buffer;
        struct timeval wait;
        fd_set fds;
        int ready;

        FD_ZERO(&fds);
        FD_SET(device->fd, &fds);
        wait.tv_sec = timeout;
        wait.tv_usec = 0;

        ready = select(device->fd + 1, &fds, NULL, NULL, &wait);
        if (ready < 0) {
            fprintf(stderr, "ml-v4l2grab: select: %s\n", strerror(errno));
            break;
        }

        if (ready == 0) {
            fprintf(stderr,
                    "ml-v4l2grab: timed out after %u frames waiting for a buffer\n",
                    captured);
            break;
        }

        memset(planes, 0, sizeof(planes));
        memset(&buffer, 0, sizeof(buffer));
        buffer.type = device->type;
        buffer.memory = V4L2_MEMORY_MMAP;

        if (device->multiplanar) {
            buffer.m.planes = planes;
            buffer.length = MAX_PLANES;
        }

        if (ioctl_retry(device->fd, VIDIOC_DQBUF, &buffer) != 0) {
            fprintf(stderr, "ml-v4l2grab: DQBUF: %s\n", strerror(errno));
            break;
        }

        if (!device->quiet) {
            printf("frame %u: buffer %u, sequence %u\n", captured, buffer.index,
                   buffer.sequence);
        }

        /* Write the first frame as well as the last. Callers that stream continuously pass a
         * large -n and kill the process long before it is reached, so a last-frame-only write
         * leaves no file at all: the raw capture silently never happened.
         */
        if (!device->quiet && (captured == 0 || captured + 1 == frame_count)) {
            if (device->mark) {
                unsigned int p;

                for (p = 0; p < buffers[buffer.index].planes; p++) {
                    char label[32];

                    snprintf(label, sizeof(label), "plane %u coverage", p);
                    report_plane_coverage(&buffers[buffer.index].plane[p],
                                          device->stride[p], label);
                }
            }

            if (write_buffer(&buffers[buffer.index], path) != 0) {
                break;
            }
        }

        if (device->mark) {
            unsigned int p;

            for (p = 0; p < buffers[buffer.index].planes; p++) {
                mark_plane(&buffers[buffer.index].plane[p]);
            }
        }

        if (ioctl_retry(device->fd, VIDIOC_QBUF, &buffer) != 0) {
            fprintf(stderr, "ml-v4l2grab: re-QBUF: %s\n", strerror(errno));
            break;
        }
    }

    /*
     * Only a loop that ran to completion is a success. Every early exit above has already
     * said why it stopped, and each leaves captured short of frame_count.
     */
    if (captured == frame_count) {
        result = 0;
    }

    elapsed = now_seconds() - started;

    if (elapsed > 0.0) {
        printf("delivered %u frames in %.3f s, %.1f per second\n", captured, elapsed,
               (double)captured / elapsed);
    }

    ioctl_retry(device->fd, VIDIOC_STREAMOFF, &type);

    return result;
}

/**
 * @brief Entry point: parse arguments, open the device and capture.
 */
int main(int argc, char **argv)
{
    const char *device = "/dev/video0";
    const char *output = "/tmp/frame.raw";
    unsigned int frame_count = DEFAULT_FRAME_COUNT;
    unsigned int timeout = DEFAULT_TIMEOUT_SECONDS;
    struct capture_buffer buffers[MAX_BUFFERS];
    struct capture_device device_state;
    unsigned int buffer_count = 0;
    unsigned int plane;
    int fd;
    int option;
    int result;

    memset(&device_state, 0, sizeof(device_state));

    while ((option = getopt(argc, argv, "d:mn:o:qt:")) != -1) {
        switch (option) {
        case 'd': {
            device = optarg;
        } break;

        case 'm': {
            device_state.mark = 1;
        } break;

        case 'q': {
            device_state.quiet = 1;
        } break;

        case 'n': {
            frame_count = (unsigned int)strtoul(optarg, NULL, 0);
        } break;

        case 'o': {
            output = optarg;
        } break;

        case 't': {
            timeout = (unsigned int)strtoul(optarg, NULL, 0);
        } break;

        default: {
            fprintf(stderr,
                    "usage: ml-v4l2grab [-d device] [-m] [-q] [-n frames] [-o file] "
                    "[-t seconds]\n"
                    "  -m  fill each buffer with a marker before queueing it and report\n"
                    "      how much of it the hardware overwrote. Diagnostic: the fill\n"
                    "      and the scan cost more than a frame period, so the capture\n"
                    "      will drop frames.\n"
                    "  -q  cycle buffers without reading or writing their contents, and\n"
                    "      report the delivered frame rate. Capture buffers can be\n"
                    "      uncached, in which case a CPU pass over a plane costs far more\n"
                    "      than a frame period; this separates that cost from the rate\n"
                    "      the device can sustain.\n");
            return 2;
        } break;
        }
    }

    memset(buffers, 0, sizeof(buffers));

    fd = open(device, O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "ml-v4l2grab: open %s: %s\n", device, strerror(errno));
        return 1;
    }

    device_state.fd = fd;
    device_state.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;

    report_device(&device_state);

    if (map_buffers(&device_state, buffers, &buffer_count) != 0) {
        close(fd);
        return 1;
    }

    result = capture_frames(&device_state, buffers, buffer_count, frame_count, timeout,
                            output);

    for (buffer_count = 0; buffer_count < MAX_BUFFERS; buffer_count++) {
        for (plane = 0; plane < MAX_PLANES; plane++) {
            struct capture_plane *mapped = &buffers[buffer_count].plane[plane];

            if (mapped->start != NULL && mapped->start != MAP_FAILED) {
                munmap(mapped->start, mapped->length);
            }
        }
    }

    close(fd);

    return result;
}
