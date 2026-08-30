#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_script="$script_dir/ci_audit.sh"

tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

repo="$tmp_root/persalone-halo"
mkdir -p "$repo/.github/workflows" "$repo/tooling"
cp "$source_script" "$repo/tooling/ci_audit.sh"

(
  cd "$repo"
  git init -q
  git config user.email test@example.invalid
  git config user.name 'CI Audit Test'

  cat > .github/workflows/verify.yml <<'YAML'
name: verify
on:
  pull_request:
permissions:
  contents: read
jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false
      - run: bash tooling/preflight.sh --all
YAML
  git add .github/workflows/verify.yml tooling/ci_audit.sh
  git commit -qm 'seed'
  bash tooling/ci_audit.sh

  sed -i '/persist-credentials/d' .github/workflows/verify.yml
  if bash tooling/ci_audit.sh >/tmp/ci-audit.out 2>/tmp/ci-audit.err; then
    printf '%s\n' 'Expected checkout credential persistence audit to fail.' >&2
    exit 1
  fi

  printf '%s\n' '# Code scanning AI findings' >> .github/workflows/verify.yml
  if bash tooling/ci_audit.sh >/tmp/ci-ai.out 2>/tmp/ci-ai.err; then
    printf '%s\n' 'Expected unsupported AI findings audit to fail.' >&2
    exit 1
  fi
)

printf '%s\n' 'ci audit tests passed.'
