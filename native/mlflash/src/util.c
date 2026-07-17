/**
 * @file util.c
 * @brief mlflash shared helpers: file slurp/map, SHA-256 (OpenSSL libcrypto), byte readers.
 */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <openssl/sha.h>

#include "util.h"

unsigned char *read_all(const char *path, size_t *out_len)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        return NULL;
    }

    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len <= 0) {
        fprintf(stderr, "%s: empty or unreadable\n", path);
        fclose(f);

        return NULL;
    }

    unsigned char *buf = malloc((size_t)len);
    if (!buf || fread(buf, 1, (size_t)len, f) != (size_t)len) {
        fprintf(stderr, "%s: read failed\n", path);
        free(buf);
        fclose(f);

        return NULL;
    }

    fclose(f);
    *out_len = (size_t)len;
    return buf;
}

unsigned char *map_file(const char *path, size_t *out_len)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        perror(path);
        return NULL;
    }

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        fprintf(stderr, "%s: empty or unreadable\n", path);
        close(fd);
        return NULL;
    }

    /* Read-only map: the pages fault in from the file and are reclaimable, so a large image
     * costs almost no anonymous RAM (matters on-device where the running stack is memory-tight).
     */
    void *p = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (p == MAP_FAILED) {
        perror("mmap");
        return NULL;
    }

    *out_len = (size_t)st.st_size;
    return (unsigned char *)p;
}

void unmap_file(unsigned char *p, size_t len)
{
    if (p) {
        munmap(p, len);
    }
}

void sha256_hex(const unsigned char *data, size_t len, char hex[65])
{
    unsigned char digest[SHA256_DIGEST_LENGTH];
    SHA256(data, len, digest);
    for (int i = 0; i < SHA256_DIGEST_LENGTH; i++) {
        sprintf(hex + i * 2, "%02x", digest[i]);
    }
    hex[SHA256_DIGEST_LENGTH * 2] = 0;
}

uint32_t rd32(const unsigned char *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

uint64_t rd64(const unsigned char *p)
{
    return (uint64_t)rd32(p) | (uint64_t)rd32(p + 4) << 32;
}

void wr32(unsigned char *p, uint32_t value)
{
    p[0] = (unsigned char)value;
    p[1] = (unsigned char)(value >> 8);
    p[2] = (unsigned char)(value >> 16);
    p[3] = (unsigned char)(value >> 24);
}

void wr64(unsigned char *p, uint64_t value)
{
    wr32(p, (uint32_t)value);
    wr32(p + 4, (uint32_t)(value >> 32));
}
