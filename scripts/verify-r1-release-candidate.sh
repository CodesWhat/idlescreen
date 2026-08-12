#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 --app /absolute/path/to/IdleScreen.app expected-certificate-sha256" >&2
  echo "       $0 /absolute/path/to/idlescreen.dmg /absolute/path/to/IdleScreenR1ReleaseCandidateV1.txt" >&2
  exit 64
}

script_root="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_root/.." && pwd)"
common="$script_root/r1-release-candidate-common.sh"
profile_policy="$script_root/camera-agent-profile-policy.sh"
[[ -f "$common" && -f "$profile_policy" ]] || {
  echo "FAIL: R1.2a verification support is incomplete." >&2
  exit 66
}
# shellcheck disable=SC1090,SC1091
source "$common"
# shellcheck disable=SC1090,SC1091
source "$profile_policy"

expected_team_identifier=3524374A2S
expected_app_group=group.com.idlescreen.shared
expected_dmg_identifier=com.idlescreen.app.dmg
fixture_mode="${IDLESCREEN_R1_FIXTURE_MODE:-NO}"
[[ "$fixture_mode" == YES || "$fixture_mode" == NO ]] || usage

override_names=(
  IDLESCREEN_R1_CODESIGN
  IDLESCREEN_R1_SECURITY
  IDLESCREEN_R1_C3_VERIFIER
  IDLESCREEN_R1_HDIUTIL
  IDLESCREEN_R1_STAPLER
  IDLESCREEN_R1_SPCTL
  IDLESCREEN_R1_PRODUCT_VERIFIER
  IDLESCREEN_R1_SIGNING_VERIFIER
)
override_present=false
for override_name in "${override_names[@]}"; do
  [[ -z "${!override_name+x}" ]] || override_present=true
done
if $override_present && [[ "$fixture_mode" != YES ]]; then
  echo "FAIL: R1.2a command overrides require explicit fixture mode." >&2
  exit 64
fi
if [[ "$fixture_mode" == YES ]]; then
  for override_name in "${override_names[@]}"; do
    [[ -n "${!override_name:-}" ]] || {
      echo "FAIL: fixture mode requires every external command override: $override_name" >&2
      exit 64
    }
  done
fi

codesign_command="${IDLESCREEN_R1_CODESIGN:-/usr/bin/codesign}"
security_command="${IDLESCREEN_R1_SECURITY:-/usr/bin/security}"
c3_verifier="${IDLESCREEN_R1_C3_VERIFIER:-$script_root/verify-release-archive-provenance.sh}"
hdiutil_command="${IDLESCREEN_R1_HDIUTIL:-/usr/bin/hdiutil}"
spctl_command="${IDLESCREEN_R1_SPCTL:-/usr/sbin/spctl}"
product_verifier="${IDLESCREEN_R1_PRODUCT_VERIFIER:-$script_root/test-camera-agent-product.sh}"
signing_verifier="${IDLESCREEN_R1_SIGNING_VERIFIER:-$script_root/verify-release-signing.sh}"
if [[ -n "${IDLESCREEN_R1_STAPLER:-}" ]]; then
  stapler_command=("$IDLESCREEN_R1_STAPLER")
else
  stapler_command=(/usr/bin/xcrun stapler)
fi

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for nested_c3_override in \
  IDLESCREEN_PROVENANCE_FIXTURE_MODE \
  IDLESCREEN_PROVENANCE_CODESIGN \
  IDLESCREEN_PROVENANCE_SECURITY; do
  [[ -z "${!nested_c3_override+x}" ]] ||
    fail "R1.2a forbids inherited nested C3 provenance command overrides"
done

for command_path in "$codesign_command" "$security_command" "$c3_verifier" "$hdiutil_command" "$spctl_command" "$product_verifier" "$signing_verifier"; do
  [[ -x "$command_path" ]] || fail "required verifier command is missing: $command_path"
done
[[ -x "${stapler_command[0]}" ]] || fail "required stapler command is missing: ${stapler_command[0]}"

scratch_root="$(mktemp -d /tmp/idlescreen-r1-release-verifier.XXXXXX)"
mounted_device=""
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$mounted_device" ]]; then
    "$hdiutil_command" detach "$mounted_device" >/dev/null 2>&1 || {
      echo "FAIL: could not detach verified release image device $mounted_device" >&2
      status=70
    }
  fi
  /bin/rm -rf "${scratch_root:?}"
  exit "$status"
}
trap cleanup EXIT

exact_metadata_field() {
  local metadata="$1"
  local product_name="$2"
  local field="$3"
  local count
  local value

  count="$(/usr/bin/awk -F= -v key="$field" '$1 == key { count += 1 } END { print count + 0 }' "$metadata")"
  [[ "$count" == 1 ]] || fail "$product_name signature metadata has no unique $field"
  value="$(/usr/bin/awk -F= -v key="$field" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$metadata")"
  [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\t'* ]] ||
    fail "$product_name signature metadata has malformed $field"
  /usr/bin/printf '%s\n' "$value"
}

validate_exact_entitlements() {
  local product_path="$1"
  local product_name="$2"
  local expected_entitlements="$3"
  local actual="$scratch_root/$product_name-entitlements.plist"
  local actual_json="$scratch_root/$product_name-entitlements.json"
  local expected_json="$scratch_root/$product_name-expected-entitlements.json"

  "$codesign_command" -d --entitlements :- "$product_path" >"$actual" 2>/dev/null ||
    fail "could not read $product_name signed entitlements"
  /usr/bin/plutil -lint "$actual" >/dev/null 2>&1 ||
    fail "$product_name signed entitlements are malformed"
  /usr/bin/plutil -convert json -o - "$actual" | /usr/bin/jq -S -c . >"$actual_json" ||
    fail "could not normalize $product_name signed entitlements"
  /usr/bin/plutil -convert json -o - "$expected_entitlements" | /usr/bin/jq -S -c . >"$expected_json" ||
    fail "could not normalize expected $product_name entitlements"
  /usr/bin/cmp -s "$actual_json" "$expected_json" ||
    fail "$product_name signed entitlements are not exact"
}

validate_distribution_profile() {
  local profile="$1"
  local product_name="$2"
  local bundle_identifier="$3"
  local signer_certificate="$4"
  local decoded="$scratch_root/$product_name-distribution-profile.plist"
  local current_epoch
  local get_task_allow

  [[ -f "$profile" && ! -L "$profile" ]] ||
    fail "$product_name is missing its Developer ID provisioning profile"
  "$security_command" cms -D -i "$profile" -o "$decoded" >/dev/null 2>&1 ||
    fail "could not decode $product_name Developer ID provisioning profile"
  /usr/bin/plutil -lint "$decoded" >/dev/null 2>&1 ||
    fail "$product_name Developer ID provisioning profile is malformed"
  [[ "$(/usr/bin/plutil -extract ProvisionsAllDevices raw "$decoded" 2>/dev/null || true)" == true ]] ||
    fail "$product_name profile is not a Developer ID distribution profile"
  if /usr/bin/plutil -extract ProvisionedDevices json -o - "$decoded" >/dev/null 2>&1; then
    fail "$product_name profile is device-scoped instead of Developer ID distribution"
  fi
  [[ "$(/usr/bin/plutil -extract TeamIdentifier.0 raw "$decoded" 2>/dev/null || true)" == "$expected_team_identifier" ]] ||
    fail "$product_name Developer ID profile TeamIdentifier drifted"
  if /usr/bin/plutil -extract TeamIdentifier.1 raw "$decoded" >/dev/null 2>&1; then
    fail "$product_name Developer ID profile contains multiple TeamIdentifiers"
  fi
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$decoded" 2>/dev/null || true)" == "$expected_team_identifier" ]] ||
    fail "$product_name Developer ID profile team entitlement drifted"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$decoded" 2>/dev/null || true)" == "$expected_team_identifier.$bundle_identifier" ]] ||
    fail "$product_name Developer ID profile application identifier drifted"
  get_task_allow="$(/usr/bin/plutil -extract Entitlements.get-task-allow raw "$decoded" 2>/dev/null || true)"
  [[ -z "$get_task_allow" || "$get_task_allow" == false ]] ||
    fail "$product_name Developer ID profile enables get-task-allow"
  camera_agent_profile_authorizes_app_group \
    "$decoded" "$expected_app_group" "$expected_team_identifier" ||
    fail "$product_name Developer ID profile does not exactly authorize $expected_app_group"
  current_epoch="$(/bin/date -u '+%s')"
  camera_agent_profile_is_current "$decoded" "$current_epoch" ||
    fail "$product_name Developer ID profile is invalid or expired"
  camera_agent_profile_authorizes_signer \
    "$decoded" "$signer_certificate" "$scratch_root/$product_name-profile-certificates" ||
    fail "$product_name Developer ID profile does not authorize the exact signer"
}

r1_validated_cdhash=""
r1_validated_certificate=""
validate_developer_id_product() {
  local product_path="$1"
  local product_name="$2"
  local expected_identifier="$3"
  local metadata="$scratch_root/$product_name-signature.txt"
  local identifier
  local team
  local timestamp_count
  local authority_count
  local signature_count
  local certificate_prefix="$scratch_root/$product_name-certificate-"

  "$codesign_command" --verify --strict "$product_path" >/dev/null 2>&1 ||
    fail "$product_name strict signature verification failed"
  "$codesign_command" -dv --verbose=4 "$product_path" >"$metadata" 2>&1 ||
    fail "could not read $product_name Developer ID signature"
  identifier="$(exact_metadata_field "$metadata" "$product_name" Identifier)"
  team="$(exact_metadata_field "$metadata" "$product_name" TeamIdentifier)"
  r1_validated_cdhash="$(exact_metadata_field "$metadata" "$product_name" CDHash | /usr/bin/tr '[:upper:]' '[:lower:]')"
  [[ "$identifier" == "$expected_identifier" ]] || fail "$product_name signing identifier drifted"
  [[ "$team" == "$expected_team_identifier" ]] || fail "$product_name TeamIdentifier drifted"
  [[ "$r1_validated_cdhash" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] ||
    fail "$product_name CDHash is malformed"
  /usr/bin/grep -Fq ' flags=0x10000(runtime) ' "$metadata" ||
    fail "$product_name signature is missing hardened runtime"
  signature_count="$(/usr/bin/awk '/^Signature size=[1-9][0-9]*$/ { count += 1 } END { print count + 0 }' "$metadata")"
  [[ "$signature_count" == 1 ]] || fail "$product_name signature is ad-hoc or malformed"
  authority_count="$(/usr/bin/awk -F= '$1 == "Authority" && $2 ~ /^Developer ID Application: / { count += 1 } END { print count + 0 }' "$metadata")"
  [[ "$authority_count" == 1 ]] || fail "$product_name is not signed by one Developer ID Application identity"
  if /usr/bin/grep -Eq '^Authority=Apple Development:|^Signature=adhoc$|flags=.*adhoc' "$metadata"; then
    fail "$product_name is not signed by one Developer ID Application identity"
  fi
  timestamp_count="$(/usr/bin/awk -F= '$1 == "Timestamp" && length($2) > 0 { count += 1 } END { print count + 0 }' "$metadata")"
  [[ "$timestamp_count" == 1 ]] || fail "$product_name signature is missing a secure timestamp"
  "$codesign_command" \
    "-R=identifier \"$expected_identifier\" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$expected_team_identifier\"" \
    --verify --strict "$product_path" >/dev/null 2>&1 ||
    fail "$product_name designated requirement is not exact Developer ID code"
  "$codesign_command" --display --extract-certificates="$certificate_prefix" \
    "$product_path" >/dev/null 2>&1 || fail "could not extract $product_name signing certificate"
  r1_validated_certificate="${certificate_prefix}0"
  [[ -s "$r1_validated_certificate" ]] || fail "$product_name has no Developer ID leaf certificate"
}

validate_developer_id_app() {
  local app_path="$1"
  local expected_certificate_sha256="$2"
  local extension_path="$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex"
  local helper_path="$app_path/Contents/Helpers/IdleScreenCameraAgent.app"
  local renderer_path="$app_path/Contents/Frameworks/IdleScreenRenderer.framework"
  local control_tool="$app_path/Contents/Helpers/idlescreenctl"
  local reference_certificate=""
  local certificate_sha
  local app_cdhash
  local extension_cdhash
  local helper_cdhash
  local renderer_cdhash
  local control_tool_cdhash

  [[ -d "$app_path" && ! -L "$app_path" ]] || fail "Developer ID app is missing or is a symbolic link"
  "$product_verifier" "$app_path" Release >/dev/null || fail "Release product contracts failed"
  "$signing_verifier" "$app_path" "$expected_team_identifier" >/dev/null ||
    fail "Release provisioning contracts failed"

  validate_developer_id_product "$renderer_path" renderer com.idlescreen.renderer
  renderer_cdhash="$r1_validated_cdhash"
  reference_certificate="$r1_validated_certificate"
  validate_developer_id_product "$extension_path" extension com.idlescreen.app.screensaver
  extension_cdhash="$r1_validated_cdhash"
  /usr/bin/cmp -s "$reference_certificate" "$r1_validated_certificate" ||
    fail "nested products do not share one exact Developer ID signing certificate"
  validate_developer_id_product "$helper_path" helper com.idlescreen.camera-agent
  helper_cdhash="$r1_validated_cdhash"
  /usr/bin/cmp -s "$reference_certificate" "$r1_validated_certificate" ||
    fail "nested products do not share one exact Developer ID signing certificate"
  validate_developer_id_product "$control_tool" control-tool com.idlescreen.ctl
  control_tool_cdhash="$r1_validated_cdhash"
  /usr/bin/cmp -s "$reference_certificate" "$r1_validated_certificate" ||
    fail "nested products do not share one exact Developer ID signing certificate"
  validate_developer_id_product "$app_path" app com.idlescreen.app
  app_cdhash="$r1_validated_cdhash"
  /usr/bin/cmp -s "$reference_certificate" "$r1_validated_certificate" ||
    fail "nested products do not share one exact Developer ID signing certificate"
  "$codesign_command" --verify --deep --strict "$app_path" >/dev/null 2>&1 ||
    fail "deep Developer ID app verification failed"

  certificate_sha="$(r1_sha256_file "$reference_certificate")"
  [[ "$certificate_sha" == "$expected_certificate_sha256" ]] ||
    fail "Developer ID certificate does not match the recorded candidate signer"

  validate_exact_entitlements "$app_path" app \
    "$project_root/IdleScreenApp/IdleScreenDeveloperID.entitlements"
  validate_exact_entitlements "$extension_path" extension \
    "$project_root/IdleScreenScreenSaver/IdleScreenScreenSaverDeveloperID.entitlements"
  validate_exact_entitlements "$helper_path" helper \
    "$project_root/IdleScreenCameraAgent/IdleScreenCameraAgentDeveloperID.entitlements"
  validate_exact_entitlements "$control_tool" control-tool \
    "$project_root/IdleScreenAgentExecutable/idlescreenctl-DeveloperID.entitlements"

  validate_distribution_profile \
    "$app_path/Contents/embedded.provisionprofile" app com.idlescreen.app "$reference_certificate"
  validate_distribution_profile \
    "$extension_path/Contents/embedded.provisionprofile" extension \
    com.idlescreen.app.screensaver "$reference_certificate"
  validate_distribution_profile \
    "$helper_path/Contents/embedded.provisionprofile" helper \
    com.idlescreen.camera-agent "$reference_certificate"

  /usr/bin/printf 'app_cdhash=%s\n' "$app_cdhash"
  /usr/bin/printf 'extension_cdhash=%s\n' "$extension_cdhash"
  /usr/bin/printf 'helper_cdhash=%s\n' "$helper_cdhash"
  /usr/bin/printf 'renderer_cdhash=%s\n' "$renderer_cdhash"
  /usr/bin/printf 'control_tool_cdhash=%s\n' "$control_tool_cdhash"
}

validate_dmg_signature() {
  local dmg_path="$1"
  local expected_certificate_sha256="$2"
  local metadata="$scratch_root/dmg-signature.txt"
  local certificate_prefix="$scratch_root/dmg-certificate-"
  local certificate_sha
  local authority_count
  local timestamp_count

  "$codesign_command" --verify --strict "$dmg_path" >/dev/null 2>&1 ||
    fail "signed DMG verification failed"
  "$codesign_command" -dv --verbose=4 "$dmg_path" >"$metadata" 2>&1 ||
    fail "could not read signed DMG metadata"
  [[ "$(exact_metadata_field "$metadata" dmg Identifier)" == "$expected_dmg_identifier" ]] ||
    fail "DMG signing identifier drifted"
  [[ "$(exact_metadata_field "$metadata" dmg TeamIdentifier)" == "$expected_team_identifier" ]] ||
    fail "DMG TeamIdentifier drifted"
  authority_count="$(/usr/bin/awk -F= '$1 == "Authority" && $2 ~ /^Developer ID Application: / { count += 1 } END { print count + 0 }' "$metadata")"
  [[ "$authority_count" == 1 ]] || fail "DMG is not signed by one Developer ID Application identity"
  timestamp_count="$(/usr/bin/awk -F= '$1 == "Timestamp" && length($2) > 0 { count += 1 } END { print count + 0 }' "$metadata")"
  [[ "$timestamp_count" == 1 ]] || fail "DMG signature is missing a secure timestamp"
  "$codesign_command" --display --extract-certificates="$certificate_prefix" \
    "$dmg_path" >/dev/null 2>&1 || fail "could not extract the DMG signing certificate"
  [[ -s "${certificate_prefix}0" ]] || fail "DMG has no Developer ID leaf certificate"
  certificate_sha="$(r1_sha256_file "${certificate_prefix}0")"
  [[ "$certificate_sha" == "$expected_certificate_sha256" ]] ||
    fail "DMG signer does not match the app signer"
}

if [[ "${1:-}" == --app ]]; then
  [[ $# -eq 3 && "$2" = /* && "$3" =~ ^[0-9a-fA-F]{64}$ ]] || usage
  validate_developer_id_app "$2" "$(/usr/bin/printf '%s' "$3" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  trap - EXIT
  /bin/rm -rf "${scratch_root:?}"
  exit 0
fi

[[ $# -eq 2 ]] || usage
dmg_path="$1"
manifest="$2"
[[ "$dmg_path" = /* && "$manifest" = /* ]] || usage
[[ -f "$dmg_path" && ! -L "$dmg_path" ]] || fail "release DMG is missing or is a symbolic link"
[[ -f "$manifest" && ! -L "$manifest" ]] || fail "release candidate manifest is missing or is a symbolic link"

schema="$(r1_manifest_value "$manifest" schema)" || fail "candidate manifest has no unique schema"
verification_mode="$(r1_manifest_value "$manifest" verification_mode)" ||
  fail "candidate manifest has no unique verification_mode"
[[ "$schema" == IdleScreenR1ReleaseCandidate/v1 ]] || fail "unexpected release candidate schema"
if [[ "$fixture_mode" == YES ]]; then
  [[ "$verification_mode" == fixture ]] || fail "fixture verification requires verification_mode=fixture"
else
  [[ "$verification_mode" == release ]] ||
    fail "trusted verification requires verification_mode=release"
fi

source_commit="$(r1_manifest_value "$manifest" source_commit)" || fail "candidate source commit is missing"
source_tree="$(r1_manifest_value "$manifest" source_tree)" || fail "candidate source tree is missing"
source_clean="$(r1_manifest_value "$manifest" source_clean)" || fail "candidate source cleanliness is missing"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ && "$source_tree" =~ ^[0-9a-f]{40}$ && "$source_clean" == true ]] ||
  fail "candidate source identity is malformed or dirty"
project_yml_sha="$(r1_manifest_value "$manifest" project_yml_sha256)" ||
  fail "candidate project.yml identity is missing"
project_pbxproj_sha="$(r1_manifest_value "$manifest" project_pbxproj_sha256)" ||
  fail "candidate project.pbxproj identity is missing"
c3_archive_tree_sha="$(r1_manifest_value "$manifest" c3_archive_tree_sha256)" ||
  fail "candidate C3 archive identity is missing"
build_environment_sha="$(r1_manifest_value "$manifest" build_environment_sha256)" ||
  fail "candidate build environment identity is missing"
submitted_dmg_sha="$(r1_manifest_value "$manifest" submitted_dmg_sha256)" ||
  fail "candidate submitted DMG identity is missing"
for recorded_sha in \
  "$project_yml_sha" "$project_pbxproj_sha" "$c3_archive_tree_sha" \
  "$build_environment_sha" "$submitted_dmg_sha"; do
  [[ "$recorded_sha" =~ ^[0-9a-f]{64}$ ]] || fail "candidate manifest contains a malformed SHA-256"
done
bundle_short_version="$(r1_manifest_value "$manifest" bundle_short_version)" ||
  fail "candidate short version is missing"
bundle_version="$(r1_manifest_value "$manifest" bundle_version)" ||
  fail "candidate build version is missing"
[[ "$bundle_short_version" =~ ^[0-9A-Za-z._-]{1,64}$ && "$bundle_version" =~ ^[0-9]+$ ]] ||
  fail "candidate versions are malformed"
((10#$bundle_version > 60)) || fail "candidate build version collides with baseline build 60"
[[ "$(r1_manifest_value "$manifest" team_identifier)" == "$expected_team_identifier" ]] ||
  fail "candidate TeamIdentifier drifted"
[[ "$(r1_manifest_value "$manifest" dmg_signing_identifier)" == "$expected_dmg_identifier" ]] ||
  fail "candidate DMG signing identifier drifted"
[[ "$(r1_manifest_value "$manifest" notary_status)" == Accepted ]] ||
  fail "candidate notarization was not accepted"
[[ "$(r1_manifest_value "$manifest" notary_issue_count)" == 0 ]] ||
  fail "candidate notarization log contains issues"
notary_submission_id="$(r1_manifest_value "$manifest" notary_submission_id)" ||
  fail "candidate notarization submission ID is missing"
[[ "$notary_submission_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] ||
  fail "candidate notarization submission ID is malformed"
[[ "$(r1_manifest_value "$manifest" stapler_status)" == valid ]] ||
  fail "candidate manifest does not record a valid stapled ticket"
[[ "$(r1_manifest_value "$manifest" dmg_gatekeeper_status)" == accepted ]] ||
  fail "candidate manifest does not record DMG Gatekeeper acceptance"
[[ "$(r1_manifest_value "$manifest" mounted_app_gatekeeper_status)" == accepted ]] ||
  fail "candidate manifest does not record mounted-app Gatekeeper acceptance"

expected_app_tree_sha="$(r1_manifest_value "$manifest" distribution_app_tree_sha256)" ||
  fail "candidate app tree hash is missing"
expected_certificate_sha="$(r1_manifest_value "$manifest" developer_id_certificate_sha256)" ||
  fail "candidate signer hash is missing"
expected_dmg_sha="$(r1_manifest_value "$manifest" stapled_dmg_sha256)" ||
  fail "candidate stapled DMG hash is missing"
for expected_hash in "$expected_app_tree_sha" "$expected_certificate_sha" "$expected_dmg_sha"; do
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || fail "candidate manifest contains a malformed SHA-256"
done
[[ "$(r1_sha256_file "$dmg_path")" == "$expected_dmg_sha" ]] ||
  fail "stapled DMG differs from the recorded candidate"

manifest_root="$(/bin/realpath "$(dirname "$manifest")")" || fail "could not resolve candidate manifest root"
dmg_relative="$(r1_manifest_value "$manifest" dmg_relative_path)" ||
  fail "candidate DMG path is missing"
[[ "$dmg_relative" == "Distribution/idlescreen-$bundle_short_version-build$bundle_version.dmg" ]] ||
  fail "candidate DMG path is not canonical"
[[ "$(/bin/realpath "$dmg_path")" == "$manifest_root/$dmg_relative" ]] ||
  fail "verified DMG does not match the candidate manifest path"
notary_log_relative="$(r1_manifest_value "$manifest" notary_log_relative_path)" ||
  fail "candidate notary log path is missing"
c3_manifest_relative="$(r1_manifest_value "$manifest" c3_manifest_relative_path)" ||
  fail "candidate C3 manifest path is missing"
case "$notary_log_relative" in Evidence/notary-log.json) ;;
  *) fail "candidate notary log path is not canonical" ;;
esac
case "$c3_manifest_relative" in C3/IdleScreenC3ReleaseProvenanceV1.txt) ;;
  *) fail "candidate C3 manifest path is not canonical" ;;
esac
notary_log="$manifest_root/$notary_log_relative"
c3_manifest="$manifest_root/$c3_manifest_relative"
c3_archive="$manifest_root/C3/IdleScreenC3Release.xcarchive"
build_environment="$manifest_root/Evidence/build-environment.txt"
[[ -f "$notary_log" && ! -L "$notary_log" && -f "$c3_manifest" && ! -L "$c3_manifest" &&
   -d "$c3_archive" && ! -L "$c3_archive" && -f "$build_environment" && ! -L "$build_environment" ]] ||
  fail "candidate evidence files are missing"
[[ "$(r1_sha256_file "$notary_log")" == "$(r1_manifest_value "$manifest" notary_log_sha256)" ]] ||
  fail "candidate notary log hash drifted"
[[ "$(r1_sha256_file "$c3_manifest")" == "$(r1_manifest_value "$manifest" c3_manifest_sha256)" ]] ||
  fail "candidate C3 provenance hash drifted"
[[ "$(r1_sha256_file "$build_environment")" == "$build_environment_sha" ]] ||
  fail "candidate build environment hash drifted"
[[ "$(r1_manifest_value "$c3_manifest" verification_mode)" == release ]] ||
  fail "candidate C3 provenance is not release evidence"
[[ "$(r1_manifest_value "$c3_manifest" archive_tree_sha256)" == "$c3_archive_tree_sha" ]] ||
  fail "candidate C3 archive identity drifted"
c3_replay_manifest="$scratch_root/c3-replayed-provenance.txt"
/usr/bin/env \
  -u IDLESCREEN_PROVENANCE_FIXTURE_MODE \
  -u IDLESCREEN_PROVENANCE_CODESIGN \
  -u IDLESCREEN_PROVENANCE_SECURITY \
  "$c3_verifier" "$c3_archive" "$c3_replay_manifest" "$expected_team_identifier" >/dev/null ||
  fail "candidate C3 archive failed provenance replay"
/usr/bin/cmp -s "$c3_manifest" "$c3_replay_manifest" ||
  fail "candidate C3 provenance does not exactly replay from its archive"

/usr/bin/jq -e . "$notary_log" >/dev/null 2>&1 || fail "candidate notary log is malformed"
log_submission_id="$(/usr/bin/jq -r '.jobId // empty' "$notary_log")"
log_status="$(/usr/bin/jq -r '.status // empty' "$notary_log")"
log_issue_count="$(/usr/bin/jq -r 'if .issues == null then 0 elif (.issues | type) == "array" then (.issues | length) else -1 end' "$notary_log")"
log_submitted_dmg_sha="$(/usr/bin/jq -r '.sha256 // empty' "$notary_log" | /usr/bin/tr '[:upper:]' '[:lower:]')"
normalized_log_submission_id="$(/usr/bin/printf '%s' "$log_submission_id" | /usr/bin/tr '[:upper:]' '[:lower:]')"
normalized_notary_submission_id="$(/usr/bin/printf '%s' "$notary_submission_id" | /usr/bin/tr '[:upper:]' '[:lower:]')"
[[ "$normalized_log_submission_id" == "$normalized_notary_submission_id" &&
   "$log_status" == Accepted && "$log_issue_count" == 0 ]] ||
  fail "candidate notary log does not match the recorded submission"
[[ "$log_submitted_dmg_sha" == "$submitted_dmg_sha" ]] ||
  fail "candidate notary log does not bind the submitted DMG SHA-256"

"$hdiutil_command" verify "$dmg_path" >/dev/null 2>&1 || fail "DMG integrity verification failed"
validate_dmg_signature "$dmg_path" "$expected_certificate_sha"
"${stapler_command[@]}" validate "$dmg_path" >/dev/null 2>&1 ||
  fail "stapled notarization ticket is not valid"
"$spctl_command" -a -t open --context context:primary-signature -v "$dmg_path" >/dev/null 2>&1 ||
  fail "Gatekeeper rejected the stapled DMG"

attach_plist="$scratch_root/attach.plist"
"$hdiutil_command" attach -readonly -nobrowse -plist "$dmg_path" >"$attach_plist" ||
  fail "could not mount the release DMG read-only"
mount_point="$(/usr/bin/plutil -extract system-entities json -o - "$attach_plist" |
  /usr/bin/jq -r '[.[] | select(has("mount-point"))] | if length == 1 then .[0]["mount-point"] else empty end')"
mounted_device="$(/usr/bin/plutil -extract system-entities json -o - "$attach_plist" |
  /usr/bin/jq -r '[.[] | select(has("mount-point"))] | if length == 1 then .[0]["dev-entry"] else empty end')"
[[ "$mount_point" = /* && -d "$mount_point" && ! -L "$mount_point" ]] ||
  fail "release DMG did not expose one canonical mount point"
[[ "$mounted_device" =~ ^/dev/disk[0-9]+(s[0-9]+)?$ ]] ||
  fail "release DMG did not expose one canonical device"

mounted_app="$mount_point/IdleScreen.app"
applications_link="$mount_point/Applications"
root_entry_count="$(/usr/bin/find "$mount_point" -mindepth 1 -maxdepth 1 -print | /usr/bin/awk 'END { print NR + 0 }')"
[[ "$root_entry_count" == 2 && -d "$mounted_app" && ! -L "$mounted_app" &&
   -L "$applications_link" && "$(/usr/bin/readlink "$applications_link")" == /Applications ]] ||
  fail "release DMG must contain exactly IdleScreen.app and the Applications link"
mounted_app_tree_sha="$(r1_tree_sha256 "$mounted_app" "$scratch_root/mounted-app-inventory.tsv")" ||
  fail "could not hash the mounted release app"
[[ "$mounted_app_tree_sha" == "$expected_app_tree_sha" ]] ||
  fail "mounted app tree differs from the signed distribution candidate"
mounted_info="$mounted_app/Contents/Info.plist"
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$mounted_info" 2>/dev/null || true)" == "$bundle_short_version" &&
   "$(/usr/bin/plutil -extract CFBundleVersion raw "$mounted_info" 2>/dev/null || true)" == "$bundle_version" ]] ||
  fail "mounted app versions differ from the candidate manifest"
embedded_provenance="$mounted_app/Contents/Resources/IdleScreenReleaseProvenance.plist"
[[ -f "$embedded_provenance" && ! -L "$embedded_provenance" ]] ||
  fail "mounted app lacks signed release provenance"
/usr/bin/plutil -lint "$embedded_provenance" >/dev/null 2>&1 ||
  fail "mounted app release provenance is malformed"
for embedded_record in \
  "Schema:IdleScreenEmbeddedReleaseProvenance/v1" \
  "SourceCommit:$source_commit" \
  "SourceTree:$source_tree" \
  "ProjectYMLSHA256:$project_yml_sha" \
  "ProjectPBXProjSHA256:$project_pbxproj_sha" \
  "C3ManifestSHA256:$(r1_manifest_value "$manifest" c3_manifest_sha256)" \
  "C3ArchiveTreeSHA256:$c3_archive_tree_sha" \
  "BuildEnvironmentSHA256:$build_environment_sha" \
  "BundleShortVersion:$bundle_short_version" \
  "BundleVersion:$bundle_version"; do
  embedded_key="${embedded_record%%:*}"
  embedded_expected="${embedded_record#*:}"
  [[ "$(/usr/bin/plutil -extract "$embedded_key" raw "$embedded_provenance" 2>/dev/null || true)" == "$embedded_expected" ]] ||
    fail "signed release provenance drifted at $embedded_key"
done
validate_developer_id_app "$mounted_app" "$expected_certificate_sha" >"$scratch_root/mounted-product.txt"
for cdhash_key in app extension helper renderer control_tool; do
  expected_cdhash="$(r1_manifest_value "$manifest" "${cdhash_key}_cdhash")" ||
    fail "candidate manifest is missing ${cdhash_key}_cdhash"
  [[ "$expected_cdhash" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] ||
    fail "candidate manifest contains a malformed ${cdhash_key}_cdhash"
  [[ "$(r1_manifest_value "$scratch_root/mounted-product.txt" "${cdhash_key}_cdhash")" == "$expected_cdhash" ]] ||
    fail "mounted product ${cdhash_key}_cdhash differs from the candidate manifest"
done
"$spctl_command" -a -t exec -vv "$mounted_app" >/dev/null 2>&1 ||
  fail "Gatekeeper rejected the mounted Developer ID app"

"$hdiutil_command" detach "$mounted_device" >/dev/null 2>&1 ||
  fail "could not detach verified release image device $mounted_device"
mounted_device=""
trap - EXIT
/bin/rm -rf "${scratch_root:?}"
echo "PASS: stapled Developer ID DMG, exact mounted app bytes, and Gatekeeper assessments are valid."
