# HALO recovery review and execution worklist

**Assessment date:** 2026-08-22

**Scope:** `JuanMaPerals/persalone-halo`, the connected HALO Supabase project, and the active server-side control-plane functions.

**Change authority:** source changes only. This review made **no merge, deployment, migration, or destructive infrastructure change**.

## Recovery verdict

The authorized repository is a Flutter/Dart companion and contract workspace at `f0138aa1f21fe7690f57262c96eb5f0e0c80ccfa`; it did not contain the requested `agent/p0-horizon-prototype` branch after `git fetch origin --prune`, nor did it contain a prior Dockview/React Flow console implementation. The historical hashes supplied for recovery were not present in the fetched object database. Consequently, the continuation branch starts from the verified current `main` tip and introduces the Engineering Console V2 as an isolated application, preserving rather than replacing the existing mobile/runtime contracts.

The HALO Supabase project is active and contains an operational server-side bridge. Its public control-plane API requires JWT verification, the dispatcher keeps the Manus API key server-side, and the webhook handler verifies signed inbound notifications with a bounded clock skew and event-id deduplication. The observed HALO registry record is enabled, has a verified persistent destination, and permits a restricted set of message types. The review did not expose or copy any credential or destination identifier.

> **Control-plane status: NOT PASS.** The implementation is structurally capable of the intended route for HALO, but an authenticated caller-to-result end-to-end execution has not been demonstrated. The registry also contains only the verified `HALO` record in this project; no persistent Manus destination may be invented for the three remaining logical workspaces.

## Verified P0 work

| ID | Finding | Evidence | Executable work | Acceptance evidence |
| --- | --- | --- | --- | --- |
| P0-EC-01 | The approved engineering workstation did not exist in the recovered repository. | Current tree contained only the Flutter companion and Dart packages; no Dockview or React Flow surface existed. | Completed in this branch: add `apps/engineering-console` with Dockview, React Flow, normalized `HaloTraceEvent`, shared focus state, replay, logs, inspector, monitors, command palette, and deterministic fixture data. | Type-check, four trace-store unit tests, production build, and live browser interaction checks pass. |
| P0-CP-01 | The HALO control-plane path requires a real authenticated end-to-end proof before it can be declared ready. | Active server-side API, dispatcher, and webhook functions were inspected; no completed caller-to-result proof was run. | Execute one scoped HALO `SEND_JOB` with an authorized client principal, observe exactly one queued/accepted job, signed webhook, deduplicated inbox result, and successful authorized result retrieval. | Correlation id links request, queue record, Manus task result, inbound webhook, and inbox record without manual copying or caller-supplied secret. |
| P0-CP-02 | The workspace registry verified in HALO covers only `HALO`. | Registry query returned one enabled record with verified destination; no other rows were observed. | Discover destination identifiers from their own authorized sources for `PERSALONE_BUSINESS`, `PERSALONE_APP`, and `JUANMAPERALS_WEB`; register each only after verification. | Each registry row is enabled, restricts permitted message types, has a verified persistent destination, and rejects unknown workspaces fail-closed. |
| P0-CP-03 | Caller identity enforcement depends on the JWT claims and database grants, which were not proven by an adversarial invocation. | The external API requires JWT verification; RPC definitions use `SECURITY DEFINER`. | Test unauthenticated, malformed-claim, cross-workspace, unauthorized message-type, duplicate idempotency-key, and valid caller requests. Review function execute grants and JWT-to-workspace authorization in the database migration. | Unauthorized calls are rejected without queue mutation; only an authorized caller can view results for its workspace. |

## Verified P1 work

| ID | Finding | Evidence | Executable work | Acceptance evidence |
| --- | --- | --- | --- | --- |
| P1-SEC-01 | The Supabase advisor reports RLS enabled with no policies on `agent_bridge.messages`, `projects`, and `webhook_events`. This may be intentional for a private-schema/service-role design, but it remains a review item. | Connected-project security advisor, 2026-08-22. | Explicitly document the access model; verify that application roles cannot access bridge tables directly, and add restrictive policies or revoke table grants where needed. | Advisory is resolved or accepted with a documented service-role-only justification and automated authorization test. |
| P1-SEC-02 | `pg_net` is installed in the `public` schema. | Connected-project security advisor, 2026-08-22. | Schedule a migration only after DDL approval to relocate or otherwise reduce the exposed extension surface. | Advisor no longer reports the warning and bridge dispatch remains operational. |
| P1-CP-01 | The dispatcher verifies a private header but the edge-function platform marks JWT verification disabled. | Function metadata and source inspection. | Keep the dispatcher non-public through network/database invocation constraints; add a negative direct-invocation test and rotate the internal dispatch secret through managed configuration as required. | Direct public invocation is rejected; only the intended queue trigger can dispatch. |
| P1-ARCH-01 | The Engineering Console is a new TypeScript application beside a Flutter workspace. | Recovered architecture and verified branch content. | Add a CI job that installs the console with a frozen lockfile, executes `lint`, `test`, and `build`; publish no bundle until deployment approval. | Console checks are required on pull requests affecting its path. |
| P1-PERF-01 | The initial console production bundle is approximately 756 kB before compression, triggering Vite’s chunk-size warning. | Local production build, 2026-08-22. | Profile first load and split graph/docking features only if measured performance needs it. | Measured interactive readiness target is met on the agreed engineering workstation baseline. |
| P1-A11Y-01 | Keyboard command invocation and named controls exist, but formal accessibility testing has not yet been run. | Live preview inspection and source review. | Add keyboard traversal, focus-order, screen-reader, contrast, and reduced-motion tests before general use. | Automated accessibility scan plus manual keyboard and screen-reader checklist passes. |
| P1-SC-01 | Third-party actions and npm dependencies are locked locally but CI action references use floating major tags. | `.github/workflows/verify.yml` and console package lock. | Pin CI action commits with an approved update mechanism; retain lockfile review and dependency scanning. | CI provenance review finds no mutable action reference. |

## Out-of-scope and preserved boundaries

The review found no tracked marker for a Manus key, Supabase service-role key, OpenAI key, webhook secret, or caller-provided dispatch credential in the authorized repository. The HALO adapter’s physical audio claims remain `PREPARED` or `BLOCKED`; console fixtures do not alter those truth labels. No upstream Brilliant Labs SDK, firmware, pairing, Lua, OTA, device, audio, database schema, edge function, GitHub pull request, deployment, or protected branch configuration was modified.

## Gated next operation

The next control-plane operation is an **authenticated, non-destructive E2E test**. It is blocked until a verified caller principal for `HALO` is available and the project owner authorizes use of the live persisted workflow. It must not be simulated with an invented destination or bypassed with a service-role credential. Until that test succeeds, the minimal `SEND_JOB` and `GET_RESULTS` contracts remain intentionally unpublished as production contracts.
