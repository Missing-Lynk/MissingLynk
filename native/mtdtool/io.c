/*
 * mtdtool: byte movers. read()/write() may legally transfer less than asked for on any fd, so
 * every transfer in this tool goes through one of these rather than a single-shot call.
 */
#include "mtdtool.h"

/* read()/write() may legally move fewer bytes than asked for, on any fd. These loop until the
 * whole buffer has moved (or the transfer genuinely fails), so a short transfer is neither
 * mistaken for an error nor silently accepted as a complete one. EINTR is retried.
 */
int read_full(int fd, unsigned char *buf, size_t len)
{
    size_t done = 0;
    while (done < len) {
        ssize_t n = read(fd, buf + done, len - done);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }

            return -1;
        }

        if (n == 0) {
            /* EOF before the expected length: the caller asked for more than the target holds.
             */
            errno = EIO;
            return -1;
        }

        done += (size_t)n;
    }

    return 0;
}

int write_full(int fd, const unsigned char *buf, size_t len)
{
    size_t done = 0;
    while (done < len) {
        ssize_t n = write(fd, buf + done, len - done);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }

            return -1;
        }

        done += (size_t)n;
    }

    return 0;
}

unsigned char *read_all(const char *path, long *out_len)
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

/* Overwrite a plain-file target from the start. The non-MTD path of write/setslot, which exists
 * so the GPT edit can be verified offline against glue/flash/gpt_setactive.py.
 */
int write_plain_file(int fd, const unsigned char *buf, size_t len)
{
    if (lseek(fd, 0, SEEK_SET) != 0) {
        return -1;
    }

    return write_full(fd, buf, len);
}
