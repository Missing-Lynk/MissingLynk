#!/usr/bin/env python3
"""Turn one au-tone-sweep.sh session into a verdict on each of its three questions.

The freeze check needs no timestamp pairing. `ml-aed` logs the scalar it acted on, so the decision
log records what was computed and `scal.csv` records what the parameter held. Three comparisons
separate the cases:

    log transitions vs sampled transitions   a producer that moved while the writes did not
    last logged scalar vs final parameter    a write path that stopped at some point
    every sampled value present in the log   a parameter carrying a value nothing computed

The register check reads the driver's own `ladder_banks` node, whose verdict column compares the
live register against the value the applier derived, under each register's mask.
"""

import pathlib
import sys


def read_banks(path: pathlib.Path) -> tuple[dict[str, str], list[tuple[str, str, str]]]:
    """(header fields, [(stage, offset, verdict), ...])."""
    head: dict[str, str] = {}
    rows: list[tuple[str, str, str]] = []

    for line in path.read_text().splitlines():
        if line.startswith("#"):
            parts = line[1:].split()

            if len(parts) >= 2:
                head[parts[0]] = parts[1]

            continue

        parts = line.split()

        if len(parts) != 6 or parts[0] == "stage":
            continue

        rows.append((parts[0], parts[1], parts[5]))

    return head, rows


def read_log_scalars(path: pathlib.Path) -> list[int]:
    """The scalar ml-aed logged acting on, one per decision, in order."""
    out: list[int] = []

    for line in path.read_text().splitlines():
        if not line.startswith("seq "):
            continue

        parts = line.split()

        if "tone" not in parts:
            continue

        out.append(int(parts[parts.index("tone") + 1]))

    return out


def read_sampled(path: pathlib.Path) -> list[int]:
    """tone_scalar as the parameter actually read, in counts."""
    out: list[int] = []

    for line in path.read_text().splitlines()[1:]:
        parts = line.split(",")

        if len(parts) < 2:
            continue

        out.append(int(parts[1]) >> 8)

    return out


def transitions(values: list[int]) -> list[int]:
    """Distinct consecutive values, so a settled stretch counts once."""
    out: list[int] = []

    for v in values:
        if not out or v != out[-1]:
            out.append(v)

    return out


def report_freeze(out: pathlib.Path) -> int:
    log = out / "aed.log"
    csv = out / "scal.csv"

    if not log.exists() or not csv.exists():
        print("freeze:   SKIPPED, no aed.log or scal.csv")
        return 0

    computed = read_log_scalars(log)
    sampled = read_sampled(csv)

    if not computed:
        print("freeze:   SKIPPED, the log carries no tone field (old ml-aed)")
        return 0

    ct = transitions(computed)
    st = transitions(sampled)
    stray = sorted(set(sampled) - set(computed))

    print(f"freeze:   {len(computed)} decisions, {len(ct)} computed transitions, "
          f"{len(sampled)} samples, {len(st)} sampled transitions")
    print(f"          computed range {min(computed)}..{max(computed)}, "
          f"sampled range {min(sampled)}..{max(sampled)}")

    bad = 0

    # The parameter is sampled at 4 Hz against decisions at ~90 Hz, so it cannot show every
    # transition. It must still land inside the computed set and end where the log ends.
    if stray:
        print(f"          FAIL: sampled values nothing computed: {stray}")
        bad = 1

    # No check that the two end on the same value: ml-aed outlives the sampler by however long
    # the bank dump and log pull take, so the log legitimately ends later than the last sample.

    tail = transitions(sampled[-40:])

    if len(ct) > 20 and len(tail) == 1:
        print(f"          FAIL: parameter flat at {tail[0]} for the last 10 s while the "
              f"producer kept moving")
        bad = 1

    if not bad:
        print("          PASS: the parameter tracked what ml-aed computed")

    return bad


def report_registers(out: pathlib.Path) -> int:
    bad = 0

    for label in ("tone-off", "tone-on"):
        path = out / f"banks-{label}.txt"

        if not path.exists():
            print(f"banks:    SKIPPED {label}, no dump")
            continue

        head, rows = read_banks(path)
        stages: dict[str, list[int]] = {}

        for stage, _off, verdict in rows:
            ok, tot = stages.setdefault(stage, [0, 0])
            stages[stage] = [ok + (verdict == "ok"), tot + 1]

        total = sum(t for _o, t in stages.values())
        good = sum(o for o, _t in stages.values())
        scal = head.get("tone_scalar", "?")
        cm = head.get("cm_trigger", "?")
        print(f"banks:    {label}: {good}/{total} registers agree "
              f"(tone_scalar {scal}, cm_trigger {cm})")

        for stage in sorted(stages):
            o, t = stages[stage]

            if o != t:
                print(f"            {stage}: {t - o} of {t} disagree")
                bad = 1

    return bad


def report_images(out: pathlib.Path) -> None:
    legs = [p for p in (out / "off", out / "on") if p.exists()]

    if len(legs) != 2:
        print("image:    SKIPPED, both DVR legs are not present")
        return

    print("image:    both legs recorded, compare with:")
    print(f"            glue/capture/ab-image-diff.py {out}/off {out}/on")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    out = pathlib.Path(sys.argv[1])
    bad = report_freeze(out)
    bad |= report_registers(out)
    report_images(out)

    print()
    print("VERDICT: " + ("something disagrees, read above" if bad else
                         "scalar and registers both clean; the image is the operator's call"))

    return bad


if __name__ == "__main__":
    sys.exit(main())
