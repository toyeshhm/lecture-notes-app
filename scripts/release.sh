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
#
# --entitlements is not optional either, and leaving it off is worse than leaving
# off --options runtime was. `--force` replaces the signature wholesale, so a
# re-sign without it strips every entitlement xcodebuild embedded — including
# `com.apple.security.device.audio-input`. Under hardened runtime that is what
# grants microphone access, so the app was refused the microphone at the runtime
# level, macOS never registered a request, and it never appeared in System
# Settings › Privacy & Security › Microphone at all. Not "denied": absent.
codesign --force --options runtime \
	--entitlements App/Resources/LectureNotes.entitlements \
	--sign - "$app"

# Verified rather than assumed, because both of this script's signing bugs looked
# fine in `codesign --verify` and only showed up in what the app could do.
if ! codesign -d --entitlements - "$app" 2>&1 | grep -q "audio-input"; then
	echo "release.sh: the signed bundle has no audio-input entitlement" >&2
	exit 1
fi
codesign --verify --deep --strict "$app"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
zip="dist/LectureNotes-$version.zip"

mkdir -p dist
rm -f "$zip"
# ditto, not zip(1): zip does not preserve the symlinks or extended attributes
# inside a bundle, and the signature does not survive the round trip.
ditto -c -k --keepParent "$app" "$zip"

echo "$zip"
