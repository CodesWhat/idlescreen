#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
production_verifier="$project_root/scripts/test-camera-agent-product.sh"
gate_verifier="$project_root/scripts/test-synthetic-gate-product.sh"
manifest_tool="$project_root/scripts/create-synthetic-gate-manifest.sh"
scratch_root="$(mktemp -d /tmp/idlescreen-synthetic-fixtures.XXXXXX)"
trap '/bin/rm -rf "$scratch_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for executable in "$production_verifier" "$gate_verifier" "$manifest_tool"; do
  [[ -x "$executable" ]] || fail "missing verifier: $executable"
done

compile_executable() {
  local output="$1"
  local return_value="$2"
  /bin/mkdir -p "$(/usr/bin/dirname "$output")"
  /usr/bin/printf 'int main(void) { return %s; }\n' "$return_value" |
    xcrun clang -x c - -o "$output"
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

code_directory_flags() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 |
    /usr/bin/sed -nE 's/^CodeDirectory .* flags=([^ ]+).*/\1/p' |
    /usr/bin/head -1
}

write_app_info() {
  local path="$1"
  /usr/bin/plutil -create xml1 "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.idlescreen.app.dev' "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string IdleScreen' "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$path"
  /usr/libexec/PlistBuddy -c 'Add :NSCameraUsageDescription string idlescreen uses the camera only for camera-based screen saver effects you explicitly enable.' "$path"
}

write_renderer_info() {
  local path="$1"
  /usr/bin/plutil -create xml1 "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.idlescreen.renderer' "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string IdleScreenRenderer' "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string FMWK' "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$path"
}

write_extension_info() {
  local path="$1"
  local synthetic="$2"
  /usr/bin/plutil -create xml1 "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.idlescreen.app.dev.screensaver' "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string IdleScreenScreenSaver' "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string XPC!' "$path"
  /usr/libexec/PlistBuddy -c 'Add :IdleScreenAppGroupIdentifier string group.com.idlescreen.dev.shared' "$path"
  /usr/libexec/PlistBuddy -c 'Add :IdleScreenCameraAgentAppGroupIdentifier string group.com.idlescreen.dev.shared' "$path"
  /usr/libexec/PlistBuddy -c 'Add :IdleScreenCameraAgentMachServiceName string group.com.idlescreen.dev.shared.camera-agent' "$path"
  /usr/libexec/PlistBuddy -c 'Add :IdleScreenCameraAgentTeamIdentifier string 3524374A2S' "$path"
  /usr/libexec/PlistBuddy -c 'Add :NSExtension dict' "$path"
  /usr/libexec/PlistBuddy -c 'Add :NSExtension:NSExtensionPointIdentifier string com.apple.screensaver' "$path"
  /usr/libexec/PlistBuddy -c 'Add :NSExtension:NSExtensionPointVersion string 1.0' "$path"
  /usr/libexec/PlistBuddy -c 'Add :NSExtension:NSExtensionPrincipalClass string IdleScreenScreenSaver.IdleScreenScreenSaverExtension' "$path"
  if [[ "$synthetic" == true ]]; then
    /usr/libexec/PlistBuddy -c 'Add :IdleScreenSyntheticHostedGateVersion string 1' "$path"
    /usr/libexec/PlistBuddy -c 'Add :ScreenSaverViewControllerClass string IdleScreenScreenSaver.IdleScreenSyntheticHostedGateViewController' "$path"
  else
    /usr/libexec/PlistBuddy -c 'Add :ScreenSaverViewControllerClass string IdleScreenScreenSaver.IdleScreenScreenSaverViewController' "$path"
  fi
}

write_helper_info() {
  local path="$1"
  local synthetic="$2"
  /usr/bin/plutil -create xml1 "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.idlescreen.camera-agent.dev' "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string IdleScreenCameraAgent' "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleName string idlescreen' "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string idlescreen' "$path"
  /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$path"
  /usr/libexec/PlistBuddy -c 'Add :LSBackgroundOnly bool true' "$path"
  /usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$path"
  /usr/libexec/PlistBuddy -c 'Add :IdleScreenCameraAgentMachServiceName string group.com.idlescreen.dev.shared.camera-agent' "$path"
  /usr/libexec/PlistBuddy -c 'Add :IdleScreenCameraAgentAppGroupIdentifier string group.com.idlescreen.dev.shared' "$path"
  /usr/libexec/PlistBuddy -c 'Add :IdleScreenCameraAgentTeamIdentifier string 3524374A2S' "$path"
  /usr/libexec/PlistBuddy -c 'Add :IdleScreenCameraAgentMailboxFileName string camera-frames-v1.mailbox' "$path"
  if [[ "$synthetic" == true ]]; then
    /usr/libexec/PlistBuddy -c 'Add :IdleScreenSyntheticGateVersion string 1' "$path"
  else
    /usr/libexec/PlistBuddy -c 'Add :NSCameraUsageDescription string idlescreen uses the camera only for camera-based screen saver effects you explicitly enable.' "$path"
    /usr/libexec/PlistBuddy -c 'Add :NSCameraUseContinuityCameraDeviceType bool true' "$path"
  fi
}

write_entitlements() {
  local path="$1"
  local camera="$2"
  /usr/bin/plutil -create xml1 "$path"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$path"
  if [[ "$camera" == true ]]; then
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.device.camera bool true' "$path"
  fi
}

write_control_tool_entitlements() {
  local path="$1"
  /usr/bin/plutil -create xml1 "$path"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$path"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' "$path"
  /usr/libexec/PlistBuddy \
    -c 'Add :com.apple.security.application-groups:0 string group.com.idlescreen.dev.shared' \
    "$path"
}

sign_outer() {
  local app="$1"
  /usr/bin/codesign --force --sign - --entitlements "$scratch_root/app.entitlements" \
    "$app" >/dev/null
}

resign_gate() {
  local app="$1"
  local helper_entitlements="$2"
  /usr/bin/codesign --force --sign - --entitlements "$helper_entitlements" \
    "$app/Contents/Helpers/IdleScreenCameraAgent.app" >/dev/null
  /usr/bin/codesign --force --sign - --entitlements "$scratch_root/extension.entitlements" \
    "$app/Contents/PlugIns/IdleScreenScreenSaver.appex" >/dev/null
  sign_outer "$app"
}

expect_gate_fail() {
  local name="$1"
  local app="$2"
  local expected="$3"
  local output="$scratch_root/failure-output.txt"
  if "$gate_verifier" "$production_app" "$app" Debug >"$output" 2>&1; then
    fail "$name unexpectedly passed"
  fi
  /usr/bin/grep -Fq "$expected" "$output" || {
    /bin/cat "$output" >&2
    fail "$name failed for the wrong reason; expected '$expected'"
  }
}

/usr/bin/plutil -create xml1 "$scratch_root/app.entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.device.camera bool true' \
  "$scratch_root/app.entitlements"
write_entitlements "$scratch_root/production-helper.entitlements" true
write_entitlements "$scratch_root/gate-helper.entitlements" false
write_entitlements "$scratch_root/extension.entitlements" false
write_control_tool_entitlements "$scratch_root/control-tool.entitlements"

production_app="$scratch_root/production/IdleScreen.app"
production_helper="$production_app/Contents/Helpers/IdleScreenCameraAgent.app"
production_extension="$production_app/Contents/PlugIns/IdleScreenScreenSaver.appex"
production_renderer="$production_app/Contents/Frameworks/IdleScreenRenderer.framework"
production_renderer_version="$production_renderer/Versions/A"
/bin/mkdir -p \
  "$production_app/Contents/MacOS" \
  "$production_renderer_version/Resources" \
  "$production_helper/Contents/MacOS" \
  "$production_extension/Contents/MacOS" \
  "$production_app/Contents/Library/LaunchAgents"
compile_executable "$production_app/Contents/MacOS/IdleScreen" 0
compile_executable "$production_app/Contents/Helpers/idlescreenctl" 0
/usr/bin/printf 'int idleScreenRendererFixture(void) { return 0; }\n' |
  /usr/bin/xcrun clang -x c - -dynamiclib \
    -install_name @rpath/IdleScreenRenderer.framework/Versions/A/IdleScreenRenderer \
    -o "$production_renderer_version/IdleScreenRenderer"
/bin/ln -s A "$production_renderer/Versions/Current"
/bin/ln -s Versions/Current/IdleScreenRenderer "$production_renderer/IdleScreenRenderer"
/bin/ln -s Versions/Current/Resources "$production_renderer/Resources"
compile_executable "$production_helper/Contents/MacOS/IdleScreenCameraAgent" 0
compile_executable "$production_extension/Contents/MacOS/IdleScreenScreenSaver" 0
write_app_info "$production_app/Contents/Info.plist"
write_renderer_info "$production_renderer_version/Resources/Info.plist"
write_extension_info "$production_extension/Contents/Info.plist" false
write_helper_info "$production_helper/Contents/Info.plist" false
/bin/cp \
  "$project_root/Sources/IdleScreenCameraAgent/LaunchAgents/group.com.idlescreen.dev.shared.camera-agent.plist" \
  "$production_app/Contents/Library/LaunchAgents/"
/usr/bin/codesign --force --sign - --entitlements "$scratch_root/production-helper.entitlements" \
  "$production_helper" >/dev/null
/usr/bin/codesign --force --sign - --identifier com.idlescreen.ctl \
  --entitlements "$scratch_root/control-tool.entitlements" \
  "$production_app/Contents/Helpers/idlescreenctl" >/dev/null
/usr/bin/codesign --force --sign - "$production_renderer" >/dev/null
/usr/bin/codesign --force --sign - --entitlements "$scratch_root/extension.entitlements" \
  "$production_extension" >/dev/null
sign_outer "$production_app"
"$production_verifier" "$production_app" Debug >/dev/null

production_hosted_marker_app="$scratch_root/production-hosted-marker/IdleScreen.app"
/usr/bin/ditto "$production_app" "$production_hosted_marker_app"
/usr/libexec/PlistBuddy -c 'Add :IdleScreenSyntheticHostedGateVersion string 1' \
  "$production_hosted_marker_app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/Info.plist"
/usr/bin/codesign --force --sign - --entitlements "$scratch_root/extension.entitlements" \
  "$production_hosted_marker_app/Contents/PlugIns/IdleScreenScreenSaver.appex" >/dev/null
sign_outer "$production_hosted_marker_app"
if "$production_verifier" "$production_hosted_marker_app" Debug \
  >"$scratch_root/production-hosted-marker-output.txt" 2>&1; then
  fail "production verifier accepted the hosted-gate extension marker"
fi
/usr/bin/grep -Fq 'production extension must not carry IdleScreenSyntheticHostedGateVersion' \
  "$scratch_root/production-hosted-marker-output.txt" ||
  fail "hosted-gate extension marker was rejected for the wrong reason"

mismatched_purpose_app="$scratch_root/mismatched-purpose/IdleScreen.app"
/usr/bin/ditto "$production_app" "$mismatched_purpose_app"
/usr/libexec/PlistBuddy -c 'Set :NSCameraUsageDescription wrong responsible-code purpose' \
  "$mismatched_purpose_app/Contents/Info.plist"
sign_outer "$mismatched_purpose_app"
if "$production_verifier" "$mismatched_purpose_app" Debug \
  >"$scratch_root/mismatched-purpose-output.txt" 2>&1; then
  fail "production verifier accepted mismatched responsible-code purpose text"
fi
/usr/bin/grep -Fq 'unexpected NSCameraUsageDescription' \
  "$scratch_root/mismatched-purpose-output.txt" ||
  fail "mismatched responsible-code purpose was rejected for the wrong reason"

gate_app="$scratch_root/gate/IdleScreen.app"
/usr/bin/ditto "$production_app" "$gate_app"
gate_helper="$gate_app/Contents/Helpers/IdleScreenCameraAgent.app"
gate_extension="$gate_app/Contents/PlugIns/IdleScreenScreenSaver.appex"
/bin/rm -rf "$gate_helper"
/bin/mkdir -p "$gate_helper/Contents/MacOS"
compile_executable "$gate_helper/Contents/MacOS/IdleScreenCameraAgent" 1
write_helper_info "$gate_helper/Contents/Info.plist" true
/bin/rm -rf "$gate_extension"
/bin/mkdir -p "$gate_extension/Contents/MacOS"
compile_executable "$gate_extension/Contents/MacOS/IdleScreenScreenSaver" 2
write_extension_info "$gate_extension/Contents/Info.plist" true
resign_gate "$gate_app" "$scratch_root/gate-helper.entitlements"

manifest="$scratch_root/manifest.txt"
"$manifest_tool" "$production_app" "$gate_app" "$manifest" >/dev/null
"$gate_verifier" "$production_app" "$gate_app" Debug "$manifest" >/dev/null

unexpected_helper_code_app="$scratch_root/unexpected-helper-code/IdleScreen.app"
/usr/bin/ditto "$gate_app" "$unexpected_helper_code_app"
compile_avfoundation_dylib \
  "$unexpected_helper_code_app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/Frameworks/UnexpectedCamera.dylib"
resign_gate "$unexpected_helper_code_app" "$scratch_root/gate-helper.entitlements"
expect_gate_fail 'unexpected signed camera dylib in synthetic helper' \
  "$unexpected_helper_code_app" \
  'synthetic helper contains unexpected Mach-O code: Contents/Frameworks/UnexpectedCamera.dylib'

unexpected_hosted_code_app="$scratch_root/unexpected-hosted-code/IdleScreen.app"
/usr/bin/ditto "$gate_app" "$unexpected_hosted_code_app"
compile_avfoundation_dylib \
  "$unexpected_hosted_code_app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/Frameworks/UnexpectedCamera.dylib"
resign_gate "$unexpected_hosted_code_app" "$scratch_root/gate-helper.entitlements"
expect_gate_fail 'unexpected signed camera dylib in hosted-gate extension' \
  "$unexpected_hosted_code_app" \
  'hosted-gate extension contains unexpected Mach-O code: Contents/Frameworks/UnexpectedCamera.dylib'

xattr_drift_app="$scratch_root/xattr-drift/IdleScreen.app"
/usr/bin/ditto "$gate_app" "$xattr_drift_app"
/usr/bin/xattr -w com.idlescreen.fixture changed-outside-substitution \
  "$xattr_drift_app/Contents/Library/LaunchAgents/group.com.idlescreen.dev.shared.camera-agent.plist"
sign_outer "$xattr_drift_app"
expect_gate_fail 'extended-attribute drift outside substitutions' "$xattr_drift_app" \
  'gate changes a path outside the helper-substitution whitelist'

flags_drift_app="$scratch_root/flags-drift/IdleScreen.app"
/usr/bin/ditto "$gate_app" "$flags_drift_app"
/usr/bin/codesign --force --sign - --options runtime \
  --entitlements "$scratch_root/app.entitlements" "$flags_drift_app" >/dev/null
[[ "$(code_directory_flags "$flags_drift_app")" != "$(code_directory_flags "$production_app")" ]] ||
  fail "fixture could not create distinct outer CodeDirectory flags"
expect_gate_fail 'outer CodeDirectory flags drift' "$flags_drift_app" \
  'gate outer CodeDirectory flags differ from production'

missing_marker_app="$scratch_root/missing-marker/IdleScreen.app"
/usr/bin/ditto "$gate_app" "$missing_marker_app"
/usr/libexec/PlistBuddy -c 'Delete :IdleScreenSyntheticGateVersion' \
  "$missing_marker_app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/Info.plist"
resign_gate "$missing_marker_app" "$scratch_root/gate-helper.entitlements"
expect_gate_fail 'missing marker' "$missing_marker_app" 'IdleScreenSyntheticGateVersion'

missing_hosted_marker_app="$scratch_root/missing-hosted-marker/IdleScreen.app"
/usr/bin/ditto "$gate_app" "$missing_hosted_marker_app"
/usr/libexec/PlistBuddy -c 'Delete :IdleScreenSyntheticHostedGateVersion' \
  "$missing_hosted_marker_app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/Info.plist"
resign_gate "$missing_hosted_marker_app" "$scratch_root/gate-helper.entitlements"
expect_gate_fail 'missing hosted marker' "$missing_hosted_marker_app" \
  'IdleScreenSyntheticHostedGateVersion'

wrong_hosted_controller_app="$scratch_root/wrong-hosted-controller/IdleScreen.app"
/usr/bin/ditto "$gate_app" "$wrong_hosted_controller_app"
/usr/libexec/PlistBuddy -c 'Set :ScreenSaverViewControllerClass IdleScreenScreenSaver.IdleScreenScreenSaverViewController' \
  "$wrong_hosted_controller_app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/Info.plist"
resign_gate "$wrong_hosted_controller_app" "$scratch_root/gate-helper.entitlements"
expect_gate_fail 'wrong hosted controller' "$wrong_hosted_controller_app" \
  'IdleScreenSyntheticHostedGateViewController'

hosted_camera_entitlement_app="$scratch_root/hosted-camera-entitlement/IdleScreen.app"
/usr/bin/ditto "$gate_app" "$hosted_camera_entitlement_app"
/usr/bin/codesign --force --sign - --entitlements "$scratch_root/production-helper.entitlements" \
  "$hosted_camera_entitlement_app/Contents/PlugIns/IdleScreenScreenSaver.appex" >/dev/null
sign_outer "$hosted_camera_entitlement_app"
expect_gate_fail 'hosted extension camera entitlement' "$hosted_camera_entitlement_app" \
  'hosted-gate extension must not carry the camera entitlement'

camera_entitlement_app="$scratch_root/camera-entitlement/IdleScreen.app"
/usr/bin/ditto "$gate_app" "$camera_entitlement_app"
resign_gate "$camera_entitlement_app" "$scratch_root/production-helper.entitlements"
expect_gate_fail 'camera entitlement' "$camera_entitlement_app" \
  'synthetic helper must not carry the camera entitlement'

wrong_association_app="$scratch_root/wrong-association/IdleScreen.app"
/usr/bin/ditto "$gate_app" "$wrong_association_app"
/usr/libexec/PlistBuddy -c 'Set :AssociatedBundleIdentifiers com.example.wrong' \
  "$wrong_association_app/Contents/Library/LaunchAgents/group.com.idlescreen.dev.shared.camera-agent.plist"
sign_outer "$wrong_association_app"
expect_gate_fail 'wrong associated identity' "$wrong_association_app" \
  'unexpected AssociatedBundleIdentifiers'

changed_extension_app="$scratch_root/changed-extension/IdleScreen.app"
/usr/bin/ditto "$gate_app" "$changed_extension_app"
/usr/libexec/PlistBuddy -c 'Set :IdleScreenCameraAgentMachServiceName group.example.wrong' \
  "$changed_extension_app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/Info.plist"
resign_gate "$changed_extension_app" "$scratch_root/gate-helper.entitlements"
expect_gate_fail 'changed hosted extension tuple' "$changed_extension_app" \
  'IdleScreenCameraAgentMachServiceName'

changed_outer_code_app="$scratch_root/changed-outer-code/IdleScreen.app"
/usr/bin/ditto "$gate_app" "$changed_outer_code_app"
compile_executable "$changed_outer_code_app/Contents/MacOS/IdleScreen" 2
sign_outer "$changed_outer_code_app"
expect_gate_fail 'changed outer code' "$changed_outer_code_app" \
  'gate outer executable code differs after removing its signature envelope'

changed_mode_app="$scratch_root/changed-mode/IdleScreen.app"
/usr/bin/ditto "$gate_app" "$changed_mode_app"
sign_outer "$changed_mode_app"
changed_mode_path="$changed_mode_app/Contents/Library/LaunchAgents/group.com.idlescreen.dev.shared.camera-agent.plist"
changed_mode_before="$(/usr/bin/stat -f '%Lp' "$changed_mode_path")"
if [[ "$changed_mode_before" == 600 ]]; then
  changed_mode_after=644
else
  changed_mode_after=600
fi
/bin/chmod "$changed_mode_after" "$changed_mode_path"
expect_gate_fail 'changed unchanged-tree file mode' "$changed_mode_app" \
  'gate changes a path outside the helper-substitution whitelist'

production_marker_app="$scratch_root/production-marker/IdleScreen.app"
/usr/bin/ditto "$production_app" "$production_marker_app"
/usr/libexec/PlistBuddy -c 'Add :IdleScreenSyntheticGateVersion string 1' \
  "$production_marker_app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/Info.plist"
if "$production_verifier" "$production_marker_app" Debug \
  >"$scratch_root/production-marker-output.txt" 2>&1; then
  fail "production verifier accepted a synthetic marker"
fi
/usr/bin/grep -Fq 'production camera helper must not carry IdleScreenSyntheticGateVersion' \
  "$scratch_root/production-marker-output.txt" ||
  fail "production marker was rejected for the wrong reason"

echo 'PASS: valid Debug fixture proves exact marker-bearing helper substitution.'
echo 'PASS: valid Debug fixture proves a distinct marker-bearing hosted-extension substitution.'
echo 'PASS: helper/extension markers, camera entitlements, attribution, tuple, mode, outer code, and production contamination mutations fail closed.'
