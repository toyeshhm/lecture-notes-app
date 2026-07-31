import LectureKit
import SwiftUI

/// The window: navigation on the left, one section on the right.
///
/// The sidebar is real navigation now rather than a course list, and Settings is
/// a section in it rather than only a `Settings` scene behind ⌘,. Both surfaces
/// still exist — ⌘, opens the scene, because that is where a Mac user reaches for
/// it — and they share the same view.
struct RootView: View {

    @Environment(SessionModel.self) private var session

    @State private var section: AppSection = .record
    /// The selected course. Nil is every course.
    @State private var course: String?
    /// The lecture opened for reading, if any.
    @State private var opened: LibraryLecture?
    @State private var showingFirstRun = false

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(section: $section, course: $course)
            Rectangle().fill(Palette.rule).frame(width: Spacing.hair)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.board)
        .toolbarBackground(Palette.board, for: .windowToolbar)
        // Presented from here rather than from the App: a sheet needs a window to
        // hang off, and this is the first view inside the only one.
        .sheet(isPresented: $showingFirstRun) {
            FirstRunView().environment(session)
        }
        .task {
            showingFirstRun = await FirstRunView.shouldPresent(settings: session.settings)
        }
        // A recording takes the pane whenever it starts, from wherever you were.
        // Coming back from a browse to find the capture screen gone is how you
        // lose a lecture, and it means the reader needs no dismissal of its own
        // for the case where class begins while you are revising.
        .onChange(of: session.phase) { _, phase in
            if phase == .recording || phase == .preparing {
                section = .record
                opened = nil
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .record:
            RecordView()
        case .library:
            if let opened {
                NoteReaderView(entry: opened, close: { self.opened = nil })
            } else {
                LibraryView(course: course, selection: $opened)
            }
        case .settings:
            SettingsView()
        }
    }
}
