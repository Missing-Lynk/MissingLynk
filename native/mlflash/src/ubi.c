/**
 * @file ubi.c
 * @brief userapp (rootfs) UBI write: feed the image to vendored mtd-utils ubiformat over a pipe.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <getopt.h>
#include <signal.h>
#include <sys/wait.h>
#include <zlib.h>

#include "ubi.h"

/* Inflate window size that selects gzip framing (header plus the CRC-32 and length trailer). */
#define ZLIB_GZIP_WINDOW (16 + MAX_WBITS)
#define INFLATE_CHUNK (256 * 1024)

/** @brief Write `len` bytes to `fd`, retrying partial writes. Returns 0, or -1 once the reader
 *         has closed the pipe. */
static int write_all(int fd, const unsigned char *data, size_t len)
{
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, data + off, len - off);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }

            return -1;
        }

        /* A zero-length write would leave the offset where it is; stop rather than spin. */
        if (n == 0) {
            return -1;
        }

        off += (size_t)n;
    }

    return 0;
}

/**
 * @brief Inflate the `len`-byte gzip stream in `data` into `fd`, a chunk at a time.
 *
 * Runs in the writer child, so the inflated image never exists as a whole anywhere: the peak
 * cost is one INFLATE_CHUNK buffer plus zlib's own window. ubiformat stopping early closes the
 * pipe, which surfaces as a write error and ends the stream; that is a clean stop, matching the
 * uncompressed path, so it is reported as success and the caller judges by ubiformat's exit.
 *
 * `out_len` is the length the manifest promises, and it bounds the loop: the stream is finished
 * once that many bytes have been written, and a member that would produce more is an error. That
 * makes the loop terminate on a counter rather than on zlib agreeing to stop, and it holds the
 * write to the size ubiformat was told to expect.
 */
static int inflate_to_fd(int fd, const unsigned char *data, size_t len, size_t out_len)
{
    z_stream zs;
    memset(&zs, 0, sizeof zs);

    if (inflateInit2(&zs, ZLIB_GZIP_WINDOW) != Z_OK) {
        fprintf(stderr, "ubi: inflateInit2 failed\n");
        return -1;
    }

    unsigned char *out = malloc(INFLATE_CHUNK);
    if (!out) {
        fprintf(stderr, "ubi: out of memory for the inflate buffer\n");
        inflateEnd(&zs);

        return -1;
    }

    zs.next_in = (unsigned char *)data;
    zs.avail_in = (unsigned int)len;

    int rc = 0;
    int stream_end = 0;
    int reader_gone = 0;
    size_t written = 0;
    while (written < out_len) {
        zs.next_out = out;
        zs.avail_out = INFLATE_CHUNK;
        unsigned int avail_in_before = zs.avail_in;

        int zrc = inflate(&zs, Z_NO_FLUSH);
        if (zrc != Z_OK && zrc != Z_STREAM_END && zrc != Z_BUF_ERROR) {
            fprintf(stderr, "ubi: rootfs inflate failed (%d)\n", zrc);
            rc = -1;
            break;
        }

        size_t have = INFLATE_CHUNK - zs.avail_out;
        if (have > out_len - written) {
            fprintf(stderr, "ubi: rootfs inflates past the %zu bytes the manifest declares\n",
                    out_len);
            rc = -1;
            break;
        }

        if (have && write_all(fd, out, have) != 0) {
            /* ubiformat stopped reading: a clean stop, the same as on the verbatim path. */
            reader_gone = 1;
            break;
        }

        written += have;

        if (zrc == Z_STREAM_END) {
            stream_end = 1;
            break;
        }

        /*
         * An iteration that neither consumed input nor produced output cannot be followed by one
         * that does, since the whole member is in front of zlib and the output buffer is emptied
         * every pass. Ending here covers every code inflate can return for a stalled stream.
         */
        if (!have && zs.avail_in == avail_in_before) {
            fprintf(stderr, "ubi: rootfs gzip stream is truncated\n");
            rc = -1;
            break;
        }
    }

    /*
     * ubiformat was told to expect exactly out_len bytes, so anything short of that is a failure
     * even though zlib ended the stream happily: the member does not hold the payload the manifest
     * describes. Only a reader that stopped early is exempt, which is the same clean stop the
     * verbatim path takes.
     */
    if (rc == 0 && !reader_gone) {
        if (written != out_len) {
            fprintf(stderr, "ubi: rootfs inflated to %zu bytes, not the %zu the manifest "
                    "declares\n", written, out_len);
            rc = -1;
        } else if (!stream_end) {
            /*
             * The declared length was reached without zlib ending the stream, so the gzip CRC-32
             * and length trailer have not been checked yet. One more pass over a fresh output
             * window: ending there with nothing left to emit is the good case, and anything else
             * means the member carries more than it declares or stops short of its trailer.
             */
            zs.next_out = out;
            zs.avail_out = INFLATE_CHUNK;

            int zrc = inflate(&zs, Z_NO_FLUSH);
            if (zrc != Z_STREAM_END || zs.avail_out != INFLATE_CHUNK) {
                fprintf(stderr, "ubi: rootfs gzip stream does not end at its declared length\n");
                rc = -1;
            }
        }
    }

    free(out);
    inflateEnd(&zs);

    return rc;
}

/* ubiformat.c's main(), renamed at compile time (-Dmain=ubiformat_main in native/build.sh) so
 * the whole vendored tool links in as a callable function instead of a second entry point.
 * It parses into a file-scope struct that is not fully re-zeroed per call, so this is sound only
 * because an .mlimg carries a single ubiformat component (the userapp rootfs) - one call per run.
 */
extern int ubiformat_main(int argc, char *const argv[]);

int ubi_write(const char *dev_path, const unsigned char *data, size_t len, size_t out_len,
              int gzipped)
{
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        perror("pipe");
        return -1;
    }

    pid_t child = fork();
    if (child < 0) {
        perror("fork");
        close(pipefd[0]);
        close(pipefd[1]);
        return -1;
    }

    if (child == 0) {
        /* Writer: stream the image into the pipe that ubiformat reads as stdin. A short read on
         * ubiformat's side (it stops at img_ebs) closes the pipe; treat EPIPE as a clean stop.
         */
        signal(SIGPIPE, SIG_IGN);
        close(pipefd[0]);

        int wr = gzipped ? inflate_to_fd(pipefd[1], data, len, out_len)
                         : write_all(pipefd[1], data, len);

        close(pipefd[1]);
        _exit(wr == 0 ? 0 : 1);
    }

    /* Parent: point ubiformat's stdin at the pipe, run it, then restore our own stdin. */
    close(pipefd[1]);

    int saved_stdin = dup(STDIN_FILENO);
    if (saved_stdin < 0 || dup2(pipefd[0], STDIN_FILENO) < 0) {
        perror("dup2");
        close(pipefd[0]);
        if (saved_stdin >= 0) {
            close(saved_stdin);
        }
        waitpid(child, NULL, 0);

        return -1;
    }

    close(pipefd[0]);

    char size_arg[32];
    snprintf(size_arg, sizeof size_arg, "%zu", out_len);
    char *argv[] = {
        "ubiformat", (char *)dev_path, "-f", "-", "-S", size_arg, "-y", NULL,
    };
    int argc = (int)(sizeof argv / sizeof argv[0]) - 1;

    optind = 1;
    int rc = ubiformat_main(argc, argv);

    dup2(saved_stdin, STDIN_FILENO);
    close(saved_stdin);

    /*
     * The writer exits non-zero only when the stream itself went wrong (a corrupt or truncated
     * gzip member), which ubiformat sees as a short image. Report it, because that diagnosis is
     * in the child and ubiformat's own message would only say the image ended early.
     */
    int status = 0;
    waitpid(child, &status, 0);
    if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
        return -1;
    }

    return rc == 0 ? 0 : -1;
}
