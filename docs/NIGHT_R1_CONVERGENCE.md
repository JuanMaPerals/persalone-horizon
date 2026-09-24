# Night R1 — synthetic convergence map

Lab: local worktree `lab-convergence-r1`, branch `lab/convergence-r1` (never
pushed). Each unit was squash-merged onto `main@bb885fa` in order, the way
GitHub squash merges land, and the full suite ran after every step.
Evidence logs: private temp `lab/` (not in the repo).

## Topology observed (2026-09-24)

| Unit | Branch | PR base | Own commits |
|---|---|---|---|
| #41 caption slice | `feat/caption-slice-r1` | `main` | 2 |
| #42 bounded display | `feat/halo-bounded-display-r1` | `main` | 1 |
| E2E emulated | `feat/e2e-emulated-r1` | no PR | merge `62dfdf7` (#41+#42) + 2 |
| #43 event stream | `feat/runtime-event-stream-r1` | `feat/e2e-emulated-r1` | 2 |
| #44 live stream | `feat/runtime-live-stream-r1` | `feat/runtime-event-stream-r1` | 4 |
| C1 control port | `feat/runtime-control-c1` | no PR | 3 |
| Night R1 | `feat/night-r1` | no PR | 5 |

#41 and #42 are siblings on `main`; everything from E2E up is one linear
stack.

## MERGE_ORDER

1. #41 → `main`
2. #42 → `main` (after #41; conflicts below)
3. E2E (`feat/e2e-emulated-r1`) → needs a PR to `main`; its own delta is
   `62dfdf7..feat/e2e-emulated-r1`
4. #43 → retarget to `main` after step 3, then merge
5. #44 → retarget to `main`, merge
6. C1 → open PR to `main`, merge
7. Night R1 → open PR to `main`, merge (or split per commit, see below)

After each squash merge, the next branch must be rebased onto `main` (its
base content is already there under a different SHA); in the lab every
rebase after step 2 applied without conflict.

## CONFLICT_FILES

Only step 2 (#42 on top of #41) conflicts:

- `packages/halo_adapter/lib/persalone_halo_adapter.dart`: both add one
  export on the same line. Resolution: keep both
  (`halo_caption_output_adapter.dart` and `halo_bounded_display.dart`).
- `packages/halo_adapter/test/halo_device_adapter_test.dart`: both append
  tests at the end of `main()`. Resolution: the version in `62dfdf7`.

With exactly the `62dfdf7` resolution, the lab tree after step 2 is
byte-identical to `62dfdf7`. Steps 3–7 apply cleanly.

## SEMANTIC_CHANGES_REQUIRED

- #41's `HaloCaptionOutputAdapter` tests assumed `displayText` was gated
  (captions BLOCKED on HALO_REAL). Once #42 lands, a real Halo caption is
  `delivered` with truth `PREPARED` through the bounded builder. `62dfdf7`
  already carries this update; the test title still says "BLOCKED" while
  asserting `delivered` — rename it when landing #42 (cosmetic).
- #43 retargeting: its PR base is `feat/e2e-emulated-r1`, which has no PR.
  Either open a PR for the E2E branch first (recommended, it is the
  emulator gate the later units rely on) or retarget #43 to `main` after
  #41/#42 and let it carry the E2E commits.
- Night R1 extends `horizon.runtime-event.v1` with a `latency` kind. Older
  Console builds reject unknown kinds and show DEGRADED (fail closed), so the
  Console and the runtime must ship together; no persisted data is affected.
- Night R1 changes the SSE body framing to close-delimited (no chunked
  encoding) to detect dropped clients; browsers and the Node client are
  covered by the live-stream E2E.

## TESTS_AFTER_EACH_STEP (lab, all exit 0)

| Step | contracts | runtime | halo | audio | mobile + E2E | Console | analyze |
|---|---|---|---|---|---|---|---|
| 1 #41 | 2 | 15 | 5 | 13 | 2 | 20 | 1 info (pre-existing) |
| 2 #42 | 2 | 15 | 43 | 13 | 2 | 20 | 1 info |
| 3 E2E | 2 | 15 | 44 | 13 | 8 | 20 | 1 info |
| 4 #43 | 2 | 18 | 44 | 13 | 8 | 28 | 1 info |
| 5 #44 | 2 | 26 | 44 | 13 | 9 | 37 | 1 info |
| 6 C1 | 2 | 42 | 44 | 13 | 13 | 37 | 1 info |
| 7 Night | 2 | 60 | 55 | 13 | 33 | 54 | 1 info |

The analyzer info is `deprecated_member_use` in `apps/mobile/lib/main.dart`
and exists on `main`.

## EXPECTED_CANONICAL_RESULT

After step 7 the lab tree is identical to `feat/night-r1@9b5d4a9` (git diff
empty; later night commits add on top and must be re-checked the same way).
Merging in the order above with the `62dfdf7` resolution therefore yields
exactly the tested night tree on `main`.
