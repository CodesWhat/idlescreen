#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/installed/idlescreen.app /absolute/gate/IdleScreenSyntheticGate.app /absolute/manifest.txt -- /absolute/gate-runner [args...]" >&2
  exit 64
}

[[ $# -ge 5 ]] || usage
installed_app="$1"
gate_candidate="$2"
manifest="$3"
[[ "$4" == -- ]] || usage
shift 4
runner=("$@")
[[ "$installed_app" = /* && "$gate_candidate" = /* && "$manifest" = /* ]] || usage
[[ "${runner[0]}" = /* && -x "${runner[0]}" ]] || usage

if [[ "$installed_app" != /Applications/idlescreen.app ||
      "${IDLESCREEN_ALLOW_PHYSICAL_TESTS:-}" != YES ||
      "${IDLESCREEN_ALLOW_CAMERA_GATE_A1T:-}" != YES ||
      "${IDLESCREEN_ALLOW_WALLPAPER_AGENT_RESTART:-}" != YES ]]; then
  echo "REFUSED: the synthetic installer requires the canonical /Applications/idlescreen.app plus explicit physical-test, A1T, and exact WallpaperAgent-restart authorization." >&2
  exit 65
fi

if [[ -n "${IDLESCREEN_PROCESS_GUARD_FIXTURE_MODE:-}" ||
      -n "${IDLESCREEN_PROCESS_GUARD_PS:-}" ||
      -n "${IDLESCREEN_PROCESS_GUARD_CODESIGN:-}" ]]; then
  echo "REFUSED: process-guard fixture overrides are forbidden in the physical installer." >&2
  exit 65
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
production_verifier="$project_root/scripts/test-camera-agent-product.sh"
gate_verifier="$project_root/scripts/test-synthetic-gate-product.sh"
transaction_library="$project_root/scripts/lib/synthetic-gate-transaction.sh"
process_guard="$project_root/scripts/camera-gate-owned-process.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x "$production_verifier" && -x "$gate_verifier" && -x "$process_guard" ]] ||
  fail "missing production verifier, synthetic product verifier, or exact process guard"
[[ -f "$transaction_library" ]] || fail "missing synthetic transaction library"

# shellcheck source=scripts/lib/synthetic-gate-transaction.sh
source "$transaction_library"

extension_id=com.idlescreen.app.screensaver
launch_agent_label=group.com.idlescreen.shared.camera-agent
launch_agent_domain="gui/$(/usr/bin/id -u)/$launch_agent_label"
launch_agent_relative="Contents/Library/LaunchAgents/$launch_agent_label.plist"
helper_executable_relative="Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
extension_relative="Contents/PlugIns/IdleScreenScreenSaver.appex"
extension_executable_relative="$extension_relative/Contents/MacOS/IdleScreenScreenSaver"

synthetic_physical_signed_cdhash() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 |
    /usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }'
}

synthetic_physical_text_executable_for_pid() {
  local process_id="$1"
  local lsof_output
  local text_executable
  local text_executable_count
  [[ "$process_id" =~ ^[1-9][0-9]*$ ]] || return 1
  lsof_output="$(/usr/sbin/lsof -a -p "$process_id" -d txt -Fn 2>/dev/null)" || {
    echo "CRITICAL: could not resolve the text executable for candidate PID $process_id; refusing to infer process absence." >&2
    return 1
  }
  text_executable_count="$(/usr/bin/awk \
    'substr($0, 1, 1) == "n" && length($0) > 1 { count += 1 } END { print count + 0 }' \
    <<<"$lsof_output")"
  [[ "$text_executable_count" == 1 ]] || {
    echo "CRITICAL: candidate PID $process_id has $text_executable_count resolvable text executables; refusing ambiguous ownership." >&2
    return 1
  }
  text_executable="$(/usr/bin/awk \
    'substr($0, 1, 1) == "n" && length($0) > 1 { print substr($0, 2); exit }' \
    <<<"$lsof_output")"
  [[ "$text_executable" = /* ]] || return 1
  /bin/realpath "$text_executable" || {
    echo "CRITICAL: candidate PID $process_id text executable is not an intact canonical path: $text_executable" >&2
    return 1
  }
}

synthetic_physical_process_listing() {
  local process_listing
  process_listing="$(/bin/ps -ww -axo pid=,comm= 2>/dev/null)" || {
    echo "CRITICAL: could not enumerate process identities; refusing to infer quiescence or absence." >&2
    return 1
  }
  [[ -n "$process_listing" ]] || {
    echo "CRITICAL: process enumeration returned no records; refusing to infer quiescence or absence." >&2
    return 1
  }
  printf '%s\n' "$process_listing"
}

synthetic_physical_snapshot_value() {
  local snapshot="$1"
  local requested_key="$2"
  /usr/bin/awk -F= -v requested_key="$requested_key" \
    '$1 == requested_key { print substr($0, length($1) + 2); found++ }
     END { exit(found == 1 ? 0 : 1) }' "$snapshot"
}

synthetic_physical_registered_extension_paths() {
  local reported_path
  /usr/bin/pluginkit -m -A -D -v -p com.apple.screensaver |
    /usr/bin/awk -F '\t' -v identity="$extension_id(" '
      index($1, identity) {
        path = $NF
        sub(/^[[:space:]]+/, "", path)
        sub(/[[:space:]]+$/, "", path)
        print path
      }
    ' |
    while IFS= read -r reported_path; do
      [[ -n "$reported_path" ]] || continue
      /bin/realpath "$reported_path" || return 1
    done |
    /usr/bin/sort -u
}

synthetic_physical_selected_extension_path() {
  local reported_path
  reported_path="$(/usr/bin/pluginkit -m -v -p com.apple.screensaver |
    /usr/bin/awk -F '\t' -v identity="$extension_id(" '
      index($1, identity) {
        path = $NF
        sub(/^[[:space:]]+/, "", path)
        sub(/[[:space:]]+$/, "", path)
        print path
        exit
      }
    ')" || return 1
  [[ -n "$reported_path" ]] || return 0
  /bin/realpath "$reported_path"
}

synthetic_physical_wait_for_registration() {
  local expected_path="$1"
  local deadline=$((SECONDS + 15))
  local observed_paths
  while ((SECONDS < deadline)); do
    observed_paths="$(synthetic_physical_registered_extension_paths)" || return 1
    if [[ -z "$expected_path" && -z "$observed_paths" ]]; then
      return 0
    fi
    if [[ -n "$expected_path" && "$observed_paths" == "$expected_path" ]]; then
      return 0
    fi
    /bin/sleep 0.1
  done
  return 1
}

synthetic_physical_wait_for_selection() {
  local expected_path="$1"
  local deadline=$((SECONDS + 15))
  local observed_path
  while ((SECONDS < deadline)); do
    observed_path="$(synthetic_physical_selected_extension_path)" || return 1
    [[ "$observed_path" == "$expected_path" ]] && return 0
    /bin/sleep 0.1
  done
  return 1
}

synthetic_physical_restart_wallpaper_agent() {
  local process_listing
  local process_id process_command process_path process_cdhash process_identity
  local new_pid new_path new_cdhash new_identity
  local old_pid=""
  local old_path=""
  local old_cdhash=""
  local old_identity=""
  local candidate_count=0
  local deadline=$((SECONDS + 15))
  process_listing="$(synthetic_physical_process_listing)" || return 1
  while read -r process_id process_command; do
    [[ "$process_id" =~ ^[1-9][0-9]*$ && -n "$process_command" ]] || continue
    [[ "$(/usr/bin/basename "$process_command")" == WallpaperAgent ]] || continue
    process_path="$(synthetic_physical_text_executable_for_pid "$process_id")" || return 1
    process_cdhash="$(synthetic_physical_signed_cdhash "$process_path")" || return 1
    synthetic_txn_is_cdhash "$process_cdhash" || return 1
    process_identity="$("$process_guard" identity \
      "$process_id" "$process_path" "$process_cdhash")" || return 1
    candidate_count=$((candidate_count + 1))
    old_pid="$process_id"
    old_path="$process_path"
    old_cdhash="$process_cdhash"
    old_identity="$process_identity"
  done <<<"$process_listing"
  if [[ "$candidate_count" != 1 ]]; then
    echo "REFUSED: expected one exact-identity WallpaperAgent restart target, found $candidate_count; the authorization does not permit generic or ambiguous termination." >&2
    return 1
  fi
  "$process_guard" cleanup \
    "$old_pid" "$old_path" "$old_cdhash" "$old_identity" || return 1
  while ((SECONDS < deadline)); do
    process_listing="$(synthetic_physical_process_listing)" || return 1
    candidate_count=0
    process_id=""
    process_path=""
    process_cdhash=""
    while read -r new_pid process_command; do
      [[ "$new_pid" =~ ^[1-9][0-9]*$ && -n "$process_command" ]] || continue
      [[ "$(/usr/bin/basename "$process_command")" == WallpaperAgent ]] || continue
      new_path="$(synthetic_physical_text_executable_for_pid "$new_pid")" || return 1
      new_cdhash="$(synthetic_physical_signed_cdhash "$new_path")" || return 1
      synthetic_txn_is_cdhash "$new_cdhash" || return 1
      new_identity="$("$process_guard" identity \
        "$new_pid" "$new_path" "$new_cdhash")" || return 1
      candidate_count=$((candidate_count + 1))
      process_id="$new_pid"
      process_path="$new_path"
      process_cdhash="$new_cdhash"
      process_identity="$new_identity"
    done <<<"$process_listing"
    if [[ "$candidate_count" == 1 && "$process_id" != "$old_pid" &&
          "$process_path" == "$old_path" && "$process_cdhash" == "$old_cdhash" &&
          -n "$process_identity" ]]; then
      return 0
    fi
    ((candidate_count <= 1)) || {
      echo "CRITICAL: WallpaperAgent restart produced multiple exact-name targets; refusing ambiguous ownership." >&2
      return 1
    }
    /bin/sleep 0.1
  done
  echo "FAIL: the exact guarded WallpaperAgent target did not relaunch with the same path and CDHash within 15 seconds." >&2
  return 1
}

synthetic_physical_exact_executable_pids() {
  local expected_executable="$1"
  local expected_realpath
  local process_listing
  local process_id
  local process_command
  local text_executable
  expected_realpath="$(/bin/realpath "$expected_executable")" || return 1
  process_listing="$(synthetic_physical_process_listing)" || return 1
  while read -r process_id process_command; do
    [[ "$process_id" =~ ^[1-9][0-9]*$ && -n "$process_command" ]] || continue
    [[ "$(/usr/bin/basename "$process_command")" == \
       "$(/usr/bin/basename "$expected_realpath")" ]] || continue
    text_executable="$(synthetic_physical_text_executable_for_pid "$process_id")" || return 1
    [[ "$text_executable" == "$expected_realpath" ]] && printf '%s\n' "$process_id"
  done <<<"$process_listing"
}

synthetic_physical_launchd_registration() {
  local app_path="$1"
  local output
  if ! output="$(/bin/launchctl print "$launch_agent_domain" 2>/dev/null)"; then
    printf 'unbound\n'
    return 0
  fi
  local expected_helper="$app_path/$helper_executable_relative"
  if ! /usr/bin/grep -Eq \
    "^[[:space:]]*(program = $expected_helper|bundle program = $helper_executable_relative)$" \
    <<<"$output"; then
    return 1
  fi
  printf 'loaded\n'
}

synthetic_physical_service_status() {
  local btm_dump
  btm_dump="$(/usr/bin/sfltool dumpbtm 2>/dev/null)" || return 1
  if /usr/bin/grep -Fq "$launch_agent_label" <<<"$btm_dump" &&
     /usr/bin/grep -Fq 'com.idlescreen.app' <<<"$btm_dump"; then
    printf 'enabled\n'
  else
    printf 'notRegistered\n'
  fi
}

synthetic_physical_write_state() {
  local app_path
  app_path="$(/bin/realpath "$1")" || return 1
  local helper_path="$app_path/$helper_executable_relative"
  local extension_path="$app_path/$extension_relative"
  local service_status
  local launchd_registration
  local helper_runtime=absent
  local helper_cdhash
  local extension_cdhash
  local registered_paths
  local selected_path
  local helper_pids
  service_status="$(synthetic_physical_service_status)" || return 1
  launchd_registration="$(synthetic_physical_launchd_registration "$app_path")" || return 1
  helper_pids="$(synthetic_physical_exact_executable_pids "$helper_path")" || return 1
  [[ -z "$helper_pids" ]] || helper_runtime=warm
  helper_cdhash="$(synthetic_physical_signed_cdhash "$app_path/Contents/Helpers/IdleScreenCameraAgent.app")" || return 1
  extension_cdhash="$(synthetic_physical_signed_cdhash "$extension_path")" || return 1
  registered_paths="$(synthetic_physical_registered_extension_paths)" || return 1
  [[ "$registered_paths" != *$'\n'* ]] || return 1
  selected_path="$(synthetic_physical_selected_extension_path)" || return 1
  {
    printf 'format=1\n'
    printf 'service_status=%s\n' "$service_status"
    printf 'launchd_registration=%s\n' "$launchd_registration"
    printf 'helper_runtime=%s\n' "$helper_runtime"
    printf 'helper_path=%s\n' "$helper_path"
    printf 'helper_cdhash=%s\n' "$helper_cdhash"
    printf 'pluginkit_paths=%s\n' "$registered_paths"
    printf 'selected_path=%s\n' "$selected_path"
    printf 'extension_cdhash=%s\n' "$extension_cdhash"
  }
}

synthetic_physical_validate_state() {
  local snapshot="$1"
  [[ -f "$snapshot" && ! -L "$snapshot" &&
     "$(/usr/bin/wc -l <"$snapshot" | /usr/bin/xargs)" == 9 ]] || return 1
  local format service_status launchd_registration helper_runtime helper_path
  local helper_cdhash pluginkit_paths selected_path extension_cdhash
  format="$(synthetic_physical_snapshot_value "$snapshot" format)" || return 1
  service_status="$(synthetic_physical_snapshot_value "$snapshot" service_status)" || return 1
  launchd_registration="$(synthetic_physical_snapshot_value "$snapshot" launchd_registration)" || return 1
  helper_runtime="$(synthetic_physical_snapshot_value "$snapshot" helper_runtime)" || return 1
  helper_path="$(synthetic_physical_snapshot_value "$snapshot" helper_path)" || return 1
  helper_cdhash="$(synthetic_physical_snapshot_value "$snapshot" helper_cdhash)" || return 1
  pluginkit_paths="$(synthetic_physical_snapshot_value "$snapshot" pluginkit_paths)" || return 1
  selected_path="$(synthetic_physical_snapshot_value "$snapshot" selected_path)" || return 1
  extension_cdhash="$(synthetic_physical_snapshot_value "$snapshot" extension_cdhash)" || return 1
  [[ "$format" == 1 ]] || return 1
  [[ "$service_status" == enabled || "$service_status" == notRegistered ]] || return 1
  [[ "$launchd_registration" == loaded || "$launchd_registration" == unbound ]] || return 1
  [[ "$helper_runtime" == absent || "$helper_runtime" == warm ]] || return 1
  synthetic_txn_is_safe_absolute_path "$helper_path" || return 1
  synthetic_txn_is_cdhash "$helper_cdhash" || return 1
  synthetic_txn_is_cdhash "$extension_cdhash" || return 1
  if [[ -n "$pluginkit_paths" ]]; then
    synthetic_txn_is_safe_absolute_path "$pluginkit_paths" || return 1
  fi
  if [[ -n "$selected_path" ]]; then
    synthetic_txn_is_safe_absolute_path "$selected_path" || return 1
  fi
  [[ "$selected_path" == "$pluginkit_paths" ]] || return 1
  [[ "$launchd_registration" == loaded || "$helper_runtime" == absent ]] || return 1
}

synthetic_physical_unregister_extension() {
  local registered_path
  while IFS= read -r registered_path; do
    [[ -n "$registered_path" ]] || continue
    /usr/bin/pluginkit -r "$registered_path" >/dev/null || return 1
  done < <(synthetic_physical_registered_extension_paths)
  synthetic_physical_wait_for_registration ""
}

synthetic_physical_bootout_helper() {
  /bin/launchctl bootout "$launch_agent_domain" >/dev/null 2>&1 || true
  local deadline=$((SECONDS + 15))
  while ((SECONDS < deadline)); do
    if ! /bin/launchctl print "$launch_agent_domain" >/dev/null 2>&1; then
      return 0
    fi
    /bin/sleep 0.1
  done
  return 1
}

synthetic_physical_bootstrap_helper() {
  local app_path="$1"
  local current_registration
  current_registration="$(synthetic_physical_launchd_registration "$app_path")" || return 1
  [[ "$current_registration" == loaded ]] && return 0
  /bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" \
    "$app_path/$launch_agent_relative" >/dev/null || return 1
  local deadline=$((SECONDS + 15))
  while ((SECONDS < deadline)); do
    [[ "$(synthetic_physical_launchd_registration "$app_path")" == loaded ]] && return 0
    /bin/sleep 0.1
  done
  return 1
}

synthetic_physical_rebind_extension() {
  local expected_extension="$1"
  synthetic_physical_unregister_extension || return 1
  /usr/bin/pluginkit -a "$expected_extension" >/dev/null || return 1
  synthetic_physical_wait_for_registration "$expected_extension" || return 1
  synthetic_physical_restart_wallpaper_agent || return 1
  synthetic_physical_wait_for_selection "$expected_extension"
}

synthetic_txn_capture_external_state() {
  synthetic_physical_write_state "$installed_app" >"$1"
}

synthetic_txn_validate_external_state_snapshot() {
  synthetic_physical_validate_state "$1"
}

synthetic_txn_retire_production_registration() {
  [[ "$1" == /Applications/idlescreen.app ]] || return 1
  synthetic_physical_unregister_extension || return 1
  synthetic_physical_bootout_helper || return 1
  synthetic_physical_restart_wallpaper_agent || return 1
  synthetic_physical_wait_for_selection ""
}

synthetic_txn_verify_production_registration_retired() {
  local state
  state="$(synthetic_physical_write_state "$1")" || return 1
  /usr/bin/grep -Fxq 'launchd_registration=unbound' <<<"$state" &&
    /usr/bin/grep -Fxq 'helper_runtime=absent' <<<"$state" &&
    /usr/bin/grep -Fxq 'pluginkit_paths=' <<<"$state" &&
    /usr/bin/grep -Fxq 'selected_path=' <<<"$state"
}

synthetic_physical_relevant_pid_paths() {
  local production_path="$1"
  local gate_path="$2"
  local process_listing
  local process_id process_command text_executable base_name
  local relevant_records=""
  process_listing="$(synthetic_physical_process_listing)" || return 1
  while read -r process_id process_command; do
    [[ "$process_id" =~ ^[1-9][0-9]*$ && -n "$process_command" ]] || continue
    case "$process_command" in
      *IdleScreen*|*ScreenSaverEngine*|*legacyScreenSaver*|*IdlescreenHelper*|*'System Settings'*) ;;
      *) continue ;;
    esac
    text_executable="$(synthetic_physical_text_executable_for_pid "$process_id")" || return 1
    base_name="$(/usr/bin/basename "$text_executable")"
    case "$text_executable" in
      "$production_path/Contents/MacOS/IdleScreen"|\
      "$production_path/$helper_executable_relative"|\
      "$production_path/$extension_executable_relative"|\
      "$gate_path/Contents/MacOS/IdleScreen"|\
      "$gate_path/$helper_executable_relative"|\
      "$gate_path/$extension_executable_relative")
        relevant_records+="$process_id:$text_executable"$'\n'
        ;;
      *)
        case "$base_name" in
          ScreenSaverEngine|legacyScreenSaver|IdlescreenHelper|'System Settings')
            relevant_records+="$process_id:$text_executable"$'\n'
            ;;
        esac
        ;;
    esac
  done <<<"$process_listing"
  [[ -z "$relevant_records" ]] || printf '%s' "$relevant_records" | /usr/bin/sort -n
}

synthetic_txn_assert_stable_quiescence() {
  local destination="$1"
  local production_path="$2"
  local gate_path="$3"
  local sample_1 sample_2 sample_3
  sample_1="$(synthetic_physical_relevant_pid_paths "$production_path" "$gate_path" |
    /usr/bin/paste -sd '|' -)" || return 1
  /bin/sleep 0.1
  sample_2="$(synthetic_physical_relevant_pid_paths "$production_path" "$gate_path" |
    /usr/bin/paste -sd '|' -)" || return 1
  /bin/sleep 0.1
  sample_3="$(synthetic_physical_relevant_pid_paths "$production_path" "$gate_path" |
    /usr/bin/paste -sd '|' -)" || return 1
  {
    printf 'format=1\n'
    printf 'sample_count=3\n'
    printf 'sample_1_pid_paths=%s\n' "$sample_1"
    printf 'sample_2_pid_paths=%s\n' "$sample_2"
    printf 'sample_3_pid_paths=%s\n' "$sample_3"
  } >"$destination"
  [[ -z "$sample_1" && "$sample_1" == "$sample_2" && "$sample_2" == "$sample_3" ]]
}

synthetic_txn_validate_quiescence_inventory() {
  local snapshot="$1"
  [[ -f "$snapshot" && ! -L "$snapshot" &&
     "$(/usr/bin/wc -l <"$snapshot" | /usr/bin/xargs)" == 5 ]] || return 1
  /usr/bin/grep -Fxq 'format=1' "$snapshot" || return 1
  /usr/bin/grep -Fxq 'sample_count=3' "$snapshot" || return 1
  local sample
  for sample in 1 2 3; do
    /usr/bin/grep -Eq \
      "^sample_${sample}_pid_paths=([1-9][0-9]*:[^|[:cntrl:]]+([|][1-9][0-9]*:[^|[:cntrl:]]+)*)?$" \
      "$snapshot" || return 1
  done
}

synthetic_txn_rebind_gate_registration() {
  local app_path="$1"
  [[ "$app_path" == /Applications/idlescreen.app ]] || return 1
  synthetic_physical_bootstrap_helper "$app_path" || return 1
  synthetic_physical_rebind_extension "$app_path/$extension_relative"
}

synthetic_txn_verify_gate_registration() {
  local app_path="$1"
  local state
  state="$(synthetic_physical_write_state "$app_path")" || return 1
  /usr/bin/grep -Fxq 'launchd_registration=loaded' <<<"$state" &&
    /usr/bin/grep -Fxq 'helper_runtime=absent' <<<"$state" &&
    /usr/bin/grep -Fxq "pluginkit_paths=$app_path/$extension_relative" <<<"$state" &&
    /usr/bin/grep -Fxq "selected_path=$app_path/$extension_relative" <<<"$state"
}

synthetic_txn_capture_gate_bound_state() {
  synthetic_physical_write_state "$2" >"$1"
}

synthetic_txn_validate_gate_bound_state() {
  synthetic_physical_validate_state "$1" || return 1
  local expected_extension="/Applications/idlescreen.app/$extension_relative"
  [[ "$(synthetic_physical_snapshot_value "$1" launchd_registration)" == loaded &&
     "$(synthetic_physical_snapshot_value "$1" pluginkit_paths)" == "$expected_extension" &&
     "$(synthetic_physical_snapshot_value "$1" selected_path)" == "$expected_extension" ]]
}

synthetic_txn_retire_gate_registration() {
  [[ "$1" == /Applications/idlescreen.app ]] || return 1
  synthetic_physical_unregister_extension || return 1
  synthetic_physical_bootout_helper || return 1
  synthetic_physical_restart_wallpaper_agent || return 1
  synthetic_physical_wait_for_selection ""
}

synthetic_txn_verify_gate_registration_retired() {
  local state
  state="$(synthetic_physical_write_state "$1")" || return 1
  /usr/bin/grep -Fxq 'launchd_registration=unbound' <<<"$state" &&
    /usr/bin/grep -Fxq 'pluginkit_paths=' <<<"$state" &&
    /usr/bin/grep -Fxq 'selected_path=' <<<"$state"
}

synthetic_txn_restore_production_registration() {
  local snapshot="$1"
  local app_path=/Applications/idlescreen.app
  local extension_path="$app_path/$extension_relative"
  local expected_launchd expected_runtime expected_plugin expected_selection
  local expected_service current_service
  expected_launchd="$(synthetic_physical_snapshot_value "$snapshot" launchd_registration)" || return 1
  expected_runtime="$(synthetic_physical_snapshot_value "$snapshot" helper_runtime)" || return 1
  expected_plugin="$(synthetic_physical_snapshot_value "$snapshot" pluginkit_paths)" || return 1
  expected_selection="$(synthetic_physical_snapshot_value "$snapshot" selected_path)" || return 1
  expected_service="$(synthetic_physical_snapshot_value "$snapshot" service_status)" || return 1
  current_service="$(synthetic_physical_service_status)" || return 1
  [[ "$current_service" == "$expected_service" ]] || return 1
  [[ -z "$expected_plugin" || "$expected_plugin" == "$extension_path" ]] || return 1
  [[ "$expected_selection" == "$expected_plugin" ]] || return 1
  synthetic_physical_unregister_extension || return 1
  synthetic_physical_bootout_helper || return 1
  if [[ "$expected_launchd" == loaded ]]; then
    synthetic_physical_bootstrap_helper "$app_path" || return 1
  fi
  if [[ -n "$expected_plugin" ]]; then
    synthetic_physical_rebind_extension "$extension_path" || return 1
  else
    synthetic_physical_restart_wallpaper_agent || return 1
    synthetic_physical_wait_for_selection "" || return 1
  fi
  if [[ "$expected_runtime" == warm ]]; then
    /bin/launchctl kickstart "$launch_agent_domain" >/dev/null || return 1
    local deadline=$((SECONDS + 15))
    local helper_pids
    while ((SECONDS < deadline)); do
      helper_pids="$(synthetic_physical_exact_executable_pids \
        "$app_path/$helper_executable_relative")" || return 1
      [[ -n "$helper_pids" ]] && return 0
      /bin/sleep 0.1
    done
    return 1
  fi
}

synthetic_txn_verify_production_registration() {
  local observed
  observed="$(synthetic_physical_write_state /Applications/idlescreen.app)" || return 1
  /usr/bin/cmp -s "$1" <(printf '%s\n' "$observed")
}

synthetic_txn_capture_post_restore_state() {
  synthetic_physical_write_state "$2" >"$1"
}

synthetic_txn_validate_post_restore_state() {
  synthetic_physical_validate_state "$1"
}

synthetic_txn_verify_production() {
  "$production_verifier" "$1" "$2"
}

synthetic_txn_verify_gate() {
  "$gate_verifier" "$1" "$2" "$3" "$4"
}

synthetic_gate_transaction_run \
  "$installed_app" "$gate_candidate" "$manifest" -- "${runner[@]}"
