#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/idlescreen.app [timeout-seconds]" >&2
  exit 64
}

[[ $# -ge 1 && $# -le 2 ]] || usage

app_path="$1"
timeout_seconds="${2:-30}"

[[ "$app_path" = /* ]] || usage
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || usage

if [[ "${IDLESCREEN_ALLOW_PHYSICAL_TESTS:-NO}" != YES ]]; then
  echo "REFUSED: set IDLESCREEN_ALLOW_PHYSICAL_TESTS=YES only after explicitly authorizing live companion delivery during a physical screen-saver run." >&2
  exit 65
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
shared_verifier="$project_root/scripts/verify-shared-state.sh"
artifact_root="$(mktemp -d /tmp/idlescreen-live-configuration.XXXXXX)"
app_info="$app_path/Contents/Info.plist"
app_binary="$app_path/Contents/MacOS/IdleScreen"
extension_path="$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex"
extension_info="$extension_path/Contents/Info.plist"
extension_binary="$extension_path/Contents/MacOS/IdleScreenScreenSaver"
launched_pids=()
restoration_required=NO

fail() {
  echo "FAIL: $*" >&2
  echo "Evidence: $artifact_root" >&2
  exit 1
}

cleanup() {
  local exit_status=$?
  local process_identifier

  trap - EXIT
  for process_identifier in "${launched_pids[@]}"; do
    [[ "$process_identifier" =~ ^[1-9][0-9]*$ ]] || continue
    if declare -F process_is_exact_executable >/dev/null &&
       process_is_exact_executable "$process_identifier" "$app_binary"; then
      /bin/kill -TERM "$process_identifier" >/dev/null 2>&1 || true
    fi
  done
  if [[ "${restoration_required:-NO}" == YES ]] &&
     declare -F restore_original_configuration_best_effort >/dev/null; then
    restore_original_configuration_best_effort || true
  fi
  exit "$exit_status"
}

trap cleanup EXIT

[[ -d "$app_path" ]] || fail "missing app bundle: $app_path"
[[ -f "$app_info" && -x "$app_binary" ]] || fail "missing companion product"
[[ -f "$extension_info" && -x "$extension_binary" ]] || fail "missing embedded extension product"
[[ -x "$shared_verifier" ]] || fail "missing shared-state verifier"

app_id="$(plutil -extract CFBundleIdentifier raw "$app_info")"
extension_id="$(plutil -extract CFBundleIdentifier raw "$extension_info")"
app_group_id="$(plutil -extract IdleScreenAppGroupIdentifier raw "$app_info")"
shared_container="$HOME/Library/Group Containers/$app_group_id"
configuration_path="$shared_container/configuration.json"
health_directory="$shared_container/Health"

[[ "$extension_id" == "$app_id.screensaver" ]] || fail "app and extension bundle identifiers do not match"
if [[ "$extension_id" == com.idlescreen.app.screensaver ]]; then
  [[ "$app_path" == /Applications/idlescreen.app ]] ||
    fail "the production configuration test requires /Applications/idlescreen.app"
fi
[[ -f "$configuration_path" && -d "$health_directory" ]] || fail "shared App Group state is unavailable"

pids_for_executable() {
  local executable="$1"
  /bin/ps -axo pid=,comm= | awk -v executable="$executable" '$2 == executable { print $1 }'
}

companion_pids="$(pids_for_executable "$app_binary")"
[[ -z "$companion_pids" ]] || fail "the companion is already running; quit it before this isolated delivery test"

extension_pids="$(pids_for_executable "$extension_binary")"
extension_pid_count="$(sed '/^$/d' <<<"$extension_pids" | wc -l | tr -d ' ')"
((extension_pid_count == 1)) || fail "exactly one hosted final-Release extension process must already be animating"
extension_pid="$(sed -n '1p' <<<"$extension_pids" | tr -d '[:space:]')"

process_is_exact_executable() {
  local process_identifier="$1"
  local expected_executable="$2"
  [[ "$(/bin/ps -ww -p "$process_identifier" -o comm= 2>/dev/null)" == "$expected_executable" ]]
}

process_is_exact_executable "$extension_pid" "$extension_binary" ||
  fail "hosted extension PID $extension_pid does not run the embedded executable"

copy_shared_state() {
  local label="$1"
  local destination="$artifact_root/$label"
  mkdir -p "$destination"
  /usr/bin/ditto "$configuration_path" "$destination/configuration.json"
  /usr/bin/ditto "$health_directory" "$destination/Health"
}

read_configuration_value() {
  local key="$1"
  plutil -extract "$key" raw "$configuration_path" 2>/dev/null || true
}

numeric_values_match() {
  awk -v lhs="$1" -v rhs="$2" 'BEGIN { difference = lhs - rhs; if (difference < 0) difference = -difference; exit(difference <= 0.0000001 ? 0 : 1) }'
}

restore_original_configuration_best_effort() {
  local restore_token="--idlescreen-lifecycle-probe=live-config-$$-failure-restore"
  local restore_process_identifier=""
  local candidate_pid
  local fallback_path
  local fallback_revision
  local fallback_modified_at

  echo "RECOVERY: restoring the original contrast after an incomplete live-delivery test." >&2
  if /usr/bin/open -g -j -n "$app_path" --args \
    "--idlescreen-configuration-probe-contrast=$original_contrast" \
    "$restore_token" >"$artifact_root/failure-restore-launch.log" 2>&1; then
    for _ in {1..50}; do
      while IFS= read -r candidate_pid; do
        [[ "$candidate_pid" =~ ^[1-9][0-9]*$ ]] || continue
        if process_is_exact_executable "$candidate_pid" "$app_binary"; then
          restore_process_identifier="$candidate_pid"
          break
        fi
      done < <(pgrep -f -- "$restore_token" || true)
      if numeric_values_match "$(read_configuration_value appearance.contrast)" "$original_contrast"; then
        restoration_required=NO
        break
      fi
      sleep 0.1
    done
  fi

  if [[ "$restore_process_identifier" =~ ^[1-9][0-9]*$ ]]; then
    /bin/kill -TERM "$restore_process_identifier" >/dev/null 2>&1 || true
  fi
  if [[ "$restoration_required" == NO ]]; then
    echo "RECOVERY: the companion restored the original contrast." >&2
    return 0
  fi

  fallback_path="$(mktemp "$shared_container/.configuration.failure-restore.XXXXXX")" || {
    echo "RECOVERY FAILED: could not create an atomic restoration file; evidence: $artifact_root" >&2
    return 1
  }
  if ! /usr/bin/ditto "$configuration_path" "$fallback_path"; then
    /bin/rm -f "$fallback_path"
    echo "RECOVERY FAILED: could not copy the shared configuration; evidence: $artifact_root" >&2
    return 1
  fi
  fallback_revision="$(read_configuration_value revision)"
  [[ "$fallback_revision" =~ ^[0-9]+$ ]] || fallback_revision="$original_revision"
  fallback_revision=$((fallback_revision + 1))
  fallback_modified_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  if plutil -replace appearance.contrast -float "$original_contrast" "$fallback_path" &&
     plutil -replace revision -integer "$fallback_revision" "$fallback_path" &&
     plutil -replace modifiedAt -string "$fallback_modified_at" "$fallback_path" &&
     /bin/mv -f "$fallback_path" "$configuration_path"; then
    restoration_required=NO
    echo "RECOVERY: atomically restored the original contrast at configuration r$fallback_revision." >&2
    return 0
  fi

  /bin/rm -f "$fallback_path"
  echo "RECOVERY FAILED: original contrast is $original_contrast; evidence: $artifact_root" >&2
  return 1
}

original_revision="$(read_configuration_value revision)"
original_contrast="$(read_configuration_value appearance.contrast)"
[[ "$original_revision" =~ ^[0-9]+$ ]] || fail "shared configuration has no valid revision"
[[ "$original_contrast" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "shared configuration has no valid contrast"

probe_contrast="$(
  awk -v value="$original_contrast" 'BEGIN {
    if (value <= 0.98) printf "%.6f", value + 0.01
    else printf "%.6f", value - 0.01
  }'
)"
numeric_values_match "$probe_contrast" "$original_contrast" && fail "probe contrast did not change"

/usr/bin/shasum -a 256 "$app_binary" "$extension_binary" >"$artifact_root/product-sha256.txt"
copy_shared_state before-change

launched_pid=""
launch_companion() {
  local label="$1"
  local contrast="${2:-}"
  local probe_token="--idlescreen-lifecycle-probe=live-config-$$-$label"
  local launch_arguments=()
  local candidate_pid

  if [[ -n "$contrast" ]]; then
    launch_arguments+=("--idlescreen-configuration-probe-contrast=$contrast")
  fi
  launch_arguments+=("$probe_token")
  /usr/bin/open -g -j -n "$app_path" --args "${launch_arguments[@]}" ||
    fail "LaunchServices could not start the $label companion probe"

  launched_pid=""
  for _ in {1..50}; do
    while IFS= read -r candidate_pid; do
      [[ "$candidate_pid" =~ ^[1-9][0-9]*$ ]] || continue
      if process_is_exact_executable "$candidate_pid" "$app_binary"; then
        launched_pid="$candidate_pid"
        break
      fi
    done < <(pgrep -f -- "$probe_token" || true)
    [[ -z "$launched_pid" ]] || break
    sleep 0.1
  done

  [[ "$launched_pid" =~ ^[1-9][0-9]*$ ]] || fail "$label companion probe did not launch"
  launched_pids+=("$launched_pid")
}

terminate_companion() {
  local process_identifier="$1"
  local label="$2"

  /bin/kill -TERM "$process_identifier" || fail "$label companion could not be terminated"
  for _ in {1..50}; do
    /bin/kill -0 "$process_identifier" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  /bin/kill -KILL "$process_identifier" >/dev/null 2>&1 || true
  fail "$label companion did not terminate cleanly"
}

shared_verification_output=""
wait_for_shared_delivery() {
  local expected_contrast="$1"
  local minimum_revision="$2"
  local expected_companion_pid="$3"
  local deadline=$((SECONDS + timeout_seconds))
  local current_contrast
  local current_revision
  local verifier_status

  while ((SECONDS < deadline)); do
    current_revision="$(read_configuration_value revision)"
    current_contrast="$(read_configuration_value appearance.contrast)"
    set +e
    shared_verification_output="$(
      "$shared_verifier" "$shared_container" "$app_id" "$extension_id" 2>&1
    )"
    verifier_status=$?
    set -e
    if ((verifier_status == 2)); then
      printf '%s\n' "$shared_verification_output" >&2
      fail "shared-state verification reported fatal evidence"
    fi
    if [[ "$current_revision" =~ ^[0-9]+$ ]] &&
       ((current_revision >= minimum_revision)) &&
       numeric_values_match "$current_contrast" "$expected_contrast" &&
       [[ "$shared_verification_output" == *"companion pid=$expected_companion_pid"* ]] &&
       [[ "$shared_verification_output" == *"extension pid=$extension_pid"* ]]; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

extension_is_animating_at_revision() {
  local expected_revision="$1"
  local report
  local report_pid
  local report_revision
  local report_lifecycle

  shopt -s nullglob
  for report in "$health_directory"/screenSaverExtension-*.json; do
    report_pid="$(plutil -extract processIdentifier raw "$report" 2>/dev/null || true)"
    report_revision="$(plutil -extract configurationRevision raw "$report" 2>/dev/null || true)"
    report_lifecycle="$(plutil -extract lifecycle raw "$report" 2>/dev/null || true)"
    if [[ "$report_pid" == "$extension_pid" &&
          "$report_revision" == "$expected_revision" &&
          "$report_lifecycle" == animating ]]; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

restoration_required=YES
launch_companion change "$probe_contrast"
change_pid="$launched_pid"
if ! wait_for_shared_delivery "$probe_contrast" $((original_revision + 1)) "$change_pid"; then
  fail "the running extension did not apply the real companion edit"
fi
changed_revision="$(read_configuration_value revision)"
printf '%s\n' "$shared_verification_output" >"$artifact_root/change-verification.txt"
copy_shared_state after-change
terminate_companion "$change_pid" change

sleep 2
process_is_exact_executable "$extension_pid" "$extension_binary" ||
  fail "the extension exited when the companion quit"
extension_is_animating_at_revision "$changed_revision" ||
  fail "the extension stopped animating or lost the changed revision after companion quit"
copy_shared_state after-quit

launch_companion relaunch
relaunch_pid="$launched_pid"
[[ "$relaunch_pid" != "$change_pid" ]] || fail "companion relaunch reused the exited process"
if ! wait_for_shared_delivery "$probe_contrast" "$changed_revision" "$relaunch_pid"; then
  fail "the relaunched companion did not reattach to the existing extension revision"
fi
printf '%s\n' "$shared_verification_output" >"$artifact_root/relaunch-verification.txt"
copy_shared_state after-relaunch
terminate_companion "$relaunch_pid" relaunch

launch_companion restore "$original_contrast"
restore_pid="$launched_pid"
if ! wait_for_shared_delivery "$original_contrast" $((changed_revision + 1)) "$restore_pid"; then
  fail "the companion did not restore the original contrast through live delivery"
fi
restored_revision="$(read_configuration_value revision)"
printf '%s\n' "$shared_verification_output" >"$artifact_root/restore-verification.txt"
copy_shared_state after-restore
terminate_companion "$restore_pid" restore

sleep 1
process_is_exact_executable "$extension_pid" "$extension_binary" ||
  fail "the extension exited after companion restoration"
extension_is_animating_at_revision "$restored_revision" ||
  fail "the extension did not remain animating at the restored revision"
numeric_values_match "$(read_configuration_value appearance.contrast)" "$original_contrast" ||
  fail "the original contrast was not restored"
[[ -z "$(pids_for_executable "$app_binary")" ]] || fail "a companion probe process remains active"
restoration_required=NO

trap - EXIT
echo "PASS: final-Release configuration r$changed_revision reached extension pid=$extension_pid from companion pid=$change_pid."
echo "PASS: the extension survived companion quit; companion pid=$relaunch_pid reattached without restarting it."
echo "PASS: companion pid=$restore_pid restored the original contrast at configuration r$restored_revision."
echo "NOTE: unlock the Mac normally to complete the surrounding host lifecycle."
echo "Evidence: $artifact_root"
