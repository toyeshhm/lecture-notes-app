import AVFoundation
import LectureKit
import Observation
import SwiftUI

/// SwiftUI declares its own `LectureSettings` scene type, so the engine's settings need
/// qualifying wherever both modules are in scope.
typealias LectureSettings = LectureKit.Settings

/// Orchestrates one recording: capture, transcription, live notes, filing.
///
/// The views bind to this and nothing else. It owns the engine actors and is the
/// single place the pipeline's ordering lives, so a view can never accidentally
/// start a pass twice or write a note out of order.
@MainActor
@Observable
final class SessionModel {

    enum Phase: Equatable {
        case idle
        case preparing          // loading models, opening the mic
        case recording
        case finishing          // batch transcript + final notes pass
        case failed(String)

        var isBusy: Bool {
            self == .preparing || self == .finishing
        }
    }

    // MARK: Observable state

    private(set) var phase: Phase = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Float = 0
    private(set) var transcript = ""
    private(set) var liveNotes = ""
    private(set) var course = unsortedFolder
    private(set) var topic = "Lecture"
    private(set) var notePath: URL?
    private(set) var statusLine = "Ready"

    var settings: LectureSettings

    // MARK: Engine

    private var capture: AudioCapture?
    private var transcriber: Transcriber?
    private var note = LectureNote(date: LectureNote.today(), course: unsortedFolder)
    private var tasks: [Task<Void, Never>] = []
    private var workDirectory: URL?
    private var lastLivePass = Date.distantPast
    private var hasDetected = false

    private let claude: ClaudeRunner
    private let writer = VaultWriter()

    init(settings: LectureSettings? = nil) {
        let resolved = settings ?? SettingsStore.load()
        self.settings = resolved
        claude = ClaudeRunner(claudePath: resolved.claudePath ?? ClaudeRunner.locate())
    }

    // MARK: Menu bar

    var menuBarTitle: String {
        switch phase {
        case .recording: return Self.clock(elapsed)
        case .preparing: return "…"
        case .finishing: return "Writing"
        default: return ""
        }
    }

    var menuBarSymbol: String {
        switch phase {
        case .recording: return "record.circle.fill"
        case .preparing, .finishing: return "hourglass"
        case .failed: return "exclamationmark.triangle"
        case .idle: return "leaf"
        }
    }

    /// The one-word state, as it is set beside the recording mark. This is the
    /// *visible* name of the state everywhere it appears, so it is also what the
    /// accessible name has to be: a label that says "Saved" over a mark reading
    /// "Ready" breaks Voice Control, which matches on what is on screen.
    var stateWord: String {
        switch phase {
        case .idle: return "Ready"
        case .preparing: return "Preparing"
        case .recording: return "Recording"
        case .finishing: return "Writing"
        case .failed: return "Stopped"
        }
    }

    /// The elapsed time spelled out. `clock` is tabular figures for the eye;
    /// "1:04" read literally is "one colon zero four", so anywhere the clock is
    /// exposed to VoiceOver it is exposed through this instead.
    var spokenElapsed: String {
        Duration.seconds(Int(elapsed))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Lifecycle

    func toggle() {
        switch phase {
        case .idle, .failed: start()
        case .recording: stop()
        case .preparing, .finishing: break   // ignore taps mid-transition
        }
    }

    func start() {
        guard !phase.isBusy, phase != .recording else { return }
        phase = .preparing
        statusLine = "Loading the transcriber…"
        reset()

        Task {
            do {
                let work = URL.temporaryDirectory
                    .appending(path: "lecture-notes-\(UUID().uuidString)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                workDirectory = work

                let tx = Transcriber()
                try await tx.loadModels()
                try await tx.start()
                transcriber = tx

                let cap = AudioCapture()
                // Feed is nonisolated and synchronous so it is safe to call
                // straight from the capture tap without hopping actors.
                try await cap.start(writingTo: work.appending(path: "capture.wav")) { buffer in
                    tx.feed(buffer)
                }
                capture = cap

                phase = .recording
                statusLine = "Recording"
                notePath = try? writer.save(&note, settings: settings)
                observe(capture: cap, transcriber: tx)
            } catch {
                fail(error)
            }
        }
    }

    func stop() {
        guard phase == .recording else { return }
        phase = .finishing
        statusLine = "Finishing up…"

        Task {
            tasks.forEach { $0.cancel() }
            tasks.removeAll()

            let wav = await capture?.stop()
            _ = try? await transcriber?.finish()
            capture = nil
            transcriber = nil

            // The streaming text drives the live view only. The kept transcript
            // comes from a batch pass over the finished file: it is complete and
            // measurably more accurate than the incremental text.
            if let wav, let complete = try? await Transcriber.transcribeFile(wav) {
                note.transcript = complete
                transcript = complete
            }
            note.duration = elapsed

            await detectCourse(force: true)
            await writeFinalNotes()

            if settings.keepAudio, let wav, let dest = notePath {
                try? FileManager.default.moveItem(
                    at: wav, to: dest.deletingPathExtension().appendingPathExtension("wav"))
            }
            if let work = workDirectory { try? FileManager.default.removeItem(at: work) }
            workDirectory = nil

            phase = .idle
            statusLine = "Saved"
        }
    }

    // MARK: Pipeline

    private func observe(capture: AudioCapture, transcriber: Transcriber) {
        tasks.append(Task { [weak self] in
            for await value in capture.levelStream {
                guard let self, !Task.isCancelled else { return }
                self.level = value
                self.elapsed = await capture.capturedDuration
            }
        })

        tasks.append(Task { [weak self] in
            // Only confirmed text: volatile updates get revised, and revised text
            // baked into a note is the bug the Python had to patch by hand.
            for await text in transcriber.confirmedText {
                guard let self, !Task.isCancelled else { return }
                self.transcript = text
                self.note.transcript = text
                await self.detectCourse(force: false)
                await self.livePassIfDue()
            }
        })
    }

    /// Runs once, as soon as there is enough speech to judge the subject.
    private func detectCourse(force: Bool) async {
        guard !hasDetected || force else { return }
        let words = note.transcript.split(whereSeparator: \.isWhitespace).count
        guard force || words >= 120 else { return }
        hasDetected = true

        let candidates = CourseDetector.candidates(in: settings.coursesDir)
        let guess = await CourseDetector(claude: claude)
            .detect(transcript: note.transcript, candidates: candidates, model: settings.detectModel)
        guard let guess else { return }

        // A pinned course still uses detection for the topic: skipping it left
        // every pinned note called "Lecture", so two in one day collided.
        note.course = settings.pinnedCourse ?? CourseDetector.resolveFolder(guess, candidates: candidates)
        note.topic = guess.topic
        if settings.pinnedCourse == nil {
            note.detectedCourse = guess.course
            note.detectionConfidence = guess.confidence
        }
        course = note.course
        topic = note.topic
        notePath = writer.saveAll(&note, settings: settings).first
    }

    private func livePassIfDue() async {
        guard phase == .recording,
              Date().timeIntervalSince(lastLivePass) >= settings.liveInterval else { return }
        lastLivePass = Date()

        let seen = liveNotes
        let prompt = NoteWriterPrompts.summariseChunk(newText: note.transcript, notesSoFar: seen)
        guard let markdown = try? await claude.run(
            prompt: prompt, system: Prompts.live, model: settings.liveModel) else { return }

        note.addSection(fixCallouts(markdown))
        liveNotes = note.liveNotes
        notePath = writer.saveAll(&note, settings: settings).first
    }

    private func writeFinalNotes() async {
        guard !note.transcript.split(whereSeparator: \.isWhitespace).isEmpty else { return }
        statusLine = "Writing notes with \(settings.finalModel)…"
        let prompt = NoteWriterPrompts.finalNotes(transcript: note.transcript, course: note.course)
        if let markdown = try? await claude.run(
            prompt: prompt, system: Prompts.final, model: settings.finalModel, timeout: 600) {
            note.finalNotes = fixCallouts(markdown)
        }
        notePath = writer.saveAll(&note, settings: settings).first
    }

    // MARK: Helpers

    private func reset() {
        note = LectureNote(date: LectureNote.today(), course: settings.pinnedCourse ?? unsortedFolder)
        transcript = ""
        liveNotes = ""
        elapsed = 0
        level = 0
        course = note.course
        topic = note.topic
        notePath = nil
        hasDetected = false
        lastLivePass = Date()
    }

    private func fail(_ error: any Error) {
        let message = (error as? LectureKitError).map(Self.describe) ?? error.localizedDescription
        phase = .failed(message)
        statusLine = message
    }

    static func describe(_ error: LectureKitError) -> String {
        switch error {
        case .microphoneDenied:
            return "Microphone access denied. Grant it in System LectureSettings › Privacy & Security."
        case .claudeNotFound:
            return "Couldn't find the claude binary. Set its path in Settings."
        case .claudeNotLoggedIn:
            return "The claude CLI isn't logged in. Run claude, then /login."
        case .claudeFailed(let why):
            return "Claude failed: \(why)"
        case .modelsUnavailable(let why):
            return "Transcription models unavailable: \(why)"
        case .captureFailed(let why):
            return "Recording failed: \(why)"
        }
    }
}

extension LectureKit.Settings {
    /// The engine spells this `coursesDirectory`; the views read it constantly.
    var coursesDir: URL { coursesDirectory }
}

#if DEBUG
extension SessionModel {
    /// Drives the model into a given state for snapshot rendering.
    ///
    /// The snapshot tool renders every state, including the failure and empty
    /// ones that are otherwise only seen when something has already gone wrong.
    /// Reaching them by running the real pipeline is not practical, so this is
    /// the seam. DEBUG-only: it must never be reachable from the shipped app.
    func previewState(
        phase: Phase,
        elapsed: TimeInterval = 0,
        level: Float = 0,
        course: String = unsortedFolder,
        topic: String = "Lecture",
        liveNotes: String = "",
        transcript: String = "",
        notePath: URL? = nil,
        statusLine: String? = nil
    ) {
        self.phase = phase
        self.elapsed = elapsed
        self.level = level
        self.course = course
        self.topic = topic
        self.liveNotes = liveNotes
        self.transcript = transcript
        self.notePath = notePath
        self.statusLine = statusLine ?? {
            switch phase {
            case .idle: return "Ready"
            case .preparing: return "Loading the transcriber…"
            case .recording: return "Recording"
            case .finishing: return "Writing notes…"
            case .failed(let why): return why
            }
        }()
    }
}
#endif
