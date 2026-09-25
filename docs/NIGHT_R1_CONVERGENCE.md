# Night R1 — canonical merge runbook for the PR chain

Freeze baseline (2026-09-25): `main@bb885fa`, `feat/night-r1@4dbf105`.
Reproduce the whole synthetic convergence, with the full suite after every
layer, in a new local worktree (never pushed, `main` untouched):

```bash
HORIZON_E2E_PYTHON=<venv>/bin/python tooling/convergence/converge_night_r1.sh ../lab-convergence-new
```

It must end with `CONVERGENCE_READY` and a final tree equal to
`feat/night-r1`.

## Chain and trees

| Layer | Branch @ head | PR | Tree after the layer |
|---|---|---|---|
| #41 caption slice | `feat/caption-slice-r1@e947553` | #41 → `main` | `afb13e8` |
| #42 bounded display | `feat/halo-bounded-display-r1@3f29e95` | #42 → `main` | `95eda9c` (= `62dfdf7`) |
| E2E emulated | `feat/e2e-emulated-r1@03e7918` | none yet | `74005c3` |
| #43 event stream | `feat/runtime-event-stream-r1@7bcd6bb` | #43 (draft, base E2E) | `86dffc8` |
| #44 live stream | `feat/runtime-live-stream-r1@7dd5eaa` | #44 (draft, base #43) | `22201f8` |
| C1 control port | `feat/runtime-control-c1@a437719` | none yet | `3417fc5` |
| Night R1 | `feat/night-r1` | none yet | equal to the branch |

`main` uses squash merges, so after each merge the next branch is rebased
onto the new `main`; only the layer's own delta may remain. In the lab every
layer after #42 applies without conflict and lands on exactly its branch's
tree.

## Step 1 — #41

Merge as is (READY: CI green on `e947553`, 0 behind `main`).

## Step 2 — #42 after #41 (the only conflicting step)

```bash
git checkout feat/halo-bounded-display-r1 && git rebase origin/main
```

Two files conflict. Resolve them deterministically from the validated
composition `62dfdf7` (it contains exactly #41 + #42):

```bash
git checkout 62dfdf7 -- packages/halo_adapter/lib/persalone_halo_adapter.dart packages/halo_adapter/test/halo_device_adapter_test.dart
```

What that resolution is, derived independently in the lab:

1. `persalone_halo_adapter.dart`: union of the two exports, alphabetical
   (`halo_bounded_display.dart`, then `halo_caption_output_adapter.dart`).
2. `halo_device_adapter_test.dart`: #42's `bounded displayText` group, then
   #41's `HaloCaptionOutputAdapter` group, with the two #41 tests updated
   BLOCKED → DELIVERED (a real Halo caption is `delivered`/`PREPARED` through
   the bounded builder; the fixture caption is `delivered`/`SIMULATED`).
3. **Hidden hazard:** both PRs add `final List<String> executed` to
   `_ControlledTransport`. Git merges one copy outside the conflict markers,
   so resolving only the markers (e.g. in the GitHub editor) leaves a
   duplicate field and the test does not compile. Keep one declaration.

Check before pushing: the rebased tree must equal `62dfdf7^{tree}`
(`95eda9c`). In the lab it did, and the suite passed (contracts 2, runtime
15, halo 43, audio 13, mobile 2, Console 20). A 40,016-input `displayText`
fuzz accepted 24,001 commands, all grammar-valid and verified by a real Lua
5.4 oracle (one `text()` call with the exact bytes, no sandbox escape), and
refused 16,015 with `invalidContract`, 0 unexpected.

The #41 test title still says "BLOCKED" while asserting `delivered`; renaming
it would change the validated tree, so it is left for a later cosmetic change.

## Step 3 — E2E

Open a PR for `feat/e2e-emulated-r1` only after #41 and #42 are on `main`,
rebased so that its delta is `62dfdf7..feat/e2e-emulated-r1` (2 commits:
caption environment from the transport, official halo-emulator E2E). Labels
it must keep: providers `SIMULATED`, HUD `EMULATED`, `HALO_REAL` =
`BLOCKED_HARDWARE`.

## Steps 4–5 — #43, #44

Retarget each to `main` after the previous layer lands and rebase onto that
exact `main`; do not keep the obsolete intermediate base. Evidence that must
stay green on each: redacted stream (free-form detail reduced to tokens,
text-bearing events rejected), fail-closed Console (DISCONNECTED /
UNAVAILABLE / UNSUPPORTED always with UNKNOWN state, silent stream times
out), reconnect (resume without duplicates, new stream id resets), backlog
(slow consumer overflow then resume from Last-Event-ID), UNKNOWN when there
is no stream, `HALO_REAL` never inferred.

## Steps 6–7 — C1, Night R1

Open PRs to `main` after #44, rebase onto the exact `main`, and re-run
`tooling/convergence/converge_night_r1.sh` before each merge.

Coupled changes in Night R1: the event stream gains `latency` and new
diagnostic codes, and the Console parses them strictly (older Consoles show
DEGRADED); runtime and Console ship together. The SSE body is
close-delimited (no chunked encoding) so dropped clients free their slot.

## Tests after each layer (lab, all exit 0)

| Layer | contracts | runtime | halo | audio | mobile + E2E | Console | analyze |
|---|---|---|---|---|---|---|---|
| #41 | 2 | 15 | 5 | 13 | 2 | 20 | 1 info (pre-existing) |
| #42 | 2 | 15 | 43 | 13 | 2 | 20 | 1 info |
| E2E | 2 | 15 | 44 | 13 | 8 | 20 | 1 info |
| #43 | 2 | 18 | 44 | 13 | 8 | 28 | 1 info |
| #44 | 2 | 26 | 44 | 13 | 9 | 37 | 1 info |
| C1 | 2 | 42 | 44 | 13 | 13 | 37 | 1 info |
| Night | 2 | 75 | 57 | 18 | 33 | 58 | 1 info |

The analyzer info is `deprecated_member_use` in `apps/mobile/lib/main.dart`
and already exists on `main`.
