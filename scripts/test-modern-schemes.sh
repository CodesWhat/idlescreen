#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
requested_root="${1:-}"
cleanup_root=NO

if [[ -z "$requested_root" ]]; then
  result_root="$(mktemp -d /tmp/idlescreen-modern-schemes.XXXXXX)"
  cleanup_root=YES
else
  [[ "$requested_root" = /* && ! -e "$requested_root" ]] || {
    echo "Usage: $0 [/absolute/nonexistent/result/directory]" >&2
    exit 64
  }
  result_root="$requested_root"
  /bin/mkdir -p "$result_root"
fi

cleanup() {
  if [[ "$cleanup_root" == YES ]]; then
    /bin/rm -rf "${result_root:?}"
  fi
}
trap cleanup EXIT

schemes=(
  IdleScreenAgent
  IdleScreenCore
  IdleScreenDisplay
  IdleScreenRenderer
  IdleScreenPerformance
  IdleScreenCamera
  IdleScreenCameraAgent
  IdleScreenSyntheticGateTests
  IdleScreenSystem
  IdleScreenScreenSaver
  IdleScreenAppCamera
)

for scheme in "${schemes[@]}"; do
  result_bundle="$result_root/$scheme.xcresult"
  echo "Running $scheme"
  if ! xcodebuild test -quiet \
    -project "$project_root/IdleScreen.xcodeproj" \
    -scheme "$scheme" \
    -destination 'platform=macOS' \
    -derivedDataPath "$result_root/DerivedData/$scheme" \
    -resultBundlePath "$result_bundle" \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES; then
    xcrun xcresulttool get test-results summary --path "$result_bundle" || true
    xcrun xcresulttool get test-results tests --path "$result_bundle" || true
    exit 1
  fi
done

echo "PASS: ${#schemes[@]} modern Xcode schemes passed."
