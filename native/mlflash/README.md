# mlflash - on-device .mlimg slot flasher

A single standalone static binary that flashes an `.mlimg` bundle (built by `glue/flash/mlimg.py`, see `docs/guides/building-a-flashable-image.md`) to a boot slot. It is the unsigned-image replacement for the vendor flasher, and runs on the goggle itself under either userspace (the vendor glibc slot and the open Alpine slot) with no host, no SSH, and no dependency on a binary already present on the running slot.

## Usage

```
mlflash --inspect <image.mlimg>          print the manifest, re-verify every component sha256
mlflash --dry-run <image.mlimg> [--slot a|b]   device preflight (below); NO writes
```

`--inspect` needs no device; it parses the bundle and checks each component's hash (the same digests `mlimg.py inspect` prints).

`--dry-run` is the on-device preflight: it reads the running slot from `/proc/cmdline` (`ubi.mtd=`, name-resolved against `userapp0`/`userapp1`), cross-checks it against the GPT active bit in `gpt0` (hard-abort if they disagree), selects the target slot (the inactive one, or `--slot`), refuses a target equal to the running slot, resolves every component's target partition by name in `/proc/mtd`, and verifies the image hashes. It performs no writes.

## Layout

Sources live in `src/`:

| file | responsibility |
|------|----------------|
| `mlflash.c` | commands (`--inspect`, `--dry-run`) and `main` |
| `util.{h,c}` | file slurp, SHA-256 (OpenSSL), little-endian readers |
| `mlimg.{h,c}` | the `.mlimg` bundle: ustar tar reader + `manifest.json` (cJSON) |
| `slot.{h,c}` | A/B slot detection: mtd names, running slot, GPT active bit |

Third-party deps are fetched into the shared `native/vendor/` (git-ignored, on the `-I` path), not committed and not under `src/`.

## How it works

An in-file ustar reader (`mlimg.c`) parses the `.mlimg` tar; `manifest.json` is parsed with cJSON, and components are verified with SHA-256 from OpenSSL `libcrypto`. Slot detection (`slot.c`) and the (future) raw-partition writes reuse the same MTD/GPT approach as `native/mtdtool.c`; the `userapp` UBI write in a later phase will link vendored upstream mtd-utils `ubiformat` rather than reimplement it.

## Build dependencies

Two third-party deps, neither committed into the tree:

- **OpenSSL `libcrypto`** (SHA-256) - linked statically; already present in the `gcc:7` build container, so nothing to install.
- **cJSON** (`manifest.json`) - fetched pinned + sha256-verified by `native/build.sh` into the shared, git-ignored `native/vendor/` (needs network on first build; cached after). Bump the version/hashes in `native/build.sh`.

## Safety (design intent for the write phases)

The write path is fenced by the project A/B slot rules (`CLAUDE.md`, `glue/docs/flash-and-verify-slots.md`): the default writes only the inactive slot while booted on A (slot B only); writing slot A requires an explicit `--force-a` plus a typed confirmation and is permitted only from a slot-B running system; the active-slot flip (`--flip`) is off by default and never happens without an explicit typed confirmation. Phase 1 has none of these paths yet.

## Build

`native/build.sh` (arm64 gcc:7 container, static). Output: `native/build/mlflash` (git-ignored). Push it to the goggle to run.
