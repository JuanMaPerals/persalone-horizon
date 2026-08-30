#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_script="$script_dir/preflight.sh"

tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

repo="$tmp_root/persalone-halo"
mkdir -p "$repo/tooling"
cp "$source_script" "$repo/tooling/preflight.sh"

(
  cd "$repo"
  git init -q
  git config user.email test@example.invalid
  git config user.name 'Preflight Test'

  printf '%s\n' 'clean' > safe.txt
  git add safe.txt
  git commit -qm 'seed'

  blocked_marker="AKIA$(printf '%016d' 1)"
  printf '%s\n' "$blocked_marker" > safe.txt
  git add safe.txt
  printf '%s\n' 'clean working tree' > safe.txt

  if bash tooling/preflight.sh >/tmp/preflight-pass.out 2>/tmp/preflight-pass.err; then
    printf '%s\n' 'Expected staged secret scan to fail.' >&2
    exit 1
  fi

  git restore safe.txt
  git restore --staged safe.txt

  printf '%s\n' 'clean staged value' > safe.txt
  git add safe.txt
  bash tooling/preflight.sh

  git commit -qm 'safe update'

  mkdir -p 'odd paths'
  space_path='odd paths/name with spaces.txt'
  tab_path=$(printf 'odd paths/name\twith\ttabs.txt')
  newline_path=$(printf 'odd paths/name\nwith\nnewlines.txt')
  unicode_path="odd paths/unicode-caf$(printf '\303\251').txt"
  dash_path='--leading-dash.txt'
  for path in "$space_path" "$tab_path" "$newline_path" "$unicode_path" "$dash_path"; do
    printf '%s\n' 'safe odd path' > "$path"
    git add -- "$path"
  done
  bash tooling/preflight.sh
  bash tooling/preflight.sh --all
  git commit -qm 'odd paths'

  git mv -- "$space_path" 'odd paths/renamed path.txt'
  git rm -- "$tab_path"
  bash tooling/preflight.sh

  printf '%s\n' "$blocked_marker" > "$newline_path"
  git add -- "$newline_path"
  printf '%s\n' 'clean working tree again' > "$newline_path"

  if bash tooling/preflight.sh >/tmp/preflight-newline.out 2>/tmp/preflight-newline.err; then
    printf '%s\n' 'Expected newline-path staged secret scan to fail.' >&2
    exit 1
  fi

  printf '%s\n' 'empty' > .env
  git add .env
  if bash tooling/preflight.sh >/tmp/preflight-env.out 2>/tmp/preflight-env.err; then
    printf '%s\n' 'Expected sensitive staged path scan to fail.' >&2
    exit 1
  fi
)

printf '%s\n' 'preflight tests passed.'
