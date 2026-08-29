#!/usr/bin/env python3
"""Read or set dvr.rtsp_stream in an ml-hud settings.json, on stdin, to stdout.

The HUD owns the restream: hud.c rtsp_tick asserts the pipeline's state to match this key on
every tick. settings.c loads the file once at startup, so a write here takes effect on the next
ml-hud start. Unparseable or absent input is treated as empty settings, matching settings_open.

    hud-setting.py read           prints "on" or "off"
    hud-setting.py write on|off   copies stdin to stdout with the key set
"""
import json
import sys


def load(stream: str) -> dict:
    try:
        settings = json.loads(stream)
    except ValueError:
        return {}

    return settings if isinstance(settings, dict) else {}


def main() -> int:
    argv: list[str] = sys.argv[1:]
    if not argv or argv[0] not in ("read", "write"):
        print(__doc__, file=sys.stderr)
        return 2

    settings: dict = load(sys.stdin.read())

    if argv[0] == "read":
        section = settings.get("dvr")
        on: bool = bool(section.get("rtsp_stream")) if isinstance(section, dict) else False
        print("on" if on else "off")
        return 0

    if len(argv) != 2 or argv[1] not in ("on", "off"):
        print("usage: hud-setting.py write on|off", file=sys.stderr)
        return 2

    settings.setdefault("dvr", {})["rtsp_stream"] = argv[1] == "on"
    json.dump(settings, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
