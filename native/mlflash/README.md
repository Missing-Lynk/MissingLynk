# mlflash - on-device .mlimg slot flasher

A single standalone static binary that flashes an `.mlimg` bundle (built by `glue/flash/mlimg.py`, see `docs/guides/building-a-flashable-image.md`) to a boot slot. It is the unsigned-image replacement for the vendor flasher, and runs on the goggle itself under either userspace (the vendor glibc slot and the open Alpine slot) with no host, no SSH, and no dependency on a binary already present on the running slot.

## Usage

```
mlflash --inspect <image.mlimg>              print the manifest, re-verify every component sha256
mlflash --dry-run <image.mlimg> [--slot a|b] device preflight (below); NO writes
mlflash --flash   <image.mlimg> [--slot a|b] flash the inactive slot, verify, no flip
```

`--inspect` needs no device; it parses the bundle and checks each component's hash (the same digests `mlimg.py inspect` prints).

`--flash` writes every component to the inactive slot behind a full preflight (running/GPT-slot agreement, target != running slot, board-identity match, and every component's hash/method/target resolved) - nothing is written unless all checks pass. The raw partitions (env/dtb/kernel/uboot) are written and SHA-256 readback-verified; the `userapp` rootfs is written through vendored mtd-utils `ubiformat` (bad-block skipping, PEB distribution, EC headers - not a raw write, so no byte-for-byte readback: the image bytes are verified against the manifest in preflight, correctness on-flash is ubiformat's own per-eraseblock write path). It does not flip the active slot. Slot-A writes (`--force-a`) and the flip (`--flip`) are not in this build yet.

`--dry-run` is the on-device preflight: it reads the running slot from `/proc/cmdline` (`ubi.mtd=`, name-resolved against `userapp0`/`userapp1`), cross-checks it against the GPT active bit in `gpt0` (hard-abort if they disagree), selects the target slot (the inactive one, or `--slot`), refuses a target equal to the running slot, resolves every component's target partition by name in `/proc/mtd`, and verifies the image hashes. It performs no writes.

## Layout

Sources live in `src/`:

| file | responsibility |
|------|----------------|
| `mlflash.c` | commands (`--inspect`, `--dry-run`) and `main` |
| `util.{h,c}` | file slurp, SHA-256 (OpenSSL), little-endian readers |
| `mlimg.{h,c}` | the `.mlimg` bundle: ustar tar reader + `manifest.json` (cJSON) |
| `slot.{h,c}` | A/B slot detection: mtd names, running slot, GPT active bit, guarded target resolve |
| `mtd.{h,c}` | raw MTD partition write + SHA-256 readback verify (mirrors `mtdtool`) |
| `ubi.{h,c}` | `userapp` UBI write: streams the image into vendored mtd-utils `ubiformat` |
| `board.{h,c}` | device-identity gate: manifest `target_device` vs the device's `product_version` |

Third-party deps are fetched into the shared `native/vendor/` (git-ignored, on the `-I` path), not committed and not under `src/`.

## How it works

An in-file ustar reader (`mlimg.c`) parses the `.mlimg` tar; `manifest.json` is parsed with cJSON, and components are verified with SHA-256 from OpenSSL `libcrypto`. Slot detection (`slot.c`) and the raw-partition writes (`mtd.c`) reuse the same MTD/GPT approach as `native/mtdtool.c`. The `userapp` UBI write (`ubi.c`) links vendored upstream mtd-utils `ubiformat` rather than reimplement the brick-capable NAND logic: `ubiformat`'s `main()` is compiled in as a callable function (`-Dmain=ubiformat_main`) and fed the in-memory image over a pipe (`-f - -S <len>`), so nothing spills to the goggle's tmpfs `/tmp`.

## Build dependencies

Three third-party deps, none committed into the tree:

- **OpenSSL `libcrypto`** (SHA-256) - linked statically; already present in the `gcc:7` build container, so nothing to install.
- **cJSON** (`manifest.json`) - fetched pinned + sha256-verified by `native/build.sh` into the shared, git-ignored `native/vendor/` (needs network on first build; cached after). Bump the version/hashes in `native/build.sh`.
- **mtd-utils** (`ubiformat` + libmtd/libubi/libubigen/libscan for the `userapp` UBI write) - fetched as the pinned + sha256-verified release tarball into `native/vendor/mtd-utils/` and compiled in statically. GPLv2; the vendored sources stay in `native/vendor/` (git-ignored), separate from our code. Bump the version/hash in `native/build.sh`.

## Safety

The write path is fenced by the project A/B slot rules (`CLAUDE.md`, `glue/docs/flash-and-verify-slots.md`): `--flash` writes only the inactive slot (target != running slot is asserted from `/proc/cmdline` and refused), and refuses slot A outright in this build. `--flash` never flips the active slot - prove the slot by RAM-boot first, then flip by hand. Writing slot A (`--force-a`, permitted only from a slot-B running system) and the active-slot flip (`--flip`, off by default, typed confirmation) are not in this build yet.

## Build

`native/build.sh` (arm64 gcc:7 container, static). Output: `native/build/mlflash` (git-ignored). Push it to the goggle to run.
