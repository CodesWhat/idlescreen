#!/bin/bash
# Lint for the companion app's SwiftUI controls. Fails on a control with an empty title, and on
# `.labelsHidden()` with no explicit `.accessibilityLabel(` within six lines either side, because
# hiding the visible label leaves VoiceOver with nothing to read.

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="${1:-$project_root/Products/IdleScreenApp}"
# Without an argument, lint the Design components and the settings pages. Studio has its own pass.
default_scope=1
[[ $# -gt 0 ]] && default_scope=0

filter() {
  if [[ "$default_scope" == 1 && "$dir_is_app" == 1 ]]; then
    /usr/bin/grep -E '/(Design/|DisplaysView|IntegrationsView|SystemViews)'
  else
    /bin/cat
  fi
}

scan() {
  local dir="$1" status=0 file
  while IFS= read -r file; do
    if /usr/bin/grep -nE '\b(Toggle|Picker|Slider|DatePicker|Stepper|TextField|SecureField|Button|Menu|Label)\(\s*""' "$file"; then
      echo "FAIL: $file has a control with an empty title." >&2
      status=1
    fi
    /usr/bin/awk -v file="$file" '
      { lines[NR] = $0 }
      END {
        bad = 0
        for (i = 1; i <= NR; i++) {
          if (lines[i] !~ /\.labelsHidden\(\)/) continue
          found = 0
          for (j = i - 6; j <= i + 6; j++) {
            if (j >= 1 && j <= NR && lines[j] ~ /\.accessibilityLabel\(/) found = 1
          }
          if (!found) {
            printf "FAIL: %s:%d .labelsHidden() without .accessibilityLabel nearby\n", file, i > "/dev/stderr"
            bad = 1
          }
        }
        exit bad
      }' "$file" || status=1
  done < <(/usr/bin/find "$dir" -type f -name '*.swift' | /usr/bin/sort | filter)
  return "$status"
}

dir_is_app=0
# Self-test: the lint must reject known-bad input and accept known-good input.
fixture="$(mktemp -d /tmp/idlescreen-a11y-lint.XXXXXX)"
trap '/bin/rm -rf "${fixture:?}"' EXIT
printf 'Toggle("", isOn: $x)\n' >"$fixture/EmptyTitle.swift"
printf 'Toggle("On", isOn: $x)\n  .labelsHidden()\n' >"$fixture/Hidden.swift"
if scan "$fixture" >/dev/null 2>&1; then
  echo "FAIL: accessibility lint accepted known-bad fixtures." >&2
  exit 1
fi
/bin/rm -f "$fixture"/*.swift
printf 'Toggle("On", isOn: $x)\n  .labelsHidden()\n  .accessibilityLabel("On")\n' >"$fixture/Good.swift"
scan "$fixture" >/dev/null 2>&1 || {
  echo "FAIL: accessibility lint rejected a known-good fixture." >&2
  exit 1
}

dir_is_app=1
scan "$app_dir"
echo "PASS: no unlabeled controls in $(basename "$app_dir")."
