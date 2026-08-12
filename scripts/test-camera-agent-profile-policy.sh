#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
policy="$project_root/scripts/camera-agent-profile-policy.sh"
scratch_root="$(mktemp -d /tmp/idlescreen-camera-profile-policy.XXXXXX)"
trap '/bin/rm -rf "$scratch_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$policy" ]] || fail "missing camera-agent profile policy library"
# shellcheck source=camera-agent-profile-policy.sh
source "$policy"

future_profile="$scratch_root/future.plist"
expired_profile="$scratch_root/expired.plist"
invalid_profile="$scratch_root/invalid.plist"
/usr/bin/plutil -create xml1 "$future_profile"
/usr/bin/plutil -insert ExpirationDate -date '2040-01-01T00:00:00Z' "$future_profile"
/usr/bin/plutil -create xml1 "$expired_profile"
/usr/bin/plutil -insert ExpirationDate -date '2020-01-01T00:00:00Z' "$expired_profile"
/usr/bin/plutil -create xml1 "$invalid_profile"
/usr/bin/plutil -insert ExpirationDate -string 'not-a-date' "$invalid_profile"

camera_agent_profile_is_current "$future_profile" 2_000_000_000 ||
  fail "a future profile was rejected"
if camera_agent_profile_is_current "$expired_profile" 2_000_000_000; then
  fail "an expired profile was accepted"
fi
if camera_agent_profile_is_current "$invalid_profile" 2_000_000_000; then
  fail "a malformed ExpirationDate was accepted"
fi

development_profile="$scratch_root/development.plist"
distribution_profile="$scratch_root/distribution.plist"
/usr/bin/plutil -create xml1 "$development_profile"
/usr/bin/plutil -insert ProvisionedDevices -array "$development_profile"
/usr/bin/plutil -insert ProvisionedDevices.0 -string 'test-device' "$development_profile"
/usr/bin/plutil -create xml1 "$distribution_profile"
/usr/bin/plutil -insert ProvisionedDevices -array "$distribution_profile"
/usr/bin/plutil -insert ProvisionedDevices.0 -string 'test-device' "$distribution_profile"
/usr/bin/plutil -insert ProvisionsAllDevices -bool true "$distribution_profile"

camera_agent_profile_is_development "$development_profile" ||
  fail "a device-scoped development profile was rejected"
if camera_agent_profile_is_development "$distribution_profile"; then
  fail "an all-devices distribution profile was accepted as development"
fi

/usr/bin/printf 'signer-certificate' >"$scratch_root/signer.der"
/usr/bin/printf 'different-certificate' >"$scratch_root/different.der"
certificate_profile="$scratch_root/certificates.plist"
/usr/bin/plutil -create xml1 "$certificate_profile"
/usr/bin/plutil -insert DeveloperCertificates -array "$certificate_profile"
/usr/bin/plutil -insert DeveloperCertificates.0 -data \
  "$(/usr/bin/base64 <"$scratch_root/different.der")" "$certificate_profile"
/usr/bin/plutil -insert DeveloperCertificates.1 -data \
  "$(/usr/bin/base64 <"$scratch_root/signer.der")" "$certificate_profile"

camera_agent_profile_authorizes_signer \
  "$certificate_profile" "$scratch_root/signer.der" "$scratch_root/decoded-certificates" ||
  fail "a signer listed in DeveloperCertificates was rejected"
if camera_agent_profile_authorizes_signer \
  "$certificate_profile" "$scratch_root/unlisted.der" "$scratch_root/unlisted-decode"; then
  fail "a missing signer certificate was accepted"
fi
/usr/bin/printf 'unlisted-certificate' >"$scratch_root/unlisted.der"
if camera_agent_profile_authorizes_signer \
  "$certificate_profile" "$scratch_root/unlisted.der" "$scratch_root/unlisted-decode"; then
  fail "an unlisted signer certificate was accepted"
fi

write_groups() {
  local path="$1"
  shift
  /usr/bin/plutil -create xml1 "$path"
  /usr/libexec/PlistBuddy \
    -c 'Add :Entitlements dict' \
    -c 'Add :Entitlements:com.apple.security.application-groups array' \
    "$path"
  local index=0
  for group in "$@"; do
    /usr/libexec/PlistBuddy \
      -c "Add :Entitlements:com.apple.security.application-groups:$index string $group" \
      "$path"
    index=$((index + 1))
  done
}

expected_group='group.com.idlescreen.shared'
team_identifier='3524374A2S'
write_groups "$scratch_root/group-only.plist" "$expected_group"
write_groups "$scratch_root/group-and-wildcard.plist" "$expected_group" "$team_identifier.*"
write_groups "$scratch_root/wildcard-only.plist" "$team_identifier.*"
write_groups "$scratch_root/extra-group.plist" "$expected_group" group.com.example.unexpected
write_groups "$scratch_root/duplicate-group.plist" "$expected_group" "$expected_group"

camera_agent_profile_authorizes_app_group \
  "$scratch_root/group-only.plist" "$expected_group" "$team_identifier" ||
  fail "a profile with only the exact App Group was rejected"
camera_agent_profile_authorizes_app_group \
  "$scratch_root/group-and-wildcard.plist" "$expected_group" "$team_identifier" ||
  fail "the exact App Group plus team wildcard was rejected"
for invalid_groups in wildcard-only extra-group duplicate-group; do
  if camera_agent_profile_authorizes_app_group \
    "$scratch_root/$invalid_groups.plist" "$expected_group" "$team_identifier"; then
    fail "invalid profile App Group set '$invalid_groups' was accepted"
  fi
done

echo 'PASS: camera-agent profile expiry, signer membership, and App Group policy fail closed.'
