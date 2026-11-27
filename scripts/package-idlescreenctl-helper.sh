#!/bin/bash
# Reshapes the control tool inside a staged IdleScreen.app for Developer ID
# signing. Usage:
#   package-idlescreenctl-helper.sh APP APP_PROFILE [SHIM_BUILDER]
#
# The archive holds Contents/Helpers/idlescreenctl as a bare Mach-O with
# restricted entitlements. AMFI kills that at launch (Code=-413 No matching
# profile found) because a bare binary can't carry a provisioning profile. This
# moves it into Contents/Helpers/IdleScreenCtl.app (com.idlescreen.app.ctl) with
# the app's Developer ID profile, and leaves an entitlement-free launcher shim at
# the original path so hooks already written into agent settings keep working.
# Signing is the caller's job: the bundle first, then the shim, then the app.

set -euo pipefail

script_root="$(cd "$(dirname "$0")" && pwd)"

[[ $# -eq 2 || $# -eq 3 ]] || {
  echo "Usage: $0 APP APP_PROFILE [SHIM_BUILDER]" >&2
  exit 64
}
app="$1"
app_profile="$2"
shim_builder="${3:-$script_root/build-idlescreenctl-shim.sh}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

control_tool="$app/Contents/Helpers/idlescreenctl"
control_bundle="$app/Contents/Helpers/IdleScreenCtl.app"
[[ -d "$app" && ! -L "$app" ]] || fail "missing app: $app"
[[ -f "$control_tool" && ! -L "$control_tool" ]] || fail "missing bare control tool: $control_tool"
[[ ! -e "$control_bundle" ]] || fail "control tool helper bundle already exists: $control_bundle"
[[ -f "$app_profile" && ! -L "$app_profile" ]] || fail "missing app profile: $app_profile"
[[ -x "$shim_builder" ]] || fail "missing shim builder: $shim_builder"

scratch_root="$(/usr/bin/mktemp -d /tmp/idlescreenctl-package.XXXXXX)"
trap '/bin/rm -rf "${scratch_root:?}"' EXIT
shim="$scratch_root/idlescreenctl-shim"
"$shim_builder" "$shim" "$control_tool" || fail "could not build the idlescreenctl launcher shim"
[[ -f "$shim" && ! -L "$shim" && -x "$shim" ]] ||
  fail "the idlescreenctl launcher shim builder produced no executable"

/bin/mkdir -p "$control_bundle/Contents/MacOS" ||
  fail "could not create the control tool helper bundle"
/bin/mv "$control_tool" "$control_bundle/Contents/MacOS/idlescreenctl" ||
  fail "could not move the control tool into its helper bundle"
/bin/cp "$shim" "$control_tool" || fail "could not install the idlescreenctl launcher shim"
/bin/chmod 755 "$control_tool"

info="$control_bundle/Contents/Info.plist"
/usr/bin/plutil -create xml1 "$info" || fail "could not create the control tool helper Info.plist"
for record in \
  CFBundleExecutable:idlescreenctl \
  CFBundleIdentifier:com.idlescreen.app.ctl \
  CFBundleName:IdleScreenCtl \
  CFBundlePackageType:APPL \
  CFBundleInfoDictionaryVersion:6.0 \
  LSMinimumSystemVersion:15.0; do
  /usr/bin/plutil -insert "${record%%:*}" -string "${record#*:}" "$info" ||
    fail "could not write the control tool helper Info.plist"
done
/usr/bin/plutil -insert LSUIElement -bool true "$info" ||
  fail "could not write the control tool helper Info.plist"

/usr/bin/ditto "$app_profile" "$control_bundle/Contents/embedded.provisionprofile" ||
  fail "could not embed the app profile in the control tool helper"
/usr/bin/xattr -c "$control_bundle/Contents/embedded.provisionprofile" ||
  fail "could not normalize the control tool helper profile metadata"
