#!/bin/bash

# Pure validation helpers for an already CMS-decoded provisioning profile.
# Callers own the profile's CMS verification and the scratch directory.

camera_agent_profile_is_current() {
  local profile_plist="$1"
  local current_epoch="${2//_/}"
  local expiration
  local expiration_epoch

  [[ "$current_epoch" =~ ^[1-9][0-9]*$ ]] || return 1
  expiration="$(
    /usr/bin/plutil -extract ExpirationDate raw "$profile_plist" 2>/dev/null || true
  )"
  expiration_epoch="$(
    /bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$expiration" '+%s' 2>/dev/null || true
  )"
  [[ "$expiration_epoch" =~ ^[1-9][0-9]*$ ]] || return 1
  ((expiration_epoch > current_epoch))
}

camera_agent_profile_is_development() {
  local profile_plist="$1"
  local provisioned_device
  local provisions_all_devices

  provisioned_device="$(
    /usr/bin/plutil -extract ProvisionedDevices.0 raw "$profile_plist" 2>/dev/null || true
  )"
  provisions_all_devices="$(
    /usr/bin/plutil -extract ProvisionsAllDevices raw "$profile_plist" 2>/dev/null || true
  )"
  [[ -n "$provisioned_device" && "$provisions_all_devices" != true ]]
}

camera_agent_profile_authorizes_signer() {
  local profile_plist="$1"
  local signer_certificate="$2"
  local scratch_root="$3"
  local profile_certificate_base64
  local profile_certificate
  local profile_certificate_count=0
  local profile_certificate_index

  [[ -s "$signer_certificate" ]] || return 1
  /bin/mkdir -p "$scratch_root" || return 1
  for profile_certificate_index in $(/usr/bin/seq 0 31); do
    profile_certificate_base64="$(
      /usr/bin/plutil \
        -extract "DeveloperCertificates.$profile_certificate_index" raw \
        "$profile_plist" 2>/dev/null || true
    )"
    [[ -n "$profile_certificate_base64" ]] || break
    profile_certificate_count=$((profile_certificate_count + 1))
    profile_certificate="$scratch_root/profile-developer-certificate-$profile_certificate_index"
    /usr/bin/printf '%s' "$profile_certificate_base64" |
      /usr/bin/base64 -D >"$profile_certificate" 2>/dev/null || return 1
    /usr/bin/cmp -s "$signer_certificate" "$profile_certificate" && return 0
  done
  ((profile_certificate_count > 0)) || return 1
  return 1
}

camera_agent_profile_authorizes_app_group() {
  local profile_plist="$1"
  local expected_app_group="$2"
  local expected_team_identifier="$3"
  local profile_app_group_count=0
  local profile_team_wildcard_count=0
  local profile_group
  local profile_group_index

  for profile_group_index in $(/usr/bin/seq 0 31); do
    profile_group="$(
      /usr/libexec/PlistBuddy \
        -c "Print :Entitlements:com.apple.security.application-groups:$profile_group_index" \
        "$profile_plist" 2>/dev/null || true
    )"
    [[ -n "$profile_group" ]] || break
    case "$profile_group" in
      "$expected_app_group") profile_app_group_count=$((profile_app_group_count + 1)) ;;
      "$expected_team_identifier.*") profile_team_wildcard_count=$((profile_team_wildcard_count + 1)) ;;
      *) return 1 ;;
    esac
  done
  [[ "$profile_app_group_count" == 1 && "$profile_team_wildcard_count" -le 1 ]]
}
