"""JSON-lines bridge between the HORIZON E2E tests and the official halo-emulator.

It stands in for the BLE link only: the host sends Lua exactly as it would over
BLE and the official emulator executes it in Lua 5.4 and renders the 256x256
framebuffer. Evidence produced through it is EMULATED, never HALO_REAL.

Requests (one JSON object per line on stdin):
  {"op": "exec", "lua": "..."}          -> {"ok": true, "prints": [...]}
  {"op": "frame", "png": "<path>|null"} -> {"ok": true, "lit": n, "upper": n,
                                            "lower": n, "outside": n,
                                            "bbox": [x0,y0,x1,y1]|null,
                                            "sha256": "...", "suspended": bool}
  {"op": "global_is_nil", "name": "X"}  -> {"ok": true, "value": bool}
  {"op": "arm_buttons"}                 -> {"ok": true}
  {"op": "button", "kind": "single|double|long"}
                                        -> {"ok": true, "device_messages": [...]}

"frame" also accepts "png_base64": true to return the PNG in the reply.

arm_buttons and button are EMULATED-only fixed operations: the bridge runs its
own constant Lua (BUTTON_REPORTER) so the device reports presses over
Bluetooth exactly as a Halo app would; no Lua crosses from the host for them.
They do not extend the HALO_REAL allow-list.
"""

import base64
import hashlib
import importlib.metadata
import io
import json
import re
import sys

from halo_emulator import HaloEmulator

UPPER_BAND = range(55, 100)
LOWER_BAND = range(150, 200)
_GLOBAL_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,31}$")
BUTTON_KINDS = ("single", "double", "long")
# Constant device-side reporter: each press is sent to the host over BLE.
BUTTON_REPORTER = " ".join(
    f'frame.button.{kind}(function() frame.bluetooth.send("btn:{kind}") end)'
    for kind in BUTTON_KINDS
)
# frame.sleep(0) is deep sleep (shutdown); a tiny positive sleep lets the
# firmware loop dispatch queued events to the registered callbacks.
EVENT_PUMP = "frame.sleep(0.001)"


def _reply(payload):
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def main():
    prints = []
    # The host owns the sandbox directory (argv[1]) and removes it after this
    # process exits, even when it is SIGKILLed; an emulator-owned temp dir
    # would be left behind on every crash.
    sandbox = sys.argv[1] if len(sys.argv) > 1 else None
    emu = HaloEmulator(print_handler=prints.append, sandbox_dir=sandbox)
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
                png_b64 = None
                if request.get("png_base64"):
                    buffer = io.BytesIO()
                    image.save(buffer, format="PNG")
                    png_b64 = base64.b64encode(buffer.getvalue()).decode("ascii")
                outside = sum(1 for x, y in lit
                              if (x - 127.5) ** 2 + (y - 127.5) ** 2 > 128 ** 2)
                bbox = ([min(x for x, _ in lit), min(y for _, y in lit),
                         max(x for x, _ in lit), max(y for _, y in lit)]
                        if lit else None)
                _reply({
                    "ok": True,
                    "lit": len(lit),
                    "outside": outside,
                    "bbox": bbox,
                    "upper": sum(1 for _, y in lit if y in UPPER_BAND),
                    "lower": sum(1 for _, y in lit if y in LOWER_BAND),
                    "sha256": hashlib.sha256(image.tobytes()).hexdigest(),
                    "suspended": bool(
                        emu.execute_lua("return frame.display.power_save()")),
                    "png_base64": png_b64,
                })
            elif op == "global_is_nil":
                name = request["name"]
                if not _GLOBAL_NAME.match(name):
                    raise ValueError("invalid global name")
                _reply({"ok": True, "value": bool(
                    emu.execute_lua(f"return rawget(_G, '{name}') == nil"))})
            elif op == "arm_buttons":
                emu.execute_lua(BUTTON_REPORTER)
                emu.clear_bluetooth_sent()
                _reply({"ok": True})
            elif op == "button":
                kind = request.get("kind")
                if kind not in BUTTON_KINDS:
                    raise ValueError("invalid button kind")
                emu.clear_bluetooth_sent()
                getattr(emu, f"inject_button_{kind}")()
                emu.execute_lua(EVENT_PUMP)
                sent = [m.decode("latin-1") for m in emu.get_bluetooth_sent()]
                emu.clear_bluetooth_sent()
                _reply({"ok": True, "device_messages": sent})
            else:
                raise ValueError(f"unknown op: {op}")
        except Exception as error:  # reported to the host like a device error
            _reply({"ok": False, "error": type(error).__name__})


if __name__ == "__main__":
    main()
