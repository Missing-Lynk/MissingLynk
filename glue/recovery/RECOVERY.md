# ABSOLUTE LAST-RESORT RECOVERY: BootROM UART flash-writer (PROVEN on hardware)

Use this when the goggle is bricked and **nothing else works**: it won't boot to Linux, the SPL won't drop to U-Boot (the `0x0A106138` bit0 trick needs a running Linux), the SoC + flash are under a soldered EMI can (no clip/programmer), and the cold-boot `V1.4` menu rejects every handshake. This path needs only the **3 debug-UART wires (GND/RX/TX)** at 115200. It was used to recover a unit whose active A/B slot was flipped to a panicking B kernel (slot A intact).

This is the nuclear option: it RE's and drives the mask BootROM to run our own bare-metal code that rewrites NAND. Do not reach for it unless the simpler routes (serial getty, `devmem 0x0A106138|=1` + watchdog reset to U-Boot from a *booting* system) are impossible.

## Why it works (the chain, all RE-verified + tested)
1. The mask **BootROM** (`glue/recovery/bootrom-0x0.bin`, 32 KB @ phys 0x0, dumped from a working sibling unit's Linux via a `devmem` word-loop; `/dev/mem` blocks RAM but not the ROM).
2. Its cold-menu UART-download entry is the **7-byte ASCII magic `"0123456"`** (matched in the menu poll loop @0x6ec; on match @0x640 it replies `'Y'`/0x59).
3. After `'Y'` it speaks a **`0x55`-frame RAM-write protocol** (header `55 52 | len(2LE) | addr(8LE) | psum | 00 00 | hsum`, then payload; `len==4` & aligned -> 32-bit poke, else memcpy; `'Y'`/`'N'` ack each; `len==0` terminator). Writes ANY RAM/MMIO, no bounds.
4. The terminator makes the ROM validate a **`.GMI` image @0x100040** and `blr` to its entry. With secure-boot OFF (efuse 0x240000 bit21 == 0, the stock state), validation is just two forgeable additive sums, so we wrap our own code in a valid `.GMI` (`glue/recovery/gmi.py`).
5. Our payload drives the **AR9301 qspi controller @0x01e00000** (RE'd in `kernel/overlay/drivers/spi/spi-ar9301.c` / `re/kernel/ar9301-qspi-re.md`) to erase + program SPI-NAND directly, flipping `gpt0` (or rewriting any partition) with no OS at all.

## Tools (all in `glue/recovery/`)
- `bootrom_dl.py` entry + protocol. Modes: `--test` (one poke, to confirm the protocol is live), `--gmi <bin> <load_hex>` (download + execute a payload as `.GMI`).
- `gmi.py` builds a valid `.GMI` (self-test vector verified): `gmi.py selftest`.
- `payload/` `entry.S` (sets sp, calls `payload_main`), `payload_c.ld` (load @0x111000, stack after body), `rw.c` (read-only qspi probe), `flash_writer.c` (the erase/program/verify writer), `data.S` (`.incbin` of the gpt0 image to write).
- `bootrom-0x0.bin` the BootROM dump (re-pull from a working unit if missing; see below).
- Target image: `out/P1_GND/mtd5-gpt0.bin`, the **A-active gpt0** (verified kernel0/userapp0 active). Writing it back flips the active slot to A.

## Procedure (recover slot A, what was actually done)

**Build the writer** (toolchain: `aarch64-linux-gnu-{gcc,objcopy}`):
```
aarch64-linux-gnu-gcc -nostdlib -nostartfiles -ffreestanding -O2 -fno-stack-protector -Wa,-I. \
  -Wl,-Tglue/recovery/payload/payload_c.ld \
  glue/recovery/payload/entry.S glue/recovery/payload/flash_writer.c glue/recovery/payload/data.S \
  -o glue/recovery/payload/flash_writer.elf
aarch64-linux-gnu-objcopy -O binary glue/recovery/payload/flash_writer.elf glue/recovery/payload/flash_writer.bin
```
(`flash_writer.c` targets gpt0 = flash 0x100000 = blocks 8,9 = pages 512..639. To rewrite a different partition, change the block/page constants and `data.S`'s `.incbin`.)

**De-risk first (READ test)**, proves the qspi works in this environment before any erase:
```
# build rw.c into readtest.bin the same way as flash_writer above (rw.c in place of the .c files), then:
./.venv/bin/python glue/recovery/bootrom_dl.py --gmi glue/recovery/payload/readtest.bin 0x111000
# power-cycle once; expect:  RD rc=00 magic@0x200='EFI PART'
```

**Write** (verify-gated, re-runnable; the magic entry is in mask ROM, so a half-write is fine):
```
./.venv/bin/python glue/recovery/bootrom_dl.py --gmi glue/recovery/payload/flash_writer.bin 0x111000
```
Power-cycle the goggle ONCE right after it starts (catches the brief BootROM window, it spams `0123456` for ~45 s). The ~260 KB body streams at 115200 (~25-30 s, baud-limited; progress `0xNNNN/0x40d20`). Then it runs and prints:
```
PRECHECK ok; unlocking + erasing gpt0 blocks 8,9...
programming 128 pages...
verifying...
WRITE+VERIFY OK -- gpt0 restored to slot A. POWER-CYCLE to boot stock A.
```
`WRITE+VERIFY OK` = every page read back byte-perfect. **Cold power-cycle -> boots stock A.**

## Re-dumping the BootROM (if `bootrom-0x0.bin` is missing)
From a WORKING sibling goggle over SSH (`root`/`artosyn` @ 192.168.3.100, legacy crypto):
```
ssh ... 'for a in $(seq 0 4 32764); do busybox devmem $a; done'   # -> 8192 hex words
# rebuild: struct.pack('<I', word) for each -> 32768-byte bootrom-0x0.bin
```
(`dd /dev/mem` HANGS on this SoC and busybox has no base64/timeout, word-loop is the only way.)

## Gotchas (each cost real time)
- The ACK is **1 byte**: read exactly 1, or every frame eats a 0.6 s timeout (~100 s for 260 KB).
- The payload inherits the BootROM's **115200** baud (it doesn't reconfigure), monitor at 115200. (The stock SPL output is at 1152000 because the SPL re-sets the console.)
- Load payloads at **0x111000** (must be in `[0x110000, 0x1fffff]`); the GMI section load+size must stay `<= 0x1fffff`.
- qspi quirk: RX-tail polarity, spin WHILE FIFOSTAT bit7 (RX-EMPTY) is SET, pop on CLEAR.
- Run a small purpose-built payload, not the full stock SPL (it stalls in its own DRAM/flash bring-up here).

## Standing lesson
**Never flip the active A/B slot to B until B's autonomous boot is proven end-to-end.** The "failed B boot falls back to A" safety only holds while A is active. See [[never-flip-slot-unproven]]. Validate slot-B changes by RAM-boot only (`loady`+`bootm`) with A still active.
