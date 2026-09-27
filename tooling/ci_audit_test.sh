#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_script="$script_dir/ci_audit.sh"

tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

repo="$tmp_root/any-directory-name"
mkdir -p "$repo/.github/workflows" "$repo/tooling"
cp "$source_script" "$repo/tooling/ci_audit.sh"

(
  cd "$repo"
  git init -q
  git config user.email test@example.invalid
  git config user.name 'CI Audit Test'
  git remote add origin https://github.com/JuanMaPerals/persalone-horizon.git

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
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
        with:
          persist-credentials: false
      - run: bash tooling/preflight.sh --all
YAML
  git add .github/workflows/verify.yml tooling/ci_audit.sh
  git commit -qm 'seed'
  bash tooling/ci_audit.sh

  cp .github/workflows/verify.yml "$tmp_root/verify.good"
  expect_fail() {
    if bash tooling/ci_audit.sh >"$tmp_root/case.out" 2>"$tmp_root/case.err"; then
      printf '%s\n' "Expected the CI audit to fail: $1" >&2
      exit 1
    fi
    cp "$tmp_root/verify.good" .github/workflows/verify.yml
    rm -f .github/workflows/extra.yml
  }

  sed -i 's#actions/checkout@[0-9a-f]\{40\}#actions/checkout@v4#' .github/workflows/verify.yml
  expect_fail 'action pinned by a tag'

  printf '%s\n' 'on:' '  pull_request_target:' > .github/workflows/extra.yml
  expect_fail 'pull_request_target trigger'

  printf '%s\n' 'on:' '  workflow_run:' > .github/workflows/extra.yml
  expect_fail 'workflow_run trigger'

  printf '%s\n' 'on:' '  pull_request:' 'jobs:' '  deploy:' > .github/workflows/extra.yml
  expect_fail 'deployment in a pull request workflow'

  printf '%s\n' 'on:' '  push:' 'jobs:' '  deploy:' '    steps:' \
    '      - uses: actions/deploy-pages@d6db90164ac5ed86f2b6aed7e0febac5b3c0c03e # v4.0.5' \
    > .github/workflows/extra.yml
  bash tooling/ci_audit.sh
  rm .github/workflows/extra.yml

  git remote set-url origin https://github.com/someone-else/persalone-horizon.git
  expect_fail 'foreign repository origin'
  git remote set-url origin https://github.com/JuanMaPerals/persalone-horizon.git
  bash tooling/ci_audit.sh

  sed -i '/persist-credentials/d' .github/workflows/verify.yml
  if bash tooling/ci_audit.sh "$tmp_root"/ci-audit.out 2"$tmp_root"/ci-audit.err; then
    printf '%s\n' 'Expected checkout credential persistence audit to fail.' >&2
    exit 1
  fi

  printf '%s\n' '# Code scanning AI findings' >> .github/workflows/verify.yml
  if bash tooling/ci_audit.sh "$tmp_root"/ci-ai.out 2"$tmp_root"/ci-ai.err; then
    printf '%s\n' 'Expected unsupported AI findings audit to fail.' >&2
    exit 1
  fi
)

printf '%s\n' 'ci audit tests passed.'
