#!/bin/bash
# Usage: check-release-reproducibility.sh <tag>
# Rebuilds the unsigned Release app from a release tag with the pinned XcodeGen
# and compares what is comparable against the published candidate manifest
# (IdleScreenR1ReleaseCandidateV1.txt on the GitHub release). Needs no signing
# credentials. Signatures, notarization and the DMG cannot be reproduced without
# them and are reported as NOT-COMPARABLE.
set -euo pipefail

xcodegen_version=2.46.0
xcodegen_sha256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806

script_root="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_root/.." && pwd)"
# shellcheck source=scripts/lib/release-reproducibility.sh
source "$script_root/lib/release-reproducibility.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ $# -eq 1 && "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] ||
  { echo "Usage: $0 <tag, for example v0.4.0>" >&2; exit 2; }
tag="$1"

scratch="$(mktemp -d /tmp/idlescreen-repro.XXXXXX)"
worktree="$scratch/src"
cleanup() {
  git -C "$project_root" worktree remove --force "$worktree" >/dev/null 2>&1 || true
  /bin/rm -rf "${scratch:?}"
}
trap cleanup EXIT

tag_commit="$(git -C "$project_root" rev-parse --verify "refs/tags/$tag^{commit}")" ||
  fail "tag $tag is not available locally; fetch tags first"
tag_tree="$(git -C "$project_root" rev-parse --verify "refs/tags/$tag^{tree}")"

mkdir "$scratch/manifest" "$scratch/tools"
gh release download "$tag" --repo CodesWhat/idlescreen \
  --pattern IdleScreenR1ReleaseCandidateV1.txt --dir "$scratch/manifest" ||
  fail "could not download the candidate manifest for $tag"
manifest="$scratch/manifest/IdleScreenR1ReleaseCandidateV1.txt"

GITHUB_PATH='' "$script_root/install-xcodegen.sh" "$xcodegen_version" "$xcodegen_sha256" \
  "$scratch/tools/xcodegen-$xcodegen_version" >/dev/null ||
  fail "could not install pinned XcodeGen"
xcodegen="$scratch/tools/xcodegen-$xcodegen_version/bin/xcodegen"

git -C "$project_root" worktree add --detach "$worktree" "$tag_commit" >/dev/null 2>&1 ||
  fail "could not check out $tag"

pbxproj="$worktree/IdleScreen.xcodeproj/project.pbxproj"
(cd "$worktree" && "$xcodegen" generate --spec project.yml >"$scratch/xcodegen.log" 2>&1) ||
  fail "project generation failed (see $scratch/xcodegen.log)"

derived="$scratch/DerivedData"
(cd "$worktree" && /usr/bin/xcrun xcodebuild build \
  -project IdleScreen.xcodeproj -scheme IdleScreenApp -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  >"$scratch/build.log" 2>&1) || { tail -40 "$scratch/build.log" >&2; fail "unsigned Release build failed"; }

app="$derived/Build/Products/Release/IdleScreen.app"
[[ -d "$app" ]] || fail "build produced no IdleScreen.app"
plist="$app/Contents/Info.plist"

{
  echo "source_commit=$tag_commit"
  echo "source_tree=$tag_tree"
  echo "project_yml_sha256=$(/usr/bin/shasum -a 256 "$worktree/project.yml" | /usr/bin/awk '{ print $1 }')"
  echo "project_pbxproj_sha256=$(/usr/bin/shasum -a 256 "$pbxproj" | /usr/bin/awk '{ print $1 }')"
  echo "bundle_short_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$plist")"
  echo "bundle_version=$(/usr/bin/plutil -extract CFBundleVersion raw "$plist")"
} >"$scratch/observed.txt"

echo "Reproducibility check for $tag (XcodeGen $xcodegen_version, unsigned Release)"
if rr_compare "$manifest" "$scratch/observed.txt"; then
  echo "PASS: every comparable field of $tag reproduces from the tag."
else
  fail "$tag does not reproduce from its tag and manifest"
fi
