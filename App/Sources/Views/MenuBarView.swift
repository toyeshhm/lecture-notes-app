import AppKit
import LectureKit
import SwiftUI

/// The menu bar popover.
///
/// This is the surface used while sitting down as a lecture starts, so it is
/// built around one unmissable action per phase: the primary button is
/// full-width, always in the same place, and always bound to Return. Nothing
/// here is read at length, so per `DESIGN.md` §5.6 the popover is board ground
/// with no sheet, no cards and `rule` hairlines for separation.
///
/// macOS draws the popover as a vibrant system material. We do not fight it:
/// the board colour goes on as a low-opacity tint so the material and the
/// system arrow survive.
struct MenuBarView: View {

    /// `DESIGN.md` §5.6: 240pt. There is no popover-width token, so the spec
    /// value is spelled here. The course and topic line wraps rather than
    /// widening the popover — `caption(_:)` is `fixedSize` on the vertical axis
    /// for exactly that reason.
    private static let width: CGFloat = 240

    /// Tint strength over the system material. Opaque fill would kill the
    /// vibrancy the popover is drawn with.
    private static let boardTint: Double = 0.6

    @Environment(SessionModel.self) private var session
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            switch session.phase {
            case .idle: idle
            case .preparing: preparing
            case .recording: recording
            case .finishing: finishing
            case .failed(let message): failed(message)
            }

            hairline
            footer
        }
        .padding(Spacing.md)
        .frame(width: Self.width)
        .background(Palette.board.opacity(Self.boardTint))
    }

    // MARK: Phases

    private var idle: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button("Start recording") { session.start() }
                .buttonStyle(PlateButtonStyle(reduceMotion: reduceMotion))
                .keyboardShortcut(.defaultAction)
                // Hint, not label: an accessible name that does not contain the
                // visible one ("Start recording a lecture" vs "Start recording")
                // is what Voice Control matches against, so overriding the label
                // makes the button unspeakable. Same everywhere below.
                .accessibilityHint("Records the lecture and files the notes in your vault")

            caption(filingDestination)
        }
    }

    private var preparing: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(session.statusLine)
                .font(Typography.ui)
                .foregroundStyle(Palette.ink)

            // Indeterminate progress is the status here, not decoration: the
            // first run downloads a multi-gigabyte model and a still popover
            // would read as hung. It stays under Reduce Motion for that reason.
            ProgressView()
                .progressViewStyle(.linear)
                .accessibilityLabel("Preparing to record")

            caption("The first run downloads the transcription model, which can take several minutes.")
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                RecordingStamp(reduceMotion: reduceMotion)

                // The word carries the state as well as the stamp does, so the
                // pigment is never the only signal.
                Text("Recording")
                    .font(Typography.caption.smallCaps())
                    .tracking(Typography.captionTracking)
                    .foregroundStyle(Palette.ink)

                Spacer()

                Text(SessionModel.clock(session.elapsed))
                    .font(Typography.h3Mono)
                    .foregroundStyle(Palette.ink)
                    // Without the spelled-out duration this reads as "Elapsed"
                    // and nothing else: a label on a Text replaces its content.
                    .accessibilityLabel("Elapsed \(session.spokenElapsed)")
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)

            LevelMeter(level: session.level)

            caption(session.course == unsortedFolder
                ? "Listening for the subject…"
                : "\(session.course) · \(session.topic)")

            Button("Stop & write") { session.stop() }
                .buttonStyle(PlateButtonStyle(reduceMotion: reduceMotion))
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Stops recording and writes the notes")
        }
    }

    private var finishing: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Writing notes…")
                .font(Typography.ui)
                .foregroundStyle(Palette.ink)

            Text(session.settings.finalModel)
                .font(Typography.micro)
                .tracking(Typography.microTracking)
                .foregroundStyle(Palette.inkSoft)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(message)
                .font(Typography.ui)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Button("Try again") { session.start() }
                .buttonStyle(PlateButtonStyle(reduceMotion: reduceMotion))
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Starts the recording over")
        }
    }

    // MARK: Chrome

    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Button("Open Lecture Notes") {
                openWindow(id: "main")
                // A menu bar extra does not activate the app, so without this
                // the window opens behind whatever the user was reading.
                NSApp.activate(ignoringOtherApps: true)
            }
            .accessibilityHint("Brings the main window to the front")

            if let note = session.notePath {
                Button("Reveal last note in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([note])
                }
                .accessibilityHint(note.lastPathComponent)
            }
        }
        .buttonStyle(.plain)
        .font(Typography.ui)
        .foregroundStyle(Palette.inkSoft)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Palette.rule)
            .frame(height: Spacing.hair)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption.smallCaps())
            .tracking(Typography.captionTracking)
            .foregroundStyle(Palette.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var filingDestination: String {
        session.settings.pinnedCourse.map { "Files under \($0)" } ?? "Course detected automatically"
    }
}

// MARK: - Recording stamp

/// The live indicator: a `stamp` disc inside a `rule` ring. One of the three
/// permitted uses of the pigment (`DESIGN.md` §2).
///
/// The ring never moves, so the mark keeps a stable outline whichever path runs.
private struct RecordingStamp: View {
    let reduceMotion: Bool

    @State private var dimmed = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Palette.rule, lineWidth: Spacing.hair)

            if reduceMotion {
                // No pulse: the disc alternates filled and hollow at 1Hz, so the
                // state stays unmistakably live as a *shape* change with no
                // movement. Driven off the timeline rather than a stored timer
                // because the view owns no other state.
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    disc.opacity(Self.isFilled(at: context.date) ? 1 : 0)
                }
            } else {
                disc
                    .opacity(dimmed ? 0.55 : 1)
                    .onAppear {
                        guard let pulse = Motion.pulse.animation(reduceMotion: false) else { return }
                        withAnimation(pulse.repeatForever(autoreverses: true)) { dimmed = true }
                    }
                    // The popover is dismissed and reshown many times during one
                    // recording, and its content view outlives each showing. Left
                    // set, `dimmed` is already `true` on the next `onAppear`, the
                    // animation has no state change to drive, and the mark comes
                    // back frozen at 0.55 — a dimmed disc that never pulses again.
                    .onDisappear { dimmed = false }
            }
        }
        .frame(width: Spacing.xl, height: Spacing.xl)
        // The "Recording" label and elapsed time beside it carry the state to
        // VoiceOver; the mark would only repeat them.
        .accessibilityHidden(true)
    }

    private var disc: some View {
        Circle()
            .fill(Palette.stamp)
            .frame(width: Spacing.md, height: Spacing.md)
    }

    private static func isFilled(at date: Date) -> Bool {
        Int(date.timeIntervalSinceReferenceDate * 2) % 2 == 0
    }
}

// MARK: - Primary button

/// The one prominent control in the popover: `wash` fill inside a 1.5pt `plate`
/// rule, `ui` Charter Bold in `ink`.
///
/// Not `.borderedProminent`: that would paint the system accent colour into a
/// palette whose only pigment is cinnabar, and cinnabar has exactly three jobs.
private struct PlateButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.uiBold)
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .background(Palette.wash)
            .overlay(Rectangle().strokeBorder(Palette.plate, lineWidth: Spacing.plateBorderOuter))
            // 0.55 is the system's one documented opacity floor (the pulse), so
            // press feedback borrows it rather than inventing a second value.
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(Motion.tap.animation(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}
