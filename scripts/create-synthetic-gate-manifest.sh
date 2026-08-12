#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/production/IdleScreen.app /absolute/path/to/gate/IdleScreen.app /absolute/path/to/manifest.txt" >&2
  exit 64
}

[[ $# -eq 3 ]] || usage
production_app="$1"
gate_app="$2"
manifest_path="$3"
[[ "$production_app" = /* && "$gate_app" = /* && "$manifest_path" = /* ]] || usage

production_app="$(/bin/realpath "$production_app")"
gate_app="$(/bin/realpath "$gate_app")"
manifest_parent="$(/bin/realpath "$(/usr/bin/dirname "$manifest_path")")"
manifest_leaf="$(/usr/bin/basename "$manifest_path")"
[[ -n "$manifest_leaf" && "$manifest_leaf" != . && "$manifest_leaf" != .. ]] || usage
manifest_path="$manifest_parent/$manifest_leaf"

production_helper_relative="Contents/Helpers/IdleScreenCameraAgent.app"
production_extension_relative="Contents/PlugIns/IdleScreenScreenSaver.appex"
launch_agents_relative="Contents/Library/LaunchAgents"
outer_code_resources_relative="Contents/_CodeSignature/CodeResources"
outer_executable_relative="Contents/MacOS/IdleScreen"
scratch_root="$(mktemp -d /tmp/idlescreen-synthetic-manifest.XXXXXX)"
trap '/bin/rm -rf "$scratch_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -d "$production_app" ]] || fail "missing production app: $production_app"
[[ -d "$gate_app" ]] || fail "missing gate app: $gate_app"
[[ "$production_app" != "$gate_app" ]] || fail "production and gate app paths must differ"
[[ ! "$manifest_path" == "$production_app"/* && ! "$manifest_path" == "$gate_app"/* ]] ||
  fail "manifest output must be outside both app bundles"

production_helper="$production_app/$production_helper_relative"
gate_helper="$gate_app/$production_helper_relative"
production_helper_info="$production_helper/Contents/Info.plist"
gate_helper_info="$gate_helper/Contents/Info.plist"
[[ -f "$production_helper_info" && -f "$gate_helper_info" ]] ||
  fail "both products must contain the nested camera helper"
if /usr/libexec/PlistBuddy \
  -c 'Print :IdleScreenSyntheticGateVersion' "$production_helper_info" >/dev/null 2>&1; then
  fail "production helper unexpectedly carries IdleScreenSyntheticGateVersion"
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :IdleScreenSyntheticGateVersion' "$gate_helper_info" 2>/dev/null || true)" == 1 ]] ||
  fail "gate helper must carry IdleScreenSyntheticGateVersion=1"

production_extension="$production_app/$production_extension_relative"
gate_extension="$gate_app/$production_extension_relative"
production_extension_info="$production_extension/Contents/Info.plist"
gate_extension_info="$gate_extension/Contents/Info.plist"
[[ -f "$production_extension_info" && -f "$gate_extension_info" ]] ||
  fail "both products must contain the nested screen-saver extension"
if /usr/libexec/PlistBuddy \
  -c 'Print :IdleScreenSyntheticHostedGateVersion' "$production_extension_info" >/dev/null 2>&1; then
  fail "production extension unexpectedly carries IdleScreenSyntheticHostedGateVersion"
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :IdleScreenSyntheticHostedGateVersion' "$gate_extension_info" 2>/dev/null || true)" == 1 ]] ||
  fail "gate extension must carry IdleScreenSyntheticHostedGateVersion=1"

is_allowed_substitution() {
  case "$1" in
    "$production_helper_relative"|"$production_helper_relative"/*|"$production_extension_relative"|"$production_extension_relative"/*|"$outer_code_resources_relative"|"$outer_executable_relative")
      return 0
      ;;
    *) return 1 ;;
  esac
}

write_xattr_inventory() {
  local entry="$1"
  local relative="$2"
  local attribute_name
  local attribute_value

  /usr/bin/xattr "$entry" 2>/dev/null | LC_ALL=C /usr/bin/sort |
    while IFS= read -r attribute_name; do
      [[ -n "$attribute_name" ]] || continue
      [[ "$attribute_name" != *$'\t'* && "$attribute_name" != *$'\n'* ]] ||
        fail "unsupported extended-attribute name on $relative"
      attribute_value="$(/usr/bin/xattr -px "$attribute_name" "$entry" 2>/dev/null |
        /usr/bin/tr -d '[:space:]')" ||
        fail "could not read extended attribute $attribute_name on $relative"
      printf 'xattr\t%s\t%s\t%s\n' \
        "$relative" "$attribute_name" "$attribute_value"
    done
}

write_inventory() {
  local app="$1"
  local output="$2"
  local relative
  local digest
  local target
  local mode

  (
    cd "$app"
    /usr/bin/find . -mindepth 1 -print | LC_ALL=C /usr/bin/sort |
      while IFS= read -r entry; do
        relative="${entry#./}"
        if is_allowed_substitution "$relative"; then
          continue
        fi
        mode="$(/usr/bin/stat -f '%Lp' "$entry")"
        if [[ -L "$entry" ]]; then
          target="$(/usr/bin/readlink "$entry")"
          printf 'link\t%s\t%s\t%s\n' "$mode" "$relative" "$target"
        elif [[ -f "$entry" ]]; then
          digest="$(/usr/bin/shasum -a 256 "$entry" | /usr/bin/awk '{ print $1 }')"
          printf 'file\t%s\t%s\t%s\n' "$mode" "$relative" "$digest"
        elif [[ -d "$entry" ]]; then
          printf 'directory\t%s\t%s\n' "$mode" "$relative"
        else
          fail "unsupported product path type: $app/$relative"
        fi
        write_xattr_inventory "$entry" "$relative"
      done
  ) >"$output"
}

# The portable manifest records type, canonical relative path, POSIX mode,
# symlink target, and file digest. ACLs and extended attributes are not portable
# archive identity here; strict nested/outer codesign verification remains the
# authority for signed resource envelopes before installation.

write_tree_inventory() {
  local root="$1"
  local output="$2"
  local mode
  (
    cd "$root"
    /usr/bin/find . -mindepth 1 -print | LC_ALL=C /usr/bin/sort |
      while IFS= read -r entry; do
        mode="$(/usr/bin/stat -f '%Lp' "$entry")"
        if [[ -L "$entry" ]]; then
          printf 'link\t%s\t%s\t%s\n' "$mode" "${entry#./}" "$(/usr/bin/readlink "$entry")"
        elif [[ -f "$entry" ]]; then
          printf 'file\t%s\t%s\t%s\n' "$mode" "${entry#./}" \
            "$(/usr/bin/shasum -a 256 "$entry" | /usr/bin/awk '{ print $1 }')"
        elif [[ -d "$entry" ]]; then
          printf 'directory\t%s\t%s\n' "$mode" "${entry#./}"
        fi
      done
  ) >"$output"
}

production_inventory="$scratch_root/production.inventory"
gate_inventory="$scratch_root/gate.inventory"
write_inventory "$production_app" "$production_inventory"
write_inventory "$gate_app" "$gate_inventory"
if ! /usr/bin/cmp -s "$production_inventory" "$gate_inventory"; then
  /usr/bin/diff -u "$production_inventory" "$gate_inventory" >&2 || true
  fail "gate changes a path outside the helper-substitution whitelist"
fi

production_outer_executable="$production_app/$outer_executable_relative"
gate_outer_executable="$gate_app/$outer_executable_relative"
[[ -x "$production_outer_executable" && -x "$gate_outer_executable" ]] ||
  fail "both products must contain $outer_executable_relative"
/bin/cp "$production_outer_executable" "$scratch_root/production-outer-unsigned"
/bin/cp "$gate_outer_executable" "$scratch_root/gate-outer-unsigned"
/usr/bin/codesign --remove-signature "$scratch_root/production-outer-unsigned" >/dev/null 2>&1 ||
  fail "could not strip the production outer signature for code comparison"
/usr/bin/codesign --remove-signature "$scratch_root/gate-outer-unsigned" >/dev/null 2>&1 ||
  fail "could not strip the gate outer signature for code comparison"
/usr/bin/cmp -s \
  "$scratch_root/production-outer-unsigned" \
  "$scratch_root/gate-outer-unsigned" ||
  fail "gate outer executable code differs after removing its signature envelope"
outer_unsigned_sha256="$(/usr/bin/shasum -a 256 "$scratch_root/production-outer-unsigned" | /usr/bin/awk '{ print $1 }')"

signed_value() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 |
    /usr/bin/awk -F= -v key="$2" '$1 == key { print $2; exit }'
}

code_directory_flags() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 |
    /usr/bin/sed -nE 's/^CodeDirectory .* flags=([^ ]+).*/\1/p' |
    /usr/bin/head -1
}

production_outer_identifier="$(signed_value "$production_app" Identifier)"
gate_outer_identifier="$(signed_value "$gate_app" Identifier)"
production_outer_team="$(signed_value "$production_app" TeamIdentifier)"
gate_outer_team="$(signed_value "$gate_app" TeamIdentifier)"
production_outer_signature="$(signed_value "$production_app" Signature)"
gate_outer_signature="$(signed_value "$gate_app" Signature)"
production_outer_flags="$(code_directory_flags "$production_app")"
gate_outer_flags="$(code_directory_flags "$gate_app")"
[[ -n "$production_outer_identifier" && "$production_outer_identifier" == "$gate_outer_identifier" ]] ||
  fail "gate outer signature identifier differs from production"
[[ -n "$production_outer_team" && "$production_outer_team" == "$gate_outer_team" ]] ||
  fail "gate outer TeamIdentifier differs from production"
[[ -n "$production_outer_flags" && "$production_outer_flags" == "$gate_outer_flags" ]] ||
  fail "gate outer CodeDirectory flags differ from production"
/usr/bin/codesign -d -r- "$production_app" >"$scratch_root/production-requirement.txt" 2>&1 ||
  fail "could not read the production designated requirement"
/usr/bin/codesign -d -r- "$gate_app" >"$scratch_root/gate-requirement.txt" 2>&1 ||
  fail "could not read the gate designated requirement"
/usr/bin/sed -E 's#^Executable=.*$#Executable=<product>#' \
  "$scratch_root/production-requirement.txt" >"$scratch_root/production-requirement.normalized"
/usr/bin/sed -E 's#^Executable=.*$#Executable=<product>#' \
  "$scratch_root/gate-requirement.txt" >"$scratch_root/gate-requirement.normalized"
if [[ "$production_outer_signature" != adhoc || "$gate_outer_signature" != adhoc ]] &&
   ! /usr/bin/cmp -s \
     "$scratch_root/production-requirement.normalized" \
     "$scratch_root/gate-requirement.normalized"; then
  /usr/bin/diff -u \
    "$scratch_root/production-requirement.normalized" \
    "$scratch_root/gate-requirement.normalized" >&2 || true
  fail "gate outer designated requirement differs from production"
fi
/usr/bin/codesign -d --entitlements :- "$production_app" \
  >"$scratch_root/production-outer-entitlements.plist" 2>/dev/null ||
  fail "could not read production outer entitlements"
/usr/bin/codesign -d --entitlements :- "$gate_app" \
  >"$scratch_root/gate-outer-entitlements.plist" 2>/dev/null ||
  fail "could not read gate outer entitlements"
/usr/bin/plutil -convert xml1 -o "$scratch_root/production-outer-entitlements.xml" \
  "$scratch_root/production-outer-entitlements.plist"
/usr/bin/plutil -convert xml1 -o "$scratch_root/gate-outer-entitlements.xml" \
  "$scratch_root/gate-outer-entitlements.plist"
/usr/bin/cmp -s \
  "$scratch_root/production-outer-entitlements.xml" \
  "$scratch_root/gate-outer-entitlements.xml" ||
  fail "gate outer entitlements differ from production"

[[ -d "$production_extension" && -d "$gate_extension" ]] ||
  fail "both products must contain $production_extension_relative"
write_tree_inventory "$production_extension" "$scratch_root/production-extension.inventory"
write_tree_inventory "$gate_extension" "$scratch_root/gate-extension.inventory"

production_launch_agents="$production_app/$launch_agents_relative"
gate_launch_agents="$gate_app/$launch_agents_relative"
[[ -d "$production_launch_agents" && -d "$gate_launch_agents" ]] ||
  fail "both products must contain $launch_agents_relative"
write_tree_inventory "$production_launch_agents" "$scratch_root/production-launch-agents.inventory"
write_tree_inventory "$gate_launch_agents" "$scratch_root/gate-launch-agents.inventory"
/usr/bin/cmp -s \
  "$scratch_root/production-launch-agents.inventory" \
  "$scratch_root/gate-launch-agents.inventory" ||
  fail "$launch_agents_relative is not byte-identical to production"

inventory_sha256="$(/usr/bin/shasum -a 256 "$production_inventory" | /usr/bin/awk '{ print $1 }')"
extension_sha256="$(/usr/bin/shasum -a 256 "$scratch_root/production-extension.inventory" | /usr/bin/awk '{ print $1 }')"
synthetic_extension_sha256="$(/usr/bin/shasum -a 256 "$scratch_root/gate-extension.inventory" | /usr/bin/awk '{ print $1 }')"
launch_agents_sha256="$(/usr/bin/shasum -a 256 "$scratch_root/production-launch-agents.inventory" | /usr/bin/awk '{ print $1 }')"
production_helper_cdhash="$(/usr/bin/codesign -dv --verbose=4 "$production_helper" 2>&1 | /usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }')"
gate_helper_cdhash="$(/usr/bin/codesign -dv --verbose=4 "$gate_helper" 2>&1 | /usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }')"
production_extension_cdhash="$(/usr/bin/codesign -dv --verbose=4 "$production_extension" 2>&1 | /usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }')"
gate_extension_cdhash="$(/usr/bin/codesign -dv --verbose=4 "$gate_extension" 2>&1 | /usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }')"
[[ -n "$production_helper_cdhash" && -n "$gate_helper_cdhash" ]] ||
  fail "both nested helpers must have a readable CDHash"
[[ -n "$production_extension_cdhash" && -n "$gate_extension_cdhash" ]] ||
  fail "both nested extensions must have a readable CDHash"
[[ "$production_helper_cdhash" != "$gate_helper_cdhash" ]] ||
  fail "synthetic helper must have a distinct CDHash from the production helper"
[[ "$production_extension_cdhash" != "$gate_extension_cdhash" ]] ||
  fail "hosted-gate extension must have a distinct CDHash from the production extension"

manifest_temp="$scratch_root/manifest.txt"
{
  printf 'format=IdleScreenSyntheticGateManifestV1\n'
  printf 'unchangedInventorySHA256=%s\n' "$inventory_sha256"
  printf 'outerExecutableUnsignedSHA256=%s\n' "$outer_unsigned_sha256"
  printf 'outerIdentifier=%s\n' "$production_outer_identifier"
  printf 'outerTeamIdentifier=%s\n' "$production_outer_team"
  printf 'outerCodeDirectoryFlags=%s\n' "$production_outer_flags"
  printf 'productionExtensionPath=%s\n' "$production_extension_relative"
  printf 'productionExtensionTreeSHA256=%s\n' "$extension_sha256"
  printf 'syntheticExtensionTreeSHA256=%s\n' "$synthetic_extension_sha256"
  printf 'productionLaunchAgentsPath=%s\n' "$launch_agents_relative"
  printf 'productionLaunchAgentsTreeSHA256=%s\n' "$launch_agents_sha256"
  printf 'productionHelperCDHash=%s\n' "$production_helper_cdhash"
  printf 'syntheticHelperCDHash=%s\n' "$gate_helper_cdhash"
  printf 'productionExtensionCDHash=%s\n' "$production_extension_cdhash"
  printf 'syntheticExtensionCDHash=%s\n' "$gate_extension_cdhash"
  printf 'allowedSubstitution=%s/\n' "$production_helper_relative"
  printf 'allowedSubstitution=%s/\n' "$production_extension_relative"
  printf 'allowedSignatureEnvelope=%s\n' "$outer_executable_relative"
  printf 'allowedSubstitution=%s\n' "$outer_code_resources_relative"
} >"$manifest_temp"
/bin/mkdir -p "$(/usr/bin/dirname "$manifest_path")"
/bin/cp "$manifest_temp" "$manifest_path"

echo "PASS: gate differs only within $production_helper_relative/, $production_extension_relative/, and the outer signature envelope."
echo "PASS: signature-stripped outer executable code, identity, requirement, and entitlements are exact."
echo "PASS: LaunchAgent trees are byte-identical; extension evidence is topology-equivalent and records distinct production/gate CDHashes."
echo "Manifest: $manifest_path"
