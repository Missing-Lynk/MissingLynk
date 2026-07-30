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
 * Build: see build.sh (static, aarch64).
 * Use:   ml-v4l2grab [-d device] [-n frames] [-o file] [-t timeout_seconds]
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
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

/** Default number of frames to capture before stopping. */
#define DEFAULT_FRAME_COUNT 5

/** Default seconds to wait for a single frame before giving up. */
#define DEFAULT_TIMEOUT_SECONDS 5

/** One memory-mapped capture buffer. */
struct capture_buffer {
    void *start;
    size_t length;
};

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
 * @brief Print the formats and current geometry the device reports.
 *
 * @param fd open capture device.
 */
static void report_device(int fd)
{
    struct v4l2_capability capability;
    struct v4l2_fmtdesc description;
    struct v4l2_format format;
    unsigned int index;

    memset(&capability, 0, sizeof(capability));
    if (ioctl_retry(fd, VIDIOC_QUERYCAP, &capability) == 0) {
        printf("driver: %s  card: %s\n", capability.driver, capability.card);
    }

    for (index = 0;; index++) {
        memset(&description, 0, sizeof(description));
        description.index = index;
        description.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;

        if (ioctl_retry(fd, VIDIOC_ENUM_FMT, &description) != 0) {
            break;
        }

        printf("format %u: %c%c%c%c\n", index,
               (char)(description.pixelformat & 0xff),
               (char)((description.pixelformat >> 8) & 0xff),
               (char)((description.pixelformat >> 16) & 0xff),
               (char)((description.pixelformat >> 24) & 0xff));
    }

    memset(&format, 0, sizeof(format));
    format.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;

    if (ioctl_retry(fd, VIDIOC_G_FMT, &format) == 0) {
        printf("current: %ux%u, %u bytes per line, %u bytes per frame\n",
               format.fmt.pix.width, format.fmt.pix.height,
               format.fmt.pix.bytesperline, format.fmt.pix.sizeimage);
    }
}

/**
 * @brief Request and memory-map the capture buffers.
 *
 * @param fd          open capture device.
 * @param buffers     array of at least BUFFER_COUNT entries to fill.
 * @param count_out   receives the number of buffers actually mapped.
 *
 * @return 0 on success, 1 on failure.
 */
static int map_buffers(int fd, struct capture_buffer *buffers, unsigned int *count_out)
{
    struct v4l2_requestbuffers request;
    unsigned int index;

    memset(&request, 0, sizeof(request));
    request.count = BUFFER_COUNT;
    request.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    request.memory = V4L2_MEMORY_MMAP;

    if (ioctl_retry(fd, VIDIOC_REQBUFS, &request) != 0) {
        fprintf(stderr, "ml-v4l2grab: REQBUFS: %s\n", strerror(errno));
        return 1;
    }

    printf("allocated %u buffers\n", request.count);

    for (index = 0; index < request.count; index++) {
        struct v4l2_buffer buffer;

        memset(&buffer, 0, sizeof(buffer));
        buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buffer.memory = V4L2_MEMORY_MMAP;
        buffer.index = index;

        if (ioctl_retry(fd, VIDIOC_QUERYBUF, &buffer) != 0) {
            fprintf(stderr, "ml-v4l2grab: QUERYBUF %u: %s\n", index, strerror(errno));
            return 1;
        }

        buffers[index].length = buffer.length;
        buffers[index].start = mmap(NULL, buffer.length, PROT_READ | PROT_WRITE, MAP_SHARED,
                                    fd, buffer.m.offset);

        if (buffers[index].start == MAP_FAILED) {
            fprintf(stderr, "ml-v4l2grab: mmap %u: %s\n", index, strerror(errno));
            return 1;
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
 * @brief Capture frames and write the last one to a file.
 *
 * @param fd            open capture device.
 * @param buffers       mapped buffers.
 * @param buffer_count  number of mapped buffers.
 * @param frame_count   number of frames to capture.
 * @param timeout       seconds to wait for each frame.
 * @param path          destination file for the final frame.
 *
 * @return 0 on success, 1 on failure.
 */
static int capture_frames(int fd, struct capture_buffer *buffers, unsigned int buffer_count,
                          unsigned int frame_count, unsigned int timeout, const char *path)
{
    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    unsigned int index;
    unsigned int captured;
    int result = 1;

    for (index = 0; index < buffer_count; index++) {
        struct v4l2_buffer buffer;

        memset(&buffer, 0, sizeof(buffer));
        buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buffer.memory = V4L2_MEMORY_MMAP;
        buffer.index = index;

        if (ioctl_retry(fd, VIDIOC_QBUF, &buffer) != 0) {
            fprintf(stderr, "ml-v4l2grab: QBUF %u: %s\n", index, strerror(errno));
            return 1;
        }
    }

    printf("starting the stream\n");

    if (ioctl_retry(fd, VIDIOC_STREAMON, &type) != 0) {
        fprintf(stderr, "ml-v4l2grab: STREAMON: %s\n", strerror(errno));
        return 1;
    }

    for (captured = 0; captured < frame_count; captured++) {
        struct v4l2_buffer buffer;
        struct timeval wait;
        fd_set fds;
        int ready;

        FD_ZERO(&fds);
        FD_SET(fd, &fds);
        wait.tv_sec = timeout;
        wait.tv_usec = 0;

        ready = select(fd + 1, &fds, NULL, NULL, &wait);
        if (ready < 0) {
            fprintf(stderr, "ml-v4l2grab: select: %s\n", strerror(errno));
            goto done;
        }

        if (ready == 0) {
            fprintf(stderr,
                    "ml-v4l2grab: timed out after %u frames waiting for a buffer\n",
                    captured);
            goto done;
        }

        memset(&buffer, 0, sizeof(buffer));
        buffer.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buffer.memory = V4L2_MEMORY_MMAP;

        if (ioctl_retry(fd, VIDIOC_DQBUF, &buffer) != 0) {
            fprintf(stderr, "ml-v4l2grab: DQBUF: %s\n", strerror(errno));
            goto done;
        }

        printf("frame %u: buffer %u, sequence %u, %u bytes\n", captured, buffer.index,
               buffer.sequence, buffer.bytesused);

        /* Write the first frame as well as the last. Callers that stream continuously pass a
         * large -n and kill the process long before it is reached, so a last-frame-only write
         * leaves no file at all: the raw capture silently never happened.
         */
        if (captured == 0 || captured + 1 == frame_count) {
            FILE *output = fopen(path, "wb");

            report_frame_content(buffers[buffer.index].start, buffers[buffer.index].length);

            if (output == NULL) {
                fprintf(stderr, "ml-v4l2grab: open %s: %s\n", path, strerror(errno));
                goto done;
            }

            fwrite(buffers[buffer.index].start, 1, buffers[buffer.index].length, output);
            fclose(output);
            printf("wrote %zu bytes to %s\n", buffers[buffer.index].length, path);
        }

        if (ioctl_retry(fd, VIDIOC_QBUF, &buffer) != 0) {
            fprintf(stderr, "ml-v4l2grab: re-QBUF: %s\n", strerror(errno));
            goto done;
        }
    }

    result = 0;

done:
    ioctl_retry(fd, VIDIOC_STREAMOFF, &type);

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
    struct capture_buffer buffers[BUFFER_COUNT];
    unsigned int buffer_count = 0;
    int fd;
    int option;
    int result;

    while ((option = getopt(argc, argv, "d:n:o:t:")) != -1) {
        switch (option) {
        case 'd': {
            device = optarg;
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
                    "usage: ml-v4l2grab [-d device] [-n frames] [-o file] [-t seconds]\n");
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

    report_device(fd);

    if (map_buffers(fd, buffers, &buffer_count) != 0) {
        close(fd);
        return 1;
    }

    result = capture_frames(fd, buffers, buffer_count, frame_count, timeout, output);

    for (buffer_count = 0; buffer_count < BUFFER_COUNT; buffer_count++) {
        if (buffers[buffer_count].start != NULL &&
            buffers[buffer_count].start != MAP_FAILED) {
            munmap(buffers[buffer_count].start, buffers[buffer_count].length);
        }
    }

    close(fd);

    return result;
}
