/**
 * @file mlfile.h
 * @brief Shared file helpers for the standalone native tools: whole-file read, atomic write, and
 *        the device-tree model string.
 *
 * These were copied verbatim across ml-rf-persist, ml-boot-record, and mlflash's device_record;
 * they live here once. Set @ref ml_prog from main() so write errors are attributed to the tool.
 */
#ifndef ML_COMMON_MLFILE_H
#define ML_COMMON_MLFILE_H

#include <stddef.h>

/* Program name used to prefix error messages; set once from main(). Defaults to "ml". */
extern const char *ml_prog;

/**
 * @brief Read a whole file into a NUL-terminated malloc'd buffer (caller frees).
 * @return the buffer, or NULL if the file cannot be read.
 */
char *ml_read_file(const char *path);

/**
 * @brief Write @p data to @p path atomically (temp file, fsync, rename, fsync dir).
 * @return 0 on success, -1 otherwise.
 */
int ml_write_file_atomic(const char *path, const char *data);

/**
 * @brief Read the NUL-terminated device-tree model string into @p out.
 * @return 0 on success, -1 if no model node is present.
 */
int ml_read_dt_model(char *out, size_t out_sz);

#endif
