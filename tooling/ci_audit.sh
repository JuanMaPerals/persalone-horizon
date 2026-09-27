#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
# Identify the repository by its origin, not its directory name, so the
# audit runs in CI and in any worktree of this repository, and nowhere else.
origin=$(git remote get-url origin 2>/dev/null || true)
case "$origin" in
  *[:/]JuanMaPerals/persalone-horizon | *[:/]JuanMaPerals/persalone-horizon.git) ;;
  *)
    printf '%s\n' "BLOCKED - repository origin is not authorized: ${origin:-none}" >&2
    exit 1
    ;;
esac

failures=()

if [[ ! -f .github/workflows/verify.yml ]]; then
  failures+=('Missing .github/workflows/verify.yml')
fi

if find .github/workflows -type f -print0 | xargs -0 grep -Eiq 'supabase db|db push'; then
  failures+=('Workflow contains a database mutation marker')
fi

# Deployment is allowed only in workflows that never run for pull requests.
while IFS= read -r -d '' workflow; do
  if grep -Eiq 'deploy' "$workflow" &&
     grep -Eq '^[[:space:]]*pull_request' "$workflow"; then
    failures+=("$workflow: deployment in a workflow that runs for pull requests")
  fi
done < <(find .github/workflows -type f -name '*.yml' -print0)

# Privileged triggers that run untrusted pull request code are refused.
if find .github/workflows -type f -print0 |
   xargs -0 grep -Eq '^[[:space:]]*(pull_request_target|workflow_run)[[:space:]]*:'; then
  failures+=('Workflows must not use pull_request_target or workflow_run')
fi

# Every third-party action is pinned to a full commit SHA (a tag can move).
unpinned=$(
  grep -RhoE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]+[^[:space:]#]+' .github/workflows |
    sed -E 's/.*uses:[[:space:]]+//' |
    grep -Ev '^(\./|docker://)' |
    grep -Ev '@[0-9a-f]{40}$' || true
)
if [[ -n $unpinned ]]; then
  while IFS= read -r action; do
    failures+=("Action not pinned to a commit SHA: $action")
  done <<<"$unpinned"
fi

if find .github/workflows -type f -print0 | xargs -0 grep -Eiq 'code scanning ai|ai findings|ai-found'; then
  failures+=('Workflow contains unsupported Code scanning AI findings automation')
fi

checkout_count=$(
  grep -REc 'uses:[[:space:]]+actions/checkout@' .github/workflows |
    awk -F: '{sum += $NF} END {print sum + 0}'
)
persist_false_count=$(
  grep -REc 'persist-credentials:[[:space:]]+false' .github/workflows |
    awk -F: '{sum += $NF} END {print sum + 0}'
)
if [[ $checkout_count -ne $persist_false_count ]]; then
  failures+=('Every checkout step must set persist-credentials: false')
fi

if ! grep -Eq '^permissions:[[:space:]]*$' .github/workflows/verify.yml ||
   ! grep -Eq '^[[:space:]]+contents:[[:space:]]+read$' .github/workflows/verify.yml; then
  failures+=('verify workflow must declare least-privilege read permissions')
fi

if ! grep -Eq '^[[:space:]]+pull_request:[[:space:]]*$' .github/workflows/verify.yml; then
  failures+=('verify workflow must run on pull_request')
fi

if ! grep -Eq 'bash tooling/preflight\.sh --all' .github/workflows/verify.yml; then
  failures+=('verify workflow must run repository preflight')
fi

if [[ ${#failures[@]} -ne 0 ]]; then
  printf '%s\n' 'CI audit failed:' >&2
  printf '%s\n' "${failures[@]}" >&2
  exit 1
fi

printf '%s\n' 'CI audit passed.'
