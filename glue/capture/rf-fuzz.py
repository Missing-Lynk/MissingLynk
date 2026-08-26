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
  tile-swap    tile 1 arrives before tile 0    -> inverted half-frame order
  tile-drop    one half of a frame is missing  -> the pair can never complete
  tile-lag     one half arrives frames late    -> the pair resolves by eviction
  frame-rewind move a pair's FrameId back        -> a duplicate PTS inside one session
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
    "tile-swap", "tile-drop", "tile-lag", "frame-rewind",
    "hdr-magic", "hdr-crc", "hdr-len",
)

# The transport modes act on whole datagrams, so `all` splits into the two families and applies
# a payload-corrupting mode and a transport mode independently, the way a bad link damages both.
ES_MODES = ("es-bitflip", "es-zero", "es-truncate", "idr-kill", "hdr-magic", "hdr-crc", "hdr-len")
TRANSPORT_MODES = ("drop", "dup", "reorder")
TILE_MODES = ("tile-swap", "tile-drop", "tile-lag", "frame-rewind")

# How far back frame-rewind moves a FrameId. ml-pipeline treats a regression of MORE than 8 as a new
# air session (mlp-rf.c: `frame_id < c->last_fid - 8`), which bumps pts_epoch and re-arms the IDR
# gate - a different code path entirely. Staying inside the window keeps the frame in the CURRENT
# session and lets it collide with an earlier one instead.
REWIND_MAX = 8

# How far a tile-lag half is pushed down the stream. Six video datagrams is about three composed
# frames, comfortably past the pairing window, so the pair is resolved by eviction rather than by
# arriving a little early.
LAG_RECORDS = 6


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


def chn_index(payload: bytes) -> int:
    """ChnIndex from the header: 0 = top tile, 1 = bottom tile. The receiver demuxes on this."""
    return struct.unpack_from("<I", payload, 8)[0]


def frame_id(payload: bytes) -> int:
    """FrameId from the header. The two tiles of one composed frame share it."""
    return struct.unpack_from("<I", payload, 16)[0]


def frame_groups(records: list[Record]) -> dict[int, dict[int, int]]:
    """{frame_id: {chn: record index}} over the video records, for the tile-level modes.

    Only the FIRST record of a given (frame, channel) is indexed. A tile is one access unit in one
    datagram at this layer, so a second one is a duplicate rather than a continuation, and the
    tile modes act on the datagram the receiver would pair with.
    """
    groups: dict[int, dict[int, int]] = {}
    for index, record in enumerate(records):
        if not record.is_video:
            continue

        groups.setdefault(frame_id(record.payload), {}).setdefault(
            chn_index(record.payload), index)

    return groups


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


def apply_tile_mode(records: list[Record], mode: str, rate: float,
                    rng: random.Random) -> tuple[list[Record], int]:
    """Damage a frame's two TILES rather than its datagrams, with probability `rate` per frame.

    The transport modes above work on datagrams and leave tile structure intact: `reorder` swaps two
    adjacent datagrams, which within one tile is arrival jitter and says nothing about which HALF of
    a composed frame reaches the compositor first. These modes act on the pair.

    They matter because the replay harnesses cannot produce any of this: every dump was captured
    with tile 0 ahead of tile 1 and `ml-rf-replay` plays a dump back verbatim, so the goggle has
    only ever been bench-tested against one arrival order with both halves always present. Over the
    air the two tiles are independent encodes of different sizes, so the order can invert and a
    half can simply not arrive.
    """
    hits = 0
    out = list(records)
    groups = frame_groups(out)

    if mode == "tile-swap":
        # Exchange the two halves' PAYLOADS rather than their positions, so the pair keeps its exact
        # inter-tile timing and only the order changes: the receiver sees tile 1 first.
        for chans in groups.values():
            if len(chans) < 2 or rng.random() >= rate:
                continue

            first, second = (out[chans[0]], out[chans[1]])
            out[chans[0]] = Record(first.delta_us, first.dport, second.payload)
            out[chans[1]] = Record(second.delta_us, second.dport, first.payload)
            hits += 1

        return out, hits

    if mode == "tile-drop":
        # One half of the frame never arrives, so the pair cannot complete and the slot must be
        # evicted. Distinct from `drop`, which deletes datagrams without regard to what that leaves
        # of a frame, and usually leaves the pair intact at these rates.
        doomed: set[int] = set()
        for chans in groups.values():
            if len(chans) < 2 or rng.random() >= rate:
                continue

            doomed.add(chans[rng.choice(sorted(chans))])
            hits += 1

        return [r for i, r in enumerate(out) if i not in doomed], hits

    if mode == "tile-lag":
        # One half arrives far later than its partner: the pair either completes late or is evicted
        # while the other half is still held. Moves the record LAG_RECORDS later in the stream and
        # leaves the deltas attached to positions, the same timing model `reorder` uses.
        moves: list[tuple[int, bytes, int]] = []
        for chans in groups.values():
            if len(chans) < 2 or rng.random() >= rate:
                continue

            index = chans[rng.choice(sorted(chans))]
            moves.append((index, out[index].payload, out[index].dport))
            hits += 1

        if not moves:
            return out, hits

        drop_at = {index for index, _, _ in moves}
        kept = [(i, r) for i, r in enumerate(out) if i not in drop_at]
        rebuilt: list[Record] = []
        pending = {index + LAG_RECORDS: (payload, dport) for index, payload, dport in moves}
        for original, record in kept:
            rebuilt.append(record)
            late = pending.pop(original, None)
            if late is not None:
                rebuilt.append(Record(0, late[1], late[0]))

        for payload, dport in pending.values():   # lagged past the end of the dump
            rebuilt.append(Record(0, dport, payload))

        return rebuilt, hits

    if mode == "frame-rewind":
        # ml-pipeline pairs on PTS and derives PTS straight from FrameId
        # (mlp-rf.c: `pts = pts_epoch + frame_id * (1s / RF_FPS)`), so moving a pair's FrameId back
        # gives two different frames the same PTS within one session. That is the input the seam
        # scratch's collision detector is built to catch: band_region() indexes by slot and
        # seam_stamp[region] holds the pair's PTS, so two pairs that share a region AND a PTS are
        # exactly the case the stamp cannot tell apart.
        #
        # Both halves are rewritten, so the pair still pairs; a half-only rewrite would just
        # un-pair the frame, which tile-drop already covers.
        for chans in groups.values():
            if len(chans) < 2 or rng.random() >= rate:
                continue

            back = rng.randint(1, REWIND_MAX)
            for index in chans.values():
                payload = bytearray(out[index].payload)
                struct.pack_into("<I", payload, 16,
                                 max(0, frame_id(out[index].payload) - back))
                fix_crc(payload)
                out[index] = Record(out[index].delta_us, out[index].dport, bytes(payload))

            hits += 1

        return out, hits

    raise ValueError(f"not a tile mode: {mode}")


def fuzz(records: list[Record], mode: str, rate: float,
         rng: random.Random) -> tuple[list[Record], dict[str, int]]:
    """Apply one mode (or the `all` mix) and return the records and a per-mode hit tally."""
    tally: dict[str, int] = {}
    if mode == "all":
        payload_mode = rng.choice(ES_MODES)
        transport_mode = rng.choice(TRANSPORT_MODES)
        tile_mode = rng.choice(TILE_MODES)
        # Tile damage first: the tile modes index frames by header, and running them before the
        # payload corruption keeps that indexing over headers the ES modes have not rewritten.
        records, tally[tile_mode] = apply_tile_mode(records, tile_mode, rate, rng)
        records, tally[payload_mode] = apply_payload_mode(records, payload_mode, rate, rng)
        records, tally[transport_mode] = apply_transport_mode(records, transport_mode, rate, rng)
    elif mode in TILE_MODES:
        records, tally[mode] = apply_tile_mode(records, mode, rate, rng)
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
    # `fid`, not `frame_id`: the module-level frame_id() reader is in scope for the whole of
    # self_test, and a loop variable of that name shadows it for every later check.
    for fid in range(40):
        for chn in range(RF_NCHN):
            is_idr = 1 if fid % 20 == 0 else 0
            es = idr_es if is_idr else p_es
            base.append(Record(16667 if chn == 0 else 300, VIDEO_PORT,
                               build_video_payload(chn, is_idr, fid, es)))

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

    # Tile modes act on the PAIR, so each has its own contract on the frames it hits.
    groups_before = frame_groups(base)
    paired = [f for f, chans in groups_before.items() if len(chans) == 2]
    if not paired:
        failures.append("tile modes: the base capture has no frame carrying both tiles")
    else:
        # tile-swap keeps every datagram and every frame, and inverts the order within a pair.
        out, _ = fuzz(clone(), "tile-swap", 1.0, random.Random(19))
        if sum(1 for r in out if r.is_video) != video_before:
            failures.append("tile-swap: changed the datagram count")
        else:
            swapped = 0
            for frame in paired:
                chans = groups_before[frame]
                lo, hi = chans[0], chans[1]
                if chn_index(out[lo].payload) == 1 and chn_index(out[hi].payload) == 0:
                    swapped += 1

            if swapped != len(paired):
                failures.append(f"tile-swap: inverted {swapped} of {len(paired)} pairs")

        # tile-drop leaves exactly one half of every hit frame.
        out, tally = fuzz(clone(), "tile-drop", 1.0, random.Random(23))
        after = frame_groups(out)
        widowed = sum(1 for f in paired if len(after.get(f, {})) == 1)
        if tally.get("tile-drop") != len(paired) or widowed != len(paired):
            failures.append(f"tile-drop: {tally.get('tile-drop')} hits, {widowed} of "
                            f"{len(paired)} frames left with one half")

        # tile-lag keeps every datagram but moves one half away from its partner.
        out, _ = fuzz(clone(), "tile-lag", 1.0, random.Random(29))
        if sum(1 for r in out if r.is_video) != video_before:
            failures.append("tile-lag: changed the datagram count")
        else:
            moved = 0
            after = frame_groups(out)
            for frame in paired:
                chans = after.get(frame, {})
                if len(chans) == 2 and abs(chans[0] - chans[1]) > 1:
                    moved += 1

            if moved == 0:
                failures.append("tile-lag: left every pair adjacent")

        # frame-rewind keeps every datagram, keeps both halves together, moves the pair's
        # FrameId back, and leaves a header the receiver still accepts (the CRC covers it).
        out, _ = fuzz(clone(), "frame-rewind", 1.0, random.Random(31))
        if sum(1 for r in out if r.is_video) != video_before:
            failures.append("frame-rewind: changed the datagram count")
        else:
            moved_back = 0
            for frame in paired:
                chans = groups_before[frame]
                new_ids = {frame_id(out[i].payload) for i in chans.values()}
                if len(new_ids) != 1:
                    failures.append("frame-rewind: split a pair across two FrameIds")
                    break

                if new_ids.pop() < frame:
                    moved_back += 1
            else:
                # FrameId 0 has nowhere to go: the rewind clamps at zero rather than wrapping into
                # the huge value an unsigned underflow would give, which the receiver would read as
                # a forward jump rather than a collision.
                expect = sum(1 for f in paired if f > 0)
                if moved_back != expect:
                    failures.append(f"frame-rewind: moved {moved_back} of {expect} rewindable pairs")
            for record in out:
                if not record.is_video:
                    continue

                reaches, why = header_passes_receiver(record.payload, len(record.payload))
                if not reaches:
                    failures.append(f"frame-rewind: header stopped passing the guard ({why})")
                    break

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
          "(framing, CRC model, guard outcomes, transport counts, tile pairs, round-trip)")
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
