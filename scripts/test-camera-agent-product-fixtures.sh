#!/bin/bash

set -euo pipefail

script_root="$(cd "$(dirname "$0")" && pwd)"
verifier="$script_root/test-camera-agent-product.sh"
scratch_root="$(mktemp -d /tmp/idlescreen-camera-agent-product-fixtures.XXXXXX)"
trap '/bin/rm -rf "$scratch_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

write_bundle_info() {
  local path="$1"
  local identifier="$2"
  local executable="$3"
  local package_type="$4"

  /usr/bin/plutil -create xml1 "$path"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $identifier" "$path"
  /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $executable" "$path"
  /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string $package_type" "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$path"
}

write_helper_info() {
  local path="$1"
  local mach_service="$2"

  /usr/bin/plutil -create xml1 "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.idlescreen.camera-agent.dev' "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string IdleScreenCameraAgent' "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleName string idlescreen' "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string idlescreen' "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$path"
  /usr/libexec/PlistBuddy -c 'Add :LSBackgroundOnly bool true' "$path"
  /usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$path"
  /usr/libexec/PlistBuddy -c 'Add :IdleScreenCameraAgentAppGroupIdentifier string group.com.idlescreen.dev.shared' "$path"
  /usr/libexec/PlistBuddy -c "Add :IdleScreenCameraAgentMachServiceName string $mach_service" "$path"
  /usr/libexec/PlistBuddy -c 'Add :IdleScreenCameraAgentMailboxFileName string camera-frames-v1.mailbox' "$path"
  /usr/libexec/PlistBuddy -c 'Add :IdleScreenCameraAgentTeamIdentifier string 3524374A2S' "$path"
  /usr/libexec/PlistBuddy -c 'Add :NSCameraUsageDescription string idlescreen uses the camera only for camera-based screen saver effects you explicitly enable.' "$path"
  /usr/libexec/PlistBuddy -c 'Add :NSCameraUseContinuityCameraDeviceType bool true' "$path"
}

write_launch_agent() {
  local path="$1"
  local service="$2"
  local associated_bundle_identifier="$3"

  /usr/bin/plutil -create xml1 "$path"
  /usr/libexec/PlistBuddy -c "Add :Label string $service" "$path"
  /usr/libexec/PlistBuddy \
    -c "Add :AssociatedBundleIdentifiers string $associated_bundle_identifier" "$path"
  /usr/libexec/PlistBuddy -c 'Add :BundleProgram string Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent' "$path"
  /usr/libexec/PlistBuddy -c 'Add :ProcessType string Interactive' "$path"
  /usr/libexec/PlistBuddy -c 'Add :MachServices dict' "$path"
  /usr/libexec/PlistBuddy -c "Add :MachServices:$service bool true" "$path"
}

write_entitlements() {
  local path="$1"
  shift

  /usr/bin/plutil -create xml1 "$path"
  while [[ $# -gt 0 ]]; do
    /usr/libexec/PlistBuddy -c "Add :$1 bool true" "$path"
    shift
  done
}

write_helper_entitlements() {
  local path="$1"
  local include_camera="$2"
  local include_app_group="$3"

  /usr/bin/plutil -create xml1 "$path"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$path"
  if [[ "$include_camera" == true ]]; then
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.device.camera bool true' "$path"
  fi
  if [[ "$include_app_group" == true ]]; then
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' "$path"
    /usr/libexec/PlistBuddy \
      -c 'Add :com.apple.security.application-groups:0 string group.com.idlescreen.dev.shared' \
      "$path"
  fi
}

compile_binary() {
  local output="$1"
  shift
  /usr/bin/xcrun clang "$scratch_root/main.c" -o "$output" "$@"
}

compile_avfoundation_dylib() {
  local output="$1"
  local source="$scratch_root/avfoundation-linked.m"

  /bin/mkdir -p "$(/usr/bin/dirname "$output")"
  /usr/bin/printf '%s\n' \
    '#import <AVFoundation/AVFoundation.h>' \
    'Class idleScreenCaptureClass(void) { return [AVCaptureSession class]; }' \
    >"$source"
  /usr/bin/xcrun clang -x objective-c "$source" -dynamiclib \
    -framework AVFoundation -framework Foundation -o "$output"
  /usr/bin/otool -L "$output" | /usr/bin/grep -F AVFoundation >/dev/null ||
    fail "fixture dylib did not retain AVFoundation linkage"
  /usr/bin/codesign --force --sign - "$output" >/dev/null
}

sign_fixture() {
  local app_path="$1"
  local helper_entitlements="$2"

  /usr/bin/codesign --force --sign - --identifier com.idlescreen.ctl \
    --entitlements "$scratch_root/control-tool.entitlements" \
    "$app_path/Contents/Helpers/idlescreenctl" >/dev/null
  /usr/bin/codesign --force --sign - \
    "$app_path/Contents/Frameworks/IdleScreenRenderer.framework" >/dev/null
  /usr/bin/codesign --force --sign - --entitlements "$helper_entitlements" \
    "$app_path/Contents/Helpers/IdleScreenCameraAgent.app" >/dev/null
  /usr/bin/codesign --force --sign - --entitlements "$scratch_root/saver.entitlements" \
    "$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex" >/dev/null
  /usr/bin/codesign --force --sign - --entitlements "$scratch_root/app.entitlements" \
    "$app_path" >/dev/null
}

make_valid_fixture() {
  local app_path="$1"
  local helper_entitlements="$scratch_root/helper.entitlements"
  local extension_path="$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex"
  local renderer_path="$app_path/Contents/Frameworks/IdleScreenRenderer.framework"
  local renderer_version_path="$renderer_path/Versions/A"

  /bin/mkdir -p \
    "$app_path/Contents/MacOS" \
    "$renderer_version_path/Resources" \
    "$app_path/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS" \
    "$app_path/Contents/Library/LaunchAgents" \
    "$extension_path/Contents/MacOS"

  write_bundle_info "$app_path/Contents/Info.plist" com.idlescreen.app.dev IdleScreen APPL
  /usr/libexec/PlistBuddy \
    -c 'Add :NSCameraUsageDescription string idlescreen uses the camera only for camera-based screen saver effects you explicitly enable.' \
    "$app_path/Contents/Info.plist"
  write_bundle_info "$extension_path/Contents/Info.plist" \
    com.idlescreen.app.dev.screensaver IdleScreenScreenSaver XPC!
  write_bundle_info "$renderer_version_path/Resources/Info.plist" \
    com.idlescreen.renderer IdleScreenRenderer FMWK
  write_helper_info \
    "$app_path/Contents/Helpers/IdleScreenCameraAgent.app/Contents/Info.plist" \
    group.com.idlescreen.dev.shared.camera-agent
  write_launch_agent \
    "$app_path/Contents/Library/LaunchAgents/group.com.idlescreen.dev.shared.camera-agent.plist" \
    group.com.idlescreen.dev.shared.camera-agent \
    com.idlescreen.app.dev
  write_helper_entitlements "$helper_entitlements" true false
  write_entitlements "$scratch_root/saver.entitlements" com.apple.security.app-sandbox
  write_entitlements "$scratch_root/app.entitlements" com.apple.security.device.camera
  /usr/bin/plutil -create xml1 "$scratch_root/control-tool.entitlements"
  /usr/libexec/PlistBuddy \
    -c 'Add :com.apple.security.app-sandbox bool true' \
    "$scratch_root/control-tool.entitlements"
  /usr/libexec/PlistBuddy \
    -c 'Add :com.apple.security.application-groups array' \
    "$scratch_root/control-tool.entitlements"
  /usr/libexec/PlistBuddy \
    -c 'Add :com.apple.security.application-groups:0 string group.com.idlescreen.dev.shared' \
    "$scratch_root/control-tool.entitlements"

  compile_binary "$app_path/Contents/MacOS/IdleScreen"
  compile_binary "$app_path/Contents/Helpers/idlescreenctl"
  /usr/bin/xcrun clang "$scratch_root/main.c" -dynamiclib \
    -install_name @rpath/IdleScreenRenderer.framework/Versions/A/IdleScreenRenderer \
    -o "$renderer_version_path/IdleScreenRenderer"
  /bin/ln -s A "$renderer_path/Versions/Current"
  /bin/ln -s Versions/Current/IdleScreenRenderer "$renderer_path/IdleScreenRenderer"
  /bin/ln -s Versions/Current/Resources "$renderer_path/Resources"
  compile_binary "$extension_path/Contents/MacOS/IdleScreenScreenSaver"
  compile_binary \
    "$app_path/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
  sign_fixture "$app_path" "$helper_entitlements"
}

expect_pass() {
  local description="$1"
  local app_path="$2"
  local output

  output="$($verifier "$app_path" Debug 2>&1)" ||
    fail "$description should pass, got: $output"
  grep -Fq 'signature identity is ad-hoc' <<<"$output" ||
    fail "$description did not explicitly report its ad-hoc identity"
  echo "PASS: $description"
}

expect_fail() {
  local description="$1"
  local app_path="$2"
  local expected_message="$3"
  local output

  if output="$($verifier "$app_path" Debug 2>&1)"; then
    fail "$description unexpectedly passed"
  fi
  grep -Fq "$expected_message" <<<"$output" ||
    fail "$description failed for the wrong reason: $output"
  echo "PASS: $description fails closed"
}

/usr/bin/printf 'int main(void) { return 0; }\n' >"$scratch_root/main.c"
base_app="$scratch_root/base/IdleScreen.app"
make_valid_fixture "$base_app"
expect_pass 'valid Debug product' "$base_app"

missing_plist_app="$scratch_root/missing-plist/IdleScreen.app"
/usr/bin/ditto "$base_app" "$missing_plist_app"
/bin/rm "$missing_plist_app/Contents/Library/LaunchAgents/group.com.idlescreen.dev.shared.camera-agent.plist"
expect_fail 'missing LaunchAgent plist' "$missing_plist_app" 'expected exactly one camera LaunchAgent plist'

opposite_plist_app="$scratch_root/opposite-plist/IdleScreen.app"
/usr/bin/ditto "$base_app" "$opposite_plist_app"
write_launch_agent \
  "$opposite_plist_app/Contents/Library/LaunchAgents/group.com.idlescreen.shared.camera-agent.plist" \
  group.com.idlescreen.shared.camera-agent \
  com.idlescreen.app
expect_fail 'opposite-configuration LaunchAgent plist' "$opposite_plist_app" 'opposite-configuration LaunchAgent plist'

missing_association_app="$scratch_root/missing-association/IdleScreen.app"
/usr/bin/ditto "$base_app" "$missing_association_app"
/usr/libexec/PlistBuddy \
  -c 'Delete :AssociatedBundleIdentifiers' \
  "$missing_association_app/Contents/Library/LaunchAgents/group.com.idlescreen.dev.shared.camera-agent.plist"
expect_fail 'missing associated companion identity' "$missing_association_app" \
  'unexpected AssociatedBundleIdentifiers'

mismatched_purpose_app="$scratch_root/mismatched-purpose/IdleScreen.app"
/usr/bin/ditto "$base_app" "$mismatched_purpose_app"
/usr/libexec/PlistBuddy \
  -c 'Set :NSCameraUsageDescription wrong responsible-code purpose' \
  "$mismatched_purpose_app/Contents/Info.plist"
expect_fail 'mismatched containing-app camera purpose' "$mismatched_purpose_app" \
  'unexpected NSCameraUsageDescription'

synthetic_marker_app="$scratch_root/synthetic-marker/IdleScreen.app"
/usr/bin/ditto "$base_app" "$synthetic_marker_app"
/usr/libexec/PlistBuddy \
  -c 'Add :IdleScreenSyntheticGateVersion string 1' \
  "$synthetic_marker_app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/Info.plist"
expect_fail 'synthetic marker in production candidate' "$synthetic_marker_app" \
  'production camera helper must not carry IdleScreenSyntheticGateVersion'

hosted_marker_app="$scratch_root/hosted-marker/IdleScreen.app"
/usr/bin/ditto "$base_app" "$hosted_marker_app"
/usr/libexec/PlistBuddy \
  -c 'Add :IdleScreenSyntheticHostedGateVersion string 1' \
  "$hosted_marker_app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/Info.plist"
sign_fixture "$hosted_marker_app" "$scratch_root/helper.entitlements"
expect_fail 'hosted-gate marker in production candidate' "$hosted_marker_app" \
  'production extension must not carry IdleScreenSyntheticHostedGateVersion'

hosted_symbol_app="$scratch_root/hosted-symbol/IdleScreen.app"
/usr/bin/ditto "$base_app" "$hosted_symbol_app"
/usr/bin/printf '%s\n' \
  'const char *marker = "IdleScreenSyntheticHostedGateViewController";' \
  'int main(void) { return marker[0] == 0; }' \
  >"$scratch_root/hosted-marker.c"
/usr/bin/xcrun clang "$scratch_root/hosted-marker.c" \
  -o "$hosted_symbol_app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver"
sign_fixture "$hosted_symbol_app" "$scratch_root/helper.entitlements"
expect_fail 'hosted-gate symbol in production extension' "$hosted_symbol_app" \
  'production screen-saver contains a synthetic hosted-gate marker or symbol'

extension_camera_linkage_app="$scratch_root/extension-camera-linkage/IdleScreen.app"
/usr/bin/ditto "$base_app" "$extension_camera_linkage_app"
compile_binary \
  "$extension_camera_linkage_app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver" \
  -framework AVFoundation
sign_fixture "$extension_camera_linkage_app" "$scratch_root/helper.entitlements"
expect_fail 'camera linkage in production extension' "$extension_camera_linkage_app" \
  'production screen-saver must not link AVFoundation'

companion_camera_linkage_app="$scratch_root/companion-camera-linkage/IdleScreen.app"
/usr/bin/ditto "$base_app" "$companion_camera_linkage_app"
compile_binary "$companion_camera_linkage_app/Contents/MacOS/IdleScreen" \
  -framework AVFoundation
sign_fixture "$companion_camera_linkage_app" "$scratch_root/helper.entitlements"
expect_fail 'camera linkage in production companion' "$companion_camera_linkage_app" \
  'production companion must not link AVFoundation'

unexpected_outer_code_app="$scratch_root/unexpected-outer-code/IdleScreen.app"
/usr/bin/ditto "$base_app" "$unexpected_outer_code_app"
compile_avfoundation_dylib \
  "$unexpected_outer_code_app/Contents/Frameworks/UnexpectedCamera.dylib"
sign_fixture "$unexpected_outer_code_app" "$scratch_root/helper.entitlements"
expect_fail 'unexpected signed camera dylib in production outer bundle' \
  "$unexpected_outer_code_app" \
  'unexpected Mach-O code in production product: Contents/Frameworks/UnexpectedCamera.dylib'

unexpected_extension_code_app="$scratch_root/unexpected-extension-code/IdleScreen.app"
/usr/bin/ditto "$base_app" "$unexpected_extension_code_app"
compile_avfoundation_dylib \
  "$unexpected_extension_code_app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/Frameworks/UnexpectedCamera.dylib"
sign_fixture "$unexpected_extension_code_app" "$scratch_root/helper.entitlements"
expect_fail 'unexpected signed camera dylib in production extension' \
  "$unexpected_extension_code_app" \
  'unexpected Mach-O code in production product: Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/Frameworks/UnexpectedCamera.dylib'

wrong_info_app="$scratch_root/wrong-info/IdleScreen.app"
/usr/bin/ditto "$base_app" "$wrong_info_app"
write_helper_info \
  "$wrong_info_app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/Info.plist" \
  group.com.idlescreen.dev.shared.wrong
/usr/bin/codesign --force --sign - --entitlements "$scratch_root/helper.entitlements" \
  "$wrong_info_app/Contents/Helpers/IdleScreenCameraAgent.app" >/dev/null
expect_fail 'wrong embedded helper configuration' "$wrong_info_app" 'unexpected IdleScreenCameraAgentMachServiceName'

duplicate_helper_app="$scratch_root/duplicate-helper/IdleScreen.app"
/usr/bin/ditto "$base_app" "$duplicate_helper_app"
/bin/cp "$duplicate_helper_app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent" \
  "$duplicate_helper_app/Contents/MacOS/IdleScreenCameraAgent"
expect_fail 'unexpected helper copy' "$duplicate_helper_app" \
  'unexpected Mach-O code in production product: Contents/MacOS/IdleScreenCameraAgent'

bare_helper_app="$scratch_root/bare-helper/IdleScreen.app"
/usr/bin/ditto "$base_app" "$bare_helper_app"
/bin/cp "$bare_helper_app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent" \
  "$bare_helper_app/Contents/Helpers/IdleScreenCameraAgent"
/bin/rm -rf "$bare_helper_app/Contents/Helpers/IdleScreenCameraAgent.app"
expect_fail 'bare helper executable' "$bare_helper_app" \
  'unexpected Mach-O code in production product: Contents/Helpers/IdleScreenCameraAgent'

embedded_framework_app="$scratch_root/embedded-framework/IdleScreen.app"
/usr/bin/ditto "$base_app" "$embedded_framework_app"
/bin/mkdir -p \
  "$embedded_framework_app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/Frameworks/IdleScreenCamera.framework"
expect_fail 'embedded static framework copy' "$embedded_framework_app" \
  'camera helper must not embed static framework copies'

missing_camera_app="$scratch_root/missing-camera/IdleScreen.app"
/usr/bin/ditto "$base_app" "$missing_camera_app"
write_helper_entitlements "$scratch_root/no-camera.entitlements" false false
/usr/bin/codesign --force --sign - --entitlements "$scratch_root/no-camera.entitlements" \
  "$missing_camera_app/Contents/Helpers/IdleScreenCameraAgent.app" >/dev/null
expect_fail 'helper without camera entitlement' "$missing_camera_app" 'camera entitlement is not true'

missing_app_camera_app="$scratch_root/missing-app-camera/IdleScreen.app"
/usr/bin/ditto "$base_app" "$missing_app_camera_app"
/usr/bin/plutil -create xml1 "$scratch_root/no-app-camera.entitlements"
/usr/bin/codesign --force --sign - --entitlements "$scratch_root/no-app-camera.entitlements" \
  "$missing_app_camera_app" >/dev/null
expect_fail 'responsible app without camera entitlement' "$missing_app_camera_app" \
  'app com.apple.security.device.camera entitlement is not true'

# Release verification decodes an Apple-signed CMS provisioning profile and
# matches its DeveloperCertificates against the actual code-signing leaf.
# An ad-hoc fixture cannot safely synthesize that Apple-issued cryptographic
# evidence, so this deterministic suite covers the Debug structural branch;
# fresh signed Release builds exercise the Release-only profile branch.
echo 'PASS: camera-agent Debug structural verifier fixture coverage is complete.'
echo 'INFO: Release CMS/profile verification requires a fresh Apple-signed product.'
