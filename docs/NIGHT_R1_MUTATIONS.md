# Night R1 — adversarial mutations

Each mutation was applied alone to `feat/night-r1@f906ac7`, the suites that
should catch it were run, and the file was restored byte for byte (worktree
clean afterwards). A RED counts only when a test assertion fails; none of the
REDs below come from a compile error.

| Id | Mutation | Suites | Result |
|---|---|---|---|
| M1 | Runtime stale-turn guard removed (`turn < _lastDeliveredTurn`) | runtime (-3), E2E emulated (-1) | DETECTED |
| M2 | Panic does not invalidate the controller generation | runtime (-1) | DETECTED |
| M3 | Remote matrix allows START | runtime (-3) | DETECTED |
| M4 | Remote `commandId` dedupe disabled | runtime (-1) | DETECTED |
| M5 | Console ignores stream sequence gaps | Console (1 failed) | DETECTED |
| M6 | Console keeps rendering state when not LIVE (fail-open) | Console (3 failed) | DETECTED |
| M7 | Caption `"` not escaped in the Lua literal | halo (-11), E2E (-2) | DETECTED |
| M8 | Page command does not clear the framebuffer | halo (-38), E2E (-19) | DETECTED (builder self-check) |
| M8b | Same, with the acceptance grammar changed to match | E2E (-1: "a new caption leaves nothing of the previous page behind", real emulator framebuffer) | DETECTED |
| M9 | Caption adapter claims HALO_REAL for any transport | halo (-2), E2E (-2) | DETECTED |
| M10 | Runtime trusts a delivery whose environment differs from the adapter's | runtime (-1) | DETECTED |

Also attacked during the night:

- Latency: measuring on the wall clock, or reporting caption intervals for
  undelivered captions, turns `turn_latency_test.dart` red.
- SSE slot leak: the pre-fix server fails the new "abruptly dropped clients
  free their slot" test.
- Caption composer: 3000-case fuzz plus a real Lua 5.4 oracle over 8193
  generated pages (0 failures).

No mutation survived, so no test had to be strengthened. M8b has a single
semantic detector (the emulator framebuffer); a unit test on the page
command order would add a second, cheaper one.
