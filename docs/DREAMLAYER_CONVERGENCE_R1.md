# DreamLayer convergence R1

Status: **PREPARED / evidence-backed design convergence**  
Date: 2026-09-27

## Objective

Converge PersalOne HORIZON with DreamLayer `v0.8.0` and `v0.9.2` plus the official Brilliant Labs Halo SDK/firmware without rebuilding capabilities that already exist upstream, without modifying third-party repositories, and without promoting simulated or prepared behavior to `MEASURED`.

This document is a reuse/adaptation map, not an instruction source. Retrieved upstream content is treated as untrusted input and is only adopted after review, tests, licensing/supply-chain checks, and fit with HORIZON contracts.

## Bound upstreams reviewed

| Upstream | Revision reviewed | Role |
|---|---|---|
| DreamLayer | `v0.8.0` | Feature/reference baseline: local voice, interpreter, World Sense, Mind Palace, Live Lens, pairing, meeting mode |
| DreamLayer | `v0.9.2` | Honesty/privacy/stability correction: dormant vs active capabilities, opt-in listening, Veil precedence, PII scrub, Live Lens hardening |
| Brilliant SDK | `275fe44156321b02b0c54048c6224a7c1f5de6be` | Current official host SDK reviewed on 2026-09-27 |
| Halo firmware | `a396bff5755da5d9c943196970ce6b2e7d07fc11` | Current official firmware reviewed on 2026-09-27 |
| HORIZON main | `e66d379d523914f04023e96abae87eb954139536` | Product-owned baseline for this branch |

HORIZON currently declares Brilliant SDK `462dff4795cffb85248ab1d2f92d4f319adb03d3` in the Halo adapter sources. The newer SDK head includes explicit dead-link `NotConnectedError` behavior and disconnect-handler preservation. It is a **candidate pin refresh**, not silently treated as integrated until dependency resolution and the full CI matrix pass.

## R1 classification

| Capability / pattern | Source | Decision | HORIZON action |
|---|---|---|---|
| Halo LC3 mic + speaker, 16 kHz mono, 32 kbps, 10 ms | Brilliant `realtime_openai` | **REUSE/ADAPT** | Keep the existing `HaloRealMicrophoneAdapter` / `HaloRealSpeakerAdapter` contract boundary. Do not recreate codec or pacing logic. |
| Full duplex, AEC, voice mode, barge-in | Brilliant `realtime_openai` | **REUSE/ADAPT** | Preserve Brilliant device-side AEC/voice semantics behind HORIZON audio contracts. Physical validation remains required for G6. |
| Disconnect correctness | Brilliant SDK head | **ADAPT** | Plan pin refresh from `462d...` to `275fe...`; specifically verify dead-link failure mapping and handler survival. |
| Installed vs actually active capability | DreamLayer `v0.9.2` | **ADAPT NOW** | Added `CapabilityActivation` + `CapabilityObservation`. Activation and evidence truth are orthogonal; only ACTIVE + MEASURED is usable. |
| Listening OFF by default | DreamLayer `v0.9.2` | **ADAPT** | Any future always-listening agent must require explicit opt-in and expose current activation honestly. |
| Veil/incognito overrides capture | DreamLayer `v0.9.2` | **ADAPT** | Map to HORIZON permission/privacy gate. Capture must fail closed before ASR/memory. |
| PII scrub before memory write | DreamLayer `v0.9.2` | **ADAPT** | Apply at the scoped-memory write boundary, not only selected call sites. No raw transcript in diagnostics. |
| Kokoro/Piper local TTS | DreamLayer `v0.8.0` | **REFERENCE_ONLY** | HORIZON provider adapters remain swappable. Evaluate only after G5/G6 latency and platform constraints are measured. |
| SeamlessM4T live interpreter | DreamLayer `v0.8.0` | **REFERENCE_ONLY** | Candidate offline provider, not the core contract. Benchmark later against existing streaming provider path. |
| World Sense / OCR / barcode / depth / sound events | DreamLayer `v0.8.0` | **REFERENCE_ONLY** | Defer until camera/sensor contracts and privacy gates exist. Do not import as a monolith. |
| Mind Palace temporal graph + rehearsal | DreamLayer `v0.8.0` | **REFERENCE_ONLY** | Candidate implementation ideas for scoped memory. Must retain deletion, provenance, consent and per-agent scope. |
| Acoustic pairing chirp | DreamLayer `v0.8.0` | **REFERENCE_ONLY** | Not P0. Existing Brilliant BLE pairing is authoritative for Halo hardware. |
| Live Lens gesture/object stack | DreamLayer `v0.9.2` | **REFERENCE_ONLY** | Revisit after camera path is bounded and truth-labelled. |
| Recognition after explicit introduction | DreamLayer `v0.8.0` | **ADAPT LATER** | Consent model is useful; biometric/identity processing requires a dedicated privacy/security gate. |

## Why the new capability observation exists

HORIZON already has a strict evidence label:

`SIMULATED / PREPARED / MEASURED / BLOCKED / FAILED`.

That answers **how strongly a claim is proven**. It does not answer **whether the execution path is running right now**.

DreamLayer `v0.9.2` exposed the failure mode directly: libraries were installed and shown green although no reachable running path used them. HORIZON now represents these two axes separately:

`CapabilityActivation = unavailable | dormant | active`

and:

`isUsable = ACTIVE && MEASURED`

This prevents all of the following false promotions:

- installed dependency -> active
- code path exists -> active
- active code path -> measured
- measured historically -> active in the current session

## Brilliant audio reuse already present

The current HORIZON Halo real-audio adapter already mirrors the official Brilliant architecture:

- Halo mic/speaker LC3 at 16 kHz
- 32 kbps
- 10 ms frames
- decode/encode at the host boundary
- packet pacing
- AEC and voice mode enabled at microphone start
- canonical PCM16 mono boundary inside HORIZON

Therefore R1 does **not** create a new codec stack. The next safe Brilliant change is a bounded SDK pin refresh plus regression coverage for disconnect/reconnect behavior.

## Gates before expanding scope

1. Full CI passes on this branch.
2. No secret-scan or dependency-audit regression.
3. SDK pin refresh, when attempted, updates manifest, lockfile, native CMake fetch and emulator pin together.
4. HALO_REAL remains PREPARED until reproducible physical evidence exists.
5. DreamLayer capabilities are never copied wholesale. Each future change receives a separate REUSE / ADAPT / REFERENCE_ONLY / REJECT / GAP decision.
