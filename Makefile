PROJECT := LectureNotes.xcodeproj
DERIVED := .build-xcode
KIT     := Packages/LectureKit

# Schemes rather than targets: xcodebuild refuses `-derivedDataPath` without one
# of `-scheme`, `-testProductsPath` or `-xctestrun`, so `-target` cannot be used
# here at all. There are no .xcscheme files on disk — xcodebuild autocreates the
# three (LectureKit, LectureNotes, Snapshot) from the generated project, which is
# why looking for the files says otherwise and `xcodebuild -list` is the answer.
XCODEBUILD := xcodebuild -project $(PROJECT) -derivedDataPath $(DERIVED) -quiet

.DEFAULT_GOAL := check
.PHONY: check lint test app release install snapshots generate

# `app` is in here deliberately. Without it `check` never compiled a line of
# App/Sources — `lint` and `test` both address the package only — so nine
# modified view files could go green, and a file with `let x: Int = "nope"` in it
# did. Two thirds of this codebase is the app target.
check: lint app test

# Not swiftlint or swift-format: neither has a config in this repo, and under
# either tool's defaults the codebase reports hundreds of style diagnostics
# (2-space indent, mostly) — a lint target that never passes gets ignored.
# Swift 6 strict concurrency is on, so a fatal-warning build is the check that
# actually catches things here — but only for the package. The app half is
# covered by `app`, which xcodebuild runs without warnings-as-errors; `-quiet`
# suppresses the warnings it does emit. That is a real gap and it is stated
# rather than papered over.
lint:
	swift build --package-path $(KIT) -Xswiftc -warnings-as-errors

test:
	swift test --package-path $(KIT)

# The .xcodeproj is generated and untracked, so every Xcode build regenerates it.
generate:
	xcodegen generate

app: generate
	$(XCODEBUILD) -scheme LectureNotes -configuration Debug build

release:
	./scripts/release.sh

# `release` first, deliberately: this installs the same signed bundle that goes
# into the zip, so what you run is what anyone downloading it runs. Neither
# `check` nor `release` puts anything in /Applications, and the failure that
# causes is silent — the app launches and is simply the previous build.
#
# Do not run this during a lecture. It quits the app to replace it.
install: release
	./scripts/install.sh

snapshots: generate
	$(XCODEBUILD) -scheme Snapshot -configuration Debug build
	$(DERIVED)/Build/Products/Debug/Snapshot.app/Contents/MacOS/Snapshot Snapshots
