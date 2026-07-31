import LectureKit
import SwiftUI

/// The library: a course opened as a full-plate composition with its lectures
/// listed beneath (`DESIGN.md` §5.2 and §5.4).
///
/// Nothing here is a card. A course is a composition on the board inside a
/// double plate border, and a lecture is a row on that same board separated from
/// its neighbours by one hairline. Several courses stack as a folio, never as a
/// grid of equal tiles: equal heights would make a course with two lectures and
/// a course with forty look like the same object.
struct LibraryView: View {

    /// The course to show. `nil` stacks every course in the vault.
    let course: String?

    /// The opened lecture. A binding so the reader can follow it without the
    /// library knowing what a reader is.
    @Binding var selection: LibraryLecture?

    @Environment(SessionModel.self) private var session

    @State private var scanned: [LibraryCourse] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if folios.isEmpty {
                    EmptyPlate(course: nil, directory: session.settings.coursesDir)
                } else {
                    ForEach(Array(folios.enumerated()), id: \.element.id) { index, folio in
                        // A hairline between plates, half a `mount` clear of
                        // each, so two compositions read as two mounted sheets
                        // on one board rather than one continuous list.
                        if index > 0 {
                            Rectangle()
                                .fill(Palette.rule)
                                .frame(height: Spacing.hair)
                                .padding(.vertical, Spacing.xxl)
                        }
                        CoursePlate(
                            course: folio.name,
                            lectures: folio.lectures,
                            directory: session.settings.lectureDirectory(course: folio.name),
                            selection: $selection)
                    }
                }
            }
            .padding(Spacing.mount)
        }
        .background(BoardBackground())
        // Re-reads on the sidebar's keys — the vault moving, and the session
        // settling on a course mid-lecture — plus the phase word, because a
        // lecture only exists on disk once the finishing pass has written it.
        // Without that third key the lecture you just recorded is missing from
        // the library it was filed into until the app is relaunched.
        .task(id: reloadKey) {
            await reload()
        }
    }

    // MARK: Grouping

    /// The scan, filtered to the selected course and reordered so `_Unsorted`
    /// trails.
    ///
    /// The scanner already groups by folder and sorts alphabetically; only the
    /// `_Unsorted` rule is added here, because it is a presentation choice rather
    /// than a fact about the disk.
    private var folios: [LibraryCourse] {
        // A named course keeps its plate even with nothing under it: an empty
        // composition states what is missing, an absent one states nothing. The
        // scanner enumerates the same directory the sidebar does, so a selected
        // course is present here unless it was deleted between the two scans —
        // and then the empty plate is the right thing to show anyway.
        if let course { return scanned.filter { $0.name == course } }

        return scanned.sorted { first, second in
            // `_Unsorted` is where detection gave up, not a course, so it sits at
            // the end rather than heading the library on a leading underscore.
            let firstIsUnsorted = first.name == unsortedFolder
            let secondIsUnsorted = second.name == unsortedFolder
            if firstIsUnsorted != secondIsUnsorted { return secondIsUnsorted }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }

    // MARK: Data

    private var reloadKey: [String] {
        [
            session.settings.coursesDir.path(percentEncoded: false),
            session.course,
            session.stateWord,
        ]
    }

    private func reload() async {
        let settings = session.settings
        // Scanning walks every course folder and opens every note's frontmatter;
        // off the main actor so a vault on a slow or unmounted network volume
        // cannot stall a frame.
        scanned = await Task.detached { LibraryScanner.scan(settings: settings) }.value
    }
}

// MARK: - Course plate

/// One course as a full-plate composition (`DESIGN.md` §5.2).
private struct CoursePlate: View {
    let course: String
    let lectures: [LibraryLecture]
    /// Where a lecture for this course would land. Shown when there are none.
    let directory: URL
    @Binding var selection: LibraryLecture?

    /// The header band.
    ///
    /// Set by the plate, not by the type. The title block needs about 76pt, but a
    /// Köhler plate is portrait at roughly 2:3, so cropping one into a 96pt band a
    /// third of the window wide leaves a horizontal sliver of stem — full-bleed
    /// in the literal sense and useless as identification. Three `mount` units
    /// gives the crop enough height that the plant is recognisable, which is the
    /// entire reason a course carries a plate.
    private static let headerHeight = Spacing.mount * 3

    /// 6pt, per §5.2. The scale has no 6, so it is spelled the way `CourseRow`
    /// spells its disc: `sm` less two hairlines.
    private static let underlineGap = Spacing.sm - Spacing.hair * 2

    @Environment(\.colorScheme) private var colorScheme

    private var plate: Plate? { PlateAssignment.plate(for: course) }

    /// A Köhler plate is dark linework on white paper, so at full strength on the
    /// near-black dark board it is a lit panel — precisely the glow §1 bans, and
    /// the brightest thing in a window whose reading surface sits at L 0.228.
    /// Pulling the whole image back darkens paper and plant together, so contrast
    /// *within* the plate is untouched and only its weight on the board changes.
    private var plateOpacity: Double { colorScheme == .dark ? 0.62 : 1 }

    /// `_Unsorted` is a folder name, not a course name, and it is the one value
    /// here that was never typed by a person.
    private var displayName: String {
        course == unsortedFolder ? "Unsorted" : course
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if lectures.isEmpty {
                EmptyPlate(course: displayName, directory: directory)
            } else {
                rows
            }
        }
        // Zero padding so the plate image reaches the inner hairline. Everything
        // that is type carries its own inset instead.
        .plateFrame(padding: 0)
    }

    // MARK: Header

    private var header: some View {
        // The one geometry read in the file, and it is bounded: a fixed height
        // with a proportional split inside it. §5.2 specifies the left *third*,
        // which no stack alignment expresses.
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 0) {
                silhouette
                    .frame(width: geo.size.width / 3, height: Self.headerHeight)
                    .clipped()
                titleBlock
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.lg)
            }
        }
        .frame(height: Self.headerHeight)
    }

    /// Full-bleed: no border, no inset, no rounding. The plate runs to the
    /// composition's inner edge and is cut off by it, the way an engraving is
    /// cut off by the sheet it was pressed onto.
    ///
    /// Shown at full strength here, unlike the sidebar's 35% saturation: at
    /// 32pt three plates in a column are a swatch book, but one plate at a
    /// third of the window is the specimen and is meant to be looked at.
    @ViewBuilder private var silhouette: some View {
        if let plate {
            // `scaledToFill` deliberately overflows, so the clip has to run
            // against a frame with two concrete sides. `maxHeight: .infinity`
            // inside a `GeometryReader` is not one: the reader proposes its size
            // but does not constrain what a child reports back, so the image kept
            // its own 2:3 aspect at a third of the window — roughly 300pt tall in
            // a 96pt band — and drew straight over the lecture rows beneath. The
            // caller supplies both sides now.
            plate.image
                .resizable()
                .scaledToFill()
                .opacity(plateOpacity)
                .accessibilityHidden(true)   // the species is in the caption line
        } else {
            // Keeps the third: a collapsed column would re-flow the title and
            // read as a layout bug rather than as a missing image.
            Color.clear
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Self.underlineGap) {
            Text(displayName)
                .font(Typography.plateTitle)
                .tracking(Typography.plateTitleTracking)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)   // a long course name shrinks; it never wraps

            Rectangle()
                .fill(Palette.rule)
                .frame(height: Spacing.hair)

            // The determination line: what this specimen is, and how many
            // sheets of it are filed. Never a pill or a chip row.
            SpecimenLabel(title: plate?.species ?? displayName, detail: tally)
                .padding(.top, Spacing.xs)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var tally: String? {
        guard let newest = lectures.first else { return nil }
        let sheets = lectures.count == 1 ? "1 sheet" : "\(lectures.count) sheets"
        // `scan` returns newest first, so the head of the list is the last
        // lecture recorded.
        return "\(sheets) · \(newest.date)"
    }

    // MARK: Rows

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lectures.enumerated()), id: \.element.id) { index, lecture in
                if index > 0 {
                    Rectangle()
                        .fill(Palette.rule)
                        .frame(height: Spacing.hair)
                        .padding(.horizontal, Spacing.md)
                }
                LectureRow(
                    lecture: lecture,
                    isSelected: selection == lecture,
                    select: { selection = lecture })
            }
        }
        // ponytail: no staggered entrance, though §6 allows the library one.
        // These rows live in a `LazyVStack`, so a stagger keyed on appearance
        // fires again every time a row scrolls back into view — the animation
        // would read as jitter rather than as one entrance.
    }
}

// MARK: - Library sheet row

/// One dated specimen filed under a course (`DESIGN.md` §5.4).
///
/// Board ground, no card, no border, no shadow: the row is a region of the
/// board, and the hairlines above and below it are the only structure it gets.
private struct LectureRow: View {
    let lecture: LibraryLecture
    let isSelected: Bool
    let select: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    /// 72pt, per §5.4: `mount` plus `sm`. No single token is that tall.
    private static let rowHeight = Spacing.mount + Spacing.sm

    /// Selected is a full `wash` fill, hover the same fill at half strength —
    /// the same two values `CourseRow` uses, so a row behaves identically in
    /// both columns. No movement on hover.
    private var fill: Double {
        if isSelected { return 1 }
        return isHovering ? 0.5 : 0
    }

    private var displayCourse: String {
        lecture.course == unsortedFolder ? "Unsorted" : lecture.course
    }

    /// Minutes as they are set on a label, or nothing at all.
    ///
    /// Clamped because the figure comes out of frontmatter a user can edit, and a
    /// negative duration would otherwise print as one. Empty when the note never
    /// carried a duration: "0 min" is a claim about the lecture, and an absent
    /// figure is a claim about the file, which is the true one.
    private var durationText: String {
        guard let minutes = lecture.durationMinutes.map({ max($0, 0) }) else { return "" }
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// `status: complete` is what the final pass writes. Anything else — the
    /// `recording` a crashed session leaves behind, or a value a person typed —
    /// is not a finished note.
    private var isComplete: Bool { lecture.status == "complete" }

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: Spacing.md) {
                HatchSwatch(wordsPerMinute: lecture.wordsPerMinute)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(lecture.topic)
                        .font(Typography.uiBold)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    // A note written mid-recording that never got its final
                    // pass. This is what a crashed session looks like from the
                    // library, and it is stated rather than styled: there is no
                    // colour, weight or icon carrying it.
                    if !isComplete {
                        Text("Unfinished — the recording ended before the final pass")
                            .font(Typography.ui)
                            .foregroundStyle(Palette.inkSoft)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 0)

                    // Hangs at the bottom left, outside any framing rule,
                    // exactly where "Drawn from nature by W.H. Fitch" sits on a
                    // Curtis plate. One line, never a chip row.
                    SpecimenLabel(
                        title: displayCourse,
                        detail: "\(lecture.date) · \(durationText)")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(height: Self.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Palette.wash.opacity(fill))
        .animation(Motion.settle.animation(reduceMotion: reduceMotion), value: fill)
        .onHover { isHovering = $0 }
        // On the Button itself, so the row keeps its activation point for
        // VoiceOver and Full Keyboard Access.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(lecture.url.path(percentEncoded: false))
    }

    /// Everything the row draws, including the hatch swatch's density, which is
    /// hidden from the tree precisely so it can be said here in words.
    private var accessibilityLabel: String {
        var parts = [
            lecture.topic,
            displayCourse,
            lecture.date,
            durationText,
            HatchSwatch.densityDescription(wordsPerMinute: lecture.wordsPerMinute),
        ]
        if !isComplete { parts.append("unfinished") }
        return parts.joined(separator: ". ")
    }

    // §5.4 also specifies a type-specimen stamp on a course's canonical
    // lecture. It is not built, and deliberately: nothing in the data model
    // records which lecture is canonical, and choosing one — most recent?
    // longest? highest confidence? — decides what "canonical" means for the
    // product. That is a product decision, not a view's, and the pigment's
    // second job stays unspent until it is made.
}

// MARK: - Empty

/// A composition with nothing filed under it yet.
///
/// Names the thing that is missing and the folder it goes in, and does not
/// apologise for either — the same voice as the sidebar's empty column.
private struct EmptyPlate: View {
    /// The course this stands for, or `nil` for an empty vault.
    let course: String?
    let directory: URL

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(course.map { "No lectures under \($0)" } ?? "No lectures yet")
                .font(Typography.ui)
                .foregroundStyle(Palette.ink)

            Text("Record one. It is transcribed on this Mac, filed under the course it was detected as, and appears here when the final pass finishes.")
                .font(Typography.ui)
                .foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            // Selectable so the path can be copied into Finder or a terminal,
            // which is the whole point of showing it.
            Text(directory.path(percentEncoded: false))
                .font(Typography.micro)
                .tracking(Typography.microTracking)
                .foregroundStyle(Palette.inkSoft)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: Spacing.measure, alignment: .leading)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
    }
}
