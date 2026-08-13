#!/bin/bash
# shellcheck disable=SC2317

set -euo pipefail

script_root="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_root/.." && pwd)"
builder="$script_root/build-r1-release-candidate.sh"
verifier="$script_root/verify-r1-release-candidate.sh"
fixture_root="$(mktemp -d /tmp/idlescreen-r1-release-fixtures.XXXXXX)"
trap '/bin/rm -rf "${fixture_root:?}"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

append_event() {
  /usr/bin/printf '%s\n' "$1" >>"$IDLESCREEN_FIXTURE_EVENT_LOG"
}

fixture_product_name() {
  case "$1" in
    *.dmg) echo dmg ;;
    */IdleScreenRenderer.framework) echo renderer ;;
    */IdleScreenScreenSaver.appex) echo extension ;;
    */IdleScreenCameraAgent.app) echo helper ;;
    */idlescreenctl) echo control-tool ;;
    */IdleScreen.app) echo app ;;
    *) return 1 ;;
  esac
}

fixture_identifier() {
  case "$1" in
    dmg) echo com.idlescreen.app.dmg ;;
    renderer) echo com.idlescreen.renderer ;;
    extension) echo com.idlescreen.app.screensaver ;;
    helper) echo com.idlescreen.camera-agent ;;
    control-tool) echo com.idlescreen.ctl ;;
    app) echo com.idlescreen.app ;;
    *) return 1 ;;
  esac
}

fixture_cdhash() {
  case "$1" in
    app) /usr/bin/printf '11%.0s' {1..20} ;;
    extension) /usr/bin/printf '22%.0s' {1..20} ;;
    helper) /usr/bin/printf '33%.0s' {1..20} ;;
    renderer) /usr/bin/printf '44%.0s' {1..20} ;;
    control-tool) /usr/bin/printf '55%.0s' {1..20} ;;
    dmg) /usr/bin/printf '66%.0s' {1..20} ;;
    *) return 1 ;;
  esac
}

mock_git_main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -C) shift 2 ;;
      status)
        if [[ "${IDLESCREEN_FIXTURE_SOURCE_MUTATED:-}" == YES ]] &&
           [[ -f "$IDLESCREEN_FIXTURE_EVENT_LOG" ]] &&
           /usr/bin/grep -Fqx c3-archive "$IDLESCREEN_FIXTURE_EVENT_LOG"; then
          echo ' M project.yml'
        fi
        exit 0
        ;;
      rev-parse)
        shift
        if [[ "${1:-}" == 'HEAD^{tree}' ]]; then
          /usr/bin/printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
        else
          /usr/bin/printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
        fi
        exit 0
        ;;
      diff)
        exit 0
        ;;
      *) shift ;;
    esac
  done
  exit 1
}

mock_security_main() {
  if [[ " $* " == *' find-identity '* ]]; then
    append_event security-identity-preflight
    /usr/bin/printf '  1) %s "Developer ID Application: Fixture Developer (3524374A2S)"\n     1 valid identities found\n' \
      "$IDLESCREEN_DEVELOPER_IDENTITY_SHA1"
    return
  fi
  if [[ " $* " == *' cms '* ]]; then
    local input=""
    local output=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -i) shift; input="$1" ;;
        -o) shift; output="$1" ;;
      esac
      shift
    done
    [[ -n "$input" && -n "$output" ]] || return 1
    append_event "profile-$(${IDLESCREEN_REAL_BASENAME:-/usr/bin/basename} "$input" .provisionprofile)"
    /bin/cp "$input" "$output"
    return
  fi
  return 1
}

mock_c3_builder_main() {
  [[ $# -eq 1 ]] || return 64
  [[ "${IDLESCREEN_ALLOW_SIGNING_CREDENTIAL_UPDATES:-}" == NO ]] || return 1
  local output="$1"
  local archive="$output/IdleScreenC3Release.xcarchive"
  local app="$archive/Products/Applications/IdleScreen.app"
  local extension="$app/Contents/PlugIns/IdleScreenScreenSaver.appex"
  local helper="$app/Contents/Helpers/IdleScreenCameraAgent.app"
  local renderer="$app/Contents/Frameworks/IdleScreenRenderer.framework"

  append_event c3-archive
  /bin/mkdir -p \
    "$app/Contents/MacOS" \
    "$extension/Contents/MacOS" \
    "$helper/Contents/MacOS" \
    "$renderer/Versions/A/Resources" \
    "$app/Contents/Library/LaunchAgents"
  /usr/bin/plutil -create xml1 "$archive/Info.plist"
  /usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string com.idlescreen.app "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleShortVersionString -string 0.1 "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleVersion -string "${IDLESCREEN_FIXTURE_BUILD_VERSION:-61}" "$app/Contents/Info.plist"
  /usr/bin/printf fixture >"$archive/.fixture-c3-archive"
  /usr/bin/printf app >"$app/Contents/MacOS/IdleScreen"
  /usr/bin/printf extension >"$extension/Contents/MacOS/IdleScreenScreenSaver"
  /usr/bin/printf helper >"$helper/Contents/MacOS/IdleScreenCameraAgent"
  /usr/bin/printf renderer >"$renderer/Versions/A/IdleScreenRenderer"
  /bin/ln -s Versions/Current/IdleScreenRenderer "$renderer/IdleScreenRenderer"
  /bin/ln -s Versions/Current/Resources "$renderer/Resources"
  /bin/ln -s A "$renderer/Versions/Current"
  /usr/bin/printf control >"$app/Contents/Helpers/idlescreenctl"
  /bin/chmod 755 \
    "$app/Contents/MacOS/IdleScreen" \
    "$extension/Contents/MacOS/IdleScreenScreenSaver" \
    "$helper/Contents/MacOS/IdleScreenCameraAgent" \
    "$renderer/Versions/A/IdleScreenRenderer" \
    "$app/Contents/Helpers/idlescreenctl"
  {
    echo 'schema=IdleScreenReleaseArchiveProvenance/v1'
    echo 'verification_mode=release'
    echo 'archive_tree_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
  } >"$output/IdleScreenC3ReleaseProvenanceV1.txt"
}

mock_c3_verifier_main() {
  [[ $# -eq 3 && "$3" == 3524374A2S ]] || return 64
  local archive="$1"
  local output="$2"
  append_event c3-provenance-replay
  [[ "${IDLESCREEN_FIXTURE_C3_REPLAY_FAILURE:-}" != YES ]] || return 1
  [[ -f "$archive/.fixture-c3-archive" && ! -e "$output" ]] || return 1
  /bin/cp "$(/usr/bin/dirname "$archive")/IdleScreenC3ReleaseProvenanceV1.txt" "$output"
}

mock_codesign_main() {
  local product_path="${!#}"
  local product_name
  local identifier
  local certificate_prefix=""
  local argument

  product_name="$(fixture_product_name "$product_path")" || return 1
  identifier="$(fixture_identifier "$product_name")"

  if [[ " $* " == *' --sign '* ]]; then
    case "$product_name" in
      renderer)
        [[ $# -eq 7 && "$1" == --force && "$2" == --sign &&
           "$3" == "$IDLESCREEN_DEVELOPER_IDENTITY_SHA1" && "$4" == --timestamp &&
           "$5" == --options && "$6" == runtime ]] || return 1
        ;;
      extension)
        [[ $# -eq 9 && "$1" == --force && "$2" == --sign &&
           "$3" == "$IDLESCREEN_DEVELOPER_IDENTITY_SHA1" && "$4" == --timestamp &&
           "$5" == --options && "$6" == runtime && "$7" == --entitlements &&
           "$8" == "$IDLESCREEN_FIXTURE_PROJECT_ROOT/Products/IdleScreenScreenSaver/IdleScreenScreenSaverDeveloperID.entitlements" ]] || return 1
        ;;
      helper)
        [[ $# -eq 9 && "$1" == --force && "$2" == --sign &&
           "$3" == "$IDLESCREEN_DEVELOPER_IDENTITY_SHA1" && "$4" == --timestamp &&
           "$5" == --options && "$6" == runtime && "$7" == --entitlements &&
           "$8" == "$IDLESCREEN_FIXTURE_PROJECT_ROOT/Sources/IdleScreenCameraAgent/IdleScreenCameraAgentDeveloperID.entitlements" ]] || return 1
        ;;
      control-tool)
        [[ $# -eq 11 && "$1" == --force && "$2" == --sign &&
           "$3" == "$IDLESCREEN_DEVELOPER_IDENTITY_SHA1" && "$4" == --timestamp &&
           "$5" == --options && "$6" == runtime && "$7" == --identifier &&
           "$8" == com.idlescreen.ctl && "$9" == --entitlements &&
           "${10}" == "$IDLESCREEN_FIXTURE_PROJECT_ROOT/Products/IdleScreenAgentExecutable/idlescreenctl-DeveloperID.entitlements" ]] || return 1
        ;;
      app)
        [[ $# -eq 9 && "$1" == --force && "$2" == --sign &&
           "$3" == "$IDLESCREEN_DEVELOPER_IDENTITY_SHA1" && "$4" == --timestamp &&
           "$5" == --options && "$6" == runtime && "$7" == --entitlements &&
           "$8" == "$IDLESCREEN_FIXTURE_PROJECT_ROOT/Products/IdleScreenApp/IdleScreenDeveloperID.entitlements" ]] || return 1
        ;;
      dmg)
        [[ $# -eq 7 && "$1" == --force && "$2" == --sign &&
           "$3" == "$IDLESCREEN_DEVELOPER_IDENTITY_SHA1" && "$4" == --timestamp &&
           "$5" == --identifier && "$6" == com.idlescreen.app.dmg ]] || return 1
        ;;
      *) return 1 ;;
    esac
    append_event "sign-$product_name"
    return
  fi
  if [[ "${1:-}" == -R=* ]]; then
    [[ $# -eq 4 && "$2" == --verify && "$3" == --strict ]] || return 1
    [[ "$1" == "-R=identifier \"$identifier\" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"3524374A2S\"" ]] ||
      return 1
    append_event "requirement-$product_name"
    return
  fi
  if [[ " $* " == *' --verify '* ]]; then
    append_event "codesign-verify-$product_name"
    [[ "${IDLESCREEN_FIXTURE_CODESIGN_FAILURE:-}" != "$product_name" ]]
    return
  fi
  if [[ " $* " == *' --entitlements '* ]]; then
    if [[ "${IDLESCREEN_FIXTURE_GET_TASK_ALLOW:-}" == "$product_name" ]]; then
      /bin/cat "$IDLESCREEN_FIXTURE_BAD_ENTITLEMENTS"
    else
      case "$product_name" in
        app) /bin/cat "$IDLESCREEN_FIXTURE_PROJECT_ROOT/Products/IdleScreenApp/IdleScreenDeveloperID.entitlements" ;;
        extension) /bin/cat "$IDLESCREEN_FIXTURE_PROJECT_ROOT/Products/IdleScreenScreenSaver/IdleScreenScreenSaverDeveloperID.entitlements" ;;
        helper) /bin/cat "$IDLESCREEN_FIXTURE_PROJECT_ROOT/Sources/IdleScreenCameraAgent/IdleScreenCameraAgentDeveloperID.entitlements" ;;
        control-tool) /bin/cat "$IDLESCREEN_FIXTURE_PROJECT_ROOT/Products/IdleScreenAgentExecutable/idlescreenctl-DeveloperID.entitlements" ;;
        *) return 1 ;;
      esac
    fi
    return
  fi
  for argument in "$@"; do
    case "$argument" in
      --extract-certificates=*) certificate_prefix="${argument#*=}" ;;
    esac
  done
  if [[ -n "$certificate_prefix" ]]; then
    if [[ "${IDLESCREEN_FIXTURE_SIGNER_MISMATCH:-}" == "$product_name" ]]; then
      /bin/cp "$IDLESCREEN_FIXTURE_OTHER_CERT" "${certificate_prefix}0"
    else
      /bin/cp "$IDLESCREEN_FIXTURE_CERT" "${certificate_prefix}0"
    fi
    return
  fi
  if [[ " $* " == *' -dv '* || " $* " == *' --verbose=4 '* ]]; then
    local authority='Developer ID Application: Fixture Developer (3524374A2S)'
    [[ "${IDLESCREEN_FIXTURE_AUTHORITY:-}" != apple-development ]] ||
      authority='Apple Development: Fixture Developer (3524374A2S)'
    /usr/bin/printf 'Executable=%s\nIdentifier=%s\n' "$product_path" "$identifier" >&2
    if [[ "${IDLESCREEN_FIXTURE_NO_RUNTIME:-}" == "$product_name" ]]; then
      /usr/bin/printf 'CodeDirectory v=20500 size=100 flags=0x0(none) hashes=1+1 location=embedded\n' >&2
    else
      /usr/bin/printf 'CodeDirectory v=20500 size=100 flags=0x10000(runtime) hashes=1+1 location=embedded\n' >&2
    fi
    /usr/bin/printf 'Signature size=4000\nAuthority=%s\nAuthority=Developer ID Certification Authority\nAuthority=Apple Root CA\n' "$authority" >&2
    /usr/bin/printf 'TeamIdentifier=3524374A2S\nCDHash=%s\n' "$(fixture_cdhash "$product_name")" >&2
    if [[ "${IDLESCREEN_FIXTURE_NO_TIMESTAMP:-}" != "$product_name" ]]; then
      /usr/bin/printf 'Timestamp=Aug 11, 2026 at 20:00:00\n' >&2
    fi
    return
  fi
  return 1
}

mock_product_verifier_main() {
  [[ $# -eq 2 && "$1" == */IdleScreen.app && "$2" == Release ]] || return 1
  append_event product-contracts
}

mock_signing_verifier_main() {
  [[ $# -eq 2 && "$1" == */IdleScreen.app && "$2" == 3524374A2S ]] || return 1
  append_event provisioning-contracts
}

mock_hdiutil_main() {
  local operation="${1:-}"
  shift || true
  case "$operation" in
    create)
      [[ $# -eq 8 && "$1" == -srcfolder && -d "$2" && "$3" == -format &&
         "$4" == UDZO && "$5" == -volname && "$6" == idlescreen &&
         "$7" == -o && "$8" == *.dmg ]] || return 1
      local source="$2"
      local output="$8"
      append_event create-dmg
      /bin/rm -rf "${IDLESCREEN_FIXTURE_MOUNT_ROOT:?}"
      /bin/mkdir -p "$IDLESCREEN_FIXTURE_MOUNT_ROOT"
      /usr/bin/ditto "$source" "$IDLESCREEN_FIXTURE_MOUNT_ROOT"
      while IFS= read -r -d '' embedded_profile; do
        if /usr/bin/xattr -p com.apple.quarantine "$embedded_profile" >/dev/null 2>&1; then
          /usr/bin/xattr -w com.apple.quarantine \
            '0081;fixture-packaged;;fixture' "$embedded_profile"
        fi
      done < <(/usr/bin/find "$IDLESCREEN_FIXTURE_MOUNT_ROOT/IdleScreen.app" \
        -name embedded.provisionprofile -type f -print0)
      /usr/bin/printf 'fixture signed disk image before stapling\n' >"$output"
      ;;
    verify)
      [[ $# -eq 1 && "$1" == *.dmg ]] || return 1
      append_event verify-dmg
      ;;
    attach)
      [[ $# -eq 4 && "$1" == -readonly && "$2" == -nobrowse && "$3" == -plist && "$4" == *.dmg ]] || return 1
      append_event attach-readonly-dmg
      if [[ "${IDLESCREEN_FIXTURE_MOUNT_DRIFT:-}" == YES ]]; then
        /usr/bin/printf drift >"$IDLESCREEN_FIXTURE_MOUNT_ROOT/IdleScreen.app/Contents/drift"
      fi
      if [[ "${IDLESCREEN_FIXTURE_MOUNT_XATTR_DRIFT:-}" == YES ]]; then
        /usr/bin/xattr -w com.idlescreen.fixture drift "$IDLESCREEN_FIXTURE_MOUNT_ROOT/IdleScreen.app"
      fi
      /usr/bin/printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
        "<plist version=\"1.0\"><dict><key>system-entities</key><array><dict><key>dev-entry</key><string>/dev/disk99</string><key>mount-point</key><string>$IDLESCREEN_FIXTURE_MOUNT_ROOT</string></dict></array></dict></plist>"
      ;;
    detach)
      [[ $# -eq 1 && "$1" == /dev/disk99 ]] || return 1
      append_event detach-dmg
      ;;
    *) return 1 ;;
  esac
}

mock_notarytool_main() {
  local operation="${1:-}"
  shift || true
  case "$operation" in
    history)
      [[ "$*" == '--keychain-profile idlescreen-fixture --output-format json' ]] || return 1
      append_event notary-credential-preflight
      echo '{"history":[]}'
      ;;
    submit)
      [[ $# -eq 5 && "$2" == --keychain-profile && "$3" == idlescreen-fixture &&
         "$4" == --output-format && "$5" == json ]] || return 1
      append_event notary-submit
      /usr/bin/shasum -a 256 "${1:?}" | /usr/bin/awk '{ print $1 }' >"$IDLESCREEN_FIXTURE_EVENT_LOG.submitted-sha"
      echo '{"id":"11111111-2222-3333-4444-555555555555","message":"Successfully uploaded file"}'
      ;;
    wait)
      [[ $# -eq 7 && "$1" == 11111111-2222-3333-4444-555555555555 &&
         "$2" == --keychain-profile && "$3" == idlescreen-fixture &&
         "$4" == --timeout && "$5" == 30m && "$6" == --output-format && "$7" == json ]] || return 1
      append_event notary-wait
      if [[ "${IDLESCREEN_FIXTURE_NOTARY_WAIT_ID_MISMATCH:-}" == YES ]]; then
        echo '{"id":"99999999-2222-3333-4444-555555555555","status":"Accepted","message":"Processing complete"}'
      else
        echo '{"id":"11111111-2222-3333-4444-555555555555","status":"Accepted","message":"Processing complete"}'
      fi
      ;;
    log)
      [[ $# -eq 4 && "$1" == 11111111-2222-3333-4444-555555555555 &&
         "$2" == --keychain-profile && "$3" == idlescreen-fixture ]] || return 1
      append_event notary-log
      local output="${!#}"
      local issues=null
      [[ "${IDLESCREEN_FIXTURE_NOTARY_ISSUES:-}" != YES ]] ||
        issues='[{"severity":"warning","message":"fixture warning"}]'
      local job_id=11111111-2222-3333-4444-555555555555
      local submitted_sha
      submitted_sha="$(<"$IDLESCREEN_FIXTURE_EVENT_LOG.submitted-sha")"
      [[ "${IDLESCREEN_FIXTURE_NOTARY_LOG_ID_MISMATCH:-}" != YES ]] ||
        job_id=99999999-2222-3333-4444-555555555555
      /usr/bin/printf '{"jobId":"%s","status":"Accepted","statusSummary":"Ready for distribution","sha256":"%s","issues":%s}\n' \
        "$job_id" "$submitted_sha" "$issues" >"$output"
      ;;
    *) return 1 ;;
  esac
}

mock_stapler_main() {
  case "${1:-}" in
    staple)
      [[ $# -eq 2 && "$2" == *.dmg ]] || return 1
      append_event staple-dmg
      [[ "${IDLESCREEN_FIXTURE_STAPLER_FAILURE:-}" != YES ]] || return 1
      /usr/bin/printf 'stapled ticket\n' >>"${2:?}"
      ;;
    validate)
      [[ $# -eq 2 && "$2" == *.dmg ]] || return 1
      append_event validate-staple
      [[ "${IDLESCREEN_FIXTURE_STAPLER_FAILURE:-}" != YES ]]
      ;;
    *) return 1 ;;
  esac
}

mock_spctl_main() {
  local product_path="${!#}"
  local product_name
  product_name="$(fixture_product_name "$product_path")" || return 1
  case "$product_name" in
    dmg)
      [[ $# -eq 7 && "$1" == -a && "$2" == -t && "$3" == open &&
         "$4" == --context && "$5" == context:primary-signature && "$6" == -v ]] || return 1
      ;;
    app)
      [[ $# -eq 5 && "$1" == -a && "$2" == -t && "$3" == exec && "$4" == -vv ]] || return 1
      ;;
    *) return 1 ;;
  esac
  append_event "gatekeeper-$product_name"
  [[ "${IDLESCREEN_FIXTURE_SPCTL_FAILURE:-}" != "$product_name" ]]
}

case "$(/usr/bin/basename "$0")" in
  mock-git) mock_git_main "$@"; exit $? ;;
  mock-security) mock_security_main "$@"; exit $? ;;
  mock-c3-builder) mock_c3_builder_main "$@"; exit $? ;;
  mock-c3-verifier) mock_c3_verifier_main "$@"; exit $? ;;
  mock-codesign) mock_codesign_main "$@"; exit $? ;;
  mock-product-verifier) mock_product_verifier_main "$@"; exit $? ;;
  mock-signing-verifier) mock_signing_verifier_main "$@"; exit $? ;;
  mock-hdiutil) mock_hdiutil_main "$@"; exit $? ;;
  mock-notarytool) mock_notarytool_main "$@"; exit $? ;;
  mock-stapler) mock_stapler_main "$@"; exit $? ;;
  mock-spctl) mock_spctl_main "$@"; exit $? ;;
esac

[[ -x "$builder" ]] || fail "missing executable build-r1-release-candidate.sh"
[[ -x "$verifier" ]] || fail "missing executable verify-r1-release-candidate.sh"

mock_root="$fixture_root/mocks"
/bin/mkdir -p "$mock_root"
for mock_name in git security c3-builder c3-verifier codesign product-verifier signing-verifier hdiutil notarytool stapler spctl; do
  /bin/ln -s "$script_root/$(/usr/bin/basename "$0")" "$mock_root/mock-$mock_name"
done

identity_sha1=1234567890ABCDEF1234567890ABCDEF12345678
certificate="$fixture_root/developer-id.der"
other_certificate="$fixture_root/other-developer-id.der"
/usr/bin/printf 'fixture Developer ID certificate' >"$certificate"
/usr/bin/printf 'different fixture Developer ID certificate' >"$other_certificate"

make_profile() {
  local path="$1"
  local application_identifier="$2"
  local certificate_base64
  certificate_base64="$(/usr/bin/base64 <"$certificate" | /usr/bin/tr -d '\n')"
  /usr/bin/plutil -create xml1 "$path"
  /usr/bin/plutil -insert TeamIdentifier -array "$path"
  /usr/bin/plutil -insert TeamIdentifier.0 -string 3524374A2S "$path"
  /usr/bin/plutil -insert ProvisionsAllDevices -bool true "$path"
  /usr/bin/plutil -insert ExpirationDate -date '2035-01-01T00:00:00Z' "$path"
  /usr/bin/plutil -insert UUID -string 11111111-2222-3333-4444-555555555555 "$path"
  /usr/bin/plutil -insert DeveloperCertificates -array "$path"
  /usr/bin/plutil -insert DeveloperCertificates.0 -data "$certificate_base64" "$path"
  /usr/libexec/PlistBuddy \
    -c 'Add :Entitlements dict' \
    -c 'Add :Entitlements:com.apple.developer.team-identifier string 3524374A2S' \
    -c "Add :Entitlements:com.apple.application-identifier string 3524374A2S.$application_identifier" \
    -c 'Add :Entitlements:com.apple.security.application-groups array' \
    -c 'Add :Entitlements:com.apple.security.application-groups:0 string group.com.idlescreen.shared' \
    -c 'Add :Entitlements:get-task-allow bool false' \
    "$path"
  /usr/bin/xattr -w com.apple.quarantine \
    '0081;fixture-source;;fixture' "$path"
}

profile_root="$fixture_root/profiles"
/bin/mkdir -p "$profile_root"
make_profile "$profile_root/app.provisionprofile" com.idlescreen.app
make_profile "$profile_root/extension.provisionprofile" com.idlescreen.app.screensaver
make_profile "$profile_root/helper.provisionprofile" com.idlescreen.camera-agent

bad_entitlements="$fixture_root/get-task-allow.entitlements"
/bin/cp "$project_root/Products/IdleScreenApp/IdleScreenDeveloperID.entitlements" "$bad_entitlements" 2>/dev/null ||
  /usr/bin/plutil -create xml1 "$bad_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.get-task-allow bool true' "$bad_entitlements"

run_builder() {
  local output_root="$1"
  shift
  IDLESCREEN_R1_FIXTURE_MODE=YES \
  IDLESCREEN_ALLOW_REAL_DISTRIBUTION=YES \
  IDLESCREEN_DEVELOPER_IDENTITY_SHA1="$identity_sha1" \
  IDLESCREEN_DEVELOPER_ID_APP_PROFILE="$profile_root/app.provisionprofile" \
  IDLESCREEN_DEVELOPER_ID_EXTENSION_PROFILE="$profile_root/extension.provisionprofile" \
  IDLESCREEN_DEVELOPER_ID_HELPER_PROFILE="$profile_root/helper.provisionprofile" \
  IDLESCREEN_NOTARY_KEYCHAIN_PROFILE=idlescreen-fixture \
  IDLESCREEN_R1_GIT="$mock_root/mock-git" \
  IDLESCREEN_R1_SECURITY="$mock_root/mock-security" \
  IDLESCREEN_R1_C3_BUILDER="$mock_root/mock-c3-builder" \
  IDLESCREEN_R1_C3_VERIFIER="$mock_root/mock-c3-verifier" \
  IDLESCREEN_R1_CODESIGN="$mock_root/mock-codesign" \
  IDLESCREEN_R1_PRODUCT_VERIFIER="$mock_root/mock-product-verifier" \
  IDLESCREEN_R1_SIGNING_VERIFIER="$mock_root/mock-signing-verifier" \
  IDLESCREEN_R1_HDIUTIL="$mock_root/mock-hdiutil" \
  IDLESCREEN_R1_NOTARYTOOL="$mock_root/mock-notarytool" \
  IDLESCREEN_R1_STAPLER="$mock_root/mock-stapler" \
  IDLESCREEN_R1_SPCTL="$mock_root/mock-spctl" \
  IDLESCREEN_FIXTURE_CERT="$certificate" \
  IDLESCREEN_FIXTURE_OTHER_CERT="$other_certificate" \
  IDLESCREEN_FIXTURE_BAD_ENTITLEMENTS="$bad_entitlements" \
  IDLESCREEN_FIXTURE_PROJECT_ROOT="$project_root" \
  IDLESCREEN_FIXTURE_MOUNT_ROOT="$fixture_root/mount-$(${IDLESCREEN_REAL_BASENAME:-/usr/bin/basename} "$output_root")" \
  IDLESCREEN_FIXTURE_EVENT_LOG="$fixture_root/events-$(${IDLESCREEN_REAL_BASENAME:-/usr/bin/basename} "$output_root").txt" \
  "$@" "$builder" "$output_root"
}

run_fixture_verifier() {
  local mount_root="$1"
  shift
  IDLESCREEN_R1_FIXTURE_MODE=YES \
  IDLESCREEN_R1_CODESIGN="$mock_root/mock-codesign" \
  IDLESCREEN_R1_SECURITY="$mock_root/mock-security" \
  IDLESCREEN_R1_C3_VERIFIER="$mock_root/mock-c3-verifier" \
  IDLESCREEN_R1_PRODUCT_VERIFIER="$mock_root/mock-product-verifier" \
  IDLESCREEN_R1_SIGNING_VERIFIER="$mock_root/mock-signing-verifier" \
  IDLESCREEN_R1_HDIUTIL="$mock_root/mock-hdiutil" \
  IDLESCREEN_R1_STAPLER="$mock_root/mock-stapler" \
  IDLESCREEN_R1_SPCTL="$mock_root/mock-spctl" \
  IDLESCREEN_FIXTURE_CERT="$certificate" \
  IDLESCREEN_FIXTURE_OTHER_CERT="$other_certificate" \
  IDLESCREEN_FIXTURE_BAD_ENTITLEMENTS="$bad_entitlements" \
  IDLESCREEN_FIXTURE_PROJECT_ROOT="$project_root" \
  IDLESCREEN_FIXTURE_MOUNT_ROOT="$mount_root" \
  IDLESCREEN_FIXTURE_EVENT_LOG="$fixture_root/replay-events.txt" \
  "$verifier" "$@"
}

expect_builder_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  local output="$fixture_root/$name"
  local result
  if result="$(run_builder "$output" "$@" 2>&1)"; then
    fail "$name unexpectedly passed"
  fi
  /usr/bin/grep -Fq "$expected" <<<"$result" ||
    fail "$name failed for the wrong reason: $result"
  [[ ! -e "$output/IdleScreenR1ReleaseCandidateV1.txt" ]] ||
    fail "$name left a trusted-looking candidate manifest"
  echo "PASS: $name fails closed"
}

valid_output="$fixture_root/valid-candidate"
run_builder "$valid_output" /usr/bin/env >/dev/null || fail "valid mocked Developer ID pipeline was rejected"
manifest="$valid_output/IdleScreenR1ReleaseCandidateV1.txt"
dmg="$valid_output/Distribution/idlescreen-0.1-build61.dmg"
[[ -f "$manifest" && -f "$dmg" ]] || fail "valid pipeline did not publish the DMG and manifest"
[[ "$(/usr/bin/find "$valid_output/Distribution" -mindepth 1 -maxdepth 1 -print | /usr/bin/awk 'END { print NR + 0 }')" == 1 ]] ||
  fail "published Distribution directory contains more than the verified DMG"
for field in \
  'schema=IdleScreenR1ReleaseCandidate/v1' \
  'verification_mode=fixture' \
  'source_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'source_tree=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'source_clean=true' \
  'team_identifier=3524374A2S' \
  'dmg_signing_identifier=com.idlescreen.app.dmg' \
  'notary_submission_id=11111111-2222-3333-4444-555555555555' \
  'notary_status=Accepted' \
  'notary_issue_count=0' \
  'stapler_status=valid' \
  'dmg_gatekeeper_status=accepted' \
  'mounted_app_gatekeeper_status=accepted'; do
  /usr/bin/grep -Fqx "$field" "$manifest" || fail "candidate manifest is missing $field"
done
for hash_field in \
  c3_manifest_sha256 distribution_app_tree_sha256 developer_id_certificate_sha256 \
  submitted_dmg_sha256 notary_log_sha256 stapled_dmg_sha256; do
  /usr/bin/grep -Eq "^$hash_field=[0-9a-f]{64}$" "$manifest" ||
    fail "candidate manifest has no exact $hash_field"
done

events="$fixture_root/events-valid-candidate.txt"
previous_line=0
for expected_event in \
  security-identity-preflight profile-app profile-extension profile-helper \
  notary-credential-preflight c3-archive c3-provenance-replay sign-renderer sign-extension sign-helper \
  sign-control-tool sign-app product-contracts provisioning-contracts create-dmg \
  sign-dmg verify-dmg notary-submit notary-wait notary-log staple-dmg \
  validate-staple gatekeeper-dmg attach-readonly-dmg gatekeeper-app detach-dmg; do
  event_line="$(/usr/bin/awk -v event="$expected_event" '$0 == event { print NR; exit }' "$events")"
  [[ "$event_line" =~ ^[1-9][0-9]*$ && "$event_line" -gt "$previous_line" ]] ||
    fail "release operation order drifted at $expected_event"
  previous_line="$event_line"
done
echo 'PASS: valid mocked Developer ID workflow is exact, ordered, and evidence-bound'

expect_builder_failure apple-development-authority 'Developer ID Application' \
  /usr/bin/env IDLESCREEN_FIXTURE_AUTHORITY=apple-development
expect_builder_failure nested-signer-mismatch 'one exact Developer ID signing certificate' \
  /usr/bin/env IDLESCREEN_FIXTURE_SIGNER_MISMATCH=extension
expect_builder_failure dmg-signer-mismatch 'DMG signer does not match the app signer' \
  /usr/bin/env IDLESCREEN_FIXTURE_SIGNER_MISMATCH=dmg
expect_builder_failure missing-secure-timestamp 'secure timestamp' \
  /usr/bin/env IDLESCREEN_FIXTURE_NO_TIMESTAMP=helper
expect_builder_failure missing-hardened-runtime 'hardened runtime' \
  /usr/bin/env IDLESCREEN_FIXTURE_NO_RUNTIME=renderer
expect_builder_failure get-task-allow-entitlement 'signed entitlements are not exact' \
  /usr/bin/env IDLESCREEN_FIXTURE_GET_TASK_ALLOW=app
expect_builder_failure notarization-warning 'notarization log contains issues' \
  /usr/bin/env IDLESCREEN_FIXTURE_NOTARY_ISSUES=YES
expect_builder_failure notary-wait-id-mismatch 'notary wait returned a different submission identifier' \
  /usr/bin/env IDLESCREEN_FIXTURE_NOTARY_WAIT_ID_MISMATCH=YES
expect_builder_failure notary-log-id-mismatch 'notarization log does not match the accepted submission' \
  /usr/bin/env IDLESCREEN_FIXTURE_NOTARY_LOG_ID_MISMATCH=YES
expect_builder_failure source-mutated-during-build 'source changed during release construction' \
  /usr/bin/env IDLESCREEN_FIXTURE_SOURCE_MUTATED=YES
expect_builder_failure c3-replay-failure 'C3 provenance replay rejected the retained archive' \
  /usr/bin/env IDLESCREEN_FIXTURE_C3_REPLAY_FAILURE=YES
expect_builder_failure colliding-build-number 'greater than baseline build 60' \
  /usr/bin/env IDLESCREEN_FIXTURE_BUILD_VERSION=60
expect_builder_failure inherited-credential-updates 'forbids signing credential or provisioning updates' \
  /usr/bin/env IDLESCREEN_ALLOW_SIGNING_CREDENTIAL_UPDATES=YES
expect_builder_failure nested-c3-override 'forbids inherited nested C3 provenance command overrides' \
  /usr/bin/env IDLESCREEN_PROVENANCE_FIXTURE_MODE=YES
expect_builder_failure staple-failure 'could not staple the accepted notarization ticket' \
  /usr/bin/env IDLESCREEN_FIXTURE_STAPLER_FAILURE=YES
expect_builder_failure dmg-gatekeeper-failure 'Gatekeeper rejected the stapled DMG' \
  /usr/bin/env IDLESCREEN_FIXTURE_SPCTL_FAILURE=dmg
expect_builder_failure mounted-app-drift 'mounted app tree differs' \
  /usr/bin/env IDLESCREEN_FIXTURE_MOUNT_DRIFT=YES
expect_builder_failure mounted-app-xattr-drift 'mounted app tree differs' \
  /usr/bin/env IDLESCREEN_FIXTURE_MOUNT_XATTR_DRIFT=YES

bad_profile_root="$fixture_root/bad-profiles"
/bin/mkdir -p "$bad_profile_root"
/bin/cp "$profile_root/app.provisionprofile" "$bad_profile_root/app.provisionprofile"
/usr/bin/plutil -replace ProvisionsAllDevices -bool false "$bad_profile_root/app.provisionprofile"
original_profile_root="$profile_root"
profile_root="$bad_profile_root"
/bin/cp "$original_profile_root/extension.provisionprofile" "$profile_root/extension.provisionprofile"
/bin/cp "$original_profile_root/helper.provisionprofile" "$profile_root/helper.provisionprofile"
expect_builder_failure development-profile 'not a Developer ID distribution profile' /usr/bin/env
profile_root="$original_profile_root"

notary_log="$valid_output/Evidence/notary-log.json"
notary_log_backup="$fixture_root/notary-log-backup.json"
notary_replay_manifest="$valid_output/notary-replay-manifest.txt"
/bin/cp "$notary_log" "$notary_log_backup"
replay_submitted_sha="$(/usr/bin/awk -F= '$1 == "submitted_dmg_sha256" { print $2 }' "$manifest")"
/usr/bin/printf '%s\n' \
  "{\"jobId\":\"99999999-2222-3333-4444-555555555555\",\"status\":\"Accepted\",\"statusSummary\":\"Ready for distribution\",\"sha256\":\"$replay_submitted_sha\",\"issues\":[]}" \
  >"$notary_log"
/bin/cp "$manifest" "$notary_replay_manifest"
notary_log_sha="$(/usr/bin/shasum -a 256 "$notary_log" | /usr/bin/awk '{ print $1 }')"
/usr/bin/sed -i '' "s/^notary_log_sha256=.*/notary_log_sha256=$notary_log_sha/" "$notary_replay_manifest"
if run_fixture_verifier "$fixture_root/mount-valid-candidate" \
  "$dmg" "$notary_replay_manifest" >"$fixture_root/notary-replay.txt" 2>&1; then
  fail "final verifier accepted a notary log from a different submission"
fi
/bin/cp "$notary_log_backup" "$notary_log"
/usr/bin/grep -Fq 'notary log does not match the recorded submission' \
  "$fixture_root/notary-replay.txt" ||
  fail "notary replay failed for the wrong reason: $(<"$fixture_root/notary-replay.txt")"

override_output="$fixture_root/override-output.txt"
if IDLESCREEN_R1_CODESIGN="$mock_root/mock-codesign" \
   IDLESCREEN_FIXTURE_EVENT_LOG="$fixture_root/override-events.txt" \
   "$verifier" "$dmg" "$manifest" >"$override_output" 2>&1; then
  fail "real verifier accepted a command override without fixture mode"
fi
/usr/bin/grep -Fq 'command overrides require explicit fixture mode' "$override_output" ||
  fail "real verifier rejected override for the wrong reason"

if "$verifier" "$dmg" "$manifest" >"$fixture_root/fixture-replay.txt" 2>&1; then
  fail "real verifier accepted fixture-only release evidence"
fi
/usr/bin/grep -Fq 'trusted verification requires verification_mode=release' \
  "$fixture_root/fixture-replay.txt" || fail "fixture evidence was rejected for the wrong reason"

echo 'PASS: Developer ID release-candidate fixtures cover identity, profiles, notarization, stapling, Gatekeeper, and exact mounted bytes.'
