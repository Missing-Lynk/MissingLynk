#!/usr/bin/env python3
"""
rf-fuzz.py - rewrite a clean .rfdump into an adversarial one, to harden the goggle's video path.

Every existing replay harness plays a CLEAN capture: the same good bytes on the same schedule.
A real RF link does not. As signal degrades the air unit's datagrams arrive bit-flipped, short,
duplicated, reordered and dropped, and the goggle must count the damage and keep flipping, never
wedge. This tool produces exactly that feed: it reads a .rfdump (pcap-to-rfdump.py or
make-synth-session.py), corrupts the video datagrams (dport 10001) by a chosen mode at a chosen
rate, and writes a .rfdump that ml-rf-replay plays with no new device-side code.

What the receiver guards, and what it does not (mlp-rf.c):
  - a datagram shorter than the header, a bad MagicCode/TailMagicCode, a header CRC mismatch, an
    out-of-range channel, a zero or over-long declared length: all COUNTED and DROPPED.
  - the elementary-stream bytes themselves: handed straight to the wave5 decoder, unchecked.
The header CRC (bytes 32..35) covers ONLY the first 32 header bytes, so corrupting the ES leaves
the CRC valid and the garbage AU reaches the VPU. That is the freeze-relevant surface a
stale-CRC fuzzer would never touch, so es-* modes recompute nothing and hdr-* modes recompute
the CRC only when the intent is for the datagram to survive the guard.

Modes (one family per run, or `all` to interleave a mix):
  es-bitflip   flip a few ES bits            -> valid framing, corrupt HEVC into the decoder
  es-zero      ES -> zeros                    -> valid framing, empty NAL stream
  es-truncate  shrink the ES (len made to match, CRC fixed) -> a short AU into the decoder
  idr-kill     break the IDR nal_unit_type    -> au_has_idr fails, the tile never starts
  drop         delete whole datagrams         -> packet loss
  dup          repeat a datagram              -> a retransmit artifact
  reorder      swap adjacent datagrams        -> arrival jitter
  hdr-magic    corrupt MagicCode              -> must be dropped as bad_hdr
  hdr-crc      corrupt the CRC field          -> must be dropped as bad_crc
  hdr-len      lie about the declared length  -> must be dropped as bad_hdr

Grading a run (replay the output, watch the pipeline):
  A hardened pipeline shows rx_bad_hdr / rx_bad_crc / rx_dropped RISING while pushed/composed and
  the display flip counter keep advancing. A wedge - ping-dead, or the flip counter frozen with
  datagrams still arriving - is a real defect. `ml-pipeline: rf done. rx=... bad_hdr=... bad_crc=...
  pushed=... composed=...` is the on-device tally.

Usage:
  rf-fuzz.py in.rfdump out.rfdump --mode es-bitflip --rate 0.02 [--seed N]
  rf-fuzz.py --check                 # in-memory self-test, needs no dump and no device
"""
from __future__ import annotations

import argparse
import random
import struct
import sys
import zlib
from pathlib import Path

# Framing, kept in lockstep with ml-pipeline.h and the .rfdump record layout in
# make-synth-session.py. A record is (delta_us, dport, len) then len payload bytes; a video
# payload is a 36-byte header, the ES, and a 4-byte tail magic.
REC_HDR = struct.Struct("<IHH")     # delta_us, dport, len
VPH_LEN = 36                        # header through CRC
TAIL_LEN = 4
VPH_MAGIC = 0x12345678
VPH_TAIL_MAGIC = 0x87654321
RF_NCHN = 2
VIDEO_PORT = 10001

MODES = (
    "es-bitflip", "es-zero", "es-truncate", "idr-kill",
    "drop", "dup", "reorder",
    "hdr-magic", "hdr-crc", "hdr-len",
)

# The transport modes act on whole datagrams, so `all` splits into the two families and applies
# a payload-corrupting mode and a transport mode independently, the way a bad link damages both.
ES_MODES = ("es-bitflip", "es-zero", "es-truncate", "idr-kill", "hdr-magic", "hdr-crc", "hdr-len")
TRANSPORT_MODES = ("drop", "dup", "reorder")


class Record:
    """One .rfdump record: the inter-datagram gap, the destination port, and the payload."""

    def __init__(self, delta_us: int, dport: int, payload: bytes) -> None:
        self.delta_us: int = delta_us
        self.dport: int = dport
        self.payload: bytes = payload

    @property
    def is_video(self) -> bool:
        """True for a downlink video datagram long enough to carry a header."""
        return self.dport == VIDEO_PORT and len(self.payload) >= VPH_LEN + TAIL_LEN

    def pack(self) -> bytes:
        return REC_HDR.pack(self.delta_us, self.dport, len(self.payload)) + self.payload


def read_dump(path: Path) -> list[Record]:
    """Parse a .rfdump into records, stopping at the first truncated tail as the replayer does."""
    data = path.read_bytes()
    records: list[Record] = []
    offset = 0
    size = len(data)
    while offset + REC_HDR.size <= size:
        delta_us, dport, length = REC_HDR.unpack_from(data, offset)
        offset += REC_HDR.size
        if offset + length > size:
            break
        records.append(Record(delta_us, dport, data[offset:offset + length]))
        offset += length

    return records


def write_dump(path: Path, records: list[Record]) -> None:
    with open(path, "wb") as handle:
        for record in records:
            handle.write(record.pack())


def declared_stream_len(payload: bytes) -> int:
    """The header's StreamLen field (bytes 4..7), the length the receiver trusts."""
    return struct.unpack_from("<I", payload, 4)[0]


def fix_crc(payload: bytearray) -> None:
    """Recompute the header CRC over the first 32 bytes, so a header edit still passes the guard."""
    struct.pack_into("<I", payload, 32, zlib.crc32(bytes(payload[:32])) & 0xFFFFFFFF)


def es_span(payload: bytes) -> tuple[int, int]:
    """Byte range [start, end) of the elementary stream inside the payload, per the header length."""
    stream_len = declared_stream_len(payload)
    start = VPH_LEN
    end = min(start + stream_len, len(payload) - TAIL_LEN)
    return start, max(start, end)


def corrupt_es_bitflip(payload: bytes, rng: random.Random) -> bytes:
    """Flip one to eight bits somewhere in the ES; framing and CRC stay valid."""
    start, end = es_span(payload)
    if end <= start:
        return payload
    out = bytearray(payload)
    for _ in range(rng.randint(1, 8)):
        pos = rng.randrange(start, end)
        out[pos] ^= 1 << rng.randrange(8)
    return bytes(out)


def corrupt_es_zero(payload: bytes, rng: random.Random) -> bytes:
    """Replace the ES with zero bytes; the header, length and CRC are untouched and valid."""
    start, end = es_span(payload)
    if end <= start:
        return payload
    out = bytearray(payload)
    for pos in range(start, end):
        out[pos] = 0
    return bytes(out)


def corrupt_es_truncate(payload: bytes, rng: random.Random) -> bytes:
    """Shrink the ES to 10-90 percent, set StreamLen to match and fix the CRC, keep the tail.

    The datagram stays self-consistent (VPH_LEN + StreamLen <= len), so the receiver accepts it
    and the wave5 decoder gets a genuinely short access unit - the honest-short-read case.
    """
    start, end = es_span(payload)
    original = end - start
    if original <= 1:
        return payload
    keep = max(1, int(original * rng.uniform(0.1, 0.9)))
    out = bytearray(payload[:start + keep])
    struct.pack_into("<I", out, 4, keep)
    fix_crc(out)
    out += struct.pack("<I", VPH_TAIL_MAGIC)
    return bytes(out)


def corrupt_idr_kill(payload: bytes, rng: random.Random) -> bytes:
    """Rewrite the nal_unit_type of every IRAP NAL to a non-IRAP class, so au_has_idr fails.

    HEVC nal_unit_type is bits 6..1 of the byte after a start code; IRAP is 16..23. Setting the
    high type bit clears it (16..23 -> 48..55), so a started tile keeps decoding but a fresh tile
    can never satisfy the session-start IDR gate - the "video never comes up" failure.
    """
    start, end = es_span(payload)
    out = bytearray(payload)
    pos = start
    touched = False
    while pos + 4 < end:
        if out[pos] == 0 and out[pos + 1] == 0 and out[pos + 2] == 1:
            header_at = pos + 3
        elif out[pos] == 0 and out[pos + 1] == 0 and out[pos + 2] == 0 and out[pos + 3] == 1:
            header_at = pos + 4
        else:
            pos += 1
            continue
        if header_at < end:
            nal_type = (out[header_at] >> 1) & 0x3F
            if 16 <= nal_type <= 23:
                out[header_at] |= 0x40    # set type bit 5: 16..23 -> 48..55, no longer IRAP
                touched = True
        pos = header_at + 1

    return bytes(out) if touched else payload


def corrupt_hdr_magic(payload: bytes, rng: random.Random) -> bytes:
    """Corrupt MagicCode; the datagram must be dropped as bad_hdr. CRC left stale on purpose."""
    out = bytearray(payload)
    struct.pack_into("<I", out, 0, VPH_MAGIC ^ 0xFFFFFFFF)
    return bytes(out)


def corrupt_hdr_crc(payload: bytes, rng: random.Random) -> bytes:
    """Corrupt the CRC field; the datagram must be dropped as bad_crc."""
    out = bytearray(payload)
    struct.pack_into("<I", out, 32, (declared_stream_len(payload) ^ 0xDEADBEEF) & 0xFFFFFFFF)
    return bytes(out)


def corrupt_hdr_len(payload: bytes, rng: random.Random) -> bytes:
    """Lie about StreamLen (past the datagram) with a valid CRC; must be dropped as bad_hdr."""
    out = bytearray(payload)
    struct.pack_into("<I", out, 4, len(payload) + 4096)
    fix_crc(out)
    return bytes(out)


PAYLOAD_CORRUPTORS = {
    "es-bitflip": corrupt_es_bitflip,
    "es-zero": corrupt_es_zero,
    "es-truncate": corrupt_es_truncate,
    "idr-kill": corrupt_idr_kill,
    "hdr-magic": corrupt_hdr_magic,
    "hdr-crc": corrupt_hdr_crc,
    "hdr-len": corrupt_hdr_len,
}


def apply_payload_mode(records: list[Record], mode: str, rate: float,
                       rng: random.Random) -> tuple[list[Record], int]:
    """Corrupt each video payload with probability `rate`. Returns the records and a hit count."""
    corruptor = PAYLOAD_CORRUPTORS[mode]
    hits = 0
    for record in records:
        if record.is_video and rng.random() < rate:
            corrupted = corruptor(record.payload, rng)
            if corrupted is not record.payload:
                record.payload = corrupted
                hits += 1

    return records, hits


def apply_transport_mode(records: list[Record], mode: str, rate: float,
                         rng: random.Random) -> tuple[list[Record], int]:
    """Drop, duplicate or swap whole video datagrams with probability `rate`."""
    hits = 0
    if mode == "drop":
        kept: list[Record] = []
        for record in records:
            if record.is_video and rng.random() < rate:
                hits += 1
                continue
            kept.append(record)
        return kept, hits

    if mode == "dup":
        out: list[Record] = []
        for record in records:
            out.append(record)
            if record.is_video and rng.random() < rate:
                out.append(Record(0, record.dport, record.payload))  # arrives back to back
                hits += 1
        return out, hits

    if mode == "reorder":
        out = list(records)
        index = 0
        while index + 1 < len(out):
            if out[index].is_video and out[index + 1].is_video and rng.random() < rate:
                out[index], out[index + 1] = out[index + 1], out[index]
                hits += 1
                index += 2
            else:
                index += 1
        return out, hits

    raise ValueError(f"not a transport mode: {mode}")


def fuzz(records: list[Record], mode: str, rate: float,
         rng: random.Random) -> tuple[list[Record], dict[str, int]]:
    """Apply one mode (or the `all` mix) and return the records and a per-mode hit tally."""
    tally: dict[str, int] = {}
    if mode == "all":
        payload_mode = rng.choice(ES_MODES)
        transport_mode = rng.choice(TRANSPORT_MODES)
        records, tally[payload_mode] = apply_payload_mode(records, payload_mode, rate, rng)
        records, tally[transport_mode] = apply_transport_mode(records, transport_mode, rate, rng)
    elif mode in TRANSPORT_MODES:
        records, tally[mode] = apply_transport_mode(records, mode, rate, rng)
    else:
        records, tally[mode] = apply_payload_mode(records, mode, rate, rng)

    return records, tally


def build_video_payload(chn: int, is_idr: int, frame_id: int, es: bytes) -> bytes:
    """A valid video datagram payload, for the self-test (mirrors make-synth-session.py)."""
    header = struct.pack("<8I", VPH_MAGIC, len(es), chn, is_idr, frame_id,
                         frame_id * 1000 // 60, 0x07800438, VPH_TAIL_MAGIC)
    header += struct.pack("<I", zlib.crc32(header) & 0xFFFFFFFF)
    return header + es + struct.pack("<I", VPH_TAIL_MAGIC)


def header_passes_receiver(payload: bytes, datagram_len: int) -> tuple[bool, str]:
    """Model mlp-rf.c's guards: does this datagram reach the decoder, and if not, which counter."""
    if datagram_len < VPH_LEN:
        return False, "bad_hdr"
    magic, stream_len = struct.unpack_from("<I", payload, 0)[0], declared_stream_len(payload)
    tail = struct.unpack_from("<I", payload, 28)[0]
    crc = struct.unpack_from("<I", payload, 32)[0]
    if magic != VPH_MAGIC or tail != VPH_TAIL_MAGIC:
        return False, "bad_hdr"
    if (zlib.crc32(payload[:32]) & 0xFFFFFFFF) != crc:
        return False, "bad_crc"
    chn = struct.unpack_from("<I", payload, 8)[0]
    if chn >= RF_NCHN or stream_len == 0 or VPH_LEN + stream_len > datagram_len:
        return False, "bad_hdr"
    return True, "pushed"


def self_test() -> int:
    """Fuzz a synthetic dump with every mode and assert the receiver-guard outcome of each.

    No dump file and no device: the point is to prove the framing math and the guard model are
    right before the tool ever spends bench time.
    """
    rng = random.Random(1234)
    idr_es = b"\x00\x00\x01\x40\x01" + b"\x00\x00\x01\x26\x01" + bytes(rng.randrange(256)
                                                                       for _ in range(200))
    p_es = b"\x00\x00\x01\x02\x01" + bytes(rng.randrange(256) for _ in range(200))
    base: list[Record] = []
    for frame_id in range(40):
        for chn in range(RF_NCHN):
            is_idr = 1 if frame_id % 20 == 0 else 0
            es = idr_es if is_idr else p_es
            base.append(Record(16667 if chn == 0 else 300, VIDEO_PORT,
                               build_video_payload(chn, is_idr, frame_id, es)))
    # a control-plane record the fuzzer must never touch
    base.append(Record(500, 20001, b"hello-control-plane"))

    failures: list[str] = []

    def clone() -> list[Record]:
        return [Record(r.delta_us, r.dport, r.payload) for r in base]

    # Every video datagram in the clean dump must reach the decoder.
    for record in base:
        if record.is_video:
            reaches, _ = header_passes_receiver(record.payload, len(record.payload))
            if not reaches:
                failures.append("clean video datagram was rejected by the guard model")
                break

    # Control-plane record survives every mode untouched.
    for mode in MODES + ("all",):
        out, _ = fuzz(clone(), mode, 1.0, random.Random(7))
        control = [r for r in out if r.dport == 20001]
        if len(control) != 1 or control[0].payload != b"hello-control-plane":
            failures.append(f"{mode}: touched the control-plane record")

    # es-bitflip / es-zero: framing intact, still reaches the decoder (CRC covers only the header).
    for mode in ("es-bitflip", "es-zero", "es-truncate", "idr-kill"):
        out, tally = fuzz(clone(), mode, 1.0, random.Random(3))
        if tally.get(mode, 0) == 0:
            failures.append(f"{mode}: corrupted nothing at rate 1.0")
        for record in out:
            if not record.is_video:
                continue
            reaches, why = header_passes_receiver(record.payload, len(record.payload))
            if not reaches:
                failures.append(f"{mode}: a datagram stopped reaching the decoder ({why})")
                break

    # idr-kill: the IDR access unit must no longer carry an IRAP NAL for au_has_idr to find.
    first_idr = next((r for r in clone() if r.is_video
                      and struct.unpack_from("<I", r.payload, 12)[0] == 1), None)
    if first_idr is not None:
        killed, _ = fuzz([Record(first_idr.delta_us, first_idr.dport, first_idr.payload)],
                         "idr-kill", 1.0, random.Random(9))
        before, after = first_idr.payload, killed[0].payload
        if before == after:
            failures.append("idr-kill: left the IDR access unit unchanged")

    # hdr-* modes must all be REJECTED by a guard (that is their contract).
    for mode, expect in (("hdr-magic", "bad_hdr"), ("hdr-crc", "bad_crc"), ("hdr-len", "bad_hdr")):
        out, _ = fuzz(clone(), mode, 1.0, random.Random(11))
        for record in out:
            if not record.is_video:
                continue
            reaches, why = header_passes_receiver(record.payload, len(record.payload))
            if reaches or why != expect:
                failures.append(f"{mode}: expected {expect}, got {'pushed' if reaches else why}")
                break

    # Transport modes change the datagram COUNT the expected direction.
    video_before = sum(1 for r in base if r.is_video)
    for mode, relation in (("drop", "<"), ("dup", ">"), ("reorder", "==")):
        out, _ = fuzz(clone(), mode, 0.5, random.Random(13))
        video_after = sum(1 for r in out if r.is_video)
        ok = ((relation == "<" and video_after < video_before)
              or (relation == ">" and video_after > video_before)
              or (relation == "==" and video_after == video_before))
        if not ok:
            failures.append(f"{mode}: count {video_before} -> {video_after} broke {relation}")

    # A fuzzed dump round-trips through the record parser unchanged in structure.
    out, _ = fuzz(clone(), "all", 0.3, random.Random(17))
    blob = b"".join(r.pack() for r in out)
    reparsed = _parse_bytes(blob)
    if len(reparsed) != len(out):
        failures.append(f"round-trip: wrote {len(out)} records, parsed back {len(reparsed)}")

    if failures:
        for line in failures:
            print(f"[rf-fuzz self-test] FAIL: {line}", file=sys.stderr)
        return 1

    print("[rf-fuzz self-test] all checks passed "
          "(framing, CRC model, guard outcomes, transport counts, round-trip)")
    return 0


def _parse_bytes(data: bytes) -> list[Record]:
    """read_dump for an in-memory blob, for the self-test round-trip."""
    records: list[Record] = []
    offset = 0
    size = len(data)
    while offset + REC_HDR.size <= size:
        delta_us, dport, length = REC_HDR.unpack_from(data, offset)
        offset += REC_HDR.size
        if offset + length > size:
            break
        records.append(Record(delta_us, dport, data[offset:offset + length]))
        offset += length
    return records


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("infile", nargs="?", type=Path)
    parser.add_argument("outfile", nargs="?", type=Path)
    parser.add_argument("--mode", choices=(*MODES, "all"), default="es-bitflip")
    parser.add_argument("--rate", type=float, default=0.02,
                        help="per-video-datagram corruption probability (default 0.02)")
    parser.add_argument("--seed", type=int, default=0, help="RNG seed for a reproducible feed")
    parser.add_argument("--check", action="store_true",
                        help="run the in-memory self-test and exit; needs no dump and no device")
    args = parser.parse_args()

    if args.check:
        return self_test()

    if args.infile is None or args.outfile is None:
        parser.error("infile and outfile are required unless --check is given")
    if not 0.0 <= args.rate <= 1.0:
        parser.error("--rate must be in [0, 1]")

    records = read_dump(args.infile)
    video_total = sum(1 for r in records if r.is_video)
    if video_total == 0:
        raise SystemExit(f"{args.infile}: no video datagrams (dport {VIDEO_PORT}) to fuzz")

    rng = random.Random(args.seed)
    records, tally = fuzz(records, args.mode, args.rate, rng)
    write_dump(args.outfile, records)

    hit_summary = ", ".join(f"{mode} x{count}" for mode, count in tally.items())
    print(f"[rf-fuzz] {args.mode} @ rate {args.rate:g} seed {args.seed}: "
          f"{video_total} video datagrams in, corrupted {hit_summary} "
          f"-> {args.outfile} ({args.outfile.stat().st_size // 1024} KiB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
