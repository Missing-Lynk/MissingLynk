/**
 * @file mlfile.c
 * @brief Shared file helpers for the standalone native tools (see mlfile.h).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>

#include "mlfile.h"

const char *ml_prog = "ml";

/* Device-tree model, exposed by the kernel under either mount point. */
static const char *const DT_MODEL_PATHS[] = {
    "/proc/device-tree/model",
    "/sys/firmware/devicetree/base/model",
    NULL,
};

char *ml_read_file(const char *path)
{
    FILE *fp = fopen(path, "rb");
    long len;
    char *buf;

    if (fp == NULL) {
        return NULL;
    }

    if (fseek(fp, 0, SEEK_END) != 0 || (len = ftell(fp)) < 0) {
        fclose(fp);
        return NULL;
    }

    rewind(fp);
    buf = malloc((size_t)len + 1);
    if (buf == NULL) {
        fclose(fp);
        return NULL;
    }

    if (fread(buf, 1, (size_t)len, fp) != (size_t)len) {
        free(buf);
        fclose(fp);
        return NULL;
    }

    fclose(fp);
    buf[len] = '\0';

    return buf;
}

/**
 * @brief fsync the directory containing @p path so a rename into it is durable. Best-effort.
 */
static void fsync_dir(const char *path)
{
    char dir[512];
    char *slash;
    int fd;

    if ((size_t)snprintf(dir, sizeof dir, "%s", path) >= sizeof dir) {
        return;
    }

    slash = strrchr(dir, '/');
    if (slash == NULL) {
        return;
    }

    /* keep the root slash if the file is directly under "/" */
    *(slash == dir ? slash + 1 : slash) = '\0';

    fd = open(dir, O_RDONLY | O_DIRECTORY);
    if (fd < 0) {
        return;
    }

    fsync(fd);
    close(fd);
}

int ml_write_file_atomic(const char *path, const char *data)
{
    char tmp[512];
    FILE *fp;
    int fd;
    size_t len = strlen(data);

    if ((size_t)snprintf(tmp, sizeof tmp, "%s.tmp", path) >= sizeof tmp) {
        return -1;
    }

    fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        fprintf(stderr, "%s: open %s: %s\n", ml_prog, tmp, strerror(errno));
        return -1;
    }

    fp = fdopen(fd, "wb");
    if (fp == NULL) {
        close(fd);
        unlink(tmp);
        return -1;
    }

    if (fwrite(data, 1, len, fp) != len || fflush(fp) != 0 || fsync(fileno(fp)) != 0) {
        fclose(fp);
        unlink(tmp);
        return -1;
    }

    fclose(fp);
    if (rename(tmp, path) != 0) {
        fprintf(stderr, "%s: rename %s: %s\n", ml_prog, path, strerror(errno));
        unlink(tmp);
        return -1;
    }

    /* fsync the containing directory so the rename is durable across a power loss - otherwise a
     * write reported as persisted could vanish on a cut right after the rename. */
    fsync_dir(path);

    return 0;
}

int ml_read_dt_model(char *out, size_t out_sz)
{
    for (int i = 0; DT_MODEL_PATHS[i]; i++) {
        char *text = ml_read_file(DT_MODEL_PATHS[i]);
        if (text == NULL) {
            continue;
        }

        snprintf(out, out_sz, "%s", text);
        free(text);
        return 0;
    }

    return -1;
}
