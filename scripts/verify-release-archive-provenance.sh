#!/bin/bash

set -euo pipefail

script_root="$(cd "$(dirname "$0")" && pwd)"
profile_policy="$script_root/camera-agent-profile-policy.sh"
[[ -f "$profile_policy" ]] || {
  echo "FAIL: missing provisioning-profile policy library" >&2
  exit 1
}
# shellcheck disable=SC1090,SC1091
source "$profile_policy"

usage() {
  echo "Usage: $0 /absolute/path/to/IdleScreen.xcarchive /absolute/path/to/provenance.manifest [expected-team-id]" >&2
  exit 64
}

[[ $# -ge 2 && $# -le 3 ]] || usage

archive_path="$1"
output_manifest="$2"
expected_team_identifier="${3:-3524374A2S}"
expected_app_identifier="com.idlescreen.app"
expected_extension_identifier="com.idlescreen.app.screensaver"
expected_helper_identifier="com.idlescreen.camera-agent"
expected_renderer_identifier="com.idlescreen.renderer"
expected_control_tool_identifier="com.idlescreen.ctl"
expected_app_group="group.com.idlescreen.shared"
expected_mach_service="group.com.idlescreen.shared.camera-agent"
expected_usage_description="idlescreen uses the camera only for camera-based screen saver effects you explicitly enable."
expected_bundle_program="Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"

codesign_command="${IDLESCREEN_PROVENANCE_CODESIGN:-/usr/bin/codesign}"
security_command="${IDLESCREEN_PROVENANCE_SECURITY:-/usr/bin/security}"
fixture_mode=false
if [[ "$codesign_command" != /usr/bin/codesign || "$security_command" != /usr/bin/security ]]; then
  [[ "${IDLESCREEN_PROVENANCE_FIXTURE_MODE:-}" == YES ]] || {
    echo "FAIL: provenance command overrides require explicit fixture mode" >&2
    exit 64
  }
  fixture_mode=true
fi

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ "$archive_path" = /* && "$output_manifest" = /* ]] || usage
[[ "$archive_path" == *.xcarchive ]] || usage
[[ "$expected_team_identifier" =~ ^[A-Z0-9]{10}$ ]] || usage
[[ -d "$archive_path" && ! -L "$archive_path" ]] || fail "archive is missing or is a symbolic link: $archive_path"
[[ ! -e "$output_manifest" && ! -L "$output_manifest" ]] || fail "output manifest already exists"
output_parent="$(/usr/bin/dirname "$output_manifest")"
[[ -d "$output_parent" && ! -L "$output_parent" ]] || fail "output manifest parent is missing or is a symbolic link"

archive_path="$(/bin/realpath "$archive_path")" || fail "could not resolve archive path"
output_parent="$(/bin/realpath "$output_parent")" || fail "could not resolve output parent"
output_manifest="$output_parent/$(/usr/bin/basename "$output_manifest")"
case "$output_manifest" in
  "$archive_path"/*) fail "output manifest must be outside the archive" ;;
esac

scratch_root="$(mktemp -d /tmp/idlescreen-release-provenance.XXXXXX)"
manifest_temp=""
cleanup() {
  [[ -z "$manifest_temp" || ! -e "$manifest_temp" ]] || /bin/rm -f "$manifest_temp"
  /bin/rm -rf "$scratch_root"
}
trap cleanup EXIT

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print tolower($1) }'
}

plist_raw() {
  local plist="$1"
  local key="$2"
  local value

  value="$(/usr/bin/plutil -extract "$key" raw "$plist" 2>/dev/null)" ||
    fail "could not read $key from $plist"
  [[ "$value" != *$'\n'* && "$value" != *$'\t'* ]] ||
    fail "$key in $plist contains unsupported control characters"
  printf '%s\n' "$value"
}

expect_plist_raw() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local actual

  actual="$(plist_raw "$plist" "$key")"
  [[ "$actual" == "$expected" ]] ||
    fail "unexpected $key in $plist: '$actual' (expected '$expected')"
}

canonical_archive_inventory() {
  local output="$1"
  local candidate
  local relative
  local mode
  local size
  local target
  local file_sha
  local xattr_name
  local xattr_value

  : >"$output"
  while IFS= read -r -d '' candidate; do
    relative="${candidate#"$archive_path"}"
    relative="${relative#/}"
    [[ -n "$relative" ]] || relative='.'
    [[ "$relative" != *$'\n'* && "$relative" != *$'\t'* ]] ||
      fail "archive contains a path with unsupported control characters"
    mode="$(/usr/bin/stat -f '%Lp' "$candidate")" ||
      fail "could not read archive mode: $relative"
    if [[ -L "$candidate" ]]; then
      target="$(/usr/bin/readlink "$candidate")" ||
        fail "could not read archive symbolic link: $relative"
      [[ "$target" != *$'\n'* && "$target" != *$'\t'* ]] ||
        fail "archive symbolic link has an unsupported target: $relative"
      printf 'link\t%s\t%s\t%s\n' "$mode" "$relative" "$target" >>"$output"
    elif [[ -f "$candidate" ]]; then
      size="$(/usr/bin/stat -f '%z' "$candidate")" ||
        fail "could not read archive file size: $relative"
      file_sha="$(sha256_file "$candidate")" ||
        fail "could not hash archive file: $relative"
      [[ "$file_sha" =~ ^[0-9a-f]{64}$ ]] || fail "malformed file hash for $relative"
      printf 'file\t%s\t%s\t%s\t%s\n' "$mode" "$size" "$file_sha" "$relative" >>"$output"
    elif [[ -d "$candidate" ]]; then
      printf 'directory\t%s\t%s\n' "$mode" "$relative" >>"$output"
    else
      fail "archive contains an unsupported filesystem entry: $relative"
    fi

    while IFS= read -r xattr_name; do
      [[ -n "$xattr_name" ]] || continue
      [[ "$xattr_name" != *$'\n'* && "$xattr_name" != *$'\t'* ]] ||
        fail "archive contains an unsupported extended-attribute name"
      xattr_value="$(/usr/bin/xattr -px "$xattr_name" "$candidate" 2>/dev/null)" ||
        fail "could not read archive extended attribute $xattr_name on $relative"
      xattr_value="$(/usr/bin/printf '%s' "$xattr_value" | /usr/bin/tr -d '[:space:]')"
      [[ "$xattr_value" =~ ^([0-9a-fA-F][0-9a-fA-F])*$ ]] ||
        fail "malformed extended-attribute value $xattr_name on $relative"
      xattr_value="$(/usr/bin/printf '%s' "$xattr_value" | /usr/bin/tr '[:upper:]' '[:lower:]')"
      printf 'xattr\t%s\t%s\t%s\n' "$relative" "$xattr_name" "$xattr_value" >>"$output"
    done < <(/usr/bin/xattr "$candidate" 2>/dev/null | LC_ALL=C /usr/bin/sort)
  done < <(/usr/bin/find -s "$archive_path" -print0)
}

archive_inventory_before="$scratch_root/archive-inventory-before.tsv"
archive_inventory_after="$scratch_root/archive-inventory-after.tsv"
canonical_archive_inventory "$archive_inventory_before"
archive_tree_sha256="$(sha256_file "$archive_inventory_before")"
[[ "$archive_tree_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "archive inventory hash is malformed"

archive_info="$archive_path/Info.plist"
applications_path="$archive_path/Products/Applications"
app_path="$applications_path/IdleScreen.app"
app_info="$app_path/Contents/Info.plist"
app_executable="$app_path/Contents/MacOS/IdleScreen"
extension_path="$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex"
extension_info="$extension_path/Contents/Info.plist"
extension_executable="$extension_path/Contents/MacOS/IdleScreenScreenSaver"
helper_path="$app_path/Contents/Helpers/IdleScreenCameraAgent.app"
helper_info="$helper_path/Contents/Info.plist"
helper_executable="$helper_path/Contents/MacOS/IdleScreenCameraAgent"
renderer_path="$app_path/Contents/Frameworks/IdleScreenRenderer.framework"
renderer_info="$renderer_path/Resources/Info.plist"
renderer_executable="$renderer_path/Versions/A/IdleScreenRenderer"
control_tool_executable="$app_path/Contents/Helpers/idlescreenctl"
launch_agents_path="$app_path/Contents/Library/LaunchAgents"
launch_agent="$launch_agents_path/$expected_mach_service.plist"

[[ -f "$archive_info" ]] || fail "archive Info.plist is missing"
[[ -d "$applications_path" ]] || fail "archive Products/Applications is missing"
archive_app_count="$(/usr/bin/find "$applications_path" -mindepth 1 -maxdepth 1 -type d -name '*.app' | /usr/bin/awk 'END { print NR + 0 }')"
[[ "$archive_app_count" == 1 && -d "$app_path" ]] ||
  fail "archive must contain exactly Products/Applications/IdleScreen.app"
expect_plist_raw "$archive_info" ApplicationProperties.ApplicationPath 'Applications/IdleScreen.app'
expect_plist_raw "$archive_info" ApplicationProperties.CFBundleIdentifier "$expected_app_identifier"

for required_plist in "$app_info" "$extension_info" "$helper_info" "$renderer_info" "$launch_agent"; do
  [[ -f "$required_plist" ]] || fail "required product property list is missing: $required_plist"
  /usr/bin/plutil -lint "$required_plist" >/dev/null 2>&1 ||
    fail "required product property list is malformed: $required_plist"
done
for required_executable in "$app_executable" "$extension_executable" "$helper_executable" "$renderer_executable" "$control_tool_executable"; do
  [[ -f "$required_executable" && -x "$required_executable" ]] ||
    fail "required product executable is missing or non-executable: $required_executable"
done

expect_plist_raw "$app_info" CFBundleIdentifier "$expected_app_identifier"
expect_plist_raw "$extension_info" CFBundleIdentifier "$expected_extension_identifier"
expect_plist_raw "$helper_info" CFBundleIdentifier "$expected_helper_identifier"
expect_plist_raw "$renderer_info" CFBundleIdentifier "$expected_renderer_identifier"
expect_plist_raw "$app_info" IdleScreenAppGroupIdentifier "$expected_app_group"
expect_plist_raw "$app_info" IdleScreenCameraAgentAppGroupIdentifier "$expected_app_group"
expect_plist_raw "$app_info" IdleScreenCameraAgentMachServiceName "$expected_mach_service"
expect_plist_raw "$app_info" IdleScreenCameraAgentTeamIdentifier "$expected_team_identifier"
expect_plist_raw "$extension_info" IdleScreenAppGroupIdentifier "$expected_app_group"
expect_plist_raw "$extension_info" IdleScreenCameraAgentAppGroupIdentifier "$expected_app_group"
expect_plist_raw "$extension_info" IdleScreenCameraAgentMachServiceName "$expected_mach_service"
expect_plist_raw "$extension_info" IdleScreenCameraAgentTeamIdentifier "$expected_team_identifier"
expect_plist_raw "$helper_info" IdleScreenCameraAgentAppGroupIdentifier "$expected_app_group"
expect_plist_raw "$helper_info" IdleScreenCameraAgentMachServiceName "$expected_mach_service"
expect_plist_raw "$helper_info" IdleScreenCameraAgentTeamIdentifier "$expected_team_identifier"

app_purpose="$(plist_raw "$app_info" NSCameraUsageDescription)"
helper_purpose="$(plist_raw "$helper_info" NSCameraUsageDescription)"
[[ "$app_purpose" == "$expected_usage_description" && "$helper_purpose" == "$app_purpose" ]] ||
  fail "app and helper camera purpose strings are not the exact shared Release purpose"
if /usr/bin/plutil -extract NSCameraUsageDescription raw "$extension_info" >/dev/null 2>&1; then
  fail "extension must not carry a camera purpose string"
fi
purpose_sha256="$(/usr/bin/printf '%s' "$app_purpose" | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print tolower($1) }')"

for plist in "$app_info" "$extension_info" "$helper_info"; do
  if /usr/bin/plutil -extract IdleScreenSyntheticGateVersion raw "$plist" >/dev/null 2>&1 ||
     /usr/bin/plutil -extract IdleScreenSyntheticHostedGateVersion raw "$plist" >/dev/null 2>&1; then
    fail "production product contains a synthetic gate marker: $plist"
  fi
done
for executable in "$app_executable" "$extension_executable" "$helper_executable"; do
  if /usr/bin/strings -a "$executable" |
     /usr/bin/grep -E 'IdleScreenSyntheticGateVersion|IdleScreenSyntheticHostedGateVersion|IdleScreenSyntheticHostedGateViewController|IdleScreenSyntheticHostedGateViewFactory|SyntheticCameraCaptureController|bootstrapSynthetic' >/dev/null; then
    fail "production executable contains a synthetic gate marker or symbol: $executable"
  fi
done
synthetic_marker_pattern='IdleScreenSyntheticGateVersion|IdleScreenSyntheticHostedGateVersion|IdleScreenSyntheticHostedGateViewController|IdleScreenSyntheticHostedGateViewFactory|SyntheticCameraCaptureController|bootstrapSynthetic'
archive_regular_files="$scratch_root/archive-regular-files.nul"
/usr/bin/find -s "$archive_path" -type f -print0 >"$archive_regular_files" ||
  fail "could not enumerate every regular archive file for synthetic marker inspection"
while IFS= read -r -d '' archive_regular_file; do
  set +e
  /usr/bin/grep -aEq "$synthetic_marker_pattern" "$archive_regular_file"
  marker_status=$?
  set -e
  case "$marker_status" in
    0) fail "production archive contains recursive synthetic gate marker bytes: $archive_regular_file" ;;
    1) ;;
    *) fail "could not inspect archive file for synthetic gate marker bytes: $archive_regular_file" ;;
  esac
done <"$archive_regular_files"

launch_agent_count="$(/usr/bin/find "$launch_agents_path" -mindepth 1 -maxdepth 1 -type f -name '*.plist' | /usr/bin/awk 'END { print NR + 0 }')"
[[ "$launch_agent_count" == 1 ]] || fail "Release product must contain exactly one LaunchAgent property list"
launch_agent_json="$scratch_root/launch-agent.json"
/usr/bin/plutil -convert json -o "$launch_agent_json" "$launch_agent" 2>/dev/null ||
  fail "could not decode Release LaunchAgent"
/usr/bin/jq -e \
  --arg service "$expected_mach_service" \
  --arg app "$expected_app_identifier" \
  --arg program "$expected_bundle_program" \
  'keys == ["AssociatedBundleIdentifiers", "BundleProgram", "Label", "MachServices", "ProcessType"]
    and .Label == $service
    and .AssociatedBundleIdentifiers == $app
    and .BundleProgram == $program
    and .ProcessType == "Interactive"
    and (.MachServices | keys) == [$service]
    and .MachServices[$service] == true' \
  "$launch_agent_json" >/dev/null || fail "Release LaunchAgent tuple is not exact"
launch_agent_sha256="$(sha256_file "$launch_agent")"

enumerate_macho_relative_paths() {
  local candidate
  local relative

  /usr/bin/find "$app_path" -type f -print0 |
    while IFS= read -r -d '' candidate; do
      if /usr/bin/file -b "$candidate" | /usr/bin/grep -Fq 'Mach-O'; then
        relative="${candidate#"$app_path"/}"
        printf '%s\n' "$relative"
      fi
    done | LC_ALL=C /usr/bin/sort
}

expected_macho_paths="$({
  printf '%s\n' \
    Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent \
    Contents/Helpers/idlescreenctl \
    Contents/Frameworks/IdleScreenRenderer.framework/Versions/A/IdleScreenRenderer \
    Contents/MacOS/IdleScreen \
    Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver
} | LC_ALL=C /usr/bin/sort)"
actual_macho_paths="$(enumerate_macho_relative_paths)"
[[ "$actual_macho_paths" == "$expected_macho_paths" ]] ||
  fail "Release app does not contain exactly the app/helper/control-tool/extension/renderer Mach-O executables"

expect_camera_free() {
  local executable="$1"
  local product="$2"

  if /usr/bin/otool -L "$executable" | /usr/bin/grep -Fq AVFoundation ||
     /usr/bin/strings -a "$executable" | /usr/bin/grep -E 'AVCapture|AVFoundation|requestAccessForMediaType|requestAccess' >/dev/null ||
     /usr/bin/nm -u "$executable" 2>/dev/null | /usr/bin/grep -E 'AVCapture|requestAccess' >/dev/null; then
    fail "$product must not carry camera capture or AVFoundation linkage"
  fi
}

expect_camera_free "$app_executable" app
expect_camera_free "$extension_executable" extension
expect_camera_free "$renderer_executable" renderer
expect_camera_free "$control_tool_executable" control-tool
control_tool_strings="$scratch_root/control-tool-strings.txt"
/usr/bin/strings "$control_tool_executable" >"$control_tool_strings" ||
  fail "could not inspect control-tool strings"
if /usr/bin/grep -Eq \
  'IDLESCREEN_CTL_SCRATCH_ROOT|group\.com\.idlescreen\.tests\.scratch' \
  "$control_tool_strings"; then
  fail "Release control tool contains the Debug-only scratch-container gate"
fi
helper_linkage="$scratch_root/helper-linkage.txt"
helper_strings="$scratch_root/helper-strings.txt"
helper_imports="$scratch_root/helper-imports.txt"
/usr/bin/otool -L "$helper_executable" >"$helper_linkage" 2>/dev/null ||
  fail "could not inspect helper framework linkage"
/usr/bin/strings -a "$helper_executable" >"$helper_strings" 2>/dev/null ||
  fail "could not inspect helper strings"
/usr/bin/nm -u "$helper_executable" >"$helper_imports" 2>/dev/null ||
  fail "could not inspect helper imports"
/usr/bin/grep -Fq AVFoundation "$helper_linkage" || fail "helper is missing AVFoundation linkage"
if ! /usr/bin/grep -Eq 'AVCapture[A-Za-z0-9_]+' "$helper_strings" &&
   ! /usr/bin/grep -Eq 'AVCapture[A-Za-z0-9_]+' "$helper_imports"; then
  fail "helper is missing an actual AVCapture symbol or import"
fi

for signed_product in "$app_path" "$extension_path" "$helper_path" "$renderer_path" "$control_tool_executable"; do
  "$codesign_command" --verify --strict "$signed_product" >/dev/null 2>&1 ||
    fail "strict signature verification failed: $signed_product"
done
"$codesign_command" --verify --deep --strict "$app_path" >/dev/null 2>&1 ||
  fail "deep app signature verification failed"

signed_metadata() {
  local product_path="$1"
  local product_name="$2"
  local output="$scratch_root/$product_name-signature.txt"

  "$codesign_command" -dv --verbose=4 "$product_path" >"$output" 2>&1 ||
    fail "could not read $product_name signature metadata"
  printf '%s\n' "$output"
}

exact_signed_field() {
  local metadata="$1"
  local product_name="$2"
  local field="$3"
  local value
  local count

  count="$(/usr/bin/awk -F= -v key="$field" '$1 == key { count += 1 } END { print count + 0 }' "$metadata")"
  [[ "$count" == 1 ]] || fail "$product_name signature metadata has no unique $field"
  value="$(/usr/bin/awk -F= -v key="$field" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$metadata")"
  [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\t'* ]] ||
    fail "$product_name signature metadata has malformed $field"
  printf '%s\n' "$value"
}

validate_release_signature_metadata() {
  local metadata="$1"
  local product_name="$2"
  local code_directory_count
  local code_directory
  local signature_count
  local development_authority_count

  code_directory_count="$(/usr/bin/awk '/^CodeDirectory / { count += 1 } END { print count + 0 }' "$metadata")"
  [[ "$code_directory_count" == 1 ]] ||
    fail "$product_name signature metadata has no unique CodeDirectory"
  code_directory="$(/usr/bin/awk '/^CodeDirectory / { print; exit }' "$metadata")"
  [[ "$code_directory" == *' flags=0x10000(runtime) '* ]] ||
    fail "$product_name CodeDirectory does not carry exactly the hardened-runtime flag"
  signature_count="$(/usr/bin/awk '/^Signature size=[1-9][0-9]*$/ { count += 1 } END { print count + 0 }' "$metadata")"
  [[ "$signature_count" == 1 ]] || fail "$product_name signature is ad-hoc or malformed"
  if /usr/bin/grep -Eq '^Signature=adhoc$|flags=.*adhoc' "$metadata"; then
    fail "$product_name signature is ad-hoc"
  fi
  development_authority_count="$(/usr/bin/awk -F= '$1 == "Authority" && $2 ~ /^Apple Development: / { count += 1 } END { print count + 0 }' "$metadata")"
  [[ "$development_authority_count" == 1 ]] ||
    fail "$product_name signature has no unique Apple Development leaf authority"
}

extract_designated_requirement() {
  local product_path="$1"
  local product_name="$2"
  local expected_identifier="$3"
  local output="$scratch_root/$product_name-designated-requirement.txt"
  local normalized="$scratch_root/$product_name-designated-requirement.normalized.txt"
  local requirement_count
  local requirement
  local requirement_prefix
  local requirement_suffix
  local development_common_name

  "$codesign_command" -dr - "$product_path" >"$output" 2>&1 ||
    fail "could not read $product_name designated requirement"
  requirement_count="$(/usr/bin/awk '/^designated => / { count += 1 } END { print count + 0 }' "$output")"
  [[ "$requirement_count" == 1 ]] ||
    fail "$product_name has no unique designated requirement"
  requirement="$(/usr/bin/awk '/^designated => / { print; exit }' "$output")"
  requirement_prefix="designated => identifier \"$expected_identifier\" and anchor apple generic and certificate leaf[subject.CN] = \"Apple Development: "
  requirement_suffix='" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */'
  if [[ "$requirement" != "$requirement_prefix"*"$requirement_suffix" ]]; then
    fail "$product_name designated requirement is not identifier-specific Apple Development code"
  fi
  development_common_name="${requirement#"$requirement_prefix"}"
  development_common_name="${development_common_name%"$requirement_suffix"}"
  [[ -n "$development_common_name" &&
     "$development_common_name" != *'"'* &&
     "$development_common_name" != *$'\n'* &&
     "$development_common_name" != *$'\t'* &&
     "$requirement" == "$requirement_prefix$development_common_name$requirement_suffix" ]] ||
    fail "$product_name designated requirement has malformed Apple Development identity text"
  /usr/bin/printf '%s\n' "$requirement" >"$normalized"
  sha256_file "$normalized"
}

extract_signed_entitlements() {
  local product_path="$1"
  local product_name="$2"
  local output="$scratch_root/$product_name-entitlements.plist"

  "$codesign_command" -d --entitlements :- "$product_path" >"$output" 2>/dev/null ||
    fail "could not read $product_name signed entitlements"
  /usr/bin/plutil -lint "$output" >/dev/null 2>&1 ||
    fail "$product_name signed entitlements are malformed"
  printf '%s\n' "$output"
}

app_metadata="$(signed_metadata "$app_path" app)"
extension_metadata="$(signed_metadata "$extension_path" extension)"
helper_metadata="$(signed_metadata "$helper_path" helper)"
renderer_metadata="$(signed_metadata "$renderer_path" renderer)"
control_tool_metadata="$(signed_metadata "$control_tool_executable" control-tool)"
validate_release_signature_metadata "$app_metadata" app
validate_release_signature_metadata "$extension_metadata" extension
validate_release_signature_metadata "$helper_metadata" helper
validate_release_signature_metadata "$renderer_metadata" renderer
validate_release_signature_metadata "$control_tool_metadata" control-tool
app_signing_identifier="$(exact_signed_field "$app_metadata" app Identifier)"
extension_signing_identifier="$(exact_signed_field "$extension_metadata" extension Identifier)"
helper_signing_identifier="$(exact_signed_field "$helper_metadata" helper Identifier)"
renderer_signing_identifier="$(exact_signed_field "$renderer_metadata" renderer Identifier)"
control_tool_signing_identifier="$(exact_signed_field "$control_tool_metadata" control-tool Identifier)"
[[ "$app_signing_identifier" == "$expected_app_identifier" ]] || fail "app signing identifier drifted"
[[ "$extension_signing_identifier" == "$expected_extension_identifier" ]] || fail "extension signing identifier drifted"
[[ "$helper_signing_identifier" == "$expected_helper_identifier" ]] || fail "helper signing identifier drifted"
[[ "$renderer_signing_identifier" == "$expected_renderer_identifier" ]] || fail "renderer signing identifier drifted"
[[ "$control_tool_signing_identifier" == "$expected_control_tool_identifier" ]] || fail "control-tool signing identifier drifted"

app_team="$(exact_signed_field "$app_metadata" app TeamIdentifier)"
extension_team="$(exact_signed_field "$extension_metadata" extension TeamIdentifier)"
helper_team="$(exact_signed_field "$helper_metadata" helper TeamIdentifier)"
renderer_team="$(exact_signed_field "$renderer_metadata" renderer TeamIdentifier)"
control_tool_team="$(exact_signed_field "$control_tool_metadata" control-tool TeamIdentifier)"
[[ "$app_team" == "$expected_team_identifier" && "$extension_team" == "$app_team" && "$helper_team" == "$app_team" && "$renderer_team" == "$app_team" && "$control_tool_team" == "$app_team" ]] ||
  fail "app, extension, helper, control tool, and renderer do not share the exact expected TeamIdentifier"

app_cdhash="$(exact_signed_field "$app_metadata" app CDHash | /usr/bin/tr '[:upper:]' '[:lower:]')"
extension_cdhash="$(exact_signed_field "$extension_metadata" extension CDHash | /usr/bin/tr '[:upper:]' '[:lower:]')"
helper_cdhash="$(exact_signed_field "$helper_metadata" helper CDHash | /usr/bin/tr '[:upper:]' '[:lower:]')"
renderer_cdhash="$(exact_signed_field "$renderer_metadata" renderer CDHash | /usr/bin/tr '[:upper:]' '[:lower:]')"
control_tool_cdhash="$(exact_signed_field "$control_tool_metadata" control-tool CDHash | /usr/bin/tr '[:upper:]' '[:lower:]')"
for cdhash in "$app_cdhash" "$extension_cdhash" "$helper_cdhash" "$renderer_cdhash" "$control_tool_cdhash"; do
  [[ "$cdhash" =~ ^[0-9a-f]{40}$ ]] || fail "signed product CDHash is malformed"
done
app_designated_requirement_sha256="$(extract_designated_requirement "$app_path" app "$expected_app_identifier")"
extension_designated_requirement_sha256="$(extract_designated_requirement "$extension_path" extension "$expected_extension_identifier")"
helper_designated_requirement_sha256="$(extract_designated_requirement "$helper_path" helper "$expected_helper_identifier")"
renderer_designated_requirement_sha256="$(extract_designated_requirement "$renderer_path" renderer "$expected_renderer_identifier")"
control_tool_designated_requirement_sha256="$(extract_designated_requirement "$control_tool_executable" control-tool "$expected_control_tool_identifier")"
for requirement_sha in \
  "$app_designated_requirement_sha256" \
  "$extension_designated_requirement_sha256" \
  "$helper_designated_requirement_sha256" \
  "$renderer_designated_requirement_sha256" \
  "$control_tool_designated_requirement_sha256"; do
  [[ "$requirement_sha" =~ ^[0-9a-f]{64}$ ]] || fail "designated-requirement hash is malformed"
done

app_entitlements="$(extract_signed_entitlements "$app_path" app)"
extension_entitlements="$(extract_signed_entitlements "$extension_path" extension)"
helper_entitlements="$(extract_signed_entitlements "$helper_path" helper)"
control_tool_entitlements="$(extract_signed_entitlements "$control_tool_executable" control-tool)"

validate_exact_entitlements() {
  local entitlements="$1"
  local product_name="$2"
  local bundle_identifier="$3"
  local expected_kind="$4"
  local json="$scratch_root/$product_name-entitlements.json"

  /usr/bin/plutil -convert json -o "$json" "$entitlements" 2>/dev/null ||
    fail "could not decode $product_name signed entitlements"
  /usr/bin/jq -e \
    --arg team "$expected_team_identifier" \
    --arg application_identifier "$expected_team_identifier.$bundle_identifier" \
    --arg group "$expected_app_group" \
    --arg kind "$expected_kind" \
    '
      . as $root
      | (($root | has("com.apple.security.get-task-allow") | not)
          or (($root["com.apple.security.get-task-allow"] | type) == "boolean"
              and $root["com.apple.security.get-task-allow"] == false))
      and $root["com.apple.developer.team-identifier"] == $team
      and $root["com.apple.application-identifier"] == $application_identifier
      and $root["com.apple.security.application-groups"] == [$group]
      and (
        if $kind == "app" then
          $root["com.apple.security.device.camera"] == true
          and
          (($root | keys) - ["com.apple.security.get-task-allow"] | sort) ==
            (["com.apple.application-identifier", "com.apple.developer.team-identifier", "com.apple.security.application-groups", "com.apple.security.device.camera"] | sort)
        elif $kind == "extension" then
          $root["com.apple.security.app-sandbox"] == true
          and $root["com.apple.security.cs.disable-library-validation"] == true
          and $root["com.apple.security.temporary-exception.mach-lookup.global-name"] ==
            ["com.apple.CARenderServer", "com.apple.CoreDisplay.master", "com.apple.ViewBridgeAuxiliary"]
          and (($root | keys) - ["com.apple.security.get-task-allow"] | sort) ==
            (["com.apple.application-identifier", "com.apple.developer.team-identifier", "com.apple.security.app-sandbox", "com.apple.security.application-groups", "com.apple.security.cs.disable-library-validation", "com.apple.security.temporary-exception.mach-lookup.global-name"] | sort)
        elif $kind == "helper" then
          $root["com.apple.security.app-sandbox"] == true
          and $root["com.apple.security.device.camera"] == true
          and (($root | keys) - ["com.apple.security.get-task-allow"] | sort) ==
            (["com.apple.application-identifier", "com.apple.developer.team-identifier", "com.apple.security.app-sandbox", "com.apple.security.application-groups", "com.apple.security.device.camera"] | sort)
        else
          $root["com.apple.security.app-sandbox"] == true
          and (($root | keys) - ["com.apple.security.get-task-allow"] | sort) ==
            (["com.apple.application-identifier", "com.apple.developer.team-identifier", "com.apple.security.app-sandbox", "com.apple.security.application-groups"] | sort)
        end
      )
    ' "$json" >/dev/null ||
    fail "$product_name signed entitlements are not the exact Release entitlement set"
}

validate_exact_entitlements "$app_entitlements" app "$expected_app_identifier" app
validate_exact_entitlements "$extension_entitlements" extension "$expected_extension_identifier" extension
validate_exact_entitlements "$helper_entitlements" helper "$expected_helper_identifier" helper
validate_exact_entitlements "$control_tool_entitlements" control-tool "$expected_control_tool_identifier" control-tool

extract_signer_certificate() {
  local product_path="$1"
  local product_name="$2"
  local prefix="$scratch_root/$product_name-signing-certificate-"
  local certificate="${prefix}0"

  "$codesign_command" --display --extract-certificates="$prefix" "$product_path" >/dev/null 2>&1 ||
    fail "could not extract $product_name signing certificate"
  [[ -s "$certificate" ]] || fail "$product_name has no leaf signing certificate"
  printf '%s\n' "$certificate"
}

app_certificate="$(extract_signer_certificate "$app_path" app)"
extension_certificate="$(extract_signer_certificate "$extension_path" extension)"
helper_certificate="$(extract_signer_certificate "$helper_path" helper)"
renderer_certificate="$(extract_signer_certificate "$renderer_path" renderer)"
control_tool_certificate="$(extract_signer_certificate "$control_tool_executable" control-tool)"
if ! /usr/bin/cmp -s "$app_certificate" "$extension_certificate" ||
   ! /usr/bin/cmp -s "$app_certificate" "$helper_certificate" ||
   ! /usr/bin/cmp -s "$app_certificate" "$renderer_certificate" ||
   ! /usr/bin/cmp -s "$app_certificate" "$control_tool_certificate"; then
  fail "app, extension, helper, control tool, and renderer do not share one exact signing certificate"
fi
app_certificate_sha256="$(sha256_file "$app_certificate")"

current_epoch="$(/bin/date -u '+%s')"
[[ "$current_epoch" =~ ^[1-9][0-9]*$ ]] || fail "could not determine current time"

validate_profile() {
  local product_path="$1"
  local product_name="$2"
  local bundle_identifier="$3"
  local signer_certificate="$4"
  local profile="$product_path/Contents/embedded.provisionprofile"
  local decoded="$scratch_root/$product_name-profile.plist"
  local entitlements_json="$scratch_root/$product_name-profile-entitlements.json"
  local profile_team
  local uuid
  local expiration
  local profile_sha

  [[ -f "$profile" ]] || fail "$product_name is missing embedded.provisionprofile"
  "$security_command" cms -D -i "$profile" -o "$decoded" >/dev/null 2>&1 ||
    fail "could not CMS-decode $product_name provisioning profile"
  /usr/bin/plutil -lint "$decoded" >/dev/null 2>&1 ||
    fail "$product_name provisioning profile is malformed"
  profile_team="$(plist_raw "$decoded" TeamIdentifier.0)"
  [[ "$profile_team" == "$expected_team_identifier" ]] ||
    fail "$product_name provisioning profile TeamIdentifier drifted"
  if /usr/bin/plutil -extract TeamIdentifier.1 raw "$decoded" >/dev/null 2>&1; then
    fail "$product_name provisioning profile contains multiple TeamIdentifiers"
  fi
  /usr/bin/plutil -extract Entitlements json -o "$entitlements_json" "$decoded" 2>/dev/null ||
    fail "could not decode $product_name provisioning profile entitlements"
  /usr/bin/jq -e \
    --arg team "$expected_team_identifier" \
    --arg application_identifier "$expected_team_identifier.$bundle_identifier" \
    --arg group "$expected_app_group" \
    '
      .["com.apple.developer.team-identifier"] == $team
      and .["com.apple.application-identifier"] == $application_identifier
      and ((has("get-task-allow") | not)
           or ((.["get-task-allow"] | type) == "boolean"
               and .["get-task-allow"] == false))
      and (.["com.apple.security.application-groups"] | type) == "array"
      and ([.["com.apple.security.application-groups"][] | select(. == $group)] | length) == 1
      and ([.["com.apple.security.application-groups"][] | select(. != $group and . != ($team + ".*"))] | length) == 0
      and ([.["com.apple.security.application-groups"][] | select(. == ($team + ".*"))] | length) <= 1
    ' "$entitlements_json" >/dev/null ||
    fail "$product_name provisioning profile does not exactly authorize its Team, application ID, App Group, and Release task policy"
  camera_agent_profile_is_current "$decoded" "$current_epoch" ||
    fail "$product_name provisioning profile is expired or has an invalid ExpirationDate"
  camera_agent_profile_authorizes_signer \
    "$decoded" "$signer_certificate" "$scratch_root/$product_name-profile-certificates" ||
    fail "$product_name provisioning profile does not authorize its exact signer"
  uuid="$(plist_raw "$decoded" UUID)"
  [[ "$uuid" =~ ^[0-9A-Fa-f-]{36}$ ]] || fail "$product_name provisioning profile UUID is malformed"
  expiration="$(plist_raw "$decoded" ExpirationDate)"
  profile_sha="$(sha256_file "$profile")"
  printf '%s\t%s\t%s\n' "$profile_sha" "$uuid" "$expiration"
}

app_profile_record="$(validate_profile "$app_path" app "$expected_app_identifier" "$app_certificate")"
extension_profile_record="$(validate_profile "$extension_path" extension "$expected_extension_identifier" "$extension_certificate")"
helper_profile_record="$(validate_profile "$helper_path" helper "$expected_helper_identifier" "$helper_certificate")"
IFS=$'\t' read -r app_profile_sha256 app_profile_uuid app_profile_expiration <<<"$app_profile_record"
IFS=$'\t' read -r extension_profile_sha256 extension_profile_uuid extension_profile_expiration <<<"$extension_profile_record"
IFS=$'\t' read -r helper_profile_sha256 helper_profile_uuid helper_profile_expiration <<<"$helper_profile_record"
for profile_sha in "$app_profile_sha256" "$extension_profile_sha256" "$helper_profile_sha256"; do
  [[ "$profile_sha" =~ ^[0-9a-f]{64}$ ]] || fail "provisioning profile hash is malformed"
done

app_entitlements_sha256="$(sha256_file "$app_entitlements")"
extension_entitlements_sha256="$(sha256_file "$extension_entitlements")"
helper_entitlements_sha256="$(sha256_file "$helper_entitlements")"
control_tool_entitlements_sha256="$(sha256_file "$control_tool_entitlements")"

canonical_archive_inventory "$archive_inventory_after"
/usr/bin/cmp -s "$archive_inventory_before" "$archive_inventory_after" ||
  fail "archive changed while provenance verification was running"
[[ "$(sha256_file "$archive_inventory_after")" == "$archive_tree_sha256" ]] ||
  fail "archive tree hash changed while provenance verification was running"

manifest_temp="$(mktemp "$output_parent/.idlescreen-release-provenance.XXXXXX")"
/bin/chmod 600 "$manifest_temp"
{
  printf 'schema=IdleScreenReleaseArchiveProvenance/v1\n'
  if $fixture_mode; then
    printf 'verification_mode=fixture\n'
  else
    printf 'verification_mode=release\n'
  fi
  printf 'archive_tree_sha256=%s\n' "$archive_tree_sha256"
  printf 'team_identifier=%s\n' "$expected_team_identifier"
  printf 'app_group=%s\n' "$expected_app_group"
  printf 'mach_service=%s\n' "$expected_mach_service"
  printf 'camera_usage_description_sha256=%s\n' "$purpose_sha256"
  printf 'launch_agent_sha256=%s\n' "$launch_agent_sha256"
  printf 'signer_certificate_sha256=%s\n' "$app_certificate_sha256"
  printf 'app_bundle_identifier=%s\n' "$expected_app_identifier"
  printf 'app_cdhash=%s\n' "$app_cdhash"
  printf 'app_designated_requirement_sha256=%s\n' "$app_designated_requirement_sha256"
  printf 'app_entitlements_sha256=%s\n' "$app_entitlements_sha256"
  printf 'app_profile_sha256=%s\n' "$app_profile_sha256"
  printf 'app_profile_uuid=%s\n' "$app_profile_uuid"
  printf 'app_profile_expiration=%s\n' "$app_profile_expiration"
  printf 'extension_bundle_identifier=%s\n' "$expected_extension_identifier"
  printf 'extension_cdhash=%s\n' "$extension_cdhash"
  printf 'extension_designated_requirement_sha256=%s\n' "$extension_designated_requirement_sha256"
  printf 'extension_entitlements_sha256=%s\n' "$extension_entitlements_sha256"
  printf 'extension_profile_sha256=%s\n' "$extension_profile_sha256"
  printf 'extension_profile_uuid=%s\n' "$extension_profile_uuid"
  printf 'extension_profile_expiration=%s\n' "$extension_profile_expiration"
  printf 'helper_bundle_identifier=%s\n' "$expected_helper_identifier"
  printf 'helper_cdhash=%s\n' "$helper_cdhash"
  printf 'helper_designated_requirement_sha256=%s\n' "$helper_designated_requirement_sha256"
  printf 'helper_entitlements_sha256=%s\n' "$helper_entitlements_sha256"
  printf 'helper_profile_sha256=%s\n' "$helper_profile_sha256"
  printf 'helper_profile_uuid=%s\n' "$helper_profile_uuid"
  printf 'helper_profile_expiration=%s\n' "$helper_profile_expiration"
  printf 'renderer_bundle_identifier=%s\n' "$expected_renderer_identifier"
  printf 'renderer_cdhash=%s\n' "$renderer_cdhash"
  printf 'renderer_designated_requirement_sha256=%s\n' "$renderer_designated_requirement_sha256"
  printf 'control_tool_signing_identifier=%s\n' "$control_tool_signing_identifier"
  printf 'control_tool_cdhash=%s\n' "$control_tool_cdhash"
  printf 'control_tool_designated_requirement_sha256=%s\n' "$control_tool_designated_requirement_sha256"
  printf 'control_tool_entitlements_sha256=%s\n' "$control_tool_entitlements_sha256"
} >"$manifest_temp"

/bin/mv "$manifest_temp" "$output_manifest"
manifest_temp=""
echo "PASS: exact signed Release archive provenance is bound to SHA-256 $archive_tree_sha256."
if $fixture_mode; then
  echo "INFO: fixture-mode evidence is parser coverage and is not Release provenance."
fi
