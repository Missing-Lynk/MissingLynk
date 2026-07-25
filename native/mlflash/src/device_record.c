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
#include "slot.h"
#include "mlfile.h"
#include "device_record.h"

#define USR_DIR   ML_USR_DIR
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
    if (ml_ensure_dir(USR_DIR) != 0) {
        return -1;
    }

    /* Only if the vendor serial cannot be read now, carry forward the previously captured vendor
     * block. */
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

    cJSON_Delete(prev);

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

/* Hash slot `slot`'s partition named `base` (e.g. "kernel" -> "kernel0"/"kernel1") into `hex`.
 * Returns 0 on success, -1 if the partition cannot be resolved or read. */
static int hash_slot_partition(const char *base, int slot, char hex[65])
{
    char name[32];
    snprintf(name, sizeof name, "%s%d", base, slot ? 1 : 0);

    int num = -1;
    unsigned long size = 0;
    if (mtd_by_name(name, &num, &size) != 0) {
        return -1;
    }

    char devpath[32];
    snprintf(devpath, sizeof devpath, "/dev/mtd%d", num);
    return mtd_partition_sha256(devpath, hex);
}

/* Copy the string field `src_key` from `src` to `dst` under `dst_key`, if present and a string. */
static void copy_string_field(cJSON *dst, const cJSON *src, const char *src_key, const char *dst_key)
{
    const cJSON *field = cJSON_GetObjectItemCaseSensitive(src, src_key);
    if (cJSON_IsString(field) && field->valuestring) {
        cJSON_AddStringToObject(dst, dst_key, field->valuestring);
    }
}

/* The recorded digest string under `key` in `rec`, or NULL when the record carries none. A record
 * written by a flash outside this tool has no digests at all, which is distinct from a digest that
 * is present and differs. */
static const char *recorded_digest(const cJSON *rec, const char *key)
{
    const cJSON *recorded = cJSON_GetObjectItemCaseSensitive(rec, key);
    if (!cJSON_IsString(recorded) || !recorded->valuestring) {
        return NULL;
    }

    return recorded->valuestring;
}

/* Whether the recorded digest under `key` in `rec` equals the live SHA-256 of slot `slot`'s `base`
 * partition. A missing recorded digest or an unhashable partition reads as a non-match. */
static int digest_matches(const cJSON *rec, const char *key, const char *base, int slot)
{
    const char *recorded = recorded_digest(rec, key);
    if (recorded == NULL) {
        return 0;
    }

    char hex[65];
    if (hash_slot_partition(base, slot, hex) != 0) {
        return 0;
    }

    return strcmp(hex, recorded) == 0;
}

int device_record_report(int slot)
{
    cJSON *out = cJSON_CreateObject();
    cJSON_AddStringToObject(out, "slot", slot ? "B" : "A");

    char *text = ml_read_file(RECORD);
    cJSON *rec = text ? cJSON_Parse(text) : NULL;
    free(text);

    if (rec == NULL) {
        cJSON_AddBoolToObject(out, "present", 0);
        char *absent = cJSON_PrintUnformatted(out);
        printf("%s\n", absent ? absent : "{}");
        free(absent);
        cJSON_Delete(out);

        return 1;
    }

    cJSON_AddBoolToObject(out, "present", 1);

    /* Carry the human-facing identity fields through verbatim (absent -> omitted). */
    copy_string_field(out, rec, "device", "device");

    const cJSON *installed = cJSON_GetObjectItemCaseSensitive(rec, "installed");
    if (installed) {
        copy_string_field(out, installed, "version", "installed_version");
        copy_string_field(out, installed, "slot", "installed_slot");
    }

    const cJSON *vendor = cJSON_GetObjectItemCaseSensitive(rec, "vendor");
    if (vendor) {
        copy_string_field(out, vendor, "sequence_number", "serial");
    }

    int boots = 0;
    const cJSON *boot_count = cJSON_GetObjectItemCaseSensitive(rec, "boots");
    if (cJSON_IsNumber(boot_count)) {
        boots = (int)boot_count->valuedouble;
    }
    cJSON_AddNumberToObject(out, "boots", boots);

    /* Whether the record carries digests at all. Only a flash performed by this tool records them,
     * so a slot installed another way (a development flash of the partitions directly) has none.
     * That is a different state from a digest that is present and differs, and the host reports it
     * differently: unverifiable rather than changed. */
    int digests_recorded = recorded_digest(rec, "kernel_sha256") != NULL &&
                           recorded_digest(rec, "dtb_sha256") != NULL;
    cJSON_AddBoolToObject(out, "digests_recorded", digests_recorded);

    /* Re-hash the queried slot's live kernel/dtb and compare to the recorded digests. The digests
     * describe the slot that was flashed (installed.slot); a different queried slot holds different
     * bytes and reads as a mismatch, which is honest. */
    int kernel_match = digest_matches(rec, "kernel_sha256", "kernel", slot);
    int dtb_match = digest_matches(rec, "dtb_sha256", "dtb", slot);
    cJSON_AddBoolToObject(out, "kernel_match", kernel_match);
    cJSON_AddBoolToObject(out, "dtb_match", dtb_match);

    /* Proven only when a healthy boot was recorded AND the exact bytes still read back identical. */
    cJSON_AddBoolToObject(out, "verified", boots > 0 && kernel_match && dtb_match);

    cJSON_Delete(rec);

    char *report = cJSON_PrintUnformatted(out);
    printf("%s\n", report ? report : "{}");
    free(report);
    cJSON_Delete(out);

    return 0;
}
