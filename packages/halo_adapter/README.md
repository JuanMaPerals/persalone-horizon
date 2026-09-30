# PersalOne Halo Adapter

This package implements the G2 **prepared** adapter boundary for Halo. It encapsulates the official Flutter BLE SDK behind the HORIZON `DeviceAdapterPort` and provides a deterministic `ScriptedHaloFixture` that exercises the same contract with `SIMULATED` evidence.

## Implemented boundary

The physical adapter uses the official SDK revision `462dff4795cffb85248ab1d2f92d4f319adb03d3` and is prepared to discover, select, connect, reconnect, observe link state, query redacted identity, query battery, expose an allow-listed Lua surface, and submit a validated USERDATA datagram. The matching firmware reference is `78bb15368f78ffe94b1b77b5f592ebe7a3f001a3`.

`ready` is emitted only after the required Halo Lua transport has been discovered. A scan result, a reconnect identifier, an SDK acknowledgement, or a fixture response does not prove a physical connection, human-visible display, audible output, or measured behavior.

## USERDATA safety boundary

G2 accepts a single USERDATA datagram only. It prepends the required `0x01` marker, validates schema and type, and rejects empty or MTU-exceeding payloads. Multipart fragmentation and reassembly remain blocked until a reviewed device-side protocol exists and is physically validated. Raw USERDATA payload is not added to diagnostics.

## Explicitly blocked

The package does not expose arbitrary Lua, file APIs, control codes, script upload, reboot, reset, remove, OTA, microphone capture, speaker playback, AEC, voice mode, providers, or agent execution. Those scopes remain behind later gates.

## Evidence label

No physical Halo has been used by this package. The physical adapter is `PREPARED`; the fixture is `SIMULATED`; no capability is promoted to `MEASURED` by code alone.
