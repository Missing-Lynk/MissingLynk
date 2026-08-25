#!/usr/bin/env python3
"""Print the compact UDP summary used by rf-net-bench.sh."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def load_iperf_json(path: Path) -> dict[str, object] | None:
    text = path.read_text()
    start = text.find("{")
    if start < 0:
        return None

    return json.loads(text[start:])


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {Path(argv[0]).name} <iperf-json>", file=sys.stderr)
        return 2

    path = Path(argv[1])
    try:
        data = load_iperf_json(path)
    except Exception as exc:  # noqa: BLE001 - this is a bench summarizer; keep the run moving.
        print(f"parse_error={exc}")
        return 0

    if data is None:
        print("parse_error=no_json_object")
        return 0

    end = data.get("end", {})
    if not isinstance(end, dict):
        print("no_udp_summary")
        return 0

    udp = end.get("sum_received", {}) or end.get("sum", {}) or end.get("sum_sent", {})
    if not isinstance(udp, dict):
        print("no_udp_summary")
        return 0

    bits = udp.get("bits_per_second")
    lost = udp.get("lost_packets")
    packets = udp.get("packets")
    jitter = udp.get("jitter_ms")
    lost_pct = udp.get("lost_percent")

    parts: list[str] = []
    if isinstance(bits, int | float):
        parts.append(f"mbit={bits / 1_000_000:.3f}")
    if isinstance(lost, int) and isinstance(packets, int):
        parts.append(f"lost={lost}/{packets}")
    if isinstance(lost_pct, int | float):
        parts.append(f"loss={lost_pct:.2f}%")
    if isinstance(jitter, int | float):
        parts.append(f"jitter_ms={jitter:.3f}")

    print(" ".join(parts) if parts else "no_udp_summary")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
