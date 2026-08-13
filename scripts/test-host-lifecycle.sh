#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/idlescreen.app [start-timeout-seconds] [invalidation-timeout-seconds] [minimum-sustain-seconds]" >&2
  exit 64
}

[[ $# -ge 1 && $# -le 4 ]] || usage

app_path="$1"
timeout_seconds="${2:-30}"
invalidation_timeout_seconds="${3:-0}"
minimum_sustain_seconds="${4:-5}"
activation_mode="${IDLESCREEN_HOST_ACTIVATION:-manual}"
[[ "$app_path" = /* ]] || usage
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$invalidation_timeout_seconds" =~ ^[0-9]+$ ]] || usage
[[ "$minimum_sustain_seconds" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$activation_mode" == manual || "$activation_mode" == idle ]] || usage

if [[ "${IDLESCREEN_ALLOW_PHYSICAL_TESTS:-NO}" != YES ]]; then
  echo "REFUSED: set IDLESCREEN_ALLOW_PHYSICAL_TESTS=YES only after explicitly authorizing a focus-changing physical screen-saver run." >&2
  exit 65
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
extension_path="$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex"
extension_info="$extension_path/Contents/Info.plist"
log_verifier="$project_root/scripts/verify-host-lifecycle-log.sh"
cycle_log_verifier="$project_root/scripts/verify-host-lifecycle-cycle-log.sh"
idle_origin_verifier="$project_root/scripts/verify-idle-activation-log.sh"
artifact_root="$(mktemp -d /tmp/idlescreen-host-lifecycle.XXXXXX)"
log_path="$artifact_root/host.log"
log_stream_pid=""

stop_log_stream() {
  [[ "$log_stream_pid" =~ ^[1-9][0-9]*$ ]] || return 0
  if /bin/ps -p "$log_stream_pid" -o comm= >/dev/null 2>&1; then
    /bin/kill "$log_stream_pid" >/dev/null 2>&1 || true
  fi
  wait "$log_stream_pid" >/dev/null 2>&1 || true
  log_stream_pid=""
}

trap stop_log_stream EXIT

fail() {
  echo "FAIL: $*" >&2
  echo "Evidence: $artifact_root" >&2
  exit 1
}

[[ -d "$extension_path" ]] || fail "missing embedded extension: $extension_path"
[[ -f "$extension_info" ]] || fail "missing extension Info.plist"
[[ -x "$log_verifier" ]] || fail "missing lifecycle log verifier"
[[ -x "$cycle_log_verifier" ]] || fail "missing completed-cycle log verifier"
[[ -x "$idle_origin_verifier" ]] || fail "missing idle activation-origin verifier"

extension_id="$(plutil -extract CFBundleIdentifier raw "$extension_info")"
if [[ "$extension_id" == "com.idlescreen.app.screensaver" ]]; then
  canonical_release_app="/Applications/idlescreen.app"
  [[ "$(/bin/realpath "$app_path")" == "$canonical_release_app" ]] ||
    fail "the Release app must be installed exactly at $canonical_release_app before physical host testing"
fi

selection_probe="$artifact_root/selection-probe"
xcrun swiftc \
  "$project_root/Sources/IdleScreenSystem/ScreenSaverSelection.swift" \
  "$project_root/scripts/ScreenSaverSelectionProbe.swift" \
  -o "$selection_probe" || fail "could not compile the production selection probe"

selection_output=""
if ! selection_output="$($selection_probe "$extension_id" 2>&1)"; then
  printf '%s\n' "$selection_output" >&2
  fail "$extension_id is not the screen saver selected everywhere"
fi
printf '%s\n' "$selection_output"

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

registration_is_exact() {
  local selected_path
  local candidate_path
  local matching_path_count=0

  selected_path="$(selected_extension_path)"
  [[ -n "$selected_path" ]] || return 1
  [[ "$(/bin/realpath "$selected_path")" == "$(/bin/realpath "$extension_path")" ]] || return 1

  while IFS= read -r candidate_path; do
    [[ -n "$candidate_path" ]] || continue
    [[ "$(/bin/realpath "$candidate_path")" == "$(/bin/realpath "$extension_path")" ]] || return 1
    matching_path_count=$((matching_path_count + 1))
  done <<<"$(registered_extension_paths)"

  ((matching_path_count == 1))
}

selection_is_current() {
  "$selection_probe" "$extension_id" >/dev/null 2>&1 && registration_is_exact
}

registered_path="$(selected_extension_path)"
[[ -n "$registered_path" ]] || fail "pluginkit does not report $extension_id"
[[ "$(/bin/realpath "$registered_path")" == "$(/bin/realpath "$extension_path")" ]] ||
  fail "selected registration points to $registered_path instead of $extension_path"
registration_is_exact || fail "pluginkit reports a duplicate or mismatched registration for $extension_id"

current_lock_state() {
  "$project_root/scripts/read-console-lock-state.sh"
}

lock_state="$(current_lock_state)" || fail "could not read the console-session lock state"
[[ "$lock_state" == false ]] || fail "the console session is locked; unlock before running the physical host test"

if pgrep -x ScreenSaverEngine >/dev/null; then
  fail "ScreenSaverEngine is already running"
fi

if pgrep -x legacyScreenSaver >/dev/null; then
  fail "legacyScreenSaver is still running; stop the old saver before testing the modern extension"
fi

if pgrep -f '/IdlescreenHelper(\.app)?/Contents/MacOS/IdlescreenHelper' >/dev/null; then
  fail "IdlescreenHelper is still running; unload the old helper before testing the modern extension"
fi

log_stream_timeout_seconds=$((timeout_seconds + invalidation_timeout_seconds + minimum_sustain_seconds + 15))
log_predicate="process == \"IdleScreenScreenSaver\" OR (process == \"WallpaperAgent\" AND subsystem == \"com.apple.ScreenSaver\") OR (process == \"launchservicesd\" AND (eventMessage CONTAINS[c] \"$extension_id\" OR eventMessage CONTAINS[c] \"idlescreen (Wallpaper)\")) OR (process == \"loginwindow\" AND eventMessage CONTAINS[c] \"kLWLockFromScreenSaver\")"
/usr/bin/log stream \
  --style compact \
  --level info \
  --timeout "$log_stream_timeout_seconds" \
  --predicate "$log_predicate" \
  >"$log_path" 2>/dev/null &
log_stream_pid=$!

for _ in {1..20}; do
  /bin/ps -p "$log_stream_pid" -o comm= >/dev/null 2>&1 ||
    fail "the unified-log stream exited before the physical host launched"
  [[ -s "$log_path" ]] && break
  sleep 0.05
done

capture_host_log() {
  /bin/ps -p "$log_stream_pid" -o comm= >/dev/null 2>&1 ||
    fail "the unified-log stream ended before lifecycle verification completed"
}

case "$activation_mode" in
  manual)
    /usr/bin/open -a ScreenSaverEngine || fail "LaunchServices could not start ScreenSaverEngine"
    ;;
  idle)
    echo "WAIT: stop input and allow macOS to activate the configured idle screen saver; this runner will not launch it."
    ;;
esac

latest_extension_pid() {
  grep -F 'IdleScreenScreenSaver[' "$log_path" |
    grep -F 'Extension initialized' |
    grep -F 'compatible=true' |
    sed -nE 's/.*IdleScreenScreenSaver\[([0-9]+):.*pid=([0-9]+) compatible=true.*/\1 \2/p' |
    awk '$1 == $2 { print $1 }' |
    tail -1
}

animation_stopped_after_latest_start() {
  local extension_pid="$1"
  local process_prefix="IdleScreenScreenSaver[$extension_pid:"
  local start_line
  local stop_line

  start_line="$(grep -nF "$process_prefix" "$log_path" | grep -F 'Animation started preview=false' | tail -1 | cut -d: -f1 || true)"
  stop_line="$(grep -nF "$process_prefix" "$log_path" | grep -F 'Animation stopped preview=false' | tail -1 | cut -d: -f1 || true)"
  [[ -n "$start_line" && -n "$stop_line" ]] && ((stop_line > start_line))
}

display_sleep_observed() {
  local extension_pid="$1"
  grep -F "IdleScreenScreenSaver[$extension_pid:" "$log_path" |
    grep -Fq 'kCGSDisplayWillSleep'
}

deadline=$((SECONDS + timeout_seconds))
while ((SECONDS < deadline)); do
  capture_host_log

  set +e
  "$log_verifier" "$log_path" false >/dev/null 2>&1
  verification_status=$?
  set -e

  case "$verification_status" in
    0)
      if [[ "$activation_mode" == idle ]]; then
        set +e
        "$idle_origin_verifier" "$log_path" >/dev/null 2>&1
        idle_origin_status=$?
        set -e
        case "$idle_origin_status" in
          0)
            "$idle_origin_verifier" "$log_path"
            ;;
          1)
            sleep 0.1
            continue
            ;;
          *)
            "$idle_origin_verifier" "$log_path" || true
            tail -80 "$log_path" >&2
            fail "the observed extension lifecycle was not started by the configured idle timer"
            ;;
        esac
      fi

      "$log_verifier" "$log_path" false
      extension_pid="$(latest_extension_pid)"
      [[ "$extension_pid" =~ ^[1-9][0-9]*$ ]] || fail "could not identify the initialized extension process"

      echo "WAIT: proving ${minimum_sustain_seconds}s of continuous modern-extension animation."
      sustain_deadline=$((SECONDS + minimum_sustain_seconds))
      while ((SECONDS < sustain_deadline)); do
        capture_host_log

        set +e
        "$log_verifier" "$log_path" false >/dev/null 2>&1
        sustained_log_status=$?
        set -e
        if ((sustained_log_status == 2)); then
          "$log_verifier" "$log_path" false || true
          tail -80 "$log_path" >&2
          fail "the physical host entered module fallback or reported a fatal lifecycle error"
        fi

        if animation_stopped_after_latest_start "$extension_pid"; then
          tail -80 "$log_path" >&2
          fail "the extension stopped before the sustained-animation gate completed"
        fi

        if ! /bin/ps -p "$extension_pid" -o comm= >/dev/null 2>&1; then
          if display_sleep_observed "$extension_pid"; then
            fail "the display slept before the sustained-animation gate completed; this is power teardown, not normal invalidation"
          fi
          fail "the initialized modern extension process exited before the sustained-animation gate completed"
        fi

        selection_is_current ||
          fail "selection changed while the screen saver was running"

        sleep 0.5
      done

      capture_host_log
      animation_stopped_after_latest_start "$extension_pid" &&
        fail "the extension stopped before the sustained-animation gate completed"
      selection_is_current || fail "selection changed while the screen saver was running"

      if ((invalidation_timeout_seconds == 0)); then
        stop_log_stream
        echo "PASS: $extension_id sustained a physical $activation_mode full-screen modern-extension lifecycle for at least ${minimum_sustain_seconds}s."
        echo "NOTE: unlock the Mac normally to end the screen saver session."
        echo "Evidence: $artifact_root"
        exit 0
      fi

      echo "WAIT: unlock the Mac normally to prove extension invalidation."
      invalidation_deadline=$((SECONDS + invalidation_timeout_seconds))
      while ((SECONDS < invalidation_deadline)); do
        capture_host_log

        set +e
        "$cycle_log_verifier" "$log_path" false "$minimum_sustain_seconds" >/dev/null 2>&1
        cycle_status=$?
        set -e

        case "$cycle_status" in
          0)
            lock_state="$(current_lock_state)" || fail "could not read the console-session lock state after invalidation"
            if [[ "$lock_state" == false ]] &&
               ! pgrep -x ScreenSaverEngine >/dev/null &&
               ! /bin/ps -p "$extension_pid" -o comm= >/dev/null 2>&1; then
              selection_is_current || fail "selection changed while the screen saver was running"
              stop_log_stream
              "$cycle_log_verifier" "$log_path" false "$minimum_sustain_seconds"
              echo "PASS: $extension_id completed and invalidated a physical $activation_mode full-screen host lifecycle."
              echo "Evidence: $artifact_root"
              exit 0
            fi
            ;;
          2)
            "$cycle_log_verifier" "$log_path" false || true
            tail -80 "$log_path" >&2
            fail "the physical host reported a fatal extension lifecycle error during invalidation"
            ;;
        esac

        sleep 0.5
      done

      tail -80 "$log_path" >&2
      if display_sleep_observed "$extension_pid"; then
        fail "the display slept before normal unlock; ordered unlock invalidation remains incomplete"
      fi
      fail "timed out waiting for animation stop, host exit, and normal console unlock"
      ;;
    2)
      "$log_verifier" "$log_path" false || true
      tail -80 "$log_path" >&2
      fail "the physical host reported a fatal extension lifecycle error"
      ;;
  esac

  sleep 0.5
done

tail -80 "$log_path" >&2
fail "timed out waiting for extension initialization, view loading, and animation"
