#!/bin/bash

set -euo pipefail

R1_TASK_DERIVED_DATA=""
R1_TASK_CAFFEINATE_PID=""

r1_error() {
  echo "FAIL: $*" >&2
  return 1
}

r1_cleanup() {
  if [[ -n "${R1_TASK_CAFFEINATE_PID:-}" ]]; then
    /bin/kill -TERM "$R1_TASK_CAFFEINATE_PID" 2>/dev/null || true
    wait "$R1_TASK_CAFFEINATE_PID" 2>/dev/null || true
    R1_TASK_CAFFEINATE_PID=""
  fi
  if [[ "${R1_TASK_DERIVED_DATA:-}" == /private/tmp/idlescreen-r1-derived.* &&
        -d "$R1_TASK_DERIVED_DATA" ]]; then
    /bin/rm -rf -- "$R1_TASK_DERIVED_DATA"
  fi
  R1_TASK_DERIVED_DATA=""
}

r1_sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'
}

r1_validate_mode_duration() {
  local mode="$1"
  local duration="$2"
  [[ "$duration" =~ ^[1-9][0-9]*$ ]] ||
    r1_error "R1.1 duration must be a positive whole number of seconds." || return
  case "$mode" in
    gating)
      [[ "$duration" == 900 ]] ||
        r1_error "gating mode requires exactly 900 seconds per duration workload." || return
      ;;
    smoke)
      ((duration >= 10 && duration < 900)) ||
        r1_error "smoke mode requires 10-899 seconds for reliable Energy coverage." || return
      ;;
    *)
      r1_error "R1.1 mode must be exactly gating or smoke." || return
      ;;
  esac
}

r1_validate_display_budget() {
  local display="$1"
  local budgets="$2"
  [[ -f "$display" && ! -L "$display" && -f "$budgets" && ! -L "$budgets" ]] ||
    r1_error "display and budget inputs must be regular files" || return
  /usr/bin/jq -e --slurpfile budgets "$budgets" '
    .count == $budgets[0].displayCount
    and .pixelWidth == $budgets[0].displayPixelWidth
    and .pixelHeight == $budgets[0].displayPixelHeight
    and .scale == $budgets[0].displayScale
  ' "$display" >/dev/null ||
    r1_error "actual display does not match the immutable budget surface"
}

r1_canonicalize_preflight() {
  local input="$1"
  local output="$2"
  /usr/bin/jq -eS '
    def positive_integer: type == "number" and . > 0 and . == floor;
    def positive_number: type == "number" and . > 0;
    def sha256: type == "string" and test("^[0-9a-f]{64}$");
    def iso8601utc:
      type == "string"
      and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    def safe_relative_path:
      type == "string"
      and length > 0
      and startswith("/") == false
      and (split("/") | all(. != "" and . != "." and . != ".."));
    def exact_keys($expected): (keys | sort) == ($expected | sort);
    if
      exact_keys([
        "artifactBuiltAt", "artifactManifestSHA256", "budgetsSHA256",
        "capturedAt", "coldStartupSampleCount", "display",
        "energySamplingIntervalSeconds", "environmentInputPaths", "hardware",
        "mode", "operatingSystem", "powerSource", "requiredDurationSeconds",
        "runIdentifier", "schemaVersion", "sourceIdentity", "targetFramesPerSecond",
        "targetSurface", "toolchain", "warmStartupSampleCount", "workloads"
      ])
      and .schemaVersion == 1
      and (.runIdentifier | type == "string" and length > 0)
      and (.capturedAt | iso8601utc)
      and (.artifactBuiltAt | iso8601utc)
      and ((.artifactBuiltAt | fromdateiso8601) <= (.capturedAt | fromdateiso8601))
      and (.mode == "gating" or .mode == "smoke")
      and (.requiredDurationSeconds | positive_integer)
      and (
        (.mode == "gating" and .requiredDurationSeconds == 900)
        or (.mode == "smoke" and .requiredDurationSeconds >= 5 and .requiredDurationSeconds < 900)
      )
      and .coldStartupSampleCount == 5
      and .warmStartupSampleCount == 5
      and (.energySamplingIntervalSeconds | positive_number)
      and (.sourceIdentity | exact_keys(["commit", "diffSHA256", "dirtyPathCount"]))
      and (.sourceIdentity.commit | type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$"))
      and (.sourceIdentity.diffSHA256 | sha256)
      and (.sourceIdentity.dirtyPathCount | type == "number" and . >= 0 and . == floor)
      and (.toolchain | exact_keys(["swiftVersion", "xcodeVersion", "xcodegenVersion"]))
      and ([.toolchain[]] | all(type == "string" and length > 0))
      and (.operatingSystem | exact_keys(["build", "version"]))
      and ([.operatingSystem[]] | all(type == "string" and length > 0))
      and (.hardware | exact_keys([
        "chip", "cpuCoreCount", "gpuCoreCount", "hardwareClass",
        "memoryBytes", "modelIdentifier"
      ]))
      and (.hardware.modelIdentifier | type == "string" and length > 0)
      and (.hardware.hardwareClass | type == "string" and length > 0)
      and (.hardware.chip | type == "string" and length > 0)
      and (.hardware.cpuCoreCount | positive_integer)
      and (.hardware.gpuCoreCount | positive_integer)
      and (.hardware.memoryBytes | positive_integer)
      and (.display | exact_keys([
        "count", "logicalHeight", "logicalWidth", "pixelHeight", "pixelWidth",
        "refreshRateHertz", "scale"
      ]))
      and (.display.count | positive_integer)
      and (.display.logicalWidth | positive_integer)
      and (.display.logicalHeight | positive_integer)
      and (.display.pixelWidth | positive_integer)
      and (.display.pixelHeight | positive_integer)
      and (.display.scale | positive_number)
      and (.display.refreshRateHertz | positive_number)
      and (.targetFramesPerSecond | positive_integer)
      and (.targetSurface | exact_keys([
        "logicalHeight", "logicalWidth", "pixelHeight", "pixelWidth"
      ]))
      and (.targetSurface.logicalWidth == .display.logicalWidth)
      and (.targetSurface.logicalHeight == .display.logicalHeight)
      and (.targetSurface.pixelWidth == .display.pixelWidth)
      and (.targetSurface.pixelHeight == .display.pixelHeight)
      and .powerSource == "AC Power"
      and (.artifactManifestSHA256 | sha256)
      and (.budgetsSHA256 | sha256)
      and (.workloads | type == "array" and length > 0)
      and ([.workloads[].workload] | unique | length) == (.workloads | length)
      and ([.workloads[] | (
        exact_keys([
          "durationSeconds", "energyPath", "iterationsPerResult", "resultPaths",
          "workload"
        ])
        and (.workload | type == "string" and length > 0)
        and (.resultPaths | type == "array" and length > 0 and all(safe_relative_path))
        and (
          .iterationsPerResult == null
          or (.iterationsPerResult | positive_integer)
        )
        and (
          .durationSeconds == null
          or (.durationSeconds | positive_integer)
        )
        and (
          .energyPath == null
          or (.energyPath | safe_relative_path)
        )
      )] | all)
      and (.environmentInputPaths | type == "array" and length > 0 and all(safe_relative_path))
      and (.environmentInputPaths == (.environmentInputPaths | unique | sort))
    then .
    else error("invalid R1.1 preflight manifest")
    end
  ' "$input" >"$output"
}

r1_install_or_compare_preflight() {
  local candidate="$1"
  local preserved="$2"
  local resume="$3"
  [[ "$resume" == 0 || "$resume" == 1 ]] ||
    r1_error "resume mode must be 0 or 1" || return
  if [[ "$resume" == 1 ]]; then
    [[ -f "$preserved" && ! -L "$preserved" ]] ||
      r1_error "resume requires an intact preflight-manifest.json" || return
    /usr/bin/cmp -s "$candidate" "$preserved" ||
      r1_error "resume preflight differs from the immutable original run" || return
    return 0
  fi
  [[ ! -e "$preserved" ]] ||
    r1_error "new run refuses to replace an existing preflight manifest" || return
  /bin/mkdir -p "$(/usr/bin/dirname "$preserved")"
  /bin/cp "$candidate" "$preserved"
}

r1_write_evidence_manifest() {
  local root="$1"
  local inventory="$2"
  local output="$3"
  local run_identifier="$4"
  local entries_json
  local sorted_inventory
  local kind path leaf hash byte_count
  local previous_path=""

  [[ -d "$root" && ! -L "$root" ]] ||
    r1_error "evidence root must be a real directory" || return
  [[ -f "$inventory" && ! -L "$inventory" ]] ||
    r1_error "evidence inventory must be a regular file" || return
  [[ -n "$run_identifier" ]] || r1_error "missing evidence run identifier" || return

  sorted_inventory="$(mktemp /tmp/idlescreen-r1-inventory.XXXXXX)"
  entries_json="$(mktemp /tmp/idlescreen-r1-entries.XXXXXX)"
  LC_ALL=C /usr/bin/sort -t $'\t' -k2,2 "$inventory" >"$sorted_inventory"
  : >"$entries_json"
  while IFS=$'\t' read -r kind path extra; do
    [[ -n "$kind" && -n "$path" && -z "${extra:-}" ]] || {
      /bin/rm -f "$sorted_inventory" "$entries_json"
      r1_error "evidence inventory rows must be kind-tab-relative-path"
      return
    }
    case "$kind" in
      preflight|artifact|budgets|metadata|workload|energy|environment|helperIdentity) ;;
      *)
        /bin/rm -f "$sorted_inventory" "$entries_json"
        r1_error "unsupported evidence kind: $kind"
        return
        ;;
    esac
    case "$path" in
      ""|/*|.|..|../*|*/../*|*/..|./*|*/./*|*/.)
        /bin/rm -f "$sorted_inventory" "$entries_json"
        r1_error "unsafe evidence path: $path"
        return
        ;;
    esac
    [[ "$path" != "$previous_path" ]] || {
      /bin/rm -f "$sorted_inventory" "$entries_json"
      r1_error "duplicate evidence path: $path"
      return
    }
    previous_path="$path"
    leaf="$root/$path"
    [[ -f "$leaf" && ! -L "$leaf" ]] || {
      /bin/rm -f "$sorted_inventory" "$entries_json"
      r1_error "evidence input is missing, nonregular, or a symlink: $path"
      return
    }
    hash="$(r1_sha256_file "$leaf")"
    byte_count="$(/usr/bin/stat -f %z "$leaf")"
    /usr/bin/jq -cn \
      --arg path "$path" \
      --arg sha256 "$hash" \
      --arg kind "$kind" \
      --argjson byte_count "$byte_count" \
      '{path:$path,sha256:$sha256,byteCount:$byte_count,kind:$kind}' \
      >>"$entries_json"
  done <"$sorted_inventory"

  /usr/bin/jq -S -n \
    --arg run_identifier "$run_identifier" \
    --slurpfile entries "$entries_json" \
    '{schemaVersion:1,runIdentifier:$run_identifier,entries:$entries}' \
    >"$output"
  /bin/rm -f "$sorted_inventory" "$entries_json"
}

r1_validate_helper_identity_pair() {
  local start="$1"
  local end="$2"
  local projection='{
    launchdJob, pid, startIdentity, executablePath, executableSHA256,
    codesign, bundle
  }'
  [[ -f "$start" && ! -L "$start" && -f "$end" && ! -L "$end" ]] ||
    r1_error "helper identity inputs must be regular files" || return
  /usr/bin/jq -e '
    .schemaVersion == 1
    and (.capturedAt | type == "string" and length > 0)
    and (.launchdJob | type == "string" and length > 0)
    and (.launchdSnapshot | type == "string" and length > 0)
    and (.pid | type == "number" and . > 0 and . == floor)
    and (.startIdentity | type == "string" and length > 0)
    and (.executablePath | type == "string" and startswith("/"))
    and (.executableSHA256 | type == "string" and test("^[0-9a-f]{64}$"))
    and (.codesign | keys | sort) == ([
      "cdHash", "dynamicDetails", "identifier", "staticDetails", "teamIdentifier"
    ] | sort)
    and (.codesign.cdHash | type == "string" and test("^[0-9a-f]{40,64}$"))
    and (.codesign.identifier | type == "string" and length > 0)
    and (.codesign.teamIdentifier | type == "string" and length > 0)
    and (.codesign.staticDetails | type == "string" and length > 0)
    and (.codesign.dynamicDetails | type == "string" and length > 0)
    and (.bundle | keys | sort) == (["identifier", "shortVersion", "version"] | sort)
    and ([.bundle[]] | all(type == "string" and length > 0))
  ' "$start" >/dev/null || r1_error "invalid helper start identity" || return
  /usr/bin/jq -e '
    .schemaVersion == 1
    and (.capturedAt | type == "string" and length > 0)
    and (.launchdSnapshot | type == "string" and length > 0)
  ' "$end" >/dev/null || r1_error "invalid helper end identity" || return
  /usr/bin/cmp -s \
    <(/usr/bin/jq -S "$projection" "$start") \
    <(/usr/bin/jq -S "$projection" "$end") ||
    r1_error "existing helper identity changed inside the sampled window"
}

r1_iso8601_now() {
  /bin/date -u +%Y-%m-%dT%H:%M:%SZ
}

r1_resolve_evidence_directory() {
  local project_root="$1"
  local requested="$2"
  local candidate parent leaf resolved_parent
  [[ -n "$requested" && "$requested" != *$'\n'* ]] ||
    r1_error "evidence directory path is empty or malformed" || return
  if [[ "$requested" == /* ]]; then
    candidate="$requested"
  else
    candidate="$project_root/$requested"
  fi
  parent="$(/usr/bin/dirname "$candidate")"
  leaf="$(/usr/bin/basename "$candidate")"
  [[ "$leaf" != . && "$leaf" != .. && -d "$parent" ]] ||
    r1_error "evidence directory parent is unavailable" || return
  resolved_parent="$(cd "$parent" && /bin/pwd -P)"
  /usr/bin/printf '%s/%s\n' "$resolved_parent" "$leaf"
}

r1_install_or_compare_file() {
  local candidate="$1"
  local preserved="$2"
  local resume="$3"
  local label="$4"
  [[ -f "$candidate" && ! -L "$candidate" ]] ||
    r1_error "$label candidate is missing or nonregular" || return
  if [[ "$resume" == 1 ]]; then
    [[ -f "$preserved" && ! -L "$preserved" ]] ||
      r1_error "resume requires the preserved $label" || return
    /usr/bin/cmp -s "$candidate" "$preserved" ||
      r1_error "resume $label differs from the immutable original run" || return
  else
    [[ ! -e "$preserved" ]] ||
      r1_error "new run refuses to replace the existing $label" || return
    /bin/cp "$candidate" "$preserved"
  fi
}

r1_capture_power_source() {
  local output="$1"
  local raw
  raw="$(mktemp /tmp/idlescreen-r1-power.XXXXXX)"
  /usr/bin/pmset -g batt >"$raw"
  /usr/bin/grep -Fq "Now drawing from 'AC Power'" "$raw" || {
    /bin/rm -f "$raw"
    r1_error "R1.1 requires uninterrupted AC power" || return
  }
  /usr/bin/printf 'AC Power\n' >"$output"
  /bin/rm -f "$raw"
  /usr/bin/printf '%s\n' "AC Power"
}

r1_capture_source_identity() {
  local project_root="$1"
  local evidence_directory="$2"
  local snapshot_output="$3"
  local identity_output="$4"
  local closure_file status_file untracked_file evidence_relative=""
  local commit diff_sha dirty_count path
  local -a pathspecs=(-- .)

  case "$evidence_directory" in
    "$project_root"/*)
      evidence_relative="${evidence_directory#"$project_root"/}"
      pathspecs+=(":(exclude)$evidence_relative" ":(exclude)$evidence_relative/**")
      ;;
  esac
  closure_file="$(mktemp /tmp/idlescreen-r1-source-closure.XXXXXX)"
  status_file="$(mktemp /tmp/idlescreen-r1-source-status.XXXXXX)"
  untracked_file="$(mktemp /tmp/idlescreen-r1-untracked.XXXXXX)"
  commit="$(/usr/bin/git -C "$project_root" rev-parse HEAD)"
  /usr/bin/git -C "$project_root" status --porcelain=v1 \
    --untracked-files=all "${pathspecs[@]}" >"$status_file"
  dirty_count="$(/usr/bin/awk 'END { print NR + 0 }' "$status_file")"
  {
    /usr/bin/printf 'HEAD\t%s\n' "$commit"
    /usr/bin/git -C "$project_root" diff --binary --full-index HEAD \
      "${pathspecs[@]}"
    /usr/bin/git -C "$project_root" ls-files --others --exclude-standard -z \
      "${pathspecs[@]}" | LC_ALL=C /usr/bin/sort -z >"$untracked_file"
    while IFS= read -r -d '' path; do
      [[ -f "$project_root/$path" && ! -L "$project_root/$path" ]] || {
        /bin/rm -f "$closure_file" "$status_file" "$untracked_file"
        r1_error "untracked source input is missing, nonregular, or a symlink: $path"
        return
      }
      /usr/bin/printf 'UNTRACKED\t%s\t%s\n' \
        "$path" "$(r1_sha256_file "$project_root/$path")"
    done <"$untracked_file"
  } >"$closure_file"
  diff_sha="$(r1_sha256_file "$closure_file")"
  /usr/bin/jq -S -n \
    --arg commit "$commit" \
    --arg diff_sha "$diff_sha" \
    --argjson dirty_count "$dirty_count" \
    --rawfile status "$status_file" \
    '{commit:$commit,diffSHA256:$diff_sha,dirtyPathCount:$dirty_count,status:$status}' \
    >"$snapshot_output"
  /usr/bin/jq -S '{commit,diffSHA256,dirtyPathCount}' \
    "$snapshot_output" >"$identity_output"
  /bin/rm -f "$closure_file" "$status_file" "$untracked_file"
}

r1_assert_source_identity_unchanged() {
  local project_root="$1"
  local evidence_directory="$2"
  local expected_identity="$3"
  local snapshot_output="$4"
  local identity_output="$5"
  local label="$6"
  local diagnostic
  [[ "$label" =~ ^[a-zA-Z0-9-]+$ ]] ||
    r1_error "source diagnostic label is invalid" || return
  r1_capture_source_identity "$project_root" "$evidence_directory" \
    "$snapshot_output" "$identity_output"
  /usr/bin/cmp -s "$expected_identity" "$identity_output" && return 0
  diagnostic="$evidence_directory/source-status-failure-$label.json"
  if [[ -e "$diagnostic" ]]; then
    [[ -f "$diagnostic" && ! -L "$diagnostic" ]] ||
      r1_error "existing source mismatch diagnostic is nonregular" || return
    /usr/bin/cmp -s "$snapshot_output" "$diagnostic" ||
      r1_error "source mismatch diagnostic already exists with different evidence" || return
  else
    /bin/cp "$snapshot_output" "$diagnostic"
  fi
  r1_error "source identity changed during the run; diagnostic: $diagnostic"
}

r1_capture_host_environment() {
  local hardware_output="$1"
  local display_output="$2"
  local os_output="$3"
  local xcode_output="$4"
  local swift_output="$5"
  local xcodegen_output="$6"
  local hardware_raw display_raw
  local model_identifier chip processor_text cpu_core_count memory_gigabytes
  local gpu_core_count display_count pixel_text resolution_text
  local pixel_width pixel_height logical_width logical_height refresh_hertz scale

  hardware_raw="$(mktemp /tmp/idlescreen-r1-hardware.XXXXXX)"
  display_raw="$(mktemp /tmp/idlescreen-r1-display.XXXXXX)"
  /usr/sbin/system_profiler SPHardwareDataType -json >"$hardware_raw"
  /usr/sbin/system_profiler SPDisplaysDataType -json >"$display_raw"
  model_identifier="$(/usr/bin/jq -er '.SPHardwareDataType[0].machine_model' "$hardware_raw")"
  chip="$(/usr/bin/jq -er '.SPHardwareDataType[0].chip_type' "$hardware_raw")"
  processor_text="$(/usr/bin/jq -er '.SPHardwareDataType[0].number_processors' "$hardware_raw")"
  cpu_core_count="$(/usr/bin/sed -E 's/^proc ([0-9]+):.*/\1/' <<<"$processor_text")"
  memory_gigabytes="$(/usr/bin/jq -er '.SPHardwareDataType[0].physical_memory' "$hardware_raw" | /usr/bin/awk '{print $1}')"
  gpu_core_count="$(/usr/bin/jq -er '.SPDisplaysDataType[0].sppci_cores' "$display_raw")"
  display_count="$(/usr/bin/jq '[.SPDisplaysDataType[].spdisplays_ndrvs[]? | select(.spdisplays_online == "spdisplays_yes")] | length' "$display_raw")"
  [[ "$display_count" == 1 ]] || {
    /bin/rm -f "$hardware_raw" "$display_raw"
    r1_error "R1.1 requires exactly one online display; found $display_count"
    return
  }
  pixel_text="$(/usr/bin/jq -er '.SPDisplaysDataType[].spdisplays_ndrvs[] | select(.spdisplays_online == "spdisplays_yes") | ._spdisplays_pixels' "$display_raw")"
  resolution_text="$(/usr/bin/jq -er '.SPDisplaysDataType[].spdisplays_ndrvs[] | select(.spdisplays_online == "spdisplays_yes") | ._spdisplays_resolution' "$display_raw")"
  [[ "$pixel_text" =~ ^([0-9]+)[[:space:]]+x[[:space:]]+([0-9]+)$ ]] || {
    /bin/rm -f "$hardware_raw" "$display_raw"
    r1_error "could not parse online display pixel dimensions"
    return
  }
  pixel_width="${BASH_REMATCH[1]}"
  pixel_height="${BASH_REMATCH[2]}"
  [[ "$resolution_text" =~ ^([0-9]+)[[:space:]]+x[[:space:]]+([0-9]+)[[:space:]]+@[[:space:]]+([0-9]+([.][0-9]+)?)Hz$ ]] || {
    /bin/rm -f "$hardware_raw" "$display_raw"
    r1_error "could not parse online display logical dimensions and refresh rate"
    return
  }
  logical_width="${BASH_REMATCH[1]}"
  logical_height="${BASH_REMATCH[2]}"
  refresh_hertz="${BASH_REMATCH[3]}"
  scale="$(/usr/bin/awk -v pixels="$pixel_width" -v points="$logical_width" 'BEGIN { printf "%.6f", pixels / points }')"
  /usr/bin/awk -v pixels="$pixel_height" -v points="$logical_height" -v expected="$scale" \
    'BEGIN { actual = pixels / points; exit !((actual - expected < 0.000001) && (expected - actual < 0.000001)) }' || {
      /bin/rm -f "$hardware_raw" "$display_raw"
      r1_error "online display has inconsistent horizontal and vertical scale"
      return
    }
  /usr/bin/jq -S -n \
    --arg model_identifier "$model_identifier" \
    --arg chip "$chip" \
    --argjson cpu_core_count "$cpu_core_count" \
    --argjson gpu_core_count "$gpu_core_count" \
    --argjson memory_bytes "$((memory_gigabytes * 1024 * 1024 * 1024))" \
    '{modelIdentifier:$model_identifier,chip:$chip,cpuCoreCount:$cpu_core_count,gpuCoreCount:$gpu_core_count,memoryBytes:$memory_bytes}' \
    >"$hardware_output"
  /usr/bin/jq -S -n \
    --argjson count "$display_count" \
    --argjson logical_width "$logical_width" \
    --argjson logical_height "$logical_height" \
    --argjson pixel_width "$pixel_width" \
    --argjson pixel_height "$pixel_height" \
    --argjson scale "$scale" \
    --argjson refresh_hertz "$refresh_hertz" \
    '{count:$count,logicalWidth:$logical_width,logicalHeight:$logical_height,pixelWidth:$pixel_width,pixelHeight:$pixel_height,scale:$scale,refreshRateHertz:$refresh_hertz}' \
    >"$display_output"
  /usr/bin/sw_vers >"$os_output"
  /usr/bin/xcodebuild -version >"$xcode_output"
  /usr/bin/swift --version >"$swift_output"
  xcodegen --version >"$xcodegen_output"
  /bin/rm -f "$hardware_raw" "$display_raw"
}

r1_capture_footprint() {
  local pid="$1"
  local output="$2"
  local raw current peak captured_at
  raw="$(mktemp /tmp/idlescreen-r1-footprint.XXXXXX)"
  /usr/bin/footprint -p "$pid" --noCategories -f bytes >"$raw" 2>&1 || {
    /bin/rm -f "$raw"
    r1_error "footprint could not sample PID $pid"
    return
  }
  current="$(/usr/bin/awk '$1 == "phys_footprint:" { print $2; exit }' "$raw")"
  peak="$(/usr/bin/awk '$1 == "phys_footprint_peak:" { print $2; exit }' "$raw")"
  [[ "$current" =~ ^[0-9]+$ && "$peak" =~ ^[0-9]+$ ]] || {
    /bin/rm -f "$raw"
    r1_error "footprint returned malformed physical-footprint counters for PID $pid"
    return
  }
  captured_at="$(r1_iso8601_now)"
  /usr/bin/printf 'capturedAt,pid,physicalFootprintBytes,physicalFootprintPeakBytes\n%s,%s,%s,%s\n' \
    "$captured_at" "$pid" "$current" "$peak" >"$output"
  /bin/rm -f "$raw"
}

r1_select_helper_executable_path() {
  /usr/bin/awk '
    /^n\// {
      path = substr($0, 2)
      if (path ~ /\/IdleScreenCameraAgent[.]app\/Contents\/MacOS\/IdleScreenCameraAgent$/) {
        selected = path
        count++
      }
    }
    END {
      if (count == 1) {
        print selected
        exit 0
      }
      exit 1
    }
  '
}

r1_capture_helper_identity() {
  local launchd_job="$1"
  local output="$2"
  local snapshot lsof_output pid executable_path start_identity executable_sha
  local static_details dynamic_details static_cdhash dynamic_cdhash
  local identifier team_identifier helper_bundle info_plist bundle_identifier
  local bundle_version bundle_short_version
  snapshot="$(/bin/launchctl print "$launchd_job" 2>&1)" ||
    r1_error "existing Release helper is not running; R1.1 will not start it" || return
  pid="$(/usr/bin/awk '/^[[:space:]]*pid = [0-9]+/ {print $3; count++} END {exit(count == 1 ? 0 : 1)}' <<<"$snapshot")" ||
    r1_error "launchd snapshot did not contain one helper PID" || return
  lsof_output="$(/usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null)" ||
    r1_error "could not resolve the existing helper executable" || return
  executable_path="$(r1_select_helper_executable_path <<<"$lsof_output")" ||
    r1_error "existing helper PID did not have one executable text path" || return
  [[ "$executable_path" == */IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent ]] ||
    r1_error "existing helper executable path is not the camera agent" || return
  start_identity="$(/bin/ps -p "$pid" -o lstart= -o command=)" ||
    r1_error "could not capture the existing helper start identity" || return
  executable_sha="$(r1_sha256_file "$executable_path")"
  /usr/bin/codesign --verify --verbose=4 "$executable_path" >/dev/null 2>&1 ||
    r1_error "existing helper static signature verification failed" || return
  /usr/bin/codesign --verify --verbose=4 "$pid" >/dev/null 2>&1 ||
    r1_error "existing helper dynamic signature verification failed" || return
  static_details="$(/usr/bin/codesign -dv --verbose=4 "$executable_path" 2>&1)" ||
    r1_error "could not read existing helper static signature" || return
  dynamic_details="$(/usr/bin/codesign -dv --verbose=4 "$pid" 2>&1)" ||
    r1_error "could not read existing helper dynamic signature" || return
  static_cdhash="$(/usr/bin/awk -F= '$1 == "CDHash" {print tolower($2); count++} END {exit(count == 1 ? 0 : 1)}' <<<"$static_details")" ||
    r1_error "existing helper static signature has no unique CDHash" || return
  dynamic_cdhash="$(/usr/bin/awk -F= '$1 == "CDHash" {print tolower($2); count++} END {exit(count == 1 ? 0 : 1)}' <<<"$dynamic_details")" ||
    r1_error "existing helper dynamic signature has no unique CDHash" || return
  [[ "$static_cdhash" == "$dynamic_cdhash" ]] ||
    r1_error "existing helper static and dynamic CDHashes differ" || return
  identifier="$(/usr/bin/awk -F= '$1 == "Identifier" {print $2; count++} END {exit(count == 1 ? 0 : 1)}' <<<"$static_details")" ||
    r1_error "existing helper signature has no unique identifier" || return
  team_identifier="$(/usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2; count++} END {exit(count == 1 ? 0 : 1)}' <<<"$static_details")" ||
    r1_error "existing helper signature has no unique team identifier" || return
  helper_bundle="$(/usr/bin/dirname "$(/usr/bin/dirname "$(/usr/bin/dirname "$executable_path")")")"
  info_plist="$helper_bundle/Contents/Info.plist"
  [[ -f "$info_plist" && ! -L "$info_plist" ]] ||
    r1_error "existing helper bundle Info.plist is unavailable" || return
  bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
  bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
  bundle_short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
  [[ "$identifier" == "$bundle_identifier" ]] ||
    r1_error "existing helper signed and bundled identifiers differ" || return
  /usr/bin/jq -S -n \
    --arg captured_at "$(r1_iso8601_now)" \
    --arg launchd_job "$launchd_job" \
    --arg launchd_snapshot "$snapshot" \
    --argjson pid "$pid" \
    --arg start_identity "$start_identity" \
    --arg executable_path "$executable_path" \
    --arg executable_sha "$executable_sha" \
    --arg cdhash "$static_cdhash" \
    --arg identifier "$identifier" \
    --arg team_identifier "$team_identifier" \
    --arg static_details "$static_details" \
    --arg dynamic_details "$dynamic_details" \
    --arg bundle_identifier "$bundle_identifier" \
    --arg bundle_version "$bundle_version" \
    --arg bundle_short_version "$bundle_short_version" \
    '{schemaVersion:1,capturedAt:$captured_at,launchdJob:$launchd_job,launchdSnapshot:$launchd_snapshot,pid:$pid,startIdentity:$start_identity,executablePath:$executable_path,executableSHA256:$executable_sha,codesign:{cdHash:$cdhash,identifier:$identifier,teamIdentifier:$team_identifier,staticDetails:$static_details,dynamicDetails:$dynamic_details},bundle:{identifier:$bundle_identifier,version:$bundle_version,shortVersion:$bundle_short_version}}' \
    >"$output"
}

r1_write_artifact_manifest() {
  local performance_binary="$1"
  local renderer_framework="$2"
  local output="$3"
  local inventory
  inventory="$(mktemp /tmp/idlescreen-r1-artifacts.XXXXXX)"
  /usr/bin/printf '%s\t%s\n' \
    "$performance_binary" idlescreen-perf \
    "$renderer_framework/IdleScreenRenderer" IdleScreenRenderer.framework/Versions/A/IdleScreenRenderer \
    "$renderer_framework/Resources/Info.plist" IdleScreenRenderer.framework/Versions/A/Resources/Info.plist \
    "$renderer_framework/Resources/default.metallib" IdleScreenRenderer.framework/Versions/A/Resources/default.metallib \
    >"$inventory"
  while IFS=$'\t' read -r path relative; do
    [[ -f "$path" && ! -L "$path" ]] || {
      /bin/rm -f "$inventory"
      r1_error "Release performance artifact is incomplete: $relative"
      return
    }
  done <"$inventory"
  LC_ALL=C /usr/bin/sort -t $'\t' -k2,2 "$inventory" |
    while IFS=$'\t' read -r path relative; do
      /usr/bin/printf '%s  %s\n' "$(r1_sha256_file "$path")" "$relative"
    done >"$output"
  /bin/rm -f "$inventory"
}

r1_install_resume_runtime() {
  local performance_binary="$1"
  local renderer_framework="$2"
  local capsule="$3"
  local framework_root
  [[ -x "$performance_binary" && -f "$performance_binary" && ! -L "$performance_binary" ]] ||
    r1_error "resume runtime executable is missing, nonregular, or a symlink" || return
  [[ "$renderer_framework" == */Versions/A ]] ||
    r1_error "resume runtime renderer path is not a versioned framework" || return
  framework_root="${renderer_framework%/Versions/A}"
  [[ -d "$framework_root" && ! -L "$framework_root" ]] ||
    r1_error "resume runtime framework is missing or a symlink" || return
  [[ ! -e "$capsule" ]] ||
    r1_error "resume runtime capsule already exists" || return
  /bin/mkdir -p "$capsule"
  /bin/cp "$performance_binary" "$capsule/idlescreen-perf"
  /bin/chmod +x "$capsule/idlescreen-perf"
  /usr/bin/ditto "$framework_root" "$capsule/IdleScreenRenderer.framework"
}

r1_validate_resume_runtime() {
  local capsule="$1"
  local expected_manifest="$2"
  local performance_binary renderer_framework candidate_manifest
  [[ -d "$capsule" && ! -L "$capsule" ]] ||
    r1_error "resume requires the preserved exact runtime capsule" || return
  performance_binary="$capsule/idlescreen-perf"
  renderer_framework="$capsule/IdleScreenRenderer.framework/Versions/A"
  [[ -x "$performance_binary" && -f "$performance_binary" && ! -L "$performance_binary" ]] ||
    r1_error "preserved resume executable is invalid" || return
  candidate_manifest="$(mktemp /tmp/idlescreen-r1-resume-artifacts.XXXXXX)"
  r1_write_artifact_manifest \
    "$performance_binary" "$renderer_framework" "$candidate_manifest" || {
      /bin/rm -f "$candidate_manifest"
      return 1
    }
  /usr/bin/cmp -s "$candidate_manifest" "$expected_manifest" || {
    /bin/rm -f "$candidate_manifest"
    r1_error "preserved resume runtime differs from the immutable artifact manifest"
    return
  }
  /bin/rm -f "$candidate_manifest"
  /usr/bin/printf '%s\t%s\n' "$performance_binary" "$renderer_framework"
}

r1_install_if_absent() {
  local candidate="$1"
  local preserved="$2"
  local label="$3"
  [[ -f "$candidate" && ! -L "$candidate" ]] ||
    r1_error "$label candidate is missing or nonregular" || return
  if [[ -e "$preserved" ]]; then
    [[ -f "$preserved" && ! -L "$preserved" ]] ||
      r1_error "preserved $label is nonregular or a symlink" || return
  else
    /bin/cp "$candidate" "$preserved"
  fi
}

r1_main() {
  local project_root duration_seconds run_mode resume_run evidence_directory
  local derived_data performance_binary renderer_framework
  local preflight_path preflight_candidate preflight_canonical run_identifier
  local captured_at artifact_built_at current_artifact_built_at artifact_candidate budget_candidate
  local artifact_sha budgets_sha hardware_class target_fps
  local display_pixel_width display_pixel_height display_scale budget_device
  local budget_pixel_format source_identity_start source_identity_end
  local hardware_base_start hardware_start display_start os_start xcode_start
  local swift_start xcodegen_start power_start hardware_base_end hardware_end
  local display_end os_end xcode_end swift_end xcodegen_end power_end
  local logical_width logical_height pixel_width pixel_height refresh_hertz
  local display_count model_identifier chip cpu_core_count gpu_core_count memory_bytes
  local commit diff_sha dirty_count os_version os_build
  local xcode_version swift_version xcodegen_version power_source
  local workloads_json environment_paths_json helper_job
  local report_exit evidence_inventory evidence_candidate metadata_candidate
  local workload path helper_pid existing_count requested_evidence_directory
  local resume_runtime resolved_runtime

  project_root="$(cd "$(dirname "$0")/.." && /bin/pwd -P)"
  duration_seconds="${IDLESCREEN_PERF_DURATION_SECONDS:-900}"
  run_mode="${IDLESCREEN_PERF_MODE:-gating}"
  resume_run="${IDLESCREEN_PERF_RESUME:-0}"
  requested_evidence_directory="${1:-$project_root/.planning/evidence/r1.1-2026-08-09-m4pro-single-display}"
  evidence_directory="$(r1_resolve_evidence_directory \
    "$project_root" "$requested_evidence_directory")"
  r1_validate_mode_duration "$run_mode" "$duration_seconds"
  [[ "$resume_run" == 0 || "$resume_run" == 1 ]] ||
    r1_error "IDLESCREEN_PERF_RESUME must be exactly 0 or 1" || return
  if [[ "$resume_run" == 1 ]]; then
    [[ -d "$evidence_directory" && ! -L "$evidence_directory" ]] ||
      r1_error "resume requires an existing real evidence directory" || return
    [[ -f "$evidence_directory/preflight-manifest.json" ]] ||
      r1_error "resume requires preflight-manifest.json" || return
  else
    [[ ! -e "$evidence_directory" ]] ||
      r1_error "evidence directory already exists: $evidence_directory" || return
  fi

  derived_data="$(mktemp -d /private/tmp/idlescreen-r1-derived.XXXXXX)"
  R1_TASK_DERIVED_DATA="$derived_data"
  trap r1_cleanup EXIT

  hardware_base_start="$derived_data/hardware-base-start.json"
  display_start="$derived_data/displays-start.json"
  os_start="$derived_data/operating-system-start.txt"
  xcode_start="$derived_data/xcode-version-start.txt"
  swift_start="$derived_data/swift-version-start.txt"
  xcodegen_start="$derived_data/xcodegen-version-start.txt"
  power_start="$derived_data/power-source-start.txt"
  r1_capture_host_environment "$hardware_base_start" "$display_start" "$os_start" \
    "$xcode_start" "$swift_start" "$xcodegen_start"
  power_source="$(r1_capture_power_source "$power_start")"

  resume_runtime="$evidence_directory/.resume-runtime"
  if [[ "$resume_run" == 1 ]]; then
    echo "Using preserved exact Release performance harness..." >&2
    resolved_runtime="$(r1_validate_resume_runtime \
      "$resume_runtime" "$evidence_directory/artifact-manifest.txt")"
    performance_binary="${resolved_runtime%%$'\t'*}"
    renderer_framework="${resolved_runtime#*$'\t'}"
  else
    echo "Building unsigned Release performance harness..." >&2
    (cd "$project_root" && xcodegen generate >/dev/null)
    /usr/bin/xcodebuild build -quiet \
      -project "$project_root/IdleScreen.xcodeproj" \
      -scheme IdleScreenPerformanceRunner \
      -configuration Release \
      -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath "$derived_data" \
      CODE_SIGNING_ALLOWED=NO \
      SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
    performance_binary="$derived_data/Build/Products/Release/idlescreen-perf"
    renderer_framework="$derived_data/Build/Products/Release/IdleScreenRenderer.framework/Versions/A"
  fi
  [[ -x "$performance_binary" ]] || r1_error "Release performance runner is unavailable" || return
  artifact_candidate="$derived_data/artifact-manifest.txt"
  r1_write_artifact_manifest "$performance_binary" "$renderer_framework" "$artifact_candidate"
  budget_candidate="$derived_data/budgets.json"
  "$performance_binary" --budgets --output "$budget_candidate"
  current_artifact_built_at="$(r1_iso8601_now)"

  hardware_class="$(/usr/bin/jq -er '.hardwareClass' "$budget_candidate")"
  target_fps="$(/usr/bin/jq -er '.targetFramesPerSecond' "$budget_candidate")"
  display_pixel_width="$(/usr/bin/jq -er '.displayPixelWidth' "$budget_candidate")"
  display_pixel_height="$(/usr/bin/jq -er '.displayPixelHeight' "$budget_candidate")"
  display_scale="$(/usr/bin/jq -er '.displayScale' "$budget_candidate")"
  budget_device="$(/usr/bin/jq -er '.metalDeviceName' "$budget_candidate")"
  budget_pixel_format="$(/usr/bin/jq -er '.colorPixelFormat' "$budget_candidate")"
  display_count="$(/usr/bin/jq -er '.count' "$display_start")"
  logical_width="$(/usr/bin/jq -er '.logicalWidth' "$display_start")"
  logical_height="$(/usr/bin/jq -er '.logicalHeight' "$display_start")"
  pixel_width="$(/usr/bin/jq -er '.pixelWidth' "$display_start")"
  pixel_height="$(/usr/bin/jq -er '.pixelHeight' "$display_start")"
  refresh_hertz="$(/usr/bin/jq -er '.refreshRateHertz' "$display_start")"
  r1_validate_display_budget "$display_start" "$budget_candidate" || return
  [[ "$(/usr/bin/jq -r '.chip' "$hardware_base_start")" == "$budget_device" ]] ||
    r1_error "actual Metal device does not match the immutable budget hardware" || return
  [[ "$budget_pixel_format" == bgra8Unorm ]] ||
    r1_error "unsupported budget color pixel format: $budget_pixel_format" || return
  hardware_start="$derived_data/hardware-start.json"
  /usr/bin/jq -S --arg hardware_class "$hardware_class" \
    '. + {hardwareClass:$hardware_class}' "$hardware_base_start" >"$hardware_start"

  source_identity_start="$derived_data/source-identity-start.json"
  r1_capture_source_identity "$project_root" "$evidence_directory" \
    "$derived_data/source-status-start.txt" "$source_identity_start"
  if [[ "$resume_run" == 1 ]]; then
    run_identifier="$(/usr/bin/jq -er '.runIdentifier' "$evidence_directory/preflight-manifest.json")"
    captured_at="$(/usr/bin/jq -er '.capturedAt' "$evidence_directory/preflight-manifest.json")"
    artifact_built_at="$(/usr/bin/jq -er '.artifactBuiltAt' "$evidence_directory/preflight-manifest.json")"
  else
    run_identifier="r1.1-$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
    captured_at="$(r1_iso8601_now)"
    artifact_built_at="$current_artifact_built_at"
  fi

  workloads_json="$derived_data/workloads.json"
  /usr/bin/jq -S -n --argjson duration "$duration_seconds" '
    [
      {workload:"rendererStartupCold",resultPaths:[range(1;6) | "rendererStartupCold-\(.).json"],iterationsPerResult:1,durationSeconds:null,energyPath:null},
      {workload:"rendererStartupWarm",resultPaths:["rendererStartupWarm.json"],iterationsPerResult:5,durationSeconds:null,energyPath:null}
    ] +
    (["generative","cameraSynthetic","pixelMaterialsSand","pixelMaterialsWater","pixelMaterialsMixed","mailboxTransport","agentSignalPolling","zeroConsumer","helperIdle"] |
      map({workload:.,resultPaths:["\(.).json"],iterationsPerResult:null,durationSeconds:$duration,energyPath:"\(.).top.csv"}))
  ' >"$workloads_json"
  environment_paths_json="$derived_data/environment-paths.json"
  {
    /usr/bin/printf '%s\n' \
      displays-start.json displays-end.json hardware-start.json hardware-end.json \
      operating-system-start.txt operating-system-end.txt power-source-start.txt power-source-end.txt \
      source-status-start.txt source-status-end.txt swift-version-start.txt swift-version-end.txt \
      thermal-start.txt thermal-end.txt vm-start.txt vm-end.txt \
      xcode-version-start.txt xcode-version-end.txt xcodegen-version-start.txt xcodegen-version-end.txt
    for workload in generative cameraSynthetic pixelMaterialsSand pixelMaterialsWater pixelMaterialsMixed mailboxTransport agentSignalPolling zeroConsumer helperIdle; do
      /usr/bin/printf '%s.footprint.csv\n' "$workload"
    done
  } | LC_ALL=C /usr/bin/sort | /usr/bin/jq -Rsc 'split("\n") | map(select(length > 0))' >"$environment_paths_json"

  artifact_sha="$(r1_sha256_file "$artifact_candidate")"
  budgets_sha="$(r1_sha256_file "$budget_candidate")"
  commit="$(/usr/bin/jq -er '.commit' "$source_identity_start")"
  diff_sha="$(/usr/bin/jq -er '.diffSHA256' "$source_identity_start")"
  dirty_count="$(/usr/bin/jq -er '.dirtyPathCount' "$source_identity_start")"
  model_identifier="$(/usr/bin/jq -er '.modelIdentifier' "$hardware_start")"
  chip="$(/usr/bin/jq -er '.chip' "$hardware_start")"
  cpu_core_count="$(/usr/bin/jq -er '.cpuCoreCount' "$hardware_start")"
  gpu_core_count="$(/usr/bin/jq -er '.gpuCoreCount' "$hardware_start")"
  memory_bytes="$(/usr/bin/jq -er '.memoryBytes' "$hardware_start")"
  os_version="$(/usr/bin/awk -F': *' '$1 == "ProductVersion" {print $2}' "$os_start")"
  os_build="$(/usr/bin/awk -F': *' '$1 == "BuildVersion" {print $2}' "$os_start")"
  xcode_version="$(/usr/bin/tr '\n' ' ' <"$xcode_start" | /usr/bin/sed 's/[[:space:]]*$//')"
  swift_version="$(/usr/bin/tr '\n' ' ' <"$swift_start" | /usr/bin/sed 's/[[:space:]]*$//')"
  xcodegen_version="$(/usr/bin/tr '\n' ' ' <"$xcodegen_start" | /usr/bin/sed 's/[[:space:]]*$//')"
  preflight_candidate="$derived_data/preflight-candidate.json"
  preflight_canonical="$derived_data/preflight-canonical.json"
  /usr/bin/jq -S -n \
    --arg run_identifier "$run_identifier" --arg captured_at "$captured_at" --arg artifact_built_at "$artifact_built_at" \
    --arg mode "$run_mode" --argjson duration "$duration_seconds" --arg commit "$commit" --arg diff_sha "$diff_sha" \
    --argjson dirty_count "$dirty_count" --arg xcode_version "$xcode_version" --arg swift_version "$swift_version" \
    --arg xcodegen_version "$xcodegen_version" --arg os_version "$os_version" --arg os_build "$os_build" \
    --arg model_identifier "$model_identifier" --arg hardware_class "$hardware_class" --arg chip "$chip" \
    --argjson cpu_core_count "$cpu_core_count" --argjson gpu_core_count "$gpu_core_count" --argjson memory_bytes "$memory_bytes" \
    --argjson display_count "$display_count" --argjson logical_width "$logical_width" --argjson logical_height "$logical_height" \
    --argjson pixel_width "$pixel_width" --argjson pixel_height "$pixel_height" --argjson display_scale "$display_scale" \
    --argjson refresh_hertz "$refresh_hertz" --argjson target_fps "$target_fps" --arg power_source "$power_source" \
    --arg artifact_sha "$artifact_sha" --arg budgets_sha "$budgets_sha" \
    --slurpfile workloads "$workloads_json" --slurpfile environment_paths "$environment_paths_json" '
      {schemaVersion:1,runIdentifier:$run_identifier,capturedAt:$captured_at,artifactBuiltAt:$artifact_built_at,mode:$mode,requiredDurationSeconds:$duration,coldStartupSampleCount:5,warmStartupSampleCount:5,energySamplingIntervalSeconds:1,sourceIdentity:{commit:$commit,diffSHA256:$diff_sha,dirtyPathCount:$dirty_count},toolchain:{xcodeVersion:$xcode_version,swiftVersion:$swift_version,xcodegenVersion:$xcodegen_version},operatingSystem:{version:$os_version,build:$os_build},hardware:{modelIdentifier:$model_identifier,hardwareClass:$hardware_class,chip:$chip,cpuCoreCount:$cpu_core_count,gpuCoreCount:$gpu_core_count,memoryBytes:$memory_bytes},display:{count:$display_count,logicalWidth:$logical_width,logicalHeight:$logical_height,pixelWidth:$pixel_width,pixelHeight:$pixel_height,scale:$display_scale,refreshRateHertz:$refresh_hertz},targetFramesPerSecond:$target_fps,targetSurface:{logicalWidth:$logical_width,logicalHeight:$logical_height,pixelWidth:$pixel_width,pixelHeight:$pixel_height},powerSource:$power_source,artifactManifestSHA256:$artifact_sha,budgetsSHA256:$budgets_sha,workloads:$workloads[0],environmentInputPaths:$environment_paths[0]}' \
    >"$preflight_candidate"
  r1_canonicalize_preflight "$preflight_candidate" "$preflight_canonical"

  /bin/mkdir -p "$evidence_directory"
  preflight_path="$evidence_directory/preflight-manifest.json"
  r1_install_or_compare_file "$artifact_candidate" "$evidence_directory/artifact-manifest.txt" "$resume_run" "artifact manifest"
  r1_install_or_compare_file "$budget_candidate" "$evidence_directory/budgets.json" "$resume_run" "budget set"
  for path in hardware-start.json displays-start.json operating-system-start.txt xcode-version-start.txt swift-version-start.txt xcodegen-version-start.txt power-source-start.txt source-status-start.txt; do
    case "$path" in
      hardware-start.json) candidate="$hardware_start" ;;
      displays-start.json) candidate="$display_start" ;;
      operating-system-start.txt) candidate="$os_start" ;;
      xcode-version-start.txt) candidate="$xcode_start" ;;
      swift-version-start.txt) candidate="$swift_start" ;;
      xcodegen-version-start.txt) candidate="$xcodegen_start" ;;
      power-source-start.txt) candidate="$power_start" ;;
      source-status-start.txt) candidate="$derived_data/source-status-start.txt" ;;
    esac
    r1_install_or_compare_file "$candidate" "$evidence_directory/$path" "$resume_run" "$path"
  done
  r1_install_or_compare_preflight "$preflight_canonical" "$preflight_path" "$resume_run"
  if [[ "$resume_run" == 0 ]]; then
    r1_install_resume_runtime \
      "$performance_binary" "$renderer_framework" "$resume_runtime"
  fi

  /usr/bin/caffeinate -di -w $$ &
  R1_TASK_CAFFEINATE_PID=$!
  if [[ "$resume_run" == 0 ]]; then
    /usr/bin/pmset -g therm >"$evidence_directory/thermal-start.txt" 2>&1
    /usr/bin/vm_stat >"$evidence_directory/vm-start.txt"
  else
    [[ -s "$evidence_directory/thermal-start.txt" && -s "$evidence_directory/vm-start.txt" ]] ||
      r1_error "resume has incomplete start-of-window environment evidence" || return
  fi

  r1_run_startup() {
    local startup_workload="$1" iterations="$2" output="$3"
    [[ -s "$output" ]] && return 0
    "$performance_binary" --workload "$startup_workload" --iterations "$iterations" \
      --width "$logical_width" --height "$logical_height" \
      --drawable-width "$pixel_width" --drawable-height "$pixel_height" \
      --output "$derived_data/$(/usr/bin/basename "$output")"
    /bin/cp "$derived_data/$(/usr/bin/basename "$output")" "$output"
  }
  echo "Measuring renderer startup samples..." >&2
  for existing_count in 1 2 3 4 5; do
    r1_run_startup rendererStartupCold 1 "$evidence_directory/rendererStartupCold-$existing_count.json"
  done
  r1_run_startup rendererStartupWarm 5 "$evidence_directory/rendererStartupWarm.json"

  r1_collect_duration_measurement() {
    local measured_workload="$1" observed_pid="${2:-}" result_candidate top_raw top_candidate footprint_candidate
    local workload_pid top_pid
    result_candidate="$derived_data/$measured_workload.result.json"
    top_raw="$derived_data/$measured_workload.top.txt"
    top_candidate="$derived_data/$measured_workload.top.csv"
    footprint_candidate="$derived_data/$measured_workload.footprint.csv"
    echo "Measuring $measured_workload for $duration_seconds seconds..." >&2
    local -a command=("$performance_binary" --workload "$measured_workload" --duration "$duration_seconds")
    case "$measured_workload" in
      generative|cameraSynthetic|pixelMaterialsSand|pixelMaterialsWater|pixelMaterialsMixed)
        command+=(--width "$logical_width" --height "$logical_height" --drawable-width "$pixel_width" --drawable-height "$pixel_height")
        ;;
      helperIdle) command+=(--pid "$observed_pid") ;;
    esac
    command+=(--output "$result_candidate")
    "${command[@]}" &
    workload_pid=$!
    [[ -n "$observed_pid" ]] || observed_pid="$workload_pid"
    /usr/bin/top -l 0 -s 1 -pid "$observed_pid" -stats pid,cpu,power,mem >"$top_raw" &
    top_pid=$!
    if ! r1_capture_footprint "$observed_pid" "$footprint_candidate"; then
      /bin/kill -TERM "$workload_pid" "$top_pid" 2>/dev/null || true
      wait "$workload_pid" 2>/dev/null || true
      wait "$top_pid" 2>/dev/null || true
      return 1
    fi
    if ! wait "$workload_pid"; then
      /bin/kill -TERM "$top_pid" 2>/dev/null || true
      wait "$top_pid" 2>/dev/null || true
      r1_error "workload failed: $measured_workload"
      return
    fi
    /bin/kill -TERM "$top_pid" 2>/dev/null || true
    wait "$top_pid" 2>/dev/null || true
    /usr/bin/awk -v expected_pid="$observed_pid" '$1 == expected_pid {print $1, $2, $3, $4}' "$top_raw" >"$top_candidate"
    [[ -s "$result_candidate" && -s "$top_candidate" && -s "$footprint_candidate" ]] ||
      r1_error "duration measurement produced incomplete evidence: $measured_workload" || return
  }
  r1_install_measurement() {
    local measured_workload="$1"
    /bin/cp "$derived_data/$measured_workload.result.json" "$evidence_directory/$measured_workload.json"
    /bin/cp "$derived_data/$measured_workload.top.csv" "$evidence_directory/$measured_workload.top.csv"
    /bin/cp "$derived_data/$measured_workload.footprint.csv" "$evidence_directory/$measured_workload.footprint.csv"
  }
  for workload in generative cameraSynthetic pixelMaterialsSand pixelMaterialsWater pixelMaterialsMixed mailboxTransport agentSignalPolling zeroConsumer; do
    existing_count=0
    for path in "$evidence_directory/$workload.json" "$evidence_directory/$workload.top.csv" "$evidence_directory/$workload.footprint.csv"; do
      [[ -s "$path" ]] && existing_count=$((existing_count + 1))
    done
    [[ "$existing_count" == 0 || "$existing_count" == 3 ]] ||
      r1_error "resume has a partial $workload measurement group" || return
    if [[ "$existing_count" == 0 ]]; then
      r1_collect_duration_measurement "$workload"
      r1_install_measurement "$workload"
    fi
    r1_assert_source_identity_unchanged \
      "$project_root" "$evidence_directory" "$source_identity_start" \
      "$derived_data/source-status-check-$workload.json" \
      "$derived_data/source-identity-check-$workload.json" "$workload"
  done

  helper_job="gui/$(/usr/bin/id -u)/group.com.idlescreen.shared.camera-agent"
  existing_count=0
  for path in helperIdle.json helperIdle.top.csv helperIdle.footprint.csv helper-start-identity.json helper-end-identity.json; do
    [[ -s "$evidence_directory/$path" ]] && existing_count=$((existing_count + 1))
  done
  [[ "$existing_count" == 0 || "$existing_count" == 5 ]] ||
    r1_error "resume has a partial helperIdle identity/measurement group" || return
  if [[ "$existing_count" == 0 ]]; then
    r1_capture_helper_identity "$helper_job" "$derived_data/helper-start-identity.json"
    helper_pid="$(/usr/bin/jq -er '.pid' "$derived_data/helper-start-identity.json")"
    r1_collect_duration_measurement helperIdle "$helper_pid"
    r1_capture_helper_identity "$helper_job" "$derived_data/helper-end-identity.json"
    r1_validate_helper_identity_pair "$derived_data/helper-start-identity.json" "$derived_data/helper-end-identity.json"
    r1_install_measurement helperIdle
    /bin/cp "$derived_data/helper-start-identity.json" "$evidence_directory/helper-start-identity.json"
    /bin/cp "$derived_data/helper-end-identity.json" "$evidence_directory/helper-end-identity.json"
  else
    r1_validate_helper_identity_pair "$evidence_directory/helper-start-identity.json" "$evidence_directory/helper-end-identity.json"
  fi
  r1_assert_source_identity_unchanged \
    "$project_root" "$evidence_directory" "$source_identity_start" \
    "$derived_data/source-status-check-helperIdle.json" \
    "$derived_data/source-identity-check-helperIdle.json" helperIdle

  /usr/bin/pmset -g therm >"$derived_data/thermal-end.txt" 2>&1
  /usr/bin/vm_stat >"$derived_data/vm-end.txt"
  hardware_base_end="$derived_data/hardware-base-end.json"
  display_end="$derived_data/displays-end.json"
  os_end="$derived_data/operating-system-end.txt"
  xcode_end="$derived_data/xcode-version-end.txt"
  swift_end="$derived_data/swift-version-end.txt"
  xcodegen_end="$derived_data/xcodegen-version-end.txt"
  power_end="$derived_data/power-source-end.txt"
  r1_capture_host_environment "$hardware_base_end" "$display_end" "$os_end" "$xcode_end" "$swift_end" "$xcodegen_end"
  r1_capture_power_source "$power_end" >/dev/null
  hardware_end="$derived_data/hardware-end.json"
  /usr/bin/jq -S --arg hardware_class "$hardware_class" '. + {hardwareClass:$hardware_class}' "$hardware_base_end" >"$hardware_end"
  source_identity_end="$derived_data/source-identity-end.json"
  r1_assert_source_identity_unchanged \
    "$project_root" "$evidence_directory" "$source_identity_start" \
    "$derived_data/source-status-end.txt" "$source_identity_end" final
  /usr/bin/cmp -s "$hardware_start" "$hardware_end" || r1_error "hardware changed during the run" || return
  /usr/bin/cmp -s "$display_start" "$display_end" || r1_error "display changed during the run" || return
  /usr/bin/cmp -s "$os_start" "$os_end" || r1_error "operating system changed during the run" || return
  /usr/bin/cmp -s "$xcode_start" "$xcode_end" || r1_error "Xcode changed during the run" || return
  /usr/bin/cmp -s "$swift_start" "$swift_end" || r1_error "Swift changed during the run" || return
  /usr/bin/cmp -s "$xcodegen_start" "$xcodegen_end" || r1_error "XcodeGen changed during the run" || return
  r1_write_artifact_manifest "$performance_binary" "$renderer_framework" "$derived_data/artifact-manifest-end.txt"
  /usr/bin/cmp -s "$artifact_candidate" "$derived_data/artifact-manifest-end.txt" || r1_error "runtime artifact closure changed during the run" || return
  "$performance_binary" --budgets --output "$derived_data/budgets-end.json"
  /usr/bin/cmp -s "$budget_candidate" "$derived_data/budgets-end.json" || r1_error "budget set changed during the run" || return
  r1_canonicalize_preflight "$preflight_candidate" "$derived_data/preflight-end.json"
  /usr/bin/cmp -s "$derived_data/preflight-end.json" "$preflight_path" || r1_error "final preflight semantics differ from the immutable manifest" || return

  for path in thermal-end.txt vm-end.txt hardware-end.json displays-end.json operating-system-end.txt xcode-version-end.txt swift-version-end.txt xcodegen-version-end.txt power-source-end.txt source-status-end.txt; do
    candidate="$derived_data/$path"
    r1_install_if_absent "$candidate" "$evidence_directory/$path" "$path"
  done
  metadata_candidate="$derived_data/metadata.json"
  /usr/bin/jq -S -n --arg run_identifier "$run_identifier" --arg captured_at "$captured_at" --arg commit "$commit" \
    --arg artifact_sha "$artifact_sha" --slurpfile hardware "$hardware_start" --arg os_version "$os_version" --arg os_build "$os_build" \
    --slurpfile display "$display_start" --argjson dirty_count "$dirty_count" --arg mode "$run_mode" --argjson duration "$duration_seconds" '
    {schemaVersion:1,runIdentifier:$run_identifier,capturedAt:$captured_at,commit:$commit,artifactSHA256:$artifact_sha,hardware:$hardware[0],operatingSystem:{version:$os_version,build:$os_build},display:$display[0],notes:["Unsigned Release offscreen harness; no companion or saver product was launched.","The already-running Release helper was sampled read-only; the runner did not start, install, or signal it.","Source closure includes tracked diffs and content hashes for every nonignored untracked source path.","Run mode \($mode); every duration workload ran for \($duration) seconds; signed-candidate lifecycle and physical camera gates were intentionally not run.","The immutable source snapshot contained \($dirty_count) changed paths."]}' >"$metadata_candidate"
  r1_install_if_absent "$metadata_candidate" "$evidence_directory/metadata.json" "metadata"

  evidence_inventory="$derived_data/evidence-inventory.tsv"
  /usr/bin/printf '%s\t%s\n' preflight preflight-manifest.json artifact artifact-manifest.txt budgets budgets.json metadata metadata.json helperIdentity helper-start-identity.json helperIdentity helper-end-identity.json >"$evidence_inventory"
  /usr/bin/jq -r '.workloads[].resultPaths[] | "workload\t\(.)"' "$preflight_path" >>"$evidence_inventory"
  /usr/bin/jq -r '.workloads[].energyPath | select(. != null) | "energy\t\(.)"' "$preflight_path" >>"$evidence_inventory"
  /usr/bin/jq -r '.environmentInputPaths[] | "environment\t\(.)"' "$preflight_path" >>"$evidence_inventory"
  evidence_candidate="$derived_data/evidence-manifest.json"
  r1_write_evidence_manifest "$evidence_directory" "$evidence_inventory" "$evidence_candidate" "$run_identifier"
  if [[ -e "$evidence_directory/evidence-manifest.json" ]]; then
    /usr/bin/cmp -s "$evidence_candidate" "$evidence_directory/evidence-manifest.json" ||
      r1_error "evidence manifest differs from the immutable finalized manifest" || return
  else
    /bin/cp "$evidence_candidate" "$evidence_directory/evidence-manifest.json"
  fi

  report_exit=0
  /usr/bin/python3 "$project_root/scripts/performance_r1_report.py" --input "$evidence_directory" \
    --output "$evidence_directory/report.json" --markdown "$evidence_directory/REPORT.md" || report_exit=$?
  [[ "$report_exit" == 0 ]] || r1_error "R1.1 evidence has missing or over-budget rows" || return
  if [[ "$resume_runtime" == "$evidence_directory/.resume-runtime" &&
        -d "$resume_runtime" && ! -L "$resume_runtime" ]]; then
    /bin/rm -rf -- "$resume_runtime"
  fi
  echo "PASS: R1.1 performance and energy budgets passed: $evidence_directory" >&2
}

if [[ "${IDLESCREEN_PERF_LIBRARY_MODE:-0}" != 1 ]]; then
  r1_main "$@"
fi
