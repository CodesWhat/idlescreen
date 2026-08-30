#!/bin/bash

set -euo pipefail

launch_cycles="${1:-1}"
[[ "$launch_cycles" =~ ^[0-9]+$ ]] || {
  echo "Usage: $0 [launch-cycles]" >&2
  exit 64
}

if [[ "${IDLESCREEN_ALLOW_PHYSICAL_TESTS:-NO}" != YES ]]; then
  echo "REFUSED: test-phase1.sh builds an application product and may change PlugInKit registration; set IDLESCREEN_ALLOW_PHYSICAL_TESTS=YES only after explicit physical authorization." >&2
  exit 65
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
artifact_root="$(mktemp -d /tmp/idlescreen-phase1.XXXXXX)"
project="$project_root/IdleScreen.xcodeproj"
destination="platform=macOS"
extension_id="com.idlescreen.app.dev.screensaver"

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

original_selected_path="$(selected_extension_path)"
original_registered_paths="$(registered_extension_paths)"
registration_restore_pending=true

restore_preflight_registration() {
  $registration_restore_pending || return 0

  while IFS= read -r registered_path; do
    [[ -z "$registered_path" ]] || /usr/bin/pluginkit -r "$registered_path" || return 1
  done <<<"$(registered_extension_paths)"

  while IFS= read -r original_path; do
    [[ -z "$original_path" ]] && continue
    if [[ "$original_path" != "$original_selected_path" ]]; then
      /usr/bin/pluginkit -a "$original_path" || return 1
    fi
  done <<<"$original_registered_paths"

  if [[ -n "$original_selected_path" ]]; then
    /usr/bin/pluginkit -a "$original_selected_path" || return 1
  fi
  wait_for_selected_extension_path "$original_selected_path" || return 1
  registration_restore_pending=false
}

trap 'restore_preflight_registration >/dev/null 2>&1 || true' EXIT

cd "$project_root"

xcodegen generate
./scripts/test-repository-layout.sh
./scripts/test-project-contracts.sh
./scripts/test-companion-compile-gate.sh "$artifact_root/CompanionCompileGate"
./scripts/test-console-lock-state.sh
./scripts/test-companion-launch-policy.sh
./scripts/test-live-configuration-delivery-guard.sh
./scripts/test-install-phase1-release-registration.sh
./scripts/test-idle-activation-log.sh
./scripts/test-record-host-lifecycle-matrix-cycle.sh
./scripts/test-host-lifecycle-matrix-evidence.sh
./scripts/test-host-lifecycle-matrix-guard.sh
./scripts/test-host-lifecycle-log.sh
./scripts/test-physical-state-transition.sh
./scripts/test-product-identity-verifier.sh
./scripts/test-shared-state-verifier.sh
./scripts/test-selection-probe.sh
./scripts/test-camera-agent-product-fixtures.sh
./scripts/test-camera-agent-profile-policy.sh
./scripts/test-camera-gate-c8-soak-planner.py
./scripts/test-controlled-physical-soak.py
./scripts/test-synthetic-gate-contracts.sh
./scripts/test-synthetic-gate-transaction.sh
./scripts/test-synthetic-gate-product-fixtures.sh
./scripts/test-camera-gate-a1-runner.sh

run_tests() {
  local scheme="$1"
  local result_name="$2"
  local derived_data="$artifact_root/${result_name}DerivedData"

  xcodebuild test -quiet \
    -project "$project" \
    -scheme "$scheme" \
    -destination "$destination" \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$artifact_root/$result_name.xcresult" \
    CODE_SIGNING_ALLOWED=NO
}

run_tests IdleScreenCore Core
run_tests IdleScreenCamera Camera
run_tests IdleScreenCameraAgent CameraAgent
run_tests IdleScreenSyntheticGateTests SyntheticGate
run_tests IdleScreenSystem System
run_tests IdleScreenScreenSaver ScreenSaver
run_tests IdleScreenAppCamera AppCamera
run_tests IdleScreenAppCompileGate AppCompileGate

xcodebuild build -quiet \
  -project "$project" \
  -scheme IdleScreenApp \
  -configuration Debug \
  -destination "$destination" \
  -derivedDataPath "$artifact_root/ModernDerivedData"

modern_app="$artifact_root/ModernDerivedData/Build/Products/Debug/IdleScreen.app"
./scripts/test-camera-agent-product.sh "$modern_app" Debug
./scripts/test-modern-product.sh "$modern_app" "$launch_cycles"

restore_preflight_registration || {
  echo "FAIL: could not restore the pre-gate screen saver registration" >&2
  exit 1
}

restored_selected_path="$(selected_extension_path)"
[[ "$restored_selected_path" == "$original_selected_path" ]] || {
  echo "FAIL: Phase 1 gate changed the selected screen saver registration" >&2
  exit 1
}

original_sorted_paths="$(sed '/^$/d' <<<"$original_registered_paths" | sort)"
restored_sorted_paths="$(registered_extension_paths | sed '/^$/d' | sort)"
[[ "$restored_sorted_paths" == "$original_sorted_paths" ]] || {
  echo "FAIL: Phase 1 gate changed the physical screen saver registration set" >&2
  exit 1
}
trap - EXIT

echo "PASS: complete Phase 1 verification finished."
echo "PASS: pre-gate screen saver registration was preserved."
echo "Evidence: $artifact_root"
