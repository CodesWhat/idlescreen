#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /Applications/idlescreen.app /absolute/C3-provenance.txt /absolute/C4-a1tr-transaction-manifest.txt /absolute/new-C5-evidence [--record-targeted-tcc-reset] [--open-camera-settings]" >&2
  exit 64
}

[[ $# -ge 4 && $# -le 6 ]] || usage
app_path="$1"
c3_manifest="$2"
c4_restoration_manifest="$3"
evidence_root="$4"
shift 4

record_tcc_reset=false
open_camera_settings=false
while (($# > 0)); do
  case "$1" in
    --record-targeted-tcc-reset)
      $record_tcc_reset && usage
      record_tcc_reset=true
      ;;
    --open-camera-settings)
      $open_camera_settings && usage
      open_camera_settings=true
      ;;
    *) usage ;;
  esac
  shift
done

[[ "$app_path" == /Applications/idlescreen.app &&
   "$c3_manifest" = /* && "$c4_restoration_manifest" = /* &&
   "$evidence_root" = /* && "$evidence_root" != / ]] || usage
[[ -f "$c3_manifest" && ! -L "$c3_manifest" &&
   -f "$c4_restoration_manifest" && ! -L "$c4_restoration_manifest" ]] || usage
[[ ! -e "$evidence_root" && ! -L "$evidence_root" ]] || {
  echo "FAIL: refusing to replace existing C5 evidence: $evidence_root" >&2
  exit 73
}
[[ -t 0 ]] || {
  echo "REFUSED: C5 requires an attended unlocked console and interactive operator witness." >&2
  exit 65
}

require_authorization() {
  local variable="$1" description="$2"
  [[ "${!variable:-}" == YES ]] || {
    echo "REFUSED: $description requires $variable=YES immediately before this run." >&2
    exit 65
  }
}

require_action_confirmation() {
  local id_variable="$1" token="$2" description="$3" authorization_id confirmation
  authorization_id="${!id_variable:-}"
  [[ "$authorization_id" =~ ^[A-Za-z0-9._-]{8,128}$ ]] || {
    echo "REFUSED: $description requires a fresh 8-128 character $id_variable." >&2
    exit 65
  }
  assert_unlocked
  echo "AUTHORIZE NOW: $description" >&2
  echo "Type exactly: $token:$authorization_id" >&2
  IFS= read -r confirmation
  [[ "$confirmation" == "$token:$authorization_id" ]] || {
    echo "REFUSED: immediate $description authorization was not confirmed." >&2
    exit 65
  }
  utc_now
}

validate_distinct_authorization_ids() {
  local variables=("$@") i j left right
  for ((i = 0; i < ${#variables[@]}; i += 1)); do
    left="${!variables[$i]:-}"
    [[ "$left" =~ ^[A-Za-z0-9._-]{8,128}$ ]] || {
      echo "REFUSED: ${variables[$i]} must be a fresh 8-128 character authorization ID." >&2
      exit 65
    }
    for ((j = i + 1; j < ${#variables[@]}; j += 1)); do
      right="${!variables[$j]:-}"
      [[ "$left" != "$right" ]] || {
        echo "REFUSED: C5 action authorization IDs must be distinct." >&2
        exit 65
      }
    done
  done
}

require_authorization IDLESCREEN_C5_ALLOW_PHYSICAL_CAMERA \
  "the physical C5 row"
require_authorization IDLESCREEN_C5_AUTHORIZE_APP_LAUNCH \
  "launching the exact companion app"
require_authorization IDLESCREEN_C5_AUTHORIZE_TCC_REQUEST \
  "requesting Camera permission"
require_authorization IDLESCREEN_C5_AUTHORIZE_CAMERA_START \
  "starting the explicit companion preview lease"
require_authorization IDLESCREEN_C5_AUTHORIZE_HARDWARE_CAMERA_USE \
  "using physical camera hardware"

if $record_tcc_reset; then
  require_authorization IDLESCREEN_C5_AUTHORIZE_TCC_RESET \
    "recording a separately performed targeted TCC reset"
elif [[ "${IDLESCREEN_C5_AUTHORIZE_TCC_RESET:-}" == YES ]]; then
  echo "REFUSED: TCC-reset authorization is ambient but --record-targeted-tcc-reset was not requested." >&2
  exit 65
fi
if $open_camera_settings; then
  require_authorization IDLESCREEN_C5_AUTHORIZE_TCC_SETTINGS \
    "opening Camera Privacy Settings"
elif [[ "${IDLESCREEN_C5_AUTHORIZE_TCC_SETTINGS:-}" == YES ]]; then
  echo "REFUSED: Camera Settings authorization is ambient but --open-camera-settings was not requested." >&2
  exit 65
fi

authorization_id_variables=(
  IDLESCREEN_C5_APP_LAUNCH_AUTHORIZATION_ID
  IDLESCREEN_C5_TCC_REQUEST_AUTHORIZATION_ID
  IDLESCREEN_C5_CAMERA_START_AUTHORIZATION_ID
  IDLESCREEN_C5_HARDWARE_USE_AUTHORIZATION_ID
)
$record_tcc_reset && authorization_id_variables+=(IDLESCREEN_C5_TCC_RESET_AUTHORIZATION_ID)
$open_camera_settings && authorization_id_variables+=(IDLESCREEN_C5_TCC_SETTINGS_AUTHORIZATION_ID)
validate_distinct_authorization_ids "${authorization_id_variables[@]}"

if [[ -n "${IDLESCREEN_PROCESS_GUARD_FIXTURE_MODE:-}" ||
      -n "${IDLESCREEN_PROCESS_GUARD_PS:-}" ||
      -n "${IDLESCREEN_PROCESS_GUARD_CODESIGN:-}" ||
      -n "${IDLESCREEN_PROVENANCE_FIXTURE_MODE:-}" ||
      -n "${IDLESCREEN_PROVENANCE_CODESIGN:-}" ||
      -n "${IDLESCREEN_PROVENANCE_SECURITY:-}" ]]; then
  echo "REFUSED: C5 physical evidence forbids fixture and command overrides." >&2
  exit 65
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
verifier="$project_root/scripts/verify-camera-gate-c5-evidence.py"
lock_probe="$project_root/scripts/read-console-lock-state.sh"
app_executable="$app_path/Contents/MacOS/IdleScreen"
helper_bundle="$app_path/Contents/Helpers/IdleScreenCameraAgent.app"
helper_executable="$helper_bundle/Contents/MacOS/IdleScreenCameraAgent"
extension_bundle="$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex"
extension_executable="$extension_bundle/Contents/MacOS/IdleScreenScreenSaver"
log_path="$evidence_root/combined.log"
identity_snapshot="$evidence_root/identity-snapshot.txt"
runtime_ownership="$evidence_root/runtime-ownership.txt"
attribution_observation="$evidence_root/attribution-observation.txt"
led_observation="$evidence_root/led-observation.txt"
checkpoints="$evidence_root/checkpoints.txt"
evidence_manifest="$evidence_root/evidence-manifest.txt"
log_stream_pid=""
cleanup_complete=false

fail() {
  echo "FAIL: $*" >&2
  [[ ! -d "$evidence_root" ]] || echo "Evidence: $evidence_root" >&2
  exit 1
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print tolower($1) }'
}

manifest_value() {
  local source="$1" key="$2"
  /usr/bin/awk -F= -v key="$key" \
    '$1 == key { print substr($0, length($1) + 2); count++ }
     END { exit(count == 1 ? 0 : 1) }' "$source" ||
    fail "$source does not contain exactly one $key"
}

utc_now() {
  /usr/bin/python3 -c \
    'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z"))'
}

assert_unlocked() {
  local state
  state="$("$lock_probe" 2>/dev/null || true)"
  [[ "$state" == false ]] || fail "the console is locked or its lock state is unreadable"
}

signed_value() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 |
    /usr/bin/awk -F= -v key="$2" '$1 == key { print $2; count++ } END { exit(count == 1 ? 0 : 1) }'
}

plist_value() {
  /usr/bin/plutil -extract "$2" raw "$1" 2>/dev/null
}

text_executable_for_pid() {
  local pid="$1" output count path
  output="$(/usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null)" || return 1
  count="$(/usr/bin/awk 'substr($0,1,1)=="n" && length($0)>1 { n++ } END { print n+0 }' <<<"$output")"
  [[ "$count" == 1 ]] || return 1
  path="$(/usr/bin/awk 'substr($0,1,1)=="n" && length($0)>1 { print substr($0,2); exit }' <<<"$output")"
  [[ "$path" = /* ]] || return 1
  /bin/realpath "$path"
}

pids_for_exact_path() {
  local expected="$1" expected_real basename listing pid command resolved
  expected_real="$(/bin/realpath "$expected")" || return 1
  basename="$(/usr/bin/basename "$expected_real")"
  listing="$(/bin/ps -ww -axo pid=,comm= 2>/dev/null)" || return 1
  [[ -n "$listing" ]] || return 1
  while read -r pid command; do
    [[ "$pid" =~ ^[1-9][0-9]*$ && -n "$command" ]] || continue
    [[ "$(/usr/bin/basename "$command")" == "$basename" ]] || continue
    resolved="$(text_executable_for_pid "$pid")" || return 1
    [[ "$resolved" == "$expected_real" ]] && printf '%s\n' "$pid"
  done <<<"$listing"
}

processes_for_executable_basename() {
  local expected="$1" basename listing pid command resolved
  basename="$(/usr/bin/basename "$expected")"
  listing="$(/bin/ps -ww -axo pid=,comm= 2>/dev/null)" || return 1
  [[ -n "$listing" ]] || return 1
  while read -r pid command; do
    [[ "$pid" =~ ^[1-9][0-9]*$ && -n "$command" ]] || continue
    [[ "$(/usr/bin/basename "$command")" == "$basename" ]] || continue
    resolved="$(text_executable_for_pid "$pid")" || return 1
    printf '%s\t%s\n' "$pid" "$resolved"
  done <<<"$listing"
}

assert_no_alternate_executable_copy() {
  local expected="$1" expected_real inventory pid path
  expected_real="$(/bin/realpath "$expected")" || return 1
  inventory="$(processes_for_executable_basename "$expected")" || return 1
  while IFS=$'\t' read -r pid path; do
    [[ -z "$pid" || "$path" == "$expected_real" ]] || return 1
  done <<<"$inventory"
}

single_pid_for_exact_path() {
  local expected="$1" pids count
  pids="$(pids_for_exact_path "$expected")" || return 1
  count="$(printf '%s\n' "$pids" | /usr/bin/awk 'NF { n++ } END { print n+0 }')"
  [[ "$count" == 1 ]] || return 1
  printf '%s\n' "$pids"
}

validate_running_code() {
  local pid="$1" path="$2" cdhash="$3" observed_path observed_hash
  observed_path="$(text_executable_for_pid "$pid")" || return 1
  [[ "$observed_path" == "$path" ]] || return 1
  /usr/bin/codesign --verify --verbose=4 "$pid" >/dev/null 2>&1 || return 1
  observed_hash="$(signed_value "$pid" CDHash)" || return 1
  observed_hash="$(printf '%s\n' "$observed_hash" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  [[ "$observed_hash" == "$cdhash" ]]
}

line_count() {
  /usr/bin/wc -l <"$log_path" | /usr/bin/xargs
}

pattern_after_line() {
  local first_line="$1" pattern="$2"
  /usr/bin/tail -n "+$first_line" "$log_path" | /usr/bin/grep -Eq "$pattern"
}

wait_for_pattern() {
  local first_line="$1" pattern="$2" polls="$3" description="$4" poll
  for ((poll = 0; poll <= polls; poll += 1)); do
    ((poll % 10 != 0)) || assert_unlocked
    /bin/kill -0 "$log_stream_pid" 2>/dev/null || fail "unified-log stream exited early"
    pattern_after_line "$first_line" "$pattern" && return 0
    /bin/sleep 0.1
  done
  fail "timed out waiting for $description"
}

first_log_line() {
  local first_line="$1" pattern="$2"
  /usr/bin/tail -n "+$first_line" "$log_path" |
    /usr/bin/grep -E "$pattern" | /usr/bin/head -1
}

last_log_line() {
  local first_line="$1" pattern="$2"
  /usr/bin/tail -n "+$first_line" "$log_path" |
    /usr/bin/grep -E "$pattern" | /usr/bin/tail -1
}

timestamp_from_log_line() {
  /usr/bin/python3 -c '
import re, sys
from datetime import datetime, timezone
line = sys.stdin.read().rstrip("\n")
m = re.match(r"^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3,6})([+-][0-9]{4})?\s", line)
if not m:
    raise SystemExit(1)
value = m.group(1) + (m.group(2) or "+0000")
parsed = datetime.strptime(value, "%Y-%m-%d %H:%M:%S.%f%z").astimezone(timezone.utc)
print(parsed.isoformat(timespec="microseconds").replace("+00:00", "Z"))
'
}

event_timestamp() {
  local first_line="$1" pattern="$2" line
  line="$(first_log_line "$first_line" "$pattern")" || return 1
  printf '%s\n' "$line" | timestamp_from_log_line
}

assert_no_capture_or_lease() {
  local first_line="$1"
  if /usr/bin/tail -n "+$first_line" "$log_path" |
    /usr/bin/grep -Eq \
      'lease_count_changed .*current=[1-9][0-9]*|capture_start_requested|capture_started|first_frame_published|capture_stop_requested|capture_stopped'; then
    fail "permission-only A0 unexpectedly acquired a preview lease or started capture"
  fi
}

stop_log_stream() {
  [[ -n "$log_stream_pid" ]] || return 0
  if /bin/kill -0 "$log_stream_pid" 2>/dev/null; then
    /bin/kill -TERM "$log_stream_pid" 2>/dev/null || return 1
  fi
  local poll
  for ((poll = 0; poll < 30; poll += 1)); do
    /bin/kill -0 "$log_stream_pid" 2>/dev/null || {
      wait "$log_stream_pid" 2>/dev/null || true
      log_stream_pid=""
      return 0
    }
    /bin/sleep 0.1
  done
  return 1
}

cleanup() {
  local status=$?
  if ! $cleanup_complete; then
    stop_log_stream || true
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM HUP

[[ -x "$verifier" && -x "$lock_probe" ]] || fail "C5 verifier or lock-state probe is unavailable"
assert_unlocked

for required in "$app_executable" "$helper_executable" "$extension_executable"; do
  [[ -x "$required" && ! -L "$required" ]] || fail "exact installed Release component is missing: $required"
done
/usr/bin/codesign --verify --deep --strict "$app_path" >/dev/null 2>&1 ||
  fail "installed product fails deep strict signature verification"

c3_schema="$(manifest_value "$c3_manifest" schema)"
c3_mode="$(manifest_value "$c3_manifest" verification_mode)"
c3_archive_hash="$(manifest_value "$c3_manifest" archive_tree_sha256)"
c3_team="$(manifest_value "$c3_manifest" team_identifier)"
c3_app_cdhash="$(manifest_value "$c3_manifest" app_cdhash | /usr/bin/tr '[:upper:]' '[:lower:]')"
c3_helper_cdhash="$(manifest_value "$c3_manifest" helper_cdhash | /usr/bin/tr '[:upper:]' '[:lower:]')"
c3_extension_cdhash="$(manifest_value "$c3_manifest" extension_cdhash | /usr/bin/tr '[:upper:]' '[:lower:]')"
[[ "$c3_schema" == IdleScreenReleaseArchiveProvenance/v1 && "$c3_mode" == release &&
   "$c3_team" == 3524374A2S && "$c3_archive_hash" =~ ^[0-9a-f]{64}$ &&
   "$c3_app_cdhash" =~ ^[0-9a-f]{40}$ && "$c3_helper_cdhash" =~ ^[0-9a-f]{40}$ &&
   "$c3_extension_cdhash" =~ ^[0-9a-f]{40}$ ]] || fail "C3 provenance is not exact release-mode evidence"

[[ "$(manifest_value "$c4_restoration_manifest" format)" == IdleScreenCameraGateC4TransactionV1 &&
   "$(manifest_value "$c4_restoration_manifest" mode)" == a1tr &&
   "$(manifest_value "$c4_restoration_manifest" c3_archive_tree_sha256)" == "$c3_archive_hash" &&
   "$(manifest_value "$c4_restoration_manifest" c3_provenance_manifest_sha256)" == "$(sha256_file "$c3_manifest")" ]] ||
  fail "C4 restoration manifest is not the exact C3-bound A1TR restoration"
c4_installed_identity="$(manifest_value "$c4_restoration_manifest" installed_production_identity)"
c4_installed_identity_sha="$(manifest_value "$c4_restoration_manifest" installed_production_identity_sha256)"
[[ "$c4_installed_identity" = /* && -f "$c4_installed_identity" && ! -L "$c4_installed_identity" &&
   "$(sha256_file "$c4_installed_identity")" == "$c4_installed_identity_sha" ]] ||
  fail "C4 restored identity evidence is missing or changed"
[[ "$(manifest_value "$c4_installed_identity" app_cdhash)" == "$c3_app_cdhash" &&
   "$(manifest_value "$c4_installed_identity" helper_cdhash)" == "$c3_helper_cdhash" &&
   "$(manifest_value "$c4_installed_identity" extension_cdhash)" == "$c3_extension_cdhash" &&
   "$(manifest_value "$c4_installed_identity" deep_signature)" == valid &&
   "$(manifest_value "$c4_installed_identity" helper_marker)" == absent &&
   "$(manifest_value "$c4_installed_identity" extension_marker)" == absent ]] ||
  fail "C4 did not restore the exact marker-free C3 identity"

current_app_cdhash="$(signed_value "$app_path" CDHash | /usr/bin/tr '[:upper:]' '[:lower:]')"
current_helper_cdhash="$(signed_value "$helper_bundle" CDHash | /usr/bin/tr '[:upper:]' '[:lower:]')"
current_extension_cdhash="$(signed_value "$extension_bundle" CDHash | /usr/bin/tr '[:upper:]' '[:lower:]')"
[[ "$current_app_cdhash" == "$c3_app_cdhash" &&
   "$current_helper_cdhash" == "$c3_helper_cdhash" &&
   "$current_extension_cdhash" == "$c3_extension_cdhash" ]] ||
  fail "installed signed product differs from the restored C3 identity"
[[ "$(plist_value "$app_path/Contents/Info.plist" CFBundleIdentifier)" == com.idlescreen.app &&
   "$(plist_value "$helper_bundle/Contents/Info.plist" CFBundleIdentifier)" == com.idlescreen.camera-agent &&
   "$(plist_value "$extension_bundle/Contents/Info.plist" CFBundleIdentifier)" == com.idlescreen.app.screensaver ]] ||
  fail "installed bundle identifiers drifted"
! /usr/libexec/PlistBuddy -c 'Print :IdleScreenSyntheticGateVersion' \
  "$helper_bundle/Contents/Info.plist" >/dev/null 2>&1 || fail "synthetic helper marker remains installed"
! /usr/libexec/PlistBuddy -c 'Print :IdleScreenSyntheticHostedGateVersion' \
  "$extension_bundle/Contents/Info.plist" >/dev/null 2>&1 || fail "synthetic hosted marker remains installed"

companion_preflight="$(pids_for_exact_path "$app_executable")" ||
  fail "could not prove exact companion-process absence"
extension_preflight="$(pids_for_exact_path "$extension_executable")" ||
  fail "could not prove exact screen-saver-process absence"
assert_no_alternate_executable_copy "$helper_executable" ||
  fail "a camera helper executable with the same name is running from another path"
[[ -z "$companion_preflight" ]] || fail "the companion is already running before its authorized launch"
[[ -z "$extension_preflight" ]] || fail "a screen-saver extension is active before C5"

evidence_parent="$(/usr/bin/dirname "$evidence_root")"
[[ -d "$evidence_parent" && ! -L "$evidence_parent" ]] || usage
evidence_parent="$(/bin/realpath "$evidence_parent")"
evidence_root="$evidence_parent/$(/usr/bin/basename "$evidence_root")"
/bin/mkdir -m 700 "$evidence_root"
: >"$log_path"
runner_started_at_utc="$(utc_now)"
identity_verified_at_utc="$(utc_now)"
console_unlocked_at_utc="$(utc_now)"

{
  printf 'format=IdleScreenCameraGateC5IdentityV1\n'
  printf 'captured_at_utc=%s\n' "$identity_verified_at_utc"
  printf 'app_path=%s\napp_bundle_identifier=com.idlescreen.app\n' "$app_path"
  printf 'app_team_identifier=3524374A2S\napp_cdhash=%s\n' "$c3_app_cdhash"
  printf 'helper_path=%s\nhelper_bundle_identifier=com.idlescreen.camera-agent\n' "$helper_executable"
  printf 'helper_team_identifier=3524374A2S\nhelper_cdhash=%s\n' "$c3_helper_cdhash"
  printf 'extension_path=%s\nextension_bundle_identifier=com.idlescreen.app.screensaver\n' "$extension_executable"
  printf 'extension_team_identifier=3524374A2S\nextension_cdhash=%s\n' "$c3_extension_cdhash"
  printf 'deep_signature=valid\nhelper_marker=absent\nextension_marker=absent\n'
  printf 'restored_release_identity=exact\n'
} >"$identity_snapshot"

log_predicate='subsystem == "com.idlescreen.camera-agent" OR (process == "IdleScreen" AND subsystem == "com.idlescreen.app" AND category == "CameraEvidence" AND eventMessage BEGINSWITH "companion_frame_consumed")'
/usr/bin/log stream --style compact --level info --timeout 360 --predicate "$log_predicate" \
  >"$log_path" 2>/dev/null &
log_stream_pid=$!
/bin/sleep 0.2
/bin/kill -0 "$log_stream_pid" 2>/dev/null || fail "could not start unified-log evidence stream"

if $record_tcc_reset; then
  require_action_confirmation \
    IDLESCREEN_C5_TCC_RESET_AUTHORIZATION_ID AUTHORIZE_TCC_RESET \
    "the separately performed targeted Camera TCC reset" >/dev/null
  echo "ACTION: perform the separately authorized targeted Camera TCC reset for idlescreen now."
  echo "This runner deliberately does not choose or execute a reset command. Type RESET_DONE after it completes."
  IFS= read -r reset_confirmation
  [[ "$reset_confirmation" == RESET_DONE ]] || fail "targeted TCC reset was not explicitly witnessed"
  assert_unlocked
  tcc_reset_action=performed
  tcc_reset_authorization=yes
else
  tcc_reset_action=not-performed
  tcc_reset_authorization=not-used
fi

app_launch_authorized_at_utc="$(require_action_confirmation \
  IDLESCREEN_C5_APP_LAUNCH_AUTHORIZATION_ID AUTHORIZE_APP_LAUNCH \
  "launching the exact companion app")"
permission_phase_first_line=$(( $(line_count) + 1 ))
app_launched_at_utc="$(utc_now)"
/usr/bin/open -n "$app_path" || fail "authorized companion launch failed"
echo "ACTION: navigate to Camera in idlescreen. Do not request permission or start preview yet."
wait_for_pattern "$permission_phase_first_line" \
  'authorization_status status=not-determined source=(startup|status-refresh)' \
  150 "fresh not-determined helper authorization"
permission_not_determined_at_utc="$(event_timestamp "$permission_phase_first_line" 'authorization_status status=not-determined source=(startup|status-refresh)')" ||
  fail "could not bind fresh authorization timestamp"
assert_no_capture_or_lease "$permission_phase_first_line"

permission_action_authorized_at_utc="$(require_action_confirmation \
  IDLESCREEN_C5_TCC_REQUEST_AUTHORIZATION_ID AUTHORIZE_TCC_REQUEST \
  "clicking Request Camera Access once")"
permission_request_at_utc="$(utc_now)"
permission_request_first_line=$(( $(line_count) + 1 ))
echo "ACTION: click Request Camera Access once. Do not click Start Camera Preview."
wait_for_pattern "$permission_request_first_line" \
  'authorization_status status=authorized source=explicit-request-completion' \
  600 "explicit Camera permission completion"
permission_authorized_at_utc="$(event_timestamp "$permission_request_first_line" 'authorization_status status=authorized source=explicit-request-completion')" ||
  fail "could not bind permission-completion timestamp"
assert_no_capture_or_lease "$permission_phase_first_line"
permission_zero_lease_at_utc="$(utc_now)"

echo "WITNESS: type the exact visible app label from the Camera prompt (expected: idlescreen)."
IFS= read -r visible_permission_label
[[ "$visible_permission_label" == idlescreen ]] ||
  fail "fresh permission prompt did not visibly attribute to idlescreen"
assert_unlocked

if $open_camera_settings; then
  require_action_confirmation \
    IDLESCREEN_C5_TCC_SETTINGS_AUTHORIZATION_ID AUTHORIZE_TCC_SETTINGS \
    "opening Camera Privacy Settings" >/dev/null
  /usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Camera' ||
    fail "authorized Camera Privacy Settings open failed"
  echo "WITNESS: confirm the idlescreen Camera entry is visible by typing idlescreen."
  IFS= read -r settings_label
  [[ "$settings_label" == idlescreen ]] || fail "Camera Settings did not show idlescreen"
  assert_unlocked
  tcc_settings_action=performed
  tcc_settings_authorization=yes
  echo "ACTION: return to the already-running idlescreen Camera page without starting preview."
else
  tcc_settings_action=not-performed
  tcc_settings_authorization=not-used
fi

{
  printf 'format=IdleScreenCameraGateC5AttributionV1\n'
  printf 'fresh_authorization_state=not-determined\n'
  printf 'visible_permission_label=idlescreen\n'
  printf 'permission_action=companion-explicit-request\n'
  printf 'authorized_bundle_identifier=com.idlescreen.camera-agent\n'
  printf 'preview_lease_during_permission=absent\n'
  printf 'capture_during_permission=absent\n'
  printf 'attribution_verdict=resolved-fresh\n'
} >"$attribution_observation"

echo "WITNESS: confirm the physical camera indicator is off before preview by typing LED_OFF_BEFORE."
IFS= read -r led_off_before_confirmation
[[ "$led_off_before_confirmation" == LED_OFF_BEFORE ]] ||
  fail "camera indicator was not witnessed off before preview"
assert_unlocked

preview_action_authorized_at_utc="$(require_action_confirmation \
  IDLESCREEN_C5_CAMERA_START_AUTHORIZATION_ID AUTHORIZE_CAMERA_START \
  "starting the explicit companion preview lease")"
hardware_use_authorized_at_utc="$(require_action_confirmation \
  IDLESCREEN_C5_HARDWARE_USE_AUTHORIZATION_ID AUTHORIZE_HARDWARE_USE \
  "using physical camera hardware")"
preview_request_at_utc="$(utc_now)"
preview_first_line=$(( $(line_count) + 1 ))
assert_unlocked
echo "ACTION: click Start Camera Preview once. This is the separately authorized hardware-camera action."
wait_for_pattern "$preview_first_line" \
  'lease_count_changed previous=0 current=1 epoch=[1-9][0-9]*' \
  20 "one explicit preview lease"
preview_lease_at_utc="$(event_timestamp "$preview_first_line" 'lease_count_changed previous=0 current=1 epoch=[1-9][0-9]*')" ||
  fail "could not bind preview-lease timestamp"
wait_for_pattern "$preview_first_line" \
  'capture_started generation=[1-9][0-9]* epoch=[1-9][0-9]*' \
  30 "physical capture start"
capture_started_at_utc="$(event_timestamp "$preview_first_line" 'capture_started generation=[1-9][0-9]* epoch=[1-9][0-9]*')" ||
  fail "could not bind capture-start timestamp"
wait_for_pattern "$preview_first_line" \
  'first_frame_published generation=[1-9][0-9]* epoch=[1-9][0-9]* sequence=[1-9][0-9]*' \
  30 "first physical camera frame"
wait_for_pattern "$preview_first_line" \
  'companion_frame_consumed generation=[1-9][0-9]* epoch=[1-9][0-9]* sequence=[1-9][0-9]*' \
  50 "first companion-consumed receipt"

capture_line="$(first_log_line "$preview_first_line" 'capture_started generation=[1-9][0-9]* epoch=[1-9][0-9]*')"
capture_generation="$(/usr/bin/sed -nE 's/.*capture_started generation=([1-9][0-9]*) epoch=([1-9][0-9]*).*/\1/p' <<<"$capture_line")"
producer_epoch="$(/usr/bin/sed -nE 's/.*capture_started generation=([1-9][0-9]*) epoch=([1-9][0-9]*).*/\2/p' <<<"$capture_line")"
first_receipt_line="$(first_log_line "$preview_first_line" 'companion_frame_consumed generation=[1-9][0-9]* epoch=[1-9][0-9]* sequence=[1-9][0-9]*')"
consumption_generation="$(/usr/bin/sed -nE 's/.*companion_frame_consumed generation=([1-9][0-9]*) epoch=([1-9][0-9]*) sequence=.*/\1/p' <<<"$first_receipt_line")"
receipt_epoch="$(/usr/bin/sed -nE 's/.*companion_frame_consumed generation=([1-9][0-9]*) epoch=([1-9][0-9]*) sequence=.*/\2/p' <<<"$first_receipt_line")"
[[ "$capture_generation" =~ ^[1-9][0-9]*$ &&
   "$consumption_generation" =~ ^[1-9][0-9]*$ &&
   "$producer_epoch" =~ ^[1-9][0-9]*$ && "$receipt_epoch" == "$producer_epoch" ]] ||
  fail "could not bind capture and consumption generations to one producer epoch"

for _ in {1..80}; do
  assert_unlocked
  receipt_count="$(/usr/bin/tail -n "+$preview_first_line" "$log_path" |
    /usr/bin/sed -nE \
      "s/.*companion_frame_consumed generation=$consumption_generation epoch=$producer_epoch sequence=([1-9][0-9]*).*/\\1/p" |
    /usr/bin/awk '$1 > prior { count++; prior=$1 } END { print count+0 }')"
  ((receipt_count >= 3)) && break
  /bin/sleep 0.1
done
((receipt_count >= 3)) || fail "fewer than three increasing companion-consumed receipts arrived"

receipt_sequences="$(/usr/bin/tail -n "+$preview_first_line" "$log_path" |
  /usr/bin/sed -nE \
    "s/.*companion_frame_consumed generation=$consumption_generation epoch=$producer_epoch sequence=([1-9][0-9]*).*/\\1/p")"
first_consumed_sequence="$(printf '%s\n' "$receipt_sequences" | /usr/bin/awk 'NF { print; exit }')"
last_consumed_sequence="$(printf '%s\n' "$receipt_sequences" | /usr/bin/awk 'NF { last=$1 } END { print last }')"
consumed_receipt_count="$(printf '%s\n' "$receipt_sequences" | /usr/bin/awk 'NF { n++ } END { print n+0 }')"
first_consumed_at_utc="$(event_timestamp "$preview_first_line" "companion_frame_consumed generation=$consumption_generation epoch=$producer_epoch sequence=[1-9][0-9]*")" ||
  fail "could not bind first companion receipt timestamp"
last_receipt_line="$(last_log_line "$preview_first_line" "companion_frame_consumed generation=$consumption_generation epoch=$producer_epoch sequence=[1-9][0-9]*")"
last_consumed_at_utc="$(printf '%s\n' "$last_receipt_line" | timestamp_from_log_line)" ||
  fail "could not bind last companion receipt timestamp"

helper_pid="$(/usr/bin/tail -n "+$preview_first_line" "$log_path" |
  /usr/bin/sed -nE 's/.*IdleScreenCameraAgent\[([1-9][0-9]*):.*capture_started.*/\1/p' |
  /usr/bin/head -1)"
companion_pid="$(/usr/bin/tail -n "+$preview_first_line" "$log_path" |
  /usr/bin/sed -nE 's/.*peer_admission_accepted .* pid=([1-9][0-9]*) team_id=3524374A2S bundle_id=com\.idlescreen\.app role=companion.*/\1/p' |
  /usr/bin/head -1)"
[[ "$helper_pid" =~ ^[1-9][0-9]*$ && "$companion_pid" =~ ^[1-9][0-9]*$ ]] ||
  fail "could not bind exact helper and companion PIDs"
[[ "$(single_pid_for_exact_path "$helper_executable")" == "$helper_pid" ]] ||
  fail "the capture helper is absent or not the sole exact-path helper"
[[ "$(single_pid_for_exact_path "$app_executable")" == "$companion_pid" ]] ||
  fail "the companion consumer is absent or not the sole exact-path companion"
assert_no_alternate_executable_copy "$helper_executable" ||
  fail "another camera helper executable is running from a non-candidate path"
extension_pids="$(pids_for_exact_path "$extension_executable")" ||
  fail "could not prove hosted-extension absence during C5"
[[ -z "$extension_pids" ]] || fail "a screen-saver extension participated in companion-only C5"
validate_running_code "$helper_pid" "$helper_executable" "$c3_helper_cdhash" ||
  fail "running helper does not match the exact restored Release identity"
validate_running_code "$companion_pid" "$app_executable" "$c3_app_cdhash" ||
  fail "running companion does not match the exact restored Release identity"

if /usr/bin/tail -n "+$preview_first_line" "$log_path" |
  /usr/bin/grep -Eq 'lease_count_changed .*current=([2-9]|[1-9][0-9]+)|role=screen-saver'; then
  fail "companion preview did not retain one sole lease/peer topology"
fi
runtime_captured_at_utc="$(utc_now)"
{
  printf 'format=IdleScreenCameraGateC5RuntimeOwnershipV1\n'
  printf 'captured_at_utc=%s\n' "$runtime_captured_at_utc"
  printf 'helper_pid=%s\nhelper_path=%s\nhelper_cdhash=%s\n' \
    "$helper_pid" "$helper_executable" "$c3_helper_cdhash"
  printf 'companion_pid=%s\ncompanion_path=%s\ncompanion_cdhash=%s\n' \
    "$companion_pid" "$app_executable" "$c3_app_cdhash"
  printf 'screen_saver_pids=none\nother_helper_pids=none\n'
  printf 'static_avfoundation_owner_bundle_identifier=com.idlescreen.camera-agent\n'
  printf 'runtime_capture_owner_pid=%s\ncompanion_frame_consumer_pid=%s\n' "$helper_pid" "$companion_pid"
  printf 'active_peer_role=companion\nmaximum_active_lease_count=1\n'
  printf 'avfoundation_capture_owner_count=1\nsole_avfoundation_owner=true\n'
} >"$runtime_ownership"

echo "WITNESS: confirm the physical camera indicator is on by typing LED_ON."
IFS= read -r led_on_confirmation
[[ "$led_on_confirmation" == LED_ON ]] || fail "camera-on indicator was not witnessed"
assert_unlocked

stop_request_at_utc="$(utc_now)"
stop_first_line=$(( $(line_count) + 1 ))
echo "ACTION: click Stop Camera Preview once. When the camera indicator turns off, type LED_OFF immediately."
IFS= read -r led_off_confirmation
led_off_at_utc="$(utc_now)"
[[ "$led_off_confirmation" == LED_OFF ]] || fail "camera-off indicator was not witnessed"
assert_unlocked
wait_for_pattern "$stop_first_line" \
  "lease_count_changed previous=1 current=0 epoch=$producer_epoch" \
  20 "final preview lease teardown"
wait_for_pattern "$stop_first_line" \
  "capture_stopped generation=$capture_generation epoch=$producer_epoch" \
  20 "physical capture stop"
final_lease_zero_at_utc="$(event_timestamp "$stop_first_line" "lease_count_changed previous=1 current=0 epoch=$producer_epoch")" ||
  fail "could not bind final-lease timestamp"
capture_stopped_at_utc="$(event_timestamp "$stop_first_line" "capture_stopped generation=$capture_generation epoch=$producer_epoch")" ||
  fail "could not bind capture-stop timestamp"

completed_at_utc="$(utc_now)"
{
  printf 'format=IdleScreenCameraGateC5LEDObservationV1\n'
  printf 'observer=human-visible-camera-indicator\n'
  printf 'before_preview=off\nduring_preview=on\nafter_final_lease=off\n'
  printf 'after_final_lease_observed_at_utc=%s\n' "$led_off_at_utc"
} >"$led_observation"

{
  printf 'format=IdleScreenCameraGateC5CheckpointsV1\n'
  printf 'runner_started_at_utc=%s\n' "$runner_started_at_utc"
  printf 'identity_verified_at_utc=%s\n' "$identity_verified_at_utc"
  printf 'console_unlocked_at_utc=%s\n' "$console_unlocked_at_utc"
  printf 'app_launch_authorized_at_utc=%s\n' "$app_launch_authorized_at_utc"
  printf 'app_launched_at_utc=%s\n' "$app_launched_at_utc"
  printf 'permission_not_determined_at_utc=%s\n' "$permission_not_determined_at_utc"
  printf 'permission_action_authorized_at_utc=%s\n' "$permission_action_authorized_at_utc"
  printf 'permission_request_at_utc=%s\n' "$permission_request_at_utc"
  printf 'permission_authorized_at_utc=%s\n' "$permission_authorized_at_utc"
  printf 'permission_zero_lease_at_utc=%s\n' "$permission_zero_lease_at_utc"
  printf 'preview_action_authorized_at_utc=%s\n' "$preview_action_authorized_at_utc"
  printf 'hardware_use_authorized_at_utc=%s\n' "$hardware_use_authorized_at_utc"
  printf 'preview_request_at_utc=%s\n' "$preview_request_at_utc"
  printf 'preview_lease_at_utc=%s\n' "$preview_lease_at_utc"
  printf 'capture_started_at_utc=%s\n' "$capture_started_at_utc"
  printf 'first_consumed_at_utc=%s\n' "$first_consumed_at_utc"
  printf 'last_consumed_at_utc=%s\n' "$last_consumed_at_utc"
  printf 'stop_request_at_utc=%s\n' "$stop_request_at_utc"
  printf 'final_lease_zero_at_utc=%s\n' "$final_lease_zero_at_utc"
  printf 'capture_stopped_at_utc=%s\n' "$capture_stopped_at_utc"
  printf 'led_off_at_utc=%s\n' "$led_off_at_utc"
  printf 'completed_at_utc=%s\n' "$completed_at_utc"
} >"$checkpoints"

stop_log_stream || fail "unified-log stream did not stop cleanly"

{
  printf 'format=IdleScreenCameraGateC5EvidenceV1\n'
  printf 'evidence_semantics=unlocked-companion-physical-camera\ntrusted_for_production=true\n'
  printf 'attribution_verdict=resolved-fresh\nconsole_state=unlocked\n'
  printf 'app_launch_action=performed\napp_launch_authorization=yes\n'
  printf 'tcc_reset_action=%s\ntcc_reset_authorization=%s\n' "$tcc_reset_action" "$tcc_reset_authorization"
  printf 'tcc_request_action=performed\ntcc_request_authorization=yes\n'
  printf 'tcc_settings_action=%s\ntcc_settings_authorization=%s\n' "$tcc_settings_action" "$tcc_settings_authorization"
  printf 'camera_start_action=performed\ncamera_start_authorization=yes\n'
  printf 'camera_hardware_action=performed\ncamera_hardware_authorization=yes\n'
  printf 'c3_provenance_manifest=%s\nc3_provenance_manifest_sha256=%s\n' \
    "$c3_manifest" "$(sha256_file "$c3_manifest")"
  printf 'c4_restoration_manifest=%s\nc4_restoration_manifest_sha256=%s\n' \
    "$c4_restoration_manifest" "$(sha256_file "$c4_restoration_manifest")"
  printf 'c3_archive_tree_sha256=%s\n' "$c3_archive_hash"
  for record in \
    "identity_snapshot:$identity_snapshot" \
    "runtime_ownership:$runtime_ownership" \
    "attribution_observation:$attribution_observation" \
    "led_observation:$led_observation" \
    "checkpoints:$checkpoints" \
    "log_path:$log_path"; do
    key="${record%%:*}"; path="${record#*:}"
    printf '%s=%s\n%s_sha256=%s\n' "$key" "$path" "$key" "$(sha256_file "$path")"
  done
  printf 'helper_pid=%s\ncompanion_pid=%s\n' "$helper_pid" "$companion_pid"
  printf 'capture_generation=%s\nconsumption_generation=%s\nproducer_epoch=%s\n' \
    "$capture_generation" "$consumption_generation" "$producer_epoch"
  printf 'first_consumed_sequence=%s\nlast_consumed_sequence=%s\n' \
    "$first_consumed_sequence" "$last_consumed_sequence"
  printf 'consumed_receipt_count=%s\nfinal_active_lease_count=0\n' "$consumed_receipt_count"
} >"$evidence_manifest"

"$verifier" "$evidence_manifest"
/bin/chmod a-w "$evidence_root"/*.txt "$evidence_root"/*.log ||
  fail "could not make C5 evidence read-only"
cleanup_complete=true
trap - EXIT INT TERM HUP

echo "PASS: unlocked companion C5 physical evidence is complete and replayable."
echo "Evidence: $evidence_root"
