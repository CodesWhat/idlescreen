#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/new-c3-evidence-directory" >&2
  exit 64
}

[[ $# -eq 1 ]] || usage

project_root="$(cd "$(dirname "$0")/.." && pwd)"
profile_policy="$project_root/scripts/camera-agent-profile-policy.sh"
requested_output_root="$1"
[[ "$requested_output_root" = /* ]] || usage
output_parent="$(/usr/bin/dirname "$requested_output_root")"
output_leaf="$(/usr/bin/basename "$requested_output_root")"
[[ -n "$output_leaf" && "$output_leaf" != . && "$output_leaf" != .. ]] || usage
[[ -d "$output_parent" && ! -L "$output_parent" ]] || {
  echo "FAIL: C3 evidence parent must be an existing, non-symlink directory: $output_parent" >&2
  exit 66
}
output_parent="$(/bin/realpath "$output_parent")"
output_root="$output_parent/$output_leaf"
[[ ! -e "$output_root" && ! -L "$output_root" ]] || {
  echo "FAIL: refusing to replace existing C3 evidence: $output_root" >&2
  exit 73
}

case "$output_root" in
  "$project_root"|"$project_root"/*)
    echo "FAIL: C3 evidence must be written outside the source repository: $output_root" >&2
    exit 64
    ;;
esac
project="$project_root/IdleScreen.xcodeproj"
scheme="IdleScreenC3ReleaseArchive"
archive_path="$output_root/IdleScreenC3Release.xcarchive"
manifest_path="$output_root/IdleScreenC3ReleaseProvenanceV1.txt"
archive_log="$output_root/archive.log"
aggregate_log="$output_root/c3-verification.log"

credential_update_opt_in="${IDLESCREEN_ALLOW_SIGNING_CREDENTIAL_UPDATES:-NO}"
[[ "$credential_update_opt_in" == YES || "$credential_update_opt_in" == NO ]] || {
  echo "FAIL: IDLESCREEN_ALLOW_SIGNING_CREDENTIAL_UPDATES must be YES or unset." >&2
  exit 64
}
provisioning_update_argument=""
if [[ "$credential_update_opt_in" == YES ]]; then
  provisioning_update_argument=-allowProvisioningUpdates
fi

fail() {
  echo "FAIL: $*" >&2
  if [[ -d "$output_root" ]]; then
    echo "Evidence: $output_root" >&2
  else
    echo "Planned evidence path was not created: $output_root" >&2
  fi
  exit 1
}

blocked() {
  echo "BLOCKED: $*" >&2
  echo "No product was installed, registered, launched, or granted camera access." >&2
  if [[ -d "$output_root" ]]; then
    echo "Evidence: $output_root" >&2
  else
    echo "Planned evidence path was not created: $output_root" >&2
  fi
  exit 69
}

if [[ -n "${IDLESCREEN_PROVENANCE_FIXTURE_MODE+x}" ||
      -n "${IDLESCREEN_PROVENANCE_CODESIGN+x}" ||
      -n "${IDLESCREEN_PROVENANCE_SECURITY+x}" ]]; then
  fail "real C3 archive preparation refuses provenance fixture mode and command overrides"
fi

for command_path in /usr/bin/security /usr/bin/xcodebuild /usr/bin/shasum /usr/libexec/PlistBuddy; do
  [[ -x "$command_path" ]] || {
    echo "FAIL: missing required command: $command_path" >&2
    exit 69
  }
done
command -v xcodegen >/dev/null 2>&1 || {
  echo "FAIL: xcodegen is required to prepare the canonical C3 project." >&2
  exit 69
}
[[ -f "$profile_policy" ]] || {
  echo "FAIL: missing provisioning-profile policy: $profile_policy" >&2
  exit 69
}
# shellcheck source=camera-agent-profile-policy.sh
source "$profile_policy"
[[ -x "$project_root/scripts/test-camera-gate-c3.sh" ]] || {
  echo "FAIL: missing C3 aggregate: $project_root/scripts/test-camera-gate-c3.sh" >&2
  exit 66
}

# A missing local identity is a normal environmental blocker. The managed shell
# can hide otherwise usable Security state, so an explicit opt-in may delegate
# credential/profile acquisition to Xcode automatic signing. That opt-in may
# mutate the developer account, local profile store, or Keychain and is never
# inferred merely from running the builder.
# `find-identity` prints the certificate's common-name suffix, not its Team OU.
# Accept any valid Apple Development leaf here; the archive verifier later
# extracts and requires TeamIdentifier=3524374A2S, exact profile membership,
# and one byte-identical signer certificate across all three products.
if ! /usr/bin/security find-identity -v -p codesigning 2>/dev/null |
   /usr/bin/grep -Eq 'Apple Development:'; then
  [[ "$credential_update_opt_in" == YES ]] ||
    blocked "no usable Apple Development signing identity is visible; rerun with IDLESCREEN_ALLOW_SIGNING_CREDENTIAL_UPDATES=YES only when developer-account, profile-store, and Keychain mutation is authorized. Exact Team identity is enforced on the completed archive."
fi

umask 077
/bin/mkdir "$output_root"
derived_data="$(mktemp -d /tmp/idlescreen-c3-release-derived.XXXXXX)"
cleanup() {
  /bin/rm -rf "$derived_data"
}
trap cleanup EXIT

profile_root="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
[[ -d "$profile_root" && ! -L "$profile_root" ]] ||
  blocked "the Xcode provisioning-profile store is unavailable"

resolve_installed_profile() {
  local expected_application_identifier="$1"
  local candidate
  local decoded_profile="$derived_data/profile.plist"
  local application_identifier

  while IFS= read -r -d '' candidate; do
    [[ -f "$candidate" && ! -L "$candidate" ]] || continue
    /usr/bin/security cms -D -i "$candidate" >"$decoded_profile" 2>/dev/null || continue
    application_identifier="$(
      /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' \
        "$decoded_profile" 2>/dev/null || true
    )"
    if [[ "$application_identifier" == "$expected_application_identifier" ]] &&
       camera_agent_profile_is_development "$decoded_profile"; then
      /bin/realpath "$candidate"
      return 0
    fi
  done < <(/usr/bin/find -s "$profile_root" -maxdepth 1 -type f -print0)
  return 1
}

app_profile="$(resolve_installed_profile '3524374A2S.com.idlescreen.app')" ||
  blocked "no installed provisioning profile authorizes com.idlescreen.app"
helper_profile="$(resolve_installed_profile '3524374A2S.com.idlescreen.camera-agent')" ||
  blocked "no installed provisioning profile authorizes com.idlescreen.camera-agent"

{
  printf 'app_profile_sha256=%s\n' \
    "$(/usr/bin/shasum -a 256 "$app_profile" | /usr/bin/awk '{ print $1 }')"
  printf 'helper_profile_sha256=%s\n' \
    "$(/usr/bin/shasum -a 256 "$helper_profile" | /usr/bin/awk '{ print $1 }')"
} >"$output_root/selected-profiles.txt"

{
  printf 'captured_at_utc=%s\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'source_revision=%s\n' "$(git -C "$project_root" rev-parse HEAD)"
  printf 'signing_credential_updates_authorized=%s\n' "$credential_update_opt_in"
  printf 'project_yml_sha256=%s\n' \
    "$(/usr/bin/shasum -a 256 "$project_root/project.yml" | /usr/bin/awk '{ print $1 }')"
  printf 'source_status_begin\n'
  git -C "$project_root" status --short --untracked-files=all
  printf 'source_status_end\n'
  /usr/bin/sw_vers
  /usr/bin/xcodebuild -version
} >"$output_root/build-environment.txt"

# Project generation changes metadata only. The dedicated scheme makes the app
# eligible solely for Archive; this script never invokes xcodebuild's build/run
# actions or any installation/registration API.
xcodegen generate --spec "$project_root/project.yml" \
  >"$output_root/xcodegen.log" 2>&1 || fail "canonical project generation failed"
[[ -d "$project" ]] || fail "canonical project was not generated"

echo "START: archiving the exact provisioned Release candidate."
echo "The terminal stays quiet while Xcode writes progress to: $archive_log"
set +e
IDLESCREEN_C3_APP_PROVISIONING_PROFILE_PATH="$app_profile" \
IDLESCREEN_C3_HELPER_PROVISIONING_PROFILE_PATH="$helper_profile" \
/usr/bin/xcodebuild archive \
  -project "$project" \
  -scheme "$scheme" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  -derivedDataPath "$derived_data" \
  ${provisioning_update_argument:+"$provisioning_update_argument"} \
  >"$archive_log" 2>&1
archive_status=$?
set -e

# Registration is a boundary violation even when a later archive step fails.
# Inspect the complete log before interpreting the xcodebuild exit status so a
# partial archive can never hide a LaunchServices action behind another error.
if /usr/bin/grep -Eq \
  'RegisterWithLaunchServices|(^|[ /])lsregister([ /]|$)' "$archive_log"; then
  fail "archive log contains a LaunchServices registration action"
fi

if ((archive_status != 0)); then
  /usr/bin/tail -100 "$archive_log" >&2
  if /usr/bin/grep -Fxq '** ARCHIVE INTERRUPTED **' "$archive_log"; then
    blocked "Xcode archive was interrupted before it could produce the exact candidate."
  fi
  if /usr/bin/grep -Eiq \
    '(^|[[:space:]])error:.*(No signing certificate|No profiles for|provisioning profile|requires a development team|authentication|account.*(missing|required))' \
    "$archive_log"; then
    blocked "Xcode could not obtain the provisioned Release credentials/profiles for the exact candidate."
  fi
  fail "provisioned Release archive failed"
fi

[[ -d "$archive_path/Products/Applications/IdleScreen.app" ]] ||
  fail "archive contains no Products/Applications/IdleScreen.app"

"$project_root/scripts/test-camera-gate-c3.sh" \
  "$archive_path" "$manifest_path" | /usr/bin/tee "$aggregate_log"

release_mode_count="$(/usr/bin/grep -Fxc 'verification_mode=release' "$manifest_path" || true)"
verification_mode_count="$(/usr/bin/grep -Ec '^verification_mode=' "$manifest_path" || true)"
[[ "$release_mode_count" == 1 && "$verification_mode_count" == 1 ]] ||
  fail "C3 aggregate returned a manifest without exactly one verification_mode=release"

/bin/chmod a-w "$manifest_path"

echo "PASS: exact provisioned C3 Release archive was hash-bound and verified."
echo "PASS: no product was installed, registered, launched, focused, or granted camera access."
echo "Archive: $archive_path"
echo "Manifest: $manifest_path"
echo "Evidence: $output_root"
