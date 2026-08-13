#!/bin/bash

set -euo pipefail

script_root="$(cd "$(dirname "$0")" && pwd)"
profile_policy="$script_root/camera-agent-profile-policy.sh"
[[ -f "$profile_policy" ]] || {
  echo "FAIL: missing camera-agent profile policy library" >&2
  exit 1
}
# shellcheck source=camera-agent-profile-policy.sh
source "$profile_policy"

usage() {
  echo "Usage: $0 /absolute/path/to/IdleScreen.app Debug|Release" >&2
  exit 64
}

[[ $# -eq 2 ]] || usage

app_path="$1"
configuration="$2"
[[ "$app_path" = /* ]] || usage
[[ "$configuration" == Debug || "$configuration" == Release ]] || usage

expected_team_identifier="3524374A2S"
expected_mailbox="camera-frames-v1.mailbox"
expected_usage_description="idlescreen uses the camera only for camera-based screen saver effects you explicitly enable."
expected_display_name="idlescreen"
expected_control_tool_identifier="com.idlescreen.ctl"
expected_bundle_program="Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
expected_process_type="Interactive"

if [[ "$configuration" == Release ]]; then
  expected_app_identifier="com.idlescreen.app"
  expected_extension_identifier="com.idlescreen.app.screensaver"
  expected_agent_identifier="com.idlescreen.camera-agent"
  expected_app_group="group.com.idlescreen.shared"
  expected_mach_service="group.com.idlescreen.shared.camera-agent"
  opposite_mach_service="group.com.idlescreen.dev.shared.camera-agent"
  expected_associated_bundle_identifier="com.idlescreen.app"
else
  expected_app_identifier="com.idlescreen.app.dev"
  expected_extension_identifier="com.idlescreen.app.dev.screensaver"
  expected_agent_identifier="com.idlescreen.camera-agent.dev"
  expected_app_group="group.com.idlescreen.dev.shared"
  expected_mach_service="group.com.idlescreen.dev.shared.camera-agent"
  opposite_mach_service="group.com.idlescreen.shared.camera-agent"
  expected_associated_bundle_identifier="com.idlescreen.app.dev"
fi

app_info="$app_path/Contents/Info.plist"
app_executable="$app_path/Contents/MacOS/IdleScreen"
renderer_executable="$app_path/Contents/Frameworks/IdleScreenRenderer.framework/Versions/A/IdleScreenRenderer"
extension_path="$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex"
extension_info="$extension_path/Contents/Info.plist"
extension_executable="$extension_path/Contents/MacOS/IdleScreenScreenSaver"
helper_path="$app_path/Contents/Helpers/IdleScreenCameraAgent.app"
helper_info="$helper_path/Contents/Info.plist"
helper_executable="$helper_path/Contents/MacOS/IdleScreenCameraAgent"
control_tool_executable="$app_path/Contents/Helpers/idlescreenctl"
launch_agents_path="$app_path/Contents/Library/LaunchAgents"
expected_agent_plist="$launch_agents_path/$expected_mach_service.plist"
opposite_agent_plist="$launch_agents_path/$opposite_mach_service.plist"
scratch_root="$(mktemp -d /tmp/idlescreen-camera-agent-product.XXXXXX)"
trap '/bin/rm -rf "$scratch_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

plist_value() {
  /usr/bin/plutil -extract "$2" raw "$1" 2>/dev/null ||
    fail "could not read $2 from $1"
}

expect_plist_value() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local actual

  actual="$(plist_value "$plist" "$key")"
  [[ "$actual" == "$expected" ]] ||
    fail "unexpected $key in $plist: '$actual' (expected '$expected')"
}

extract_entitlements() {
  local product_path="$1"
  local product_name="$2"
  local output="$3"

  /usr/bin/codesign -d --entitlements :- "$product_path" >"$output" 2>/dev/null ||
    fail "could not read $product_name entitlements"
  /usr/bin/plutil -lint "$output" >/dev/null 2>&1 ||
    fail "$product_name entitlements are not a valid property list"
}

expect_true_entitlement() {
  local entitlements="$1"
  local product_name="$2"
  local key="$3"
  local value

  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$entitlements" 2>/dev/null || true)"
  [[ "$value" == true ]] || fail "$product_name $key entitlement is not true"
}

expect_absent_entitlement() {
  local entitlements="$1"
  local product_name="$2"
  local key="$3"

  if /usr/libexec/PlistBuddy -c "Print :$key" "$entitlements" >/dev/null 2>&1; then
    fail "$product_name must not carry the $key entitlement"
  fi
}

signed_value() {
  local product_path="$1"
  local key="$2"

  /usr/bin/codesign -dv --verbose=4 "$product_path" 2>&1 |
    /usr/bin/awk -F= -v key="$key" '$1 == key { print $2; exit }'
}

expect_camera_free_binary() {
  local executable="$1"
  local product_name="$2"
  local architecture
  local architecture_count
  local architectures
  local inspected_executable

  [[ -x "$executable" ]] || fail "missing $product_name executable: $executable"
  if /usr/bin/otool -L "$executable" |
     /usr/bin/grep -Fq AVFoundation; then
    fail "$product_name must not link AVFoundation"
  fi

  architectures="$(/usr/bin/lipo -archs "$executable" 2>/dev/null)" ||
    fail "could not inspect $product_name architectures"
  [[ -n "$architectures" ]] || fail "$product_name contains no Mach-O architecture"
  architecture_count="$(/usr/bin/awk '{ print NF }' <<<"$architectures")"
  for architecture in $architectures; do
    inspected_executable="$executable"
    if ((architecture_count > 1)); then
      inspected_executable="$scratch_root/${product_name// /-}-$architecture"
      /usr/bin/lipo "$executable" -thin "$architecture" -output "$inspected_executable" 2>/dev/null ||
        fail "could not inspect $product_name architecture $architecture"
    fi
    if /usr/bin/strings -a "$inspected_executable" |
       /usr/bin/grep -E 'AVCapture|AVFoundation|requestAccessForMediaType|requestAccess' >/dev/null; then
      fail "$product_name contains a camera API or authorization-request symbol"
    fi
    if /usr/bin/nm -u "$inspected_executable" 2>/dev/null |
       /usr/bin/grep -Eq 'AVCapture|requestAccess'; then
      fail "$product_name imports a camera or authorization-request symbol"
    fi
  done
}

expect_no_synthetic_hosted_marker() {
  local executable="$1"
  local product_name="$2"

  if /usr/bin/strings -a "$executable" |
     /usr/bin/grep -E 'IdleScreenSyntheticHostedGateVersion|IdleScreenSyntheticHostedGateViewController|IdleScreenSyntheticHostedGateViewFactory' >/dev/null; then
    fail "$product_name contains a synthetic hosted-gate marker or symbol"
  fi
}

enumerate_macho_relative_paths() {
  local product_root="$1"
  local candidate
  local relative

  /usr/bin/find "$product_root" -type f -print0 |
    while IFS= read -r -d '' candidate; do
      if /usr/bin/file -b "$candidate" | /usr/bin/grep -F 'Mach-O' >/dev/null; then
        relative="${candidate#"$product_root"/}"
        printf '%s\n' "$relative"
      fi
    done | LC_ALL=C /usr/bin/sort
}

expect_exact_production_macho_paths() {
  local actual
  local expected
  local relative

  expected="$({
    printf '%s\n' \
      Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent \
      Contents/Helpers/idlescreenctl \
      Contents/Frameworks/IdleScreenRenderer.framework/Versions/A/IdleScreenRenderer \
      Contents/MacOS/IdleScreen \
      Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver
  } | LC_ALL=C /usr/bin/sort)"
  actual="$(enumerate_macho_relative_paths "$app_path")"
  while IFS= read -r relative; do
    [[ -n "$relative" ]] || continue
    if ! /usr/bin/grep -Fx "$relative" <<<"$expected" >/dev/null; then
      fail "unexpected Mach-O code in production product: $relative"
    fi
  done <<<"$actual"
  [[ "$actual" == "$expected" ]] ||
    fail "production product does not contain exactly the app/renderer/helper/control-tool/extension executables"
}

[[ -d "$app_path" ]] || fail "missing app bundle: $app_path"
[[ -f "$app_info" ]] || fail "missing app Info.plist"
[[ -d "$extension_path" ]] || fail "missing embedded screen saver extension"
[[ -f "$extension_info" ]] || fail "missing embedded screen saver Info.plist"
[[ -d "$launch_agents_path" ]] || fail "missing Contents/Library/LaunchAgents"
expect_exact_production_macho_paths

expect_plist_value "$app_info" CFBundleIdentifier "$expected_app_identifier"
expect_plist_value "$app_info" NSCameraUsageDescription "$expected_usage_description"
expect_plist_value "$extension_info" CFBundleIdentifier "$expected_extension_identifier"
if /usr/libexec/PlistBuddy \
  -c 'Print :IdleScreenSyntheticHostedGateVersion' "$extension_info" >/dev/null 2>&1; then
  fail "production extension must not carry IdleScreenSyntheticHostedGateVersion"
fi
expect_camera_free_binary "$app_executable" "production companion"
expect_camera_free_binary "$renderer_executable" "production renderer"
expect_camera_free_binary "$extension_executable" "production screen-saver"
expect_camera_free_binary "$control_tool_executable" "production control tool"
expect_no_synthetic_hosted_marker "$app_executable" "production companion"
expect_no_synthetic_hosted_marker "$renderer_executable" "production renderer"
expect_no_synthetic_hosted_marker "$extension_executable" "production screen-saver"

[[ ! -e "$opposite_agent_plist" ]] ||
  fail "found opposite-configuration LaunchAgent plist: $opposite_agent_plist"
camera_agent_plist_count="$(
  /usr/bin/find "$launch_agents_path" -maxdepth 1 -type f -name '*camera-agent.plist' -print |
    /usr/bin/awk 'END { print NR + 0 }'
)"
[[ "$camera_agent_plist_count" == 1 && -f "$expected_agent_plist" ]] ||
  fail "expected exactly one camera LaunchAgent plist: $expected_agent_plist"

expect_plist_value "$expected_agent_plist" Label "$expected_mach_service"
actual_associated_bundle_identifier="$(/usr/libexec/PlistBuddy \
  -c 'Print :AssociatedBundleIdentifiers' "$expected_agent_plist" 2>/dev/null || true)"
[[ "$actual_associated_bundle_identifier" == "$expected_associated_bundle_identifier" ]] ||
  fail "unexpected AssociatedBundleIdentifiers in $expected_agent_plist: '$actual_associated_bundle_identifier' (expected '$expected_associated_bundle_identifier')"
expect_plist_value "$expected_agent_plist" BundleProgram "$expected_bundle_program"
expect_plist_value "$expected_agent_plist" ProcessType "$expected_process_type"
mach_services_plist="$scratch_root/mach-services.plist"
/usr/bin/plutil -extract MachServices xml1 -o "$mach_services_plist" "$expected_agent_plist" 2>/dev/null ||
  fail "LaunchAgent plist has no MachServices dictionary"
mach_service_count="$(/usr/bin/awk '/<key>.*<\/key>/ { count += 1 } END { print count + 0 }' "$mach_services_plist")"
[[ "$mach_service_count" == 1 ]] ||
  fail "LaunchAgent MachServices must contain exactly one service"
[[ "$(/usr/libexec/PlistBuddy -c "Print :MachServices:$expected_mach_service" "$expected_agent_plist" 2>/dev/null || true)" == true ]] ||
  fail "LaunchAgent MachServices does not enable $expected_mach_service"

[[ -d "$helper_path" && -f "$helper_info" && -x "$helper_executable" ]] ||
  fail "missing GUI-less camera-agent app bundle: $helper_path"
if /usr/libexec/PlistBuddy \
  -c 'Print :IdleScreenSyntheticGateVersion' "$helper_info" >/dev/null 2>&1; then
  fail "production camera helper must not carry IdleScreenSyntheticGateVersion"
fi
[[ ! -d "$helper_path/Contents/Frameworks" ]] ||
  fail "camera helper must not embed static framework copies"
helper_bundle_count="$(
  /usr/bin/find "$app_path/Contents" -type d -name IdleScreenCameraAgent.app -print |
    /usr/bin/awk 'END { print NR + 0 }'
)"
helper_executable_count="$(
  /usr/bin/find "$app_path/Contents" -type f -name IdleScreenCameraAgent -print |
    /usr/bin/awk 'END { print NR + 0 }'
)"
[[ "$helper_bundle_count" == 1 && "$helper_executable_count" == 1 ]] ||
  fail "unexpected camera helper copy; expected only $helper_path"

helper_architectures="$(/usr/bin/lipo -archs "$helper_executable" 2>/dev/null)" ||
  fail "could not inspect helper architectures"
[[ -n "$helper_architectures" ]] || fail "helper contains no Mach-O architecture"
architecture_count="$(/usr/bin/awk '{ print NF }' <<<"$helper_architectures")"
for architecture in $helper_architectures; do
  architecture_helper="$helper_executable"
  if ((architecture_count > 1)); then
    architecture_helper="$scratch_root/helper-$architecture"
    /usr/bin/lipo "$helper_executable" -thin "$architecture" -output "$architecture_helper" 2>/dev/null ||
      fail "could not inspect helper architecture $architecture"
  fi
  if /usr/bin/strings -a "$architecture_helper" |
     /usr/bin/grep -Eq 'IdleScreenSyntheticGateVersion|SyntheticCameraCaptureController|bootstrapSynthetic'; then
    fail "production camera helper contains a synthetic gate marker or symbol"
  fi
done

expect_plist_value "$helper_info" CFBundleIdentifier "$expected_agent_identifier"
expect_plist_value "$helper_info" CFBundleName "$expected_display_name"
expect_plist_value "$helper_info" CFBundleDisplayName "$expected_display_name"
expect_plist_value "$helper_info" CFBundlePackageType APPL
expect_plist_value "$helper_info" LSBackgroundOnly true
expect_plist_value "$helper_info" LSUIElement true
expect_plist_value "$helper_info" IdleScreenCameraAgentMachServiceName "$expected_mach_service"
expect_plist_value "$helper_info" IdleScreenCameraAgentAppGroupIdentifier "$expected_app_group"
expect_plist_value "$helper_info" IdleScreenCameraAgentTeamIdentifier "$expected_team_identifier"
expect_plist_value "$helper_info" IdleScreenCameraAgentMailboxFileName "$expected_mailbox"
expect_plist_value "$helper_info" NSCameraUsageDescription "$expected_usage_description"
expect_plist_value "$helper_info" NSCameraUseContinuityCameraDeviceType true

/usr/bin/codesign --verify --strict "$helper_path" >/dev/null 2>&1 ||
  fail "camera helper signature verification failed"
/usr/bin/codesign --verify --strict "$extension_path" >/dev/null 2>&1 ||
  fail "screen saver signature verification failed"
/usr/bin/codesign --verify --strict "$control_tool_executable" >/dev/null 2>&1 ||
  fail "control-tool signature verification failed"

helper_entitlements="$scratch_root/helper-entitlements.plist"
app_entitlements="$scratch_root/app-entitlements.plist"
extension_entitlements="$scratch_root/extension-entitlements.plist"
control_tool_entitlements="$scratch_root/control-tool-entitlements.plist"
extract_entitlements "$helper_path" camera-helper "$helper_entitlements"
extract_entitlements "$app_path" app "$app_entitlements"
extract_entitlements "$extension_path" screen-saver "$extension_entitlements"
extract_entitlements "$control_tool_executable" control-tool "$control_tool_entitlements"

expect_true_entitlement "$helper_entitlements" camera-helper com.apple.security.app-sandbox
expect_true_entitlement "$helper_entitlements" camera-helper com.apple.security.device.camera
if [[ "$configuration" == Release ]]; then
  helper_app_group="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :com.apple.security.application-groups:0' \
      "$helper_entitlements" 2>/dev/null || true
  )"
  [[ "$helper_app_group" == "$expected_app_group" ]] ||
    fail "camera-helper App Group entitlement is not exactly $expected_app_group"
  if /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.application-groups:1' \
    "$helper_entitlements" >/dev/null 2>&1; then
    fail "camera-helper carries unexpected additional App Group entitlements"
  fi
fi
expect_true_entitlement "$app_entitlements" app com.apple.security.device.camera
expect_absent_entitlement "$extension_entitlements" screen-saver com.apple.security.device.camera
expect_true_entitlement "$control_tool_entitlements" control-tool com.apple.security.app-sandbox
control_tool_app_group="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.application-groups:0' \
    "$control_tool_entitlements" 2>/dev/null || true
)"
[[ "$control_tool_app_group" == "$expected_app_group" ]] ||
  fail "control-tool App Group entitlement is not exactly $expected_app_group"
if /usr/libexec/PlistBuddy \
  -c 'Print :com.apple.security.application-groups:1' \
  "$control_tool_entitlements" >/dev/null 2>&1; then
  fail "control-tool carries unexpected additional App Group entitlements"
fi
expect_absent_entitlement "$control_tool_entitlements" control-tool com.apple.security.device.camera
[[ "$(signed_value "$control_tool_executable" Identifier)" == "$expected_control_tool_identifier" ]] ||
  fail "control-tool signing identifier is not $expected_control_tool_identifier"

app_team="$(signed_value "$app_path" TeamIdentifier)"
extension_team="$(signed_value "$extension_path" TeamIdentifier)"
helper_team="$(signed_value "$helper_path" TeamIdentifier)"
control_tool_team="$(signed_value "$control_tool_executable" TeamIdentifier)"
app_signature="$(signed_value "$app_path" Signature)"
extension_signature="$(signed_value "$extension_path" Signature)"
helper_signature="$(signed_value "$helper_path" Signature)"
control_tool_signature="$(signed_value "$control_tool_executable" Signature)"

if [[ "$configuration" == Release ]]; then
  [[ "$app_team" == "$expected_team_identifier" ]] ||
    fail "Release app TeamIdentifier='$app_team', expected $expected_team_identifier"
  [[ "$extension_team" == "$expected_team_identifier" ]] ||
    fail "Release screen saver TeamIdentifier='$extension_team', expected $expected_team_identifier"
  [[ "$helper_team" == "$expected_team_identifier" ]] ||
    fail "Release camera helper TeamIdentifier='$helper_team', expected $expected_team_identifier"
  [[ "$control_tool_team" == "$expected_team_identifier" ]] ||
    fail "Release control tool TeamIdentifier='$control_tool_team', expected $expected_team_identifier"

  helper_profile="$helper_path/Contents/embedded.provisionprofile"
  helper_profile_plist="$scratch_root/helper-profile.plist"
  [[ -f "$helper_profile" ]] ||
    fail "Release camera helper is missing its own embedded provisioning profile"
  /usr/bin/security cms -D -i "$helper_profile" >"$helper_profile_plist" 2>/dev/null ||
    fail "could not decode Release camera helper provisioning profile"
  profile_application_identifier="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :Entitlements:com.apple.application-identifier' \
      "$helper_profile_plist" 2>/dev/null || true
  )"
  [[ "$profile_application_identifier" == "$expected_team_identifier.$expected_agent_identifier" ]] ||
    fail "Release camera helper profile application identifier is not $expected_team_identifier.$expected_agent_identifier"

  current_epoch="$(/bin/date -u '+%s')"
  camera_agent_profile_is_current "$helper_profile_plist" "$current_epoch" ||
    fail "Release camera helper profile has an invalid or expired ExpirationDate"

  helper_signing_certificate_prefix="$scratch_root/helper-signing-certificate-"
  /usr/bin/codesign --display \
    --extract-certificates="$helper_signing_certificate_prefix" \
    "$helper_path" >/dev/null 2>&1 ||
    fail "could not extract the Release camera helper signing certificate"
  helper_signing_certificate="${helper_signing_certificate_prefix}0"
  [[ -s "$helper_signing_certificate" ]] ||
    fail "Release camera helper has no leaf signing certificate"

  camera_agent_profile_authorizes_signer \
    "$helper_profile_plist" \
    "$helper_signing_certificate" \
    "$scratch_root/profile-developer-certificates" ||
    fail "Release camera helper signer is not authorized by the provisioning profile"

  camera_agent_profile_authorizes_app_group \
    "$helper_profile_plist" "$expected_app_group" "$expected_team_identifier" ||
    fail "Release camera helper profile must contain exactly $expected_app_group and at most one team wildcard"
else
  if [[ "$app_signature" == adhoc && "$extension_signature" == adhoc && "$helper_signature" == adhoc && "$control_tool_signature" == adhoc ]]; then
    echo 'INFO: Debug signature identity is ad-hoc; mutual authentication is not physically usable with this artifact.'
  elif [[ -n "$app_team" && "$app_team" != 'not set' &&
          "$extension_team" == "$app_team" && "$helper_team" == "$app_team" &&
          "$control_tool_team" == "$app_team" ]]; then
    echo "PASS: Debug signatures share TeamIdentifier=$app_team."
  else
    fail "Debug app, screen saver, helper, and control-tool signatures have inconsistent identities"
  fi
fi

/usr/bin/codesign --verify --deep --strict "$app_path" >/dev/null 2>&1 ||
  fail "deep app signature verification failed"

echo "PASS: $configuration camera-agent bundle structure and embedded configuration are exact."
echo 'PASS: only the camera helper carries camera APIs, and all nested signatures verify.'
