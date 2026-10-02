#!/usr/bin/env python3
"""Fixed-address O.MG basic controller. No raw-command or execution interface."""
import argparse
from pathlib import Path
import re
import socket
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent / "vendor"))
try:
    import websocket
except ImportError as exc:
    raise SystemExit("Missing Python module: %s. Copy the entire payload folder." % exc)

HOST = "192.168.4.1"
URL = "ws://192.168.4.1/d/ws/issue"
TIMEOUT = 5.0
ACTIONS = {
    "status": (("CV", "Firmware"), ("CI", "System")),
    "payload-status": (("CEStatus", "Payload"),),
    "descriptors": (("CNGet", "USB descriptors"),),
    "jiggler-on": (("CJ1", "Jiggler on"),),
    "jiggler-off": (("CJ0", "Jiggler off"),),
    "usb-on": (("CU1", "USB on"),),
    "usb-off": (("CU0", "USB off"),),
    "reboot": (("CR1", "Reboot"),),
}
WRITES = {"CJ0", "CJ1", "CU0", "CU1", "CR1"}


class ControllerError(Exception):
    pass


def clean(value):
    """Keep device output from placing control sequences in the Pager log."""
    return "".join(c if c.isprintable() else " " for c in value)[:400]


def exchange(ws, command):
    deadline = time.monotonic() + TIMEOUT
    attempted = False
    try:
        ws.settimeout(TIMEOUT)
        attempted = True
        ws.send(command)
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("No matching response")
            ws.settimeout(remaining)
            raw = ws.recv()
            if raw == "" or raw == b"":
                raise ConnectionError("Device closed the connection")
            if isinstance(raw, bytes):
                raw = raw.decode("utf-8", errors="replace")
            text = raw.strip()
            if "unrecognized command" in text.lower():
                raise ControllerError("Command unsupported by this device/firmware: " + command)
            token = re.split(r"\s+", text, maxsplit=1)[0]
            if token.endswith("Error"):
                raise ControllerError("Device error: " + clean(text))
            if token == command:
                return text
            # Ignore unrelated notifications; do not accept prefix collisions.
    except (OSError, websocket.WebSocketException) as exc:
        if attempted and command in WRITES:
            raise ControllerError(
                "No acknowledgement for %s; it may have taken effect. "
                "Not retried. Check the device before repeating." % command
            ) from exc
        raise ControllerError("No response for %s: %s" % (command, clean(str(exc)))) from exc


def describe(command, label, reply):
    fields = reply.split()
    if command == "CV" and len(fields) >= 4:
        return ["Firmware: " + fields[1], "Type: %s / status: %s" % tuple(fields[2:4])]
    if command == "CI" and len(fields) >= 9:
        return ["MAC: " + fields[1], "Flash: " + fields[2],
                "Uptime: %s seconds" % fields[6], "Free heap: %s KB" % fields[7],
                "Restart reason: %s / faults: %s" % (fields[3], fields[8])]
    if command == "CNGet":
        parts = reply.split("\t")
        if len(parts) == 6:
            return ["%s: %s" % (name, value) for name, value in zip(
                ("VID", "PID", "Manufacturer", "Product", "Serial"), parts[1:])]
    if command in WRITES:
        return [label + ": acknowledged"]
    return [label + ": " + reply]


def run(action):
    # A direct socket prevents environment proxy settings from routing local control.
    connection = None
    ws = None
    try:
        connection = socket.create_connection((HOST, 80), timeout=TIMEOUT)
        ws = websocket.create_connection(
            URL, socket=connection, timeout=TIMEOUT, origin="http://192.168.4.1"
        )
        for command, label in ACTIONS[action]:
            reply = exchange(ws, command)
            for line in describe(command, label, reply):
                print(clean(line), flush=True)
        return 0
    except (ControllerError, OSError, websocket.WebSocketException) as exc:
        print("O.MG: " + clean(str(exc)), file=sys.stderr)
        print("Check the Pager's connection to O.MG Wi-Fi (192.168.4.1).", file=sys.stderr)
        return 1
    finally:
        if ws is not None:
            try:
                ws.close(timeout=0.2)
            except (OSError, websocket.WebSocketException):
                pass
        if connection is not None:
            connection.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=tuple(ACTIONS))
    args = parser.parse_args()
    sys.exit(run(args.action))
