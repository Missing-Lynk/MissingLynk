/**
 * @file util.c
 * @brief mlflash shared helpers: file slurp, SHA-256 (OpenSSL libcrypto), byte readers.
 */
#include <stdio.h>
#include <stdlib.h>
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
