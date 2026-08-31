# mlflash - on-device .mlimg slot flasher

A single standalone static binary that flashes an `.mlimg` bundle (built by `glue/flash/mlimg.py`, see `docs/guides/building-a-flashable-image.md`) to a boot slot. It is the unsigned-image replacement for the vendor flasher, and runs on the goggle itself under either userspace (the vendor glibc slot and the open Alpine slot) with no host, no SSH, and no dependency on a binary already present on the running slot.

## Usage

```
mlflash --inspect <image.mlimg>              print the manifest, re-verify every component sha256
mlflash --dry-run <image.mlimg> [--slot a|b] device preflight (below); NO writes
mlflash --flash   <image.mlimg> [--slot a|b] [--flip] [--force-a]  flash the inactive slot, verify
mlflash --flip                  [--slot a|b] make the non-active slot active (no write, gpt0 only)
mlflash --slots                              print the A/B slot state + a classification of the
                                             flip target's contents as JSON; NO writes
mlflash --preflight                          print whether the inactive slot can be flashed at all
                                             as JSON; needs no image; NO writes
```

`--inspect` needs no device; it parses the bundle and checks each component's hash (the same digests `mlimg.py inspect` prints).

`--flash` writes every component to the inactive slot behind a full preflight (running/GPT-slot agreement, target != running slot, board-identity match, and every component's hash/method/target resolved) - nothing is written unless all checks pass. The raw partitions (env/dtb/kernel/uboot) are written and SHA-256 readback-verified; the `userapp` rootfs is written through vendored mtd-utils `ubiformat` (bad-block skipping, PEB distribution, EC headers - not a raw write, so no byte-for-byte readback: the member is verified against the manifest in preflight as stored, its gzip CRC-32 and declared length are checked as it inflates, and correctness on-flash is ubiformat's own per-eraseblock write path). By default it does NOT flip the active slot.

`--flip` makes the non-active slot active and re-reads `gpt0` to confirm; it writes only gpt0, never partition data. Use it standalone (`mlflash --flip`) as the last step of the flash -> flashboot -> flip workflow - flash the slot, prove it with a flashboot, then flip the already-proven slot without rewriting it - or combined (`--flash ... --flip`) to flip immediately after a verified flash. The target is the complement of the GPT-ACTIVE slot, so the flip works from either slot and from inside a flashboot, where the running slot is the flashed one and the target is the slot that is provably running; the only refusals are an unreadable `gpt0` and a target that is already active. (The write path is different: `--flash` still requires the running and GPT-active slots to agree.) A verified flash proves the bytes landed, not that the slot boots, so a flip can leave an unproven slot active (HARD RULE 2); prove the slot with a flashboot first (`make flashboot`, which boots the flashed kernel1/dtb1/rootfs with slot A still active). `--force-a` permits writing an INACTIVE slot A, allowed only while the running slot is B so slot A is never the live target. Both flags act on the flag alone (no interactive prompt, so mlflash can run unattended); the guardrails are structural: `--flip` and `--force-a` are mutually exclusive, so slot A always stays an intact, recoverable keystone.

`--slots` reports the running slot, the GPT-active slot, whether they agree (`consistent`: false = flashboot), and a read-only classification of the flip target's contents - the target being the complement of the GPT-ACTIVE slot, since that is the bit a flip moves: the dtb partition's root `model` property names the installed image (the open firmware's "Artosyn Proxima-9311 (BetaFPV ..." vs the stock "Artosyn, Proxima Development Board"), and the kernel (OTRA container magic; a kernel partition always holds the vendor OTRA+uImage container the SPL boots, never a raw arm64 Image) and userapp (UBI magic) heads confirm the slot is complete. One JSON object on stdout, e.g. `{"running":"A","gpt_active":"A","consistent":true,"target_slot":"B","target_content":"open","target_model":"...","target_kernel":true,"target_rootfs":true,"target_complete":true}`. The `target_*` keys are absent when `gpt0` could not be read (no defined flip direction). This is the host flasher's input for offering a slot switch; nothing is written.

`--preflight` answers "can this device flash its inactive slot at all", with no image in hand, as one JSON object on stdout: the running slot, the GPT-active slot, whether they agree, `flash_slot` (the slot a flash would write, i.e. the complement of the RUNNING slot, which is what `--flash` picks), and a per-partition guard verdict for every partition that slot owns - `uboot`, `env`, `kernel`, `dtb`, `userapp`, each `ok`, `missing`, `sibling` (its 0/1 counterpart resolves to the same mtd), `whole-flash` (resolved to mtd0), or `small`. Example: `{"running":"A","gpt_active":"A","consistent":true,"flash_slot":"B","targets":[{"name":"kernel1","status":"ok","mtd":14,"bytes":6291456}, ...],"targets_resolved":true}`. `targets` is empty when the flash slot is unknown, since there is then no partition to name. Exit is 0 when the running slot resolved, 1 otherwise; the JSON is printed either way, so parse before judging the exit status.

No policy is applied: `--preflight` reports what it found and the host decides what it means. This is the host flasher's gate for whether an image may even be selected, which is why it takes no image - the image-specific checks are `--dry-run`'s. Nothing is written.

`--dry-run` is the on-device preflight: it reads the running slot from `/proc/cmdline` (`ubi.mtd=`, name-resolved against `userapp0`/`userapp1`), cross-checks it against the GPT active bit in `gpt0` (hard-abort if they disagree), selects the target slot (the inactive one, or `--slot`), refuses a target equal to the running slot, resolves every component's target partition by name in `/proc/mtd`, and verifies the image hashes. It performs no writes.

## Layout

Sources live in `src/`:

| file | responsibility |
|------|----------------|
| `mlflash.c` | commands (`--inspect`, `--dry-run`) and `main` |
| `util.{h,c}` | file slurp, SHA-256 (OpenSSL), little-endian readers |
| `mlimg.{h,c}` | the `.mlimg` bundle: ustar tar reader + `manifest.json` (cJSON) |
| `slot.{h,c}` | A/B slots: mtd names, running slot, GPT active bit (read + flip), guarded target resolve/judge |
| `probe.{h,c}` | read-only slot content classification: dtb model string, kernel/rootfs magics |
| `mtd.{h,c}` | raw MTD partition write + SHA-256 readback verify (mirrors `mtdtool`) |
| `ubi.{h,c}` | `userapp` UBI write: streams the image into vendored mtd-utils `ubiformat` |
| `board.{h,c}` | device-identity gate: manifest `target_device` vs the device's `product_version` |

Third-party deps are fetched into the shared `native/vendor/` (git-ignored, on the `-I` path), not committed and not under `src/`.

## How it works

An in-file ustar reader (`mlimg.c`) parses the `.mlimg` tar; `manifest.json` is parsed with cJSON, and components are verified with SHA-256 from OpenSSL `libcrypto`. Slot detection (`slot.c`) and the raw-partition writes (`mtd.c`) reuse the same MTD/GPT approach as `native/mtdtool.c`. The `userapp` UBI write (`ubi.c`) links vendored upstream mtd-utils `ubiformat` rather than reimplement the brick-capable NAND logic: `ubiformat`'s `main()` is compiled in as a callable function (`-Dmain=ubiformat_main`) and fed the image over a pipe (`-f - -S <len>`), so nothing spills to the device's tmpfs `/tmp`.

That component is stored gzip-compressed in the bundle, which roughly halves it and is what lets a unit with no card hold the image in `/tmp` at all. A forked writer inflates it into the pipe a chunk at a time, so the inflated rootfs never exists whole anywhere. Which components are compressed follows from `method` (`ubiformat` yes, `mtdtool-raw` no), so the manifest carries no compression flag that could disagree; `sha256`/`bytes` describe the payload as it lands on flash and `stored_sha256`/`stored_bytes` the tar member. Preflight hashes the member as stored, which keeps every component verified before any is written without inflating anything. `native/tests/ubi-inflate.c` covers the writer (`make check-native`).

## Build dependencies

Three third-party deps, none committed into the tree:

- **OpenSSL `libcrypto`** (SHA-256) - linked statically; already present in the `gcc:7` build container, so nothing to install.
- **cJSON** (`manifest.json`) - fetched pinned + sha256-verified by `native/build.sh` into the shared, git-ignored `native/vendor/` (needs network on first build; cached after). Bump the version/hashes in `native/build.sh`.
- **mtd-utils** (`ubiformat` + libmtd/libubi/libubigen/libscan for the `userapp` UBI write) - fetched as the pinned + sha256-verified release tarball into `native/vendor/mtd-utils/` and compiled in statically. GPLv2; the vendored sources stay in `native/vendor/` (git-ignored), separate from our code. Bump the version/hash in `native/build.sh`.

## Safety

The write path is fenced by the project A/B slot rules (`glue/docs/flash-and-verify-slots.md`): `--flash` writes only the inactive slot (target != running slot is asserted from `/proc/cmdline` and refused). Slot A is refused unless `--force-a` is given, and `--force-a` is honoured only while the running slot is B (so A is always an inactive target, never the live one). The active-slot flip (`--flip`) is off by default; when given it re-reads `gpt0` to confirm the new active slot and prints the recovery path, because it can make an unproven slot active (HARD RULE 2). Neither `--flip` nor `--force-a` prompts - the flag is the authorization, so mlflash can run unattended - but `--flip` and `--force-a` are mutually exclusive, so a run can never both write slot A and flip: slot A stays an intact BootROM-recovery keystone. The gold-standard proof before any flip is a flashboot (`make flashboot` / `glue/boot/ram-boot-flashed-b.sh`), which boots the flashed kernel1/dtb1/rootfs from flash with the current slot still active. (It does not exercise the flashed uboot1/SPL - only the eventual flip does - which is why slot A stays the recovery net.)

## Build

`native/build.sh` (arm64 gcc:7 container, static). Output: `native/build/mlflash` (git-ignored). Push it to the goggle to run.

## Getting it onto the device

The goggle's SSH server is a legacy Dropbear that only speaks old algorithms, and a current OpenSSH client refuses them by default. Every `ssh`/`scp` invocation must re-enable them:

```
-o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1
-o HostKeyAlgorithms=+ssh-rsa,ssh-dss
-o PubkeyAcceptedAlgorithms=+ssh-rsa
-o Ciphers=+aes128-ctr,aes128-cbc,3des-cbc
-o MACs=+hmac-sha1
```

There is also no `scp` or sftp subsystem on the device, so copy by streaming the bytes over a plain SSH channel with `cat`. Address and password track the booted slot: stock slot A is `192.168.3.100` / `artosyn`, the open slot B (goggle) is `192.168.3.101` / `libre`. `mlflash` runs on either slot, so pick the address and password for whichever slot is currently booted (the examples below use the stock slot). `/tmp` is an exec-allowed tmpfs on the open slot; use any writable, exec-mounted path.

Put those options in a shell array, not a plain string: zsh (the goggle project's default shell) does not word-split an unquoted `$var`, so `ssh $STRING ...` collapses them into one bad `-o` argument. An array expanded as `"${sshopts[@]}"` works in both zsh and bash.

Push both the binary and the `.mlimg` to `/tmp` over SSH, one `cat` stream each - ideally with the video pipeline stopped, since a large sustained push concurrent with video can wedge the USB gadget. `mlflash` `mmap`s the image rather than copying it into the heap, so staging it in `/tmp` (tmpfs) costs only the file's own size in RAM, not double - which is why a tens-of-MB image loads fine on stock slot A:

```
sshopts=(-o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1
  -o HostKeyAlgorithms=+ssh-rsa,ssh-dss -o PubkeyAcceptedAlgorithms=+ssh-rsa
  -o Ciphers=+aes128-ctr,aes128-cbc,3des-cbc -o MACs=+hmac-sha1
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
img=mlimg-P1_GND_VR04-<ver>.tar
sshpass -p artosyn ssh "${sshopts[@]}" root@192.168.3.100 'cat > /tmp/mlflash && chmod +x /tmp/mlflash' < native/build/mlflash
sshpass -p artosyn ssh "${sshopts[@]}" root@192.168.3.100 "cat > /tmp/$img" < "$img"
```

`/tmp` is RAM-backed, so its pages are not reclaimable while the file sits there; on stock slot A (where the primary flash-B-from-A path runs) there is room, but the open slot B mounts a smaller `/tmp` tmpfs - if a large image will not fit there, stage it on the persistent `/usrdata` instead (mlflash reads it the same way). `glue/dev/push.sh native/build/mlflash` wraps the binary push (it defaults to the open slot B password `libre`; for stock slot A run `ROOT_PASS=artosyn glue/dev/push.sh native/build/mlflash`).

Then run it over the same SSH connection - start with the read-only checks before any write:

```
sshpass -p artosyn ssh "${sshopts[@]}" root@192.168.3.100 "/tmp/mlflash --inspect /tmp/$img"
sshpass -p artosyn ssh "${sshopts[@]}" root@192.168.3.100 "/tmp/mlflash --dry-run /tmp/$img"
sshpass -p artosyn ssh "${sshopts[@]}" root@192.168.3.100 "/tmp/mlflash --flash   /tmp/$img"
```

Then prove slot B before committing to it, and only then flip - attach the serial console first, since a flip is the one step that can leave an unbootable active slot:

```
make flashboot                       # host: boot the flashed kernel1/dtb1/rootfs, A still active; confirm B is reachable
# from inside the flashboot (or after rebooting back to A):
sshpass -p libre ssh "${sshopts[@]}" root@192.168.3.101 "/tmp/mlflash --flip"     # set B active (gpt0 only)
```

The flip targets the complement of the GPT-ACTIVE slot, so it can be issued from inside the flashboot itself (address and password are the flashbooted slot's) - no reboot back to A in between.

`--flip` and `--force-a` take no prompt - the flag alone authorizes the action, so these run fine over a non-interactive SSH command (suited to automation).
