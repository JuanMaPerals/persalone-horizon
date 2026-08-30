#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: tooling/preflight.sh [--all]'
}

mode='staged'
if [[ ${1:-} == '--all' ]]; then
  mode='all'
elif [[ $# -ne 0 ]]; then
  usage
  exit 64
fi

repo_root=$(git rev-parse --show-toplevel)
case "$repo_root" in
  */persalone-halo) ;;
  *)
    printf '%s\n' "BLOCKED — repository path is not authorized: $repo_root" >&2
    exit 1
    ;;
esac

files=()
if [[ $mode == 'all' ]]; then
  while IFS= read -r -d '' file; do
    files+=("$file")
  done < <(git ls-files -z)
else
  while IFS= read -r -d '' file; do
    files+=("$file")
  done < <(git diff --cached --name-only --diff-filter=ACMR -z)
fi

if [[ ${#files[@]} -eq 0 ]]; then
  printf '%s\n' 'Preflight passed: no files to inspect.'
  exit 0
fi

blocked_path='(^|/)(\.env($|\.)|secrets/|.*\.(pem|key|p12|pfx)$|id_rsa($|\.))'
for file in "${files[@]}"; do
  if [[ $file != '.env.example' && $file =~ $blocked_path ]]; then
    printf '%s\n' "BLOCKED — sensitive path is not allowed: $file" >&2
    exit 1
  fi
done

secret_pattern='BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}'
matches=()
if [[ $mode == 'all' ]]; then
  for file in "${files[@]}"; do
    if grep -Eaq -- "$secret_pattern" "$file"; then
      matches+=("$file")
    fi
  done
else
  for file in "${files[@]}"; do
    if git show ":$file" 2>/dev/null | grep -Eaq "$secret_pattern"; then
      matches+=("$file")
    fi
  done
fi
if [[ ${#matches[@]} -ne 0 ]]; then
  printf '%s\n' 'BLOCKED — potential secret marker found in:' >&2
  printf '%s\n' "${matches[@]}" >&2
  exit 1
fi

printf '%s\n' "Preflight passed for ${#files[@]} file(s) in $repo_root."
