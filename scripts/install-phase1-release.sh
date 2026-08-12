#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/Release/IdleScreen.app" >&2
  exit 64
}

[[ $# -eq 1 ]] || usage

candidate_app="$1"
destination_app="/Applications/idlescreen.app"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
signing_verifier="$project_root/scripts/verify-release-signing.sh"
camera_product_verifier="$project_root/scripts/test-camera-agent-product.sh"
state_capture="$project_root/scripts/capture-phase1-physical-state.sh"
extension_id="com.idlescreen.app.screensaver"
current_user_uid="$(/usr/bin/id -u)"
camera_agent_label="group.com.idlescreen.shared.camera-agent"
camera_agent_domain="gui/$current_user_uid/$camera_agent_label"
camera_helper_relative="Contents/Helpers/IdleScreenCameraAgent.app"
wallpaper_agent_executable="/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent"
launch_services_register="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
artifact_root=""
rollback_pending=false
staging_cleanup_pending=false

[[ "$candidate_app" = /* ]] || usage

fail() {
  echo "FAIL: $*" >&2
  [[ -z "$artifact_root" ]] || echo "Evidence: $artifact_root" >&2
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
  echo "REFUSED: the console is locked; unlock normally before replacing the canonical Release." >&2
  exit 65
elif ((console_lock_status != 1)); then
  echo "REFUSED: the console lock state could not be verified; canonical replacement will not run fail-open." >&2
  exit 65
fi
if pgrep -x ScreenSaverEngine >/dev/null; then
  echo "REFUSED: ScreenSaverEngine is active; finish the physical session before installing Release." >&2
  exit 65
fi
if /bin/ps ax -o comm= |
   grep -Fq '/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver'; then
  echo "REFUSED: a modern screen-saver extension is active; finish the physical session before installing Release." >&2
  exit 65
fi
if /bin/ps ax -o comm= |
   grep -Fxq '/Applications/idlescreen.app/Contents/MacOS/IdleScreen'; then
  echo "REFUSED: the canonical companion is active; quit it before replacing its bundle." >&2
  exit 65
fi
if /bin/ps ax -o comm= | grep -Fq '/IdlescreenHelper'; then
  echo "REFUSED: the legacy helper is active; unload it before installing the modern Release." >&2
  exit 65
fi
if pgrep -x 'System Settings' >/dev/null; then
  echo "REFUSED: quit System Settings before replacing the screen-saver extension; the installer will not take focus or close it for you." >&2
  exit 65
fi

[[ -x "$signing_verifier" ]] || fail "missing Release signing verifier"
[[ -x "$camera_product_verifier" ]] || fail "missing camera-agent product verifier"
[[ -x "$state_capture" ]] || fail "missing Phase 1 state recorder"
[[ -x "$launch_services_register" ]] || fail "missing LaunchServices registration utility"
[[ -d "$candidate_app" ]] || fail "missing Release candidate: $candidate_app"
[[ -d "$destination_app" ]] || fail "missing canonical app to update: $destination_app"
[[ "$(/bin/realpath "$candidate_app")" != "$(/bin/realpath "$destination_app")" ]] ||
  fail "candidate and destination resolve to the same app"

"$signing_verifier" "$candidate_app"
"$camera_product_verifier" "$candidate_app" Release

artifact_root="$(mktemp -d /tmp/idlescreen-phase1-install.XXXXXX)"
selection_probe="$artifact_root/selection-probe"
staging_app="/Applications/.idlescreen-install-$$.app"
timestamp="$(date -u '+%Y%m%d-%H%M%S')"
backup_app="$HOME/.Trash/idlescreen-pre-phase1-$timestamp-$$.app"
failed_app="$HOME/.Trash/idlescreen-failed-phase1-$timestamp-$$.app"
failed_staging_app="$HOME/.Trash/idlescreen-failed-staging-$timestamp-$$.app"
destination_extension="$destination_app/Contents/PlugIns/IdleScreenScreenSaver.appex"

[[ ! -e "$staging_app" ]] || fail "staging path already exists: $staging_app"
[[ ! -e "$backup_app" && ! -e "$failed_app" && ! -e "$failed_staging_app" ]] ||
  fail "a recoverable install path already exists"
mkdir -p "$HOME/.Trash"

selected_extension_path() {
  /usr/bin/pluginkit -m -v -p com.apple.screensaver | awk -F '\t' -v identity="$extension_id(" '
    !found && index($1, identity) {
      path = $NF
      sub(/^[[:space:]]+/, "", path)
      sub(/[[:space:]]+$/, "", path)
      print path
      found = 1
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
  local first_path
  local second_path

  [[ -n "$1" && -n "$2" ]] || return 1
  first_path="$(/bin/realpath "$1" 2>/dev/null)" || return 1
  second_path="$(/bin/realpath "$2" 2>/dev/null)" || return 1
  [[ "$first_path" == "$second_path" ]]
}

wait_for_only_registered_path() {
  local expected_path="$1"
  local deadline=$((SECONDS + 30))
  local stable_observations=0
  local stable_observation_target=10

  while ((SECONDS < deadline)); do
    # Replacing an extension at the same canonical path can briefly expose the
    # old cached PlugInKit record before its asynchronous invalidation lands.
    # Keep submitting the new on-disk extension while waiting for a stable
    # inventory; otherwise that invalidation can leave the inventory empty for
    # the remainder of the deadline even though the first path-only check
    # appeared to succeed.
    if [[ -n "$expected_path" ]]; then
      /usr/bin/pluginkit -a "$expected_path" >/dev/null 2>&1 || true
    fi
    if registration_inventory_is_only_path "$expected_path"; then
      stable_observations=$((stable_observations + 1))
    else
      stable_observations=0
    fi
    if ((stable_observations >= stable_observation_target)); then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

registration_inventory_is_only_path() {
  local expected_path="$1"
  local registered_paths
  local canonical_registered_paths
  local expected_canonical_path

  registered_paths="$(registered_extension_paths)" || return 1
  if [[ -z "$expected_path" ]]; then
    [[ -z "$registered_paths" ]]
    return
  fi
  canonical_registered_paths="$(
    while IFS= read -r registered_path; do
      [[ -z "$registered_path" ]] || /bin/realpath "$registered_path"
    done <<<"$registered_paths" | /usr/bin/sort -u
  )" || return 1
  expected_canonical_path="$(/bin/realpath "$expected_path")" || return 1
  [[ "$(sed '/^$/d' <<<"$canonical_registered_paths" | wc -l | tr -d ' ')" -eq 1 &&
     "$canonical_registered_paths" == "$expected_canonical_path" ]]
}

register_extension_until_visible() {
  local extension_path="$1"
  local deadline=$((SECONDS + 30))

  while ((SECONDS < deadline)); do
    /usr/bin/pluginkit -a "$extension_path" >/dev/null 2>&1 || true
    if registration_inventory_is_only_path "$extension_path"; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_for_selected_path() {
  local expected_path="$1"
  local deadline=$((SECONDS + 30))
  local selected_path
  local stable_observations=0
  local stable_observation_target=10

  while ((SECONDS < deadline)); do
    selected_path="$(selected_extension_path)" || return 1
    if [[ -z "$expected_path" && -z "$selected_path" ]]; then
      stable_observations=$((stable_observations + 1))
    elif paths_refer_to_same_file "$selected_path" "$expected_path"; then
      stable_observations=$((stable_observations + 1))
    else
      stable_observations=0
    fi
    if ((stable_observations >= stable_observation_target)); then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

current_user_wallpaper_agent_pids() {
  /bin/ps -axo pid=,uid=,comm= | awk \
    -v expected_uid="$current_user_uid" \
    -v expected_executable="$wallpaper_agent_executable" '
      $2 == expected_uid && $3 == expected_executable { print $1 }
    '
}

single_current_user_wallpaper_agent_pid() {
  local pid_list
  local pid_count

  pid_list="$(current_user_wallpaper_agent_pids)" || return 1
  pid_count="$(printf '%s\n' "$pid_list" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "$pid_count" -ne 1 ]]; then
    echo "FAIL: expected exactly one current-user Apple WallpaperAgent, found $pid_count." >&2
    return 1
  fi
  printf '%s\n' "$pid_list"
}

restart_wallpaper_agent() {
  local old_pid
  local guarded_pid
  local current_pid
  local current_pid_list
  local current_pid_count
  local deadline=$((SECONDS + 15))
  local graceful_deadline=$((SECONDS + 2))
  local forced_restart=false

  old_pid="$(single_current_user_wallpaper_agent_pid)" || return 1

  # Resolve the exact uid and executable again immediately before signalling so
  # a stale PID can never redirect the restart to an unrelated process.
  guarded_pid="$(single_current_user_wallpaper_agent_pid)" || return 1
  [[ "$guarded_pid" == "$old_pid" ]] || {
    echo "FAIL: WallpaperAgent identity changed before the guarded restart." >&2
    return 1
  }
  /bin/kill -TERM "$old_pid" || return 1

  while ((SECONDS < deadline)); do
    current_pid_list="$(current_user_wallpaper_agent_pids)" || return 1
    current_pid_count="$(printf '%s\n' "$current_pid_list" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [[ "$current_pid_count" -gt 1 ]]; then
      echo "FAIL: multiple current-user Apple WallpaperAgent processes appeared after restart." >&2
      return 1
    fi
    if [[ "$current_pid_count" -eq 1 ]]; then
      current_pid="$(printf '%s\n' "$current_pid_list" | sed '/^$/d')"
      if [[ "$current_pid" =~ ^[1-9][0-9]*$ && "$current_pid" != "$old_pid" ]]; then
        return 0
      fi
      # Tahoe 26.5.2 can leave WallpaperAgent alive after a successful TERM,
      # while SIP rejects launchctl kickstart for this Apple job. Escalate only
      # after the graceful window and only if a second exact uid/path lookup
      # still resolves the original PID. KILL remains narrowly targeted and
      # launchd immediately relaunches the per-user Apple agent.
      if ! $forced_restart && ((SECONDS >= graceful_deadline)) &&
         [[ "$current_pid" == "$old_pid" ]]; then
        guarded_pid="$(single_current_user_wallpaper_agent_pid)" || return 1
        [[ "$guarded_pid" == "$old_pid" ]] || {
          echo "FAIL: WallpaperAgent identity changed before the guarded forced restart." >&2
          return 1
        }
        /bin/kill -KILL "$old_pid" || return 1
        forced_restart=true
      fi
    fi
    sleep 0.1
  done
  return 1
}

settle_canonical_registration() {
  local expected_path="$1"

  wait_for_only_registered_path "$expected_path" || {
    echo "FAIL: PlugInKit registration inventory did not converge." >&2
    registered_extension_paths \
      >"$artifact_root/registration-inventory-failure-paths.txt" 2>&1 || true
    /usr/bin/pluginkit -m -A -D -v -p com.apple.screensaver \
      >"$artifact_root/registration-inventory-failure-full.txt" 2>&1 || true
    return 1
  }
  restart_wallpaper_agent || {
    echo "FAIL: WallpaperAgent did not restart to a new exact PID." >&2
    return 1
  }
  wait_for_selected_path "$expected_path" || {
    echo "FAIL: the selected screen-saver provider did not converge after the host restart." >&2
    return 1
  }
}

current_camera_agent_pid() {
  /bin/launchctl print "$camera_agent_domain" 2>/dev/null |
    /usr/bin/awk -F ' = ' '
      /^[[:space:]]*pid = / { value = $2 }
      END { if (value != "") print value }
    '
}

signed_cdhash() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 |
    /usr/bin/awk -F= '
      $1 == "CDHash" { value = tolower($2) }
      END { if (value != "") print value }
    '
}

rebind_camera_agent() {
  local app_path="$1"
  local previous_process_identifier="$2"
  local result_path="$3"
  local launch_log="$4"
  local helper_path="$app_path/$camera_helper_relative"
  local expected_source_path
  local expected_bundle_version
  local expected_cdhash
  local result_status
  local result_previous_process_identifier
  local result_process_identifier
  local result_process_epoch
  local result_bundle_version
  local result_source_path
  local result_cdhash
  local companion_process_identifier
  local launchd_snapshot="$result_path.launchd.txt"
  local launchd_process_identifier
  local launchd_parent_bundle_version
  local launch_arguments=()
  local deadline=$((SECONDS + 20))

  [[ -d "$app_path" && -d "$helper_path" ]] || {
    echo "FAIL: camera-agent rebind could not find the installed app or embedded helper." >&2
    return 1
  }
  [[ ! -e "$result_path" && ! -e "$launchd_snapshot" ]] || {
    echo "FAIL: camera-agent rebind evidence paths already exist." >&2
    return 1
  }
  expected_source_path="$(/bin/realpath "$app_path")" || {
    echo "FAIL: camera-agent rebind could not canonicalize the installed app path." >&2
    return 1
  }
  expected_bundle_version="$(/usr/bin/plutil -extract CFBundleVersion raw "$helper_path/Contents/Info.plist")" || {
    echo "FAIL: camera-agent rebind could not read the embedded helper version." >&2
    return 1
  }
  expected_cdhash="$(signed_cdhash "$helper_path")" || {
    echo "FAIL: camera-agent rebind could not read the embedded helper CDHash." >&2
    return 1
  }
  [[ "$expected_cdhash" =~ ^[[:xdigit:]]{40,64}$ ]] || {
    echo "FAIL: camera-agent rebind found an invalid embedded helper CDHash: $expected_cdhash" >&2
    return 1
  }

  launch_arguments=("--idlescreen-camera-agent-rebind-result=$result_path")
  if [[ -n "$previous_process_identifier" ]]; then
    [[ "$previous_process_identifier" =~ ^[1-9][0-9]*$ ]] || {
      echo "FAIL: camera-agent rebind received an invalid previous PID: $previous_process_identifier" >&2
      return 1
    }
    launch_arguments+=(
      "--idlescreen-camera-agent-rebind-previous-pid=$previous_process_identifier"
    )
  fi
  /usr/bin/open -g -j -n "$app_path" --args "${launch_arguments[@]}" \
    >"$launch_log" 2>&1 || {
      echo "FAIL: camera-agent rebind could not launch the installed companion." >&2
      return 1
    }

  while ((SECONDS < deadline)); do
    [[ -f "$result_path" ]] && break
    sleep 0.1
  done
  [[ -f "$result_path" ]] || {
    echo "FAIL: camera-agent rebind timed out waiting for the installed companion result." >&2
    return 1
  }

  result_status="$(/usr/bin/plutil -extract status raw "$result_path" 2>/dev/null)" || {
    echo "FAIL: camera-agent rebind result has no status." >&2
    return 1
  }
  [[ "$result_status" == verified ]] || {
    /usr/bin/plutil -extract failureMessage raw "$result_path" 2>/dev/null >&2 || true
    return 1
  }
  companion_process_identifier="$(/usr/bin/plutil -extract companionProcessIdentifier raw "$result_path")" || return 1
  result_process_identifier="$(/usr/bin/plutil -extract helperProcessIdentifier raw "$result_path")" || return 1
  result_process_epoch="$(/usr/bin/plutil -extract helperProcessEpoch raw "$result_path")" || return 1
  result_bundle_version="$(/usr/bin/plutil -extract helperBundleVersion raw "$result_path")" || return 1
  result_source_path="$(/usr/bin/plutil -extract helperSourceAppPath raw "$result_path")" || return 1
  result_cdhash="$(/usr/bin/plutil -extract helperCodeDirectoryHash raw "$result_path" | /usr/bin/tr '[:upper:]' '[:lower:]')" || return 1

  [[ "$companion_process_identifier" =~ ^[1-9][0-9]*$ &&
     "$result_process_identifier" =~ ^[1-9][0-9]*$ &&
     "$result_process_epoch" =~ ^[1-9][0-9]*$ ]] || {
    echo "FAIL: camera-agent rebind result contains an invalid companion PID, helper PID, or process epoch." >&2
    return 1
  }
  [[ "$result_bundle_version" == "$expected_bundle_version" &&
     "$result_source_path" == "$expected_source_path" &&
     "$result_cdhash" == "$expected_cdhash" ]] || {
    echo "FAIL: camera-agent rebind result does not match the installed helper identity." >&2
    return 1
  }
  if [[ -n "$previous_process_identifier" ]]; then
    result_previous_process_identifier="$(/usr/bin/plutil -extract previousHelperProcessIdentifier raw "$result_path")" || return 1
    [[ "$result_previous_process_identifier" == "$previous_process_identifier" &&
       "$result_process_identifier" != "$previous_process_identifier" ]] || {
      echo "FAIL: camera-agent rebind did not replace previous PID $previous_process_identifier." >&2
      return 1
    }
  fi

  for _ in {1..50}; do
    /bin/kill -0 "$companion_process_identifier" 2>/dev/null || break
    sleep 0.1
  done
  /bin/kill -0 "$companion_process_identifier" 2>/dev/null && {
    echo "FAIL: hidden camera-agent rebind companion PID $companion_process_identifier did not exit." >&2
    return 1
  }

  /bin/launchctl print "$camera_agent_domain" >"$launchd_snapshot" 2>&1 || {
    echo "FAIL: launchd does not expose the rebound camera-agent job." >&2
    return 1
  }
  launchd_process_identifier="$(/usr/bin/awk -F ' = ' '/^[[:space:]]*pid = / { print $2; exit }' "$launchd_snapshot")"
  launchd_parent_bundle_version="$(/usr/bin/awk -F ' = ' '/^[[:space:]]*parent bundle version = / { print $2; exit }' "$launchd_snapshot")"
  [[ "$launchd_process_identifier" == "$result_process_identifier" ]] || {
    echo "FAIL: launchd camera-agent PID $launchd_process_identifier differs from authenticated PID $result_process_identifier." >&2
    return 1
  }
  [[ "$launchd_parent_bundle_version" == "$(/usr/bin/plutil -extract CFBundleVersion raw "$app_path/Contents/Info.plist")" ]] || {
    echo "FAIL: launchd camera-agent parent version $launchd_parent_bundle_version is stale." >&2
    return 1
  }

  if [[ -n "$previous_process_identifier" ]] &&
     /bin/ps -p "$previous_process_identifier" -o comm= 2>/dev/null |
       /usr/bin/grep -Fq 'IdleScreenCameraAgent'; then
    echo "FAIL: previous camera-agent PID $previous_process_identifier is still running." >&2
    return 1
  fi
}

shared_configuration_matches() {
  local before="$1/shared-state/configuration.json"
  local after="$2/shared-state/configuration.json"

  if [[ -e "$before" || -e "$after" ]]; then
    [[ -f "$before" && -f "$after" ]] || return 1
    /usr/bin/cmp -s "$before" "$after"
  fi
}

rollback_install() {
  $rollback_pending || return 0

  while IFS= read -r registered_path; do
    [[ -z "$registered_path" ]] || /usr/bin/pluginkit -r "$registered_path" >/dev/null 2>&1 || true
  done <<<"$(registered_extension_paths)"

  if [[ -e "$backup_app" ]]; then
    if [[ -e "$destination_app" ]]; then
      /bin/mv "$destination_app" "$failed_app" || return 1
    fi
    /bin/mv "$backup_app" "$destination_app" || return 1
  fi
  if [[ -e "$staging_app" ]]; then
    /bin/mv "$staging_app" "$failed_staging_app" || return 1
  fi
  if [[ -d "$destination_extension" ]]; then
    "$launch_services_register" -f "$destination_app" >/dev/null 2>&1 || return 1
    register_extension_until_visible "$destination_extension" || return 1
    settle_canonical_registration "$destination_extension" || return 1
  fi
  rollback_selection="$($selection_probe "$extension_id")" || return 1
  if [[ "$rollback_selection" != "$selection_before" ]]; then
    echo "FAIL: rollback did not restore the production provider set." >&2
    return 1
  fi
  rollback_pending=false
  staging_cleanup_pending=false
}

cleanup_staging() {
  $staging_cleanup_pending || return 0
  if [[ -e "$staging_app" ]]; then
    /bin/mv "$staging_app" "$failed_staging_app" || return 1
  fi
  staging_cleanup_pending=false
}

handle_installer_exit() {
  local command_exit=$?
  trap - EXIT
  if $rollback_pending; then
    if ! rollback_install; then
      echo "CRITICAL: automatic Release rollback failed; inspect $artifact_root and the explicit Trash paths before continuing." >&2
      exit 70
    fi
    echo "INFO: automatic rollback restored the previous canonical Release and registration." >&2
  elif $staging_cleanup_pending; then
    if ! cleanup_staging; then
      echo "CRITICAL: Release staging cleanup failed; inspect $staging_app before continuing." >&2
      exit 70
    fi
    echo "INFO: incomplete Release staging was moved recoverably to $failed_staging_app." >&2
  fi
  exit "$command_exit"
}

trap handle_installer_exit EXIT

xcrun swiftc \
  "$project_root/IdleScreenSystem/ScreenSaverSelection.swift" \
  "$project_root/scripts/ScreenSaverSelectionProbe.swift" \
  -o "$selection_probe" || fail "could not compile the production selection probe"
selection_before="$($selection_probe "$extension_id")" || {
  printf '%s\n' "$selection_before" >&2
  fail "$extension_id is not the screen saver selected everywhere"
}

initial_registered_paths="$(registered_extension_paths)"
[[ "$(sed '/^$/d' <<<"$initial_registered_paths" | wc -l | tr -d ' ')" -eq 1 ]] ||
  fail "canonical Release update requires exactly one existing registration"
[[ "$(/bin/realpath "$initial_registered_paths")" == "$(/bin/realpath "$destination_extension")" ]] ||
  fail "existing registration is not the canonical extension"
[[ "$(/bin/realpath "$(selected_extension_path)")" == "$(/bin/realpath "$destination_extension")" ]] ||
  fail "canonical extension is not the active registration"
wallpaper_agent_preflight_pid="$(single_current_user_wallpaper_agent_pid)" ||
  fail "canonical Release update requires exactly one current-user Apple WallpaperAgent"
printf '%s\n' "$wallpaper_agent_preflight_pid" >"$artifact_root/wallpaper-agent-preflight-pid.txt"
camera_agent_preflight_pid="$(current_camera_agent_pid)" ||
  fail "canonical Release update requires the enabled camera agent"
[[ "$camera_agent_preflight_pid" =~ ^[1-9][0-9]*$ ]] ||
  fail "canonical Release update requires one running camera-agent PID"
printf '%s\n' "$camera_agent_preflight_pid" >"$artifact_root/camera-agent-preflight-pid.txt"

"$state_capture" "$destination_app" "$artifact_root" before-install
printf '%s\n' "$selection_before" >"$artifact_root/selection-before.txt"

staging_cleanup_pending=true
/usr/bin/ditto "$candidate_app" "$staging_app" || fail "could not stage the Release candidate"
"$signing_verifier" "$staging_app" >"$artifact_root/staging-signing-verification.txt"

candidate_app_hash="$(/usr/bin/shasum -a 256 "$candidate_app/Contents/MacOS/IdleScreen" | awk '{print $1}')"
candidate_extension_hash="$(
  /usr/bin/shasum -a 256 \
    "$candidate_app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver" |
    awk '{print $1}'
)"

rollback_pending=true
/usr/bin/pluginkit -r "$destination_extension" || fail "could not unregister the existing canonical extension"
wait_for_only_registered_path "" || fail "existing Release registration did not disappear"

/bin/mv "$destination_app" "$backup_app" || fail "could not move the previous Release to the Trash"
/bin/mv "$staging_app" "$destination_app" || fail "could not place the verified Release at the canonical path"
staging_cleanup_pending=false

"$signing_verifier" "$destination_app" >"$artifact_root/installed-signing-verification.txt"
installed_app_hash="$(/usr/bin/shasum -a 256 "$destination_app/Contents/MacOS/IdleScreen" | awk '{print $1}')"
installed_extension_hash="$(
  /usr/bin/shasum -a 256 \
    "$destination_extension/Contents/MacOS/IdleScreenScreenSaver" |
    awk '{print $1}'
)"
[[ "$installed_app_hash" == "$candidate_app_hash" ]] || fail "installed companion hash differs from the candidate"
[[ "$installed_extension_hash" == "$candidate_extension_hash" ]] || fail "installed extension hash differs from the candidate"

# A replacement app at the same canonical path still needs a fresh
# LaunchServices bundle record before PlugInKit can discover its new embedded
# extension. Without this boundary Tahoe reports "no appex record" and silently
# ignores an otherwise successful `pluginkit -a` request.
"$launch_services_register" -f "$destination_app" >/dev/null 2>&1 ||
  fail "could not register the replacement app with LaunchServices"
register_extension_until_visible "$destination_extension" ||
  fail "could not register the canonical extension after LaunchServices accepted the replacement app"
settle_canonical_registration "$destination_extension" ||
  fail "canonical registration did not converge to one selected path or produce a new WallpaperAgent PID"

selection_after="$($selection_probe "$extension_id")" ||
  fail "screen-saver selection did not survive the canonical Release update"
[[ "$selection_after" == "$selection_before" ]] ||
  fail "screen-saver provider set changed during the canonical Release update"
printf '%s\n' "$selection_after" >"$artifact_root/selection-after.txt"

rollback_pending=false
trap - EXIT

rebind_camera_agent \
  "$destination_app" \
  "$camera_agent_preflight_pid" \
  "$artifact_root/camera-agent-rebind.plist" \
  "$artifact_root/camera-agent-rebind-launch.log" ||
  fail "the installed app could not replace and authenticate its camera agent"

"$state_capture" "$destination_app" "$artifact_root" after-install
shared_configuration_matches \
  "$artifact_root/before-install" \
  "$artifact_root/after-install" ||
  fail "shared user configuration changed during the Release update"

{
  printf 'candidateAppHash=%s\n' "$candidate_app_hash"
  printf 'candidateExtensionHash=%s\n' "$candidate_extension_hash"
  printf 'installedAppHash=%s\n' "$installed_app_hash"
  printf 'installedExtensionHash=%s\n' "$installed_extension_hash"
  printf 'recoverablePreviousApp=%s\n' "$backup_app"
} >"$artifact_root/install-result.txt"

echo "PASS: verified Release candidate installed at $destination_app."
echo "PASS: one canonical registration and the production provider set were preserved."
echo "PASS: the installed app replaced and authenticated a new camera-agent PID without camera demand."
echo "Previous app: $backup_app"
echo "Evidence: $artifact_root"
