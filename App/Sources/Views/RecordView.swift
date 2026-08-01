import AppKit
import LectureKit
import UniformTypeIdentifiers
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
    @State private var link = ""

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
        // Refused rather than accepted-and-ignored when nothing dragged is a
        // PDF: returning true would show the drop as having worked.
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            guard !pdfs.isEmpty else { return false }
            Task { await session.addPDFs(pdfs) }
            return true
        }
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
        case .recording: return "\(displayCourse) · \(LectureNote.day())"
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
            inbox
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

    /// Files that arrived from somewhere else and are being written up.
    ///
    /// Shown because it is otherwise invisible work that spends subscription
    /// quota: the app would sit there apparently idle while calling a model
    /// about a lecture the user does not remember handing it.
    @ViewBuilder private var inbox: some View {
        if session.inboxPending > 0 || session.inboxWorking != nil {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                sectionRule("From your phone")
                if let working = session.inboxWorking {
                    Text("Writing up \(working)")
                        .font(Typography.bodyText)
                        .foregroundStyle(Palette.ink)
                }
                if session.inboxPending > 0 {
                    // "File", not "recording": the inbox takes PDFs as well now,
                    // and a count that calls a chapter of the textbook a
                    // recording reads as the app having mistaken what it found.
                    // Everything counted here is a file — a link is written up
                    // directly and never lands in the inbox.
                    Text(session.inboxPending == 1
                        ? "1 more file waiting."
                        : "\(session.inboxPending) more files waiting.")
                        .font(Typography.ui)
                        .foregroundStyle(Palette.inkSoft)
                }
            }
            .padding(.bottom, Spacing.lg)
        }
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

            fromPhone.padding(.top, Spacing.lg)
            readingSection.padding(.top, Spacing.lg)
        }
    }

    /// The inbox, made visible.
    ///
    /// It worked before this and could not be found: nothing in the app said the
    /// folder existed or where it was. That is the same failure the window had
    /// when Start Recording lived only in the menu bar — a feature with no
    /// surface is a feature nobody uses.
    ///
    /// "Show the folder" matters more than the picker. Adding a file here is a
    /// one-off; the thing worth doing once is opening the folder in Finder so a
    /// phone's share sheet can be pointed at it, after which the picker is never
    /// needed again.
    private var fromPhone: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionRule("Recorded somewhere else")
            Text("Audio dropped into the inbox folder in your vault is written up the same way. Your vault already syncs to your phone, so a voice memo shared into it arrives here on its own.")
                .font(Typography.bodyText)
                .foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.lg) {
                quietAction("Add a recording…") { chooseRecordings() }
                quietAction("Show the inbox folder") {
                    let inbox = session.settings.inboxDirectory
                    try? InboxWatcher.prepare(inbox)
                    NSWorkspace.shared.activateFileViewerSelecting([inbox])
                }
            }
        }
    }

    /// PDFs and web pages.
    ///
    /// A sibling of `fromPhone` rather than part of it: both are "material that
    /// did not come from the microphone", but one is a folder you point a share
    /// sheet at once and forget, and the other is a thing you do deliberately
    /// each time. Sharing a section would bury the folder.
    private var readingSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionRule("Something to read")
            Text("A PDF or a web page is read and written up the same way, filed under the course it belongs to. PDFs dropped into the inbox folder work too.")
                .font(Typography.bodyText)
                .foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            quietAction("Add a PDF…") { choosePDFs() }

            HStack(spacing: Spacing.md) {
                TextField("https://…", text: $link)
                    .textFieldStyle(.plain)
                    .font(Typography.ui)
                    .foregroundStyle(Palette.ink)
                    .padding(.vertical, Spacing.sm)
                    .padding(.horizontal, Spacing.md)
                    // A hairline, per DESIGN.md §2: `rule` is never the sole
                    // boundary of an interactive control, so the field also
                    // carries a `wash` fill.
                    .background(Palette.wash)
                    .overlay(Rectangle().stroke(Palette.rule, lineWidth: Spacing.hair))
                    .frame(maxWidth: 320)
                    .onSubmit(submitLink)
                    .disabled(session.isReadingLink)

                quietAction(session.isReadingLink ? "Reading…" : "Write up", run: submitLink)
                    .disabled(
                        session.isReadingLink
                            || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func submitLink() {
        let raw = link
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Cleared straight away: the write-up takes a minute, and a field still
        // holding the last URL reads as though nothing happened.
        link = ""
        Task { await session.writeUpLink(raw) }
    }

    /// PDFs only, several at once — a term's backlog of handouts is a realistic
    /// first use, the same as the recordings picker beside it.
    private func choosePDFs() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "Add"
        panel.message = "PDFs are copied into your vault's inbox and written up."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { await session.addPDFs(urls) }
    }

    private func quietAction(_ title: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .font(Typography.ui)
                .foregroundStyle(Palette.stamp)
        }
        .buttonStyle(.plain)
    }

    /// Audio only, several at once: a term's backlog of voice memos is a
    /// realistic first use, and making that one-at-a-time would be unkind.
    private func chooseRecordings() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .wav, .mp3, .aiff]
        panel.prompt = "Add"
        panel.message = "Recordings are copied into your vault's inbox and written up."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { await session.addRecordings(urls) }
    }

    private static let steps = [
        "Your Mac transcribes the lecture as it happens. No audio leaves the machine.",
        "Every few minutes Claude writes interim notes, so you have something even if the recording ends badly.",
        "When you stop, the whole lecture is re-transcribed and written up properly, then filed under the course it worked out.",
        "Leave the lid open. Recording keeps the Mac awake, but closing the lid sleeps it regardless and the recording stops there.",
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
            remedy(for: why)
        }
    }

    /// A way out of the failure, where one exists.
    ///
    /// The microphone case needs this more than it looks like it does.
    /// `AVCaptureDevice.requestAccess` shows its dialog **once, ever**: after a
    /// first denial it returns false immediately and silently, with no prompt. So
    /// an app that only calls `requestAccess` is, from that moment on, permanently
    /// unable to record and unable to say how to fix it — pressing the button
    /// just fails again. The only route back is System Settings, and the app has
    /// to be the thing that offers it.
    @ViewBuilder private func remedy(for why: String) -> some View {
        if why.contains("Microphone"), let pane = Self.microphonePane {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Button("Open Privacy & Security") { NSWorkspace.shared.open(pane) }
                    .buttonStyle(.plain)
                    .font(Typography.uiBold)
                    .foregroundStyle(Palette.board)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.md)
                    .background(Palette.stamp, in: RoundedRectangle(cornerRadius: Spacing.sm))
                    .accessibilityHint("Opens the Microphone list in System Settings")

                Text("Switch Lecture Notes on in the Microphone list, then press record again. macOS only asks once on its own, so this is the only way back.")
                    .font(Typography.ui)
                    .foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Opens System Settings at the Microphone list rather than the pane's root,
    /// which is several scrolls from the switch that matters.
    private static let microphonePane = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")

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
