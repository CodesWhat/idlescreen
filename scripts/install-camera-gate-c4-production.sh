#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/C3/IdleScreen.app /absolute/C3-provenance.txt /absolute/new-install-evidence-directory" >&2
  exit 64
}

[[ $# -eq 3 ]] || usage
candidate_app="$1"
c3_manifest="$2"
evidence_root="$3"
[[ "$candidate_app" = /* && "$c3_manifest" = /* && "$evidence_root" = /* ]] || usage
[[ -d "$candidate_app" && ! -L "$candidate_app" ]] || usage
[[ -f "$c3_manifest" && ! -L "$c3_manifest" ]] || usage
[[ "${IDLESCREEN_C4_AUTHORIZE_INSTALL_REBIND:-}" == YES ]] || {
  echo "REFUSED: C4 production installation/replacement requires IDLESCREEN_C4_AUTHORIZE_INSTALL_REBIND=YES." >&2
  exit 65
}

evidence_parent="$(/usr/bin/dirname "$evidence_root")"
[[ -d "$evidence_parent" && ! -L "$evidence_parent" ]] || usage
evidence_parent="$(/bin/realpath "$evidence_parent")"
evidence_root="$evidence_parent/$(/usr/bin/basename "$evidence_root")"
[[ ! -e "$evidence_root" && ! -L "$evidence_root" ]] || {
  echo "FAIL: refusing to replace C4 install evidence: $evidence_root" >&2
  exit 73
}

project_root="$(cd "$(dirname "$0")/.." && pwd)"
destination_app=/Applications/idlescreen.app
launch_agent_label=group.com.idlescreen.shared.camera-agent
launch_agent_domain="gui/$(/usr/bin/id -u)/$launch_agent_label"
extension_id=com.idlescreen.app.screensaver
production_verifier="$project_root/scripts/test-camera-agent-product.sh"
selection_probe="$evidence_root/ScreenSaverSelectionProbe"
selection_source="$project_root/scripts/ScreenSaverSelectionProbe.swift"
selection_client="$project_root/IdleScreenSystem/ScreenSaverSelection.swift"
staging_app="/Applications/.idlescreen-c4-staging-$$.app"
retired_app="/Applications/.idlescreen-c4-retired-$$.app"
backup_app="$evidence_root/prior-installed.app"
failed_app="$evidence_root/failed-candidate.app"
install_active=false

fail() {
  echo "FAIL: $*" >&2
  echo "Evidence: $evidence_root" >&2
  exit 1
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print tolower($1) }'
}

manifest_value() {
  local key="$1"
  /usr/bin/awk -F= -v key="$key" '$1 == key { print substr($0, length($1) + 2); count++ } END { exit(count == 1 ? 0 : 1) }' "$c3_manifest" ||
    fail "C3 manifest does not contain exactly one $key"
}

signed_cdhash() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 |
    /usr/bin/awk -F= '$1 == "CDHash" { print tolower($2); exit }'
}

write_tree_inventory() {
  local root="$1"
  local output="$2"
  local entry relative mode size digest target attribute value
  local find_output xattr_output
  : >"$output"
  find_output="$evidence_root/.tree-find-$$"
  [[ ! -e "$find_output" ]] || return 1
  /usr/bin/find -s "$root" -print0 >"$find_output" || return 1
  while IFS= read -r -d '' entry; do
    relative="${entry#"$root"}"
    relative="${relative#/}"
    [[ -n "$relative" ]] || relative=.
    [[ "$relative" != *$'\n'* && "$relative" != *$'\t'* ]] || return 1
    mode="$(/usr/bin/stat -f '%Lp' "$entry")" || return 1
    if [[ -L "$entry" ]]; then
      target="$(/usr/bin/readlink "$entry")" || return 1
      [[ "$target" != *$'\n'* && "$target" != *$'\t'* ]] || return 1
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
    xattr_output="$evidence_root/.tree-xattr-$$"
    [[ ! -e "$xattr_output" ]] || return 1
    /usr/bin/xattr "$entry" >"$xattr_output" 2>/dev/null || return 1
    LC_ALL=C /usr/bin/sort -o "$xattr_output" "$xattr_output" || return 1
    while IFS= read -r attribute; do
      [[ -n "$attribute" && "$attribute" != *$'\n'* && "$attribute" != *$'\t'* ]] || continue
      value="$(/usr/bin/xattr -px "$attribute" "$entry" 2>/dev/null)" || return 1
      value="${value//[[:space:]]/}"
      printf 'xattr\t%s\t%s\t%s\n' "$relative" "$attribute" "$value" >>"$output"
    done <"$xattr_output"
    /bin/rm "$xattr_output" || return 1
  done <"$find_output"
  /bin/rm "$find_output" || return 1
}

registered_extension_paths() {
  local output reported normalized
  output="$(/usr/bin/pluginkit -m -A -D -v -p com.apple.screensaver)" || return 1
  normalized="$(/usr/bin/awk -F '\t' -v identity="$extension_id(" '
    index($1, identity) { path=$NF; sub(/^[[:space:]]+/, "", path); sub(/[[:space:]]+$/, "", path); print path }
  ' <<<"$output")" || return 1
  while IFS= read -r reported; do
    [[ -n "$reported" ]] || continue
    /bin/realpath "$reported" || return 1
  done <<<"$normalized"
}

capture_selection_state() {
  local output="$1"
  local status
  set +e
  "$selection_probe" "$extension_id" >"$output" 2>&1
  status=$?
  set -e
  [[ "$status" == 0 || "$status" == 1 ]] || return 1
  [[ "$(/usr/bin/wc -l <"$output" | /usr/bin/xargs)" == 2 ]] || return 1
  /usr/bin/grep -Eq '^providers=[^[:cntrl:]]*$' "$output" || return 1
  /usr/bin/grep -Eq '^selectedEverywhere=(true|false)$' "$output" || return 1
}

assert_quiescent_fail_closed() {
  local process_table pid command text_path
  process_table="$(/bin/ps -ww -axo pid=,command=)" || return 1
  while read -r pid command; do
    case "$command" in
      *IdleScreen*|*ScreenSaverEngine*|*legacyScreenSaver*|*IdlescreenHelper*|*'System Settings'*) ;;
      *) continue ;;
    esac
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    text_path="$(/usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null |
      /usr/bin/awk 'substr($0,1,1)=="n" { print substr($0,2); count++ } END { exit(count == 1 ? 0 : 1) }')" || return 1
    [[ -n "$text_path" ]] || return 1
    printf '%s\t%s\n' "$pid" "$text_path" >>"$evidence_root/quiescence-blockers.tsv"
  done <<<"$process_table"
  [[ ! -s "$evidence_root/quiescence-blockers.tsv" ]]
}

retire_new_registration() {
  local registered registered_paths
  registered_paths="$(registered_extension_paths)" || return 1
  while IFS= read -r registered; do
    [[ -n "$registered" ]] || continue
    /usr/bin/pluginkit -r "$registered" >/dev/null 2>&1 || return 1
  done <<<"$registered_paths"
  /bin/launchctl bootout "$launch_agent_domain" >/dev/null 2>&1 || true
}

rollback() {
  local original_exit=$?
  trap - EXIT
  if $install_active; then
    retire_new_registration || {
      echo "CRITICAL: C4 rollback could not retire candidate registration." >&2
      exit 70
    }
    if [[ -e "$destination_app" ]]; then
      /bin/mv "$destination_app" "$failed_app" || exit 70
    fi
    if [[ -e "$retired_app" ]]; then
      /bin/mv "$retired_app" "$destination_app" || exit 70
    fi
  fi
  if [[ -e "$staging_app" ]]; then
    /bin/mv "$staging_app" "$evidence_root/failed-staging.app" || exit 70
  fi
  exit "$original_exit"
}
trap rollback EXIT

umask 077
/bin/mkdir "$evidence_root"
[[ -x "$production_verifier" ]] || fail "missing production verifier"
[[ -f "$selection_source" && -f "$selection_client" ]] || fail "missing selection probe source"
xcrun swiftc "$selection_client" "$selection_source" -o "$selection_probe" \
  >"$evidence_root/selection-probe-build.log" 2>&1 || fail "could not compile selection probe"
capture_selection_state "$evidence_root/selection-before.txt" ||
  fail "could not read the real ScreenSaver selection state"
/usr/bin/grep -Fxq "providers=$extension_id" "$evidence_root/selection-before.txt" &&
  /usr/bin/grep -Fxq 'selectedEverywhere=true' "$evidence_root/selection-before.txt" ||
  fail "C4 requires idlescreen to already be the saver selected everywhere"
[[ -d "$destination_app" && ! -L "$destination_app" ]] ||
  fail "C4 requires one existing canonical app to preserve recoverably"
[[ ! -e "$staging_app" && ! -e "$retired_app" ]] || fail "C4 staging path already exists"
[[ "$(/usr/bin/grep -Fxc 'verification_mode=release' "$c3_manifest" || true)" == 1 &&
   "$(/usr/bin/grep -Ec '^verification_mode=' "$c3_manifest" || true)" == 1 ]] ||
  fail "C3 manifest is not release-mode evidence"

"$production_verifier" "$candidate_app" Release >"$evidence_root/candidate-product-verification.log"
expected_app_cdhash="$(manifest_value app_cdhash)"
expected_helper_cdhash="$(manifest_value helper_cdhash)"
expected_extension_cdhash="$(manifest_value extension_cdhash)"
c3_archive_tree_sha256="$(manifest_value archive_tree_sha256)"
[[ "$c3_archive_tree_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "C3 archive hash is malformed"
[[ "$(signed_cdhash "$candidate_app")" == "$expected_app_cdhash" &&
   "$(signed_cdhash "$candidate_app/Contents/Helpers/IdleScreenCameraAgent.app")" == "$expected_helper_cdhash" &&
   "$(signed_cdhash "$candidate_app/Contents/PlugIns/IdleScreenScreenSaver.appex")" == "$expected_extension_cdhash" ]] ||
  fail "C3 candidate CDHashes do not match the release manifest"

registered_before="$(registered_extension_paths)" || fail "could not enumerate PlugInKit state"
[[ -z "$registered_before" ]] ||
  fail "safe C4 initial install currently requires no registered idlescreen provider"
if /bin/launchctl print "$launch_agent_domain" >"$evidence_root/launchd-before.txt" 2>&1; then
  fail "safe C4 initial install currently requires the camera LaunchAgent to be unbound"
fi
assert_quiescent_fail_closed || fail "process enumeration failed or relevant app/host/UI processes are not quiescent"

write_tree_inventory "$candidate_app" "$evidence_root/candidate-tree.tsv" ||
  fail "could not inventory exact C3 candidate"
write_tree_inventory "$destination_app" "$evidence_root/prior-tree.tsv" ||
  fail "could not inventory prior canonical app"
/usr/bin/ditto "$destination_app" "$backup_app" || fail "could not preserve prior canonical app"
write_tree_inventory "$backup_app" "$evidence_root/prior-backup-tree.tsv" ||
  fail "could not inventory prior app backup"
/usr/bin/cmp -s "$evidence_root/prior-tree.tsv" "$evidence_root/prior-backup-tree.tsv" ||
  fail "recoverable prior-app backup is not byte-exact"

/usr/bin/ditto "$candidate_app" "$staging_app" || fail "could not stage C3 production candidate"
write_tree_inventory "$staging_app" "$evidence_root/staging-tree.tsv" || fail "could not inventory staging app"
/usr/bin/cmp -s "$evidence_root/candidate-tree.tsv" "$evidence_root/staging-tree.tsv" ||
  fail "staged C3 candidate differs from archive product"
"$production_verifier" "$staging_app" Release >"$evidence_root/staging-product-verification.log"

/bin/mv "$destination_app" "$retired_app"
install_active=true
/bin/mv "$staging_app" "$destination_app"
/bin/sync
"$production_verifier" "$destination_app" Release >"$evidence_root/installed-product-verification.log"
write_tree_inventory "$destination_app" "$evidence_root/installed-tree.tsv" ||
  fail "could not inventory installed C3 candidate"
/usr/bin/cmp -s "$evidence_root/candidate-tree.tsv" "$evidence_root/installed-tree.tsv" ||
  fail "installed C3 production is not byte-exact to the archive product"
[[ -z "$(registered_extension_paths)" ]] ||
  fail "production installation unexpectedly changed PlugInKit state"
capture_selection_state "$evidence_root/selection-after.txt" ||
  fail "could not recheck the real ScreenSaver selection state"
/usr/bin/cmp -s "$evidence_root/selection-before.txt" "$evidence_root/selection-after.txt" ||
  fail "production installation changed ScreenSaver selection state"
if /bin/launchctl print "$launch_agent_domain" >"$evidence_root/launchd-after.txt" 2>&1; then
  fail "production installation unexpectedly bound the camera LaunchAgent"
fi

# The prior product is already retained byte-exact under the durable evidence
# root, so the retired in-place copy can no longer influence discovery.
/bin/rm -rf "$retired_app"
install_active=false
trap - EXIT

{
  printf 'schema=IdleScreenC4ProductionInstall/v1\n'
  printf 'verification_mode=release\n'
  printf 'c3_archive_tree_sha256=%s\n' "$c3_archive_tree_sha256"
  printf 'c3_provenance_manifest_sha256=%s\n' "$(sha256_file "$c3_manifest")"
  printf 'app_cdhash=%s\n' "$expected_app_cdhash"
  printf 'helper_cdhash=%s\n' "$expected_helper_cdhash"
  printf 'extension_cdhash=%s\n' "$expected_extension_cdhash"
  printf 'candidate_tree_sha256=%s\n' "$(sha256_file "$evidence_root/candidate-tree.tsv")"
  printf 'installed_tree_sha256=%s\n' "$(sha256_file "$evidence_root/installed-tree.tsv")"
  printf 'prior_backup_tree_sha256=%s\n' "$(sha256_file "$evidence_root/prior-backup-tree.tsv")"
  printf 'initial_registration=unbound\n'
  printf 'final_registration=unbound\n'
  printf 'camera_tcc_action=none\n'
} >"$evidence_root/install-manifest.txt"

echo "PASS: exact C3 production candidate installed byte-for-byte at $destination_app."
echo "PASS: prior app is recoverable; registration stayed unbound and no camera/TCC action ran."
echo "Evidence: $evidence_root"
