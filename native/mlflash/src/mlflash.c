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
 *   mtd.{h,c}    raw-partition write + SHA-256 readback (env/dtb/kernel/uboot)
 *   ubi.{h,c}    userapp UBI write via vendored mtd-utils ubiformat
 *
 *   mlflash --inspect <image.mlimg>    print the manifest, re-verify every component hash
 *   mlflash --dry-run <image.mlimg>    preflight: detect the running slot, cross-check the GPT
 *                                      active bit, resolve every target mtd by name, verify
 *                                      image hashes; print the plan; NO writes
 *   mlflash --flash   <image.mlimg>    flash every component to the inactive slot (raw partitions
 *                                      readback-verified, userapp via ubiformat), behind the full
 *                                      preflight; flips the active slot only with --flip
 *   mlflash --flip                     standalone: set the inactive slot active (gpt0 write +
 *                                      readback), no component writes
 *
 * Guards: writing slot A requires --force-a, which is permitted only while running on slot B and
 * is mutually exclusive with --flip. Static build, see native/build.sh.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "util.h"
#include "mlimg.h"
#include "slot.h"
#include "mtd.h"
#include "ubi.h"
#include "board.h"

static int cmd_inspect(const char *path)
{
    size_t img_len = 0;
    unsigned char *img = map_file(path, &img_len);
    if (!img) {
        return 1;
    }

    const unsigned char *manifest_data;
    size_t manifest_len;
    if (tar_find(img, img_len, "manifest.json", &manifest_data, &manifest_len) != 0) {
        fprintf(stderr, "%s: no manifest.json (not an .mlimg?)\n", path);
        unmap_file(img, img_len);
        return 1;
    }

    struct manifest m;
    if (manifest_parse(manifest_data, manifest_len, &m) != 0) {
        unmap_file(img, img_len);
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
    unmap_file(img, img_len);

    return ok ? 0 : 1;
}

static int cmd_dry_run(const char *path, const char *want_slot)
{
    size_t img_len = 0;
    unsigned char *img = map_file(path, &img_len);
    if (!img) {
        return 1;
    }

    const unsigned char *manifest_data;
    size_t manifest_len;
    if (tar_find(img, img_len, "manifest.json", &manifest_data, &manifest_len) != 0) {
        fprintf(stderr, "%s: no manifest.json\n", path);
        unmap_file(img, img_len);
        return 1;
    }

    struct manifest m;
    if (manifest_parse(manifest_data, manifest_len, &m) != 0) {
        unmap_file(img, img_len);
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
        printf("  ABORT: GPT-active and running slot disagree (post-flip / flashboot window); "
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

    /* Board gate: manifest target_device vs the device's own product id. */
    int board = board_matches(m.target_device);
    printf("manifest target_device:       %s\n", m.target_device);
    printf("device product id:            %s\n",
           board < 0 ? "UNKNOWN (no sdk_version.json; open slot B)"
                     : board ? "matches" : "MISMATCH");
    if (board == 0) {
        printf("  ABORT: image targets %s but this device is a different product.\n",
               m.target_device);
        fail = 1;
    }

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
    unmap_file(img, img_len);

    return fail ? 1 : 0;
}

/*
 * Preflight the bundle against the device (no writes): parse the manifest, establish the running
 * slot and cross-check it against the GPT active bit, pick the target (inactive) slot, gate on
 * board identity, and verify every component's hash, write method, and target partition. On a
 * clean pass fills `m`, `devpath` (one resolved /dev/mtdN per component), and `*target`; returns
 * 0. Returns 1 (message already printed) on any blocker.
 *
 * `force_a` relaxes the slot-A refusal to allow writing an INACTIVE slot A (only while running on
 * B); it never lets the target equal the running slot.
 */
static int flash_preflight(const unsigned char *img, size_t img_len, const char *want_slot,
                           int force_a, struct manifest *m, char devpath[][32], int *target)
{
    const unsigned char *manifest_data;
    size_t manifest_len;

    if (tar_find(img, img_len, "manifest.json", &manifest_data, &manifest_len) != 0) {
        fprintf(stderr, "flash: no manifest.json\n");
        return 1;
    }
    if (manifest_parse(manifest_data, manifest_len, m) != 0) {
        return 1;
    }

    int running = running_slot();
    int gpt = gpt_active_slot();
    if (running < 0) {
        fprintf(stderr, "flash: cannot determine the running slot; refusing.\n");
        return 1;
    }

    if (gpt >= 0 && gpt != running) {
        fprintf(stderr, "flash: GPT-active and running slot disagree; resolve by hand.\n");
        return 1;
    }

    int tgt = want_slot ? ((want_slot[0] == 'b' || want_slot[0] == 'B') ? 1 : 0) : !running;
    if (tgt == running) {
        fprintf(stderr, "flash: target == running slot; cannot write the live slot.\n");
        return 1;
    }

    if (tgt == 0) {
        if (!force_a) {
            fprintf(stderr, "flash: refusing to write slot A without --force-a "
                    "(A is the BootROM-recovery keystone).\n");
            return 1;
        }
        if (running != 1) {
            fprintf(stderr, "flash: --force-a is allowed only while running on slot B "
                    "(so A is an inactive, recoverable target); running slot is %s.\n",
                    running == 0 ? "A" : "unknown");
            return 1;
        }
    }

    int board = board_matches(m->target_device);
    if (board == 0) {
        fprintf(stderr, "flash: image targets %s but this is a different board; refusing.\n",
                m->target_device);
        return 1;
    }

    if (board < 0) {
        fprintf(stderr, "flash: WARNING could not determine the device board "
                "(image targets %s); proceeding.\n", m->target_device);
    }

    for (int i = 0; i < m->ncomp; i++) {
        struct component *comp = &m->comp[i];
        const unsigned char *data;
        size_t data_len;
        char hex[65];

        if (tar_find(img, img_len, comp->file, &data, &data_len) != 0) {
            fprintf(stderr, "flash: missing member %s\n", comp->file);
            return 1;
        }

        sha256_hex(data, data_len, hex);
        if ((long long)data_len != comp->bytes || strcmp(hex, comp->sha256) != 0) {
            fprintf(stderr, "flash: %s image hash/size mismatch; refusing.\n", comp->name);
            return 1;
        }

        if (strcmp(comp->method, "mtdtool-raw") != 0 &&
            strcmp(comp->method, "ubiformat") != 0) {
            fprintf(stderr, "flash: %s uses unknown method '%s'; refusing.\n",
                    comp->name, comp->method);
            return 1;
        }

        if (slot_resolve_target(comp->target, tgt, (unsigned long)data_len,
                                devpath[i], sizeof devpath[i]) != 0) {
            return 1;
        }
    }

    *target = tgt;
    return 0;
}

/*
 * Commit a preflighted bundle: write each component to its resolved partition, readback-verifying
 * the raw partitions (env/dtb/kernel/uboot) before the next; the userapp rootfs goes through
 * ubiformat (which does its own per-eraseblock verification). Does NOT flip the active slot.
 * Returns 0 on success, 1 on the first write failure (leaving the slot partially written).
 */
static int flash_commit(const unsigned char *img, size_t img_len, const struct manifest *m,
                        char devpath[][32], int target)
{
    printf("flash: writing %d components to slot %s...\n", m->ncomp, target ? "B" : "A");

    for (int i = 0; i < m->ncomp; i++) {
        const struct component *comp = &m->comp[i];
        const unsigned char *data;
        size_t data_len;

        tar_find(img, img_len, comp->file, &data, &data_len);
        printf("  %-7s -> %s (%zu B, %s)\n", comp->name, devpath[i], data_len, comp->method);

        int wr;
        if (strcmp(comp->method, "ubiformat") == 0) {
            wr = ubi_write(devpath[i], data, data_len);
        } else {
            wr = mtd_write_verify(devpath[i], data, data_len, comp->sha256);
        }

        if (wr != 0) {
            fprintf(stderr, "flash: %s write FAILED; slot %s is now partially written.\n",
                    comp->name, target ? "B" : "A");
            return 1;
        }
    }

    printf("flash: OK - slot %s written and readback-verified. NOT flipped; prove it by "
           "flashboot (make flashboot), then flip by hand.\n", target ? "B" : "A");
    return 0;
}

/*
 * Warn (loudly, non-interactively) that --force-a is about to write the INACTIVE slot A. The
 * structural guards (--force-a required, running slot is B, mutual exclusion with --flip) live in
 * the preflight and arg parsing; this only surfaces the risk in the log.
 */
static void flash_warn_force_a(void)
{
    printf("\nflash: --force-a: writing the INACTIVE slot A.\n");
    printf("  Slot A is the BootROM-recovery keystone. This is only safe because you are running\n");
    printf("  on slot B (A is inactive) and this run cannot also flip. A partial or failed A write\n");
    printf("  is a mixed state that only BootROM recovery clears (glue/recovery/RECOVERY.md).\n");
}

/*
 * Flip the active slot to `target` after a verified flash. This makes a not-yet-booted slot the
 * active one (HARD RULE 2); the flag itself is the authorization (no prompt, so it can run
 * unattended). The gpt0 write is re-read to confirm the new active slot before declaring success.
 * Returns 0 on success, 1 otherwise.
 */
static int flash_flip(int target)
{
    printf("\nflash: --flip: making slot %s the ACTIVE boot slot.\n", target ? "B" : "A");
    printf("  A readback-verified flash proves the BYTES landed, NOT that the slot boots. Prove it\n");
    printf("  by flashboot first (make flashboot: boots the flashed kernel1/dtb1/rootfs, A stays\n");
    printf("  active); if a flipped slot does not boot, recover per glue/recovery/RECOVERY.md\n");
    printf("  (works while slot A is intact).\n");

    if (gpt_set_active(target) != 0) {
        return 1;
    }

    int now = gpt_active_slot();
    if (now != target) {
        fprintf(stderr, "flash: post-flip gpt0 readback shows active=%s (expected %s); "
                "verify by hand before rebooting.\n",
                now == 0 ? "A" : now == 1 ? "B" : "unknown", target ? "B" : "A");
        return 1;
    }

    printf("flash: OK - active slot is now %s (gpt0 re-read confirmed). Reboot via the watchdog "
           "to boot it.\n", target ? "B" : "A");
    return 0;
}

/*
 * Flash the bundle to the inactive slot (or --slot): preflight, then commit only on a clean pass,
 * then flip only if --flip and the commit succeeded. Owns the image buffer so the stages can
 * early-return without cleanup bookkeeping.
 */
static int cmd_flash(const char *path, const char *want_slot, int want_flip, int force_a)
{
    size_t img_len = 0;
    unsigned char *img = map_file(path, &img_len);
    if (!img) {
        return 1;
    }

    struct manifest m;
    char devpath[MAX_COMPONENTS][32];
    int target = -1;

    int rc = flash_preflight(img, img_len, want_slot, force_a, &m, devpath, &target);
    if (rc == 0 && target == 0) {
        flash_warn_force_a();
    }

    if (rc == 0) {
        rc = flash_commit(img, img_len, &m, devpath, target);
    }

    if (rc == 0 && want_flip) {
        rc = flash_flip(target);
    }

    unmap_file(img, img_len);
    return rc;
}

/*
 * Standalone flip (no image write): confirm the running/GPT slots agree, pick the inactive target
 * (or --slot), and flip it active via the same gpt_set_active + post-flip readback as --flash
 * --flip. This is the flip step of the flash -> flashboot -> flip workflow, so the slot was
 * already written and proven separately; it never touches partition data, only gpt0.
 */
static int cmd_flip(const char *want_slot)
{
    int running = running_slot();
    int gpt = gpt_active_slot();
    if (running < 0) {
        fprintf(stderr, "flip: cannot determine the running slot; refusing.\n");
        return 1;
    }

    if (gpt >= 0 && gpt != running) {
        fprintf(stderr, "flip: GPT-active and running slot disagree (still in a flashboot? reboot "
                "to the active slot first); refusing.\n");
        return 1;
    }

    int target = want_slot ? ((want_slot[0] == 'b' || want_slot[0] == 'B') ? 1 : 0) : !running;
    if (target == running) {
        fprintf(stderr, "flip: slot %s is already the running slot; nothing to flip.\n",
                target ? "B" : "A");
        return 1;
    }

    return flash_flip(target);
}

static void usage(void)
{
    fprintf(stderr,
            "usage:\n"
            "  mlflash --inspect <image.mlimg>              print manifest, re-verify hashes\n"
            "  mlflash --dry-run <image.mlimg> [--slot a|b] device preflight, no writes\n"
            "  mlflash --flash   <image.mlimg> [--slot a|b] [--flip] [--force-a]\n"
            "                                               flash the inactive slot, verify\n"
            "  mlflash --flip                  [--slot a|b] set the inactive slot active, no write\n"
            "    --flip     (with --flash) after a verified flash, set it active; or standalone\n"
            "               to flip an already-flashed+proven slot (overrides Rule 2; no prompt)\n"
            "    --force-a  permit writing an inactive slot A (only while running B; no prompt)\n");
}

int main(int argc, char **argv)
{
    const char *mode = NULL;
    const char *image = NULL;
    const char *slot = NULL;
    int want_flip = 0;
    int force_a = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--inspect") || !strcmp(argv[i], "--dry-run") ||
            !strcmp(argv[i], "--flash")) {
            mode = argv[i];
        } else if (!strcmp(argv[i], "--slot") && i + 1 < argc) {
            slot = argv[++i];
        } else if (!strcmp(argv[i], "--flip")) {
            want_flip = 1;
        } else if (!strcmp(argv[i], "--force-a")) {
            force_a = 1;
        } else if (argv[i][0] != '-') {
            image = argv[i];
        } else {
            fprintf(stderr, "unknown or unsupported option: %s\n", argv[i]);
            usage();
            return 2;
        }
    }

    if (slot && strcmp(slot, "a") && strcmp(slot, "A") &&
        strcmp(slot, "b") && strcmp(slot, "B")) {
        fprintf(stderr, "--slot must be a or b\n");
        return 2;
    }

    /* Standalone flip: --flip with no flash/inspect/dry-run mode and no image. */
    if (!mode && want_flip) {
        if (force_a) {
            fprintf(stderr, "--force-a does not apply to a standalone --flip (it writes no "
                    "partitions, only gpt0)\n");
            return 2;
        }
        return cmd_flip(slot);
    }

    if (!mode || !image) {
        usage();
        return 2;
    }

    /* --flip and --force-a only make sense for a real flash (or --flip standalone, above). */
    if ((want_flip || force_a) && strcmp(mode, "--flash")) {
        fprintf(stderr, "--flip and --force-a are only valid with --flash\n");
        return 2;
    }

    /* Keep slot A a recoverable keystone: never write A and flip in one run. */
    if (want_flip && force_a) {
        fprintf(stderr, "--flip and --force-a are mutually exclusive "
                "(writing A and flipping in one run would leave no intact keystone)\n");
        return 2;
    }

    if (!strcmp(mode, "--inspect")) {
        return cmd_inspect(image);
    }

    if (!strcmp(mode, "--flash")) {
        return cmd_flash(image, slot, want_flip, force_a);
    }

    return cmd_dry_run(image, slot);
}
