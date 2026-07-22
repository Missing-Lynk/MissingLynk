/**
 * @file ml-rf-persist.c
 * @brief Persist a newly-paired air-unit MAC into the AR8030 candidate list.
 *
 * ml-linkd runs the RF pair sequence and locks the peer into the chip at runtime (bb_ioctl
 * 0x02000004). That lock does not survive a power cycle: the chip re-reads its config from the
 * blob artosyn_sdio uploads at insmod. This tool writes the peer MAC into that config's
 * `baseband.basic.ap.candidate.slot` array so the binding persists across reboots.
 *
 * The rootfs bakes the config into /lib/firmware (read-only by policy, and overwritten on a
 * reflash), so the edited copy lives under /usrdata (a persistent, slot-independent volume). The
 * boot service exports ML_RF_FW_PATH=/usrdata/missinglynk, which ml-rf-bringup writes to the
 * kernel firmware search path: the driver then loads the edited config when present and falls back
 * to the baked one otherwise. Both band variants (race + normal) are edited, since a binding is
 * band-independent; each is seeded from its baked /lib/firmware copy on first use.
 *
 * The array edit reproduces the vendor writer AR_AR8030_RxUpdateApDataCjson byte-faithfully:
 * force the array to exactly 5 entries (append ascending dummy fills, delete from the head if
 * long), string-compare all 5 for the MAC, and only if absent shift toward the head
 * (slot[i] = slot[i+1]) and write the MAC at slot[4] (newest; slot[0] is oldest, evicted when
 * full). Re-binding a MAC already in the list is therefore a no-op: no duplicate can appear.
 *
 * LIMITATION: at most SLOT_COUNT (5) bound air units can be remembered; a 6th bind FIFO-evicts the
 * oldest. This is the vendor's hardcoded array size, kept byte-faithful because the baseband
 * firmware is presumed to expect exactly 5 (an untested array length could be truncated/rejected at
 * insmod). Raising it needs a HW/RE check of what lengths the firmware accepts - see
 * plans/rf-binding.md "Future: more than 5 remembered bindings". (This is a remembered-bindings cap,
 * not a simultaneous-link cap: the goggle connects to one air unit at a time regardless.)
 *
 * Usage: ml-rf-persist <mac>   where <mac> is 8 lowercase hex digits (e.g. e515815c).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>

#include "vendor/cJSON.h"

#define PROG        "ml-rf-persist"
#define FW_DIR      "/lib/firmware"
#define USR_DIR     "/usrdata/missinglynk"
#define SLOT_COUNT  5   /* vendor-hardcoded candidate-list size; max remembered bindings (see file header) */

/* The two band-variant config filenames, matching etc/init.d/ml-video (RF_CFG_RACE / RF_CFG_NORMAL).
 * Both carry the same candidate list; a bind edits both so either band picks it up next boot. */
static const char *const CFG_FILES[] = {
    "bb_config_gnd.json.usr_cfg.json",
    "bb_config_gnd.json.normal_cfg.json",
};

/**
 * @brief Read a whole file into a NUL-terminated malloc'd buffer.
 * @return the buffer (caller frees), or NULL if the file cannot be read.
 */
static char *read_file(const char *path)
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

    if ((size_t) snprintf(dir, sizeof dir, "%s", path) >= sizeof dir) {
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

/**
 * @brief Write @p data to @p path atomically (temp file, fsync, rename).
 * @return 0 on success, -1 otherwise.
 */
static int write_file_atomic(const char *path, const char *data)
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
        fprintf(stderr, PROG ": open %s: %s\n", tmp, strerror(errno));
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
        fprintf(stderr, PROG ": rename %s: %s\n", path, strerror(errno));
        unlink(tmp);
        return -1;
    }

    /* fsync the containing directory so the rename is durable across a power loss - otherwise a
     * bind reported as persisted could vanish on a cut right after the rename. */
    fsync_dir(path);

    return 0;
}

/**
 * @brief Locate the candidate.slot array in a parsed config tree.
 * @return the array cJSON node, or NULL if the path is absent or not an array.
 */
static cJSON *find_slot_array(cJSON *root)
{
    cJSON *node = root;
    static const char *const path[] = { "baseband", "basic", "ap", "candidate", "slot" };
    for (unsigned i = 0; i < sizeof path / sizeof path[0]; i++) {
        node = cJSON_GetObjectItemCaseSensitive(node, path[i]);
        if (node == NULL) {
            return NULL;
        }
    }

    return cJSON_IsArray(node) ? node : NULL;
}

/**
 * @brief Apply the vendor candidate-list edit to @p slot for @p mac.
 * @return 1 if the array changed, 0 if it was already correct (mac present, length 5).
 *
 * Reproduces AR_AR8030_RxUpdateApDataCjson: normalize to SLOT_COUNT, dedup-scan, and only on a
 * miss shift toward the head and append the mac at the tail.
 */
static int slot_apply(cJSON *slot, const char *mac)
{
    int size = cJSON_GetArraySize(slot);
    int changed = 0;
    int present = 0;

    /* Normalize to exactly SLOT_COUNT. Short: append the running (size+1)&0xf nibble x8 as the
     * vendor does. Long: delete from the head. */
    while (size < SLOT_COUNT) {
        char fill[9];
        int nibble = (size + 1) & 0xf;
        memset(fill, "0123456789abcdef"[nibble], 8);
        fill[8] = '\0';
        cJSON_AddItemToArray(slot, cJSON_CreateString(fill));
        size++;
        changed = 1;
    }

    while (size > SLOT_COUNT) {
        cJSON_DeleteItemFromArray(slot, 0);
        size--;
        changed = 1;
    }

    /* Dedup: a case-sensitive string compare, matching the vendor's %02x lowercase format. */
    for (int i = 0; i < SLOT_COUNT; i++) {
        cJSON *item = cJSON_GetArrayItem(slot, i);

        if (item != NULL && item->valuestring != NULL && strcmp(item->valuestring, mac) == 0) {
            present = 1;
            break;
        }
    }

    if (present) {
        return changed;
    }

    /* Miss: shift toward the head (slot[i] = slot[i+1]) and write the mac at the tail. Guard the
     * source string like the dedup loop does: a non-string entry (malformed config) has a NULL
     * valuestring, which would otherwise be passed to cJSON_CreateString. */
    for (int i = 0; i < SLOT_COUNT - 1; i++) {
        cJSON *next = cJSON_GetArrayItem(slot, i + 1);
        const char *val = (next != NULL && next->valuestring != NULL) ? next->valuestring : "";

        cJSON_ReplaceItemInArray(slot, i, cJSON_CreateString(val));
    }

    cJSON_ReplaceItemInArray(slot, SLOT_COUNT - 1, cJSON_CreateString(mac));

    return 1;
}

/**
 * @brief Seed-if-absent, edit, and persist one band-variant config file.
 * @return 0 on success or a benign skip, -1 on a hard error.
 *
 * The edit target is the /usrdata copy; it is seeded from the baked /lib/firmware copy the first
 * time. Nothing is written when the mac is already present and no /usrdata copy exists yet (the
 * baked config already holds it), so re-binding a factory-bound unit touches no files.
 */
static int persist_one(const char *cfg, const char *mac)
{
    char dst[512], baked[512], backup[512];
    char *text;
    int from_baked;
    cJSON *root, *slot;

    if ((size_t)snprintf(dst, sizeof dst, "%s/%s", USR_DIR, cfg) >= sizeof dst
        || (size_t)snprintf(baked, sizeof baked, "%s/%s", FW_DIR, cfg) >= sizeof baked) {
        return -1;
    }

    text = read_file(dst);
    from_baked = 0;
    if (text == NULL) {
        text = read_file(baked);
        from_baked = 1;
    }

    if (text == NULL) {
        fprintf(stderr, PROG ": %s: no config in %s or %s, skipping\n", cfg, USR_DIR, FW_DIR);
        return 0;
    }

    root = cJSON_Parse(text);
    free(text);
    if (root == NULL) {
        fprintf(stderr, PROG ": %s: parse failed, skipping\n", cfg);
        return -1;
    }

    slot = find_slot_array(root);
    if (slot == NULL) {
        fprintf(stderr, PROG ": %s: no baseband.basic.ap.candidate.slot array, skipping\n", cfg);
        cJSON_Delete(root);
        return -1;
    }

    /* No change and no /usrdata copy yet means the baked config already holds the mac: leave the
     * fallback in place and write nothing. */
    if (slot_apply(slot, mac) == 0 && from_baked) {
        cJSON_Delete(root);
        printf(PROG ": %s: %s already bound, no change\n", cfg, mac);
        return 0;
    }

    /* Back up the pre-edit config once, so a bad edit is recoverable. */
    if (snprintf(backup, sizeof backup, "%s.pre-bind", dst) < (int)sizeof backup
        && access(backup, F_OK) != 0 && access(dst, F_OK) == 0) {
        char *cur = read_file(dst);

        if (cur != NULL) {
            write_file_atomic(backup, cur);
            free(cur);
        }
    }

    char *out = cJSON_Print(root);
    cJSON_Delete(root);
    if (out == NULL) {
        return -1;
    }

    if (write_file_atomic(dst, out) != 0) {
        free(out);
        return -1;
    }

    free(out);
    printf(PROG ": %s: bound %s%s\n", cfg, mac, from_baked ? " (seeded from baked config)" : "");

    return 0;
}

/**
 * @brief Validate that @p mac is exactly 8 lowercase hex digits.
 */
static int mac_valid(const char *mac)
{
    if (strlen(mac) != 8) {
        return 0;
    }

    for (int i = 0; i < 8; i++) {
        if (!isxdigit((unsigned char)mac[i]) || isupper((unsigned char)mac[i])) {
            return 0;
        }
    }

    return 1;
}

#ifndef ML_RF_PERSIST_TEST
int main(int argc, char **argv)
{
    int rc = 0;

    if (argc != 2 || !mac_valid(argv[1])) {
        fprintf(stderr, "usage: " PROG " <mac>   (8 lowercase hex digits, e.g. e515815c)\n");
        return 2;
    }

    if (access(USR_DIR, F_OK) != 0 && mkdir(USR_DIR, 0755) != 0 && errno != EEXIST) {
        fprintf(stderr, PROG ": %s: %s\n", USR_DIR, strerror(errno));
        return 1;
    }

    for (unsigned i = 0; i < sizeof CFG_FILES / sizeof CFG_FILES[0]; i++) {
        if (persist_one(CFG_FILES[i], argv[1]) != 0) {
            rc = 1;
        }
    }

    return rc;
}
#endif /* ML_RF_PERSIST_TEST */
