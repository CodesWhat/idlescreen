#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

private_tracked_paths="$({
  git ls-files -- \
    .planning \
    Archive \
    Design \
    CODE_REVIEW.md \
    'docs/ROADMAP*' \
    'docs/RESEARCH*' \
    'docs/C6_*' \
    'docs/C7_*' \
    'docs/C8_*' \
    'docs/V5_*' \
    docs/baseline \
    docs/evidence \
    docs/decisions
} | sed -n '1,20p')"
[[ -z "$private_tracked_paths" ]] ||
  fail "private planning material is tracked:\n$private_tracked_paths"

grep -Fqx '/.planning/' .gitignore ||
  fail "the local-only .planning directory must be ignored"

for public_file in \
  LICENSE \
  THIRD_PARTY_NOTICES.md \
  CHANGELOG.md \
  CODE_OF_CONDUCT.md \
  CONTRIBUTING.md \
  docs/ASSET_PROVENANCE.md \
  docs/assets/idlescreen-icon.svg \
  docs/assets/idlescreen-saver.svg \
  SECURITY.md \
  .coderabbit.yaml \
  .github/CODEOWNERS \
  .github/FUNDING.yml \
  .github/workflows/codeql.yml \
  .github/ISSUE_TEMPLATE/bug_report.yml \
  .github/ISSUE_TEMPLATE/config.yml \
  scripts/generate-brand-assets.sh \
  scripts/generate-homebrew-cask.sh \
  scripts/test-public-release-contract.sh \
  renovate.json; do
  [[ -f "$public_file" ]] ||
    fail "required public repository file is missing: $public_file"
done

codeql_workflow=.github/workflows/codeql.yml
for codeql_contract in \
  'language: actions' \
  'language: c-cpp' \
  'language: python' \
  'language: swift' \
  'runner: macos-26' \
  'build-mode: manual' \
  'xcodebuild build' \
  'ARCHS=arm64' \
  'security-events: write'; do
  grep -Fq "$codeql_contract" "$codeql_workflow" ||
    fail "advanced CodeQL workflow is missing: $codeql_contract"
done
if grep -Eq 'uses: [^[:space:]]+@v[0-9]' "$codeql_workflow"; then
  fail "advanced CodeQL actions must use full commit SHAs"
fi

tracked_redistribution_archives="$(git ls-files -- '*.zip' '*.ttf' '*.otf' '*.dmg' '*.pkg')"
[[ -z "$tracked_redistribution_archives" ]] ||
  fail "binary redistribution input is tracked:\n$tracked_redistribution_archives"

if git grep -n -I -E '/Users/sbenson|archived_sessions|sbenson' -- \
  . ':(exclude)scripts/test-repository-layout.sh'; then
  fail "tracked public files contain a local identity or filesystem path"
fi

grep -Fq 'AppexSaverMinimal' THIRD_PARTY_NOTICES.md ||
  fail "the AppexSaverMinimal attribution is missing"
grep -Fq 'Copyright (c) 2026 Guillaume Louel' THIRD_PARTY_NOTICES.md ||
  fail "the AppexSaverMinimal copyright notice is incomplete"
grep -Fq 'path: THIRD_PARTY_NOTICES.md' project.yml ||
  fail "the distributed app must embed its third-party notices"

grep -Fq '$project_root/.planning/evidence/' scripts/run-performance-r1.sh ||
  fail "performance evidence must default to the ignored .planning tree"

[[ -f IdleScreen.xcodeproj/project.pbxproj ]] ||
  fail "IdleScreen.xcodeproj is not the canonical generated project"
[[ "$(find . -maxdepth 1 -type d -name '*.xcodeproj' -print | wc -l | tr -d ' ')" == 1 ]] ||
  fail "the repository root must contain exactly one Xcode project"
[[ -z "$(find . -maxdepth 1 -type d -name 'Idlescreen.xcodeproj' -print)" ]] ||
  fail "the superseded Idlescreen.xcodeproj remains at the repository root"

grep -Fqx 'name: IdleScreen' project.yml ||
  fail "project.yml does not declare the canonical IdleScreen project name"

for legacy_root in Idlescreen IdlescreenHelper IdlescreenSettings IdlescreenTests; do
  [[ ! -e "$legacy_root" ]] ||
    fail "$legacy_root remains beside the modern product"
done

if grep -Eq '^  (Idlescreen|IdlescreenHelper|IdlescreenSettings|IdlescreenTests):$' project.yml; then
  fail "the active project still declares a legacy product or test target"
fi
if grep -Fq 'Archive/Legacy' project.yml; then
  fail "the active project reaches back into archived source"
fi

root_reference_archives="$(find . -maxdepth 1 -type f -name '*.zip' -print)"
[[ -z "$root_reference_archives" ]] ||
  fail "reference archives belong under .planning, not the repository root: $root_reference_archives"

[[ ! -e IdleScreenApp/IdleScreenVisualsView.swift ]] ||
  fail "the superseded pre-Studio IdleScreenVisualsView source remains active"
[[ ! -e release ]] ||
  fail "raw release artifacts must not accumulate in the source repository"
for retired_view in \
  'struct SaverView' \
  'struct HealthView' \
  'struct CameraDeferredView' \
  'struct SystemStatusCard'; do
  ! grep -Fq "$retired_view" IdleScreenApp/SystemViews.swift ||
    fail "the superseded pre-Studio declaration remains active: $retired_view"
done

if grep -Eq -- '-scheme (Idlescreen|IdlescreenSettings|IdlescreenTests)([[:space:]\\]|$)' \
  .github/workflows/ci.yml scripts/test-phase1.sh; then
  fail "the active CI/test gate still builds a legacy scheme"
fi

grep -Fq '[[ "$(xcodegen --version)" == "Version: 2.46.0" ]]' \
  .github/workflows/ci.yml ||
  fail "CI must enforce the XcodeGen version that owns the checked-in project"
grep -Fq 'git diff --exit-code -- IdleScreen.xcodeproj' \
  .github/workflows/ci.yml ||
  fail "CI must reject tracked generated-project drift"
grep -Fq 'git ls-files --others --exclude-standard -- IdleScreen.xcodeproj' \
  .github/workflows/ci.yml ||
  fail "CI must reject newly generated untracked project metadata"

grep -Fq 'ASCII art screen saver for macOS' README.md ||
  fail "README.md does not identify the product"

echo "PASS: one canonical modern project is active and private planning material is excluded."
