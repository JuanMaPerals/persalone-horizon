# HORIZON Studio V2 — Halo digital twin

The Hello Halo run (V1) now lives inside a 3D Halo built from the official
Brilliant Labs model, in the same Studio panel. The twin is driven by the
canonical runtime event stream, not by a parallel feed, and shows the real
official-emulator framebuffer on its display surface.

```
Hello Halo app -> Companion -> official halo-emulator -> 256x256 framebuffer
   -> Engineering Console -> texture on the twin display (and virtual image)
Companion run -> horizon.runtime-event.v1 (RuntimeEventServer, SSE, loopback)
   -> RuntimeStreamClient (fail closed) -> TwinStateMapper -> HaloDigitalTwin
```

## Official assets and licence

| Asset | Source (brilliantlabsAR/docs @ 808d317) | sha256 |
|---|---|---|
| Model | `halo/halo.stl` (201,574 triangles, mm) | `cb5aef98…b78f4` |
| Locations | `halo/hardware.md` + `halo/images/halo-*.jpeg`, `halo-exploded-view.jpeg` | recorded in the evidence folder |

Licence: ISC, Copyright © 2024 Brilliant Labs Ltd. — covers all files of the
docs repository (no Halo-specific exception). The notice ships next to the
derived asset: `apps/engineering-console/public/twin/NOTICE-brilliant-labs.txt`.

## Pipeline (`tools/twin/build-halo-asset.mjs`, own Node process)

official STL (pinned hash, binary only, ≤ 32 MiB, ≤ 500k triangles, finite
bounded coordinates) → normalise (the STL is mm, X width, Y up, front +Z:
recentre, mm → m) → glTF → weld → meshopt simplify (bounded error 0.0005) →
smooth normals on the indexed mesh → quantisation + EXT_meshopt_compression →
sha256 → `halo.asset.json`.

Result: `halo.glb` 609,924 bytes, 100,786 triangles, sha256 `d58686f9…`,
byte-for-byte reproducible.

The browser accepts it only after checking: manifest schema
`horizon.twin-asset.v1`, size ≤ 8 MiB, SHA-256, GLB container structure, no
external or data URIs, no images/textures, extensions limited to
`EXT_meshopt_compression` and `KHR_mesh_quantization`. Nothing referenced
inside a model is fetched.

## Components and provenance

Only the shell is official geometry. Internal parts are proxy shapes; the
label says how their location is known. Nothing inferred is shown as real.

| Component | Provenance | Basis |
|---|---|---|
| Frame, lenses, arms | OFFICIAL_GEOMETRY | halo.stl |
| Display (VGA020) | OFFICIAL_LOCATION | "mounted to the top of Halo's frame" + render |
| Camera (PAG7982J1) | OFFICIAL_LOCATION | "front facing" + render |
| Button | OFFICIAL_LOCATION | "placed under the left arm" + render |
| Microphones ×2 | DOCUMENTED_PROXY | official render |
| Bone-conduction speakers ×2 | DOCUMENTED_PROXY | official render |
| Battery cells ×2 | DOCUMENTED_PROXY | exploded view |
| Bluetooth MCU (Balletto B1) | DOCUMENTED_PROXY | exploded view "AI Processor" |
| PCB | DOCUMENTED_PROXY | exploded view "PCB" |
| IMU (BMA580 + QMC6308) | INFERRED_PROXY | no official location; not a real position |

The virtual-image plane (where the wearer sees the display) is an
illustrative placement; the optics are not modelled.

## Views

ASSEMBLED · EXPLODED · X_RAY · SIGNAL_FLOW · LIVE_FRAMEBUFFER ·
COMPONENT_STATE. Rendering is on demand (no permanent animation); view
transitions are instant with `prefers-reduced-motion`.

## Runtime state mapping

`TwinStateMapper` (pure) maps `horizon.runtime-event.v1` onto components and
signal-flow segments:

- Not LIVE (connecting, disconnected, unavailable, unsupported) → every
  component and segment UNKNOWN/inactive; never the last green state.
- Execution environment (SIMULATED/EMULATED/PC_REAL/HALO_REAL/UNKNOWN/
  BLOCKED) and evidence (PREPARED/MEASURED/HARDWARE_OBSERVED/UNKNOWN) are
  separate and come only from events that carry them; HARDWARE_OBSERVED is
  never derived from stream events.
- Segments MIC→STT→TRANSLATION→CAPTION→DISPLAY and TRANSLATION→TTS→SPEAKER
  light only with runtime evidence of the current session; stop, failure or
  Panic turn them off. A Hello Halo run lights CAPTION→DISPLAY only.
- A new session resets session-scoped state (a replayed older session never
  leaks its button press or caption).
- G5 captures and speaks on the phone, so G5 events never light the Halo
  microphones or speakers.

The Companion mirrors each run on the stream: sessionState, deviceState
(HaloDeviceAdapter snapshots, EMULATED), caption per page shown (no text),
`inputButton` per gesture reported by the device, `panicExecuted`.

## Performance (measured, never assumed)

Measured by the E2E in headless Chromium on the VPS (no GPU; software
rendering):

| Metric | Value |
|---|---|
| Model bytes | 609,924 |
| Triangles drawn | 101,762 (shell 100,786 + proxies) |
| Draw calls | 12 |
| Load (fetch + validate + parse) | 238 ms |
| Frame time p50 / p95 | 71.7 / 108.4 ms |
| FPS p50 / p95 | 13.9 / 9.2 |
| Renderer | ANGLE / SwiftShader (software) |

60 FPS is **not** demonstrated: there is no GPU on this machine. Studio shows
the "Measure rendering" table so the number is taken on the user's own
hardware. CI uploads the measurement (`twin-performance.json`).

## Accessibility

Every 3D action has a non-3D equivalent: component tree (arrow keys, focus
visible, aria-pressed), textual state per component, textual signal-flow
list, screen-reader label on the viewport, reduced motion, and full
operation without WebGL.

## Tests

- Console unit: catalogue provenance rules, mapper (LIVE/not LIVE, paths,
  Panic/stop, stale sessions, blocked captions, unmapped events), asset
  validation (malformed, truncated, external/data URI, images, extensions,
  size, hash, schema).
- Companion: the run mirrored on the SSE stream, in order, without text.
- Browser E2E (`e2e/twin.e2e.ts`, `e2e/twin-nowebgl.e2e.ts`): create → run →
  framebuffer pixels on the 3D display → explode → keyboard-select the
  button → inject → page 2 on the twin → X-ray / signal flow / component
  state → measured performance → Panic turns every path off and the display
  back to UNKNOWN; negatives: asset missing, malformed GLB, tampered GLB,
  runtime disconnected, unsupported protocol, stale framebuffer, unknown
  component, reduced motion, WebGL unavailable.

## Limits

HALO_REAL = BLOCKED_HARDWARE. Internal geometry is proxy (no official CAD
parts). The IMU location is inferred. Performance on a GPU desktop is not
measured here. de/pt/it/ca strings are unreviewed drafts.
