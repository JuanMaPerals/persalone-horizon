#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_script="$script_dir/lockfile_guard.sh"

tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

repo="$tmp_root/persalone-halo"
mkdir -p "$repo/tooling" "$repo/apps/console"
cp "$source_script" "$repo/tooling/lockfile_guard.sh"

(
  cd "$repo"
  git init -q
  git config user.email test@example.invalid
  git config user.name 'Lockfile Guard Test'

  printf '%s\n' 'root-lock-v1' > pubspec.lock
  printf '%s\n' 'pnpm-lock-v1' > apps/console/pnpm-lock.yaml
  git add pubspec.lock apps/console/pnpm-lock.yaml tooling/lockfile_guard.sh
  git commit -qm 'seed'

  bash tooling/lockfile_guard.sh

  printf '%s\n' 'root-lock-v2' > pubspec.lock
  if bash tooling/lockfile_guard.sh >/tmp/lockfile-guard.out 2>/tmp/lockfile-guard.err; then
    printf '%s\n' 'Expected modified pubspec.lock to fail.' >&2
    exit 1
  fi

  git restore -- pubspec.lock
  printf '%s\n' 'pnpm-lock-v2' > apps/console/pnpm-lock.yaml
  if bash tooling/lockfile_guard.sh >/tmp/lockfile-guard-pnpm.out 2>/tmp/lockfile-guard-pnpm.err; then
    printf '%s\n' 'Expected modified pnpm-lock.yaml to fail.' >&2
    exit 1
  fi
)

printf '%s\n' 'lockfile guard tests passed.'
