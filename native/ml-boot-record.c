/**
 * @file ml-boot-record.c
 * @brief Mark a healthy boot in the per-unit device record /usrdata/missinglynk/device.json.
 *
 * Run once late in boot (an OpenRC oneshot ordered after the services that make the unit usable,
 * SSH included), so reaching this point means the slot came up healthy. It increments `boots`
 * (0 = never came up healthy, so `boots > 0` is the "this image booted" marker a host switch tool
 * consults), records the open firmware version from /etc/ml-release into `installed.version`, and
 * stamps `last_boot_time`. Every other field is preserved.
 *
 * The kernel/dtb digests are written only by the flasher (mlflash) at flash time and are NOT
 * refreshed here: an image flashed outside the tool therefore reads as unverified at switch time
 * (its recorded digests do not match, or are absent), which is the honest state since the flasher
 * never hashed those bytes. That is safe because the switch is advisory, never a hard gate.
 *
 * When the record does not exist yet (a manual flash, or a first boot before any mlflash run) it is
 * created with the DT model, the version, and boots = 1. Writes are atomic (temp + rename + fsync
 * of file and directory) since this runs shortly before watchdog resets.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>

#include "vendor/cJSON.h"
#include "mlfile.h"

#define PROG      "ml-boot-record"
#define USR_DIR   ML_USR_DIR
#define RECORD    USR_DIR "/device.json"
#define RELEASE   "/etc/ml-release"

/**
 * @brief Read the value of key @p key from the os-release-style /etc/ml-release into @p out.
 * @return 0 on success, -1 if the file or key is absent.
 *
 * Lines are KEY="value"; the surrounding double quotes are stripped.
 */
static int read_release_value(const char *key, char *out, size_t out_sz)
{
    char *text = ml_read_file(RELEASE);
    if (text == NULL) {
        return -1;
    }

    int found = -1;
    size_t key_len = strlen(key);
    for (char *line = strtok(text, "\n"); line != NULL; line = strtok(NULL, "\n")) {
        if (strncmp(line, key, key_len) != 0 || line[key_len] != '=') {
            continue;
        }

        char *value = line + key_len + 1;
        if (*value == '"') {
            value++;
            char *end = strrchr(value, '"');
            if (end != NULL) {
                *end = '\0';
            }
        }
        snprintf(out, out_sz, "%s", value);
        found = 0;
        break;
    }

    free(text);
    return found;
}

/**
 * @brief Set string member @p key on @p obj, replacing any existing value.
 */
static void set_string(cJSON *obj, const char *key, const char *value)
{
    cJSON_DeleteItemFromObjectCaseSensitive(obj, key);
    cJSON_AddStringToObject(obj, key, value);
}

/**
 * @brief Set numeric member @p key on @p obj, replacing any existing value.
 */
static void set_number(cJSON *obj, const char *key, double value)
{
    cJSON_DeleteItemFromObjectCaseSensitive(obj, key);
    cJSON_AddNumberToObject(obj, key, value);
}

int main(void)
{
    ml_prog = PROG;

    char version[128] = "";
    int have_version = (read_release_value("ML_VERSION", version, sizeof version) == 0);

    /* Read-modify-write the existing record, or start a fresh one. */
    char *text = ml_read_file(RECORD);
    cJSON *root = text ? cJSON_Parse(text) : NULL;
    free(text);
    if (root == NULL) {
        root = cJSON_CreateObject();
        char model[128];
        if (ml_read_dt_model(model, sizeof model) == 0) {
            cJSON_AddStringToObject(root, "device", model);
        }
    }

    /* boots: increment the recorded count (0/missing -> 1). This runs once per healthy boot. */
    const cJSON *prev_boots = cJSON_GetObjectItemCaseSensitive(root, "boots");
    double boots = cJSON_IsNumber(prev_boots) ? prev_boots->valuedouble : 0;
    set_number(root, "boots", boots + 1);
    set_number(root, "last_boot_time", (double)time(NULL));

    /* installed.version reflects the image that actually booted, from /etc/ml-release. */
    if (have_version) {
        cJSON *installed = cJSON_GetObjectItemCaseSensitive(root, "installed");
        if (!cJSON_IsObject(installed)) {
            installed = cJSON_CreateObject();
            cJSON_AddItemToObject(root, "installed", installed);
        }
        set_string(installed, "version", version);
    }

    if (ml_ensure_dir(USR_DIR) != 0) {
        cJSON_Delete(root);
        return 1;
    }

    char *out = cJSON_Print(root);
    cJSON_Delete(root);
    if (out == NULL) {
        return 1;
    }

    int rc = ml_write_file_atomic(RECORD, out);
    if (rc == 0) {
        printf(PROG ": boot %d recorded (version %s)\n",
               (int)(boots + 1), have_version ? version : "unknown");
    }
    free(out);

    return rc == 0 ? 0 : 1;
}
