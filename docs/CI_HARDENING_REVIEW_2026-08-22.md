# CI Hardening Review 2026-08-22

## Scope

Reviewed repository-owned CI only. The current repository contains one workflow:

- `.github/workflows/verify.yml`

The known "Code scanning AI findings" failure is not backed by a versioned workflow in this repository. Standard CodeQL must remain enabled and blocking where configured by GitHub.

## Collision Result

`TARGET_PATHS=tooling/ci_audit.sh tooling/ci_audit_test.sh docs/CI_HARDENING_REVIEW_2026-08-22.md`

`COLLISION=NO`

Open PRs modify `.github/workflows/verify.yml`, so this lane does not write that workflow.

## Findings

- No repository workflow currently contains a "Code scanning AI findings" automation block.
- The verify workflow uses read permissions and disables checkout credential persistence.
- The verify workflow runs Flutter analysis, package tests, repository preflight, secret scan, and SBOM generation.
- The verify workflow push trigger currently covers `feat/**`; changing trigger coverage would touch a workflow already modified by open PRs.

## Added Guard

`tooling/ci_audit.sh` provides a local read-only guard for:

- unsupported "Code scanning AI findings" workflow markers;
- accidental deploy or database mutation markers;
- checkout steps missing `persist-credentials: false`;
- missing least-privilege read permissions;
- missing pull request trigger;
- missing repository preflight step.
