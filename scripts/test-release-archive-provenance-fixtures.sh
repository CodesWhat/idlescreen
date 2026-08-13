#!/bin/bash
# shellcheck disable=SC2317

set -euo pipefail

mock_codesign_main() {
  local product_path="${!#}"
  local argument
  local certificate_prefix=""
  local certificate_source
  local identifier
  local info_plist
  local team_identifier=3524374A2S
  local cdhash

  info_plist="$product_path/Contents/Info.plist"
  if [[ "$product_path" == */idlescreenctl ]]; then
    identifier=com.idlescreen.ctl
  elif [[ "$product_path" == *.framework ]]; then
    info_plist="$product_path/Resources/Info.plist"
  fi

  if [[ " $* " == *' --verify '* ]]; then
    if [[ -e "$product_path/.invalid-signature" ]] ||
       /usr/bin/find "$product_path" -name .invalid-signature -print -quit | /usr/bin/grep -q .; then
      exit 1
    fi
    exit 0
  fi
  if [[ " $* " == *' --entitlements '* ]]; then
    if [[ "$product_path" == */idlescreenctl ]]; then
      /bin/cat "$product_path.fixture-entitlements.plist"
    else
      /bin/cat "$product_path/Contents/fixture-entitlements.plist"
    fi
    exit 0
  fi
  for argument in "$@"; do
    case "$argument" in
      --extract-certificates=*) certificate_prefix="${argument#*=}" ;;
    esac
  done
  if [[ -n "$certificate_prefix" ]]; then
    certificate_source="$IDLESCREEN_MOCK_LEAF_CERTIFICATE"
    [[ ! -e "$product_path/.mismatched-signer" ]] ||
      certificate_source="$IDLESCREEN_MOCK_OTHER_CERTIFICATE"
    /bin/cp "$certificate_source" "${certificate_prefix}0"
    exit 0
  fi
  if [[ " $* " == *' -dr '* ]]; then
    if [[ "$product_path" != */idlescreenctl ]]; then
      identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$info_plist")"
    fi
    /usr/bin/printf 'Executable=%s\n' "$product_path" >&2
    if [[ -e "$product_path/.malformed-designated-requirement" ]]; then
      /usr/bin/printf 'designated => identifier "com.example.wrong" and anchor apple generic\n' >&2
    elif [[ -e "$product_path/.extra-designated-clause" ]]; then
      /usr/bin/printf '%s\n' \
        "designated => identifier \"$identifier\" and anchor apple generic and certificate leaf[subject.CN] = \"Apple Development: Fixture Developer (7C7W4L54G6)\" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */ and true" >&2
    else
      /usr/bin/printf '%s\n' \
        "designated => identifier \"$identifier\" and anchor apple generic and certificate leaf[subject.CN] = \"Apple Development: Fixture Developer (7C7W4L54G6)\" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */" >&2
    fi
    exit 0
  fi
  if [[ " $* " == *' -dv '* || " $* " == *' --verbose=4 '* ]]; then
    if [[ "$product_path" != */idlescreenctl ]]; then
      identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$info_plist")"
    fi
    [[ ! -e "$product_path/.wrong-team" ]] || team_identifier=AAAAAAAAAA
    case "$identifier" in
      com.idlescreen.app) cdhash=1111111111111111111111111111111111111111 ;;
      com.idlescreen.app.screensaver) cdhash=2222222222222222222222222222222222222222 ;;
      com.idlescreen.camera-agent) cdhash=3333333333333333333333333333333333333333 ;;
      com.idlescreen.renderer) cdhash=4444444444444444444444444444444444444444 ;;
      com.idlescreen.ctl) cdhash=5555555555555555555555555555555555555555 ;;
      *) exit 1 ;;
    esac
    if [[ -e "$product_path/.missing-runtime" ]]; then
      /usr/bin/printf 'CodeDirectory v=20500 size=100 flags=0x0(none) hashes=1+1 location=embedded\n' >&2
    elif [[ -e "$product_path/.adhoc-signature" ]]; then
      /usr/bin/printf 'CodeDirectory v=20500 size=100 flags=0x10002(adhoc,runtime) hashes=1+1 location=embedded\n' >&2
    else
      /usr/bin/printf 'CodeDirectory v=20500 size=100 flags=0x10000(runtime) hashes=1+1 location=embedded\n' >&2
    fi
    if [[ -e "$product_path/.adhoc-signature" ]]; then
      /usr/bin/printf 'Signature=adhoc\n' >&2
    else
      /usr/bin/printf 'Signature size=4000\n' >&2
      /usr/bin/printf 'Authority=Apple Development: Fixture Developer (7C7W4L54G6)\n' >&2
      /usr/bin/printf 'Authority=Apple Worldwide Developer Relations Certification Authority\n' >&2
      /usr/bin/printf 'Authority=Apple Root CA\n' >&2
    fi
    if [[ -e "$product_path/.malformed-signature-metadata" ]]; then
      /usr/bin/printf 'Identifier=%s\nTeamIdentifier=%s\nTeamIdentifier=%s\nCDHash=%s\n' \
        "$identifier" "$team_identifier" "$team_identifier" "$cdhash" >&2
    else
      /usr/bin/printf 'Identifier=%s\nTeamIdentifier=%s\nCDHash=%s\n' "$identifier" "$team_identifier" "$cdhash" >&2
    fi
    exit 0
  fi
  exit 1
}

mock_security_main() {
  local input=""
  local output=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i)
        shift
        input="$1"
        ;;
      -o)
        shift
        output="$1"
        ;;
    esac
    shift
  done
  [[ -n "$input" && -n "$output" ]] || exit 1
  /bin/cp "$input" "$output"
}

case "$(/usr/bin/basename "$0")" in
  mock-codesign|mock-codesign.sh) mock_codesign_main "$@"; exit $? ;;
  mock-security|mock-security.sh) mock_security_main "$@"; exit $? ;;
esac

script_root="$(cd "$(dirname "$0")" && pwd)"
verifier="$script_root/verify-release-archive-provenance.sh"
scratch_root="$(mktemp -d /tmp/idlescreen-release-provenance-fixtures.XXXXXX)"
trap '/bin/rm -rf "$scratch_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x "$verifier" ]] || fail "Release archive provenance verifier is missing"

leaf_certificate="$scratch_root/leaf-certificate.der"
other_certificate="$scratch_root/other-certificate.der"
/usr/bin/printf 'fixture exact shared leaf certificate' >"$leaf_certificate"
/usr/bin/printf 'fixture mismatched leaf certificate' >"$other_certificate"

write_common_info_tuple() {
  local plist="$1"

  /usr/libexec/PlistBuddy -c 'Add :IdleScreenAppGroupIdentifier string group.com.idlescreen.shared' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :IdleScreenCameraAgentAppGroupIdentifier string group.com.idlescreen.shared' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :IdleScreenCameraAgentMachServiceName string group.com.idlescreen.shared.camera-agent' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :IdleScreenCameraAgentTeamIdentifier string 3524374A2S' "$plist"
}

write_bundle_info() {
  local plist="$1"
  local identifier="$2"
  local executable="$3"
  local package_type="$4"

  /usr/bin/plutil -create xml1 "$plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $identifier" "$plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $executable" "$plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string $package_type" "$plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$plist"
  write_common_info_tuple "$plist"
}

write_helper_info() {
  local plist="$1"

  /usr/bin/plutil -create xml1 "$plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.idlescreen.camera-agent' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string IdleScreenCameraAgent' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :IdleScreenCameraAgentAppGroupIdentifier string group.com.idlescreen.shared' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :IdleScreenCameraAgentMachServiceName string group.com.idlescreen.shared.camera-agent' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :IdleScreenCameraAgentTeamIdentifier string 3524374A2S' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :NSCameraUsageDescription string idlescreen uses the camera only for camera-based screen saver effects you explicitly enable.' "$plist"
}

add_identity_entitlements() {
  local plist="$1"
  local identifier="$2"

  /usr/libexec/PlistBuddy -c 'Add :com.apple.developer.team-identifier string 3524374A2S' "$plist"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string 3524374A2S.$identifier" "$plist"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups:0 string group.com.idlescreen.shared' "$plist"
}

write_app_entitlements() {
  local plist="$1"

  /usr/bin/plutil -create xml1 "$plist"
  add_identity_entitlements "$plist" com.idlescreen.app
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.device.camera bool true' "$plist"
}

write_extension_entitlements() {
  local plist="$1"

  /usr/bin/plutil -create xml1 "$plist"
  add_identity_entitlements "$plist" com.idlescreen.app.screensaver
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.mach-lookup.global-name array' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.mach-lookup.global-name:0 string com.apple.CARenderServer' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.mach-lookup.global-name:1 string com.apple.CoreDisplay.master' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.mach-lookup.global-name:2 string com.apple.ViewBridgeAuxiliary' "$plist"
}

write_helper_entitlements() {
  local plist="$1"

  /usr/bin/plutil -create xml1 "$plist"
  add_identity_entitlements "$plist" com.idlescreen.camera-agent
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.device.camera bool true' "$plist"
}

write_control_tool_entitlements() {
  local plist="$1"

  /usr/bin/plutil -create xml1 "$plist"
  add_identity_entitlements "$plist" com.idlescreen.ctl
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$plist"
}

write_profile() {
  local profile="$1"
  local identifier="$2"
  local uuid="$3"
  local certificate_base64

  certificate_base64="$(/usr/bin/base64 <"$leaf_certificate" | /usr/bin/tr -d '\n')"
  /usr/bin/plutil -create xml1 "$profile"
  /usr/libexec/PlistBuddy -c 'Add :TeamIdentifier array' "$profile"
  /usr/libexec/PlistBuddy -c 'Add :TeamIdentifier:0 string 3524374A2S' "$profile"
  /usr/libexec/PlistBuddy -c 'Add :Entitlements dict' "$profile"
  /usr/libexec/PlistBuddy -c 'Add :Entitlements:com.apple.developer.team-identifier string 3524374A2S' "$profile"
  /usr/libexec/PlistBuddy -c "Add :Entitlements:com.apple.application-identifier string 3524374A2S.$identifier" "$profile"
  /usr/libexec/PlistBuddy -c 'Add :Entitlements:com.apple.security.application-groups array' "$profile"
  /usr/libexec/PlistBuddy -c 'Add :Entitlements:com.apple.security.application-groups:0 string group.com.idlescreen.shared' "$profile"
  /usr/libexec/PlistBuddy -c 'Add :Entitlements:get-task-allow bool false' "$profile"
  /usr/libexec/PlistBuddy -c 'Add :DeveloperCertificates array' "$profile"
  /usr/bin/plutil -insert DeveloperCertificates.0 -data "$certificate_base64" "$profile"
  /usr/libexec/PlistBuddy -c "Add :UUID string $uuid" "$profile"
  /usr/bin/plutil -insert ExpirationDate -date '2035-01-01T00:00:00Z' "$profile"
}

write_launch_agent() {
  local plist="$1"

  /usr/bin/plutil -create xml1 "$plist"
  /usr/libexec/PlistBuddy -c 'Add :AssociatedBundleIdentifiers string com.idlescreen.app' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :BundleProgram string Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :Label string group.com.idlescreen.shared.camera-agent' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :MachServices dict' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :MachServices:group.com.idlescreen.shared.camera-agent bool true' "$plist"
  /usr/libexec/PlistBuddy -c 'Add :ProcessType string Interactive' "$plist"
}

compile_plain_binary() {
  local output="$1"

  /usr/bin/xcrun clang "$scratch_root/plain.c" -o "$output"
}

compile_scratch_gate_binary() {
  local output="$1"

  /usr/bin/xcrun clang "$scratch_root/scratch-gate.c" -o "$output"
}

compile_camera_binary() {
  local output="$1"

  /usr/bin/xcrun clang -x objective-c "$scratch_root/camera.m" \
    -framework AVFoundation -framework Foundation -o "$output"
  /usr/bin/otool -L "$output" | /usr/bin/grep -Fq AVFoundation ||
    fail "camera fixture did not retain AVFoundation linkage"
}

compile_framework_only_binary() {
  local output="$1"

  /usr/bin/xcrun clang -x objective-c "$scratch_root/framework-only.m" \
    -framework AVFoundation -framework Foundation -o "$output"
  /usr/bin/otool -L "$output" | /usr/bin/grep -Fq AVFoundation ||
    fail "framework-only fixture did not retain AVFoundation linkage"
}

make_valid_archive() {
  local archive="$1"
  local app="$archive/Products/Applications/IdleScreen.app"
  local extension="$app/Contents/PlugIns/IdleScreenScreenSaver.appex"
  local helper="$app/Contents/Helpers/IdleScreenCameraAgent.app"
  local renderer="$app/Contents/Frameworks/IdleScreenRenderer.framework"
  local control_tool="$app/Contents/Helpers/idlescreenctl"
  local launch_agent="$app/Contents/Library/LaunchAgents/group.com.idlescreen.shared.camera-agent.plist"

  /bin/mkdir -p \
    "$app/Contents/MacOS" \
    "$extension/Contents/MacOS" \
    "$helper/Contents/MacOS" \
    "$renderer/Resources" \
    "$renderer/Versions/A" \
    "$app/Contents/Library/LaunchAgents"

  /usr/bin/plutil -create xml1 "$archive/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :ApplicationProperties dict' "$archive/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :ApplicationProperties:ApplicationPath string Applications/IdleScreen.app' "$archive/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :ApplicationProperties:CFBundleIdentifier string com.idlescreen.app' "$archive/Info.plist"

  write_bundle_info "$app/Contents/Info.plist" com.idlescreen.app IdleScreen APPL
  /usr/libexec/PlistBuddy -c 'Add :NSCameraUsageDescription string idlescreen uses the camera only for camera-based screen saver effects you explicitly enable.' "$app/Contents/Info.plist"
  write_bundle_info "$extension/Contents/Info.plist" com.idlescreen.app.screensaver IdleScreenScreenSaver XPC!
  write_helper_info "$helper/Contents/Info.plist"
  write_bundle_info "$renderer/Resources/Info.plist" com.idlescreen.renderer IdleScreenRenderer FMWK
  write_launch_agent "$launch_agent"

  write_app_entitlements "$app/Contents/fixture-entitlements.plist"
  write_extension_entitlements "$extension/Contents/fixture-entitlements.plist"
  write_helper_entitlements "$helper/Contents/fixture-entitlements.plist"
  write_control_tool_entitlements "$control_tool.fixture-entitlements.plist"
  write_profile "$app/Contents/embedded.provisionprofile" com.idlescreen.app 11111111-1111-1111-1111-111111111111
  write_profile "$extension/Contents/embedded.provisionprofile" com.idlescreen.app.screensaver 22222222-2222-2222-2222-222222222222
  write_profile "$helper/Contents/embedded.provisionprofile" com.idlescreen.camera-agent 33333333-3333-3333-3333-333333333333

  compile_plain_binary "$app/Contents/MacOS/IdleScreen"
  compile_plain_binary "$extension/Contents/MacOS/IdleScreenScreenSaver"
  compile_camera_binary "$helper/Contents/MacOS/IdleScreenCameraAgent"
  compile_plain_binary "$renderer/Versions/A/IdleScreenRenderer"
  compile_plain_binary "$control_tool"
}

/usr/bin/printf 'int main(void) { return 0; }\n' >"$scratch_root/plain.c"
/usr/bin/printf '%s\n' \
  '#include <stdio.h>' \
  'int main(void) { puts("IDLESCREEN_CTL_SCRATCH_ROOT"); puts("group.com.idlescreen.tests.scratch"); return 0; }' \
  >"$scratch_root/scratch-gate.c"
/usr/bin/printf '%s\n' \
  '#import <AVFoundation/AVFoundation.h>' \
  'int main(void) { return [AVCaptureSession class] == Nil; }' \
  >"$scratch_root/camera.m"
/usr/bin/printf '%s\n' \
  '#import <AVFoundation/AVFoundation.h>' \
  'int main(void) { return [AVAsset class] == Nil; }' \
  >"$scratch_root/framework-only.m"

mock_codesign="$scratch_root/mock-codesign.sh"
mock_security="$scratch_root/mock-security.sh"
fixture_script="$script_root/$(/usr/bin/basename "$0")"
/bin/ln -s "$fixture_script" "$mock_codesign"
/bin/ln -s "$fixture_script" "$mock_security"

run_verifier() {
  IDLESCREEN_PROVENANCE_FIXTURE_MODE=YES \
  IDLESCREEN_PROVENANCE_CODESIGN="$mock_codesign" \
  IDLESCREEN_PROVENANCE_SECURITY="$mock_security" \
  IDLESCREEN_MOCK_LEAF_CERTIFICATE="$leaf_certificate" \
  IDLESCREEN_MOCK_OTHER_CERTIFICATE="$other_certificate" \
    "$verifier" "$@"
}

expect_pass() {
  local description="$1"
  local archive="$2"
  local manifest="$3"
  local output

  output="$(run_verifier "$archive" "$manifest" 2>&1)" ||
    fail "$description should pass, got: $output"
  /usr/bin/grep -Fq 'verification_mode=fixture' "$manifest" ||
    fail "$description did not label its evidence as fixture-only"
  /usr/bin/grep -Eq '^archive_tree_sha256=[0-9a-f]{64}$' "$manifest" ||
    fail "$description did not emit a canonical archive hash"
  /usr/bin/grep -Fq 'signer_certificate_sha256=' "$manifest" ||
    fail "$description did not bind the shared signer certificate"
  /usr/bin/grep -Fqx 'renderer_bundle_identifier=com.idlescreen.renderer' "$manifest" ||
    fail "$description did not bind the renderer bundle identifier"
  /usr/bin/grep -Fqx 'renderer_cdhash=4444444444444444444444444444444444444444' "$manifest" ||
    fail "$description did not bind the renderer CDHash"
  /usr/bin/grep -Fqx 'control_tool_signing_identifier=com.idlescreen.ctl' "$manifest" ||
    fail "$description did not bind the idlescreenctl signing identifier"
  /usr/bin/grep -Fqx 'control_tool_cdhash=5555555555555555555555555555555555555555' "$manifest" ||
    fail "$description did not bind the idlescreenctl CDHash"
  /usr/bin/grep -Fq 'fixture-mode evidence is parser coverage' <<<"$output" ||
    fail "$description did not disclaim fixture evidence"
  echo "PASS: $description"
}

expect_fail() {
  local description="$1"
  local archive="$2"
  local expected_message="$3"
  local manifest="$scratch_root/${description// /-}.manifest"
  local output

  if output="$(run_verifier "$archive" "$manifest" 2>&1)"; then
    fail "$description unexpectedly passed"
  fi
  [[ ! -e "$manifest" ]] || fail "$description left a trusted-looking manifest after failure"
  /usr/bin/grep -Fq "$expected_message" <<<"$output" ||
    fail "$description failed for the wrong reason: $output"
  echo "PASS: $description fails closed"
}

base_archive="$scratch_root/base/IdleScreen.xcarchive"
make_valid_archive "$base_archive"
base_manifest="$scratch_root/base.manifest"
expect_pass 'exact Release archive fixture' "$base_archive" "$base_manifest"

replay_manifest="$scratch_root/replay.manifest"
expect_pass 'deterministic manifest replay' "$base_archive" "$replay_manifest"
/usr/bin/cmp -s "$base_manifest" "$replay_manifest" ||
  fail "unchanged archive did not reproduce byte-identical provenance evidence"
echo 'PASS: unchanged archive reproduces byte-identical provenance evidence'

override_output="$scratch_root/override-without-fixture-mode.txt"
if IDLESCREEN_PROVENANCE_CODESIGN="$mock_codesign" \
   IDLESCREEN_PROVENANCE_SECURITY="$mock_security" \
   "$verifier" "$base_archive" "$override_output" >/dev/null 2>&1; then
  fail "command override without fixture mode unexpectedly passed"
fi
[[ ! -e "$override_output" ]] || fail "rejected command override emitted evidence"
echo 'PASS: command injection is refused outside explicit fixture mode'

get_task_app="$scratch_root/get-task-app/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$get_task_app"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.get-task-allow bool true' \
  "$get_task_app/Products/Applications/IdleScreen.app/Contents/fixture-entitlements.plist"
expect_fail 'app get-task-allow' "$get_task_app" 'app signed entitlements are not the exact Release entitlement set'

null_get_task_app="$scratch_root/null-get-task-app/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$null_get_task_app"
null_get_task_entitlements="$null_get_task_app/Products/Applications/IdleScreen.app/Contents/fixture-entitlements.plist"
/usr/bin/plutil -convert json -o "$scratch_root/null-get-task-base.json" "$null_get_task_entitlements"
/usr/bin/jq '. + {"com.apple.security.get-task-allow": null}' \
  "$scratch_root/null-get-task-base.json" >"$scratch_root/null-get-task.json"
/bin/cp "$scratch_root/null-get-task.json" "$null_get_task_entitlements"
expect_fail 'null get-task-allow' "$null_get_task_app" 'app signed entitlements'

get_task_profile="$scratch_root/get-task-profile/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$get_task_profile"
/usr/libexec/PlistBuddy -c 'Set :Entitlements:get-task-allow true' \
  "$get_task_profile/Products/Applications/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/embedded.provisionprofile"
expect_fail 'profile get-task-allow' "$get_task_profile" 'extension provisioning profile does not exactly authorize'

wrong_profile_group="$scratch_root/wrong-profile-group/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$wrong_profile_group"
/usr/libexec/PlistBuddy -c 'Set :Entitlements:com.apple.security.application-groups:0 group.example.wrong' \
  "$wrong_profile_group/Products/Applications/IdleScreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/embedded.provisionprofile"
expect_fail 'profile App Group drift' "$wrong_profile_group" 'helper provisioning profile does not exactly authorize'

mismatched_signer="$scratch_root/mismatched-signer/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$mismatched_signer"
/usr/bin/touch "$mismatched_signer/Products/Applications/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex/.mismatched-signer"
expect_fail 'nested signer disagreement' "$mismatched_signer" 'do not share one exact signing certificate'

wrong_team="$scratch_root/wrong-team/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$wrong_team"
/usr/bin/touch "$wrong_team/Products/Applications/IdleScreen.app/Contents/Helpers/IdleScreenCameraAgent.app/.wrong-team"
expect_fail 'nested TeamIdentifier drift' "$wrong_team" 'do not share the exact expected TeamIdentifier'

malformed_signature="$scratch_root/malformed-signature/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$malformed_signature"
/usr/bin/touch "$malformed_signature/Products/Applications/IdleScreen.app/.malformed-signature-metadata"
expect_fail 'ambiguous signature metadata' "$malformed_signature" 'signature metadata has no unique TeamIdentifier'

missing_runtime="$scratch_root/missing-runtime/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$missing_runtime"
/usr/bin/touch "$missing_runtime/Products/Applications/IdleScreen.app/Contents/Helpers/IdleScreenCameraAgent.app/.missing-runtime"
expect_fail 'missing hardened runtime' "$missing_runtime" 'helper CodeDirectory does not carry exactly the hardened-runtime flag'

adhoc_signature="$scratch_root/adhoc-signature/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$adhoc_signature"
/usr/bin/touch "$adhoc_signature/Products/Applications/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex/.adhoc-signature"
expect_fail 'ad-hoc nested signature' "$adhoc_signature" 'extension CodeDirectory does not carry exactly the hardened-runtime flag'

malformed_requirement="$scratch_root/malformed-requirement/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$malformed_requirement"
/usr/bin/touch "$malformed_requirement/Products/Applications/IdleScreen.app/.malformed-designated-requirement"
expect_fail 'designated requirement identity drift' "$malformed_requirement" 'app designated requirement is not identifier-specific Apple Development code'

extra_requirement_clause="$scratch_root/extra-requirement-clause/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$extra_requirement_clause"
/usr/bin/touch "$extra_requirement_clause/Products/Applications/IdleScreen.app/.extra-designated-clause"
expect_fail 'designated requirement extra clause' "$extra_requirement_clause" 'app designated requirement is not identifier-specific Apple Development code'

missing_camera_entitlement="$scratch_root/missing-camera-entitlement/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$missing_camera_entitlement"
/usr/libexec/PlistBuddy -c 'Delete :com.apple.security.device.camera' \
  "$missing_camera_entitlement/Products/Applications/IdleScreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/fixture-entitlements.plist"
expect_fail 'helper missing camera entitlement' "$missing_camera_entitlement" 'helper signed entitlements are not the exact Release entitlement set'

missing_app_camera_entitlement="$scratch_root/missing-app-camera-entitlement/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$missing_app_camera_entitlement"
/usr/libexec/PlistBuddy -c 'Delete :com.apple.security.device.camera' \
  "$missing_app_camera_entitlement/Products/Applications/IdleScreen.app/Contents/fixture-entitlements.plist"
expect_fail 'responsible app missing camera entitlement' "$missing_app_camera_entitlement" 'app signed entitlements are not the exact Release entitlement set'

control_tool_group_drift="$scratch_root/control-tool-group-drift/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$control_tool_group_drift"
/usr/libexec/PlistBuddy -c 'Set :com.apple.security.application-groups:0 group.example.wrong' \
  "$control_tool_group_drift/Products/Applications/IdleScreen.app/Contents/Helpers/idlescreenctl.fixture-entitlements.plist"
expect_fail 'control tool App Group drift' "$control_tool_group_drift" 'control-tool signed entitlements are not the exact Release entitlement set'

missing_control_tool="$scratch_root/missing-control-tool/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$missing_control_tool"
/bin/rm -f "$missing_control_tool/Products/Applications/IdleScreen.app/Contents/Helpers/idlescreenctl"
expect_fail 'missing control tool' "$missing_control_tool" 'required product executable is missing or non-executable'

scratch_gated_control_tool="$scratch_root/scratch-gated-control-tool/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$scratch_gated_control_tool"
compile_scratch_gate_binary \
  "$scratch_gated_control_tool/Products/Applications/IdleScreen.app/Contents/Helpers/idlescreenctl"
expect_fail 'Release control tool scratch gate' "$scratch_gated_control_tool" \
  'Release control tool contains the Debug-only scratch-container gate'

helper_without_linkage="$scratch_root/helper-without-linkage/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$helper_without_linkage"
compile_plain_binary "$helper_without_linkage/Products/Applications/IdleScreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
expect_fail 'helper without capture linkage' "$helper_without_linkage" 'helper is missing AVFoundation linkage'

helper_framework_only="$scratch_root/helper-framework-only/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$helper_framework_only"
compile_framework_only_binary "$helper_framework_only/Products/Applications/IdleScreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
expect_fail 'helper framework-only linkage' "$helper_framework_only" 'helper is missing an actual AVCapture symbol or import'

app_with_linkage="$scratch_root/app-with-linkage/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$app_with_linkage"
compile_camera_binary "$app_with_linkage/Products/Applications/IdleScreen.app/Contents/MacOS/IdleScreen"
expect_fail 'AVFoundation linkage outside helper' "$app_with_linkage" 'app must not carry camera capture or AVFoundation linkage'

purpose_drift="$scratch_root/purpose-drift/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$purpose_drift"
/usr/libexec/PlistBuddy -c 'Set :NSCameraUsageDescription wrong purpose' \
  "$purpose_drift/Products/Applications/IdleScreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/Info.plist"
expect_fail 'purpose-string drift' "$purpose_drift" 'camera purpose strings are not the exact shared Release purpose'

extension_purpose="$scratch_root/extension-purpose/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$extension_purpose"
/usr/libexec/PlistBuddy -c 'Add :NSCameraUsageDescription string forbidden extension purpose' \
  "$extension_purpose/Products/Applications/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/Info.plist"
expect_fail 'extension camera purpose' "$extension_purpose" 'extension must not carry a camera purpose string'

launch_agent_drift="$scratch_root/launch-agent-drift/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$launch_agent_drift"
/usr/libexec/PlistBuddy -c 'Set :AssociatedBundleIdentifiers com.example.wrong' \
  "$launch_agent_drift/Products/Applications/IdleScreen.app/Contents/Library/LaunchAgents/group.com.idlescreen.shared.camera-agent.plist"
expect_fail 'LaunchAgent tuple drift' "$launch_agent_drift" 'Release LaunchAgent tuple is not exact'

helper_marker="$scratch_root/helper-marker/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$helper_marker"
/usr/libexec/PlistBuddy -c 'Add :IdleScreenSyntheticGateVersion string 1' \
  "$helper_marker/Products/Applications/IdleScreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/Info.plist"
expect_fail 'production helper marker' "$helper_marker" 'production product contains a synthetic gate marker'

extension_marker="$scratch_root/extension-marker/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$extension_marker"
/usr/libexec/PlistBuddy -c 'Add :IdleScreenSyntheticHostedGateVersion string 1' \
  "$extension_marker/Products/Applications/IdleScreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/Info.plist"
expect_fail 'production hosted marker' "$extension_marker" 'production product contains a synthetic gate marker'

resource_marker="$scratch_root/resource-marker/IdleScreen.xcarchive"
/usr/bin/ditto "$base_archive" "$resource_marker"
/bin/mkdir -p "$resource_marker/Products/Applications/IdleScreen.app/Contents/Resources"
/usr/bin/printf 'untrusted-key=IdleScreenSyntheticHostedGateVersion\n' \
  >"$resource_marker/Products/Applications/IdleScreen.app/Contents/Resources/untrusted-marker.bin"
expect_fail 'synthetic marker in resource file' "$resource_marker" 'production archive contains recursive synthetic gate marker bytes'

echo 'PASS: signed Release archive provenance fixture coverage is complete.'
