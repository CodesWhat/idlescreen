#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/IdleScreen.app [launch-cycles]" >&2
  exit 64
}

[[ $# -ge 1 && $# -le 2 ]] || usage

app_path="$1"
launch_cycles="${2:-1}"

[[ "$app_path" = /* ]] || usage
[[ "$launch_cycles" =~ ^[0-9]+$ ]] || usage

app_info="$app_path/Contents/Info.plist"
app_binary="$app_path/Contents/MacOS/IdleScreen"
extension_path="$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex"
extension_info="$extension_path/Contents/Info.plist"
extension_assets="$extension_path/Contents/Resources/Assets.car"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -d "$app_path" ]] || fail "missing app bundle: $app_path"
[[ -f "$app_info" ]] || fail "missing app Info.plist"
[[ -x "$app_binary" ]] || fail "missing app executable"
[[ -d "$extension_path" ]] || fail "missing embedded screen saver extension"
[[ -f "$extension_info" ]] || fail "missing extension Info.plist"
[[ -f "$extension_assets" ]] || fail "missing compiled extension asset catalog"

app_id="$(plutil -extract CFBundleIdentifier raw "$app_info")"
extension_id="$(plutil -extract CFBundleIdentifier raw "$extension_info")"
extension_point="$(plutil -extract NSExtension.NSExtensionPointIdentifier raw "$extension_info")"
extension_version="$(plutil -extract NSExtension.NSExtensionPointVersion raw "$extension_info")"

[[ "$extension_id" == "$app_id.screensaver" ]] ||
  fail "extension bundle ID '$extension_id' is outside app family '$app_id'"
[[ "$extension_point" == "com.apple.screensaver" ]] ||
  fail "unexpected extension point: $extension_point"
[[ "$extension_version" == "1.0" ]] ||
  fail "unexpected screen saver extension version: $extension_version"

app_camera_description="$(
  plutil -extract NSCameraUsageDescription raw "$app_info" 2>/dev/null || true
)"
[[ -n "$app_camera_description" ]] ||
  fail "camera-enabled companion is missing its privacy usage description"
if plutil -p "$extension_info" | grep -Fq 'NSCameraUsageDescription'; then
  fail "screen saver extension must remain camera-free and use the isolated helper"
fi

asset_info="$(xcrun assetutil --info "$extension_assets")"
grep -Fq '"Name" : "thumbnail"' <<<"$asset_info" ||
  fail "compiled extension is missing its System Settings thumbnail"

for forbidden_framework in IdleScreenCore.framework IdleScreenSystem.framework; do
  [[ ! -e "$app_path/Contents/Frameworks/$forbidden_framework" ]] ||
    fail "static archive was incorrectly embedded: $forbidden_framework"
done

codesign --verify --deep --strict "$app_path" 2>&1 ||
  fail "nested code signature verification failed"
codesign --verify --strict "$extension_path" 2>&1 ||
  fail "extension signature verification failed"

selected_extension_path() {
  /usr/bin/pluginkit -m -v -p com.apple.screensaver | awk -F '\t' -v identity="$extension_id(" '
    index($1, identity) {
      path = $NF
      sub(/^[[:space:]]+/, "", path)
      sub(/[[:space:]]+$/, "", path)
      print path
      exit
    }
  '
}

registered_extension_paths() {
  /usr/bin/pluginkit -m -A -D -v -p com.apple.screensaver | awk -F '\t' -v identity="$extension_id(" '
    index($1, identity) {
      path = $NF
      sub(/^[[:space:]]+/, "", path)
      sub(/[[:space:]]+$/, "", path)
      print path
    }
  '
}

paths_refer_to_same_file() {
  [[ -n "$1" && -n "$2" ]] || return 1
  [[ "$(/bin/realpath "$1")" == "$(/bin/realpath "$2")" ]]
}

wait_for_selected_extension_path() {
  local expected_path="$1"
  local deadline=$((SECONDS + 10))
  local current_path

  while ((SECONDS < deadline)); do
    current_path="$(selected_extension_path)"
    if [[ -z "$expected_path" && -z "$current_path" ]]; then
      return 0
    fi
    if paths_refer_to_same_file "$current_path" "$expected_path"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

normalized_registered_extension_paths() {
  while IFS= read -r path; do
    [[ -z "$path" ]] || /bin/realpath "$path"
  done < <(registered_extension_paths)
}

wait_for_registered_extension_paths() {
  local expected_paths="$1"
  local deadline=$((SECONDS + 10))
  local current_paths

  while ((SECONDS < deadline)); do
    current_paths="$(normalized_registered_extension_paths | sort)"
    if [[ "$current_paths" == "$expected_paths" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

original_selected_path="$(selected_extension_path)"
original_registered_paths="$(registered_extension_paths)"
original_normalized_registered_paths="$(
  while IFS= read -r path; do
    [[ -z "$path" ]] || /bin/realpath "$path"
  done <<<"$original_registered_paths" | sort
)"
registration_was_changed=false

restore_registration() {
  $registration_was_changed || return 0

  while IFS= read -r registered_path; do
    [[ -z "$registered_path" ]] || /usr/bin/pluginkit -r "$registered_path" || return 1
  done <<<"$(registered_extension_paths)"

  while IFS= read -r original_path; do
    [[ -z "$original_path" ]] && continue
    if ! paths_refer_to_same_file "$original_path" "$original_selected_path"; then
      /usr/bin/pluginkit -a "$original_path" || return 1
    fi
  done <<<"$original_registered_paths"

  if [[ -n "$original_selected_path" ]]; then
    /usr/bin/pluginkit -a "$original_selected_path" || return 1
  fi
  wait_for_registered_extension_paths "$original_normalized_registered_paths" || return 1
  wait_for_selected_extension_path "$original_selected_path" || return 1
  registration_was_changed=false
}

trap 'restore_registration >/dev/null 2>&1 || true' EXIT

registration_was_changed=true
while IFS= read -r registered_path; do
  [[ -z "$registered_path" ]] && continue
  if ! paths_refer_to_same_file "$registered_path" "$extension_path"; then
    /usr/bin/pluginkit -r "$registered_path"
  fi
done <<<"$original_registered_paths"
/usr/bin/pluginkit -a "$extension_path"
expected_registered_path="$(/bin/realpath "$extension_path")"
wait_for_registered_extension_paths "$expected_registered_path" ||
  fail "pluginkit did not register only the embedded extension within 10 seconds"

while IFS= read -r known_path; do
  [[ -z "$known_path" ]] && continue
  paths_refer_to_same_file "$known_path" "$extension_path" ||
    fail "pluginkit retained stale screen saver copy '$known_path'"
done <<<"$(registered_extension_paths)"

echo "PASS: signed app and embedded extension bundle contracts are valid."
echo "PASS: pluginkit reports only the embedded $extension_id path."

for ((cycle = 1; cycle <= launch_cycles; cycle += 1)); do
  probe_token="--idlescreen-lifecycle-probe=$$-$cycle"
  /usr/bin/open -g -j -n "$app_path" --args "$probe_token"

  app_pid=""
  for _ in {1..20}; do
    app_pid="$(pgrep -f -- "$probe_token" | head -1 || true)"
    [[ -z "$app_pid" ]] || break
    sleep 0.1
  done

  [[ -n "$app_pid" ]] || fail "LaunchServices did not start cycle $cycle"
  sleep 1
  kill -0 "$app_pid" 2>/dev/null || fail "app exited during launch cycle $cycle"

  kill -TERM "$app_pid"
  for _ in {1..20}; do
    if ! kill -0 "$app_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  if kill -0 "$app_pid" 2>/dev/null; then
    kill -KILL "$app_pid"
    fail "app did not terminate cleanly during launch cycle $cycle"
  fi
done

echo "PASS: IdleScreen survived $launch_cycles launch/terminate cycles."

restore_registration || fail "could not restore the pre-test screen saver registration"
restored_selected_path="$(selected_extension_path)"
if [[ -n "$original_selected_path" ]]; then
  paths_refer_to_same_file "$restored_selected_path" "$original_selected_path" ||
    fail "restored registration '$restored_selected_path' does not match '$original_selected_path'"
elif [[ -n "$restored_selected_path" ]]; then
  fail "test created unexpected selected registration '$restored_selected_path'"
fi

restored_sorted_paths="$(normalized_registered_extension_paths | sort)"
[[ "$restored_sorted_paths" == "$original_normalized_registered_paths" ]] ||
  fail "pre-test physical registration set was not restored"
trap - EXIT

echo "PASS: pre-test screen saver registration was preserved."
