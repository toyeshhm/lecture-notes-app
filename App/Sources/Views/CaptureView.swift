import Foundation
import LectureKit
import SwiftUI

/// The live capture surface: board plane, one sheet mounted on it.
///
/// This is the surface the legibility guardrail protects. Everything textured —
/// grain, plate mark — belongs to `BoardBackground`; the sheet is a flat
/// `Palette.sheet` fill and nothing is ever drawn underneath the prose on it.
///
/// The sheet does not widen with the window. It stops at `Spacing.sheetMax` and
/// the board grows around it; prose inside stops again at `Spacing.measure`.
/// Code fences are the one thing allowed past the measure, and only inside their
/// own horizontal scroller (DESIGN.md §3).
struct CaptureView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// How much raw transcript stays on screen. It is a rolling window, not a
    /// log: the kept transcript comes from the batch pass after the recording
    /// stops, so there is nothing to gain from keeping the whole stream mounted.
    private static let transcriptWindow = 600

    @State private var pulsing = false

    // This body is invalidated at the rate `elapsed` ticks — one audio buffer,
    // so roughly twelve times a second for the whole lecture. Anything costly
    // that does not depend on the clock belongs in its own view: `@Observable`
    // scopes tracking to the `body` that read a property, so a computed
    // property here sits inside the clock's tracking scope and a child does not.
    var body: some View {
        ScrollView(.vertical) {
            sheet
                .frame(maxWidth: Spacing.sheetMax)
                .frame(maxWidth: .infinity)   // centres the sheet, grows the mount
                .padding(.horizontal, Spacing.mount)
                .padding(.vertical, Spacing.plate)
        }
        // A live pass appends a section every few minutes. Anchoring the scroll
        // to the top means that growth extends the document downward instead of
        // pulling the viewport out from under whatever is being read.
        .defaultScrollAnchor(.top)
        .background(BoardBackground())
    }

    // MARK: Sheet

    private var sheet: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header
            plateRule
            NotesSection()
            if !session.transcript.isEmpty {
                plateRule
                rawTranscript
            }
            plateRule
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The sheet fill goes *outside* the plate frame, per `PlateFrame`'s own
        // contract: mounted inside it, the frame's border band would be board —
        // grain and all — inside the rule that is supposed to close the sheet.
        .plateFrame(padding: Spacing.sheetPadding)
        .background(Palette.sheet)
    }

    /// A rule reads heavier than the space it occupies, so it takes `xl` above
    /// and `lg` below — the stack's own spacing supplies the `lg`.
    private var plateRule: some View {
        Rectangle()
            .fill(Palette.rule)
            .frame(height: Spacing.hair)
            .padding(.top, Spacing.sm)
            .accessibilityHidden(true)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.lg) {
                Text(SessionModel.clock(session.elapsed))
                    .font(Typography.h2Mono)
                    .foregroundStyle(Palette.ink)
                    .accessibilityLabel("Elapsed \(session.spokenElapsed)")
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer(minLength: Spacing.lg)
                stateMark
            }
            Text(session.topic)
                .font(Typography.h1)
                .foregroundStyle(Palette.ink)
                // The sheet's only heading, so it is the rotor's only landmark.
                .accessibilityAddTraits(.isHeader)
            SpecimenLabel(title: "\(session.course) · \(LectureNote.today())")
        }
        .frame(maxWidth: Spacing.measure, alignment: .leading)
    }

    /// Recording state, carried three ways at once: a filled disc versus a
    /// hollow ring, the word beside it, and only then the cinnabar. Anyone who
    /// cannot see the pigment still reads the state from the shape or the word.
    private var stateMark: some View {
        HStack(spacing: Spacing.sm) {
            indicator
            Text(session.stateWord)
                .font(Typography.caption.smallCaps())
                .tracking(Typography.captionTracking)
                .foregroundStyle(Palette.ink)
        }
        // Label is the word on screen, not `statusLine`: at rest the mark reads
        // "Ready" while `statusLine` says "Saved", and an accessible name that
        // contradicts the visible one is what Voice Control matches against.
        // The longer status still gets through, as the value.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.stateWord)
        .accessibilityValue(session.statusLine == session.stateWord ? "" : session.statusLine)
    }

    private var indicator: some View {
        ZStack {
            // The ring never moves or fills, so the outline of the mark is
            // stable mid-pulse and the disc is the only thing that changes.
            Circle().strokeBorder(Palette.rule, lineWidth: Spacing.hair)
            if isRecording {
                if reduceMotion {
                    // No pulse under Reduce Motion. The disc alternates present
                    // and absent at 1Hz instead: still unmistakably live, with
                    // nothing in motion.
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        disc.opacity(
                            Int(context.date.timeIntervalSinceReferenceDate * 2).isMultiple(of: 2) ? 1 : 0
                        )
                    }
                } else {
                    disc
                        .opacity(pulsing ? 0.55 : 1)
                        .onAppear { withAnimation(pulseAnimation) { pulsing = true } }
                        .onDisappear { pulsing = false }
                }
            }
        }
        .frame(width: Spacing.lg, height: Spacing.lg)
    }

    /// `DESIGN.md` §5.3 sets the disc at 10pt. The scale has no 10pt step, so it
    /// is spelled as `sm` plus two hairlines rather than as a bare literal —
    /// the same idiom the sidebar's 6pt disc uses.
    private static let discDiameter = Spacing.sm + Spacing.hair * 2

    private var disc: some View {
        Circle()
            .fill(Palette.stamp)
            .frame(width: Self.discDiameter, height: Self.discDiameter)
    }

    private var pulseAnimation: Animation? {
        Motion.pulse.animation(reduceMotion: reduceMotion)?.repeatForever(autoreverses: true)
    }

    // MARK: Raw transcript — secondary, and provisional

    private var rawTranscript: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SpecimenLabel(title: "Raw speech · discarded and re-transcribed when you stop")
            Text(transcriptTail)
                .font(Typography.ui)
                .italic()   // provisional by shape, not only by weight of colour
                .foregroundStyle(Palette.inkSoft)
                .lineSpacing(Typography.bodyLineSpacing(isDark: colorScheme == .dark))
                .frame(maxWidth: Spacing.measure, alignment: .leading)
        }
        // .contain, not .combine: the transcript itself must stay readable to
        // VoiceOver rather than being collapsed into the caption.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Raw transcript, provisional. Replaced by a full pass when the recording stops.")
    }

    /// The tail of the stream, without walking the whole string: `count` on a
    /// forty-thousand-word transcript would run on every recognised phrase.
    private var transcriptTail: String {
        let text = session.transcript
        guard let start = text.index(
            text.endIndex, offsetBy: -Self.transcriptWindow, limitedBy: text.startIndex
        ) else {
            return text
        }
        return "…\(text[start...])"
    }

    // MARK: Footer

    private var footer: some View {
        Text(session.notePath?.path(percentEncoded: false) ?? "Not filed yet — the path appears once the course is detected.")
            .font(Typography.micro)
            .foregroundStyle(Palette.inkSoft)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .accessibilityLabel(
                session.notePath.map { "Writing to \($0.path(percentEncoded: false))" }
                    ?? "Not filed yet. The path appears once the course is detected."
            )
    }

    // MARK: Derived state

    private var isRecording: Bool {
        session.phase == .recording
    }
}

// MARK: - Live notes — the reading content

/// The notes themselves, and the empty/failed state that stands in for them.
///
/// Its own `View` rather than a computed property on `CaptureView`, because
/// `@Observable` scopes tracking to the `body` that read a property: mounted
/// inside `CaptureView.body` this re-split the entire live-notes markdown and
/// rebuilt every block each time `elapsed` ticked — twelve times a second,
/// over a document that grows for the whole lecture. Here it only tracks the
/// strings it actually reads, so it redraws when a live pass lands and not
/// before. `NotesSection` has no stored properties, so `CaptureView` redrawing
/// does not drag it along.
private struct NotesSection: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder var body: some View {
        if session.liveNotes.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(Array(Self.blocks(session.liveNotes).enumerated()), id: \.offset) { item in
                    switch item.element {
                    case .prose(let text):
                        Text(text)
                            .font(Typography.bodyText)
                            .foregroundStyle(Palette.ink)
                            .lineSpacing(Typography.bodyLineSpacing(isDark: colorScheme == .dark))
                            .textSelection(.enabled)
                            .frame(maxWidth: Spacing.measure, alignment: .leading)
                    case .code(let text):
                        codeBlock(text)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Live notes")
        }
    }

    /// The measure exception. A hundred-column code block is core material for
    /// the student this is for, so it runs to the full sheet width and scrolls
    /// inside its own container rather than wrapping or shrinking.
    private func codeBlock(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(Typography.code)
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .padding(Spacing.md)
        }
        .background(Palette.wash)
        .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Spacing.hair))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Says what the sheet will do, not that it is empty. This is the state the
    /// app sits in before every lecture, so it is the one that has to teach.
    ///
    /// The explanation is dropped once the headline is a failure: telling
    /// someone what the app is about to do, directly under the reason it just
    /// stopped, contradicts itself.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(emptyHeadline)
                .font(Typography.runIn)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Spacing.measure, alignment: .leading)
            if !hasFailed {
                Text(
                    """
                    Speech is recognised on this Mac and appears below as raw text \
                    within a few seconds. Every few minutes it is rewritten into \
                    structured notes here, on this sheet. When you stop, the whole \
                    lecture is transcribed again in one pass, the notes are written \
                    in full, and the file is filed under its course in your vault.
                    """
                )
                .font(Typography.bodyText)
                .foregroundStyle(Palette.inkSoft)
                .lineSpacing(Typography.bodyLineSpacing(isDark: colorScheme == .dark))
                .frame(maxWidth: Spacing.measure, alignment: .leading)
            }
        }
    }

    private var hasFailed: Bool {
        if case .failed = session.phase { return true }
        return false
    }

    private var emptyHeadline: String {
        switch session.phase {
        case .idle: return "Nothing recorded yet."
        case .preparing, .finishing: return session.statusLine
        case .recording: return "Listening. Notes arrive after the first few minutes of speech."
        case .failed(let message): return message
        }
    }

    // MARK: Markdown blocks

    private enum Block {
        case prose(String)
        case code(String)
    }

    /// Splits live notes at fenced code blocks so prose can be held to the
    /// measure while fences are not.
    ///
    /// ponytail: fences only. Tables and display maths also earn the exception
    /// per DESIGN.md §3, but the live pass emits prose and code; add them here
    /// when the note reader's full renderer lands, and share one splitter.
    private static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var current: [Substring] = []
        var inFence = false

        func flush() {
            let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(inFence ? .code(text) : .prose(text)) }
            current = []
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                flush()
                inFence.toggle()
            } else {
                current.append(line)
            }
        }
        flush()
        return blocks
    }
}
