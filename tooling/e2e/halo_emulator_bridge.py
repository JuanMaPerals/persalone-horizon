"""JSON-lines bridge between the HORIZON E2E tests and the official halo-emulator.

It stands in for the BLE link only: the host sends Lua exactly as it would over
BLE and the official emulator executes it in Lua 5.4 and renders the 256x256
framebuffer. Evidence produced through it is EMULATED, never HALO_REAL.

Requests (one JSON object per line on stdin):
  {"op": "exec", "lua": "..."}          -> {"ok": true, "prints": [...]}
  {"op": "frame", "png": "<path>|null"} -> {"ok": true, "lit": n, "upper": n,
                                            "lower": n, "sha256": "...",
                                            "suspended": bool}
  {"op": "global_is_nil", "name": "X"}  -> {"ok": true, "value": bool}
"""

import hashlib
import importlib.metadata
import json
import re
import sys

from halo_emulator import HaloEmulator

UPPER_BAND = range(55, 100)
LOWER_BAND = range(150, 200)
_GLOBAL_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,31}$")


def _reply(payload):
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def main():
    prints = []
    emu = HaloEmulator(print_handler=prints.append)
    emu.connect()
    # Halo boots with its display in power-save mode; mirror that so the host
    # must wake it explicitly.
    emu.execute_lua("frame.display.power_save(true)")
    _reply({"ready": True, "emulator": "halo-emulator",
            "version": importlib.metadata.version("halo-emulator")})

    for line in sys.stdin:
        request = json.loads(line)
        op = request.get("op")
        try:
            if op == "exec":
                prints.clear()
                emu.execute_lua(request["lua"])
                _reply({"ok": True, "prints": list(prints)})
            elif op == "frame":
                image = emu.get_framebuffer().convert("RGB")
                pixels = image.load()
                lit = [(x, y) for y in range(256) for x in range(256)
                       if pixels[x, y] != (0, 0, 0)]
                if request.get("png"):
                    image.save(request["png"])
                _reply({
                    "ok": True,
                    "lit": len(lit),
                    "upper": sum(1 for _, y in lit if y in UPPER_BAND),
                    "lower": sum(1 for _, y in lit if y in LOWER_BAND),
                    "sha256": hashlib.sha256(image.tobytes()).hexdigest(),
                    "suspended": bool(
                        emu.execute_lua("return frame.display.power_save()")),
                })
            elif op == "global_is_nil":
                name = request["name"]
                if not _GLOBAL_NAME.match(name):
                    raise ValueError("invalid global name")
                _reply({"ok": True, "value": bool(
                    emu.execute_lua(f"return rawget(_G, '{name}') == nil"))})
            else:
                raise ValueError(f"unknown op: {op}")
        except Exception as error:  # reported to the host like a device error
            _reply({"ok": False, "error": type(error).__name__})


if __name__ == "__main__":
    main()
