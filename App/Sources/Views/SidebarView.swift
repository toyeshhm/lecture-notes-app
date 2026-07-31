import LectureKit
import SwiftUI

/// The course list, as a collection of mounted specimens.
///
/// Board ground throughout: this is chrome, nothing here is read at length, and
/// the texture and grain of the board plane never reach the sheet (DESIGN.md
/// §1). Each row's only per-course discriminator is its Köhler plate, so five
/// courses read as five recognisably different plants at a glance.
struct SidebarView: View {

    /// The selected course code. A binding so the detail pane can follow it
    /// without the sidebar knowing anything about what a detail pane is.
    @Binding var selection: String?

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
            header
            if courses.isEmpty {
                emptyState
            } else {
                list
            }
            Spacer(minLength: 0)
        }
        .frame(width: Spacing.sidebarWidth)
        // The sidebar *is* board (DESIGN.md §1), so it carries the board's grain
        // rather than a flat fill. `BoardBackground` already lays `Palette.board`
        // underneath the grain, so this is the same plane, not an extra layer.
        .background(BoardBackground())
        // Re-reads when the vault moves, and when the session settles on a
        // course: detection happens mid-lecture and files under a folder that
        // may not have existed when this list was scanned. Without the second
        // key that course is missing from the column for the rest of the
        // launch — and, since the row is what carries the recording disc, the
        // running lecture shows nowhere in the sidebar at all.
        .task(id: [session.settings.coursesDir.path(percentEncoded: false), session.course]) {
            await reload()
        }
    }

    // MARK: Sections

    /// A section head is a caption line over a hairline, never a tracked
    /// uppercase eyebrow (DESIGN.md §5.1).
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Palette.rule)
                .frame(height: Spacing.hair)
            Text("Term")
                .font(Typography.caption.smallCaps())
                .tracking(Typography.captionTracking)
                .foregroundStyle(Palette.inkSoft)
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.sm)
        }
        .accessibilityAddTraits(.isHeader)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(courses) { course in
                    CourseRow(
                        code: course.code,
                        name: course.name,
                        isSelected: selection == course.code,
                        isRecording: session.phase == .recording && session.course == course.code,
                        select: { selection = course.code })
                }
            }
        }
    }

    /// An empty column tells a first-run user nothing. The roster file is the
    /// one action that fills it, so the empty state names it and shows the
    /// folder it belongs in, selectable so the path can be copied.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("No courses yet")
                .font(Typography.ui)
                .foregroundStyle(Palette.ink)
            Text("List them in \(rosterFilename), one per line, as “- CS 314H — Data Structures”. Folders already in the vault count too.")
                .font(Typography.ui)
                .foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Text(session.settings.coursesDir.path(percentEncoded: false))
                .font(Typography.micro)
                .tracking(Typography.microTracking)
                .foregroundStyle(Palette.inkSoft)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.sm)
    }

    // MARK: Data

    private func reload() async {
        let directory = session.settings.coursesDir
        // Scanning the vault touches the disk; off the main actor so a slow
        // network volume cannot stall a frame.
        let found = await Task.detached { CourseDetector.candidates(in: directory) }.value
        courses = found
            .map { Course(code: $0.key, name: $0.value) }
            .sorted { $0.code.localizedStandardCompare($1.code) == .orderedAscending }
    }
}

// MARK: - Row

/// One course: plate, code, species (DESIGN.md §5.1).
private struct CourseRow: View {
    let code: String
    let name: String
    let isSelected: Bool
    let isRecording: Bool
    let select: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    /// 56pt, with no single token at that value: `xxl` for the 32pt plate plus
    /// `xl` for the padding either side of it.
    private static let rowHeight = Spacing.xxl + Spacing.xl

    /// DESIGN.md §5.1 sets the silhouette at 85%: full-strength `inkSoft`
    /// linework at 32pt reads as a blot rather than a plant.
    /// Pulled well back: at full saturation three colour plates in a row
    /// turn the sidebar into a swatch book and outshout the course codes.
    private static let plateSaturation: Double = 0.35

    private static let silhouetteOpacity = 0.85

    /// The 6pt recording disc. The scale stops at `sm`; 6pt is `sm` less two
    /// hairlines, which is how the value is spelled rather than as a literal.
    private static let discDiameter = Spacing.sm - Spacing.hair * 2

    private var plate: Plate? { PlateAssignment.plate(for: code) }

    /// Selected is a full `wash` fill; hover is the same fill at half strength.
    /// No movement and no scale — things settle onto the board, they do not
    /// slide (DESIGN.md §6).
    private var fill: Double {
        if isSelected { return 1 }
        return isHovering ? 0.5 : 0
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: Spacing.md) {
                silhouette
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(code)
                        .font(isSelected ? Typography.uiBold : Typography.ui)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if let plate {
                        // The determination line: quiet, italic, a binomial set
                        // the way it is set on a herbarium label.
                        Text(plate.species)
                            .font(Typography.caption)
                            .italic()
                            .tracking(Typography.captionTracking)
                            .foregroundStyle(Palette.inkSoft)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                if isRecording { recordingDisc }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(height: Self.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(alignment: .leading) {
            Palette.wash.opacity(fill)
            if isSelected {
                // An inset rule that closes the plate on its inside edge — held
                // clear of the row's own edge, because a rule flush to the
                // boundary is a coloured side stripe, which is banned.
                Rectangle()
                    .fill(Palette.plate)
                    .frame(width: Spacing.plateBorderOuter)
                    .padding(.vertical, Spacing.sm)
                    .padding(.leading, Spacing.xs)
            }
        }
        .animation(Motion.settle.animation(reduceMotion: reduceMotion), value: fill)
        .onHover { isHovering = $0 }
        // Set on the Button rather than on a synthesised element, so the row
        // keeps its activation point for VoiceOver and Full Keyboard Access.
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isRecording ? "Recording" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(name.isEmpty ? code : "\(code) — \(name)")
    }

    /// The plate itself, small, as the course's identity.
    ///
    /// DESIGN.md asks for a monochrome silhouette, and two attempts at one were
    /// made with `luminanceToAlpha`. Both produced a solid filled square, and
    /// the reason is the source material rather than the technique: a Köhler
    /// plate is a dense colour illustration filling its frame, not sparse
    /// linework on white paper, so there is no threshold that leaves a
    /// recognisable outline. Showing the plate is also truer to a herbarium
    /// sheet, where the specimen is the identifier.
    ///
    /// Held quiet so it identifies without competing with the course code:
    /// desaturated toward the board and inset in a hairline mount.
    @ViewBuilder private var silhouette: some View {
        if let plate {
            plate.image
                .resizable()
                .scaledToFill()
                .frame(width: Spacing.xxl, height: Spacing.xxl)
                .clipped()
                .saturation(Self.plateSaturation)
                .opacity(Self.silhouetteOpacity)
                .overlay {
                    Rectangle().strokeBorder(Palette.rule, lineWidth: Spacing.hair)
                }
                .accessibilityHidden(true)   // the species name carries this
        } else {
            // Keeps the identity column aligned when a plate is missing: an
            // empty mount reads as absence, a collapsed row reads as a bug.
            Rectangle()
                .strokeBorder(Palette.rule, lineWidth: Spacing.hair)
                .frame(width: Spacing.xxl, height: Spacing.xxl)
        }
    }

    /// Cinnabar, first of its three permitted uses (the live recording
    /// indicator; DESIGN.md §2). The disc is present only
    /// while this course is recording, so the state is carried by a mark
    /// appearing at all — shape, not hue — and it is named in the row's
    /// accessibility value and tooltip for anyone who reads neither.
    private var recordingDisc: some View {
        Circle()
            .fill(Palette.stamp)
            .frame(width: Self.discDiameter, height: Self.discDiameter)
            .help("Recording")
    }

    private var accessibilityLabel: String {
        var parts = [name.isEmpty ? code : "\(code), \(name)"]
        if let plate { parts.append("plate, \(plate.species)") }
        return parts.joined(separator: ". ")
    }
}
