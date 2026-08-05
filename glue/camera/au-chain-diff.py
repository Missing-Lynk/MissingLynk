#!/usr/bin/env python3
"""Diff two au-chain-capture.sh captures, section by section.

Usage: glue/camera/au-chain-diff.py out/au-chain/slotA.txt out/au-chain/slotB.txt

Both captures must have GATE-BEFORE = 0784043c. A capture taken while the VIF front end was
not measuring incoming video says nothing about anything downstream of the link, and comparing
against one is how earlier conclusions in this project went wrong.
"""

import re
import sys

# Sensor registers that drift at runtime on the vendor and are therefore expected to differ.
# Measured: on streaming slot A, 156 of 183 registers still hold exactly the value the vendor
# library programmed; every one of the 27 that moved lies in these two ranges. Our driver
# programs the same initial values and never updates them, so a difference here is the vendor
# adapting, not our stack being wrong. Do not chase these.
SENSOR_RUNTIME_RANGES = ((0x8200, 0x826f), (0x8550, 0x855f))


def sensor_runtime(reg):
    return any(lo <= reg <= hi for lo, hi in SENSOR_RUNTIME_RANGES)


def load(path):
    """{section: {key: value}} plus the two gate readings."""
    out, gates, section = {}, {}, None
    with open(path) as handle:
        lines = handle.read().splitlines()
    for line in lines:
        line = line.rstrip()
        m = re.match(r'GATE-(BEFORE|AFTER) (\S*)', line)
        if m:
            gates[m.group(1)] = m.group(2)
            continue

        m = re.match(r'SECTION (\S+)', line)
        if m:
            section = m.group(1)
            out[section] = {}
            continue

        if section is None:
            continue

        m = re.match(r'\+0x([0-9a-f]{4}): (.*)', line)
        if m:
            off = int(m.group(1), 16)
            for i, w in enumerate(m.group(2).split()):
                if re.fullmatch(r'[0-9a-f]{8}', w):
                    out[section][off + 4 * i] = w

            continue

        # sensor lines look like "0x3611 0x3611 = 0x30": the tool echoes the address.
        m = re.match(r'(0x[0-9a-f]{4})\s+0x[0-9a-f]{4}\s*=\s*(0x[0-9a-f]+)', line)
        if m and section == 'sensor':
            out[section][int(m.group(1), 16)] = m.group(2)

    # The gate line was empty in captures taken before the quoting fix. VIF 0x1f0 is inside
    # the vif section anyway, so derive it rather than trust the line: a missing gate must not
    # be reported as a dead link.
    if not gates.get('BEFORE') and 0x1f0 in out.get('vif', {}):
        gates['BEFORE'] = out['vif'][0x1f0]
        gates.setdefault('AFTER', out['vif'][0x1f0])

    return out, gates


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    a, ga = load(sys.argv[1])
    b, gb = load(sys.argv[2])

    print(f"slot A gate: {ga.get('BEFORE')} .. {ga.get('AFTER')}")
    print(f"slot B gate: {gb.get('BEFORE')} .. {gb.get('AFTER')}")
    for name, g in (("A", ga), ("B", gb)):
        if g.get('BEFORE') != '0784043c':
            print(f"\n*** slot {name} was not receiving video. This diff is not "
                  f"interpretable. ***")
    print()

    for sec in a:
        if sec not in b:
            continue

        common = sorted(set(a[sec]) & set(b[sec]))
        diff = [k for k in common if a[sec][k] != b[sec][k]]
        if sec == 'sensor':
            drift = [k for k in diff if sensor_runtime(k)]
            real = [k for k in diff if not sensor_runtime(k)]
            flag = "" if not real else "   <-- differs"
            print(f"{sec:16} compared {len(common):4d}  differ {len(real):4d}"
                  f"  (+{len(drift)} expected runtime drift){flag}")
            continue

        flag = "" if not diff else "   <-- differs"
        print(f"{sec:16} compared {len(common):4d}  differ {len(diff):4d}{flag}")

    for sec in a:
        if sec not in b:
            continue

        common = sorted(set(a[sec]) & set(b[sec]))
        diff = [k for k in common if a[sec][k] != b[sec][k]]
        if sec == 'sensor':
            diff = [k for k in diff if not sensor_runtime(k)]

        if not diff:
            continue

        print(f"\n=== {sec} ===")
        print(f"{'reg':10} {'slotA':>10} {'slotB':>10}")
        for k in diff:
            print(f"0x{k:04x}    {a[sec][k]:>10} {b[sec][k]:>10}")


if __name__ == '__main__':
    main()
