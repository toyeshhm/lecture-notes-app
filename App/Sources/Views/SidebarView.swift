import LectureKit
import SwiftUI

/// Where you are in the app, and which course you are looking at.
///
/// It used to be a bare column of courses, with every action — start a recording,
/// open settings — reachable only from the menu bar popover or a keyboard
/// shortcut. That was a deliberate choice and it was wrong: a window with no
/// visible way to record is a broken window, and the first thing said about the
/// shipped app was that it had no way to start a recording. It had two. Neither
/// was in the window.
struct SidebarView: View {

    @Binding var section: AppSection
    /// The selected course. Nil means all of them.
    @Binding var course: String?

    @Environment(SessionModel.self) private var session

    @State private var courses: [Course] = []

    private struct Course: Identifiable {
        let code: String
        /// Full name from the roster. Often empty: a course discovered as a
        /// folder has a code and nothing else.
        let name: String
        var id: String { code }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
            ForEach(AppSection.allCases) { item in
                NavRow(
                    section: item,
                    isSelected: section == item,
                    isLive: item == .record && session.phase == .recording,
                    select: { section = item })
            }

            courseHeader
            if courses.isEmpty {
                emptyCourses
            } else {
                courseList
            }

            Spacer(minLength: Spacing.lg)
            destination
        }
        .frame(width: Spacing.sidebarWidth)
        .background(Palette.sheet)
        // Re-reads when the vault moves, and when the session settles on a course
        // mid-lecture: detection happens while recording and files under a folder
        // that may not have existed when this list was scanned.
        .task(id: [session.settings.coursesDir.path(percentEncoded: false), session.course]) {
            await reload()
        }
    }

    // MARK: Chrome

    private var title: some View {
        Text("Lecture Notes")
            .font(Typography.uiBold)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.lg)
    }

    private var courseHeader: some View {
        Text("Courses")
            .font(Typography.caption.smallCaps())
            .tracking(Typography.captionTracking)
            .foregroundStyle(Palette.inkSoft)
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.sm)
            .accessibilityAddTraits(.isHeader)
    }

    /// The destination, always visible.
    ///
    /// It is the most reassuring fact the app can state while a lecture is being
    /// recorded, and it was previously only in the capture sheet's footer — which
    /// is to say, invisible from the library, from settings, and from the moment
    /// you are actually wondering about it.
    private var destination: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Filing into")
                .font(Typography.caption.smallCaps())
                .tracking(Typography.captionTracking)
                .foregroundStyle(Palette.inkSoft)
            Text(session.settings.coursesDir.path(percentEncoded: false))
                .font(Typography.micro)
                .tracking(Typography.microTracking)
                .foregroundStyle(Palette.inkSoft)
                .lineLimit(1)
                // Head, not tail: the vault name is at the end of the path and it
                // is the part that says which vault this is.
                .truncationMode(.head)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.lg)
        .accessibilityElement(children: .combine)
    }

    private var courseList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(courses) { item in
                    CourseRow(
                        code: item.code,
                        name: item.name,
                        isSelected: course == item.code && section == .library,
                        isRecording: session.phase == .recording && session.course == item.code,
                        select: {
                            course = item.code
                            section = .library
                        })
                }
            }
        }
    }

    private var emptyCourses: some View {
        Text("None yet. A course appears once a lecture is filed under it, and you can add them in Settings.")
            .font(Typography.ui)
            .foregroundStyle(Palette.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Spacing.lg)
    }

    // MARK: Data

    private func reload() async {
        let directory = session.settings.coursesDir
        // Scanning touches the disk; off the main actor so a slow or unmounted
        // network volume cannot stall a frame.
        let found = await Task.detached { CourseDetector.candidates(in: directory) }.value
        courses = found
            .map { Course(code: $0.key, name: $0.value) }
            .sorted { first, second in
                // `_Unsorted` is where detection gave up, not a course, so it
                // trails rather than heading the list on a leading underscore.
                let firstIsUnsorted = first.code == unsortedFolder
                let secondIsUnsorted = second.code == unsortedFolder
                if firstIsUnsorted != secondIsUnsorted { return secondIsUnsorted }
                return first.code.localizedStandardCompare(second.code) == .orderedAscending
            }
    }
}

// MARK: - Sections

/// The three places you can be. Deliberately not an open-ended list: a fourth
/// entry here would mean the app had grown a fourth job.
enum AppSection: String, CaseIterable, Identifiable {
    case record, library, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .record: return "Record"
        case .library: return "Library"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .record: return "record.circle"
        case .library: return "books.vertical"
        case .settings: return "slider.horizontal.3"
        }
    }
}

// MARK: - Rows

private struct NavRow: View {
    let section: AppSection
    let isSelected: Bool
    /// A recording in progress. Shown on the Record row whether or not it is
    /// selected — the whole point is that it is visible from the other two.
    let isLive: Bool
    let select: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var fill: Double {
        if isSelected { return 1 }
        return isHovering ? 0.5 : 0
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: Spacing.md) {
                Image(systemName: section.symbol)
                    .font(.system(size: 13))
                    .frame(width: Spacing.lg)
                Text(section.title)
                    .font(isSelected ? Typography.uiBold : Typography.ui)
                Spacer(minLength: 0)
                if isLive {
                    Circle()
                        .fill(Palette.stamp)
                        .frame(width: Spacing.sm, height: Spacing.sm)
                }
            }
            .foregroundStyle(isSelected ? Palette.ink : Palette.inkSoft)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(alignment: .leading) {
            Palette.wash.opacity(fill)
            if isSelected {
                // A lit edge, held clear of the boundary. Flush to the edge it is
                // a coloured side stripe, which is banned; inset, it reads as
                // light catching the near edge of a raised row.
                Rectangle()
                    .fill(Palette.plate)
                    .frame(width: Spacing.plateBorderOuter)
                    .padding(.vertical, Spacing.xs)
                    .padding(.leading, Spacing.xs)
            }
        }
        .animation(Motion.settle.animation(reduceMotion: reduceMotion), value: fill)
        .onHover { isHovering = $0 }
        .accessibilityLabel(section.title)
        .accessibilityValue(isLive ? "Recording" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// One course: its scene, its code, and whether it is live.
///
/// The scene replaces the Köhler plate that identified a course before. A
/// botanical engraving at 26pt was a blot; a graded forest photograph at 26pt is
/// still recognisably a place, which is the whole job this element has.
private struct CourseRow: View {
    let code: String
    let name: String
    let isSelected: Bool
    let isRecording: Bool
    let select: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private static let thumbnail: CGFloat = 26

    private var scene: Backdrop? { Scenery.scene(for: code) }

    private var fill: Double {
        if isSelected { return 1 }
        return isHovering ? 0.5 : 0
    }

    /// `_Unsorted` is a folder name, not a course name, and the one value here
    /// that was never typed by a person.
    private var displayName: String {
        code == unsortedFolder ? "Unsorted" : code
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: Spacing.md) {
                thumbnailView
                Text(displayName)
                    .font(isSelected ? Typography.uiBold : Typography.ui)
                    .foregroundStyle(isSelected || isRecording ? Palette.ink : Palette.inkSoft)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isRecording {
                    Circle()
                        .fill(Palette.stamp)
                        .frame(width: Spacing.sm, height: Spacing.sm)
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(alignment: .leading) {
            Palette.wash.opacity(fill)
            if isSelected {
                Rectangle()
                    .fill(Palette.plate)
                    .frame(width: Spacing.plateBorderOuter)
                    .padding(.vertical, Spacing.xs)
                    .padding(.leading, Spacing.xs)
            }
        }
        .animation(Motion.settle.animation(reduceMotion: reduceMotion), value: fill)
        .onHover { isHovering = $0 }
        .accessibilityLabel(name.isEmpty ? displayName : "\(displayName), \(name)")
        .accessibilityValue(isRecording ? "Recording" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(name.isEmpty ? displayName : "\(displayName) — \(name)")
    }

    @ViewBuilder private var thumbnailView: some View {
        ZStack {
            Palette.wash
            if let scene {
                scene.image
                    .resizable()
                    .scaledToFill()
                    // Held back so a column of them identifies without turning
                    // into a strip of postcards competing with the course codes.
                    .saturation(0.75)
                    .opacity(0.9)
            }
        }
        .frame(width: Self.thumbnail, height: Self.thumbnail)
        .clipShape(RoundedRectangle(cornerRadius: Spacing.xs))
        .accessibilityHidden(true)   // the course code carries this
    }
}
