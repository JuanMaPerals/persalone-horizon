#!/usr/bin/env bash
# Deterministic synthetic convergence of the PR chain onto main, locally.
#
#   #41 -> #42 -> E2E -> #43 -> #44 -> C1 -> night-r1
#
# Each layer is squashed onto origin/main in a NEW local worktree, the way a
# GitHub squash merge would land it, and the full suite runs after every
# layer. Nothing is pushed and main is never modified.
#
# Usage: tooling/convergence/converge_night_r1.sh <new-worktree-dir> [log-dir]
# Env:   HORIZON_E2E_PYTHON (required for the emulated E2E), SKIP_TESTS=1.
set -uo pipefail

LAB=${1:?usage: converge_night_r1.sh <new-worktree-dir> [log-dir]}
LOGS=${2:-$LAB.logs}
REPO=$(git rev-parse --show-toplevel)
BRANCH=lab/convergence-$(date -u +%Y%m%d%H%M%S)

# The only conflicting layer (#42 on top of #41) is resolved exactly as in the
# E2E composition merge 62dfdf7 (export union + that merge's test file).
RESOLUTION=62dfdf7
RESOLVED_FILES=(
  packages/halo_adapter/lib/persalone_halo_adapter.dart
  packages/halo_adapter/test/halo_device_adapter_test.dart
)

mkdir -p "$LOGS"
SUMMARY=$LOGS/summary.txt
: > "$SUMMARY"
say() { echo "$*" | tee -a "$SUMMARY"; }
die() { say "FAIL $*"; exit 1; }

[ -e "$LAB" ] && die "$LAB already exists; pick a new directory"
git -C "$REPO" fetch -q origin || die "fetch"
ref() { git -C "$REPO" rev-parse --verify -q "origin/$1" || die "missing origin/$1"; }
MAIN=$(ref main)
L41=$(ref feat/caption-slice-r1)
L42=$(ref feat/halo-bounded-display-r1)
E2E=$(ref feat/e2e-emulated-r1)
L43=$(ref feat/runtime-event-stream-r1)
L44=$(ref feat/runtime-live-stream-r1)
C1=$(ref feat/runtime-control-c1)
NIGHT=$(ref feat/night-r1)
git -C "$REPO" merge-base --is-ancestor "$RESOLUTION" "$E2E" || die "$RESOLUTION is not in the E2E layer"
say "BASE main=${MAIN:0:7} night=${NIGHT:0:7}"

git -C "$REPO" worktree add -q -b "$BRANCH" "$LAB" "$MAIN" || die "worktree add"
cd "$LAB" || die "cd $LAB"
export GIT_AUTHOR_NAME=convergence-lab GIT_AUTHOR_EMAIL=lab@localhost
export GIT_COMMITTER_NAME=convergence-lab GIT_COMMITTER_EMAIL=lab@localhost

run_tests() { # $1 layer
  [ "${SKIP_TESTS:-0}" = 1 ] && { say "TESTS $1 skipped"; return 0; }
  local l=$1 rc total=0
  for p in contracts translation_runtime halo_adapter audio_adapters; do
    [ -d "packages/$p" ] || continue
    if grep -q 'sdk: flutter' "packages/$p/pubspec.yaml"; then
      (cd "packages/$p" && flutter test) > "$LOGS/$l.$p.log" 2>&1
    else
      (cd "packages/$p" && dart test) > "$LOGS/$l.$p.log" 2>&1
    fi
    rc=$?; total=$((total + rc)); say "TESTS $l $p rc=$rc"
  done
  (cd apps/mobile && env HORIZON_E2E_REQUIRED=1 HORIZON_E2E_NODE=${HORIZON_E2E_NODE:-node} flutter test) > "$LOGS/$l.mobile.log" 2>&1
  rc=$?; total=$((total + rc)); say "TESTS $l mobile+e2e rc=$rc"
  flutter analyze --no-fatal-infos > "$LOGS/$l.analyze.log" 2>&1
  rc=$?; total=$((total + rc)); say "TESTS $l analyze rc=$rc"
  (cd apps/engineering-console && corepack pnpm@10 install --frozen-lockfile && corepack pnpm@10 test && corepack pnpm@10 lint) > "$LOGS/$l.console.log" 2>&1
  rc=$?; total=$((total + rc)); say "TESTS $l console rc=$rc"
  git checkout -q -- pubspec.lock 2>/dev/null
  [ "$total" = 0 ] || die "tests red at layer $l"
}

commit_layer() { # $1 layer
  git commit -q -m "lab: squash $1" || die "commit $1"
  say "LAYER $1 tree=$(git rev-parse --short HEAD^{tree})"
}

# 1. #41
git merge -q --squash "$L41" > "$LOGS/41.merge.log" 2>&1 || die "#41 conflicts"
commit_layer '#41'; run_tests 41

# 2. #42, deterministic resolution
if ! git merge -q --squash "$L42" > "$LOGS/42.merge.log" 2>&1; then
  CONFLICTS=$(git diff --name-only --diff-filter=U | sort | tr '\n' ' ')
  EXPECTED=$(printf '%s\n' "${RESOLVED_FILES[@]}" | sort | tr '\n' ' ')
  [ "$CONFLICTS" = "$EXPECTED" ] || die "#42 unexpected conflicts: $CONFLICTS"
  say "CONFLICTS #42: $CONFLICTS-> resolved from $RESOLUTION"
  git checkout "$RESOLUTION" -- "${RESOLVED_FILES[@]}" && git add "${RESOLVED_FILES[@]}"
fi
[ "$(git write-tree)" = "$(git rev-parse "$RESOLUTION^{tree}")" ] || die "#42 tree differs from $RESOLUTION"
commit_layer '#42'; run_tests 42

# 3..7. Linear layers: apply exactly each layer's own delta.
apply_layer() { # $1 name, $2 from, $3 to
  git diff --binary "$2" "$3" | git apply --index --3way > "$LOGS/$1.apply.log" 2>&1 \
    || die "$1 does not apply: $(git diff --name-only --diff-filter=U | tr '\n' ' ')"
  [ "$(git write-tree)" = "$(git rev-parse "$3^{tree}")" ] || die "$1 tree differs from its branch"
  commit_layer "$1"; run_tests "$1"
}
apply_layer E2E "$RESOLUTION" "$E2E"
apply_layer '#43' "$E2E" "$L43"
apply_layer '#44' "$L43" "$L44"
apply_layer C1 "$L44" "$C1"
apply_layer night "$C1" "$NIGHT"

[ "$(git rev-parse HEAD^{tree})" = "$(git rev-parse "$NIGHT^{tree}")" ] || die "final tree differs from night"
say "CONVERGENCE_READY final_tree=$(git rev-parse --short HEAD^{tree}) equals feat/night-r1@${NIGHT:0:7}"
