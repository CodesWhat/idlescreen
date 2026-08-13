#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
probe_source="$project_root/scripts/ScreenSaverSelectionProbe.swift"
fixture_root="$(mktemp -d /tmp/idlescreen-selection-probe-tests.XXXXXX)"
trap 'rm -rf "$fixture_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$probe_source" ]] || fail "missing screen saver selection probe source"

probe_binary="$fixture_root/selection-probe"
xcrun swiftc \
  "$project_root/Sources/IdleScreenSystem/ScreenSaverSelection.swift" \
  "$probe_source" \
  -o "$probe_binary"

extension_path="$fixture_root/idlescreen.appex"
mkdir -p "$extension_path/Contents"
expected_id="com.idlescreen.app.dev.screensaver"
index_path="$fixture_root/Index.plist"

EXPECTED_ID="$expected_id" EXTENSION_PATH="$extension_path" INDEX_PATH="$index_path" \
  /usr/bin/python3 - <<'PY'
import os
import plistlib
from pathlib import Path

extension_path = Path(os.environ["EXTENSION_PATH"])
with (extension_path / "Contents" / "Info.plist").open("wb") as stream:
    plistlib.dump(
        {
            "CFBundleIdentifier": os.environ["EXPECTED_ID"],
            "CFBundlePackageType": "XPC!",
        },
        stream,
        fmt=plistlib.FMT_BINARY,
    )

configuration = plistlib.dumps(
    {"module": {"relative": extension_path.as_uri()}},
    fmt=plistlib.FMT_BINARY,
)
index = {
    "AllSpacesAndDisplays": {
        "Idle": {
            "Content": {
                "Choices": [
                    {
                        "Provider": "com.apple.wallpaper.choice.screen-saver",
                        "Configuration": configuration,
                    }
                ]
            }
        }
    }
}
with Path(os.environ["INDEX_PATH"]).open("wb") as stream:
    plistlib.dump(index, stream, fmt=plistlib.FMT_BINARY)
PY

output="$($probe_binary "$expected_id" "$index_path")" ||
  fail "probe rejected the selected modern extension"
grep -Fq "providers=$expected_id" <<<"$output" ||
  fail "probe did not resolve the generic provider to the extension bundle ID"
grep -Fq 'selectedEverywhere=true' <<<"$output" ||
  fail "probe did not report selected-everywhere state"

set +e
wrong_output="$($probe_binary com.example.other "$index_path" 2>&1)"
wrong_status=$?
set -e
[[ "$wrong_status" -eq 1 ]] || fail "probe must reject a different expected extension"
grep -Fq 'selectedEverywhere=false' <<<"$wrong_output" ||
  fail "probe did not explain its rejected selection"

echo "PASS: the diagnostic probe executes the production selection parser."
