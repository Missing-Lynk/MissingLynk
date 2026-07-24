/**
 * @file mlfile.h
 * @brief Shared file helpers for the standalone native tools: whole-file read, atomic write,
 *        directory creation, and the device-tree model string.
 *
 * These were copied verbatim across ml-rf-persist, ml-boot-record, mlflash, fbtext and mlmenu;
 * they live here once. Set @ref ml_prog from main() so write errors are attributed to the tool.
 */
#ifndef ML_COMMON_MLFILE_H
#define ML_COMMON_MLFILE_H

#include <stddef.h>

/* The per-unit persistent volume every native tool writes its records under. */
#define ML_USR_DIR "/usrdata/missinglynk"

/* Program name used to prefix error messages; set once from main(). Defaults to "ml". */
extern const char *ml_prog;

/**
 * @brief Read a whole file into a malloc'd binary buffer (caller frees).
 * @param out_len set to the byte count on success; may be NULL if not wanted.
 * @return the buffer, or NULL if the file cannot be read or is empty.
 */
unsigned char *ml_read_file_bin(const char *path, size_t *out_len);

/**
 * @brief Read a whole file into a NUL-terminated malloc'd buffer (caller frees).
 * @return the buffer, or NULL if the file cannot be read or is empty.
 */
char *ml_read_file(const char *path);

/**
 * @brief Ensure directory @p path exists, creating it (mode 0755) if absent.
 * @return 0 if the directory exists or was created, -1 otherwise (message printed).
 */
int ml_ensure_dir(const char *path);

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
