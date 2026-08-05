#!/usr/bin/env python3
"""
Say whether two captures of the same scene differ, and by how much.

au-prove-camera.sh takes two live captures in one configuration to tell a live sensor from a
residual frame left in DRAM. A byte-identical pair means nothing is updating, which has read
as a good capture before. The caller handles the identical case; this quantifies the rest.

Sampled every 997 bytes rather than compared whole: the answer is "is anything moving", a
prime stride avoids aliasing against the frame's own row stride, and a full compare of two
3 MB planes buys no more certainty.

Usage: frame-movement.py <capture-a> <capture-b>
"""

import sys
from pathlib import Path

STRIDE = 997


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2

    a = Path(sys.argv[1]).read_bytes()
    b = Path(sys.argv[2]).read_bytes()
    n = min(len(a), len(b))
    diff = sum(1 for i in range(0, n, STRIDE) if a[i] != b[i])

    print(f"  DIFFER -> frames are updating "
          f"({100.0 * diff / (n // STRIDE + 1):.1f}% of sampled bytes changed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
