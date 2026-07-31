#!/usr/bin/env bash
#
# Release build, ad-hoc signature, zip into dist/.
#
# There is no Apple Developer account behind this app, so the signature is
# ad-hoc and the result is NOT notarized. A zip downloaded from a browser
# carries a quarantine flag and Gatekeeper refuses the first double-click; the
# README gives the two remedies.
set -euo pipefail

cd "$(dirname "$0")/.."

xcodegen generate
xcodebuild -project LectureNotes.xcodeproj -scheme LectureNotes \
	-configuration Release -derivedDataPath .build-xcode -quiet build

app=".build-xcode/Build/Products/Release/LectureNotes.app"
if [ ! -d "$app" ]; then
	echo "release.sh: no app bundle at $app" >&2
	exit 1
fi

# `-` is the ad-hoc identity.
#
# --options runtime is not optional here even though project.yml already sets
# ENABLE_HARDENED_RUNTIME. --force replaces the signature wholesale and codesign
# does not inherit the previous one's flags, so re-signing without it silently
# ships a bundle with the hardened runtime turned off. Verified: after a bare
# `codesign --force --sign -`, `codesign -d --verbose=2` reports flags=0x2(adhoc)
# with no `runtime`.
#
# No --deep. There is nothing to reach: SPM dependencies link statically into the
# main binary, the bundle has no Frameworks/ directory, and Apple documents
# --deep as a repair tool rather than a build step.
codesign --force --options runtime --sign - "$app"
codesign --verify --deep --strict "$app"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
zip="dist/LectureNotes-$version.zip"

mkdir -p dist
rm -f "$zip"
# ditto, not zip(1): zip does not preserve the symlinks or extended attributes
# inside a bundle, and the signature does not survive the round trip.
ditto -c -k --keepParent "$app" "$zip"

echo "$zip"
