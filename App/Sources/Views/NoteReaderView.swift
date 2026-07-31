import Foundation
import LectureKit
import SwiftUI

/// A past lecture, read back (DESIGN.md §5.5). The product: everything on this
/// surface defers to Charter at 17pt.
///
/// The note body is rendered by ``NoteMarkdown``; the plate border and the
/// dark-appearance shadow by ``PlateFrame``; the caption line by
/// ``SpecimenLabel``. What this view owns is the file: reading it off the main
/// actor, stripping what the reader draws itself, and staying a reading surface
/// when the file is no longer there.
struct NoteReaderView: View {

    let entry: LibraryLecture

    /// Back to the library. The reader fills the detail pane rather than
    /// presenting over it, so there is no system-supplied way out and Escape
    /// alone would leave the control invisible to the pointer.
    let close: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Bumped by "Look again", which is the only way a re-read gets requested;
    /// `.task(id:)` restarts on any change to either half.
    @State private var reloads = 0
    @State private var content: Content = .loading

    private enum Content: Equatable {
        case loading
        case note(String)
        /// The file is gone from this path. Renaming or deleting a note in
        /// Obsidian is ordinary housekeeping, not an error.
        case missing
        /// Present but unreadable: an unmounted volume, a permission the app
        /// does not hold, bytes that are not UTF-8.
        case unreadable
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xl) {
                    backToLibrary
                    LectureActionBar(entry: entry, reload: { reloads += 1 })
                }
                sheet
                // Outside the plate border, bottom left, where "Drawn from
                // nature by W.H. Fitch" sits on a Curtis plate (§5.4).
                SpecimenLabel(title: captionTitle, detail: captionDetail)
            }
            .frame(maxWidth: Spacing.sheetMax)
            .frame(maxWidth: .infinity)   // centres the sheet, grows the mount
            .padding(.horizontal, Spacing.mount)
            .padding(.vertical, Spacing.plate)
        }
        .defaultScrollAnchor(.top)
        .background(BoardBackground())
        .animation(Motion.mount.animation(reduceMotion: reduceMotion), value: content)
        .task(id: [entry.url.path(percentEncoded: false), String(reloads)]) {
            await load()
        }
    }

    /// Set in the board margin above the sheet, not on it: the sheet is the
    /// specimen and nothing that is not the note goes inside its border.
    private var backToLibrary: some View {
        Button(action: close) {
            Text("← \(entry.course)")
                .font(Typography.caption.smallCaps())
                .tracking(Typography.captionTracking)
                .foregroundStyle(Palette.inkSoft)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
        .accessibilityLabel("Back to \(entry.course)")
    }

    // MARK: Sheet

    /// The sheet fill sits *outside* the plate frame, per ``PlateFrame``'s
    /// contract, and the frame supplies both the 1.5pt `plate` rule and the
    /// hard-edged shadow that the dark appearance's 1.13:1 plane step cannot
    /// carry on its own (§1).
    private var sheet: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            title
            noteBody(for: content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The gutter is a left margin on the sheet's content, not a column
        // beside the sheet: the hairlines are engraved shading on this plate.
        .padding(.leading, Spacing.gutterWidth)
        .plateFrame(padding: Spacing.sheetPadding)
        .background(Palette.sheet)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(entry.topic)
                .font(Typography.h1)
                .tracking(Typography.h1Tracking)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Rectangle()
                .fill(Palette.rule)
                .frame(height: Spacing.hair)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: Spacing.measure, alignment: .leading)
    }

    @ViewBuilder
    private func noteBody(for content: Content) -> some View {
        switch content {
        case .loading:
            // Deliberately blank. A local file resolves inside a frame or two,
            // and a spinner that appears and vanishes reads as a fault.
            Color.clear.frame(height: Spacing.mount)

        case let .note(source):
            NoteMarkdown(source: source, measure: Spacing.measure)
                // Charter's natural leading at 17pt is short of the 1.62 (light)
                // and 1.70 (dark) targets, and light type on a dark ground needs
                // the larger of the two. Set here rather than per block: it is
                // the reading surface's setting, not the renderer's.
                .lineSpacing(Typography.bodyLineSpacing(isDark: colorScheme == .dark))
                // People quote from a lecture note. Set on the container as well
                // as on the blocks so a selection can run across them.
                .textSelection(.enabled)

        case .missing, .unreadable:
            absent
        }
    }

    // MARK: Absent

    /// A note deleted or renamed in Obsidian since the last scan is a normal
    /// occurrence. It gets the same sheet, the same frame and the same caption
    /// as any other note — the difference is that the sheet says what is not
    /// there and offers to look again, rather than showing a failure screen.
    private var absent: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(content == .missing
                ? "This note is no longer at this path. It was probably renamed or moved in Obsidian."
                : "This note could not be read. Its volume may not be mounted.")
                .font(Typography.bodyText)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(entry.url.path(percentEncoded: false))
                .font(Typography.micro)
                .tracking(Typography.microTracking)
                .foregroundStyle(Palette.inkSoft)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)

            // Re-reads this one file rather than rescanning the library: the
            // library owns its own scan, and the answer the reader needs is
            // whether this path resolves now.
            Button { reloads += 1 } label: {
                // Padding and border inside the label, so the whole plate is the
                // click target rather than the four words in the middle of it.
                Text("Look again")
                    .font(Typography.uiBold)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .overlay { Rectangle().strokeBorder(Palette.plate, lineWidth: Spacing.hair) }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: Spacing.measure, alignment: .leading)
    }

    // MARK: Caption

    /// `_Unsorted` is a real folder and a real state, but it is a path spelling;
    /// the caption line is prose.
    private var captionTitle: String {
        entry.course == unsortedFolder ? "Unsorted" : entry.course
    }

    /// The typed half: the date as written in the frontmatter, the duration, and
    /// the unfinished state when the note never got its final pass. That state
    /// is carried by the word, never by a mark or a colour.
    private var captionDetail: String {
        var parts = [entry.date]
        // A duration the frontmatter never carried is left out rather than shown
        // as zero: "0 min" is a claim about the lecture, absence is a claim about
        // the file.
        if let minutes = entry.durationMinutes { parts.append("\(minutes) min") }
        if entry.status != "complete" { parts.append("incomplete") }
        return parts.joined(separator: " · ")
    }

    // MARK: Loading

    private func load() async {
        let url = entry.url
        // Off the main actor: the vault can be on a network volume or an
        // external disk, where a read is not a frame's worth of work.
        content = await Task.detached {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
                    ? Content.unreadable
                    : Content.missing
            }
            return .note(NoteSource.body(of: raw))
        }.value
    }
}

// MARK: - Source

/// Reduces a note file to the part the reader renders.
///
/// Free of the view so it can run on the reading task's actor rather than
/// hopping back to the main one for a string operation.
private enum NoteSource {

    static func body(of raw: String) -> String {
        var lines = raw.components(separatedBy: .newlines)
        dropFrontmatter(&lines)
        dropLeadingBlanks(&lines)

        // The file opens with `# <topic>` and a `**Course** · date` byline,
        // both of which this view already draws — as the h1 with its rule and as
        // the caption line. Rendered again they read as the note repeating
        // itself. Only the leading pair is dropped; a heading further down is a
        // section and belongs to the reader.
        if lines.first?.hasPrefix("# ") == true {
            lines.removeFirst()
            dropLeadingBlanks(&lines)
            if lines.first?.firstMatch(of: /^\*\*.+\*\*\s*·/) != nil {
                lines.removeFirst()
            }
        }
        dropLeadingBlanks(&lines)
        return lines.joined(separator: "\n")
    }

    /// Removes the YAML block, which is metadata and already in the caption.
    ///
    /// A block with no closing fence is left alone rather than guessed at: a
    /// hand-edited note whose frontmatter is malformed still has a body, and
    /// dropping to the next `---` in an unfenced file would swallow it. Showing
    /// a few lines of YAML is the smaller failure.
    private static func dropFrontmatter(_ lines: inout [String]) {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return }
        guard let close = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return }
        lines.removeSubrange(0...close)
    }

    private static func dropLeadingBlanks(_ lines: inout [String]) {
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
    }
}

// MARK: - Deferred

// The hatching gutter (§5.5) is not built here. It is 24pt of hairlines whose
// spacing encodes speech density minute by minute and whose drag scrubs the
// audio, so it is not a decoration that can be added to a static view later: it
// needs the per-minute density series and a live playback position, and audio
// playback is being written in parallel. Half a gutter — hatching that does not
// scrub, or scrubbing without density — is worse than none, because the design
// makes the scrollbar, the timeline and the plate's shading one object, and a
// version where only one of the three is true teaches the wrong affordance.
//
// The 24pt margin it occupies is already reserved above, so adding it does not
// move a single line of prose. When it lands it takes that inset, draws
// `inkSoft` hairlines snapped to whole device pixels at no more than
// `Spacing.gutterMaxDensity` coverage, and carries its position and density as
// text in the accessibility tree beside a standard scrubber.
