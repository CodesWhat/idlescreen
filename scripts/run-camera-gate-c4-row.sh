#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /Applications/idlescreen.app /absolute/transaction-evidence /absolute/new-a1-evidence MODE" >&2
  exit 64
}

[[ $# -eq 4 ]] || usage
app_path="$1"
transaction_evidence="$2"
a1_evidence="$3"
mode="$4"
[[ "$app_path" == /Applications/idlescreen.app && "$transaction_evidence" = /* &&
   "$a1_evidence" = /* && ( "$mode" == a1t || "$mode" == a1tr ) ]] || usage
[[ "${IDLESCREEN_C4_AUTHORIZE_HOST_ACTIVATION:-}" == YES ]] || {
  echo "REFUSED: C4 host activation requires IDLESCREEN_C4_AUTHORIZE_HOST_ACTIVATION=YES." >&2
  exit 65
}
if [[ "$mode" == a1tr &&
      "${IDLESCREEN_C4_AUTHORIZE_A1TR_EXACT_HELPER_TERMINATION:-}" != YES ]]; then
  echo "REFUSED: C4 A1TR requires IDLESCREEN_C4_AUTHORIZE_A1TR_EXACT_HELPER_TERMINATION=YES." >&2
  exit 65
fi
[[ ! -e "$a1_evidence" && ! -L "$a1_evidence" ]] || usage

project_root="$(cd "$(dirname "$0")/.." && pwd)"
a1_runner="$project_root/scripts/run-camera-gate-a1.sh"
journal=/Applications/.idlescreen.app.synthetic-transaction/journal
transition_events="$transaction_evidence/transition-events.raw"
helper_bundle="$app_path/Contents/Helpers/IdleScreenCameraAgent.app"
extension_bundle="$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex"

fail() {
  echo "FAIL: $*" >&2
  echo "Evidence: $transaction_evidence" >&2
  exit 1
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print tolower($1) }'
}

manifest_value() {
  local source="$1" key="$2"
  /usr/bin/awk -F= -v key="$key" \
    '$1 == key { print substr($0, length($1) + 2); count++ } END { exit(count == 1 ? 0 : 1) }' \
    "$source" || fail "$source does not contain exactly one $key"
}

plist_value() {
  # Entitlement names contain literal dots. `plutil -extract` treats those as
  # key-path separators, while PlistBuddy's colon path preserves the key.
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

entitlement_absent() {
  ! /usr/libexec/PlistBuddy -c "Print :$2" "$1" >/dev/null 2>&1
}

write_runtime_entitlements() {
  local component="$1" pid="$2" procinfo="$3" bundle="$4" output="$5"
  local entitlements="$transaction_evidence/$component-static-entitlements.plist"
  local cdhash team application app_group disable mach_lookup path
  /usr/bin/codesign -d --entitlements :- "$bundle" >"$entitlements" 2>/dev/null ||
    fail "could not extract $component static entitlements"
  /usr/bin/plutil -lint "$entitlements" >/dev/null || fail "$component entitlements are malformed"
  /usr/bin/grep -Fq 'entitlements validated' "$procinfo" ||
    fail "$component procinfo lacks validated runtime entitlements"
  cdhash="$(/usr/bin/codesign -dv --verbose=4 "$bundle" 2>&1 |
    /usr/bin/awk -F= '$1 == "CDHash" { print $2; count++ } END { exit(count == 1 ? 0 : 1) }')" ||
    fail "$component has no unique CDHash"
  team="$(plist_value "$entitlements" com.apple.developer.team-identifier)" || fail "$component lacks team entitlement"
  application="$(plist_value "$entitlements" com.apple.application-identifier)" || fail "$component lacks application entitlement"
  app_group="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$entitlements" 2>/dev/null)" ||
    fail "$component lacks exact App Group"
  ! /usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:1' "$entitlements" >/dev/null 2>&1 ||
    fail "$component has unexpected extra App Groups"
  [[ "$team" == 3524374A2S && "$app_group" == group.com.idlescreen.shared &&
     "$(plist_value "$entitlements" com.apple.security.app-sandbox)" == true ]] ||
    fail "$component runtime trust entitlements are not exact"
  entitlement_absent "$entitlements" com.apple.security.device.camera || fail "$component unexpectedly has camera entitlement"
  entitlement_absent "$entitlements" com.apple.security.get-task-allow ||
    [[ "$(plist_value "$entitlements" com.apple.security.get-task-allow)" == false ]] ||
    fail "$component unexpectedly has get-task-allow"
  if ! /usr/bin/grep -Fq "$application" "$procinfo" ||
     ! /usr/bin/grep -Fq "$app_group" "$procinfo"; then
    fail "$component procinfo is not bound to its signed application/App Group identity"
  fi
  if [[ "$component" == helper ]]; then
    [[ "$application" == 3524374A2S.com.idlescreen.camera-agent ]] || fail "helper application identifier drifted"
    entitlement_absent "$entitlements" com.apple.security.cs.disable-library-validation ||
      [[ "$(plist_value "$entitlements" com.apple.security.cs.disable-library-validation)" == false ]] ||
      fail "helper disables library validation"
    entitlement_absent "$entitlements" com.apple.security.temporary-exception.mach-lookup.global-name ||
      fail "helper unexpectedly carries Mach lookup exceptions"
    disable=false; mach_lookup=none
    path="$app_path/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
  else
    [[ "$application" == 3524374A2S.com.idlescreen.app.screensaver ]] || fail "extension application identifier drifted"
    [[ "$(plist_value "$entitlements" com.apple.security.cs.disable-library-validation)" == true ]] ||
      fail "extension lacks required library-validation exception"
    mach_lookup="$({
      /usr/libexec/PlistBuddy -c 'Print :com.apple.security.temporary-exception.mach-lookup.global-name:0' "$entitlements"
      /usr/libexec/PlistBuddy -c 'Print :com.apple.security.temporary-exception.mach-lookup.global-name:1' "$entitlements"
      /usr/libexec/PlistBuddy -c 'Print :com.apple.security.temporary-exception.mach-lookup.global-name:2' "$entitlements"
    } 2>/dev/null | /usr/bin/paste -sd ',' -)" || fail "could not read extension Mach lookup exceptions"
    ! /usr/libexec/PlistBuddy -c 'Print :com.apple.security.temporary-exception.mach-lookup.global-name:3' "$entitlements" >/dev/null 2>&1 ||
      fail "extension has unexpected extra Mach lookup exceptions"
    [[ "$mach_lookup" == 'com.apple.CARenderServer,com.apple.CoreDisplay.master,com.apple.ViewBridgeAuxiliary' ]] ||
      fail "extension Mach lookup exceptions drifted"
    disable=true
    path="$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver"
  fi
  {
    printf 'format=IdleScreenCameraGateC4RuntimeEntitlementsV1\n'
    printf 'captured_at_utc=%s\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%S.000000Z')"
    printf 'source=launchctl-procinfo\n'
    printf 'entitlements_validated=true\n'
    printf 'pid=%s\n' "$pid"
    printf 'path=%s\n' "$path"
    printf 'cdhash=%s\n' "$cdhash"
    printf 'team_identifier=%s\n' "$team"
    printf 'application_identifier=%s\n' "$application"
    printf 'app_group=%s\n' "$app_group"
    printf 'app_sandbox=true\n'
    printf 'camera=false\n'
    printf 'get_task_allow=false\n'
    printf 'disable_library_validation=%s\n' "$disable"
    printf 'mach_lookup=%s\n' "$mach_lookup"
  } >"$output"
}

[[ -x "$a1_runner" && -f "$journal" && ! -L "$journal" ]] || fail "C4 row prerequisites are missing"
[[ "$(manifest_value "$journal" phase)" == runner_active ]] || fail "transaction is not in runner_active"
/usr/bin/ditto "$journal" "$transaction_evidence/journal-runner-active.txt" || fail "could not retain runner-active journal"
printf 'runner_started@%s\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%S.000000Z')" >>"$transition_events"

runner_args=("$app_path" "$a1_evidence" "$mode" --normal-host-activation-authorized)
[[ "$mode" != a1tr ]] || runner_args+=(--terminate-exact-synthetic-helper-once)
IDLESCREEN_ALLOW_PHYSICAL_TESTS=YES IDLESCREEN_ALLOW_CAMERA_GATE_A1T=YES \
  "$a1_runner" "${runner_args[@]}"

a1_manifest="$a1_evidence/evidence-manifest.txt"
[[ -f "$a1_manifest" && ! -L "$a1_manifest" ]] || fail "A1 runner did not emit its evidence manifest"
for role in initial_helper saver; do
  pid="$(manifest_value "$a1_manifest" "${role}_pid")"
  procinfo="$(manifest_value "$a1_manifest" "${role}_procinfo")"
  procinfo_sha="$(manifest_value "$a1_manifest" "${role}_procinfo_sha256")"
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$procinfo" == "$a1_evidence/"* &&
     -f "$procinfo" && ! -L "$procinfo" && "$(sha256_file "$procinfo")" == "$procinfo_sha" ]] ||
    fail "$role procinfo is not hash-bound A1 evidence"
  if [[ "$role" == initial_helper ]]; then
    write_runtime_entitlements helper "$pid" "$procinfo" "$helper_bundle" \
      "$transaction_evidence/initial-helper-runtime-entitlements.txt"
  else
    write_runtime_entitlements saver "$pid" "$procinfo" "$extension_bundle" \
      "$transaction_evidence/saver-runtime-entitlements.txt"
  fi
done
if [[ "$mode" == a1tr ]]; then
  pid="$(manifest_value "$a1_manifest" recovered_helper_pid)"
  procinfo="$(manifest_value "$a1_manifest" recovered_helper_procinfo)"
  procinfo_sha="$(manifest_value "$a1_manifest" recovered_helper_procinfo_sha256)"
  [[ "$pid" =~ ^[1-9][0-9]*$ && "$procinfo" == "$a1_evidence/"* &&
     -f "$procinfo" && ! -L "$procinfo" && "$(sha256_file "$procinfo")" == "$procinfo_sha" ]] ||
    fail "recovered helper procinfo is not hash-bound A1TR evidence"
  write_runtime_entitlements helper "$pid" "$procinfo" "$helper_bundle" \
    "$transaction_evidence/recovered-helper-runtime-entitlements.txt"
fi
printf 'runner_completed@%s\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%S.000000Z')" >>"$transition_events"

echo "PASS: C4 $mode row retained hash-bound runtime entitlement evidence."
