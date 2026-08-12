#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/production/IdleScreen.app /absolute/path/to/gate/IdleScreen.app Debug|Release [manifest.txt]" >&2
  exit 64
}

[[ $# -eq 3 || $# -eq 4 ]] || usage
production_app="$1"
gate_app="$2"
configuration="$3"
expected_manifest="${4:-}"
[[ "$production_app" = /* && "$gate_app" = /* ]] || usage
[[ "$configuration" == Debug || "$configuration" == Release ]] || usage
[[ -z "$expected_manifest" || "$expected_manifest" = /* ]] || usage

project_root="$(cd "$(dirname "$0")/.." && pwd)"
manifest_tool="$project_root/scripts/create-synthetic-gate-manifest.sh"
profile_policy="$project_root/scripts/camera-agent-profile-policy.sh"
scratch_root="$(mktemp -d /tmp/idlescreen-synthetic-product.XXXXXX)"
trap '/bin/rm -rf "$scratch_root"' EXIT
[[ -f "$profile_policy" ]] || {
  echo "FAIL: missing camera-agent profile policy library" >&2
  exit 1
}
# shellcheck source=camera-agent-profile-policy.sh
source "$profile_policy"

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

expect_absent_plist_key() {
  if /usr/libexec/PlistBuddy -c "Print :$2" "$1" >/dev/null 2>&1; then
    fail "$1 must not contain $2"
  fi
}

extract_entitlements() {
  /usr/bin/codesign -d --entitlements :- "$1" >"$2" 2>/dev/null ||
    fail "could not read entitlements from $1"
  /usr/bin/plutil -lint "$2" >/dev/null 2>&1 ||
    fail "invalid entitlements extracted from $1"
}

signed_value() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 |
    /usr/bin/awk -F= -v key="$2" '$1 == key { print $2; exit }'
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

expect_only_macho_path() {
  local product_root="$1"
  local expected="$2"
  local product_name="$3"
  local actual
  local relative

  actual="$(enumerate_macho_relative_paths "$product_root")"
  while IFS= read -r relative; do
    [[ -n "$relative" ]] || continue
    if [[ "$relative" != "$expected" ]]; then
      fail "$product_name contains unexpected Mach-O code: $relative"
    fi
  done <<<"$actual"
  [[ "$actual" == "$expected" ]] ||
    fail "$product_name does not contain exactly its expected executable"
}

if [[ "$configuration" == Release ]]; then
  expected_app_identifier="com.idlescreen.app"
  expected_extension_identifier="com.idlescreen.app.screensaver"
  expected_agent_identifier="com.idlescreen.camera-agent"
  expected_app_group="group.com.idlescreen.shared"
  expected_mach_service="group.com.idlescreen.shared.camera-agent"
  expected_associated_app="com.idlescreen.app"
else
  expected_app_identifier="com.idlescreen.app.dev"
  expected_extension_identifier="com.idlescreen.app.dev.screensaver"
  expected_agent_identifier="com.idlescreen.camera-agent.dev"
  expected_app_group="group.com.idlescreen.dev.shared"
  expected_mach_service="group.com.idlescreen.dev.shared.camera-agent"
  expected_associated_app="com.idlescreen.app.dev"
fi

helper_relative="Contents/Helpers/IdleScreenCameraAgent.app"
extension_relative="Contents/PlugIns/IdleScreenScreenSaver.appex"
launch_agent_relative="Contents/Library/LaunchAgents/$expected_mach_service.plist"
production_helper="$production_app/$helper_relative"
gate_helper="$gate_app/$helper_relative"
gate_helper_info="$gate_helper/Contents/Info.plist"
gate_helper_executable="$gate_helper/Contents/MacOS/IdleScreenCameraAgent"
production_extension="$production_app/$extension_relative"
gate_extension="$gate_app/$extension_relative"
production_extension_info="$production_extension/Contents/Info.plist"
gate_extension_info="$gate_extension/Contents/Info.plist"
gate_extension_executable="$gate_extension/Contents/MacOS/IdleScreenScreenSaver"
gate_launch_agent="$gate_app/$launch_agent_relative"

[[ -x "$manifest_tool" ]] || fail "missing manifest tool"
[[ -d "$production_app" && -d "$gate_app" ]] || fail "missing production or gate app"
[[ -d "$production_helper" && -d "$gate_helper" ]] || fail "missing production or gate helper"
[[ -f "$gate_helper_info" && -x "$gate_helper_executable" ]] ||
  fail "gate helper is incomplete"
[[ -d "$production_extension" && -d "$gate_extension" && -f "$gate_launch_agent" ]] ||
  fail "gate lacks the production reference, hosted-gate extension, or LaunchAgent"
[[ -f "$production_extension_info" && -f "$gate_extension_info" && -x "$gate_extension_executable" ]] ||
  fail "hosted-gate extension is incomplete"
expect_only_macho_path "$gate_helper" \
  Contents/MacOS/IdleScreenCameraAgent "synthetic helper"
expect_only_macho_path "$gate_extension" \
  Contents/MacOS/IdleScreenScreenSaver "hosted-gate extension"

expect_plist_value "$gate_app/Contents/Info.plist" CFBundleIdentifier "$expected_app_identifier"
expect_plist_value "$gate_extension/Contents/Info.plist" CFBundleIdentifier \
  "$expected_extension_identifier"
expect_plist_value "$gate_extension_info" CFBundleExecutable IdleScreenScreenSaver
expect_plist_value "$gate_extension_info" CFBundlePackageType XPC!
expect_plist_value "$gate_extension_info" IdleScreenAppGroupIdentifier "$expected_app_group"
expect_plist_value "$gate_extension_info" IdleScreenCameraAgentAppGroupIdentifier \
  "$expected_app_group"
expect_plist_value "$gate_extension_info" IdleScreenCameraAgentMachServiceName \
  "$expected_mach_service"
expect_plist_value "$gate_extension_info" IdleScreenCameraAgentTeamIdentifier 3524374A2S
expect_plist_value "$gate_extension_info" IdleScreenSyntheticHostedGateVersion 1
expect_plist_value "$gate_extension_info" NSExtension.NSExtensionPointIdentifier \
  com.apple.screensaver
expect_plist_value "$gate_extension_info" NSExtension.NSExtensionPointVersion 1.0
expect_plist_value "$gate_extension_info" NSExtension.NSExtensionPrincipalClass \
  IdleScreenScreenSaver.IdleScreenScreenSaverExtension
expect_plist_value "$gate_extension_info" ScreenSaverViewControllerClass \
  IdleScreenScreenSaver.IdleScreenSyntheticHostedGateViewController
expect_absent_plist_key "$gate_extension_info" NSCameraUsageDescription
expect_absent_plist_key "$gate_extension_info" NSCameraUseContinuityCameraDeviceType
expect_plist_value "$gate_helper_info" CFBundleIdentifier "$expected_agent_identifier"
expect_plist_value "$gate_helper_info" CFBundleExecutable IdleScreenCameraAgent
expect_plist_value "$gate_helper_info" CFBundleName idlescreen
expect_plist_value "$gate_helper_info" CFBundleDisplayName idlescreen
expect_plist_value "$gate_helper_info" CFBundlePackageType APPL
expect_plist_value "$gate_helper_info" LSBackgroundOnly true
expect_plist_value "$gate_helper_info" LSUIElement true
expect_plist_value "$gate_helper_info" IdleScreenCameraAgentMachServiceName \
  "$expected_mach_service"
expect_plist_value "$gate_helper_info" IdleScreenCameraAgentAppGroupIdentifier \
  "$expected_app_group"
expect_plist_value "$gate_helper_info" IdleScreenCameraAgentTeamIdentifier 3524374A2S
expect_plist_value "$gate_helper_info" IdleScreenCameraAgentMailboxFileName \
  camera-frames-v1.mailbox
expect_plist_value "$gate_helper_info" IdleScreenSyntheticGateVersion 1
expect_absent_plist_key "$gate_helper_info" NSCameraUsageDescription
expect_absent_plist_key "$gate_helper_info" NSCameraUseContinuityCameraDeviceType

expect_plist_value "$gate_launch_agent" Label "$expected_mach_service"
expect_plist_value "$gate_launch_agent" AssociatedBundleIdentifiers "$expected_associated_app"
expect_plist_value "$gate_launch_agent" BundleProgram \
  Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent
expect_plist_value "$gate_launch_agent" ProcessType Interactive
[[ "$(/usr/libexec/PlistBuddy -c "Print :MachServices:$expected_mach_service" "$gate_launch_agent" 2>/dev/null || true)" == true ]] ||
  fail "gate LaunchAgent does not enable $expected_mach_service"

if /usr/bin/otool -L "$gate_helper_executable" |
   /usr/bin/grep -Eq 'AVFoundation|CoreMedia'; then
  fail "synthetic helper links a camera/media framework"
fi
if /usr/bin/strings -a "$gate_helper_executable" |
   /usr/bin/grep -Eq 'AVCapture|AVFoundation|requestAccessForMediaType|requestAccess'; then
  fail "synthetic helper contains a camera API or authorization-request symbol"
fi
for architecture in $(/usr/bin/lipo -archs "$gate_helper_executable"); do
  architecture_helper="$gate_helper_executable"
  if [[ "$(/usr/bin/lipo -archs "$gate_helper_executable" | /usr/bin/awk '{ print NF }')" -gt 1 ]]; then
    architecture_helper="$scratch_root/gate-helper-$architecture"
    /usr/bin/lipo "$gate_helper_executable" -thin "$architecture" \
      -output "$architecture_helper"
  fi
  if /usr/bin/nm -u "$architecture_helper" 2>/dev/null |
     /usr/bin/grep -Eq 'AVCapture|requestAccess'; then
    fail "synthetic helper imports a camera or authorization-request symbol"
  fi
done

if /usr/bin/otool -L "$gate_extension_executable" |
   /usr/bin/grep -Fq AVFoundation; then
  fail "hosted-gate extension links AVFoundation"
fi
if /usr/bin/strings -a "$gate_extension_executable" |
   /usr/bin/grep -E 'AVCapture|AVFoundation|requestAccessForMediaType|requestAccess' >/dev/null; then
  fail "hosted-gate extension contains a camera API or authorization-request symbol"
fi
for architecture in $(/usr/bin/lipo -archs "$gate_extension_executable"); do
  architecture_extension="$gate_extension_executable"
  if [[ "$(/usr/bin/lipo -archs "$gate_extension_executable" | /usr/bin/awk '{ print NF }')" -gt 1 ]]; then
    architecture_extension="$scratch_root/gate-extension-$architecture"
    /usr/bin/lipo "$gate_extension_executable" -thin "$architecture" \
      -output "$architecture_extension"
  fi
  if /usr/bin/nm -u "$architecture_extension" 2>/dev/null |
     /usr/bin/grep -Eq 'AVCapture|requestAccess'; then
    fail "hosted-gate extension imports a camera or authorization-request symbol"
  fi
done

/usr/bin/codesign --verify --strict "$gate_helper" >/dev/null 2>&1 ||
  fail "synthetic helper signature verification failed"
/usr/bin/codesign --verify --strict "$gate_extension" >/dev/null 2>&1 ||
  fail "hosted-gate extension signature verification failed"
/usr/bin/codesign --verify --deep --strict "$gate_app" >/dev/null 2>&1 ||
  fail "gate app deep signature verification failed"

helper_entitlements="$scratch_root/helper-entitlements.plist"
production_extension_entitlements="$scratch_root/production-extension-entitlements.plist"
gate_extension_entitlements="$scratch_root/gate-extension-entitlements.plist"
extract_entitlements "$gate_helper" "$helper_entitlements"
extract_entitlements "$production_extension" "$production_extension_entitlements"
extract_entitlements "$gate_extension" "$gate_extension_entitlements"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$helper_entitlements" 2>/dev/null || true)" == true ]] ||
  fail "synthetic helper must retain the sandbox entitlement"
if /usr/libexec/PlistBuddy \
  -c 'Print :com.apple.security.device.camera' "$helper_entitlements" >/dev/null 2>&1; then
  fail "synthetic helper must not carry the camera entitlement"
fi
if /usr/libexec/PlistBuddy \
  -c 'Print :com.apple.security.device.camera' "$gate_extension_entitlements" >/dev/null 2>&1; then
  fail "hosted-gate extension must not carry the camera entitlement"
fi
/usr/bin/plutil -convert xml1 "$production_extension_entitlements"
/usr/bin/plutil -convert xml1 "$gate_extension_entitlements"
/usr/bin/cmp -s "$production_extension_entitlements" "$gate_extension_entitlements" ||
  fail "hosted-gate extension entitlements differ from production"
if [[ "$configuration" == Release ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$helper_entitlements" 2>/dev/null || true)" == "$expected_app_group" ]] ||
    fail "synthetic helper must carry exactly the Release App Group"
  if /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.application-groups:1' "$helper_entitlements" >/dev/null 2>&1; then
    fail "synthetic helper carries an extra App Group"
  fi
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$gate_extension_entitlements" 2>/dev/null || true)" == "$expected_app_group" ]] ||
    fail "hosted-gate extension must carry exactly the Release App Group"
  if /usr/libexec/PlistBuddy \
    -c 'Print :com.apple.security.application-groups:1' "$gate_extension_entitlements" >/dev/null 2>&1; then
    fail "hosted-gate extension carries an extra App Group"
  fi

  gate_helper_team="$(signed_value "$gate_helper" TeamIdentifier)"
  gate_helper_identifier="$(signed_value "$gate_helper" Identifier)"
  gate_helper_signature="$(signed_value "$gate_helper" Signature)"
  [[ "$gate_helper_team" == 3524374A2S ]] ||
    fail "Release synthetic helper TeamIdentifier='$gate_helper_team', expected 3524374A2S"
  [[ "$gate_helper_identifier" == "$expected_agent_identifier" ]] ||
    fail "Release synthetic helper designated identifier is not $expected_agent_identifier"
  [[ "$gate_helper_signature" != adhoc && -n "$gate_helper_signature" ]] ||
    fail "Release synthetic helper must not be ad-hoc signed"

  gate_extension_team="$(signed_value "$gate_extension" TeamIdentifier)"
  gate_extension_identifier="$(signed_value "$gate_extension" Identifier)"
  gate_extension_signature="$(signed_value "$gate_extension" Signature)"
  [[ "$gate_extension_team" == 3524374A2S ]] ||
    fail "Release hosted-gate extension TeamIdentifier='$gate_extension_team', expected 3524374A2S"
  [[ "$gate_extension_identifier" == "$expected_extension_identifier" ]] ||
    fail "Release hosted-gate extension designated identifier is not $expected_extension_identifier"
  [[ "$gate_extension_signature" != adhoc && -n "$gate_extension_signature" ]] ||
    fail "Release hosted-gate extension must not be ad-hoc signed"

  signed_application_identifier="$(/usr/libexec/PlistBuddy \
    -c 'Print :com.apple.application-identifier' \
    "$helper_entitlements" 2>/dev/null || true)"
  [[ "$signed_application_identifier" == "3524374A2S.$expected_agent_identifier" ]] ||
    fail "Release synthetic helper signed application-identifier is not 3524374A2S.$expected_agent_identifier"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' \
    "$helper_entitlements" 2>/dev/null || true)" == 3524374A2S ]] ||
    fail "Release synthetic helper signed developer team identifier is not 3524374A2S"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' \
    "$gate_extension_entitlements" 2>/dev/null || true)" == \
    "3524374A2S.$expected_extension_identifier" ]] ||
    fail "Release hosted-gate extension signed application-identifier is not 3524374A2S.$expected_extension_identifier"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' \
    "$gate_extension_entitlements" 2>/dev/null || true)" == 3524374A2S ]] ||
    fail "Release hosted-gate extension signed developer team identifier is not 3524374A2S"

  helper_profile="$gate_helper/Contents/embedded.provisionprofile"
  helper_profile_plist="$scratch_root/helper-profile.plist"
  [[ -f "$helper_profile" ]] ||
    fail "Release synthetic helper is missing its embedded provisioning profile"
  /usr/bin/security cms -D -i "$helper_profile" >"$helper_profile_plist" 2>/dev/null ||
    fail "could not decode Release synthetic helper provisioning profile"
  profile_application_identifier="$(/usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:com.apple.application-identifier' \
    "$helper_profile_plist" 2>/dev/null || true)"
  [[ "$profile_application_identifier" == "3524374A2S.$expected_agent_identifier" ]] ||
    fail "Release synthetic helper profile application identifier is not exact"
  camera_agent_profile_is_current "$helper_profile_plist" "$(/bin/date -u '+%s')" ||
    fail "Release synthetic helper profile is invalid or expired"

  helper_signing_certificate_prefix="$scratch_root/helper-signing-certificate-"
  /usr/bin/codesign --display \
    --extract-certificates="$helper_signing_certificate_prefix" \
    "$gate_helper" >/dev/null 2>&1 ||
    fail "could not extract the Release synthetic helper signing certificate"
  helper_signing_certificate="${helper_signing_certificate_prefix}0"
  [[ -s "$helper_signing_certificate" ]] ||
    fail "Release synthetic helper has no leaf signing certificate"
  camera_agent_profile_authorizes_signer \
    "$helper_profile_plist" \
    "$helper_signing_certificate" \
    "$scratch_root/profile-developer-certificates" ||
    fail "Release synthetic helper signer is not authorized by its profile"
  camera_agent_profile_authorizes_app_group \
    "$helper_profile_plist" "$expected_app_group" 3524374A2S ||
    fail "Release synthetic helper profile does not authorize exactly $expected_app_group"

  production_helper_profile="$production_helper/Contents/embedded.provisionprofile"
  production_extension_profile="$production_extension/Contents/embedded.provisionprofile"
  extension_profile="$gate_extension/Contents/embedded.provisionprofile"
  [[ -f "$production_helper_profile" && -f "$production_extension_profile" && \
     -f "$extension_profile" ]] ||
    fail "Release C3/gate products are missing an embedded provisioning profile"
  /usr/bin/cmp -s "$production_helper_profile" "$helper_profile" ||
    fail "Release synthetic helper did not replay the exact C3 provisioning profile"
  /usr/bin/cmp -s "$production_extension_profile" "$extension_profile" ||
    fail "Release hosted-gate extension did not replay the exact C3 provisioning profile"

  extension_profile_plist="$scratch_root/extension-profile.plist"
  /usr/bin/security cms -D -i "$extension_profile" \
    >"$extension_profile_plist" 2>/dev/null ||
    fail "could not decode Release hosted-gate extension provisioning profile"
  [[ "$(/usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:com.apple.application-identifier' \
    "$extension_profile_plist" 2>/dev/null || true)" == \
    "3524374A2S.$expected_extension_identifier" ]] ||
    fail "Release hosted-gate extension profile application identifier is not exact"
  camera_agent_profile_is_current "$extension_profile_plist" "$(/bin/date -u '+%s')" ||
    fail "Release hosted-gate extension profile is invalid or expired"
  extension_signing_certificate_prefix="$scratch_root/extension-signing-certificate-"
  /usr/bin/codesign --display \
    --extract-certificates="$extension_signing_certificate_prefix" \
    "$gate_extension" >/dev/null 2>&1 ||
    fail "could not extract the Release hosted-gate extension signing certificate"
  extension_signing_certificate="${extension_signing_certificate_prefix}0"
  [[ -s "$extension_signing_certificate" ]] ||
    fail "Release hosted-gate extension has no leaf signing certificate"
  camera_agent_profile_authorizes_signer \
    "$extension_profile_plist" \
    "$extension_signing_certificate" \
    "$scratch_root/extension-profile-developer-certificates" ||
    fail "Release hosted-gate extension signer is not authorized by its profile"
  camera_agent_profile_authorizes_app_group \
    "$extension_profile_plist" "$expected_app_group" 3524374A2S ||
    fail "Release hosted-gate extension profile does not authorize exactly $expected_app_group"
fi

generated_manifest="$scratch_root/generated-manifest.txt"
"$manifest_tool" "$production_app" "$gate_app" "$generated_manifest" >/dev/null
if [[ -n "$expected_manifest" ]]; then
  [[ -f "$expected_manifest" ]] || fail "missing expected manifest: $expected_manifest"
  /usr/bin/cmp -s "$generated_manifest" "$expected_manifest" ||
    fail "gate no longer matches its exact substitution manifest"
fi

echo "PASS: $configuration synthetic gate has the production runtime tuple and explicit helper/hosted-extension markers."
echo "PASS: the topology-equivalent hosted extension has no AVFoundation linkage, camera entitlement, camera purpose key, or requestAccess symbol."
echo "PASS: only the nested helper, hosted-gate extension, and outer signature envelope differ from the production app."
