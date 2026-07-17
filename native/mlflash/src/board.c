/**
 * @file board.c
 * @brief Device-identity gate: match the manifest's target_device against the device's own
 *        product id, read verbatim from the vendor sdk_version.json.
 */
#include <stdio.h>
#include <string.h>

#include "cJSON.h"
#include "board.h"

/* The vendor records the product id in sdk_version.json's "product_version" field (e.g.
 * "P1_GND_VR04"), which is exactly the string mlimg.py stamps into the manifest's target_device.
 * Reading that one field and comparing it verbatim keeps this device-agnostic: no product name is
 * enumerated here, so a new device needs no code change - only a matching target_device.
 */
#define SDK_VERSION_FIELD "product_version"

static const char *const SDK_VERSION_PATHS[] = {
    "/usr/usrdata/sdk_version.json",
    "/usrdata/sdk_version.json",
    NULL,
};

/* Read the device's product id into `out`. Returns 0 on success, -1 if no sdk_version.json is
 * present (e.g. the open Alpine slot B) or it carries no product_version string.
 */
static int device_product_id(char *out, size_t out_sz)
{
    for (int i = 0; SDK_VERSION_PATHS[i]; i++) {
        FILE *f = fopen(SDK_VERSION_PATHS[i], "rb");
        if (!f) {
            continue;
        }

        char buf[4096];
        size_t n = fread(buf, 1, sizeof buf - 1, f);
        fclose(f);
        buf[n] = 0;

        cJSON *root = cJSON_Parse(buf);
        if (!root) {
            continue;
        }

        const cJSON *field = cJSON_GetObjectItemCaseSensitive(root, SDK_VERSION_FIELD);
        int have = cJSON_IsString(field) && field->valuestring;
        if (have) {
            snprintf(out, out_sz, "%s", field->valuestring);
        }
        cJSON_Delete(root);

        if (have) {
            return 0;
        }
    }

    return -1;
}

int board_matches(const char *manifest_device)
{
    char product_id[64];

    if (device_product_id(product_id, sizeof product_id) != 0) {
        return -1;
    }
    return strcmp(product_id, manifest_device) == 0 ? 1 : 0;
}
