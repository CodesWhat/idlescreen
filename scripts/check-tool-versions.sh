#!/bin/bash

# Reports where locally installed gate tools disagree with the versions
# docs/BUILDING.md declares.
#
# Homebrew installs whatever is current and the Qlty installer tracks its own
# latest, so a local checkout drifts from the gate without saying so. CI asserts
# xcodegen exactly and pins Qlty to a commit SHA, which means drift surfaces as
# a CI disagreement long after the local run looked clean. This makes it visible
# up front.
#
# xcodegen is a hard failure because it rewrites the checked-in project and CI
# asserts the same exact string. The rest are warnings: they change findings
# rather than generated artifacts.

set -uo pipefail

# Keep in step with the tool list in docs/BUILDING.md.
expected_xcodegen="2.46.0"
expected_lefthook="2.1.11"
expected_qlty="0.618.0"
expected_actionlint="1.7.12"
expected_zizmor="1.29.0"

status=0
warnings=0

# Prints the first version-looking string in a command's first line of output.
observed() {
  local binary="$1"
  shift
  command -v "$binary" >/dev/null 2>&1 || { printf 'missing'; return; }
  "$binary" "$@" 2>&1 | head -1 |
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

check() {
  local label="$1" expected="$2" actual="$3" hard="$4"
  if [[ -z "$actual" || "$actual" == missing ]]; then
    echo "FAIL: $label is not installed (expected $expected)"
    status=1
    return
  fi
  if [[ "$actual" == "$expected" ]]; then
    echo "  ok    $label $actual"
    return
  fi
  if [[ "$hard" == hard ]]; then
    echo "FAIL: $label is $actual, the gate requires $expected"
    status=1
  else
    echo "WARN: $label is $actual, docs/BUILDING.md declares $expected"
    warnings=$((warnings + 1))
  fi
}

echo "Checking gate tool versions against docs/BUILDING.md"
check xcodegen   "$expected_xcodegen"   "$(observed xcodegen --version)"   hard
check lefthook   "$expected_lefthook"   "$(observed lefthook version)"     soft
check qlty       "$expected_qlty"       "$(observed qlty --version)"       soft
check actionlint "$expected_actionlint" "$(observed actionlint --version)" soft
check zizmor     "$expected_zizmor"     "$(observed zizmor --version)"     soft

if [[ "$status" -ne 0 ]]; then
  echo "FAIL: local tooling disagrees with the gate."
  exit 1
fi
if [[ "$warnings" -gt 0 ]]; then
  echo "PASS with $warnings version warning(s). CI remains the authority."
  exit 0
fi
echo "PASS: local gate tooling matches docs/BUILDING.md."
