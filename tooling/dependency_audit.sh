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

while IFS= read -r -d '' pubspec; do
  if ! grep -Eq '^publish_to:[[:space:]]+none$' "$pubspec"; then
    failures+=("$pubspec: local packages must declare publish_to: none")
  fi

  if grep -Eq '^dependency_overrides:' "$pubspec"; then
    failures+=("$pubspec: dependency_overrides is not allowed without review")
  fi

  while IFS= read -r line; do
    line_number=${line%%:*}
    block=$(sed -n "${line_number},$((line_number + 8))p" "$pubspec")
    if ! grep -Eq '^[[:space:]]+url:[[:space:]]+https://' <<<"$block"; then
      failures+=("$pubspec:$line_number git dependency must use https URL")
    fi
    if ! grep -Eq '^[[:space:]]+ref:[[:space:]]+[0-9a-f]{40}$' <<<"$block"; then
      failures+=("$pubspec:$line_number git dependency must pin a 40-character commit ref")
    fi
  done < <(grep -nE '^[[:space:]]+git:[[:space:]]*$' "$pubspec" || true)
done < <(git ls-files -z -- '*pubspec.yaml')

if [[ ! -f pubspec.lock ]]; then
  failures+=('pubspec.lock is required for reproducible dependency resolution')
fi

if [[ ${#failures[@]} -ne 0 ]]; then
  printf '%s\n' 'Dependency audit failed:' >&2
  printf '%s\n' "${failures[@]}" >&2
  exit 1
fi

printf '%s\n' 'Dependency audit passed.'
