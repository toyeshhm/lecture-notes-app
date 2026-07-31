import Foundation
import LectureKit
import SwiftUI

/// The library: a course as a scene with its lectures listed beneath it.
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
                            selection: $selection,
                            sceneIndex: index)
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

// MARK: - Course

/// One course: its scene, its name, and every lecture filed under it.
private struct CoursePlate: View {
    let course: String
    let lectures: [LibraryLecture]
    /// Where a lecture for this course would land. Shown when there are none.
    let directory: URL
    @Binding var selection: LibraryLecture?

    /// The header band.
    ///
    /// A 16:9 crop deep enough to read as a place, with room for the title over
    /// it. Shorter than the record screen's hero, because a folio stacks several
    /// of these and a full-height band each would make two courses a scroll.
    private static let headerHeight = Spacing.mount * 2

    /// The course's scene, spread across the set rather than hashed to it.
    ///
    /// `Scenery.scene(for:)` hashes the course code, which is right in the
    /// sidebar where each row is seen on its own. In a folio the courses are
    /// stacked and adjacent, and with four scenes and three courses a hash
    /// collision is likelier than not — two courses in a row drew the same
    /// waterfall, which reads as a bug rather than as a coincidence. Position in
    /// the list cannot collide.
    let sceneIndex: Int

    private var scene: Backdrop? { Scenery.scene(atOffset: sceneIndex) }

    /// 6pt, per §5.2. The scale has no 6, so it is spelled the way `CourseRow`
    /// spells its disc: `sm` less two hairlines.
    private static let underlineGap = Spacing.sm - Spacing.hair * 2

    @Environment(\.colorScheme) private var colorScheme

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

    /// The course's scene, full width, with the title sitting on it.
    ///
    /// It was a left-third crop of a Köhler plate beside a title block. Cropping
    /// a portrait engraving into a wide band left a sliver of stem, which is why
    /// the band had to be three `mount` units tall to be legible at all — and the
    /// composition then had a large empty right half. A 16:9 photograph fills the
    /// band at its own aspect and the title goes on top of it, which is both
    /// truer to the direction and less geometry.
    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            HeroBand(scene: scene, height: Self.headerHeight)
            titleBlock
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.lg)
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

            // How many lectures are filed here and when the latest was, set as
            // one line. Never a pill or a chip row.
            if let tally {
                SpecimenLabel(title: tally)
                    .padding(.top, Spacing.xs)
            }
        }
        // No trailing Spacer. The block is bottom-aligned inside the hero, and a
        // Spacer inside it pushed the title to the top of the band and left the
        // rest of the composition empty above the first row.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var tally: String? {
        guard let newest = lectures.first else { return nil }
        // "Lectures", not "sheets": the herbarium metaphor went with the
        // botanical plates, and a student has lectures.
        let count = lectures.count == 1 ? "1 lecture" : "\(lectures.count) lectures"
        // `scan` returns newest first, so the head of the list is the last
        // lecture recorded.
        return "\(count) · latest \(newest.date)"
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

    /// The same figure in words. "1 h 30 min" is set for the eye and read out as
    /// the letters, so the caption line keeps the engraved form and the row's
    /// label carries this one.
    private var spokenDuration: String {
        guard let minutes = lecture.durationMinutes.map({ max($0, 0) }) else { return "" }
        return Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .wide))
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
                        Text("Unfinished. The recording ended before the notes were written.")
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
            spokenDuration,
            HatchSwatch.densityDescription(wordsPerMinute: lecture.wordsPerMinute),
        ]
        if !isComplete { parts.append("Unfinished") }
        // A note with no date or no duration would otherwise contribute an empty
        // part, which joins as a doubled full stop and reads as a pause where
        // nothing was said.
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
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

            Text("Record one. It is transcribed on this Mac, filed under the course it was detected as, and appears here once the notes are written.")
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
