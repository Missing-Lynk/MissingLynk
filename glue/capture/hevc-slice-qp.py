#!/usr/bin/env python3
"""Read the QP each picture of an HEVC elementary stream was coded at.

SliceQpY = 26 + init_qp_minus26 (PPS) + slice_qp_delta (slice header). Neither value is in a fixed
byte position: both are Exp-Golomb coded after a variable-length prefix, so the SPS and PPS have to
be parsed to know how many bits precede them.

What each parse needs:

    SPS   chroma_format_idc, separate_colour_plane_flag, sample_adaptive_offset_enabled_flag
    PPS   num_extra_slice_header_bits, output_flag_present_flag,
          dependent_slice_segments_enabled_flag, init_qp_minus26

An IRAP slice header is short: first_slice_segment_in_pic_flag is 1 so there is no segment address,
and an IDR carries no POC and no reference picture set, so slice_qp_delta is reached without
parsing a short-term RPS. Inter slices are parsed far enough to reject rather than guess: a P slice
header carries ref-list and weighted-prediction syntax whose length depends on state this tool does
not track, so those report their QP as unknown.

The vendor's own SEI reports QP 0 for FrameId 0 and is not a usable source for the first picture on
either side; this reads the slice header instead.

Usage:
    hevc-slice-qp.py FILE.h265 [FILE.h265 ...] [--limit N]

Reference: assoc-arm.c0.h265 (vendor air unit) reads init_qp_minus26 0, slice_qp_delta 9, QP 35.
"""
import sys
from collections.abc import Iterator

NAL_NAMES = {
    19: "IDR_W_RADL", 20: "IDR_N_LP", 21: "CRA", 32: "VPS", 33: "SPS", 34: "PPS",
    35: "AUD", 36: "EOS", 37: "EOB", 38: "FD", 39: "PREFIX_SEI", 40: "SUFFIX_SEI",
}

IRAP_LO, IRAP_HI = 16, 23
IDR_TYPES = (19, 20)


class Bits:
    """Bit reader over an RBSP, i.e. after emulation-prevention bytes are removed."""

    def __init__(self, data: bytes) -> None:
        self.d = data
        self.p = 0

    def u(self, n: int) -> int:
        v = 0
        for _ in range(n):
            byte = self.p >> 3
            if byte >= len(self.d):
                raise EOFError("ran off the end of the NAL")

            v = (v << 1) | ((self.d[byte] >> (7 - (self.p & 7))) & 1)
            self.p += 1

        return v

    def ue(self) -> int:
        n = 0
        while self.u(1) == 0:
            n += 1
            if n > 32:
                raise ValueError("Exp-Golomb prefix over 32 bits")

        return (1 << n) - 1 + (self.u(n) if n else 0)

    def se(self) -> int:
        k = self.ue()
        return (k + 1) // 2 if k & 1 else -(k // 2)


def unescape(nal: bytes) -> bytes:
    """Strip emulation-prevention bytes: 00 00 03 -> 00 00."""
    out = bytearray()
    zeros = 0
    for b in nal:
        if zeros >= 2 and b == 3:
            zeros = 0
            continue

        out.append(b)
        zeros = zeros + 1 if b == 0 else 0

    return bytes(out)


def nal_units(data: bytes) -> Iterator[tuple[int, int, bytes]]:
    """Yield (offset, header_len, payload) for every NAL, both 3- and 4-byte start codes."""
    starts = []
    i = 0
    while True:
        i = data.find(b"\x00\x00\x01", i)
        if i < 0:
            break

        four = i > 0 and data[i - 1] == 0
        starts.append((i - 1 if four else i, 4 if four else 3))
        i += 3

    for k, (off, sc) in enumerate(starts):
        end = starts[k + 1][0] if k + 1 < len(starts) else len(data)
        yield off, sc, data[off + sc:end]


def profile_tier_level(r: Bits, max_sub_layers_minus1: int) -> None:
    r.u(2 + 1 + 5)
    r.u(32)
    r.u(4)
    r.u(44)
    r.u(8)

    present = []
    for _ in range(max_sub_layers_minus1):
        present.append((r.u(1), r.u(1)))

    if max_sub_layers_minus1 > 0:
        for _ in range(max_sub_layers_minus1, 8):
            r.u(2)

    for prof, lvl in present:
        if prof:
            r.u(2 + 1 + 5)
            r.u(32)
            r.u(4)
            r.u(44)

        if lvl:
            r.u(8)


def scaling_list_data(r: Bits) -> None:
    for size_id in range(4):
        step = 3 if size_id == 3 else 1
        for _ in range(0, 6, step):
            if not r.u(1):
                r.ue()
            else:
                coefs = min(64, 1 << (4 + (size_id << 1)))
                if size_id > 1:
                    r.se()

                for _ in range(coefs):
                    r.se()


def parse_sps(rbsp: bytes) -> dict[str, int]:
    r = Bits(rbsp)
    r.u(16)                                     # NAL header
    r.u(4)                                      # sps_video_parameter_set_id
    max_sub = r.u(3)
    r.u(1)                                      # sps_temporal_id_nesting_flag
    profile_tier_level(r, max_sub)
    r.ue()                                      # sps_seq_parameter_set_id

    chroma_format_idc = r.ue()
    separate_colour_plane_flag = r.u(1) if chroma_format_idc == 3 else 0
    width = r.ue()
    height = r.ue()
    if r.u(1):                                  # conformance_window_flag
        for _ in range(4):
            r.ue()

    r.ue()                                      # bit_depth_luma_minus8
    r.ue()                                      # bit_depth_chroma_minus8
    r.ue()                                      # log2_max_pic_order_cnt_lsb_minus4

    sub_layer_ordering = r.u(1)
    for _ in range(0 if sub_layer_ordering else max_sub, max_sub + 1):
        r.ue()
        r.ue()
        r.ue()

    for _ in range(6):                          # the six log2 CB/TB size fields
        r.ue()

    if r.u(1) and r.u(1):                       # scaling_list_enabled, sps_..._data_present
        scaling_list_data(r)
    r.u(1)                                      # amp_enabled_flag
    sao = r.u(1)                                # sample_adaptive_offset_enabled_flag

    return {
        "chroma_array_type": 0 if separate_colour_plane_flag else chroma_format_idc,
        "sao": sao,
        "width": width,
        "height": height,
    }


def parse_pps(rbsp: bytes) -> dict[str, int]:
    r = Bits(rbsp)
    r.u(16)                                     # NAL header
    r.ue()                                      # pps_pic_parameter_set_id
    r.ue()                                      # pps_seq_parameter_set_id
    dependent = r.u(1)
    output_flag_present = r.u(1)
    extra_bits = r.u(3)
    r.u(1)                                      # sign_data_hiding_enabled_flag
    r.u(1)                                      # cabac_init_present_flag
    r.ue()                                      # num_ref_idx_l0_default_active_minus1
    r.ue()                                      # num_ref_idx_l1_default_active_minus1
    init_qp_minus26 = r.se()

    return {
        "dependent": dependent,
        "output_flag_present": output_flag_present,
        "extra_bits": extra_bits,
        "init_qp_minus26": init_qp_minus26,
    }


def slice_qp_delta(rbsp: bytes, nal_type: int, sps: dict[str, int],
                   pps: dict[str, int]) -> int | None:
    """slice_qp_delta of an IRAP slice, or None for a slice this tool will not parse."""
    if not (IRAP_LO <= nal_type <= IRAP_HI):
        return None

    r = Bits(rbsp)
    r.u(16)                                     # NAL header
    first = r.u(1)
    if not first:
        return None
    r.u(1)                                      # no_output_of_prior_pics_flag
    r.ue()                                      # slice_pic_parameter_set_id

    for _ in range(pps["extra_bits"]):
        r.u(1)

    slice_type = r.ue()
    if slice_type != 2:                         # 2 = I; an IRAP carries nothing else
        return None

    if pps["output_flag_present"]:
        r.u(1)                                  # pic_output_flag

    if nal_type not in IDR_TYPES:               # CRA carries POC and an RPS
        return None

    if sps["sao"]:
        r.u(1)                                  # slice_sao_luma_flag
        if sps["chroma_array_type"] != 0:
            r.u(1)                              # slice_sao_chroma_flag

    return r.se()


def scan(path: str, limit: int) -> int:
    with open(path, "rb") as fh:
        data = fh.read()
    sps = pps = None
    au_bytes = 0
    au_first_vcl = None
    pictures = []
    fail = None

    def flush() -> None:
        if au_first_vcl is not None:
            pictures.append((au_first_vcl[0], au_first_vcl[1], au_bytes))

    for off, sc, payload in nal_units(data):
        if len(payload) < 2:
            continue

        nal_type = (payload[0] >> 1) & 0x3F
        vcl = nal_type < 32

        if vcl and au_first_vcl is not None:
            flush()
            au_bytes = 0
            au_first_vcl = None

        au_bytes += sc + len(payload)

        if nal_type == 33:
            try:
                sps = parse_sps(unescape(payload))
            except (EOFError, ValueError) as exc:
                fail = fail or f"SPS: {exc}"
        elif nal_type == 34:
            try:
                pps = parse_pps(unescape(payload))
            except (EOFError, ValueError) as exc:
                fail = fail or f"PPS: {exc}"
        elif vcl and au_first_vcl is None:
            qp = None
            if sps is not None and pps is not None:
                try:
                    delta = slice_qp_delta(unescape(payload), nal_type, sps, pps)
                    if delta is not None:
                        qp = 26 + pps["init_qp_minus26"] + delta
                except (EOFError, ValueError) as exc:
                    fail = fail or f"slice at {off}: {exc}"
            au_first_vcl = (nal_type, qp)

        if len(pictures) >= limit:
            break

    flush()

    print(f"{path}")
    if sps:
        print(f"  SPS {sps['width']}x{sps['height']}  sao={sps['sao']} "
              f"chroma_array_type={sps['chroma_array_type']}")

    if pps:
        print(f"  PPS init_qp_minus26={pps['init_qp_minus26']} "
              f"(base QP {26 + pps['init_qp_minus26']})  "
              f"extra_slice_header_bits={pps['extra_bits']}")

    if fail:
        print(f"  parse stopped: {fail}")

    for i, (nal_type, qp, size) in enumerate(pictures[:limit]):
        name = NAL_NAMES.get(nal_type, f"nal{nal_type}")
        shown = f"QP {qp}" if qp is not None else "QP -"
        print(f"  au {i:4d}  {name:11s} {size:8d} B  {shown}")

    return 0 if pictures else 1


def main(argv: list[str]) -> int:
    limit = 8
    paths = []
    i = 0
    while i < len(argv):
        if argv[i] == "--limit":
            i += 1
            limit = int(argv[i])
        else:
            paths.append(argv[i])
        i += 1

    if not paths:
        print(__doc__.strip().splitlines()[-4], file=sys.stderr)
        return 2

    rc = 0
    for p in paths:
        rc |= scan(p, limit)

    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
