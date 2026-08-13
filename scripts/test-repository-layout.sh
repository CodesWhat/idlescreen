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
  docs/assets/idlescreen-logo.png \
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

brand_asset_generator=scripts/generate-brand-assets.sh
grep -Fq 'icon_source="$project_root/docs/assets/idlescreen-logo.png"' \
  "$brand_asset_generator" ||
  fail "the app icon must be generated from the canonical CRT product logo"

codeql_workflow=.github/workflows/codeql.yml
for codeql_contract in \
  'language: actions' \
  'language: c-cpp' \
  'language: python' \
  'language: swift' \
  'runner: macos-26' \
  'build-mode: manual' \
  'arch -arm64 /opt/homebrew/bin/brew install xcodegen' \
  'xcodebuild build' \
  'ARCHS=arm64' \
  "EXCLUDED_SOURCE_FILE_NAMES='*.metal'" \
  'security-events: write'; do
  grep -Fq -- "$codeql_contract" "$codeql_workflow" ||
    fail "advanced CodeQL workflow is missing: $codeql_contract"
done
action_ref_is_pinned() {
  local action_ref="$1"
  [[ "$action_ref" == ./* || "$action_ref" =~ ^[^@[:space:]]+@[0-9a-f]{40}$ ]]
}
if action_ref_is_pinned actions/checkout@main ||
   action_ref_is_pinned actions/checkout@4.4.0 ||
   ! action_ref_is_pinned actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; then
  fail "the action-reference validator must reject every mutable external reference"
fi
while IFS= read -r action_ref; do
  action_ref_is_pinned "$action_ref" ||
    fail "advanced CodeQL actions must use full commit SHAs: $action_ref"
done < <(awk '/uses:/ { print $2 }' "$codeql_workflow")

coderabbit_tone_length="$(ruby -ryaml -e 'print YAML.load_file(ARGV.fetch(0)).fetch("tone_instructions").length' .coderabbit.yaml)" ||
  fail "CodeRabbit configuration must parse"
if ((coderabbit_tone_length > 250)); then
  fail "CodeRabbit tone_instructions exceeds the 250-character schema limit"
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

canonical_paths=(
  Products/IdleScreenAgentExecutable
  Products/IdleScreenApp
  Products/IdleScreenCameraAgentExecutable
  Products/IdleScreenScreenSaver
  Sources/IdleScreenAgent
  Sources/IdleScreenCamera
  Sources/IdleScreenCameraAgent
  Sources/IdleScreenCameraAtomics
  Sources/IdleScreenCore
  Sources/IdleScreenDisplay
  Sources/IdleScreenPerformance
  Sources/IdleScreenProduct
  Sources/IdleScreenRenderer
  Sources/IdleScreenSystem
  Tests/IdleScreenAgentTests
  Tests/IdleScreenAppCameraTests
  Tests/IdleScreenAppCompileGateTests
  Tests/IdleScreenCameraAgentTests
  Tests/IdleScreenCameraTests
  Tests/IdleScreenCoreTestSupport
  Tests/IdleScreenCoreTests
  Tests/IdleScreenDisplayTests
  Tests/IdleScreenPerformanceTests
  Tests/IdleScreenRendererTests
  Tests/IdleScreenScreenSaverTests
  Tests/IdleScreenSyntheticGateTests
  Tests/IdleScreenSystemTests
  Support/IdleScreenPerformanceExecutable
  Support/IdleScreenSyntheticGate
  Support/IdleScreenSyntheticHostedGateExtension
)

for canonical_path in "${canonical_paths[@]}"; do
  [[ -d "$canonical_path" ]] ||
    fail "canonical repository directory is missing: $canonical_path"
done

flat_modern_roots="$(find . -maxdepth 1 -type d -name 'IdleScreen*' ! -name '*.xcodeproj' -print | sort)"
[[ -z "$flat_modern_roots" ]] ||
  fail "modern product directories must not remain flat at the repository root:\n$flat_modern_roots"

stale_root_references="$({
  for canonical_path in "${canonical_paths[@]}"; do
    canonical_name="${canonical_path#*/}"
    while IFS= read -r reference; do
      [[ "$reference" == *"Products/$canonical_name/"* ]] && continue
      [[ "$reference" == *"Sources/$canonical_name/"* ]] && continue
      [[ "$reference" == *"Tests/$canonical_name/"* ]] && continue
      [[ "$reference" == *"Support/$canonical_name/"* ]] && continue
      [[ "$reference" == *"-only-testing:"* ]] && continue
      [[ "$reference" == *"'/$canonical_name/"* ]] && continue
      printf '%s\n' "$reference"
    done < <(git grep -n -I -F "$canonical_name/" -- . ':(exclude).planning/**' || true)
  done
} | sort -u | sed -n '1,20p')"
[[ -z "$stale_root_references" ]] ||
  fail "tracked files still reference pre-layout root paths:\n$stale_root_references"

if grep -Eq '^  (Idlescreen|IdlescreenHelper|IdlescreenSettings|IdlescreenTests):$' project.yml; then
  fail "the active project still declares a legacy product or test target"
fi
if grep -Fq 'Archive/Legacy' project.yml; then
  fail "the active project reaches back into archived source"
fi

root_reference_archives="$(find . -maxdepth 1 -type f -name '*.zip' -print)"
[[ -z "$root_reference_archives" ]] ||
  fail "reference archives belong under .planning, not the repository root: $root_reference_archives"

[[ ! -e Products/IdleScreenApp/IdleScreenVisualsView.swift ]] ||
  fail "the superseded pre-Studio IdleScreenVisualsView source remains active"
[[ ! -e release ]] ||
  fail "raw release artifacts must not accumulate in the source repository"
for retired_view in \
  'struct SaverView' \
  'struct HealthView' \
  'struct CameraDeferredView' \
  'struct SystemStatusCard'; do
  ! grep -Fq "$retired_view" Products/IdleScreenApp/SystemViews.swift ||
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
