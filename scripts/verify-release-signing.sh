#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/idlescreen.app [expected-team-id]" >&2
  exit 64
}

[[ $# -ge 1 && $# -le 2 ]] || usage

app_path="$1"
expected_team_identifier="${2:-3524374A2S}"
expected_app_identifier="com.idlescreen.app"
expected_extension_identifier="com.idlescreen.app.screensaver"
expected_app_group="group.com.idlescreen.shared"
extension_path="$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex"
app_info="$app_path/Contents/Info.plist"
extension_info="$extension_path/Contents/Info.plist"
app_profile="$app_path/Contents/embedded.provisionprofile"
extension_profile="$extension_path/Contents/embedded.provisionprofile"
scratch_root="$(mktemp -d /tmp/idlescreen-release-signing.XXXXXX)"
trap 'rm -rf "$scratch_root"' EXIT

[[ "$app_path" = /* ]] || usage
[[ "$expected_team_identifier" =~ ^[A-Z0-9]{10}$ ]] || usage

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$app_info" ]] || fail "missing app Info.plist"
[[ -f "$extension_info" ]] || fail "missing embedded extension Info.plist"
[[ -f "$app_profile" ]] || fail "missing app embedded.provisionprofile"
[[ -f "$extension_profile" ]] || fail "missing extension embedded.provisionprofile"

app_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app_info")"
extension_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$extension_info")"
[[ "$app_identifier" == "$expected_app_identifier" ]] ||
  fail "unexpected Release app identifier: $app_identifier"
[[ "$extension_identifier" == "$expected_extension_identifier" ]] ||
  fail "unexpected Release extension identifier: $extension_identifier"

/usr/bin/codesign --verify --deep --strict "$app_path" 2>&1 ||
  fail "nested Release signature verification failed"
/usr/bin/codesign --verify --strict "$extension_path" 2>&1 ||
  fail "extension signature verification failed"

signed_team_identifier() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 |
    awk -F= '/^TeamIdentifier=/ { print $2; exit }'
}

app_signed_team="$(signed_team_identifier "$app_path")"
extension_signed_team="$(signed_team_identifier "$extension_path")"
[[ "$app_signed_team" == "$expected_team_identifier" ]] ||
  fail "app TeamIdentifier=$app_signed_team, expected $expected_team_identifier"
[[ "$extension_signed_team" == "$expected_team_identifier" ]] ||
  fail "extension TeamIdentifier=$extension_signed_team, expected $expected_team_identifier"

validate_entitlements() {
  local product_path="$1"
  local product_name="$2"
  local bundle_identifier="$3"
  local requires_sandbox="$4"
  local entitlement_file="$scratch_root/$product_name-entitlements.plist"
  local entitlement_json

  /usr/bin/codesign -d --entitlements :- "$product_path" >"$entitlement_file" 2>/dev/null ||
    fail "could not read $product_name entitlements"
  entitlement_json="$(/usr/bin/plutil -convert json -o - "$entitlement_file")" ||
    fail "could not decode $product_name entitlements"

  /usr/bin/jq -e \
    --arg team "$expected_team_identifier" \
    --arg application_identifier "$expected_team_identifier.$bundle_identifier" \
    --arg app_group "$expected_app_group" \
    '."com.apple.developer.team-identifier" == $team
      and ."com.apple.application-identifier" == $application_identifier
      and (."com.apple.security.application-groups" == [$app_group])' \
    <<<"$entitlement_json" >/dev/null ||
    fail "$product_name signature does not carry the exact Team ID, application ID, and App Group"

  if [[ "$requires_sandbox" == true ]]; then
    /usr/bin/jq -e '."com.apple.security.app-sandbox" == true' \
      <<<"$entitlement_json" >/dev/null ||
      fail "$product_name signature is missing the App Sandbox entitlement"
  fi
}

validate_profile() {
  local profile_path="$1"
  local product_name="$2"
  local bundle_identifier="$3"
  local decoded_profile="$scratch_root/$product_name-profile.plist"
  local profile_team
  local profile_entitlement_team
  local profile_application_identifier
  local profile_groups

  /usr/bin/security cms -D -i "$profile_path" -o "$decoded_profile" >/dev/null 2>&1 ||
    fail "could not decode $product_name provisioning profile"
  profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$decoded_profile")" ||
    fail "$product_name provisioning profile has no TeamIdentifier"
  profile_entitlement_team="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :Entitlements:com.apple.developer.team-identifier' \
      "$decoded_profile"
  )" || fail "$product_name provisioning profile has no team entitlement"
  profile_application_identifier="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :Entitlements:com.apple.application-identifier' \
      "$decoded_profile"
  )" || fail "$product_name provisioning profile has no application identifier"
  profile_groups="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :Entitlements:com.apple.security.application-groups' \
      "$decoded_profile"
  )" || fail "$product_name provisioning profile has no App Group authorization"

  [[ "$profile_team" == "$expected_team_identifier" ]] ||
    fail "$product_name provisioning profile has the wrong TeamIdentifier"
  [[ "$profile_entitlement_team" == "$expected_team_identifier" ]] ||
    fail "$product_name provisioning profile has the wrong team entitlement"
  [[ "$profile_application_identifier" == "$expected_team_identifier.$bundle_identifier" ]] ||
    fail "$product_name provisioning profile has the wrong application identifier"
  sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$profile_groups" |
    grep -Fxq "$expected_app_group" ||
    fail "$product_name provisioning profile does not authorize $expected_app_group"
}

validate_entitlements "$app_path" app "$app_identifier" false
validate_entitlements "$extension_path" extension "$extension_identifier" true
validate_profile "$app_profile" app "$app_identifier"
validate_profile "$extension_profile" extension "$extension_identifier"

echo "PASS: Release app and extension signatures share TeamIdentifier=$expected_team_identifier."
echo "PASS: both provisioning profiles authorize $expected_app_group for their exact application identifiers."
