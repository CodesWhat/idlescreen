#!/bin/bash

# Functions in this deterministic harness are invoked by installer helpers loaded with eval.
# shellcheck disable=SC2030,SC2031,SC2329

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
installer="$project_root/scripts/install-phase1-release.sh"
test_root="$(mktemp -d /tmp/idlescreen-installer-registration-test.XXXXXX)"

cleanup() {
  /bin/rm -rf "$test_root"
}

trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

extract_function() {
  local function_name="$1"
  awk -v signature="$function_name() {" '
    $0 == signature { inside = 1 }
    inside { print }
    inside && $0 == "}" { exit }
  ' "$installer"
}

[[ -f "$installer" ]] || fail "missing installer: $installer"

paths_function="$(extract_function paths_refer_to_same_file)"
registered_wait_function="$(extract_function wait_for_only_registered_path)"
inventory_function="$(extract_function registration_inventory_is_only_path)"
selected_wait_function="$(extract_function wait_for_selected_path)"
settle_function="$(extract_function settle_canonical_registration)"

[[ -n "$paths_function" ]] || fail "installer needs an empty-safe path comparison helper"
[[ -n "$registered_wait_function" ]] || fail "installer needs a registered-inventory convergence helper"
[[ -n "$inventory_function" ]] || fail "installer needs one canonical-path inventory observation"
[[ -n "$selected_wait_function" ]] || fail "installer needs a separate selected-path convergence helper"
[[ -n "$settle_function" ]] || fail "installer needs one ordered canonical-registration convergence helper"

expected_path="$test_root/IdleScreenScreenSaver.appex"
mkdir -p "$expected_path"

(
  eval "$paths_function"
  eval "$inventory_function"
  eval "$registered_wait_function"

  selection_query_marker="$test_root/selection-queried"
  registered_extension_paths() {
    printf '%s\n' "$expected_path"
  }
  selected_extension_path() {
    : >"$selection_query_marker"
  }
  sleep() {
    SECONDS=$((SECONDS + 1))
  }

  wait_for_only_registered_path "$expected_path" ||
    fail "one exact registered path was rejected while selection was still settling"
  [[ ! -e "$selection_query_marker" ]] ||
    fail "registered-inventory convergence incorrectly queried selected state"
)

(
  eval "$paths_function"
  eval "$inventory_function"
  eval "$registered_wait_function"

  registered_extension_paths() {
    printf '%s\n%s\n' "$expected_path" "$expected_path"
  }
  sleep() {
    SECONDS=$((SECONDS + 1))
  }

  wait_for_only_registered_path "$expected_path" ||
    fail "duplicate PlugInKit records for one canonical path were treated as a second app copy"
)

(
  eval "$paths_function"
  eval "$selected_wait_function"

  selection_count_file="$test_root/selection-count"
  printf '0\n' >"$selection_count_file"
  selected_extension_path() {
    local selection_count
    selection_count="$(<"$selection_count_file")"
    selection_count=$((selection_count + 1))
    printf '%s\n' "$selection_count" >"$selection_count_file"
    if ((selection_count >= 2)); then
      printf '%s\n' "$expected_path"
    fi
  }
  sleep() {
    SECONDS=$((SECONDS + 1))
  }

  selected_output="$(wait_for_selected_path "$expected_path" 2>&1)" ||
    fail "selected path did not converge after an initially empty query: $selected_output"
  [[ -z "$selected_output" ]] ||
    fail "empty selected state was passed to realpath: $selected_output"
)

(
  artifact_root="$test_root"
  eval "$settle_function"

  events=""
  wait_for_only_registered_path() {
    [[ "$1" == "$expected_path" ]] || return 1
    events="${events}registered|"
  }
  restart_wallpaper_agent() {
    events="${events}restart|"
  }
  wait_for_selected_path() {
    [[ "$1" == "$expected_path" ]] || return 1
    events="${events}selected|"
  }

  settle_canonical_registration "$expected_path" ||
    fail "ordered canonical registration convergence failed"
  [[ "$events" == "registered|restart|selected|" ]] ||
    fail "canonical registration settled in unsafe order: $events"
)

(
  artifact_root="$test_root"
  eval "$settle_function"

  events=""
  wait_for_only_registered_path() {
    events="${events}registered|"
    return 1
  }
  restart_wallpaper_agent() {
    events="${events}restart|"
  }
  wait_for_selected_path() {
    events="${events}selected|"
  }

  if settle_canonical_registration "$expected_path" >/dev/null 2>&1; then
    fail "canonical registration settlement ignored an inventory failure"
  fi
  [[ "$events" == "registered|" ]] ||
    fail "canonical registration continued after an inventory failure: $events"
)

echo "PASS: canonical registration convergence separates inventory from Tahoe cache selection."
