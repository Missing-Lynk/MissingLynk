/**
 * @file util.h
 * @brief Small shared helpers for mlflash: file slurp, SHA-256, little-endian readers.
 */
#ifndef MLFLASH_UTIL_H
#define MLFLASH_UTIL_H

#include <stddef.h>
#include <stdint.h>

/**
 * @brief Read an entire file into a malloc'd buffer (caller frees). For small files.
 * @return the buffer with *out_len set, or NULL on error (message already printed).
 */
unsigned char *read_all(const char *path, size_t *out_len);

/**
 * @brief Memory-map a file read-only (caller unmaps with unmap_file). For large files (the image)
 *        where a heap copy would waste RAM the device does not have.
 * @return the mapping with *out_len set, or NULL on error (message already printed).
 */
unsigned char *map_file(const char *path, size_t *out_len);

/** @brief Release a mapping from map_file. */
void unmap_file(unsigned char *p, size_t len);

/** @brief Hex-encode the SHA-256 of `data` into `hex` (65 bytes incl. NUL). */
void sha256_hex(const unsigned char *data, size_t len, char hex[65]);

/** @brief Little-endian 32-bit read from a byte buffer. */
uint32_t rd32(const unsigned char *p);

/** @brief Little-endian 64-bit read from a byte buffer. */
uint64_t rd64(const unsigned char *p);

/** @brief Little-endian 32-bit write into a byte buffer. */
void wr32(unsigned char *p, uint32_t value);

/** @brief Little-endian 64-bit write into a byte buffer. */
void wr64(unsigned char *p, uint64_t value);

#endif
