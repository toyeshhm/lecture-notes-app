import AppKit
import LectureKit
import SwiftUI

/// Renders the app's views to PNG without launching the app or needing any
/// screen-capture permission.
///
/// Two approaches were tried. `ImageRenderer` is the obvious one and is wrong
/// here: it does not lay out `ScrollView` or `NavigationSplitView`, so the
/// capture pane rendered as a bare board and the whole window rendered
/// byte-identically in both appearances — a design review comparing a file
/// against itself. It also ignores `NSApp.appearance` and
/// `performAsCurrentDrawingAppearance`, both measured.
///
/// Hosting the view in an offscreen `NSWindow` renders the real hierarchy,
/// resolves dynamic `NSColor`s against `window.appearance`, and needs no
/// permission because the window is ours.
///
/// Usage: Snapshot <output-directory>

@MainActor
func render(_ name: String, size: CGSize, _ view: @escaping @autoclosure () -> some View) {
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let host = NSHostingView(rootView: AnyView(view()))
        host.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        // This is what actually drives light/dark: dynamic NSColors resolve
        // against the hosting window's appearance.
        window.appearance = NSAppearance(named: appearance)

        host.layoutSubtreeIfNeeded()
        // SwiftUI settles layout and async image loads over a run-loop turn or
        // two; rendering immediately catches a half-built hierarchy.
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            FileHandle.standardError.write(Data("no bitmap for \(name)\n".utf8))
            continue
        }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("no png for \(name)\n".utf8))
            continue
        }
        let url = outputDirectory.appending(path: "\(name)-\(suffix).png")
        try? png.write(to: url)
        print("  \(url.lastPathComponent)")
        window.contentView = nil
    }
}

let outputDirectory: URL = {
    let arg = CommandLine.arguments.dropFirst().first
    let dir = arg.map { URL(fileURLWithPath: $0) }
        ?? URL.currentDirectory().appending(path: "Snapshots")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

enum SnapshotFixtures {
    /// Real output from the pipeline, so layout is judged against the text it
    /// will actually hold rather than lorem ipsum.
    static let liveNotes = """
        ### Deletion — three cases

        - **Leaf.** Remove it; null the parent's pointer.
        - **One child.** Splice the child into its place.
        - **Two children.** Copy the **in-order successor**'s key into the node, \
        then delete the successor instead. It has at most one child by \
        construction, so case 3 reduces to case 1 or 2.

        > [!important] Likely on exam
        > "The deletion case comes up on the final almost every year."
        """

    static let transcript = """
        Alright everyone, settle down. Today we are doing binary search trees, \
        and I want to flag now that the deletion case comes up on the final \
        almost every year. So a binary search tree is a rooted binary tree where \
        for every node, all keys in the left subtree are less than the node key, \
        and all keys in the right subtree are greater. That invariant is the \
        whole thing.
        """

    /// The transcript stretched or trimmed to a given length, for fixtures whose
    /// word count is the thing being tested.
    static func transcript(words: Int) -> String {
        let source = transcript.split(whereSeparator: \.isWhitespace)
        guard !source.isEmpty else { return "" }
        return (0..<words).map { String(source[$0 % source.count]) }.joined(separator: " ")
    }
}

extension LectureKit.Settings {
    static var preview: Self {
        Settings(vault: URL(fileURLWithPath: "/tmp/preview-vault"), coursesSubdir: "Courses")
    }
}

/// Writes a term's worth of lectures to `/tmp/preview-vault` so the library and
/// the reader have something to draw.
///
/// The library reads the disk rather than an index, which is the whole point of
/// its design — so there is no in-memory fixture that could stand in here. The
/// notes go through `VaultWriter` for the same reason the capture fixtures are
/// real pipeline output: a layout judged against invented text is judged against
/// text the app will never hold.
@MainActor
enum PreviewVault {
    static func populate() {
        let settings = LectureKit.Settings.preview
        try? FileManager.default.removeItem(at: settings.vault)

        // The last figure is words per minute, and it is the reason this table
        // carries one at all: the hatch swatch encodes speech density, so a
        // fixture where every lecture has the same transcript renders six
        // identical swatches and proves nothing. Real lecturers run roughly 100
        // to 160; the spread here is a slow proof against a rapid derivation.
        for (course, topic, date, minutes, wpm) in [
            ("CS 314H", "Binary Search Tree Deletion", "2026-07-30", 74.0, 138.0),
            ("CS 314H", "Hash Tables — Collision Resolution", "2026-07-28", 51.0, 155.0),
            ("CS 314H", "Amortised Analysis", "2026-07-24", 68.0, 96.0),
            ("M 340L", "Eigenvalues and Diagonalisation", "2026-07-29", 49.0, 112.0),
            ("M 340L", "Change of Basis", "2026-07-27", 55.0, 124.0),
            (unsortedFolder, "Great Wall of China Myth", "2026-07-31", 12.0, 168.0),
        ] {
            var note = LectureNote(
                date: date, course: course, topic: topic,
                finalNotes: SnapshotFixtures.liveNotes,
                transcript: SnapshotFixtures.transcript(words: Int(minutes * wpm)),
                duration: minutes * 60,
                detectedCourse: course,
                detectionConfidence: course == unsortedFolder ? .low : .high)
            _ = try? VaultWriter().save(&note, settings: settings)
        }

        // One note left mid-recording: the shape a crashed session leaves behind,
        // and the only way to see the library's unfinished state.
        var crashed = LectureNote(
            date: "2026-07-22", course: "CS 314H", topic: "Red-Black Trees",
            sections: [SnapshotFixtures.liveNotes],
            transcript: SnapshotFixtures.transcript(words: 2400), duration: 2100)
        _ = try? VaultWriter().save(&crashed, settings: settings)
    }

    /// The lecture the reader snapshot opens.
    static var opened: LibraryLecture? {
        LibraryScanner.scan(settings: .preview)
            .first { $0.name == "CS 314H" }?.lectures.first
    }
}

@main
enum Main {
    static func main() {
        // A window needs a real NSApplication, but not a visible one.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        MainActor.assumeIsolated {
            print("rendering to \(outputDirectory.path)")

            let idle = SessionModel(settings: .preview)

            let recording = SessionModel(settings: .preview)
            recording.previewState(
                phase: .recording, elapsed: 743, level: 0.42,
                course: "CS 314H", topic: "Binary Search Tree Deletion",
                liveNotes: SnapshotFixtures.liveNotes,
                transcript: SnapshotFixtures.transcript
            )

            let failed = SessionModel(settings: .preview)
            failed.previewState(
                phase: .failed("The claude CLI isn't logged in. Run claude, then /login."))

            render("menubar-idle", size: CGSize(width: 240, height: 190),
                   MenuBarView().environment(idle))
            render("menubar-recording", size: CGSize(width: 240, height: 300),
                   MenuBarView().environment(recording))
            render("menubar-failed", size: CGSize(width: 240, height: 230),
                   MenuBarView().environment(failed))

            render("capture-idle", size: CGSize(width: 840, height: 700),
                   CaptureView().environment(idle))
            render("capture-recording", size: CGSize(width: 840, height: 700),
                   CaptureView().environment(recording))

            render("sidebar", size: CGSize(width: 232, height: 700),
                   SidebarView(selection: .constant(nil)).environment(recording))

            render("window-recording", size: CGSize(width: 1120, height: 720),
                   RootView().environment(recording))

            PreviewVault.populate()

            render("window-idle", size: CGSize(width: 1120, height: 720),
                   RootView().environment(idle))
            render("library-folio", size: CGSize(width: 888, height: 1100),
                   LibraryView(course: nil, selection: .constant(nil)).environment(idle))
            render("library-course", size: CGSize(width: 888, height: 760),
                   LibraryView(course: "CS 314H", selection: .constant(nil)).environment(idle))

            if let opened = PreviewVault.opened {
                render("reader", size: CGSize(width: 888, height: 1000),
                       NoteReaderView(entry: opened, close: {}).environment(idle))
            } else {
                print("  reader skipped — the preview vault produced no lectures")
            }
        }
    }
}
