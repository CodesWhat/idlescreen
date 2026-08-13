#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
artifact_root="${1:-$(mktemp -d /tmp/idlescreen-companion-compile-gate.XXXXXX)}"
project="$project_root/IdleScreen.xcodeproj"
log_path="$artifact_root/xcodebuild.log"

/bin/mkdir -p "$artifact_root"

set +e
xcodebuild test \
  -project "$project" \
  -scheme IdleScreenAppCompileGate \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$artifact_root/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  2>&1 | /usr/bin/tee "$log_path"
build_status=${PIPESTATUS[0]}
set -e

if ((build_status != 0)); then
  echo "FAIL: companion compile gate did not build and test successfully." >&2
  echo "Evidence: $log_path" >&2
  exit "$build_status"
fi

if /usr/bin/grep -Eq 'RegisterWithLaunchServices|(^|[^[:alnum:]_])lsregister([^[:alnum:]_]|$)' "$log_path"; then
  echo "FAIL: companion compile gate invoked Launch Services registration." >&2
  echo "Evidence: $log_path" >&2
  exit 1
fi

if /usr/bin/grep -Eq 'IdleScreen\.app|IdleScreenScreenSaver\.appex|IdleScreenCameraAgent\.app' "$log_path"; then
  echo "FAIL: companion compile gate produced an application or extension bundle." >&2
  echo "Evidence: $log_path" >&2
  exit 1
fi

if /usr/bin/grep -Fq "$project_root/Products/IdleScreenApp/Info.plist" "$log_path"; then
  echo "FAIL: companion compile gate reused application bundle metadata." >&2
  echo "Evidence: $log_path" >&2
  exit 1
fi

if ! /usr/bin/grep -Eq 'Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed' "$log_path"; then
  echo "FAIL: companion compile gate did not execute its smoke tests." >&2
  echo "Evidence: $log_path" >&2
  exit 1
fi

echo "PASS: companion sources compiled and smoke-tested without an application product."
echo "PASS: build log contains no RegisterWithLaunchServices or lsregister command."
echo "Evidence: $log_path"
