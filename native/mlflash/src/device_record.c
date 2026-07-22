/**
 * @file device_record.c
 * @brief Write the per-unit device record /usrdata/missinglynk/device.json at flash time.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>

#include "cJSON.h"
#include "mtd.h"
#include "mlfile.h"
#include "device_record.h"

#define USR_DIR   "/usrdata/missinglynk"
#define RECORD    USR_DIR "/device.json"

/* The vendor serial lives in sdk_version.json on the stock slot's usr_data (same file board.c
 * reads the product id from); it is absent on the open Alpine slot. */
static const char *const SDK_VERSION_PATHS[] = {
    "/usr/usrdata/sdk_version.json",
    "/usrdata/sdk_version.json",
    NULL,
};

/**
 * @brief Build the "vendor" object from sdk_version.json (serial fields copied verbatim).
 * @return a new cJSON object, or NULL if sdk_version.json is absent/unparseable.
 */
static cJSON *read_vendor(void)
{
    for (int i = 0; SDK_VERSION_PATHS[i]; i++) {
        char *text = ml_read_file(SDK_VERSION_PATHS[i]);
        if (text == NULL) {
            continue;
        }

        cJSON *root = cJSON_Parse(text);
        free(text);
        if (root == NULL) {
            continue;
        }

        cJSON *vendor = cJSON_CreateObject();
        static const char *const keys[] = {
            "hardware_version", "software_version", "sequence_number", "product_version",
        };
        for (unsigned k = 0; k < sizeof keys / sizeof keys[0]; k++) {
            const cJSON *field = cJSON_GetObjectItemCaseSensitive(root, keys[k]);
            if (cJSON_IsString(field) && field->valuestring) {
                cJSON_AddStringToObject(vendor, keys[k], field->valuestring);
            } else if (cJSON_IsNumber(field)) {
                cJSON_AddNumberToObject(vendor, keys[k], field->valuedouble);
            }
        }

        cJSON_Delete(root);
        return vendor;
    }

    return NULL;
}

/* Locate the resolved /dev path of the component named @p name (kernel/dtb), or NULL if absent. */
static const char *component_devpath(const struct manifest *m, char devpath[][32],
                                     const char *name)
{
    for (int i = 0; i < m->ncomp; i++) {
        if (strcmp(m->comp[i].name, name) == 0) {
            return devpath[i];
        }
    }

    return NULL;
}

/* Add the whole-partition digest of the component named @p name to @p root under @p key. Warns and
 * skips (leaving the key absent) when the component or its partition cannot be hashed. */
static void add_partition_digest(cJSON *root, const char *key, const struct manifest *m,
                                 char devpath[][32], const char *name)
{
    const char *dev = component_devpath(m, devpath, name);
    if (dev == NULL) {
        fprintf(stderr, "device.json: no %s component; %s omitted\n", name, key);
        return;
    }

    char hex[65];
    if (mtd_partition_sha256(dev, hex) != 0) {
        fprintf(stderr, "device.json: could not hash %s (%s); %s omitted\n", name, dev, key);
        return;
    }

    cJSON_AddStringToObject(root, key, hex);
}

int device_record_write_flash(const struct manifest *m, char devpath[][32], int target)
{
    if (access(USR_DIR, F_OK) != 0 && mkdir(USR_DIR, 0755) != 0 && errno != EEXIST) {
        fprintf(stderr, "device.json: %s: %s\n", USR_DIR, strerror(errno));
        return -1;
    }

    /* Carry forward the user-assigned nickname and, only if the vendor serial cannot be read now,
     * the previously captured vendor block. */
    char *prev_text = ml_read_file(RECORD);
    cJSON *prev = prev_text ? cJSON_Parse(prev_text) : NULL;
    free(prev_text);

    cJSON *root = cJSON_CreateObject();

    char model[128];
    if (ml_read_dt_model(model, sizeof model) == 0) {
        cJSON_AddStringToObject(root, "device", model);
    } else {
        cJSON_AddStringToObject(root, "device", m->target_device);
    }

    cJSON *vendor = read_vendor();
    if (vendor == NULL && prev) {
        const cJSON *prev_vendor = cJSON_GetObjectItemCaseSensitive(prev, "vendor");
        if (prev_vendor) {
            vendor = cJSON_Duplicate(prev_vendor, 1);
        }
    }

    if (vendor) {
        cJSON_AddItemToObject(root, "vendor", vendor);
    }

    cJSON *installed = cJSON_CreateObject();
    cJSON_AddStringToObject(installed, "version", m->version);
    cJSON_AddNumberToObject(installed, "flash_time", (double)time(NULL));
    cJSON_AddStringToObject(installed, "slot", target ? "B" : "A");
    cJSON_AddItemToObject(root, "installed", installed);

    add_partition_digest(root, "kernel_sha256", m, devpath, "kernel");
    add_partition_digest(root, "dtb_sha256", m, devpath, "dtb");

    /* This image has not proven it boots yet: the open slot's boot service sets this on a healthy
     * boot, and a switch decision trusts it only when the recorded digests still match. */
    cJSON_AddNumberToObject(root, "boots", 0);

    if (prev) {
        const cJSON *nickname = cJSON_GetObjectItemCaseSensitive(prev, "nickname");
        if (cJSON_IsString(nickname) && nickname->valuestring) {
            cJSON_AddStringToObject(root, "nickname", nickname->valuestring);
        }
        cJSON_Delete(prev);
    }

    char *out = cJSON_Print(root);
    cJSON_Delete(root);
    if (out == NULL) {
        return -1;
    }

    int rc = ml_write_file_atomic(RECORD, out);
    free(out);
    if (rc == 0) {
        printf("device.json: recorded install of %s to slot %s\n",
               m->version, target ? "B" : "A");
    }

    return rc;
}
