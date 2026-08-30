#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_script="$script_dir/dependency_audit.sh"

tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

repo="$tmp_root/persalone-halo"
mkdir -p "$repo/tooling"
cp "$source_script" "$repo/tooling/dependency_audit.sh"

(
  cd "$repo"
  git init -q
  git config user.email test@example.invalid
  git config user.name 'Dependency Audit Test'

  cat > pubspec.yaml <<'YAML'
name: fixture
publish_to: none
dependencies:
  safe_git:
    git:
      url: https://github.com/example/safe.git
      ref: 0123456789abcdef0123456789abcdef01234567
YAML
  touch pubspec.lock
  git add pubspec.yaml pubspec.lock tooling/dependency_audit.sh
  git commit -qm 'seed'
  bash tooling/dependency_audit.sh

  sed -i '/ref:/d' pubspec.yaml
  if bash tooling/dependency_audit.sh >/tmp/dependency-audit.out 2>/tmp/dependency-audit.err; then
    printf '%s\n' 'Expected unpinned git dependency to fail.' >&2
    exit 1
  fi

  cat > pubspec.yaml <<'YAML'
name: fixture
publish_to: none
dependency_overrides:
  unsafe: any
YAML
  if bash tooling/dependency_audit.sh >/tmp/dependency-override.out 2>/tmp/dependency-override.err; then
    printf '%s\n' 'Expected dependency_overrides to fail.' >&2
    exit 1
  fi
)

printf '%s\n' 'dependency audit tests passed.'
