#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/new-release-candidate-directory" >&2
  exit 64
}

[[ $# -eq 1 ]] || usage

script_root="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_root/.." && pwd)"
common="$script_root/r1-release-candidate-common.sh"
profile_policy="$script_root/camera-agent-profile-policy.sh"
verifier="$script_root/verify-r1-release-candidate.sh"
[[ -f "$common" && -f "$profile_policy" && -x "$verifier" ]] || {
  echo "FAIL: R1.2a release support is incomplete." >&2
  exit 66
}
# shellcheck disable=SC1090,SC1091
source "$common"
# shellcheck disable=SC1090,SC1091
source "$profile_policy"

requested_output="$1"
[[ "$requested_output" = /* ]] || usage
output_parent="$(/usr/bin/dirname "$requested_output")"
output_leaf="$(/usr/bin/basename "$requested_output")"
[[ -n "$output_leaf" && "$output_leaf" != . && "$output_leaf" != .. ]] || usage
[[ -d "$output_parent" && ! -L "$output_parent" ]] || {
  echo "FAIL: release candidate parent must be an existing non-symlink directory." >&2
  exit 66
}
output_parent="$(/bin/realpath "$output_parent")"
output_root="$output_parent/$output_leaf"
[[ ! -e "$output_root" && ! -L "$output_root" ]] || {
  echo "FAIL: refusing to replace existing release candidate output: $output_root" >&2
  exit 73
}
case "$output_root" in
  "$project_root"|"$project_root"/*)
    echo "FAIL: release candidate output must remain outside the source repository." >&2
    exit 64
    ;;
esac

fixture_mode="${IDLESCREEN_R1_FIXTURE_MODE:-NO}"
[[ "$fixture_mode" == YES || "$fixture_mode" == NO ]] || usage
[[ "${IDLESCREEN_ALLOW_REAL_DISTRIBUTION:-NO}" == YES ]] || {
  echo "BLOCKED: set IDLESCREEN_ALLOW_REAL_DISTRIBUTION=YES only for an intentional Developer ID submission." >&2
  exit 69
}

override_names=(
  IDLESCREEN_R1_GIT
  IDLESCREEN_R1_SECURITY
  IDLESCREEN_R1_C3_BUILDER
  IDLESCREEN_R1_C3_VERIFIER
  IDLESCREEN_R1_CODESIGN
  IDLESCREEN_R1_PRODUCT_VERIFIER
  IDLESCREEN_R1_SIGNING_VERIFIER
  IDLESCREEN_R1_HDIUTIL
  IDLESCREEN_R1_NOTARYTOOL
  IDLESCREEN_R1_STAPLER
  IDLESCREEN_R1_SPCTL
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

git_command="${IDLESCREEN_R1_GIT:-/usr/bin/git}"
security_command="${IDLESCREEN_R1_SECURITY:-/usr/bin/security}"
c3_builder="${IDLESCREEN_R1_C3_BUILDER:-$script_root/build-camera-gate-c3-release.sh}"
c3_verifier="${IDLESCREEN_R1_C3_VERIFIER:-$script_root/verify-release-archive-provenance.sh}"
codesign_command="${IDLESCREEN_R1_CODESIGN:-/usr/bin/codesign}"
product_verifier="${IDLESCREEN_R1_PRODUCT_VERIFIER:-$script_root/test-camera-agent-product.sh}"
signing_verifier="${IDLESCREEN_R1_SIGNING_VERIFIER:-$script_root/verify-release-signing.sh}"
hdiutil_command="${IDLESCREEN_R1_HDIUTIL:-/usr/bin/hdiutil}"
spctl_command="${IDLESCREEN_R1_SPCTL:-/usr/sbin/spctl}"
if [[ -n "${IDLESCREEN_R1_NOTARYTOOL:-}" ]]; then
  notary_command=("$IDLESCREEN_R1_NOTARYTOOL")
else
  notary_command=(/usr/bin/xcrun notarytool)
fi
if [[ -n "${IDLESCREEN_R1_STAPLER:-}" ]]; then
  stapler_command=("$IDLESCREEN_R1_STAPLER")
else
  stapler_command=(/usr/bin/xcrun stapler)
fi

for command_path in \
  "$git_command" "$security_command" "$c3_builder" "$c3_verifier" "$codesign_command" \
  "$product_verifier" "$signing_verifier" "$hdiutil_command" "$spctl_command" \
  /usr/bin/xattr; do
  [[ -x "$command_path" ]] || {
    echo "FAIL: required release command is missing: $command_path" >&2
    exit 69
  }
done
[[ -x "${notary_command[0]}" && -x "${stapler_command[0]}" ]] || {
  echo "FAIL: Xcode notarization commands are unavailable." >&2
  exit 69
}

identity_sha1="${IDLESCREEN_DEVELOPER_IDENTITY_SHA1:-}"
notary_profile="${IDLESCREEN_NOTARY_KEYCHAIN_PROFILE:-}"
app_profile="${IDLESCREEN_DEVELOPER_ID_APP_PROFILE:-}"
extension_profile="${IDLESCREEN_DEVELOPER_ID_EXTENSION_PROFILE:-}"
helper_profile="${IDLESCREEN_DEVELOPER_ID_HELPER_PROFILE:-}"
[[ "$identity_sha1" =~ ^[0-9A-Fa-f]{40}$ ]] || usage
identity_sha1="$(/usr/bin/printf '%s' "$identity_sha1" | /usr/bin/tr '[:lower:]' '[:upper:]')"
[[ "$notary_profile" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || usage
fail() {
  echo "FAIL: $*" >&2
  [[ ! -d "$output_root" ]] || echo "Evidence: $output_root" >&2
  exit 1
}

blocked() {
  echo "BLOCKED: $*" >&2
  [[ ! -d "$output_root" ]] || echo "Evidence: $output_root" >&2
  exit 69
}

[[ "${IDLESCREEN_ALLOW_SIGNING_CREDENTIAL_UPDATES:-NO}" != YES ]] ||
  blocked "R1.2a forbids signing credential or provisioning updates"
for nested_c3_override in \
  IDLESCREEN_PROVENANCE_FIXTURE_MODE \
  IDLESCREEN_PROVENANCE_CODESIGN \
  IDLESCREEN_PROVENANCE_SECURITY; do
  [[ -z "${!nested_c3_override+x}" ]] ||
    fail "R1.2a forbids inherited nested C3 provenance command overrides"
done

scratch_root="$(mktemp -d /tmp/idlescreen-r1-release-builder.XXXXXX)"
manifest_temp=""
cleanup() {
  local status=$?
  trap - EXIT
  [[ -z "$manifest_temp" || ! -e "$manifest_temp" ]] || /bin/rm -f "${manifest_temp:?}"
  /bin/rm -rf "${scratch_root:?}"
  exit "$status"
}
trap cleanup EXIT

source_status="$($git_command -C "$project_root" status --porcelain=v1 --untracked-files=all)" ||
  fail "could not inspect source status"
[[ -z "$source_status" ]] || blocked "the exact release source must be a clean committed worktree"
source_commit="$($git_command -C "$project_root" rev-parse HEAD)" || fail "could not resolve source commit"
source_tree="$($git_command -C "$project_root" rev-parse 'HEAD^{tree}')" || fail "could not resolve source tree"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ && "$source_tree" =~ ^[0-9a-f]{40}$ ]] ||
  fail "source commit or tree identity is malformed"
$git_command -C "$project_root" diff --check || fail "source tree contains whitespace errors"

identity_inventory="$scratch_root/signing-identities.txt"
"$security_command" find-identity -v -p codesigning >"$identity_inventory" 2>&1 ||
  blocked "Developer ID signing identities are unavailable"
identity_match_count="$(/usr/bin/awk -v identity="$identity_sha1" '
  index($0, identity) && $0 ~ /"Developer ID Application: .* \(3524374A2S\)"/ { count += 1 }
  END { print count + 0 }
' "$identity_inventory")"
[[ "$identity_match_count" == 1 ]] ||
  blocked "the exact Developer ID Application identity for Team 3524374A2S is unavailable or ambiguous"

validate_profile_preflight() {
  local profile="$1"
  local product_name="$2"
  local bundle_identifier="$3"
  local decoded="$4"
  local current_epoch
  local get_task_allow

  [[ "$profile" = /* && -f "$profile" && ! -L "$profile" ]] ||
    blocked "$product_name Developer ID profile must be an absolute regular non-symlink file"
  "$security_command" cms -D -i "$profile" -o "$decoded" >/dev/null 2>&1 ||
    blocked "could not decode $product_name Developer ID provisioning profile"
  /usr/bin/plutil -lint "$decoded" >/dev/null 2>&1 ||
    fail "$product_name Developer ID profile is malformed"
  [[ "$(/usr/bin/plutil -extract ProvisionsAllDevices raw "$decoded" 2>/dev/null || true)" == true ]] ||
    fail "$product_name profile is not a Developer ID distribution profile"
  if /usr/bin/plutil -extract ProvisionedDevices json -o - "$decoded" >/dev/null 2>&1; then
    fail "$product_name profile is not a Developer ID distribution profile"
  fi
  [[ "$(/usr/bin/plutil -extract TeamIdentifier.0 raw "$decoded" 2>/dev/null || true)" == 3524374A2S ]] ||
    fail "$product_name Developer ID profile TeamIdentifier drifted"
  if /usr/bin/plutil -extract TeamIdentifier.1 raw "$decoded" >/dev/null 2>&1; then
    fail "$product_name Developer ID profile contains multiple TeamIdentifiers"
  fi
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$decoded" 2>/dev/null || true)" == 3524374A2S ]] ||
    fail "$product_name Developer ID profile team entitlement drifted"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$decoded" 2>/dev/null || true)" == "3524374A2S.$bundle_identifier" ]] ||
    fail "$product_name Developer ID profile application identifier drifted"
  get_task_allow="$(/usr/bin/plutil -extract Entitlements.get-task-allow raw "$decoded" 2>/dev/null || true)"
  [[ -z "$get_task_allow" || "$get_task_allow" == false ]] ||
    fail "$product_name Developer ID profile enables get-task-allow"
  camera_agent_profile_authorizes_app_group "$decoded" group.com.idlescreen.shared 3524374A2S ||
    fail "$product_name Developer ID profile does not exactly authorize the production App Group"
  current_epoch="$(/bin/date -u '+%s')"
  camera_agent_profile_is_current "$decoded" "$current_epoch" ||
    fail "$product_name Developer ID profile is invalid or expired"
}

decoded_app_profile="$scratch_root/app-profile.plist"
decoded_extension_profile="$scratch_root/extension-profile.plist"
decoded_helper_profile="$scratch_root/helper-profile.plist"
validate_profile_preflight "$app_profile" app com.idlescreen.app "$decoded_app_profile"
validate_profile_preflight \
  "$extension_profile" extension com.idlescreen.app.screensaver "$decoded_extension_profile"
validate_profile_preflight "$helper_profile" helper com.idlescreen.camera-agent "$decoded_helper_profile"

notary_history="$scratch_root/notary-history.json"
"${notary_command[@]}" history --keychain-profile "$notary_profile" --output-format json \
  >"$notary_history" 2>/dev/null ||
  blocked "the existing notarytool Keychain profile could not authenticate"
/usr/bin/jq -e . "$notary_history" >/dev/null 2>&1 ||
  blocked "the existing notarytool Keychain profile returned malformed data"

umask 077
/bin/mkdir "$output_root"
/bin/mkdir "$output_root/Evidence" "$output_root/Distribution"
c3_root="$output_root/C3"
/usr/bin/env \
  -u IDLESCREEN_PROVENANCE_FIXTURE_MODE \
  -u IDLESCREEN_PROVENANCE_CODESIGN \
  -u IDLESCREEN_PROVENANCE_SECURITY \
  IDLESCREEN_ALLOW_SIGNING_CREDENTIAL_UPDATES=NO \
  "$c3_builder" "$c3_root" ||
  fail "the exact C3 archive foundation failed"
c3_archive="$c3_root/IdleScreenC3Release.xcarchive"
c3_manifest="$c3_root/IdleScreenC3ReleaseProvenanceV1.txt"
[[ -d "$c3_archive" && ! -L "$c3_archive" && -f "$c3_manifest" && ! -L "$c3_manifest" ]] ||
  fail "C3 did not produce its exact archive and provenance manifest"
[[ "$(r1_manifest_value "$c3_manifest" verification_mode)" == release ]] ||
  fail "R1.2a requires real release-mode C3 provenance"
c3_archive_tree_sha="$(r1_manifest_value "$c3_manifest" archive_tree_sha256)" ||
  fail "C3 archive tree identity is missing"
[[ "$c3_archive_tree_sha" =~ ^[0-9a-f]{64}$ ]] || fail "C3 archive tree identity is malformed"
c3_replay_manifest="$scratch_root/c3-replayed-provenance.txt"
/usr/bin/env \
  -u IDLESCREEN_PROVENANCE_FIXTURE_MODE \
  -u IDLESCREEN_PROVENANCE_CODESIGN \
  -u IDLESCREEN_PROVENANCE_SECURITY \
  "$c3_verifier" "$c3_archive" "$c3_replay_manifest" 3524374A2S >/dev/null ||
  fail "C3 provenance replay rejected the retained archive"
/usr/bin/cmp -s "$c3_manifest" "$c3_replay_manifest" ||
  fail "retained C3 provenance does not exactly replay from the archive"

source_app="$c3_archive/Products/Applications/IdleScreen.app"
distribution_stage="$scratch_root/distribution-stage"
distribution_app="$distribution_stage/IdleScreen.app"
[[ -d "$source_app" && ! -L "$source_app" ]] || fail "C3 archive contains no canonical IdleScreen.app"
/bin/mkdir "$distribution_stage"
/usr/bin/ditto "$source_app" "$distribution_app" || fail "could not stage the distribution app with ditto"

distribution_extension="$distribution_app/Contents/PlugIns/IdleScreenScreenSaver.appex"
distribution_helper="$distribution_app/Contents/Helpers/IdleScreenCameraAgent.app"
distribution_renderer="$distribution_app/Contents/Frameworks/IdleScreenRenderer.framework"
distribution_control_tool="$distribution_app/Contents/Helpers/idlescreenctl"
for distribution_product in \
  "$distribution_extension" "$distribution_helper" "$distribution_renderer" "$distribution_control_tool"; do
  [[ -e "$distribution_product" && ! -L "$distribution_product" ]] ||
    fail "distribution staging is missing a required nested product: $distribution_product"
done
/usr/bin/ditto "$app_profile" "$distribution_app/Contents/embedded.provisionprofile" ||
  fail "could not embed app Developer ID profile"
/usr/bin/ditto "$extension_profile" "$distribution_extension/Contents/embedded.provisionprofile" ||
  fail "could not embed extension Developer ID profile"
/usr/bin/ditto "$helper_profile" "$distribution_helper/Contents/embedded.provisionprofile" ||
  fail "could not embed helper Developer ID profile"
for embedded_profile in \
  "$distribution_app/Contents/embedded.provisionprofile" \
  "$distribution_extension/Contents/embedded.provisionprofile" \
  "$distribution_helper/Contents/embedded.provisionprofile"; do
  /usr/bin/xattr -c "$embedded_profile" ||
    fail "could not normalize embedded provisioning-profile metadata"
  external_xattrs="$(
    /usr/bin/xattr "$embedded_profile" |
      /usr/bin/awk '$0 != "com.apple.provenance"'
  )"
  [[ -z "$external_xattrs" ]] ||
    fail "embedded provisioning profile retains external filesystem metadata"
done

bundle_short_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$distribution_app/Contents/Info.plist")" ||
  fail "distribution app has no short version"
bundle_version="$(/usr/bin/plutil -extract CFBundleVersion raw "$distribution_app/Contents/Info.plist")" ||
  fail "distribution app has no build version"
[[ "$bundle_short_version" =~ ^[0-9A-Za-z._-]{1,64}$ && "$bundle_version" =~ ^[0-9A-Za-z._-]{1,64}$ ]] ||
  fail "distribution app version is unsafe for packaging"
[[ "$bundle_version" =~ ^[0-9]+$ ]] || fail "release candidate build version must be an integer"
((10#$bundle_version > 60)) || fail "release candidate build version must be greater than baseline build 60"

project_yml_sha="$(r1_sha256_file "$project_root/project.yml")"
project_pbxproj_sha="$(r1_sha256_file "$project_root/IdleScreen.xcodeproj/project.pbxproj")"
c3_manifest_sha="$(r1_sha256_file "$c3_manifest")"
build_environment="$output_root/Evidence/build-environment.txt"
{
  /usr/bin/printf 'source_commit=%s\n' "$source_commit"
  /usr/bin/printf 'source_tree=%s\n' "$source_tree"
  /usr/bin/sw_vers
  /usr/bin/xcodebuild -version
} >"$build_environment"
build_environment_sha="$(r1_sha256_file "$build_environment")"
embedded_provenance="$distribution_app/Contents/Resources/IdleScreenReleaseProvenance.plist"
/bin/mkdir -p "$distribution_app/Contents/Resources"
/usr/bin/plutil -create xml1 "$embedded_provenance"
/usr/bin/plutil -insert Schema -string IdleScreenEmbeddedReleaseProvenance/v1 "$embedded_provenance"
/usr/bin/plutil -insert SourceCommit -string "$source_commit" "$embedded_provenance"
/usr/bin/plutil -insert SourceTree -string "$source_tree" "$embedded_provenance"
/usr/bin/plutil -insert ProjectYMLSHA256 -string "$project_yml_sha" "$embedded_provenance"
/usr/bin/plutil -insert ProjectPBXProjSHA256 -string "$project_pbxproj_sha" "$embedded_provenance"
/usr/bin/plutil -insert C3ManifestSHA256 -string "$c3_manifest_sha" "$embedded_provenance"
/usr/bin/plutil -insert C3ArchiveTreeSHA256 -string "$c3_archive_tree_sha" "$embedded_provenance"
/usr/bin/plutil -insert BuildEnvironmentSHA256 -string "$build_environment_sha" "$embedded_provenance"
/usr/bin/plutil -insert BundleShortVersion -string "$bundle_short_version" "$embedded_provenance"
/usr/bin/plutil -insert BundleVersion -string "$bundle_version" "$embedded_provenance"

sign_product() {
  local product_path="$1"
  local entitlements="${2:-}"
  local identifier="${3:-}"
  local arguments=(--force --sign "$identity_sha1" --timestamp --options runtime)
  [[ -z "$identifier" ]] || arguments+=(--identifier "$identifier")
  [[ -z "$entitlements" ]] || arguments+=(--entitlements "$entitlements")
  arguments+=("$product_path")
  "$codesign_command" "${arguments[@]}" || fail "Developer ID signing failed: $product_path"
}

# Apple requires explicit inside-out signing. Do not replace this order with --deep.
sign_product "$distribution_renderer"
sign_product "$distribution_extension" \
  "$project_root/IdleScreenScreenSaver/IdleScreenScreenSaverDeveloperID.entitlements"
sign_product "$distribution_helper" \
  "$project_root/IdleScreenCameraAgent/IdleScreenCameraAgentDeveloperID.entitlements"
sign_product "$distribution_control_tool" \
  "$project_root/IdleScreenAgentExecutable/idlescreenctl-DeveloperID.entitlements" \
  com.idlescreen.ctl
sign_product "$distribution_app" "$project_root/IdleScreenApp/IdleScreenDeveloperID.entitlements"

extract_certificate() {
  local product_path="$1"
  local product_name="$2"
  local prefix="$scratch_root/$product_name-certificate-"
  "$codesign_command" --display --extract-certificates="$prefix" "$product_path" >/dev/null 2>&1 ||
    fail "could not extract $product_name Developer ID certificate"
  [[ -s "${prefix}0" ]] || fail "$product_name has no Developer ID leaf certificate"
  /usr/bin/printf '%s\n' "${prefix}0"
}

app_certificate="$(extract_certificate "$distribution_app" app)"
extension_certificate="$(extract_certificate "$distribution_extension" extension)"
helper_certificate="$(extract_certificate "$distribution_helper" helper)"
renderer_certificate="$(extract_certificate "$distribution_renderer" renderer)"
control_tool_certificate="$(extract_certificate "$distribution_control_tool" control-tool)"
for nested_certificate in \
  "$extension_certificate" "$helper_certificate" "$renderer_certificate" "$control_tool_certificate"; do
  /usr/bin/cmp -s "$app_certificate" "$nested_certificate" ||
    fail "nested products do not share one exact Developer ID signing certificate"
done
developer_id_certificate_sha="$(r1_sha256_file "$app_certificate")"
[[ "$developer_id_certificate_sha" =~ ^[0-9a-f]{64}$ ]] || fail "Developer ID certificate hash is malformed"
camera_agent_profile_authorizes_signer \
  "$decoded_app_profile" "$app_certificate" "$scratch_root/app-profile-certificates" ||
  fail "app Developer ID profile does not authorize the exact signer"
camera_agent_profile_authorizes_signer \
  "$decoded_extension_profile" "$app_certificate" "$scratch_root/extension-profile-certificates" ||
  fail "extension Developer ID profile does not authorize the exact signer"
camera_agent_profile_authorizes_signer \
  "$decoded_helper_profile" "$app_certificate" "$scratch_root/helper-profile-certificates" ||
  fail "helper Developer ID profile does not authorize the exact signer"

product_verification="$output_root/Evidence/developer-id-product.txt"
"$verifier" --app "$distribution_app" "$developer_id_certificate_sha" >"$product_verification" ||
  fail "Developer ID app verification failed before packaging"
distribution_app_tree_sha="$(r1_tree_sha256 "$distribution_app" "$output_root/Evidence/distribution-app-inventory.tsv")" ||
  fail "could not hash the exact distribution app"

package_root="$scratch_root/package-root"
/bin/mkdir "$package_root"
/usr/bin/ditto "$distribution_app" "$package_root/IdleScreen.app" ||
  fail "could not stage the DMG app with ditto"
/bin/ln -s /Applications "$package_root/Applications"
dmg_path="$output_root/Distribution/idlescreen-$bundle_short_version-build$bundle_version.dmg"
"$hdiutil_command" create -srcfolder "$package_root" -format UDZO -volname idlescreen -o "$dmg_path" ||
  fail "could not create the UDZO release DMG"
[[ -f "$dmg_path" && ! -L "$dmg_path" ]] || fail "DMG creation produced no regular file"
"$codesign_command" --force --sign "$identity_sha1" --timestamp \
  --identifier com.idlescreen.app.dmg "$dmg_path" || fail "could not sign the release DMG"
"$hdiutil_command" verify "$dmg_path" >/dev/null 2>&1 || fail "signed DMG integrity verification failed"
submitted_dmg_sha="$(r1_sha256_file "$dmg_path")"

notary_submit="$output_root/Evidence/notary-submit.json"
"${notary_command[@]}" submit "$dmg_path" --keychain-profile "$notary_profile" \
  --output-format json >"$notary_submit" || fail "notary submission failed"
notary_submission_id="$(/usr/bin/jq -r '.id // empty' "$notary_submit")"
[[ "$notary_submission_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] ||
  fail "notary submission returned no valid identifier"
notary_wait="$output_root/Evidence/notary-wait.json"
"${notary_command[@]}" wait "$notary_submission_id" --keychain-profile "$notary_profile" \
  --timeout 30m --output-format json >"$notary_wait" || fail "notary wait did not complete"
wait_submission_id="$(/usr/bin/jq -r '.id // empty' "$notary_wait")"
notary_status="$(/usr/bin/jq -r '.status // empty' "$notary_wait")"
normalized_wait_submission_id="$(/usr/bin/printf '%s' "$wait_submission_id" | /usr/bin/tr '[:upper:]' '[:lower:]')"
normalized_notary_submission_id="$(/usr/bin/printf '%s' "$notary_submission_id" | /usr/bin/tr '[:upper:]' '[:lower:]')"
[[ "$normalized_wait_submission_id" == "$normalized_notary_submission_id" ]] ||
  fail "notary wait returned a different submission identifier"
[[ "$notary_status" == Accepted ]] || fail "notary service did not accept the release DMG"
notary_log="$output_root/Evidence/notary-log.json"
"${notary_command[@]}" log "$notary_submission_id" --keychain-profile "$notary_profile" \
  "$notary_log" || fail "could not download the notarization log"
/usr/bin/jq -e . "$notary_log" >/dev/null 2>&1 || fail "notarization log is malformed"
log_submission_id="$(/usr/bin/jq -r '.jobId // empty' "$notary_log")"
log_status="$(/usr/bin/jq -r '.status // empty' "$notary_log")"
log_submitted_dmg_sha="$(/usr/bin/jq -r '.sha256 // empty' "$notary_log" | /usr/bin/tr '[:upper:]' '[:lower:]')"
notary_issue_count="$(/usr/bin/jq -r 'if .issues == null then 0 elif (.issues | type) == "array" then (.issues | length) else -1 end' "$notary_log")"
normalized_log_submission_id="$(/usr/bin/printf '%s' "$log_submission_id" | /usr/bin/tr '[:upper:]' '[:lower:]')"
[[ "$normalized_log_submission_id" == "$normalized_notary_submission_id" &&
   "$log_status" == Accepted ]] || fail "notarization log does not match the accepted submission"
[[ "$log_submitted_dmg_sha" == "$submitted_dmg_sha" ]] ||
  fail "notarization log does not bind the submitted DMG SHA-256"
[[ "$notary_issue_count" == 0 ]] || fail "notarization log contains issues"
notary_log_sha="$(r1_sha256_file "$notary_log")"

"${stapler_command[@]}" staple "$dmg_path" ||
  fail "could not staple the accepted notarization ticket"
"${stapler_command[@]}" validate "$dmg_path" >/dev/null 2>&1 ||
  fail "stapled notarization ticket is not valid"
stapled_dmg_sha="$(r1_sha256_file "$dmg_path")"

manifest="$output_root/IdleScreenR1ReleaseCandidateV1.txt"
manifest_temp="$output_root/.IdleScreenR1ReleaseCandidateV1.txt.tmp"
{
  echo 'schema=IdleScreenR1ReleaseCandidate/v1'
  if [[ "$fixture_mode" == YES ]]; then
    echo 'verification_mode=fixture'
  else
    echo 'verification_mode=release'
  fi
  /usr/bin/printf 'source_commit=%s\n' "$source_commit"
  /usr/bin/printf 'source_tree=%s\n' "$source_tree"
  echo 'source_clean=true'
  /usr/bin/printf 'project_yml_sha256=%s\n' "$project_yml_sha"
  /usr/bin/printf 'project_pbxproj_sha256=%s\n' "$project_pbxproj_sha"
  echo 'c3_manifest_relative_path=C3/IdleScreenC3ReleaseProvenanceV1.txt'
  /usr/bin/printf 'c3_manifest_sha256=%s\n' "$c3_manifest_sha"
  /usr/bin/printf 'c3_archive_tree_sha256=%s\n' "$c3_archive_tree_sha"
  /usr/bin/printf 'build_environment_sha256=%s\n' "$build_environment_sha"
  /usr/bin/printf 'bundle_short_version=%s\n' "$bundle_short_version"
  /usr/bin/printf 'bundle_version=%s\n' "$bundle_version"
  echo 'team_identifier=3524374A2S'
  echo 'dmg_signing_identifier=com.idlescreen.app.dmg'
  /usr/bin/printf 'distribution_app_tree_sha256=%s\n' "$distribution_app_tree_sha"
  /usr/bin/printf 'developer_id_certificate_sha256=%s\n' "$developer_id_certificate_sha"
  for cdhash_key in app extension helper renderer control_tool; do
    /usr/bin/printf '%s_cdhash=%s\n' "$cdhash_key" \
      "$(r1_manifest_value "$product_verification" "${cdhash_key}_cdhash")"
  done
  /usr/bin/printf 'dmg_relative_path=Distribution/%s\n' "$(/usr/bin/basename "$dmg_path")"
  /usr/bin/printf 'submitted_dmg_sha256=%s\n' "$submitted_dmg_sha"
  /usr/bin/printf 'notary_submission_id=%s\n' "$notary_submission_id"
  /usr/bin/printf 'notary_status=%s\n' "$notary_status"
  /usr/bin/printf 'notary_issue_count=%s\n' "$notary_issue_count"
  echo 'notary_log_relative_path=Evidence/notary-log.json'
  /usr/bin/printf 'notary_log_sha256=%s\n' "$notary_log_sha"
  /usr/bin/printf 'stapled_dmg_sha256=%s\n' "$stapled_dmg_sha"
  echo 'stapler_status=valid'
  echo 'dmg_gatekeeper_status=accepted'
  echo 'mounted_app_gatekeeper_status=accepted'
} >"$manifest_temp"

"$verifier" "$dmg_path" "$manifest_temp" >"$output_root/Evidence/final-verification.txt" ||
  fail "final stapled DMG verification failed"
final_source_status="$($git_command -C "$project_root" status --porcelain=v1 --untracked-files=all)" ||
  fail "could not recheck source status"
final_source_commit="$($git_command -C "$project_root" rev-parse HEAD)" ||
  fail "could not recheck source commit"
final_source_tree="$($git_command -C "$project_root" rev-parse 'HEAD^{tree}')" ||
  fail "could not recheck source tree"
$git_command -C "$project_root" diff --check || fail "source changed during release construction"
[[ -z "$final_source_status" && "$final_source_commit" == "$source_commit" &&
   "$final_source_tree" == "$source_tree" ]] || fail "source changed during release construction"
/bin/mv "$manifest_temp" "$manifest"
manifest_temp=""
/bin/chmod a-w "$manifest" "$dmg_path"

trap - EXIT
/bin/rm -rf "${scratch_root:?}"
echo "PASS: one exact Developer ID release candidate was signed, notarized, stapled, and Gatekeeper verified."
echo "DMG: $dmg_path"
echo "Manifest: $manifest"
echo "Evidence: $output_root"
