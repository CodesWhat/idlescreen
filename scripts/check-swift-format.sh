#!/bin/bash

set -euo pipefail

mode="${1:-changed}"
case "$mode" in
  all | changed) ;;
  *)
    echo "Usage: $0 [all|changed]" >&2
    exit 64
    ;;
esac

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

files=()
if [[ "$mode" == all ]]; then
  while IFS= read -r -d '' file; do
    files+=("$file")
  done < <(/usr/bin/find Products Sources Support Tests -type f -name '*.swift' -print0)
else
  base_ref="origin/main"
  if [[ -n "${GITHUB_BASE_REF:-}" ]] &&
     git rev-parse --verify --quiet "origin/$GITHUB_BASE_REF" >/dev/null; then
    base_ref="origin/$GITHUB_BASE_REF"
  fi
  if ! git rev-parse --verify --quiet "$base_ref" >/dev/null; then
    base_ref="HEAD^"
  fi
  merge_base="$(git merge-base "$base_ref" HEAD)"
  while IFS= read -r -d '' file; do
    [[ -f "$file" ]] && files+=("$file")
  done < <(git diff --name-only --diff-filter=ACMR -z "$merge_base...HEAD" -- '*.swift')
fi

if [[ ${#files[@]} -eq 0 ]]; then
  echo "PASS: no Swift files require a format check."
  exit 0
fi

temporary_output="$(mktemp /tmp/idlescreen-swift-format.XXXXXX)"
trap '/bin/rm -f "${temporary_output:?}"' EXIT
baseline="$project_root/.swift-format-baseline"

failed=0
for file in "${files[@]}"; do
  xcrun swift-format format "$file" >"$temporary_output"
  if ! /usr/bin/cmp -s "$file" "$temporary_output"; then
    current_sha="$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{ print $1 }')"
    if [[ -f "$baseline" ]] &&
       /usr/bin/grep -Fxq "$current_sha  $file" "$baseline"; then
      echo "BASELINE: $file retains its reviewed pre-adoption formatting."
      continue
    fi
    echo "FAIL: $file is not formatted with Xcode's swift-format." >&2
    /usr/bin/diff -u "$file" "$temporary_output" || true
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi
echo "PASS: ${#files[@]} Swift files match swift-format."
