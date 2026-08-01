#!/usr/bin/env bash
#
# Install the signed release build into /Applications, then verify the bundle
# that actually landed there.
#
# This exists because `make check` builds into .build-xcode and `make release`
# builds into dist/, and *neither* installs anything. Copying by hand was the
# missing step, and the failure it produces is silent: the app launches, looks
# right, and is simply the previous build — a feature added an hour ago appears
# not to exist.
#
# It installs what `release.sh` signed rather than making its own build, so the
# thing being run is byte-for-byte the thing in the zip a friend downloads.
set -euo pipefail

cd "$(dirname "$0")/.."

app=".build-xcode/Build/Products/Release/LectureNotes.app"
target="/Applications/Lecture Notes.app"
bundle_id="com.toyeshhm.LectureNotes"

[ -d "$app" ] || { echo "install.sh: no build at $app — run scripts/release.sh first" >&2; exit 1; }

# Quit gracefully rather than killing. A recording holds audio that exists
# nowhere else, and SIGKILL mid-lecture loses it with no note written.
#
# DO NOT run this during a lecture. The check below cannot tell a recording from
# an idle window — it only asks the app to quit, which it will.
if pgrep -f "$target/Contents/MacOS/" >/dev/null 2>&1; then
	echo "install.sh: quitting the running app"
	osascript -e 'tell application "Lecture Notes" to quit' >/dev/null 2>&1 || true
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		pgrep -f "$target/Contents/MacOS/" >/dev/null 2>&1 || break
		sleep 1
	done
	if pgrep -f "$target/Contents/MacOS/" >/dev/null 2>&1; then
		echo "install.sh: it did not quit — close it and try again" >&2
		exit 1
	fi
fi

# Only ever replaces this app. `rm -rf` on a path assembled from variables is
# how a typo deletes something else, so the bundle identifier is checked first
# and anything unrecognised is left alone.
if [ -e "$target" ]; then
	existing=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
		"$target/Contents/Info.plist" 2>/dev/null || echo "")
	if [ "$existing" != "$bundle_id" ]; then
		echo "install.sh: $target is not $bundle_id (found '${existing:-nothing}') — refusing" >&2
		exit 1
	fi
	rm -rf "$target"
fi

# ditto, not cp: cp does not preserve the symlinks and extended attributes
# inside a bundle, and the signature does not survive the round trip.
ditto "$app" "$target"

# Everything below verifies the bundle in /Applications rather than the one that
# was built. Both of this project's signing bugs looked fine in the build
# directory; what matters is what the copy can do.
codesign --verify --deep --strict "$target"

# Without this entitlement, hardened runtime refuses the microphone at the
# runtime level: macOS never registers a request, and the app never appears in
# System Settings › Privacy & Security › Microphone at all. Not denied — absent.
codesign -d --entitlements - "$target" 2>&1 | grep -q "audio-input" \
	|| { echo "install.sh: installed bundle has no audio-input entitlement" >&2; exit 1; }

# The scenery is a build-phase away from being omitted — it once shipped only in
# the Snapshot target, so a whole design change was reviewed on renders while the
# installed app had no images in it.
[ -d "$target/Contents/Resources/Scenery" ] \
	|| { echo "install.sh: installed bundle has no Scenery/" >&2; exit 1; }

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$target/Contents/Info.plist")
echo "installed $version → $target"
