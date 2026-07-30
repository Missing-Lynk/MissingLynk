#!/usr/bin/env python3
"""Emit ISP register writes for au-prove-camera.sh stage 5d.

    gen-block3d.py vendor [LO-HI]   the vendor's live values over a range
    gen-block3d.py table  [LO-HI]   what raising configure_upto to 2082 would write
    gen-block3d.py diff             EVERY differing ISP register, minus the exclusions

Range defaults to the 0x3d60-0x3e1c curve bank. Output is one "0xADDR 0xVALUE"
line per register, absolute addresses, ready for `ml-regdump -w`.

`vendor` and `table` are NOT the same over the default range, which is why both
exist: the table's copy of the bank carries a different first curve, so only 32
of its 44 writes land on the vendor's live value.

`diff` is the decisive experiment rather than another single page. It makes our
ISP match the vendor everywhere we safely can, so a picture that still does not
improve rules out the ISP register file as the cause and points at the
DMA-fetched tables or the absent 3A.

EXCLUSIONS exist because some registers are not configuration and writing them
mid-stream is either useless or harmful:

  0x0000        top control. The recorded bisect found that asserting its input
                enable bit breaks the geometry stage (0x7070 -> 0), so this one
                is genuinely dangerous, not merely pointless.
  0x0014        the table-fetch trigger. Writing it republishes and re-fetches.
  0x0020-0x0068 DMA table physical addresses. The vendor's addresses point into
                the vendor's own allocations; re-publishing them mid-stream
                would retrigger fetches against buffers we do not own.
"""

import os
import re
import sys

LO, HI = 0x3D60, 0x3E1C
ISP_BASE = 0x08C00000
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

HEADER = re.compile(r"^---\s+(\S+)\s+\+(\S+)\s+\((\d+) words\)")
LINE = re.compile(r"^\+(?:0[xX])?([0-9a-fA-F]+):\s+(.*)$")


def parse_dump(path):
    out, block, base = {}, None, 0
    with open(path) as fh:
        for raw in fh:
            h = HEADER.match(raw)
            if h:
                block, base = h.group(1), int(h.group(2), 16)
                continue
            m = LINE.match(raw)
            if not m or block != "isp":
                continue
            addr = base + int(m.group(1), 16)
            for i, w in enumerate(m.group(2).split()):
                out[addr + i * 4] = int(w, 16)
    return out


def parse_defaults(path):
    with open(path) as handle:
        src = handle.read()
    arrays = {}
    for mm in re.finditer(r"(\w+)\s*\[\s*\]\s*=\s*\{(.*?)\n\};", src, re.S):
        arrays[mm.group(1)] = [
            (int(a, 16), int(v, 16))
            for a, v in re.findall(r"\{\s*0x([0-9a-fA-F]+)\s*,\s*0x([0-9a-fA-F]+)", mm.group(2))
        ]
    return arrays


def excluded(off):
    return off == 0x0000 or off == 0x0014 or 0x0020 <= off <= 0x0068


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("vendor", "table", "diff", "sweep", "sweepreg"):
        sys.stderr.write(__doc__)
        return 2

    lo, hi = LO, HI
    if len(sys.argv) >= 3 and "-" in sys.argv[2]:
        a, b = sys.argv[2].split("-", 1)
        lo, hi = int(a, 0), int(b, 0)

    snap = os.path.join(REPO, "out/au-snapshot/registers.txt")
    if not os.path.exists(snap):
        sys.stderr.write(f"missing vendor snapshot: {snap}\n")
        return 1

    if sys.argv[1] == "sweepreg":
        # One GROUP per register, so a bring-up names the exact register rather than the page.
        # Restrict with a range or this emits 184 groups. Cumulative, same as `sweep`.
        ours_path = os.path.join(REPO, "out/au-snapshot/ours-registers-live.txt")
        ven, ours = parse_dump(snap), parse_dump(ours_path)
        n = 0
        for off in sorted(set(ven) & set(ours)):
            if ven[off] == ours[off] or excluded(off) or not (lo <= off <= hi):
                continue
            print(f"GROUP 0x{off:04x}")
            print(f"0x{ISP_BASE + off:08x} 0x{ven[off]:08x}")
            n += 1
        sys.stderr.write(f"sweepreg mode: {n} single-register groups in 0x{lo:04x}-0x{hi:04x}\n")
        return 0 if n else 1

    if sys.argv[1] == "sweep":
        # Same writes as `diff`, but grouped by page and emitted with GROUP markers so the
        # device can apply one page at a time and capture after each. The writes are
        # cumulative, so the first group whose capture jumps is the one that carries the fix.
        # This is what turns the bisect from one boot per page into a single bring-up.
        ours_path = os.path.join(REPO, "out/au-snapshot/ours-registers-live.txt")
        if not os.path.exists(ours_path):
            sys.stderr.write(f"missing our live dump: {ours_path}\n")
            return 1
        ven, ours = parse_dump(snap), parse_dump(ours_path)
        pages = {}
        for off in sorted(set(ven) & set(ours)):
            if ven[off] == ours[off] or excluded(off):
                continue
            pages.setdefault(off & ~0xFF, []).append(off)
        for page in sorted(pages):
            print(f"GROUP 0x{page:04x}")
            for off in pages[page]:
                print(f"0x{ISP_BASE + off:08x} 0x{ven[off]:08x}")
        sys.stderr.write(
            f"sweep mode: {sum(len(x) for x in pages.values())} writes in {len(pages)} page groups\n")
        return 0

    if sys.argv[1] == "diff":
        ours_path = os.path.join(REPO, "out/au-snapshot/ours-registers-live.txt")
        if not os.path.exists(ours_path):
            sys.stderr.write(f"missing our live dump: {ours_path}\n")
            return 1
        ven, ours = parse_dump(snap), parse_dump(ours_path)
        vals, skipped = {}, 0
        for off in sorted(set(ven) & set(ours)):
            if ven[off] == ours[off]:
                continue
            if excluded(off):
                skipped += 1
                continue
            vals[off] = ven[off]
        sys.stderr.write(f"diff mode: {len(vals)} writes, {skipped} excluded as unsafe/runtime\n")
    elif sys.argv[1] == "vendor":
        regs = parse_dump(snap)
        vals = {off: regs[off] for off in range(lo, hi + 4, 4)
                if off in regs and not excluded(off)}
    else:
        hdr = os.path.join(REPO, "kernel/overlay/drivers/media/artosyn/ar-isp-defaults.h")
        arrays = parse_defaults(hdr)
        full = {}
        for a, v in arrays["ar_isp_recovered"]:
            full[a] = v
        for a, v in arrays["ar_isp_setup_1080p60"]:
            full[a] = v
        vals = {off: full[off] for off in range(lo, hi + 4, 4)
                if off in full and not excluded(off)}

    if not vals:
        sys.stderr.write("no values found for the block\n")
        return 1

    for off in sorted(vals):
        print(f"0x{ISP_BASE + off:08x} 0x{vals[off]:08x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
