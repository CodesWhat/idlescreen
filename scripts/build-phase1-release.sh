#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
project="$project_root/IdleScreen.xcodeproj"
extension_id="com.idlescreen.app.screensaver"
signing_verifier="$project_root/scripts/verify-release-signing.sh"
product_verifier="$project_root/scripts/test-modern-product.sh"
camera_product_verifier="$project_root/scripts/test-camera-agent-product.sh"
artifact_root=""
wallpaper_refresh_pending=false

fail() {
  echo "FAIL: $*" >&2
  echo "Evidence: $artifact_root" >&2
  exit 1
}

console_is_locked() {
  local lock_state
  lock_state="$("$project_root/scripts/read-console-lock-state.sh")" || return 2
  case "$lock_state" in
    true) return 0 ;;
    false) return 1 ;;
    *) return 2 ;;
  esac
}

set +e
console_is_locked
console_lock_status=$?
set -e
if ((console_lock_status == 0)); then
  echo "REFUSED: the console is locked; unlock normally before building a Release candidate." >&2
  exit 65
elif ((console_lock_status != 1)); then
  echo "REFUSED: the console lock state could not be verified; Release discovery will not run fail-open." >&2
  exit 65
fi
if pgrep -x ScreenSaverEngine >/dev/null; then
  echo "REFUSED: ScreenSaverEngine is active; finish and invalidate the physical session before building Release." >&2
  exit 65
fi
if /bin/ps ax -o comm= |
   grep -Fq '/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver'; then
  echo "REFUSED: a modern screen-saver extension is active; finish the physical session before building Release." >&2
  exit 65
fi
if pgrep -x 'System Settings' >/dev/null; then
  echo "REFUSED: System Settings is open; quit it before building Release so the chooser cannot cache a Derived Data extension path." >&2
  exit 65
fi

artifact_root="$(mktemp -d /tmp/idlescreen-phase1-release.XXXXXX)"
derived_data="$artifact_root/DerivedData"
candidate_app="$derived_data/Build/Products/Release/IdleScreen.app"
selection_probe="$artifact_root/selection-probe"

[[ -x "$signing_verifier" ]] || fail "missing Release signing verifier"
[[ -x "$product_verifier" ]] || fail "missing modern product verifier"
[[ -x "$camera_product_verifier" ]] || fail "missing camera-agent product verifier"

xcrun swiftc \
  "$project_root/Sources/IdleScreenSystem/ScreenSaverSelection.swift" \
  "$project_root/scripts/ScreenSaverSelectionProbe.swift" \
  -o "$selection_probe" || fail "could not compile the production selection probe"
selection_before="$($selection_probe "$extension_id")" || {
  printf '%s\n' "$selection_before" >&2
  fail "$extension_id is not the screen saver selected everywhere"
}
printf '%s\n' "$selection_before" >"$artifact_root/selection-before.txt"

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

normalized_registered_extension_paths() {
  while IFS= read -r registered_path; do
    [[ -z "$registered_path" ]] || /bin/realpath "$registered_path"
  done < <(registered_extension_paths)
}

wait_for_registration_state() {
  local expected_selected_path="$1"
  local expected_registered_paths="$2"
  local deadline=$((SECONDS + 15))
  local current_selected_path
  local current_registered_paths

  while ((SECONDS < deadline)); do
    current_selected_path="$(selected_extension_path)"
    current_registered_paths="$(normalized_registered_extension_paths | sort)"
    if [[ "$current_registered_paths" == "$expected_registered_paths" ]]; then
      if [[ -z "$expected_selected_path" && -z "$current_selected_path" ]]; then
        return 0
      fi
      if paths_refer_to_same_file "$current_selected_path" "$expected_selected_path"; then
        return 0
      fi
    fi
    sleep 0.1
  done
  return 1
}

original_selected_path="$(selected_extension_path)"
original_registered_paths="$(registered_extension_paths)"
original_normalized_registered_paths="$(
  while IFS= read -r original_path; do
    [[ -z "$original_path" ]] || /bin/realpath "$original_path"
  done <<<"$original_registered_paths" | sort
)"
registration_restore_pending=true

restore_preflight_registration() {
  $registration_restore_pending || return 0

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
  wait_for_registration_state \
    "$original_selected_path" \
    "$original_normalized_registered_paths" || return 1
  registration_restore_pending=false
}

refresh_wallpaper_agent() {
  $wallpaper_refresh_pending || return 0
  local old_pid_list
  local old_pid_set
  local current_pid
  old_pid_list="$(pgrep -x WallpaperAgent 2>/dev/null | paste -sd '|' - || true)"
  old_pid_set="|$old_pid_list|"
  /usr/bin/killall WallpaperAgent >/dev/null 2>&1 || true
  local deadline=$((SECONDS + 15))
  while ((SECONDS < deadline)); do
    while IFS= read -r current_pid; do
      [[ "$current_pid" =~ ^[1-9][0-9]*$ ]] || continue
      if [[ "$old_pid_set" != *"|$current_pid|"* ]]; then
        wallpaper_refresh_pending=false
        return 0
      fi
    done < <(pgrep -x WallpaperAgent 2>/dev/null || true)
    sleep 0.1
  done
  return 1
}

handle_builder_exit() {
  local command_exit=$?
  trap - EXIT
  if $registration_restore_pending; then
    if ! restore_preflight_registration; then
      echo "CRITICAL: Release registration restoration failed; inspect $artifact_root before continuing." >&2
      exit 70
    fi
  fi
  if ! refresh_wallpaper_agent; then
    echo "CRITICAL: no new WallpaperAgent PID appeared after Release registration restoration; inspect $artifact_root before continuing." >&2
    exit 70
  fi
  exit "$command_exit"
}

trap handle_builder_exit EXIT

{
  printf 'capturedAtUTC=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'selectedPath=%s\n' "$original_selected_path"
  printf 'registeredPaths:\n%s\n' "$original_registered_paths"
} >"$artifact_root/registration-before.txt"
/usr/bin/sw_vers >"$artifact_root/sw-vers.txt"
xcodebuild -version >"$artifact_root/xcode-version.txt"

wallpaper_refresh_pending=true
xcodebuild build \
  -project "$project" \
  -scheme IdleScreenApp \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  -allowProvisioningUpdates \
  >"$artifact_root/build.log" 2>&1 || {
    tail -100 "$artifact_root/build.log" >&2
    fail "provisioned Release build failed"
  }

[[ -d "$candidate_app" ]] || fail "Release build did not produce $candidate_app"
"$signing_verifier" "$candidate_app" | tee "$artifact_root/signing-verification.txt"
"$camera_product_verifier" "$candidate_app" Release |
  tee "$artifact_root/camera-agent-product-verification.txt"
"$product_verifier" "$candidate_app" 0 | tee "$artifact_root/product-verification.txt"

{
  /usr/bin/shasum -a 256 "$candidate_app/Contents/MacOS/IdleScreen"
  /usr/bin/shasum -a 256 \
    "$candidate_app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver"
} >"$artifact_root/product-sha256.txt"

restore_preflight_registration || fail "could not restore the pre-build Release registration"
refresh_wallpaper_agent || fail "no new WallpaperAgent PID appeared after registration restoration"
selection_after="$($selection_probe "$extension_id")" ||
  fail "the provisioned Release build changed the production screen saver selection"
[[ "$selection_after" == "$selection_before" ]] ||
  fail "the production screen saver provider set changed during the Release build"
printf '%s\n' "$selection_after" >"$artifact_root/selection-after.txt"
{
  printf 'capturedAtUTC=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'selectedPath=%s\n' "$(selected_extension_path)"
  printf 'registeredPaths:\n%s\n' "$(registered_extension_paths)"
} >"$artifact_root/registration-after.txt"
trap - EXIT

echo "PASS: provisioned Phase 1 Release candidate built and verified."
echo "PASS: pre-build Release registration and production selection were restored."
echo "Candidate: $candidate_app"
echo "Evidence: $artifact_root"
