import LectureKit
import SwiftUI

/// The main window: a board with the course column on the left and the capture
/// sheet mounted on the right.
///
/// The toolbar carries nothing but the sidebar toggle. Every action worth a
/// button lives in the menu bar popover, which is the surface actually reachable
/// while a lecture is starting; duplicating them here would put the same control
/// in two places and make the window's chrome compete with the sheet it frames.
struct RootView: View {

    @Environment(SessionModel.self) private var session

    /// Which course the sidebar has selected. Owned here so the sidebar and the
    /// detail pane stay ignorant of one another.
    @State private var selection: String?

    /// The lecture opened for reading, if any.
    @State private var opened: LibraryLecture?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(Spacing.sidebarWidth)
        } detail: {
            detail
        }
        // Chrome is board (DESIGN.md §1), including the titlebar the split view
        // draws its own material into.
        .toolbarBackground(Palette.board, for: .windowToolbar)
        .background(Palette.board)
    }

    /// Capture while a lecture is running, the library otherwise.
    ///
    /// A recording is the one thing in this app that cannot wait, so it takes the
    /// pane whenever it is live regardless of what was being read — coming back
    /// from a browse to find the capture panel gone is how you lose a lecture. It
    /// also means the reader does not need its own dismissal for the case where
    /// class starts while you are revising.
    @ViewBuilder private var detail: some View {
        if session.phase != .idle {
            CaptureView()
        } else if let opened {
            NoteReaderView(entry: opened, close: { self.opened = nil })
        } else {
            LibraryView(course: selection, selection: $opened)
        }
    }
}
