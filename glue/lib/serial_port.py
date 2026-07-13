"""
Return the goggle console serial port from the ML_SERIAL setting.

ML_SERIAL comes from the environment, or from glue/glue.env (local, gitignored;
copy glue.env.example). Import find_port(), or run this file to print the path
(so shell scripts can resolve it the same way):

    PORT="$(python3 glue/lib/serial_port.py)" || exit 1
"""
import os
import sys


ENV_FILE = os.path.join(os.path.dirname(__file__), os.pardir, "glue.env")


def glue_env_serial():
    """Return ML_SERIAL from glue/glue.env (simple KEY=VALUE, no shell expansion), or None."""
    try:
        with open(ENV_FILE) as env:
            for line in env:
                line = line.strip()
                if line.startswith("#") or "=" not in line:
                    continue

                key, _, value = line.partition("=")
                if key.strip() == "ML_SERIAL":
                    return value.strip().strip('"').strip("'") or None
    except FileNotFoundError:
        pass

    return None


def find_port():
    port = os.environ.get("ML_SERIAL") or glue_env_serial()
    if not port:
        raise SystemExit(
            "serial_port: ML_SERIAL is not set. Put it in glue/glue.env (copy glue.env.example) "
            "or export it, e.g. ML_SERIAL=/dev/serial/by-id/usb-Raspberry_Pi_Pico_...-if00"
        )

    return port


if __name__ == "__main__":
    print(find_port())
    sys.exit(0)
