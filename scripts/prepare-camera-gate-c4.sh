#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/C3.xcarchive /absolute/C3-provenance.txt /absolute/new-C4-gate-directory" >&2
  exit 64
}

[[ $# -eq 3 ]] || usage
archive_path="$1"
c3_manifest="$2"
output_root="$3"
[[ "$archive_path" = /* && "$c3_manifest" = /* && "$output_root" = /* ]] || usage
[[ "$archive_path" == *.xcarchive && -d "$archive_path" && ! -L "$archive_path" ]] || usage
[[ -f "$c3_manifest" && ! -L "$c3_manifest" ]] || usage
output_parent="$(/usr/bin/dirname "$output_root")"
[[ -d "$output_parent" && ! -L "$output_parent" ]] || usage
output_parent="$(/bin/realpath "$output_parent")"
output_root="$output_parent/$(/usr/bin/basename "$output_root")"
[[ ! -e "$output_root" && ! -L "$output_root" ]] || {
  echo "FAIL: refusing to replace existing C4 gate evidence: $output_root" >&2
  exit 73
}

if [[ -n "${IDLESCREEN_PROVENANCE_FIXTURE_MODE+x}" ||
      -n "${IDLESCREEN_PROVENANCE_CODESIGN+x}" ||
      -n "${IDLESCREEN_PROVENANCE_SECURITY+x}" ]]; then
  echo "FAIL: C4 gate preparation refuses provenance fixture mode and command overrides." >&2
  exit 64
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
verifier="$project_root/scripts/verify-release-archive-provenance.sh"
gate_verifier="$project_root/scripts/test-synthetic-gate-product.sh"
manifest_tool="$project_root/scripts/create-synthetic-gate-manifest.sh"
project="$project_root/IdleScreen.xcodeproj"
production_app="$archive_path/Products/Applications/IdleScreen.app"
production_helper="$production_app/Contents/Helpers/IdleScreenCameraAgent.app"
production_extension="$production_app/Contents/PlugIns/IdleScreenScreenSaver.appex"
production_helper_profile="$production_helper/Contents/embedded.provisionprofile"
production_extension_profile="$production_extension/Contents/embedded.provisionprofile"
helper_archive="$output_root/IdleScreenSyntheticHelper.xcarchive"
extension_archive="$output_root/IdleScreenSyntheticHostedExtension.xcarchive"
synthetic_helper="$helper_archive/Products/Applications/IdleScreenCameraAgent.app"
synthetic_extension="$extension_archive/Products/Applications/IdleScreenScreenSaver.appex"
gate_app="$output_root/IdleScreenC4Gate.app"
gate_manifest="$output_root/IdleScreenC4GateManifestV1.txt"
binding_manifest="$output_root/IdleScreenC4GateBindingV1.txt"
scratch_root="$(mktemp -d /tmp/idlescreen-c4-gate-preparation.XXXXXX)"
trap '/bin/rm -rf "$scratch_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  echo "Evidence: $output_root" >&2
  exit 1
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print tolower($1) }'
}

write_tree_inventory() {
  local root="$1" output="$2" listing="$scratch_root/tree-list-$$"
  local entry relative mode size digest target attributes attribute value
  /usr/bin/find -s "$root" -print0 >"$listing" || return 1
  : >"$output"
  while IFS= read -r -d '' entry; do
    relative="${entry#"$root"}"; relative="${relative#/}"; [[ -n "$relative" ]] || relative=.
    [[ "$relative" != *$'\n'* && "$relative" != *$'\t'* ]] || return 1
    mode="$(/usr/bin/stat -f '%Lp' "$entry")" || return 1
    if [[ -L "$entry" ]]; then
      target="$(/usr/bin/readlink "$entry")" || return 1
      printf 'link\t%s\t%s\t%s\n' "$mode" "$relative" "$target" >>"$output"
    elif [[ -f "$entry" ]]; then
      size="$(/usr/bin/stat -f '%z' "$entry")" || return 1
      digest="$(sha256_file "$entry")" || return 1
      printf 'file\t%s\t%s\t%s\t%s\n' "$mode" "$size" "$digest" "$relative" >>"$output"
    elif [[ -d "$entry" ]]; then
      printf 'directory\t%s\t%s\n' "$mode" "$relative" >>"$output"
    else
      return 1
    fi
    attributes="$scratch_root/tree-xattrs-$$"
    /usr/bin/xattr "$entry" >"$attributes" 2>/dev/null || return 1
    LC_ALL=C /usr/bin/sort -o "$attributes" "$attributes" || return 1
    while IFS= read -r attribute; do
      [[ -n "$attribute" ]] || continue
      [[ "$attribute" != *$'\n'* && "$attribute" != *$'\t'* ]] || return 1
      value="$(/usr/bin/xattr -px "$attribute" "$entry" 2>/dev/null)" || return 1
      value="${value//[[:space:]]/}"
      printf 'xattr\t%s\t%s\t%s\n' "$relative" "$attribute" "$value" >>"$output"
    done <"$attributes"
    /bin/rm "$attributes" || return 1
  done <"$listing"
  /bin/rm "$listing" || return 1
}

manifest_value() {
  local manifest="$1"
  local key="$2"
  local value
  value="$(/usr/bin/awk -F= -v key="$key" '$1 == key { print substr($0, length($1) + 2); count++ } END { exit(count == 1 ? 0 : 1) }' "$manifest")" ||
    fail "manifest does not contain exactly one $key"
  [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\t'* ]] ||
    fail "manifest contains malformed $key"
  printf '%s\n' "$value"
}

signed_value() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 |
    /usr/bin/awk -F= -v key="$2" '$1 == key { print $2; exit }'
}

code_directory_flags() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 |
    /usr/bin/sed -nE 's/^CodeDirectory .* flags=([^ ]+).*/\1/p' |
    /usr/bin/head -1
}

for required in "$verifier" "$gate_verifier" "$manifest_tool"; do
  [[ -x "$required" ]] || {
    echo "FAIL: missing C4 prerequisite: $required" >&2
    exit 66
  }
done

umask 077
/bin/mkdir "$output_root"

replayed_manifest="$scratch_root/c3-replayed.txt"
"$verifier" "$archive_path" "$replayed_manifest" >"$output_root/c3-replay.log"
[[ "$(/usr/bin/grep -Fxc 'verification_mode=release' "$c3_manifest" || true)" == 1 &&
   "$(/usr/bin/grep -Ec '^verification_mode=' "$c3_manifest" || true)" == 1 ]] ||
  fail "C3 manifest is not trusted release-mode evidence"
[[ "$(/usr/bin/grep -Fxc 'verification_mode=release' "$replayed_manifest" || true)" == 1 &&
   "$(/usr/bin/grep -Ec '^verification_mode=' "$replayed_manifest" || true)" == 1 ]] ||
  fail "C3 replay did not produce trusted release-mode evidence"
/usr/bin/cmp -s "$c3_manifest" "$replayed_manifest" ||
  fail "C3 archive does not reproduce its recorded provenance manifest"

c3_archive_tree_sha256="$(manifest_value "$c3_manifest" archive_tree_sha256)"
c3_app_cdhash="$(manifest_value "$c3_manifest" app_cdhash)"
c3_helper_cdhash="$(manifest_value "$c3_manifest" helper_cdhash)"
c3_extension_cdhash="$(manifest_value "$c3_manifest" extension_cdhash)"
[[ "$c3_archive_tree_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "malformed C3 archive hash"
for cdhash in "$c3_app_cdhash" "$c3_helper_cdhash" "$c3_extension_cdhash"; do
  [[ "$cdhash" =~ ^[0-9a-f]{40}$ ]] || fail "malformed C3 CDHash"
done
[[ "$(signed_value "$production_app" CDHash | /usr/bin/tr '[:upper:]' '[:lower:]')" == "$c3_app_cdhash" ]] ||
  fail "C3 archive app CDHash drifted before gate preparation"
[[ -f "$production_helper_profile" && ! -L "$production_helper_profile" ]] ||
  fail "exact C3 helper is missing its embedded provisioning profile"
[[ -f "$production_extension_profile" && ! -L "$production_extension_profile" ]] ||
  fail "exact C3 extension is missing its embedded provisioning profile"
c3_product_tree="$output_root/c3-product-tree.tsv"
write_tree_inventory "$production_app" "$c3_product_tree" ||
  fail "could not inventory the exact C3 archive product"
c3_product_tree_sha256="$(sha256_file "$c3_product_tree")"

credential_updates="${IDLESCREEN_ALLOW_SIGNING_CREDENTIAL_UPDATES:-NO}"
[[ "$credential_updates" == YES || "$credential_updates" == NO ]] || usage
provisioning_update_argument=""
[[ "$credential_updates" != YES ]] || provisioning_update_argument=-allowProvisioningUpdates

xcodegen generate --spec "$project_root/project.yml" >"$output_root/xcodegen.log" 2>&1 ||
  fail "project generation failed"
for archive_record in \
  "IdleScreenC4SyntheticHelperArchive|$helper_archive|synthetic-helper" \
  "IdleScreenC4SyntheticHostedExtensionArchive|$extension_archive|synthetic-extension"; do
  scheme="${archive_record%%|*}"
  remainder="${archive_record#*|}"
  product_archive="${remainder%%|*}"
  log_name="${remainder##*|}"
  set +e
  IDLESCREEN_C4_HELPER_PROVISIONING_PROFILE_PATH="$production_helper_profile" \
  IDLESCREEN_C4_EXTENSION_PROVISIONING_PROFILE_PATH="$production_extension_profile" \
  /usr/bin/xcodebuild archive \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$product_archive" \
    ${provisioning_update_argument:+"$provisioning_update_argument"} \
    >"$output_root/$log_name-archive.log" 2>&1
  archive_status=$?
  set -e
  if /usr/bin/grep -Eq 'RegisterWithLaunchServices|(^|[ /])lsregister([ /]|$)' \
    "$output_root/$log_name-archive.log"; then
    fail "$log_name archive attempted LaunchServices registration"
  fi
  if ((archive_status != 0)); then
    /usr/bin/tail -100 "$output_root/$log_name-archive.log" >&2
    fail "$log_name archive failed"
  fi
done

[[ -d "$synthetic_helper" && -d "$synthetic_extension" ]] ||
  fail "synthetic archives are missing the helper or hosted extension"
/usr/bin/cmp -s "$production_helper_profile" \
  "$synthetic_helper/Contents/embedded.provisionprofile" ||
  fail "synthetic helper did not replay the exact C3 embedded profile"
/usr/bin/cmp -s "$production_extension_profile" \
  "$synthetic_extension/Contents/embedded.provisionprofile" ||
  fail "hosted extension did not replay the exact C3 embedded profile"
/usr/bin/ditto "$production_app" "$gate_app"
/bin/rm -rf "$gate_app/Contents/Helpers/IdleScreenCameraAgent.app"
/usr/bin/ditto "$synthetic_helper" "$gate_app/Contents/Helpers/IdleScreenCameraAgent.app"
/bin/rm -rf "$gate_app/Contents/PlugIns/IdleScreenScreenSaver.appex"
/usr/bin/ditto "$synthetic_extension" "$gate_app/Contents/PlugIns/IdleScreenScreenSaver.appex"

outer_entitlements="$scratch_root/outer-entitlements.plist"
/usr/bin/codesign -d --entitlements :- "$production_app" >"$outer_entitlements" 2>/dev/null ||
  fail "could not preserve C3 outer entitlements"
signing_identity="$(/usr/bin/codesign -dv --verbose=4 "$production_app" 2>&1 |
  /usr/bin/awk -F= '$1 == "Authority" { print $2; exit }')"
[[ -n "$signing_identity" ]] || fail "could not resolve C3 outer signing identity"
production_flags="$(code_directory_flags "$production_app")"
/usr/bin/codesign --force --sign "$signing_identity" \
  --entitlements "$outer_entitlements" \
  --preserve-metadata=identifier,requirements,flags \
  "$gate_app" >"$output_root/outer-reseal.log" 2>&1 ||
  fail "could not reseal the C3-derived gate outer app"
[[ "$(code_directory_flags "$gate_app")" == "$production_flags" ]] ||
  fail "gate reseal changed C3 outer CodeDirectory flags"

"$manifest_tool" "$production_app" "$gate_app" "$gate_manifest" \
  >"$output_root/gate-manifest.log"
"$gate_verifier" "$production_app" "$gate_app" Release "$gate_manifest" \
  >"$output_root/gate-verification.log"

gate_app_cdhash="$(signed_value "$gate_app" CDHash)"
gate_helper_cdhash="$(manifest_value "$gate_manifest" syntheticHelperCDHash)"
gate_extension_cdhash="$(manifest_value "$gate_manifest" syntheticExtensionCDHash)"
{
  printf 'schema=IdleScreenC4GateBinding/v1\n'
  printf 'verification_mode=release\n'
  printf 'c3_archive_tree_sha256=%s\n' "$c3_archive_tree_sha256"
  printf 'c3_provenance_manifest_sha256=%s\n' "$(sha256_file "$c3_manifest")"
  printf 'c3_product_tree_sha256=%s\n' "$c3_product_tree_sha256"
  printf 'c3_app_cdhash=%s\n' "$c3_app_cdhash"
  printf 'c3_helper_cdhash=%s\n' "$c3_helper_cdhash"
  printf 'c3_extension_cdhash=%s\n' "$c3_extension_cdhash"
  printf 'gate_manifest_sha256=%s\n' "$(sha256_file "$gate_manifest")"
  printf 'gate_app_cdhash=%s\n' "$gate_app_cdhash"
  printf 'gate_helper_cdhash=%s\n' "$gate_helper_cdhash"
  printf 'gate_extension_cdhash=%s\n' "$gate_extension_cdhash"
} >"$binding_manifest"
/bin/chmod a-w "$gate_manifest" "$binding_manifest"

echo "PASS: C4 gate was derived from and hash-bound to exact C3 archive $c3_archive_tree_sha256."
echo "PASS: only synthetic helper/hosted-extension archives were built; no product was installed, registered, or launched."
echo "Gate: $gate_app"
echo "Gate manifest: $gate_manifest"
echo "Binding manifest: $binding_manifest"
echo "Evidence: $output_root"
