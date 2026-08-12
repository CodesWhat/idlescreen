#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/app-group-container app-bundle-id extension-bundle-id" >&2
  exit 64
}

[[ $# -eq 3 ]] || usage

container_root="$1"
expected_app_id="$2"
expected_extension_id="$3"

[[ "$container_root" = /* ]] || usage

configuration_path="$container_root/configuration.json"
health_directory="$container_root/Health"

if [[ ! -f "$configuration_path" || ! -d "$health_directory" ]]; then
  echo "WAIT: shared configuration or health evidence is missing." >&2
  exit 1
fi

shopt -s nullglob
health_paths=("$health_directory"/*.json)
shopt -u nullglob
if ((${#health_paths[@]} == 0)); then
  echo "WAIT: shared process-health evidence is missing." >&2
  exit 1
fi

read_required_value() {
  local path="$1"
  local key="$2"
  local value
  if ! value="$(plutil -extract "$key" raw "$path" 2>/dev/null)"; then
    echo "FAIL: $path is missing required field $key." >&2
    exit 2
  fi
  printf '%s\n' "$value"
}

configuration_schema="$(read_required_value "$configuration_path" schemaVersion)"
configuration_revision="$(read_required_value "$configuration_path" revision)"
configuration_modified_at="$(read_required_value "$configuration_path" modifiedAt)"

if [[ ! "$configuration_schema" =~ ^[0-9]+$ ]] || ((configuration_schema > 1)); then
  echo "FAIL: shared configuration uses unsupported schema $configuration_schema." >&2
  exit 2
fi

if [[ ! "$configuration_revision" =~ ^[0-9]+$ ]] || ((configuration_revision == 0)); then
  echo "WAIT: change a Release setting before claiming live cross-process delivery." >&2
  exit 1
fi

app_process_identifier=""
extension_process_identifier=""
extension_instance_identifier=""
extension_display_identifier=""

for health_path in "${health_paths[@]}"; do
  report_schema="$(read_required_value "$health_path" schemaVersion)"
  if [[ ! "$report_schema" =~ ^[0-9]+$ ]] || ((report_schema > 2)); then
    echo "FAIL: $health_path uses unsupported schema $report_schema." >&2
    exit 2
  fi

  report_process="$(read_required_value "$health_path" process)"
  case "$report_process" in
    companionApp)
      expected_bundle_id="$expected_app_id"
      expected_executable_name="IdleScreen"
      ;;
    screenSaverExtension)
      expected_bundle_id="$expected_extension_id"
      expected_executable_name="IdleScreenScreenSaver"
      ;;
    *)
      continue
      ;;
  esac

  report_bundle_id="$(read_required_value "$health_path" build.bundleIdentifier)"
  if [[ "$report_bundle_id" != "$expected_bundle_id" ]]; then
    echo "FAIL: $health_path belongs to $report_process/$report_bundle_id." >&2
    exit 2
  fi

  report_process_identifier="$(plutil -extract processIdentifier raw "$health_path" 2>/dev/null || true)"
  report_revision="$(plutil -extract configurationRevision raw "$health_path" 2>/dev/null || true)"
  report_lifecycle="$(read_required_value "$health_path" lifecycle)"
  report_updated_at="$(read_required_value "$health_path" updatedAt)"

  [[ "$report_process_identifier" =~ ^[1-9][0-9]*$ ]] || continue
  /bin/ps -p "$report_process_identifier" -o comm= >/dev/null 2>&1 || continue
  process_started_at="$(
    LC_ALL=C /bin/ps -p "$report_process_identifier" -o lstart= |
      sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
  )"
  normalized_report_updated_at="$(sed -E 's/\.[0-9]+Z$/Z/' <<<"$report_updated_at")"
  process_started_epoch="$(
    LC_ALL=C /bin/date -j -f '%a %b %e %T %Y' "$process_started_at" '+%s' 2>/dev/null || true
  )"
  report_updated_epoch="$(
    /bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$normalized_report_updated_at" '+%s' 2>/dev/null || true
  )"
  if [[ -z "$process_started_epoch" || -z "$report_updated_epoch" ]]; then
    echo "FAIL: $health_path or PID $report_process_identifier has an unparseable lifetime timestamp." >&2
    exit 2
  fi
  ((report_updated_epoch + 1 >= process_started_epoch)) || continue
  report_executable_path="$(/bin/ps -ww -p "$report_process_identifier" -o comm=)"
  if [[ "${report_executable_path##*/}" != "$expected_executable_name" ]]; then
    echo "FAIL: $health_path claims live $report_process health, but PID $report_process_identifier runs $report_executable_path (wrong executable identity)." >&2
    exit 2
  fi
  [[ "$report_revision" == "$configuration_revision" ]] || continue
  [[ "$report_updated_at" < "$configuration_modified_at" ]] && continue

  case "$report_process" in
    companionApp)
      [[ "$report_lifecycle" == attached ]] || continue
      app_process_identifier="$report_process_identifier"
      ;;
    screenSaverExtension)
      [[ "$report_lifecycle" == animating ]] || continue
      extension_process_identifier="$report_process_identifier"
      extension_instance_identifier="$(plutil -extract instanceIdentifier raw "$health_path" 2>/dev/null || true)"
      extension_display_identifier="$(plutil -extract displayIdentifier raw "$health_path" 2>/dev/null || true)"
      ;;
  esac
done

if [[ -z "$app_process_identifier" || -z "$extension_process_identifier" ]]; then
  echo "WAIT: configuration r$configuration_revision is not active in both live processes." >&2
  exit 1
fi
if [[ "$app_process_identifier" == "$extension_process_identifier" ]]; then
  echo "FAIL: companion and extension health report the same process identifier." >&2
  exit 2
fi

extension_detail="extension pid=$extension_process_identifier"
[[ -z "$extension_instance_identifier" ]] || extension_detail+=" instance=$extension_instance_identifier"
[[ -z "$extension_display_identifier" ]] || extension_detail+=" display=$extension_display_identifier"
echo "PASS: live companion pid=$app_process_identifier and $extension_detail both report configuration r$configuration_revision."
