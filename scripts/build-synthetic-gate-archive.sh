#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
project="$project_root/IdleScreen.xcodeproj"
production_verifier="$project_root/scripts/test-camera-agent-product.sh"
gate_verifier="$project_root/scripts/test-synthetic-gate-product.sh"
manifest_tool="$project_root/scripts/create-synthetic-gate-manifest.sh"
artifact_root="$(mktemp -d /tmp/idlescreen-synthetic-gate-archive.XXXXXX)"
production_archive="$artifact_root/IdleScreenProduction.xcarchive"
helper_archive="$artifact_root/IdleScreenSyntheticHelper.xcarchive"
extension_archive="$artifact_root/IdleScreenSyntheticHostedExtension.xcarchive"
production_app="$production_archive/Products/Applications/IdleScreen.app"
synthetic_helper="$helper_archive/Products/Applications/IdleScreenCameraAgent.app"
synthetic_extension="$extension_archive/Products/Applications/IdleScreenScreenSaver.appex"
gate_app="$artifact_root/IdleScreenSyntheticGate.app"
manifest="$artifact_root/IdleScreenSyntheticGateManifestV1.txt"

fail() {
  echo "FAIL: $*" >&2
  echo "Evidence: $artifact_root" >&2
  exit 1
}

code_directory_flags() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 |
    /usr/bin/sed -nE 's/^CodeDirectory .* flags=([^ ]+).*/\1/p' |
    /usr/bin/head -1
}

for executable in "$production_verifier" "$gate_verifier" "$manifest_tool"; do
  [[ -x "$executable" ]] || fail "missing required verifier: $executable"
done
[[ -d "$project" ]] || fail "missing generated Xcode project"

# Archive is deliberate. `xcodebuild build` registers app products with Launch
# Services on this Mac and is prohibited for the synthetic gate workflow.
xcodebuild archive \
  -project "$project" \
  -scheme IdleScreenSyntheticHostedGateExtensionArchive \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$extension_archive" \
  -allowProvisioningUpdates \
  SKIP_INSTALL=NO \
  >"$artifact_root/synthetic-extension-archive.log" 2>&1 || {
    /usr/bin/tail -100 "$artifact_root/synthetic-extension-archive.log" >&2
    fail "synthetic hosted-gate extension archive failed"
  }

xcodebuild archive \
  -project "$project" \
  -scheme IdleScreenApp \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$production_archive" \
  -allowProvisioningUpdates \
  >"$artifact_root/production-archive.log" 2>&1 || {
    /usr/bin/tail -100 "$artifact_root/production-archive.log" >&2
    fail "production archive failed"
  }

xcodebuild archive \
  -project "$project" \
  -scheme IdleScreenCameraSyntheticAgentArchive \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$helper_archive" \
  -allowProvisioningUpdates \
  SKIP_INSTALL=NO \
  >"$artifact_root/synthetic-helper-archive.log" 2>&1 || {
    /usr/bin/tail -100 "$artifact_root/synthetic-helper-archive.log" >&2
    fail "synthetic helper archive failed"
  }

[[ -d "$production_app" ]] || fail "production archive contains no IdleScreen.app"
[[ -d "$synthetic_helper" ]] ||
  fail "synthetic helper archive contains no IdleScreenCameraAgent.app"
[[ -d "$synthetic_extension" ]] ||
  fail "synthetic hosted-gate extension archive contains no IdleScreenScreenSaver.appex"
"$production_verifier" "$production_app" Release \
  >"$artifact_root/production-verification.txt" || fail "production archive failed verification"
production_code_directory_flags="$(code_directory_flags "$production_app")"
[[ "$production_code_directory_flags" == *runtime* ]] ||
  fail "production outer app does not carry hardened-runtime CodeDirectory flags"

/usr/bin/ditto "$production_app" "$gate_app"
gate_helper="$gate_app/Contents/Helpers/IdleScreenCameraAgent.app"
[[ -d "$gate_helper" ]] || fail "copied production app has no nested helper"
/bin/rm -rf "$gate_helper"
/usr/bin/ditto "$synthetic_helper" "$gate_helper"
gate_extension="$gate_app/Contents/PlugIns/IdleScreenScreenSaver.appex"
[[ -d "$gate_extension" ]] || fail "copied production app has no nested extension"
/bin/rm -rf "$gate_extension"
/usr/bin/ditto "$synthetic_extension" "$gate_extension"

outer_entitlements="$artifact_root/outer-entitlements.plist"
/usr/bin/codesign -d --entitlements :- "$production_app" >"$outer_entitlements" 2>/dev/null ||
  fail "could not preserve production outer entitlements"
signing_identity="$(/usr/bin/codesign -dv --verbose=4 "$production_app" 2>&1 |
  /usr/bin/awk -F= '$1 == "Authority" { print $2; exit }')"
[[ -n "$signing_identity" ]] || fail "could not resolve production signing identity"

# Reseal only the outer bundle after explicit helper and hosted-extension
# substitution. The manifest separately compares signature-stripped outer code.
/usr/bin/codesign --force \
  --sign "$signing_identity" \
  --entitlements "$outer_entitlements" \
  --preserve-metadata=identifier,requirements,flags \
  "$gate_app" >"$artifact_root/outer-reseal.txt" 2>&1 ||
  fail "could not reseal the synthetic gate outer app"
gate_code_directory_flags="$(code_directory_flags "$gate_app")"
[[ "$gate_code_directory_flags" == "$production_code_directory_flags" ]] ||
  fail "resealed gate did not preserve production CodeDirectory flags"

"$manifest_tool" "$production_app" "$gate_app" "$manifest" |
  tee "$artifact_root/manifest-verification.txt"
"$gate_verifier" "$production_app" "$gate_app" Release "$manifest" |
  tee "$artifact_root/gate-product-verification.txt"

echo "PASS: archived production app, synthetic helper, and hosted extension without launching any product."
echo "PASS: the topology-equivalent gate was composed by explicit helper/hosted-extension substitution and outer-only resealing."
echo "Production archive: $production_archive"
echo "Synthetic helper archive: $helper_archive"
echo "Synthetic hosted extension archive: $extension_archive"
echo "Gate candidate: $gate_app"
echo "Manifest: $manifest"
echo "Evidence: $artifact_root"
