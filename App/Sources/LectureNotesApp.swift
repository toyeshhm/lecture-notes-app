import LectureKit
import SwiftUI

/// The app shell.
///
/// Two surfaces, one state object. The menu bar exists because starting a
/// recording has to be one click while you are sitting down as class begins —
/// hunting for a window is exactly when you miss the first minute.
@main
struct LectureNotesApp: App {
    @State private var session = SessionModel()

    var body: some Scene {
        Window("Lecture Notes", id: "main") {
            RootView()
                .environment(session)
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1080, height: 720)
        // Start and stop live in the popover, which is reachable by pointer and
        // by Control-F8 but by no shortcut. A menu item gives the capture flow a
        // keyboard path from the window, where the popover is not on screen at
        // all, and puts it in the Help menu's search index.
        .commands {
            CommandGroup(after: .newItem) {
                Button(session.phase == .recording ? "Stop & Write" : "Start Recording") {
                    session.toggle()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(session.phase.isBusy)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(session)
        } label: {
            // A template image so macOS tints it for light/dark menu bars.
            Label(session.menuBarTitle, systemImage: session.menuBarSymbol)
                // `menuBarTitle` is empty except while recording or writing, so
                // without this the app's primary control announces as its raw
                // glyph ("leaf", "record circle fill") or as nothing at all.
                .accessibilityLabel("Lecture Notes, \(session.stateWord)")
        }
        .menuBarExtraStyle(.window)
    }
}
