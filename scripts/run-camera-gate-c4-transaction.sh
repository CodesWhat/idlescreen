#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /Applications/idlescreen.app /absolute/C4-gate.app /absolute/gate-manifest.txt /absolute/C3-provenance.txt /absolute/gate-binding.txt MODE /absolute/new-transaction-evidence -- /absolute/C4-row-runner [args...]" >&2
  exit 64
}

[[ $# -ge 10 ]] || usage
installed_app="$1"
gate_candidate="$2"
manifest="$3"
c3_manifest="$4"
binding_manifest="$5"
mode="$6"
durable_evidence="$7"
[[ "$8" == -- ]] || usage
shift 8
runner=("$@")
[[ "$installed_app" = /* && "$gate_candidate" = /* && "$manifest" = /* &&
   "$c3_manifest" = /* && "$binding_manifest" = /* &&
   "$durable_evidence" = /* && "$durable_evidence" != / ]] || usage
[[ "$mode" == a1t || "$mode" == a1tr ]] || usage
[[ "${runner[0]}" = /* && -x "${runner[0]}" ]] || usage

if [[ "$installed_app" != /Applications/idlescreen.app ||
      "${IDLESCREEN_C4_AUTHORIZE_INSTALL_REBIND:-}" != YES ]]; then
  echo "REFUSED: the C4 transaction requires the canonical app and IDLESCREEN_C4_AUTHORIZE_INSTALL_REBIND=YES." >&2
  exit 65
fi

durable_parent="$(/usr/bin/dirname "$durable_evidence")"
[[ -d "$durable_parent" && ! -L "$durable_parent" ]] || usage
durable_parent="$(/bin/realpath "$durable_parent")"
durable_evidence="$durable_parent/$(/usr/bin/basename "$durable_evidence")"
[[ ! -e "$durable_evidence" && ! -L "$durable_evidence" ]] || {
  echo "FAIL: refusing to replace C4 transaction evidence: $durable_evidence" >&2
  exit 73
}
/bin/mkdir -m 700 "$durable_evidence"

project_root="$(cd "$(dirname "$0")/.." && pwd)"
production_verifier="$project_root/scripts/test-camera-agent-product.sh"
gate_verifier="$project_root/scripts/test-synthetic-gate-product.sh"
transaction_library="$project_root/scripts/lib/synthetic-gate-transaction.sh"
row_runner="$project_root/scripts/run-camera-gate-c4-row.sh"
transition_events="$durable_evidence/transition-events.raw"

fail() {
  echo "FAIL: $*" >&2
  echo "Evidence: $durable_evidence" >&2
  exit 1
}

synthetic_c4_sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print tolower($1) }'
}

synthetic_c4_copy_once() {
  local source="$1"
  local leaf="$2"
  [[ -f "$source" && ! -L "$source" && ! -e "$durable_evidence/$leaf" ]] || return 1
  /usr/bin/ditto "$source" "$durable_evidence/$leaf" || return 1
  synthetic_c4_sha256_file "$durable_evidence/$leaf" >"$durable_evidence/$leaf.sha256"
}

synthetic_c4_timestamp() {
  /bin/date -u '+%Y-%m-%dT%H:%M:%S.000000Z'
}

synthetic_c4_record_transition() {
  printf '%s@%s\n' "$1" "$(synthetic_c4_timestamp)" >>"$transition_events"
}

synthetic_c4_manifest_value() {
  local source="$1"
  local key="$2"
  /usr/bin/awk -F= -v key="$key" \
    '$1 == key { print substr($0, length($1) + 2); count++ } END { exit(count == 1 ? 0 : 1) }' \
    "$source"
}

synthetic_c4_write_tree_inventory() {
  local root="$1" output="$2" listing="$durable_evidence/.tree-list-$$"
  local entry relative mode size digest target attributes attribute value
  [[ ! -e "$listing" ]] || return 1
  /usr/bin/find -s "$root" -print0 >"$listing" || return 1
  : >"$output"
  while IFS= read -r -d '' entry; do
    relative="${entry#"$root"}"; relative="${relative#/}"; [[ -n "$relative" ]] || relative=.
    [[ "$relative" != *$'\n'* && "$relative" != *$'\t'* ]] || return 1
    mode="$(/usr/bin/stat -f '%Lp' "$entry")" || return 1
    if [[ -L "$entry" ]]; then
      target="$(/usr/bin/readlink "$entry")" || return 1
      printf 'link\t%s\t%s\t%s\n' "$mode" "$relative" "$target" >>"$output"
    elif [[ -f "$entry" ]]; then
      size="$(/usr/bin/stat -f '%z' "$entry")" || return 1
      digest="$(synthetic_c4_sha256_file "$entry")" || return 1
      printf 'file\t%s\t%s\t%s\t%s\n' "$mode" "$size" "$digest" "$relative" >>"$output"
    elif [[ -d "$entry" ]]; then
      printf 'directory\t%s\t%s\n' "$mode" "$relative" >>"$output"
    else
      return 1
    fi
    attributes="$durable_evidence/.xattrs-$$"
    /usr/bin/xattr "$entry" >"$attributes" 2>/dev/null || return 1
    LC_ALL=C /usr/bin/sort -o "$attributes" "$attributes" || return 1
    while IFS= read -r attribute; do
      [[ -n "$attribute" ]] || continue
      [[ "$attribute" != *$'\n'* && "$attribute" != *$'\t'* ]] || return 1
      value="$(/usr/bin/xattr -px "$attribute" "$entry" 2>/dev/null)" || return 1
      value="${value//[[:space:]]/}"
      printf 'xattr\t%s\t%s\t%s\n' "$relative" "$attribute" "$value" >>"$output"
    done <"$attributes"
    /bin/rm "$attributes" || return 1
  done <"$listing"
  /bin/rm "$listing" || return 1
}

[[ -x "$production_verifier" && -x "$gate_verifier" ]] ||
  fail "missing production or synthetic product verifier"
[[ -f "$transaction_library" ]] || fail "missing synthetic transaction library"
[[ -f "$c3_manifest" && ! -L "$c3_manifest" &&
   -f "$binding_manifest" && ! -L "$binding_manifest" ]] ||
  fail "missing C3 provenance or gate binding manifest"
[[ "${runner[0]}" == "$row_runner" && "${runner[1]:-}" == "$installed_app" &&
   "${runner[2]:-}" == "$durable_evidence" &&
   "${runner[3]:-}" == "$durable_evidence/a1" && "${runner[4]:-}" == "$mode" &&
   "${#runner[@]}" == 5 ]] || fail "C4 transaction requires the exact C4 row wrapper"
: >"$transition_events"

# shellcheck source=scripts/lib/synthetic-gate-transaction.sh
source "$transaction_library"

extension_id=com.idlescreen.app.screensaver
launch_agent_label=group.com.idlescreen.shared.camera-agent
launch_agent_domain="gui/$(/usr/bin/id -u)/$launch_agent_label"
launch_agent_relative="Contents/Library/LaunchAgents/$launch_agent_label.plist"
helper_executable_relative="Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
extension_relative="Contents/PlugIns/IdleScreenScreenSaver.appex"
extension_executable_relative="$extension_relative/Contents/MacOS/IdleScreenScreenSaver"
selection_probe="$durable_evidence/ScreenSaverSelectionProbe"
xcrun swiftc \
  "$project_root/Sources/IdleScreenSystem/ScreenSaverSelection.swift" \
  "$project_root/scripts/ScreenSaverSelectionProbe.swift" \
  -o "$selection_probe" >"$durable_evidence/selection-probe-build.log" 2>&1 ||
  fail "could not compile the real ScreenSaver selection probe"

synthetic_physical_signed_cdhash() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 |
    /usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }'
}

synthetic_physical_snapshot_value() {
  local snapshot="$1"
  local requested_key="$2"
  /usr/bin/awk -F= -v requested_key="$requested_key" \
    '$1 == requested_key { print substr($0, length($1) + 2); found++ }
     END { exit(found == 1 ? 0 : 1) }' "$snapshot"
}

synthetic_physical_registered_extension_paths() {
  local output parsed reported_path resolved_path paths=""
  output="$(/usr/bin/pluginkit -m -A -D -v -p com.apple.screensaver)" || return 1
  parsed="$(/usr/bin/awk -F '\t' -v identity="$extension_id(" '
      index($1, identity) {
        path = $NF
        sub(/^[[:space:]]+/, "", path)
        sub(/[[:space:]]+$/, "", path)
        print path
      }
    ' <<<"$output")" || return 1
  while IFS= read -r reported_path; do
    [[ -n "$reported_path" ]] || continue
    resolved_path="$(/bin/realpath "$reported_path")" || return 1
    paths="${paths}${paths:+$'\n'}$resolved_path"
  done <<<"$parsed"
  [[ -z "$paths" ]] || LC_ALL=C /usr/bin/sort -u <<<"$paths"
}

synthetic_physical_selected_extension_path() {
  local report status paths
  set +e
  report="$("$selection_probe" "$extension_id" 2>&1)"
  status=$?
  set -e
  [[ "$status" == 0 || "$status" == 1 ]] || return 1
  [[ "$(printf '%s\n' "$report" | /usr/bin/wc -l | /usr/bin/xargs)" == 2 ]] || return 1
  /usr/bin/grep -Fxq "providers=$extension_id" <<<"$report" || return 1
  /usr/bin/grep -Fxq 'selectedEverywhere=true' <<<"$report" || return 1
  paths="$(synthetic_physical_registered_extension_paths)" || return 1
  [[ "$paths" != *$'\n'* ]] || return 1
  [[ -z "$paths" ]] || printf '%s\n' "$paths"
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

synthetic_physical_exact_executable_pids() {
  local expected_executable="$1"
  local process_id process_command text_executable process_table lsof_output count
  process_table="$(/bin/ps -ww -axo pid=,command=)" || return 1
  while read -r process_id process_command; do
    [[ "$process_command" == *"$(/usr/bin/basename "$expected_executable")"* ]] || continue
    [[ "$process_id" =~ ^[1-9][0-9]*$ ]] || return 1
    lsof_output="$(/usr/sbin/lsof -a -p "$process_id" -d txt -Fn 2>/dev/null)" || return 1
    count="$(/usr/bin/awk 'substr($0,1,1)=="n" && length($0)>1 { count++ } END { print count+0 }' <<<"$lsof_output")" || return 1
    [[ "$count" == 1 ]] || return 1
    text_executable="$(/usr/bin/awk 'substr($0,1,1)=="n" && length($0)>1 { print substr($0,2) }' <<<"$lsof_output")" || return 1
    [[ "$text_executable" == "$expected_executable" ]] && printf '%s\n' "$process_id"
  done <<<"$process_table"
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
  local registration
  registration="$(synthetic_physical_launchd_registration "$1")" || return 1
  [[ "$registration" == loaded ]] && printf 'enabled\n' || printf 'notRegistered\n'
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
  service_status="$(synthetic_physical_service_status "$app_path")" || return 1
  launchd_registration="$(synthetic_physical_launchd_registration "$app_path")" || return 1
  local helper_pids
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
  local registered_path registered_paths
  registered_paths="$(synthetic_physical_registered_extension_paths)" || return 1
  while IFS= read -r registered_path; do
    [[ -n "$registered_path" ]] || continue
    /usr/bin/pluginkit -r "$registered_path" >/dev/null || return 1
  done <<<"$registered_paths"
  synthetic_physical_wait_for_registration ""
}

synthetic_physical_bootout_helper() {
  local helper_pids
  helper_pids="$(synthetic_physical_exact_executable_pids "/Applications/idlescreen.app/$helper_executable_relative")" || return 1
  [[ -z "$helper_pids" ]] || return 1
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
  synthetic_physical_wait_for_selection "$expected_extension"
}

synthetic_txn_capture_external_state() {
  synthetic_physical_write_state "$installed_app" >"$1" || return 1
  synthetic_c4_copy_once "$1" pre-state.txt || return 1
  synthetic_c4_record_transition pre_state_captured
}

synthetic_txn_validate_external_state_snapshot() {
  synthetic_physical_validate_state "$1"
}

synthetic_txn_retire_production_registration() {
  [[ "$1" == /Applications/idlescreen.app ]] || return 1
  synthetic_physical_unregister_extension || return 1
  synthetic_physical_bootout_helper || return 1
  synthetic_physical_wait_for_selection "" || return 1
  synthetic_c4_record_transition production_registration_retired
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
  local process_id process_command text_executable base_name process_table lsof_output count
  local results=""
  process_table="$(/bin/ps -ww -axo pid=,command=)" || return 1
  while read -r process_id process_command; do
    case "$process_command" in
      *IdleScreen*|*ScreenSaverEngine*|*legacyScreenSaver*|*IdlescreenHelper*|*'System Settings'*) ;;
      *) continue ;;
    esac
    [[ "$process_id" =~ ^[1-9][0-9]*$ ]] || return 1
    lsof_output="$(/usr/sbin/lsof -a -p "$process_id" -d txt -Fn 2>/dev/null)" || return 1
    count="$(/usr/bin/awk 'substr($0,1,1)=="n" && length($0)>1 { count++ } END { print count+0 }' <<<"$lsof_output")" || return 1
    [[ "$count" == 1 ]] || return 1
    text_executable="$(/usr/bin/awk 'substr($0,1,1)=="n" && length($0)>1 { print substr($0,2) }' <<<"$lsof_output")" || return 1
    base_name="$(/usr/bin/basename "$text_executable")"
    case "$text_executable" in
      "$production_path/Contents/MacOS/IdleScreen"|\
      "$production_path/$helper_executable_relative"|\
      "$production_path/$extension_executable_relative"|\
      "$gate_path/Contents/MacOS/IdleScreen"|\
      "$gate_path/$helper_executable_relative"|\
      "$gate_path/$extension_executable_relative")
        results="${results}${results:+$'\n'}$process_id:$text_executable"
        ;;
      *)
        case "$base_name" in
          ScreenSaverEngine|legacyScreenSaver|IdlescreenHelper|'System Settings')
            results="${results}${results:+$'\n'}$process_id:$text_executable"
            ;;
        esac
        ;;
    esac
  done <<<"$process_table"
  [[ -z "$results" ]] || /usr/bin/sort -n <<<"$results"
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
  [[ -z "$sample_1" && "$sample_1" == "$sample_2" && "$sample_2" == "$sample_3" ]] || return 1
  synthetic_c4_copy_once "$destination" quiescence-inventory.txt || return 1
  synthetic_c4_record_transition quiescence_proven
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
  synthetic_physical_write_state "$2" >"$1" || return 1
  synthetic_c4_copy_once "$1" gate-bound-state.txt
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
  synthetic_physical_wait_for_selection "" || return 1
  local helper_pids extension_pids captured helper_cdhash extension_cdhash
  helper_pids="$(synthetic_physical_exact_executable_pids "$1/$helper_executable_relative")" || return 1
  extension_pids="$(synthetic_physical_exact_executable_pids "$1/$extension_executable_relative")" || return 1
  [[ -z "$helper_pids" && -z "$extension_pids" ]] || return 1
  captured="$(synthetic_c4_timestamp)"
  helper_cdhash="$(synthetic_physical_signed_cdhash "$1/Contents/Helpers/IdleScreenCameraAgent.app")" || return 1
  extension_cdhash="$(synthetic_physical_signed_cdhash "$1/$extension_relative")" || return 1
  {
    printf 'format=IdleScreenCameraGateC4ProcessInventoryV1\n'
    printf 'captured_at_utc=%s\n' "$captured"
    printf 'helper_path=%s\n' "$1/$helper_executable_relative"
    printf 'helper_cdhash=%s\n' "$helper_cdhash"
    printf 'helper_pids=none\n'
    printf 'extension_path=%s\n' "$1/$extension_executable_relative"
    printf 'extension_cdhash=%s\n' "$extension_cdhash"
    printf 'extension_pids=none\n'
  } >"$durable_evidence/marker-process-inventory.txt"
  marker_processes_absent_at_utc="$captured"
  synthetic_c4_record_transition gate_registration_retired
  printf 'marker_processes_absent@%s\n' "$captured" >>"$transition_events"
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
  current_service="$(synthetic_physical_service_status "$app_path")" || return 1
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
    synthetic_physical_wait_for_selection "" || return 1
  fi
  if [[ "$expected_runtime" == warm ]]; then
    /bin/launchctl kickstart "$launch_agent_domain" >/dev/null || return 1
    local deadline=$((SECONDS + 15))
    while ((SECONDS < deadline)); do
      [[ -n "$(synthetic_physical_exact_executable_pids "$app_path/$helper_executable_relative")" ]] && return 0
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
  synthetic_physical_write_state "$2" >"$1" || return 1
  synthetic_c4_copy_once "$1" post-restore-state.txt || return 1
  synthetic_c4_record_transition production_registration_rebound
  synthetic_c4_record_transition post_restore_state_captured
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

synthetic_txn_after_checkpoint() {
  local checkpoint="$1"
  local captured app_cdhash helper_cdhash extension_cdhash helper_marker extension_marker
  case "$checkpoint" in
    after_production_backup) synthetic_c4_record_transition production_bytes_backed_up ;;
    after_gate_install) synthetic_c4_record_transition gate_installed ;;
    after_gate_rebind) synthetic_c4_record_transition gate_registration_rebound ;;
    after_production_restore)
      production_restored_at_utc="$(synthetic_c4_timestamp)"
      printf 'production_bytes_restored@%s\n' "$production_restored_at_utc" >>"$transition_events"
      ;;
    after_production_rebind)
      synthetic_c4_copy_once "$synthetic_txn_journal" transaction-journal.txt || return 1
      captured="$production_restored_at_utc"
      app_cdhash="$(synthetic_physical_signed_cdhash "$installed_app")" || return 1
      helper_cdhash="$(synthetic_physical_signed_cdhash "$installed_app/Contents/Helpers/IdleScreenCameraAgent.app")" || return 1
      extension_cdhash="$(synthetic_physical_signed_cdhash "$installed_app/$extension_relative")" || return 1
      helper_marker=absent
      extension_marker=absent
      ! /usr/libexec/PlistBuddy -c 'Print :IdleScreenSyntheticGateVersion' \
        "$installed_app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/Info.plist" >/dev/null 2>&1 || return 1
      ! /usr/libexec/PlistBuddy -c 'Print :IdleScreenSyntheticHostedGateVersion' \
        "$installed_app/$extension_relative/Contents/Info.plist" >/dev/null 2>&1 || return 1
      /usr/bin/codesign --verify --deep --strict "$installed_app" >/dev/null 2>&1 || return 1
      {
        printf 'format=IdleScreenCameraGateC4InstalledIdentityV1\n'
        printf 'captured_at_utc=%s\n' "$captured"
        printf 'app_path=%s\n' "$installed_app"
        printf 'app_cdhash=%s\n' "$app_cdhash"
        printf 'helper_path=%s\n' "$installed_app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
        printf 'helper_cdhash=%s\n' "$helper_cdhash"
        printf 'extension_path=%s\n' "$installed_app/$extension_executable_relative"
        printf 'extension_cdhash=%s\n' "$extension_cdhash"
        printf 'deep_signature=valid\nhelper_marker=%s\nextension_marker=%s\n' "$helper_marker" "$extension_marker"
      } >"$durable_evidence/installed-production-identity.txt"
      synthetic_c4_write_tree_inventory "$installed_app" "$durable_evidence/restored-production-tree.tsv" || return 1
      ;;
  esac
}

started_at_utc="$(synthetic_c4_timestamp)"
set +e
synthetic_gate_transaction_run \
  "$installed_app" "$gate_candidate" "$manifest" -- "${runner[@]}"
transaction_exit=$?
set -e
[[ "$transaction_exit" == 0 ]] || exit "$transaction_exit"

completed_at_utc="$(synthetic_c4_timestamp)"
c3_archive_tree_sha256="$(synthetic_c4_manifest_value "$c3_manifest" archive_tree_sha256)" ||
  fail "C3 provenance lacks one archive hash"
c3_provenance_manifest_sha256="$(synthetic_c4_sha256_file "$c3_manifest")"
binding_c3_hash="$(synthetic_c4_manifest_value "$binding_manifest" c3_archive_tree_sha256)" ||
  fail "gate binding lacks one C3 archive hash"
binding_c3_manifest_hash="$(synthetic_c4_manifest_value "$binding_manifest" c3_provenance_manifest_sha256)" ||
  fail "gate binding lacks one C3 manifest hash"
binding_product_tree_hash="$(synthetic_c4_manifest_value "$binding_manifest" c3_product_tree_sha256)" ||
  fail "gate binding lacks one C3 product tree hash"
[[ "$binding_c3_hash" == "$c3_archive_tree_sha256" &&
   "$binding_c3_manifest_hash" == "$c3_provenance_manifest_sha256" &&
   "$binding_product_tree_hash" == "$(synthetic_c4_sha256_file "$durable_evidence/restored-production-tree.tsv")" ]] ||
  fail "restored production tree does not match the exact bound C3 archive product"
[[ "$(synthetic_c4_manifest_value "$binding_manifest" gate_manifest_sha256)" == "$(synthetic_c4_sha256_file "$manifest")" ]] ||
  fail "gate manifest differs from its C3 binding"
[[ "$(synthetic_c4_manifest_value "$c3_manifest" verification_mode)" == release &&
   "$(synthetic_c4_manifest_value "$binding_manifest" verification_mode)" == release ]] ||
  fail "C4 transaction refuses non-release C3 evidence"

expected_events=(
  pre_state_captured production_registration_retired quiescence_proven
  production_bytes_backed_up gate_installed gate_registration_rebound
  runner_started runner_completed gate_registration_retired marker_processes_absent
  production_bytes_restored production_registration_rebound post_restore_state_captured
)
[[ "$(/usr/bin/wc -l <"$transition_events" | /usr/bin/xargs)" == 13 ]] ||
  fail "transaction transition evidence is incomplete"
transitions="$durable_evidence/transaction-transitions.txt"
{
  printf 'format=IdleScreenCameraGateC4TransitionsV1\n'
  printf 'transaction_id=%s\n' "$synthetic_txn_transaction_id"
  event_index=0
  while IFS= read -r event_record; do
    expected_name="${expected_events[$event_index]}"
    [[ "$event_record" == "$expected_name@"* ]] || exit 90
    printf 'event_%02d=%s\n' "$((event_index + 1))" "$event_record"
    event_index=$((event_index + 1))
  done <"$transition_events"
  [[ "$event_index" == 13 ]] || exit 90
} >"$transitions" || fail "transaction transitions are not exact A1 lifecycle order"

for required_evidence in \
  transaction-journal.txt pre-state.txt quiescence-inventory.txt gate-bound-state.txt \
  post-restore-state.txt marker-process-inventory.txt installed-production-identity.txt \
  restored-production-tree.tsv initial-helper-runtime-entitlements.txt \
  saver-runtime-entitlements.txt a1/evidence-manifest.txt; do
  [[ -f "$durable_evidence/$required_evidence" && ! -L "$durable_evidence/$required_evidence" ]] ||
    fail "missing durable transaction evidence: $required_evidence"
done
/usr/bin/cmp -s "$durable_evidence/pre-state.txt" "$durable_evidence/post-restore-state.txt" ||
  fail "production service/selection state was not restored byte-exactly"

recovered_path=none
recovered_sha=none
if [[ "$mode" == a1tr ]]; then
  recovered_path="$durable_evidence/recovered-helper-runtime-entitlements.txt"
  [[ -f "$recovered_path" && ! -L "$recovered_path" ]] || fail "A1TR lacks recovered helper runtime entitlements"
  recovered_sha="$(synthetic_c4_sha256_file "$recovered_path")"
fi
transaction_manifest="$durable_evidence/transaction-manifest.txt"
{
  printf 'format=IdleScreenCameraGateC4TransactionV1\n'
  printf 'mode=%s\n' "$mode"
  printf 'started_at_utc=%s\n' "$started_at_utc"
  printf 'marker_processes_absent_at_utc=%s\n' "$marker_processes_absent_at_utc"
  printf 'production_restored_at_utc=%s\n' "$production_restored_at_utc"
  printf 'completed_at_utc=%s\n' "$completed_at_utc"
  printf 'c3_archive_tree_sha256=%s\n' "$c3_archive_tree_sha256"
  printf 'c3_provenance_manifest_sha256=%s\n' "$c3_provenance_manifest_sha256"
  printf 'gate_binding_manifest_sha256=%s\n' "$(synthetic_c4_sha256_file "$binding_manifest")"
  printf 'synthetic_gate_manifest_sha256=%s\n' "$(synthetic_c4_sha256_file "$manifest")"
  printf 'a1_evidence_manifest=%s\n' "$durable_evidence/a1/evidence-manifest.txt"
  printf 'a1_evidence_manifest_sha256=%s\n' "$(synthetic_c4_sha256_file "$durable_evidence/a1/evidence-manifest.txt")"
  for reference in \
    'transaction_journal:transaction-journal.txt' \
    'transaction_transitions:transaction-transitions.txt' \
    'pre_state:pre-state.txt' \
    'quiescence_inventory:quiescence-inventory.txt' \
    'gate_bound_state:gate-bound-state.txt' \
    'post_restore_state:post-restore-state.txt' \
    'marker_process_inventory:marker-process-inventory.txt' \
    'installed_production_identity:installed-production-identity.txt' \
    'restored_production_tree_inventory:restored-production-tree.tsv' \
    'initial_helper_runtime_entitlements:initial-helper-runtime-entitlements.txt' \
    'saver_runtime_entitlements:saver-runtime-entitlements.txt'; do
    key="${reference%%:*}"; leaf="${reference#*:}"; path="$durable_evidence/$leaf"
    printf '%s=%s\n%s_sha256=%s\n' "$key" "$path" "$key" "$(synthetic_c4_sha256_file "$path")"
  done
  printf 'recovered_helper_runtime_entitlements=%s\n' "$recovered_path"
  printf 'recovered_helper_runtime_entitlements_sha256=%s\n' "$recovered_sha"
} >"$transaction_manifest"
/bin/chmod a-w "$transaction_manifest" "$transitions" "$durable_evidence"/*.txt "$durable_evidence"/*.tsv 2>/dev/null ||
  fail "could not make C4 transaction evidence immutable"

echo "PASS: C4 $mode completed with replayable runtime, restoration, and exact-tree evidence."
echo "Evidence: $durable_evidence"
