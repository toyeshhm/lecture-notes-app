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
}

extension LectureKit.Settings {
    static var preview: Self {
        Settings(vault: URL(fileURLWithPath: "/tmp/preview-vault"), coursesSubdir: "Courses")
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
            render("window-idle", size: CGSize(width: 1120, height: 720),
                   RootView().environment(idle))
        }
    }
}
