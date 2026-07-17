/**
 * @file mlflash.c
 * @brief Standalone on-device flasher for .mlimg slot bundles (Artosyn goggle/air): entry point.
 *
 * mlflash consumes a .mlimg bundle (built by glue/flash/mlimg.py) and writes it to a boot
 * slot's partitions, as an unsigned-image replacement for the vendor flasher. It is a single
 * static aarch64 binary that runs under either userspace (vendor glibc slot, open Alpine slot)
 * with no host, no SSH, and no dependency on a binary already present on the running slot.
 *
 * This file holds the command implementations and argument parsing; the pieces live in:
 *   util.{h,c}   file slurp, SHA-256 (OpenSSL libcrypto), little-endian readers
 *   mlimg.{h,c}  the .mlimg bundle: ustar tar reader + manifest.json (cJSON)
 *   slot.{h,c}   A/B slot detection (mtd names, running slot, GPT active bit)
 *
 * Phase 1 only: the pure-read foundation.
 *   mlflash --inspect <image.mlimg>    print the manifest, re-verify every component hash
 *   mlflash --dry-run <image.mlimg>    preflight: detect the running slot, cross-check the GPT
 *                                      active bit, resolve every target mtd by name, verify
 *                                      image hashes; print the plan; NO writes
 *
 * The write path (raw partitions via the mtdtool primitives, userapp via vendored mtd-utils
 * ubiformat) and the gated --flip / --force-a actions land in later phases and are intentionally
 * absent here: this build cannot write flash. Static aarch64 build, see native/build.sh.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "util.h"
#include "mlimg.h"
#include "slot.h"

static int cmd_inspect(const char *path)
{
    size_t img_len = 0;
    unsigned char *img = read_all(path, &img_len);
    if (!img) {
        return 1;
    }

    const unsigned char *manifest_data;
    size_t manifest_len;
    if (tar_find(img, img_len, "manifest.json", &manifest_data, &manifest_len) != 0) {
        fprintf(stderr, "%s: no manifest.json (not an .mlimg?)\n", path);
        free(img);
        return 1;
    }

    struct manifest m;
    if (manifest_parse(manifest_data, manifest_len, &m) != 0) {
        free(img);
        return 1;
    }

    printf("mlimg: %s\n", path);
    printf("  format %lld  device %s  version %s\n",
           m.format_version, m.target_device, m.version);
    printf("  components:\n");

    int ok = 1;
    for (int i = 0; i < m.ncomp; i++) {
        struct component *comp = &m.comp[i];
        const unsigned char *data;
        size_t data_len;
        if (tar_find(img, img_len, comp->file, &data, &data_len) != 0) {
            printf("    %-7s MISSING member %s\n", comp->name, comp->file);
            ok = 0;
            continue;
        }

        char hex[65];
        sha256_hex(data, data_len, hex);
        int size_ok = ((long long)data_len == comp->bytes);
        int hash_ok = (strcmp(hex, comp->sha256) == 0);
        const char *status = (size_ok && hash_ok) ? "OK" : "FAIL";
        if (!size_ok || !hash_ok) {
            ok = 0;
        }
        printf("    %-7s %-6s -> %-8s %12zu B  %.16s  [%s]\n",
               comp->name, comp->role, comp->target, data_len, hex, status);
    }

    printf("  => %s\n", ok ? "all components verified" : "VERIFICATION FAILED");
    free(img);

    return ok ? 0 : 1;
}

static int cmd_dry_run(const char *path, const char *want_slot)
{
    size_t img_len = 0;
    unsigned char *img = read_all(path, &img_len);
    if (!img) {
        return 1;
    }

    const unsigned char *manifest_data;
    size_t manifest_len;
    if (tar_find(img, img_len, "manifest.json", &manifest_data, &manifest_len) != 0) {
        fprintf(stderr, "%s: no manifest.json\n", path);
        free(img);
        return 1;
    }

    struct manifest m;
    if (manifest_parse(manifest_data, manifest_len, &m) != 0) {
        free(img);
        return 1;
    }

    int fail = 0;

    /* Running slot (authoritative) + GPT cross-check. */
    int running = running_slot();
    int gpt_slot = gpt_active_slot();
    printf("running slot (/proc/cmdline): %s\n",
           running == 0 ? "A" : running == 1 ? "B" : "UNKNOWN");
    printf("gpt active bit (gpt0):        %s\n",
           gpt_slot == 0 ? "A" : gpt_slot == 1 ? "B" : "UNKNOWN");
    if (running < 0) {
        printf("  ABORT: cannot determine the running slot; refusing to plan a write.\n");
        fail = 1;
    } else if (gpt_slot >= 0 && gpt_slot != running) {
        printf("  ABORT: GPT-active and running slot disagree (post-flip / RAM-boot window); "
               "resolve by hand.\n");
        fail = 1;
    }

    /* Target selection: the inactive slot by default, or --slot. */
    int target = -1;
    if (want_slot) {
        target = (want_slot[0] == 'b' || want_slot[0] == 'B') ? 1 : 0;
    } else if (running >= 0) {
        target = !running;
    }
    printf("target slot:                  %s%s\n",
           target == 0 ? "A" : target == 1 ? "B" : "UNKNOWN",
           want_slot ? " (--slot)" : " (inactive, default)");

    if (target >= 0 && running >= 0 && target == running) {
        printf("  ABORT: target == running slot; cannot write the live slot.\n");
        fail = 1;
    }

    if (target == 0) {
        printf("  NOTE: target is slot A; a real flash would require --force-a and a running "
               "slot of B (this is a dry run, no writes).\n");
    }

    /* Board gate (enforced in the write path, phase 2+). */
    printf("manifest target_device:       %s\n", m.target_device);
    printf("  NOTE: board-identity match is enforced in the write path (phase 2+).\n");

    /* Resolve every component target for the chosen slot and verify image hashes. */
    printf("components -> mtd (slot %s):\n", target == 1 ? "B" : "A");
    for (int i = 0; i < m.ncomp; i++) {
        struct component *comp = &m.comp[i];
        char part_name[48];
        snprintf(part_name, sizeof part_name, "%s%d", comp->target, target == 1 ? 1 : 0);

        int mtd_num = -1;
        unsigned long mtd_size = 0;
        int resolved = (target >= 0) ? mtd_by_name(part_name, &mtd_num, &mtd_size) : -1;

        const unsigned char *data;
        size_t data_len;
        int have = (tar_find(img, img_len, comp->file, &data, &data_len) == 0);
        char hex[65] = "";
        int hash_ok = 0;
        if (have) {
            sha256_hex(data, data_len, hex);
            hash_ok = (strcmp(hex, comp->sha256) == 0) && ((long long)data_len == comp->bytes);
        }

        if (resolved == 0) {
            printf("    %-7s -> /dev/mtd%-2d %-9s (%lu B)  image %s\n",
                   comp->name, mtd_num, part_name, mtd_size, hash_ok ? "hash OK" : "HASH FAIL");
        } else {
            printf("    %-7s -> %-9s UNRESOLVED  image %s\n",
                   part_name, "", hash_ok ? "hash OK" : "HASH FAIL");
        }

        if (!have || !hash_ok) {
            fail = 1;
        }
    }

    printf("=> dry-run %s (no writes performed)\n", fail ? "found blockers" : "plan is clean");
    free(img);

    return fail ? 1 : 0;
}

static void usage(void)
{
    fprintf(stderr,
            "usage (phase 1, read-only):\n"
            "  mlflash --inspect <image.mlimg>            print manifest, re-verify hashes\n"
            "  mlflash --dry-run <image.mlimg> [--slot a|b]  device preflight, no writes\n");
}

int main(int argc, char **argv)
{
    const char *mode = NULL;
    const char *image = NULL;
    const char *slot = NULL;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--inspect") || !strcmp(argv[i], "--dry-run")) {
            mode = argv[i];
        } else if (!strcmp(argv[i], "--slot") && i + 1 < argc) {
            slot = argv[++i];
        } else if (argv[i][0] != '-') {
            image = argv[i];
        } else {
            fprintf(stderr, "unknown or unsupported option: %s\n", argv[i]);
            usage();
            return 2;
        }
    }

    if (!mode || !image) {
        usage();
        return 2;
    }

    if (slot && strcmp(slot, "a") && strcmp(slot, "A") &&
        strcmp(slot, "b") && strcmp(slot, "B")) {
        fprintf(stderr, "--slot must be a or b\n");
        return 2;
    }

    if (!strcmp(mode, "--inspect")) {
        return cmd_inspect(image);
    }

    return cmd_dry_run(image, slot);
}
