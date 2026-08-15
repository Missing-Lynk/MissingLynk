/**
 * @file mlimg.c
 * @brief .mlimg bundle reading: ustar tar parsing and manifest.json (cJSON).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "mlimg.h"
#include "cJSON.h"     /* native/vendor (shared), on the -I path */

/* ustar (tar) header field layout, all in the 512-byte header block. */
#define TAR_BLOCK         512
#define TAR_NAME_LEN      100         /* name field at offset 0 */
#define TAR_SIZE_OFF      124
#define TAR_SIZE_LEN      12          /* octal ASCII */

struct component_spec {
    const char *name;
    const char *role;
    const char *target;
    const char *method;
    const char *file;
};

static const struct component_spec COMPONENT_SPECS[] = {
    { "uboot",  "vendor", "uboot",   "mtdtool-raw", "uboot.bin" },
    { "env",    "vendor", "env",     "mtdtool-raw", "env.bin" },
    { "kernel", "open",   "kernel",  "mtdtool-raw", "kernel.otra" },
    { "dtb",    "open",   "dtb",     "mtdtool-raw", "dtb.dtb" },
    { "rootfs", "open",   "userapp", "ubiformat",   "rootfs.ubi" },
};

static const struct component_spec *find_component_spec(const char *target)
{
    for (unsigned i = 0; i < sizeof COMPONENT_SPECS / sizeof COMPONENT_SPECS[0]; i++) {
        if (strcmp(COMPONENT_SPECS[i].target, target) == 0) {
            return &COMPONENT_SPECS[i];
        }
    }

    return NULL;
}

/*
 * Only the component streamed into ubiformat's stdin can be inflated on the way past. The raw
 * partitions are written from the mapped pointer and read back against their digest through that
 * same pointer, so inflating one would mean holding the whole payload in RAM on a device that has
 * little of it. The builder compresses by this same rule.
 */
int component_is_gzipped(const struct component *comp)
{
    return strcmp(comp->method, "ubiformat") == 0;
}

static int is_sha256_hex(const char *s)
{
    for (int i = 0; i < 64; i++) {
        if (!isxdigit((unsigned char)s[i])) {
            return 0;
        }
    }

    return s[64] == 0;
}

static int validate_component(const struct component *comp, unsigned *seen_targets)
{
    const struct component_spec *spec = find_component_spec(comp->target);
    if (!spec) {
        fprintf(stderr, "manifest: component %s targets unsupported partition '%s'\n",
                comp->name, comp->target);
        return -1;
    }

    unsigned bit = 1u << (unsigned)(spec - COMPONENT_SPECS);
    if (*seen_targets & bit) {
        fprintf(stderr, "manifest: duplicate target '%s'\n", comp->target);
        return -1;
    }
    *seen_targets |= bit;

    if (strcmp(comp->name, spec->name) || strcmp(comp->role, spec->role) ||
        strcmp(comp->method, spec->method) || strcmp(comp->file, spec->file)) {
        fprintf(stderr, "manifest: component for target '%s' has unexpected metadata\n",
                comp->target);
        return -1;
    }

    if (comp->bytes <= 0) {
        fprintf(stderr, "manifest: component %s has invalid byte length %lld\n",
                comp->name, comp->bytes);
        return -1;
    }

    if (!is_sha256_hex(comp->sha256)) {
        fprintf(stderr, "manifest: component %s has invalid sha256\n", comp->name);
        return -1;
    }

    if (comp->stored_bytes <= 0) {
        fprintf(stderr, "manifest: component %s has invalid stored byte length %lld\n",
                comp->name, comp->stored_bytes);
        return -1;
    }

    if (!is_sha256_hex(comp->stored_sha256)) {
        fprintf(stderr, "manifest: component %s has invalid stored sha256\n", comp->name);
        return -1;
    }

    /* A verbatim component's two digests describe the same bytes, so they have to agree. */
    if (!component_is_gzipped(comp) &&
        (comp->stored_bytes != comp->bytes || strcmp(comp->stored_sha256, comp->sha256) != 0)) {
        fprintf(stderr, "manifest: uncompressed component %s disagrees with its stored digest\n",
                comp->name);
        return -1;
    }

    return 0;
}

int tar_find(const unsigned char *img, size_t img_len, const char *name,
             const unsigned char **out, size_t *out_len)
{
    size_t block_off = 0;
    while (block_off + TAR_BLOCK <= img_len) {
        const unsigned char *header = img + block_off;
        int empty = 1;

        for (int i = 0; i < TAR_BLOCK; i++) {
            if (header[i]) {
                empty = 0;
                break;
            }
        }

        if (empty) {
            break;
        }

        char size_field[TAR_SIZE_LEN + 1];
        memcpy(size_field, header + TAR_SIZE_OFF, TAR_SIZE_LEN);
        size_field[TAR_SIZE_LEN] = 0;
        size_t member_size = (size_t)strtoul(size_field, NULL, 8);

        char member_name[TAR_NAME_LEN + 1];
        memcpy(member_name, header, TAR_NAME_LEN);
        member_name[TAR_NAME_LEN] = 0;

        size_t data_off = block_off + TAR_BLOCK;
        if (data_off + member_size > img_len) {
            return -1;
        }

        if (strcmp(member_name, name) == 0) {
            *out = img + data_off;
            *out_len = member_size;
            return 0;
        }

        /* Each member's data is padded up to a whole number of blocks. */
        block_off = data_off + ((member_size + TAR_BLOCK - 1) / TAR_BLOCK) * TAR_BLOCK;
    }

    return -1;
}

/* Copy a string-valued key from a cJSON object into `out` (empty string if absent). */
static void json_copy_string(const cJSON *obj, const char *key, char *out, size_t out_sz)
{
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(obj, key);

    if (cJSON_IsString(item) && item->valuestring) {
        snprintf(out, out_sz, "%s", item->valuestring);
        return;
    }

    out[0] = 0;
}

int manifest_parse(const unsigned char *data, size_t len, struct manifest *m)
{
    memset(m, 0, sizeof *m);

    cJSON *root = cJSON_ParseWithLength((const char *)data, len);
    if (!root) {
        fprintf(stderr, "manifest: JSON parse error\n");
        return -1;
    }

    const cJSON *format_version = cJSON_GetObjectItemCaseSensitive(root, "format_version");
    if (!cJSON_IsNumber(format_version)) {
        fprintf(stderr, "manifest: missing format_version\n");
        cJSON_Delete(root);

        return -1;
    }

    m->format_version = (long long)format_version->valuedouble;
    if (m->format_version != MLIMG_FORMAT_VERSION) {
        fprintf(stderr, "manifest: unsupported format_version %lld (expected %d)\n",
                m->format_version, MLIMG_FORMAT_VERSION);
        cJSON_Delete(root);

        return -1;
    }

    json_copy_string(root, "target_device", m->target_device, sizeof m->target_device);
    json_copy_string(root, "version", m->version, sizeof m->version);
    if (!m->target_device[0] || !m->version[0]) {
        fprintf(stderr, "manifest: missing target_device or version\n");
        cJSON_Delete(root);

        return -1;
    }

    const cJSON *components = cJSON_GetObjectItemCaseSensitive(root, "components");
    if (!cJSON_IsArray(components)) {
        fprintf(stderr, "manifest: missing components array\n");
        cJSON_Delete(root);

        return -1;
    }

    const cJSON *item = NULL;
    unsigned seen_targets = 0;
    cJSON_ArrayForEach(item, components) {
        if (m->ncomp >= MAX_COMPONENTS) {
            fprintf(stderr, "manifest: too many components\n");
            cJSON_Delete(root);

            return -1;
        }

        struct component *comp = &m->comp[m->ncomp];
        json_copy_string(item, "name", comp->name, sizeof comp->name);
        json_copy_string(item, "role", comp->role, sizeof comp->role);
        json_copy_string(item, "target", comp->target, sizeof comp->target);
        json_copy_string(item, "method", comp->method, sizeof comp->method);
        json_copy_string(item, "file", comp->file, sizeof comp->file);
        json_copy_string(item, "sha256", comp->sha256, sizeof comp->sha256);

        const cJSON *bytes = cJSON_GetObjectItemCaseSensitive(item, "bytes");
        if (cJSON_IsNumber(bytes)) {
            comp->bytes = (long long)bytes->valuedouble;
        }

        json_copy_string(item, "stored_sha256", comp->stored_sha256, sizeof comp->stored_sha256);

        const cJSON *stored_bytes = cJSON_GetObjectItemCaseSensitive(item, "stored_bytes");
        if (cJSON_IsNumber(stored_bytes)) {
            comp->stored_bytes = (long long)stored_bytes->valuedouble;
        }

        if (!comp->name[0] || !comp->file[0] || !comp->target[0] || !comp->sha256[0]) {
            fprintf(stderr, "manifest: component %d missing required fields\n", m->ncomp);
            cJSON_Delete(root);

            return -1;
        }

        if (validate_component(comp, &seen_targets) != 0) {
            cJSON_Delete(root);

            return -1;
        }

        m->ncomp++;
    }

    cJSON_Delete(root);

    if (m->ncomp == 0) {
        fprintf(stderr, "manifest: no components\n");
        return -1;
    }

    unsigned want_targets = (1u << (sizeof COMPONENT_SPECS / sizeof COMPONENT_SPECS[0])) - 1u;
    if (seen_targets != want_targets) {
        fprintf(stderr, "manifest: expected uboot, env, kernel, dtb and rootfs components\n");
        return -1;
    }

    return 0;
}
