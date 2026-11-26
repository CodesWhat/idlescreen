#!/bin/bash

r1_sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print tolower($1) }'
}

r1_canonical_tree_inventory() {
  local root="$1"
  local output="$2"
  local candidate
  local relative
  local mode
  local size
  local target
  local resolved_target
  local file_sha
  local candidate_list
  local xattr_name
  local xattr_names
  local xattr_value

  [[ -d "$root" && ! -L "$root" ]] || return 1
  root="$(/bin/realpath "$root")" || return 1
  : >"$output" || return 1
  candidate_list="$output.candidates.$$"
  { /usr/bin/printf '%s\0' "$root"; /usr/bin/find -s "$root" -mindepth 1 -print0; } \
    >"$candidate_list" || return 1
  while IFS= read -r -d '' candidate; do
    relative="${candidate#"$root"}"
    relative="${relative#/}"
    [[ -n "$relative" ]] || relative=.
    [[ "$relative" != *$'\n'* && "$relative" != *$'\t'* ]] || return 1
    mode="$(/usr/bin/stat -f '%Lp' "$candidate")" || return 1
    if [[ -L "$candidate" ]]; then
      target="$(/usr/bin/readlink "$candidate")" || return 1
      [[ "$target" != *$'\n'* && "$target" != *$'\t'* ]] || return 1
      [[ "$target" != /* ]] || return 1
      resolved_target="$(/bin/realpath "$candidate" 2>/dev/null)" || return 1
      case "$resolved_target" in
        "$root"/*) ;;
        *) return 1 ;;
      esac
      /usr/bin/printf 'link\t%s\t%s\t%s\n' "$mode" "$relative" "$target" >>"$output"
    elif [[ -f "$candidate" ]]; then
      size="$(/usr/bin/stat -f '%z' "$candidate")" || return 1
      file_sha="$(r1_sha256_file "$candidate")" || return 1
      [[ "$file_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
      /usr/bin/printf 'file\t%s\t%s\t%s\t%s\n' \
        "$mode" "$size" "$file_sha" "$relative" >>"$output"
    elif [[ -d "$candidate" ]]; then
      /usr/bin/printf 'directory\t%s\t%s\n' "$mode" "$relative" >>"$output"
    else
      return 1
    fi
    xattr_names="$(/usr/bin/xattr "$candidate" 2>/dev/null)" || return 1
    while IFS= read -r xattr_name; do
      [[ -n "$xattr_name" ]] || continue
      [[ "$xattr_name" != *$'\n'* && "$xattr_name" != *$'\t'* ]] || return 1
      xattr_value="$(/usr/bin/xattr -px "$xattr_name" "$candidate" 2>/dev/null)" || return 1
      xattr_value="$(/usr/bin/printf '%s' "$xattr_value" | /usr/bin/tr -d '[:space:]')"
      [[ "$xattr_value" =~ ^([0-9a-fA-F][0-9a-fA-F])*$ ]] || return 1
      xattr_value="$(/usr/bin/printf '%s' "$xattr_value" | /usr/bin/tr '[:upper:]' '[:lower:]')"
      /usr/bin/printf 'xattr\t%s\t%s\t%s\n' \
        "$relative" "$xattr_name" "$xattr_value" >>"$output"
    done < <(/usr/bin/printf '%s\n' "$xattr_names" | LC_ALL=C /usr/bin/sort)
  done <"$candidate_list"
  /bin/rm -f "${candidate_list:?}"
}

r1_tree_sha256() {
  local root="$1"
  local inventory="$2"

  r1_canonical_tree_inventory "$root" "$inventory" || return 1
  r1_sha256_file "$inventory"
}

r1_manifest_value() {
  local manifest="$1"
  local key="$2"
  local count
  local value

  count="$(/usr/bin/awk -F= -v key="$key" '$1 == key { count += 1 } END { print count + 0 }' "$manifest")"
  [[ "$count" == 1 ]] || return 1
  value="$(/usr/bin/awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$manifest")"
  [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\t'* ]] || return 1
  /usr/bin/printf '%s\n' "$value"
}

# Chooses notarytool credentials. Tries the Keychain profile first; only when
# notarytool says the profile is missing does it fall back to the App Store
# Connect API key from IDLESCREEN_ASC_KEY_PATH, IDLESCREEN_ASC_KEY_ID and
# IDLESCREEN_ASC_ISSUER_ID. Sets r1_notary_auth to the credential arguments for
# every later notarytool call. Secret values are never printed.
# Usage: r1_resolve_notary_auth <profile> <scratch-dir> <notarytool command...>
# Returns 0 on success, 1 when no credential works, 2 when the Keychain profile
# exists but notarytool failed for another reason (no fallback in that case).
r1_notary_auth=()
r1_resolve_notary_auth() {
  local profile="$1"
  local scratch="$2"
  shift 2
  local history_out="$scratch/notary-history.json"
  local history_err="$scratch/notary-history.err"
  local key_path="${IDLESCREEN_ASC_KEY_PATH:-}"
  local key_id="${IDLESCREEN_ASC_KEY_ID:-}"
  local issuer_id="${IDLESCREEN_ASC_ISSUER_ID:-}"

  r1_notary_auth=(--keychain-profile "$profile")
  if "$@" history "${r1_notary_auth[@]}" --output-format json \
    >"$history_out" 2>"$history_err"; then
    return 0
  fi
  if ! /usr/bin/grep -Eiq 'no keychain password item|profile.*(not found|does not exist|missing)|could not find.*profile' "$history_err"; then
    return 2
  fi

  echo "notarytool Keychain profile '$profile' is missing; trying the App Store Connect API key." >&2
  if [[ -z "$key_path" || -z "$key_id" || -z "$issuer_id" ]]; then
    echo "Neither credential is usable: the Keychain profile is missing and IDLESCREEN_ASC_KEY_PATH, IDLESCREEN_ASC_KEY_ID and IDLESCREEN_ASC_ISSUER_ID are not all set." >&2
    return 1
  fi
  if [[ ! -f "$key_path" || -L "$key_path" || ! -r "$key_path" ]]; then
    echo "Neither credential is usable: IDLESCREEN_ASC_KEY_PATH is not a readable regular file." >&2
    return 1
  fi
  if [[ ! "$key_id" =~ ^[A-Za-z0-9]{10}$ ||
    ! "$issuer_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    echo "Neither credential is usable: IDLESCREEN_ASC_KEY_ID or IDLESCREEN_ASC_ISSUER_ID is malformed." >&2
    return 1
  fi
  r1_notary_auth=(--key "$key_path" --key-id "$key_id" --issuer "$issuer_id")
  if "$@" history "${r1_notary_auth[@]}" --output-format json \
    >"$history_out" 2>"$history_err"; then
    return 0
  fi
  echo "Neither credential is usable: the App Store Connect API key was rejected by notarytool." >&2
  return 1
}
