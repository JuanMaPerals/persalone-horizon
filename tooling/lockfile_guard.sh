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

mapfile -t lockfiles < <(git ls-files '*lock*' | grep -E '(^|/)(pubspec\.lock|pnpm-lock\.yaml)$' || true)
if [[ ${#lockfiles[@]} -eq 0 ]]; then
  printf '%s\n' 'Lockfile guard passed: no tracked lockfiles.'
  exit 0
fi

dirty=()
while IFS= read -r file; do
  dirty+=("$file")
done < <(git diff --name-only -- "${lockfiles[@]}")

if [[ ${#dirty[@]} -ne 0 ]]; then
  printf '%s\n' 'BLOCKED - tracked lockfiles changed after validation:' >&2
  printf '%s\n' "${dirty[@]}" >&2
  printf '%s\n' 'Restore unintended resolver churn or commit an explicit dependency update.' >&2
  exit 1
fi

printf '%s\n' "Lockfile guard passed for ${#lockfiles[@]} tracked lockfile(s)."
