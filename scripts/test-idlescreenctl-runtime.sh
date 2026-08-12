#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch_root="$(mktemp -d /tmp/idlescreenctl-runtime.XXXXXX)"
trap '/bin/rm -rf "$scratch_root"' EXIT

derived_data="$scratch_root/DerivedData"
container_root="$scratch_root/container"
build_log="$scratch_root/build.log"
stdout_file="$scratch_root/stdout"
stderr_file="$scratch_root/stderr"
test_group="group.com.idlescreen.tests.scratch"

/bin/mkdir -p "$container_root"
/usr/bin/xcodebuild \
  -project "$project_root/IdleScreen.xcodeproj" \
  -scheme IdleScreenCtl \
  -configuration Debug \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) IDLESCREEN_CTL_SCRATCH_GATE' \
  build >"$build_log"

control_tool="$derived_data/Build/Products/Debug/idlescreenctl"
[[ -x "$control_tool" ]] || {
  echo "FAIL: Debug idlescreenctl was not built" >&2
  exit 1
}

/usr/bin/xcodebuild \
  -project "$project_root/IdleScreen.xcodeproj" \
  -scheme IdleScreenCtl \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) IDLESCREEN_CTL_SCRATCH_GATE' \
  build >>"$build_log"

release_control_tool="$derived_data/Build/Products/Release/idlescreenctl"
[[ -x "$release_control_tool" ]] || {
  echo "FAIL: Release idlescreenctl was not built" >&2
  exit 1
}
if /usr/bin/strings "$release_control_tool" | /usr/bin/grep -Eq \
  'IDLESCREEN_CTL_SCRATCH_ROOT|group\.com\.idlescreen\.tests\.scratch'; then
  echo "FAIL: Release idlescreenctl contains the scratch-container gate" >&2
  exit 1
fi
set +e
IDLESCREEN_CTL_SCRATCH_ROOT="$container_root" \
  "$release_control_tool" status --provider codex --session release \
    --state done --app-group "$test_group" >"$stdout_file" 2>"$stderr_file"
release_status=$?
set -e
[[ "$release_status" -eq 69 ]] || {
  echo "FAIL: Release idlescreenctl exposed the scratch-container gate" >&2
  exit 1
}

expect_exit() {
  local expected="$1"
  local input="$2"
  shift 2
  local actual

  set +e
  if [[ "$input" == /dev/null ]]; then
    IDLESCREEN_CTL_SCRATCH_ROOT="$container_root" \
      "$control_tool" "$@" >"$stdout_file" 2>"$stderr_file"
  else
    IDLESCREEN_CTL_SCRATCH_ROOT="$container_root" \
      "$control_tool" "$@" <"$input" >"$stdout_file" 2>"$stderr_file"
  fi
  actual=$?
  set -e
  [[ "$actual" -eq "$expected" ]] || {
    echo "FAIL: idlescreenctl returned $actual, expected $expected: $*" >&2
    /bin/cat "$stderr_file" >&2
    exit 1
  }
}

expect_exit 64 /dev/null status --provider codex --session session --state working
expect_exit 69 /dev/null status --provider codex --session session --state working \
  --app-group group.com.example.unavailable

common_group=(--app-group "$test_group")
expect_exit 64 /dev/null status --provider codex --session session --state other \
  "${common_group[@]}"
expect_exit 64 /dev/null status --provider codex --session session --state done \
  --unknown value "${common_group[@]}"
expect_exit 64 /dev/null status --provider codex --session session --state done \
  "${common_group[@]}" --app-group "$test_group"

expect_exit 0 /dev/null status --provider codex --session codex-session --state working \
  --title '**Working**' --message $'safe\033[31m message' "${common_group[@]}"
expect_exit 0 /dev/null status --provider claude --session claude-session --state done \
  "${common_group[@]}"

inbox="$container_root/AgentSignals/inbox-v1.json"
[[ -f "$inbox" ]] || {
  echo "FAIL: real idlescreenctl did not create its scratch inbox" >&2
  exit 1
}
/usr/bin/grep -Fq 'codex-session' "$inbox" || {
  echo "FAIL: status did not persist the Codex session" >&2
  exit 1
}
/usr/bin/grep -Fq 'claude-session' "$inbox" || {
  echo "FAIL: status did not persist the Claude session" >&2
  exit 1
}
if /usr/bin/grep -Fq $'\033' "$inbox"; then
  echo "FAIL: status retained an escape sequence" >&2
  exit 1
fi

expect_exit 0 /dev/null clear --provider codex --session codex-session \
  "${common_group[@]}"
signals_json="$scratch_root/signals.json"
/usr/bin/plutil -extract signals json -o "$signals_json" "$inbox"
if /usr/bin/grep -Fq 'codex-session' "$signals_json"; then
  echo "FAIL: scoped clear retained the Codex session" >&2
  exit 1
fi
/usr/bin/grep -Fq 'claude-session' "$signals_json" || {
  echo "FAIL: scoped clear removed another provider session" >&2
  exit 1
}

expect_exit 0 /dev/null clear-all "${common_group[@]}"
/usr/bin/plutil -extract signals json -o "$signals_json" "$inbox"
/usr/bin/grep -Fqx '[]' "$signals_json" || {
  echo "FAIL: clear-all did not empty the inbox" >&2
  exit 1
}

/bin/cat >"$container_root/configuration.json" <<'JSON'
{
  "schemaVersion": 9,
  "revision": 1,
  "modifiedAt": "2026-08-11T12:00:00Z",
  "source": "generative",
  "appearance": {"glyphScale": 0.38, "contrast": 0.58, "palette": "Ember"},
  "agentIntegration": {
    "codexEnabled": true,
    "claudeEnabled": false,
    "messageTimeout": 120,
    "displayDestination": "primary",
    "overlayPosition": "topTrailing",
    "showsProviderLabel": true,
    "showsMessage": true,
    "stateVisuals": {
      "working": "active",
      "needsAttention": "attention",
      "done": "success",
      "error": "failure"
    }
  }
}
JSON

malformed_input="$scratch_root/malformed.json"
boundary_input="$scratch_root/boundary.json"
oversized_input="$scratch_root/oversized.json"
valid_input="$scratch_root/valid.json"
/usr/bin/printf 'not-json' >"$malformed_input"
/usr/bin/printf '%s' \
  '{"hook_event_name":"PermissionRequest","session_id":"runtime-boundary","padding":"' \
  >"$boundary_input"
boundary_padding_count=$((65536 - $(/usr/bin/stat -f '%z' "$boundary_input") - 2))
/usr/bin/head -c "$boundary_padding_count" /dev/zero | /usr/bin/tr '\0' a \
  >>"$boundary_input"
/usr/bin/printf '"}' >>"$boundary_input"
/usr/bin/yes a | /usr/bin/head -c 65537 >"$oversized_input" || true
/usr/bin/printf '%s' \
  '{"hook_event_name":"PermissionRequest","session_id":"runtime-hook","turn_id":"turn-1","tool_input":"private runtime payload"}' \
  >"$valid_input"

expect_exit 65 "$malformed_input" hook --provider codex "${common_group[@]}"
expect_exit 64 "$valid_input" hook --provider codex --installation other \
  "${common_group[@]}"
expect_exit 0 "$boundary_input" hook --provider codex \
  --installation idlescreen-v1 "${common_group[@]}"
expect_exit 65 "$oversized_input" hook --provider codex "${common_group[@]}"
expect_exit 0 "$valid_input" hook --provider codex \
  --installation idlescreen-v1 "${common_group[@]}"
/usr/bin/grep -Fq 'runtime-hook' "$inbox" || {
  echo "FAIL: valid hook input did not reach the scratch inbox" >&2
  exit 1
}
if /usr/bin/grep -Fq 'private runtime payload' "$inbox"; then
  echo "FAIL: hook input retained a private payload field" >&2
  exit 1
fi

/bin/rm -rf "$container_root/AgentSignals"
/usr/bin/printf 'not-a-directory' >"$container_root/AgentSignals"
expect_exit 74 /dev/null status --provider codex --session storage-failure --state done \
  "${common_group[@]}"

echo "PASS: real idlescreenctl enforces its command matrix through a Debug-only scratch container gate."
