# HORIZON Studio V1 — Hello Halo

First vertical slice of HORIZON Studio (architecture R1.1 §12, V1): from the
existing Engineering Console, create an app from the `hello-display`
template, edit its caption, run it on the **official halo-emulator**, see
the real framebuffer, press the emulated button, run tests and export a
reproducible package. No 3D yet (V2).

## What runs where

| Piece | Location | Role |
|---|---|---|
| Studio panel "Hello Halo" | `apps/engineering-console/src/components/HelloHaloPanel.tsx` | UI (es/en complete; de/pt/it/ca unreviewed drafts) |
| Companion | `apps/companion` (pure Dart) | Local API `/v1` on loopback; single authority for app runs |
| Halo core | `packages/halo_core` (pure Dart) | Composer, bounded display commands, device adapter (page navigation) |
| Emulator transport | `packages/halo_emulator` | Drives `tooling/e2e/halo_emulator_bridge.py` → official emulator |

Studio never talks to the emulator directly; every action goes through the
Companion.

## Run it locally

1. Official emulator venv (same pin as CI):

   ```bash
   python3 -m venv ~/.cache/horizon-e2e-venv
   ```

   ```bash
   ~/.cache/horizon-e2e-venv/bin/pip install -r tooling/e2e/requirements-halo-emulator.txt
   ```

2. Companion (from the repo root, after `flutter pub get`):

   ```bash
   dart run apps/companion/bin/horizon_companion.dart --workspace ~/.horizon-studio --python ~/.cache/horizon-e2e-venv/bin/python --bridge tooling/e2e/halo_emulator_bridge.py
   ```

   It prints `HORIZON_COMPANION_READY url=http://127.0.0.1:47810 token=…`.

3. Console:

   ```bash
   cd apps/engineering-console && pnpm install && pnpm dev
   ```

   Open http://127.0.0.1:5173, tab **Hello Halo (Studio)**, paste the token,
   Connect.

## The journey

1. **Create** from template `hello-display` (manifest v1, digest shown).
2. **Edit** the caption and the gesture that shows the next page (single /
   double / long). Only text and that validated parameter: no host code, no
   Lua. The composer preview shows pages and the **glyph limit**: characters
   outside the Halo ASCII font are folded or shown as `?`, reported as loss,
   never as Unicode support.
3. **Run** on the official emulator. The framebuffer is the emulator's real
   256×256 display (PNG + SHA-256).
4. **Button**: the bridge injects the hardware gesture; the device-side
   reporter (constant, EMULATED-only) sends `btn:<gesture>` over Bluetooth;
   the Companion shows the next page only when the configured gesture is
   reported. Other gestures are shown as reported but do not change the page.
5. **Stop / PANIC**: PANIC stops every run and clears the display, without
   waiting for the UI.
6. **Test**: 9 assertions on a fresh emulator instance (manifest, no text
   loss, page visible, inside the round display, glyph degradation reported,
   device button report, page advance, other gestures ignored, stop clears).
   Result format per architecture §4.2: data `SYNTHETIC`, target `EMULATED`,
   providers per stage (STT/translation/TTS `NOT_USED`), outcome, evidence,
   metrics on the Companion's monotonic clock with sample counts (p50 only
   with 5+ samples, p95 with 20+), hashed framebuffer artifacts. Without an
   emulator the result is `BLOCKED` with the reason.
7. **Export**: `.horizonapp` = deterministic ustar (sorted entries, mtime 0)
   with manifest, validation, test spec, provenance, the latest test result
   of this exact digest with its PNGs, and `CHECKSUMS.sha256`. Same content,
   same bytes.

## Security boundaries (V1)

- Companion listens on 127.0.0.1 only; pairing token; Host header check
  (DNS rebinding); Origin allow-list (CORS is not authentication); 64 KiB
  JSON bodies; stable error codes.
- Manifest refuses host code, device Lua, `HALO_REAL`, unknown capabilities
  and required capabilities V1 cannot grant.
- The official emulator executes Lua without a sandbox (host `os`/`io`
  reachable). V1 sends it only bounded display commands built from the
  caption and constant bridge operations; user text is never code. Free Lua
  stays blocked until OS isolation is proven (V3).
- `HALO_REAL` is not reachable: the device allow-list is unchanged.

## Evidence

- Companion: 18 tests, including the full API journey against the official
  emulator (`apps/companion/test/hello_halo_journey_test.dart`).
- Studio UI journey: Playwright drives the Console against the real
  Companion and emulator (`apps/engineering-console/e2e/hello-halo.e2e.ts`),
  English flow with export hash verification and Spanish flow with PANIC; CI
  job `studio-e2e` uploads step screenshots.
- Console: i18n completeness (same keys and placeholders in six locales),
  client and render tests.

What this proves: software behaviour on the official emulator with synthetic
input. What it does not prove: Halo hardware, optics, BLE link, battery or
acoustics (BLOCKED_HARDWARE).

## Not in V1

3D twin (V2), host code / free Lua / IMU / microphone (V3, needs isolation),
package import and offline installer (V4), public SDK/OpenAPI (V5),
GitHub/MCP/connectors (V6–V8), HALO_REAL (V10). de/pt/it/ca need human
review before they can be declared complete.
