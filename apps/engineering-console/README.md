# HALO Engineering Console V2

This application is the **engineering workstation** for HALO traces. It is intentionally separate from the Flutter companion: the companion remains responsible for device and audio boundaries, while this console presents normalized engineering evidence for investigation, replay, and operational debugging.

The initial workspace contains a dockable execution graph, timeline with replay, shared inspector, trace logs, BLE monitor, translation inspector, memory/RAG policy view, metrics panel, session selector, search, command palette, and browser-local layout persistence. Panel interactions share a single `FocusTarget`, so a timeline, graph, or log selection resolves to the same inspector subject.

> The bundled fixture is deterministic and explicitly labelled `SIMULATED`, `PREPARED`, or `BLOCKED`. It contains metadata only; it never contains PCM, raw transcripts, credentials, physical device identifiers, or a claim of physical Halo evidence.

| Command | Purpose |
| --- | --- |
| `pnpm install` | Resolve the locked local application dependencies. |
| `pnpm dev` | Run the local workstation preview. |
| `pnpm lint` | Type-check the TypeScript application. |
| `pnpm test` | Run normalized trace-store unit tests. |
| `pnpm build` | Produce the static production bundle. |

## Trace ingestion boundary

`HaloTraceEvent` in `src/types/trace.ts` is the normalized console contract. A future adapter may append real or emulated runtime events only after it removes sensitive payload fields, labels evidence truthfully, preserves session/trace/span correlation, and supplies monotonic event ordering. The console will not infer `MEASURED` from a transport acknowledgement, a UI transition, an SDK response, or a mock value.

The next integration increment is an explicit adapter from the existing Dart companion’s redacted session, capability, audio-metadata, and diagnostic events to `HaloTraceEvent`; it must be tested with both a deterministic fixture and a physical evidence gate.
