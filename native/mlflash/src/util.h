/**
 * @file util.h
 * @brief Small shared helpers for mlflash: file slurp, SHA-256, little-endian readers.
 */
#ifndef MLFLASH_UTIL_H
#define MLFLASH_UTIL_H

#include <stddef.h>
#include <stdint.h>

/**
 * @brief Read an entire file into a malloc'd buffer (caller frees).
 * @return the buffer with *out_len set, or NULL on error (message already printed).
 */
unsigned char *read_all(const char *path, size_t *out_len);

/** @brief Hex-encode the SHA-256 of `data` into `hex` (65 bytes incl. NUL). */
void sha256_hex(const unsigned char *data, size_t len, char hex[65]);

/** @brief Little-endian 32-bit read from a byte buffer. */
uint32_t rd32(const unsigned char *p);

/** @brief Little-endian 64-bit read from a byte buffer. */
uint64_t rd64(const unsigned char *p);

#endif
