#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
verifier="$project_root/scripts/verify-shared-state.sh"
fixture_root="$(mktemp -d /tmp/idlescreen-shared-state-tests.XXXXXX)"
mkdir -p "$fixture_root/bin"
/bin/ln -s /bin/sleep "$fixture_root/bin/IdleScreen"
/bin/ln -s /bin/sleep "$fixture_root/bin/IdleScreenScreenSaver"
"$fixture_root/bin/IdleScreen" 60 &
app_fixture_pid=$!
"$fixture_root/bin/IdleScreenScreenSaver" 60 &
extension_fixture_pid=$!
/bin/sleep 60 &
wrong_executable_pid=$!
fixture_timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

cleanup() {
  kill "$app_fixture_pid" "$extension_fixture_pid" "$wrong_executable_pid" >/dev/null 2>&1 || true
  wait "$app_fixture_pid" "$extension_fixture_pid" "$wrong_executable_pid" >/dev/null 2>&1 || true
  rm -rf "$fixture_root"
}

trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_verifier() {
  local root="$1"
  set +e
  "$verifier" \
    "$root" \
    com.idlescreen.app \
    com.idlescreen.app.screensaver \
    >/dev/null 2>&1
  local verifier_status=$?
  set -e
  return "$verifier_status"
}

[[ -x "$verifier" ]] || fail "missing executable shared-state verifier"

success_root="$fixture_root/success"
mkdir -p "$success_root/Health"
printf '%s\n' \
  '{' \
  '  "schemaVersion": 1,' \
  '  "revision": 12,' \
  "  \"modifiedAt\": \"$fixture_timestamp\"," \
  '  "source": "generative",' \
  '  "appearance": {"glyphScale": 0.5, "contrast": 0.6, "palette": "Ember"}' \
  '}' >"$success_root/configuration.json"
printf '%s\n' \
  '{' \
  '  "schemaVersion": 1,' \
  '  "process": "companionApp",' \
  "  \"processIdentifier\": $app_fixture_pid," \
  '  "lifecycle": "attached",' \
  '  "build": {"version": "0.1", "buildNumber": "1", "bundleIdentifier": "com.idlescreen.app"},' \
  "  \"updatedAt\": \"$fixture_timestamp\"," \
  '  "configurationRevision": 12' \
  '}' >"$success_root/Health/companionApp-$app_fixture_pid.json"
printf '%s\n' \
  '{' \
  '  "schemaVersion": 2,' \
  '  "process": "screenSaverExtension",' \
  "  \"processIdentifier\": $extension_fixture_pid," \
  '  "instanceIdentifier": "view-a",' \
  '  "displayIdentifier": 2,' \
  '  "lifecycle": "animating",' \
  '  "build": {"version": "0.1", "buildNumber": "1", "bundleIdentifier": "com.idlescreen.app.screensaver"},' \
  "  \"updatedAt\": \"$fixture_timestamp\"," \
  '  "configurationRevision": 12' \
  '}' >"$success_root/Health/screenSaverExtension-$extension_fixture_pid.json"

printf '%s\n' \
  '{' \
  '  "schemaVersion": 1,' \
  '  "process": "screenSaverExtension",' \
  '  "processIdentifier": 999999,' \
  '  "lifecycle": "detached",' \
  '  "build": {"version": "0.1", "buildNumber": "1", "bundleIdentifier": "com.idlescreen.app.screensaver"},' \
  "  \"updatedAt\": \"$fixture_timestamp\"," \
  '  "configurationRevision": 12' \
  '}' >"$success_root/Health/screenSaverExtension-999999.json"

success_output="$(
  "$verifier" \
    "$success_root" \
    com.idlescreen.app \
    com.idlescreen.app.screensaver
)" || fail "matching live shared state was rejected"
grep -Fq 'instance=view-a display=2' <<<"$success_output" ||
  fail "live shared state did not identify the hosted view and display"

stale_root="$fixture_root/stale"
cp -R "$success_root" "$stale_root"
plutil -replace configurationRevision -integer 11 "$stale_root/Health/screenSaverExtension-$extension_fixture_pid.json"
if run_verifier "$stale_root"; then
  fail "a stale extension configuration revision was accepted"
else
  [[ "$?" -eq 1 ]] || fail "stale revision must be incomplete, not fatal"
fi

dead_process_root="$fixture_root/dead-process"
cp -R "$success_root" "$dead_process_root"
plutil -replace processIdentifier -integer 999998 "$dead_process_root/Health/screenSaverExtension-$extension_fixture_pid.json"
if run_verifier "$dead_process_root"; then
  fail "health from an exited extension process was accepted"
else
  [[ "$?" -eq 1 ]] || fail "an exited extension process must be incomplete, not fatal"
fi

default_revision_root="$fixture_root/default-revision"
cp -R "$success_root" "$default_revision_root"
plutil -replace revision -integer 0 "$default_revision_root/configuration.json"
plutil -replace modifiedAt -string '0001-01-01T00:00:00Z' "$default_revision_root/configuration.json"
plutil -replace configurationRevision -integer 0 "$default_revision_root/Health/companionApp-$app_fixture_pid.json"
plutil -replace configurationRevision -integer 0 "$default_revision_root/Health/screenSaverExtension-$extension_fixture_pid.json"
if run_verifier "$default_revision_root"; then
  fail "untouched default configuration was accepted as live delivery evidence"
else
  [[ "$?" -eq 1 ]] || fail "default configuration must be incomplete, not fatal"
fi

wrong_process_root="$fixture_root/wrong-process"
cp -R "$success_root" "$wrong_process_root"
plutil -replace build.bundleIdentifier -string com.example.other "$wrong_process_root/Health/screenSaverExtension-$extension_fixture_pid.json"
if run_verifier "$wrong_process_root"; then
  fail "health from a different extension bundle was accepted"
else
  [[ "$?" -eq 2 ]] || fail "wrong process identity must be fatal"
fi

wrong_executable_root="$fixture_root/wrong-executable"
cp -R "$success_root" "$wrong_executable_root"
plutil -replace processIdentifier -integer "$wrong_executable_pid" "$wrong_executable_root/Health/screenSaverExtension-$extension_fixture_pid.json"
if run_verifier "$wrong_executable_root"; then
  fail "health pointing at an unrelated live executable was accepted"
else
  [[ "$?" -eq 2 ]] || fail "wrong executable identity must be fatal"
fi

reused_pid_root="$fixture_root/reused-pid"
cp -R "$success_root" "$reused_pid_root"
plutil -replace modifiedAt -string '1999-12-31T23:59:59Z' "$reused_pid_root/configuration.json"
plutil -replace updatedAt -string '2000-01-01T00:00:00Z' "$reused_pid_root/Health/screenSaverExtension-$extension_fixture_pid.json"
if run_verifier "$reused_pid_root"; then
  fail "health predating the current extension process lifetime was accepted"
else
  [[ "$?" -eq 1 ]] || fail "reused-PID health must be incomplete, not fatal"
fi

stale_wrong_executable_root="$fixture_root/stale-wrong-executable"
cp -R "$reused_pid_root" "$stale_wrong_executable_root"
plutil -replace processIdentifier -integer "$wrong_executable_pid" "$stale_wrong_executable_root/Health/screenSaverExtension-$extension_fixture_pid.json"
if run_verifier "$stale_wrong_executable_root"; then
  fail "stale health assigned to a reused unrelated PID was accepted"
else
  [[ "$?" -eq 1 ]] || fail "stale wrong-executable health must be ignored as incomplete"
fi

echo "PASS: shared-state evidence distinguishes synchronized, stale, and wrong-process reports."
