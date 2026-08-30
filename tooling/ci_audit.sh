#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
case "$repo_root" in
  */persalone-halo) ;;
  *)
    printf '%s\n' "BLOCKED - repository path is not authorized: $repo_root" >&2
    exit 1
    ;;
esac

failures=()

if [[ ! -f .github/workflows/verify.yml ]]; then
  failures+=('Missing .github/workflows/verify.yml')
fi

if find .github/workflows -type f -print0 | xargs -0 grep -Eiq 'deploy|supabase db|db push'; then
  failures+=('Workflow contains a deployment or database mutation marker')
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
