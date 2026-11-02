#!/bin/bash
# Lint for the companion app's SwiftUI controls. Fails on a control with an empty title, and on `.labelsHidden()` with no
# explicit `.accessibilityLabel(` in the same control: the label must sit between this control's initializer and the next
# control's initializer, so a neighbouring control's label cannot satisfy it. Hiding the visible label leaves VoiceOver with
# nothing to read. A scope that matches no Swift files fails instead of passing vacuously.

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="${1:-$project_root/Products/IdleScreenApp}"
# Without an argument, lint the Design components, the setup flow and the settings pages. Studio has its own pass.
default_scope=1
[[ $# -gt 0 ]] && default_scope=0
dir_is_app=0

filter() {
  if [[ "$default_scope" == 1 && "$dir_is_app" == 1 ]]; then
    /usr/bin/grep -E '/(Design/|Setup/|Status/|DisplaysView|IntegrationsView|SystemViews)' || true
  else
    /bin/cat
  fi
}

scan() {
  local dir="$1" status=0 file count=0
  while IFS= read -r file; do
    count=$((count + 1))
    if /usr/bin/grep -nE '\b(Toggle|Picker|Slider|DatePicker|Stepper|TextField|SecureField|Button|Menu|Label)\(\s*""' "$file"; then
      echo "FAIL: $file has a control with an empty title." >&2
      status=1
    fi
    /usr/bin/awk -v file="$file" '
      function is_control(line) {
        return line ~ /(^|[^A-Za-z.])(Toggle|Picker|Slider|DatePicker|Stepper|TextField|SecureField|Button|Menu|Label|DesignPopup|DesignSegmented)[(]/ \
          || line ~ /(^|[^A-Za-z.])(Toggle|Picker|Slider|DatePicker|Stepper|TextField|SecureField|Button|Menu)[ ]*[{]/
      }
      { lines[NR] = $0 }
      END {
        bad = 0
        for (i = 1; i <= NR; i++) {
          if (lines[i] !~ /\.labelsHidden\(\)/) continue
          # Back to this control initializer, forward to the next one.
          start = i
          while (start > 1 && !is_control(lines[start])) start--
          stop = NR
          for (k = i + 1; k <= NR; k++) if (is_control(lines[k])) { stop = k - 1; break }
          found = 0
          for (j = start; j <= stop; j++) if (lines[j] ~ /\.accessibilityLabel\(/) found = 1
          if (!found) {
            printf "FAIL: %s:%d .labelsHidden() without .accessibilityLabel in the same control\n", file, i > "/dev/stderr"
            bad = 1
          }
        }
        exit bad
      }' "$file" || status=1
  done < <(/usr/bin/find "$dir" -type f -name '*.swift' | /usr/bin/sort | filter)
  if [[ "$count" -eq 0 ]]; then
    echo "FAIL: no Swift files matched in $dir." >&2
    status=1
  fi
  return "$status"
}

# Self-test: each rule must fire on its own bad fixture, with the message for that rule, and stay quiet on a good one.
fixture="$(mktemp -d /tmp/idlescreen-a11y-lint.XXXXXX)"
trap '/bin/rm -rf "${fixture:?}"' EXIT

expect_fail() {
  local name="$1" content="$2" message="$3" output
  /bin/rm -f "$fixture"/*.swift
  printf '%b' "$content" >"$fixture/$name.swift"
  if output="$(scan "$fixture" 2>&1)"; then
    echo "FAIL: accessibility lint accepted the $name fixture." >&2
    exit 1
  fi
  if ! grep -Fq "$message" <<<"$output"; then
    echo "FAIL: the $name fixture failed for the wrong reason: $output" >&2
    exit 1
  fi
}

expect_fail EmptyTitle 'Toggle("", isOn: $x)\n' 'empty title'
expect_fail Hidden 'Toggle("On", isOn: $x)\n  .labelsHidden()\n' 'without .accessibilityLabel'
# A neighbouring control's label, before or after, must not satisfy this control.
expect_fail LabelAfter 'Toggle("On", isOn: $x)\n  .labelsHidden()\nToggle("Off", isOn: $y)\n  .labelsHidden()\n  .accessibilityLabel("Off")\n' 'without .accessibilityLabel'
expect_fail LabelBefore 'Button("B") {}\n  .accessibilityLabel("B")\nToggle("A", isOn: $x)\n  .labelsHidden()\n' 'without .accessibilityLabel'

/bin/rm -f "$fixture"/*.swift
printf 'Toggle("On", isOn: $x)\n  .labelsHidden()\n  .accessibilityLabel("On")\nToggle("Off", isOn: $y)\n  .labelsHidden()\n  .accessibilityLabel("Off")\n' >"$fixture/Good.swift"
scan "$fixture" >/dev/null 2>&1 || {
  echo "FAIL: accessibility lint rejected a known-good fixture." >&2
  exit 1
}

# An empty scope must fail rather than pass vacuously.
empty="$(mktemp -d /tmp/idlescreen-a11y-empty.XXXXXX)"
if empty_output="$(scan "$empty" 2>&1)"; then
  /bin/rm -rf "${empty:?}"
  echo "FAIL: accessibility lint passed on an empty scope." >&2
  exit 1
fi
/bin/rm -rf "${empty:?}"
grep -Fq 'no Swift files matched' <<<"$empty_output" || {
  echo "FAIL: the empty scope failed for the wrong reason." >&2
  exit 1
}

dir_is_app=1
scan "$app_dir"
echo "PASS: no unlabeled controls in $(basename "$app_dir")."
