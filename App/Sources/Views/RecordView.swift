import LectureKit
import SwiftUI

/// The home of the app: start a lecture, or watch the one that is running.
///
/// One surface for both states rather than a separate idle screen and capture
/// screen. The transition from "about to record" to "recording" is the single
/// most important moment in the product and it happens with a lecture already
/// starting; swapping the whole pane out at that instant is how you lose your
/// place. The hero, the title block and the button stay where they are, and only
/// what they say changes.
struct RecordView: View {

    @Environment(SessionModel.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private var isRecording: Bool { session.phase == .recording }

    /// The course's own scene while one is known, so the screen looks like the
    /// lecture it is recording rather than like the app.
    private var scene: Backdrop? {
        isRecording ? Scenery.scene(for: session.course) : Scenery.scene(named: "clearing")
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                hero
                content(for: session.phase)
            }
        }
        .defaultScrollAnchor(.top)
        .background(Palette.board)
    }

    // MARK: Hero

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            HeroBand(scene: scene, height: Spacing.heroHeight)
            HStack(alignment: .bottom, spacing: Spacing.xl) {
                titleBlock
                Spacer(minLength: Spacing.lg)
                controls
            }
            .padding(Spacing.xl)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            stateMark
            Text(headline)
                .font(Typography.h1)
                .tracking(Typography.h1Tracking)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            // While preparing, this line is the only thing telling the user the
            // app is alive. Loading the models is slow enough that a static
            // "Preparing" reads as a hang, so the step is named.
            Text(subtitle)
                .font(Typography.ui)
                .foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headline: String {
        switch session.phase {
        case .recording: return session.topic
        case .preparing: return "Getting ready"
        case .finishing: return "Writing your notes"
        case .failed: return "Recording stopped"
        case .idle: return "Ready to record"
        }
    }

    private var subtitle: String {
        switch session.phase {
        case .recording: return "\(displayCourse) · \(LectureNote.today())"
        case .preparing, .finishing: return session.statusLine
        case .failed: return session.statusLine
        case .idle: return "Notes are written when you stop."
        }
    }

    private var displayCourse: String {
        session.course == unsortedFolder ? "Detecting the course…" : session.course
    }

    /// State three ways at once: the shape of the mark, the word beside it, and
    /// only then the warm light. Anyone who cannot see the accent still reads it.
    private var stateMark: some View {
        HStack(spacing: Spacing.sm) {
            indicator
            Text(session.stateWord.uppercased())
                .font(Typography.caption.smallCaps())
                .tracking(Typography.captionTracking)
                .foregroundStyle(isRecording ? Palette.stamp : Palette.inkSoft)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.stateWord)
        .accessibilityValue(session.statusLine == session.stateWord ? "" : session.statusLine)
    }

    private var indicator: some View {
        ZStack {
            Circle()
                .strokeBorder(isRecording ? Palette.stamp : Palette.rule, lineWidth: Spacing.hair)
            if isRecording {
                if reduceMotion {
                    // No pulse under Reduce Motion. The disc alternates filled and
                    // hollow at 1Hz instead — unmistakably live, nothing moving.
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        if Int(context.date.timeIntervalSinceReferenceDate * 2).isMultiple(of: 2) {
                            disc
                        } else {
                            disc.opacity(0).overlay(
                                Circle().strokeBorder(Palette.stamp, lineWidth: Spacing.hair))
                        }
                    }
                } else {
                    disc
                        .opacity(pulsing ? 0.55 : 1)
                        .onAppear { withAnimation(Motion.pulse.animation(reduceMotion: false)?.repeatForever(autoreverses: true)) { pulsing = true } }
                        .onDisappear { pulsing = false }
                }
            }
        }
        .frame(width: Spacing.md, height: Spacing.md)
    }

    private var disc: some View {
        Circle()
            .fill(Palette.stamp)
            .frame(width: Spacing.sm, height: Spacing.sm)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .trailing, spacing: Spacing.md) {
            if isRecording || session.phase.isBusy {
                Text(SessionModel.clock(session.elapsed))
                    .font(Typography.h2Mono)
                    .foregroundStyle(Palette.ink)
                    .accessibilityLabel("Elapsed \(session.spokenElapsed)")
                    .accessibilityAddTraits(.updatesFrequently)
            }
            primaryButton
        }
    }

    /// The control the shipped window did not have. Filled with the accent
    /// because there is exactly one primary action on this screen, and hunting
    /// for it is how you lose the first minute of a lecture.
    private var primaryButton: some View {
        Button(action: session.toggle) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: isRecording ? "stop.fill" : "record.circle.fill")
                    .font(.system(size: 12))
                Text(buttonTitle)
                    .font(Typography.uiBold)
            }
            .foregroundStyle(Palette.board)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .background(Palette.stamp, in: RoundedRectangle(cornerRadius: Spacing.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.phase.isBusy)
        // No ⌘R here. The same shortcut is on the File-menu command in
        // `LectureNotesApp`, which works from every section and from the menu bar
        // popover; declaring it twice makes which one fires a matter of which
        // view happens to be in the responder chain.
        .accessibilityLabel(buttonTitle)
        .accessibilityHint(isRecording ? "Writes the notes into your vault" : "Starts a new lecture")
    }

    private var buttonTitle: String {
        switch session.phase {
        case .recording: return "Stop & Write"
        case .preparing: return "Preparing…"
        case .finishing: return "Writing…"
        default: return "Start Recording"
        }
    }

    // MARK: Body

    @ViewBuilder private func content(for phase: SessionModel.Phase) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            switch phase {
            case .idle where session.transcript.isEmpty:
                readyNotes
            case .failed(let why):
                failure(why)
            default:
                liveTranscript
            }
        }
        .frame(maxWidth: Spacing.sheetMax, alignment: .leading)
        .padding(Spacing.xl)
    }

    /// What the app is about to do, in the words of someone who has not read the
    /// README. Shown while idle, which is when it can actually be read.
    private var readyNotes: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionRule("What happens when you record")
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                    Text("—").foregroundStyle(Palette.inkSoft)
                    Text(step)
                        .foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(Typography.bodyText)
        }
    }

    private static let steps = [
        "Your Mac transcribes the lecture as it happens. No audio leaves the machine.",
        "Every few minutes Claude writes interim notes, so you have something even if the recording ends badly.",
        "When you stop, the whole lecture is re-transcribed and written up properly, then filed under the course it worked out.",
    ]

    private var liveTranscript: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionRule("Live transcript")
            if session.transcript.isEmpty {
                Text("Listening…")
                    .font(Typography.bodyText)
                    .foregroundStyle(Palette.inkSoft)
            } else {
                Text(session.transcript.suffix(1200))
                    .font(Typography.bodyText)
                    .foregroundStyle(Palette.inkSoft)
                    .lineSpacing(Typography.bodyLineSpacing(isDark: true))
                    .frame(maxWidth: Spacing.measure, alignment: .leading)
                    .textSelection(.enabled)
            }
            if !session.liveNotes.isEmpty {
                sectionRule("Notes so far")
                NoteMarkdown(source: session.liveNotes, measure: Spacing.measure)
            }
            if let path = session.notePath {
                Text(path.path(percentEncoded: false))
                    .font(Typography.micro)
                    .tracking(Typography.microTracking)
                    .foregroundStyle(Palette.inkSoft)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.top, Spacing.sm)
            }
        }
    }

    private func failure(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionRule("Stopped")
            Text(why)
                .font(Typography.bodyText)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionRule(_ title: String) -> some View {
        HStack(spacing: Spacing.md) {
            Text(title)
                .font(Typography.caption.smallCaps())
                .tracking(Typography.captionTracking)
                .foregroundStyle(Palette.inkSoft)
            Rectangle().fill(Palette.rule).frame(height: Spacing.hair)
        }
        .accessibilityAddTraits(.isHeader)
    }
}
