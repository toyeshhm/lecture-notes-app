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

    /// Which course the sidebar has selected. Owned here so the sidebar and the
    /// detail pane stay ignorant of one another.
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(Spacing.sidebarWidth)
        } detail: {
            CaptureView()
        }
        // Chrome is board (DESIGN.md §1), including the titlebar the split view
        // draws its own material into.
        .toolbarBackground(Palette.board, for: .windowToolbar)
        .background(Palette.board)
    }
}
