# PersalOne HORIZON

```text
      ────╲    .-─────────-.   .-─────────-.    ╱────
           ╲  /  [CONTEXT] \___/  [AGENTS]  \  ╱
            ╲|    VISION   |   |    AUDIO   |╱
             |             |───|            |
            ╱|             |   |            |╲
           ╱  \____________/     \__________/  ╲
      ────╱      ╲___╱               ╲___╱      ╲────

                    PERSALONE HORIZON
                     SEE · UNDERSTAND · ACT
```

**PersalOne HORIZON** is an evidence-first, privacy-first platform for useful agents at the edge of human attention. It is being built to help people see, understand, and act while retaining control over devices, permissions, data, and the difference between a prepared capability and one proven in the physical world.

The first product agent is **HORIZON Translate**: a bidirectional English ↔ Spanish conversation agent. **Halo is the first hardware target, not the limit of the product.** The core contracts are intended to support future wearable, mobile, accessibility, vision, meeting, assist, and community-built agents without treating a particular device or cloud provider as the product itself.

> **Current truth:** HORIZON has a prepared governance and mobile-contract foundation. It does **not** yet claim Halo BLE connectivity, microphone capture, speaker playback, translation, real-time duplex audio, AEC, provider integration, agent execution, OTA, or physical hardware evidence.

## Verified state

| Gate | Status | What is verifiably present | What is not claimed |
|---|---|---|---|
| **G0 — Governance & security baseline** | `PREPARED` | Contribution and security policies, a repository preflight, CI definitions, secret scanning, SBOM generation, and local checks. | GitHub branch protection and private vulnerability reporting still require owner activation. |
| **G1 — Flutter & canonical contracts** | `PREPARED` | Minimal Android/iOS Flutter shell, versioned Dart contracts, truth labels, typed errors, and local tests. | No physical device adapter or enabled device capability. |
| **G2 — Halo integration** | `BLOCKED` | No Halo transport has been integrated. | Discovery, pairing, identity, battery, Lua, USERDATA, or connected state. |
| **G3 — Input audio** | `BLOCKED` | No capture path is enabled. | Microphone availability, latency, dropped-frame, or device evidence. |
| **G4 — Output audio** | `BLOCKED` | No playback path is enabled. | Speaker availability, underrun, output latency, or audible acceptance. |
| **G5 — Translation** | `BLOCKED` | No STT, translation, TTS, or provider path is enabled. | End-to-end English ↔ Spanish translation. |
| **G6 — Duplex, AEC & barge-in** | `BLOCKED` | No simultaneous audio route is enabled. | Full duplex, echo cancellation, interruption, or endurance. |
| **G7 — Agent runtime** | `BLOCKED` | No agent receives implicit device or data access. | Agent lifecycle, tools, memory, or permissions execution. |
| **G8 — Release & community readiness** | `BLOCKED` | The repository remains private. | Store distribution, public release, or a production-ready community preview. |

The distinction is intentional. HORIZON counts **accepted, reproducible functionality**, never code volume, screenshots, acknowledgements, or vendor claims.

## The HORIZON model

```text
Human intent
    │
    ▼
HORIZON agent runtime ── explicit permissions ── policy & evidence engine
    │                                  │                     │
    │                                  │                     └─ censored diagnostics only
    ▼                                  ▼
Conversation / perception runtime   Provider ports
    │                                  │
    └────────────── canonical contracts ──────────────┐
                                                        ▼
                                              Verified device adapter
                                                        │
                              Halo (first target) · mobile · future devices
```

This is an **agent-first** architecture, but agents are not trusted by default. A future HORIZON agent must declare its purpose, data scope, provider requirements, tools, lifecycle, and requested capabilities. It must never gain access to microphone, camera, BLE, Lua, memory, external tools, or OTA merely because it is installed.

## Privacy and security by design

Privacy is a product constraint, not an afterthought. HORIZON is local-first where that provides meaningful user control, exposes provider boundaries instead of hiding them, and keeps raw audio, transcripts, credentials, device identifiers, and private evidence out of Git and default diagnostics.

Every capability is labelled using a shared truth model:

| Label | Meaning |
|---|---|
| `SIMULATED` | Deterministic test transport or fixture using the same production contracts. It is not hardware evidence. |
| `PREPARED` | Code and contracts exist, but reproducible physical validation has not yet happened. |
| `MEASURED` | Reproducible physical evidence exists for the stated capability and conditions. |
| `BLOCKED` | The capability is intentionally unavailable or has not passed its gate. |
| `FAILED` | A test or runtime path failed and must not be presented as usable. |

A transport acknowledgement is not audible output. A mock value is not telemetry. A local UI state is not a connected device. These boundaries are visible so users, contributors, and future reviewers can make informed decisions.

## Hardware and upstream boundaries

Product development happens only in this repository. Halo firmware and the Brilliant SDK are upstream references and remain read-only.

| Repository | Role | Boundary |
|---|---|---|
| [`JuanMaPerals/persalone-halo`](https://github.com/JuanMaPerals/persalone-halo) | HORIZON product, contracts, tests, documentation, and PRs. | The sole product write target. |
| [`brilliantlabsAR/halo-firmware`](https://github.com/brilliantlabsAR/halo-firmware) | Firmware, BLE, Lua, audio, display, sensors, pairing, and OTA evidence. | Read-only upstream. No modifications, flashing, or PRs from HORIZON work. |
| [`brilliantlabsAR/brilliant_sdk`](https://github.com/brilliantlabsAR/brilliant_sdk) | Official Flutter, Android, iOS, BLE, transport, and audio SDK reference. | Read-only upstream. HORIZON may adapt verified interfaces without duplicating proven SDK behavior. |

Before G2, the project will publish an evidence-backed integration decision that separates what the official SDK provides, what requires direct protocol work, and what remains physically unverified.

## Road to a real first agent

HORIZON Translate will become an agent only through demonstrable gates:

1. **G2:** a fail-closed `DeviceAdapter` with a deterministic simulator that shares production contracts and never impersonates hardware.
2. **G3–G4:** real operating-system microphone and speaker paths, instrumented for capture, buffering, output, dropped frames, underruns, overruns, and measured latency.
3. **G5:** real streaming STT → incremental English/Spanish translation → streaming TTS with provider ports, partial transcripts, source/translated history, and no committed credentials.
4. **G6:** interruption, push-to-talk fallback, double-talk and AEC work only after the underlying audio path is real and measurable.
5. **G7:** HORIZON Translate runs under declared permissions, lifecycle, memory scope, provider requirements, and audit events rather than as hard-coded product logic.
6. **G8:** a polished UI, community documentation, reproducible evidence, and security readiness precede any recommendation to make the repository public.

Until those gates are passed, a future-facing product narrative will not be substituted for operational evidence.

## Build with the community

HORIZON is private while its contribution, security, developer, and evidence practices become reliable. The project is preparing for a community that values useful agents, inclusive interfaces, hardware honesty, security review, and contributors who can build on stable contracts rather than reverse-engineered assumptions.

Contributors will eventually be able to create agents for translation, vision, accessibility, meetings, assist, security, and other community needs. Public launch is not a marketing deadline: it is a gate that requires green CI, an active security baseline, truthful documentation, real end-to-end speech translation, a contract-compatible Halo simulator, a polished state-driven UI, usable documentation, and explicit disclosure that physical Halo behavior is not `MEASURED` until physically validated.

## Contributing and security

The repository currently uses branches and pull requests; **never push directly to `main`**. Read [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), [the current gate status](docs/STATUS.md), and [manual GitHub settings](docs/GITHUB_MANUAL_SETTINGS.md) before proposing work.

For local validation from the repository root:

```bash
flutter pub get
flutter analyze
(cd packages/contracts && dart test)
(cd apps/mobile && flutter test)
bash tooling/preflight.sh --all
```

Do not commit credentials, `.env` files, audio, transcripts, private evidence, voice data, certificates, or device identifiers. See [the architecture audit](docs/ARCHITECTURE_AUDIT_2026-08-19.md) for the current architectural decision record.

## License

PersalOne-owned source code in this repository is licensed under [Apache-2.0](LICENSE). SDKs, model weights, voices, datasets, firmware, and other third-party materials retain their own terms and are never automatically relicensed.

**Author:** Juan Ma Perals.
