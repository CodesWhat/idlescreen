#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
verifier="$project_root/scripts/verify-idle-activation-log.sh"
fixture_root="$(mktemp -d /tmp/idlescreen-idle-origin-tests.XXXXXX)"
trap 'rm -rf "$fixture_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

write_extension_start() {
  local destination="$1"
  printf '%s\n' \
    '2026-08-01 08:22:15.164 I  IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:Extension] Extension initialized pid=2042 compatible=true' \
    '2026-08-01 08:22:15.169 I  IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:ViewController] Loading view width=1920.000000 height=1080.000000 preview=false' \
    '2026-08-01 08:22:15.199 I  IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Animation started preview=false' \
    >>"$destination"
}

run_verifier() {
  local fixture="$1"

  set +e
  "$verifier" "$fixture" >/dev/null 2>&1
  verifier_status=$?
  set -e
}

[[ -x "$verifier" ]] || fail "missing executable idle-origin verifier"

natural="$fixture_root/natural.log"
printf '%s\n' \
  '2026-08-01 08:22:14.918 Df loginwindow[427:1696912] [com.apple.loginwindow.logging:Standard] -[LWScreenLock startScreenLock:] | entered kLWLockFromScreenSaverIdleLaunch (3)' \
  >"$natural"
write_extension_start "$natural"
run_verifier "$natural"
[[ "$verifier_status" -eq 0 ]] || fail "a true Tahoe idle-timer launch was rejected"

external="$fixture_root/external.log"
printf '%s\n' \
  '2026-08-01 08:22:14.918 Df loginwindow[427:1696912] [com.apple.loginwindow.logging:Standard] -[LWScreenLock startScreenLock:] | entered kLWLockFromScreenSaverOtherLaunch (4)' \
  >"$external"
write_extension_start "$external"
run_verifier "$external"
[[ "$verifier_status" -eq 2 ]] || fail "an external LaunchServices start must be fatal idle evidence"

hot_corner="$fixture_root/hot-corner.log"
printf '%s\n' \
  '2026-08-01 08:22:14.918 Df loginwindow[427:1696912] [com.apple.loginwindow.logging:Standard] -[LWScreenLock startScreenLock:] | entered kLWLockFromScreenSaverHotCornerActivation (2)' \
  >"$hot_corner"
write_extension_start "$hot_corner"
run_verifier "$hot_corner"
[[ "$verifier_status" -eq 2 ]] || fail "a Hot Corner start must be fatal idle evidence"

unclassified="$fixture_root/unclassified.log"
write_extension_start "$unclassified"
run_verifier "$unclassified"
[[ "$verifier_status" -eq 1 ]] || fail "a lifecycle without launch-origin evidence must remain incomplete"

stale_idle="$fixture_root/stale-idle.log"
printf '%s\n' \
  '2026-08-01 08:21:00.000 Df loginwindow[427:1696912] [com.apple.loginwindow.logging:Standard] -[LWScreenLock startScreenLock:] | entered kLWLockFromScreenSaverIdleLaunch (3)' \
  '2026-08-01 08:22:14.918 Df loginwindow[427:1696912] [com.apple.loginwindow.logging:Standard] -[LWScreenLock startScreenLock:] | entered kLWLockFromScreenSaverOtherLaunch (4)' \
  >"$stale_idle"
write_extension_start "$stale_idle"
run_verifier "$stale_idle"
[[ "$verifier_status" -eq 2 ]] || fail "stale idle evidence must not mask a later external start"

echo "PASS: Tahoe idle-timer launches are distinguished from manual, Hot Corner, and unclassified starts."
