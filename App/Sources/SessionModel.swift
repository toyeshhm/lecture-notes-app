import AVFoundation
import LectureKit
import OSLog
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
    private var note = LectureNote(date: LectureNote.day(), course: unsortedFolder)
    private var tasks: [Task<Void, Never>] = []
    private var workDirectory: URL?
    /// The models, loading or loaded. See `warmUp()`.
    private var warm: Task<Transcriber, Error>?

    /// Held for the length of a recording so the Mac does not idle-sleep.
    ///
    /// A lecture is an hour of no keyboard and no trackpad, which is exactly
    /// what macOS reads as idle: it sleeps, `AVAudioEngine` stops, and the rest
    /// of the lecture is gone. Nothing about the app's own activity counts as
    /// user activity, so this has to be asserted explicitly.
    ///
    /// It does **not** survive the lid closing. Nothing an app can assert does;
    /// clamshell sleep is unconditional without external power and a display.
    /// The remedy there is to leave the lid open, and the app says so.
    private var awake: NSObjectProtocol?
    private var lastLivePass = Date.distantPast
    private var hasDetected = false
    /// Transcript words already sent to a live pass, so the next one can tell how
    /// much is genuinely new.
    private var wordsSummarised = 0

    private let writer = VaultWriter()

    /// Built per call from the *current* settings, not stored.
    ///
    /// It was stored, and that made the one setting whose entire purpose is to
    /// unblock a failure the one setting that could not: recording fails with
    /// "Couldn't find the claude binary. Set its path in Settings", the user sets
    /// it, the path is saved and displayed, and the next recording fails
    /// identically because the runner still holds the `nil` it was constructed
    /// with. Only a relaunch fixed it. `ClaudeRunner` holds a path and nothing
    /// else, so there is nothing to reuse and no reason to cache one.
    private var claude: ClaudeRunner {
        ClaudeRunner(claudePath: settings.claudePath ?? ClaudeRunner.locate())
    }

    init(settings: LectureSettings? = nil) {
        self.settings = settings ?? SettingsStore.load()
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

    /// Load the transcription models without recording anything.
    ///
    /// Called at launch. The cost it moves is lopsided and both halves matter:
    ///
    /// - The **first ever** load on a machine takes ~110 seconds, measured on an
    ///   M5 with the models already downloaded. That is CoreML compiling the
    ///   encoder for the Neural Engine, and having the `.mlmodelc` on disk does
    ///   not avoid it.
    /// - **Every load after that takes about a second**, because macOS caches the
    ///   compiled artifact. Measured too — the two figures are three orders of
    ///   magnitude apart and it is easy to generalise from whichever one you hit
    ///   first.
    ///
    /// So this is not a general-purpose speed-up; it is insurance against the one
    /// run that is slow. Paid inside `start()` that run looks exactly like a
    /// hang — press record, watch "Preparing" for two minutes, conclude the app
    /// is broken, which is what happened. It also recurs after an OS update or a
    /// FluidAudio version bump invalidates the compile cache, which is precisely
    /// when nobody will remember this is a known cost.
    func warmUp() {
        guard warm == nil else { return }
        warm = Task {
            Self.log.info("warm-up: loading models")
            let started = Date()
            do {
                let transcriber = Transcriber()
                try await transcriber.loadModels()
                Self.log.info("warm-up: ready in \(Int(Date().timeIntervalSince(started)))s")
                return transcriber
            } catch {
                // Logged, not swallowed. A warm-up runs with nobody awaiting it,
                // so a failure here is invisible until the record button is
                // pressed minutes later — and then it surfaces as a generic
                // failure with no hint that it happened at launch.
                Self.log.error("warm-up failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
    }

    private static let log = Logger(subsystem: "LectureNotes", category: "session")

    // MARK: Inbox

    /// Recordings made elsewhere and waiting to be written up.
    private(set) var inboxPending = 0
    /// The file currently being written up, if any.
    private(set) var inboxWorking: String?

    /// Write up anything dropped into the vault's inbox.
    ///
    /// Called at launch and whenever the Mac wakes, so a lecture recorded on a
    /// phone on the way home is written up the next time the laptop is opened
    /// rather than waiting to be noticed.
    /// - Parameter automatic: whether the app started this pass on its own.
    ///   "From your phone" turns those off. It does not turn off a file the user
    ///   has just picked or dropped: that copies into the inbox and would then
    ///   sit there forever, with no error and no later pass that would find it.
    func processInbox(settledFor: TimeInterval = 20, automatic: Bool = true) async {
        guard !automatic || settings.watchesInbox, phase == .idle else { return }
        // One pass at a time, and this is not belt-and-braces. Launch fires both
        // the initial `.task` and the become-active handler, and measured on a
        // real inbox they raced: two passes both listed the same file before
        // either archived it, so one lecture was transcribed twice and written
        // up twice, at twice the subscription cost. Joining the run in flight
        // rather than starting a second is the fix; the caller still awaits a
        // finished pass either way.
        if let inFlight = inboxRun {
            await inFlight.value
            // An automatic pass has nothing of its own waiting and is finished
            // here. A manual one is not: it copied its file in *after* the pass
            // it just joined had listed the folder, so that file is in neither
            // pass and the next one is a wake or a return to the app away — off
            // altogether if "From your phone" is off. It gets its own pass.
            guard !automatic else { return }
        }
        let run = Task { await runInbox(settledFor: settledFor) }
        inboxRun = run
        await run.value
        // Only if it is still ours. A manual caller that joined this run starts
        // the next one the instant this task completes, and the two resumptions
        // are not ordered — clearing unconditionally can null out *their* run
        // and let a third caller start a pass alongside it, which is the
        // double-write this whole property exists to prevent.
        if inboxRun == run { inboxRun = nil }
    }

    private var inboxRun: Task<Void, Never>?

    private func runInbox(settledFor: TimeInterval) async {
        let inbox = settings.inboxDirectory
        try? InboxWatcher.prepare(inbox)

        let waiting = await Task.detached {
            InboxWatcher.pending(in: inbox, settledFor: settledFor)
        }.value
        inboxPending = waiting.count
        guard !waiting.isEmpty else { return }
        Self.log.info("inbox: \(waiting.count) recording(s) waiting")

        for item in waiting {
            // A recording that arrives while one is being written up waits for
            // the next pass, and a lecture starting takes priority over both:
            // the live pipeline needs the transcriber and the subscription.
            guard phase == .idle else { break }
            await writeUp(item)
            inboxPending = max(0, inboxPending - 1)
        }
        inboxWorking = nil
    }

    /// Copy recordings into the inbox and write them up now.
    ///
    /// `settledFor: 0` because a file chosen in an open panel is finished by
    /// definition. The twenty-second wait exists for files a sync client is
    /// still extending, and applying it here would make a deliberate action sit
    /// there apparently doing nothing.
    func addRecordings(_ urls: [URL]) async {
        try? InboxWatcher.prepare(settings.inboxDirectory)
        urls.forEach(copyIntoInbox)
        await processInbox(settledFor: 0, automatic: false)
    }

    /// What the picker and the window's drop target will take.
    ///
    /// `isFileURL` is the load-bearing half. `dropDestination(for: URL.self)`
    /// also receives a link dragged out of a browser, and
    /// `https://arxiv.org/pdf/2301.00001.pdf` passes an extension test happily;
    /// `FileManager.copyItem` then reads that remote URL's *path* as a local
    /// one, so this is not only about which error the user sees.
    static func isPDF(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "pdf"
    }

    /// Copy PDFs into the inbox and read them now. `settledFor: 0` for the same
    /// reason as `addRecordings`.
    ///
    /// Filtered rather than trusted: this is also what the window's drop target
    /// calls, and a drop carries whatever was dragged.
    func addPDFs(_ urls: [URL]) async {
        try? InboxWatcher.prepare(settings.inboxDirectory)
        urls.filter(Self.isPDF).forEach(copyIntoInbox)
        await processInbox(settledFor: 0, automatic: false)
    }

    /// Puts one file in the inbox under a name nothing else there is using.
    ///
    /// Copied, never moved: the file belongs to the user and may be the only
    /// copy of it.
    private func copyIntoInbox(_ url: URL) {
        let inbox = settings.inboxDirectory
        var destination = inbox.appending(path: url.lastPathComponent)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            let stem = url.deletingPathExtension().lastPathComponent
            destination = inbox.appending(path: "\(stem) \(suffix).\(url.pathExtension)")
            suffix += 1
        }
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            Self.log.error("inbox: could not copy \(url.lastPathComponent, privacy: .public)")
            statusLine = "Couldn't add \(url.lastPathComponent)."
        }
    }

    /// Whether a link is being fetched right now, so the field can disable itself.
    private(set) var isReadingLink = false

    /// Read a web page and write it up.
    ///
    /// Nothing is copied into the inbox: there is no file, and the URL recorded
    /// in the note's frontmatter is the way back to the source.
    func writeUpLink(_ raw: String) async {
        guard !isReadingLink, phase == .idle else { return }
        isReadingLink = true
        defer { isReadingLink = false }

        statusLine = "Reading the page…"
        let extracted: Extracted
        do {
            extracted = try await WebReader.read(raw)
        } catch let failure as SourceFailure {
            statusLine = failure.message
            return
        } catch {
            statusLine = "Couldn't read that link."
            return
        }
        await writeUp(extracted, dated: LectureNote.day(), duration: 0)
    }

    private func writeUp(_ item: InboxWatcher.Pending) async {
        inboxWorking = item.url.lastPathComponent
        statusLine = "Writing up \(item.url.lastPathComponent)…"

        let extracted: Extracted
        let day: String
        /// Where a PDF was moved to before its note was attempted, so a note
        /// that never reaches the vault can put it back.
        var archived: URL?
        switch item.kind {
        case .audio:
            Self.log.info("inbox: transcribing \(item.url.lastPathComponent, privacy: .public)")
            guard let transcript = try? await Transcriber.transcribeFile(item.url),
                  !transcript.split(whereSeparator: \.isWhitespace).isEmpty
            else {
                // Left in place rather than archived: an empty transcript is more
                // often a file that has not finished syncing than a silent lecture,
                // and the next pass should try again.
                Self.log.error("inbox: no speech in \(item.url.lastPathComponent, privacy: .public)")
                statusLine = "Couldn't read \(item.url.lastPathComponent)."
                inboxWorking = nil
                return
            }
            extracted = Extracted(text: transcript, title: nil, source: .lecture)
            // The file's own date, not today's. A lecture shared on Friday for a
            // Wednesday recording belongs to Wednesday, and the date is what the
            // note is filed and sorted by.
            day = LectureNote.day(of: item.modified)

        case .pdf:
            Self.log.info("inbox: reading \(item.url.lastPathComponent, privacy: .public)")
            do {
                // Detached: `PDFReader.read` is synchronous and a scanned lecture
                // takes it a minute of OCR. Called inline it would block the main
                // actor for that minute — the clock stops, the window stops
                // drawing, and the app is indistinguishable from hung.
                var read = try await Task.detached { try PDFReader.read(item.url) }.value
                // Archived here, before the note is written, where a recording is
                // archived after. The note's `source:` is the only route back to
                // the PDF, so it has to name where the file really is — and the
                // only way to know that is to have moved it. Working the
                // destination out in advance writes a path that a failed move
                // never creates, and nothing afterwards reconciles the two.
                //
                // Moving this early costs nothing that the recording ordering
                // protects. The text is already in hand, so a notes pass that
                // fails costs a drag back out of `Written up/` rather than a lost
                // recording — and the PDF is not re-read, re-OCR'd and re-written
                // up on every inbox pass from now until someone notices.
                if case .pdf(_, let pages, let ocr) = read.source {
                    let home = try? InboxWatcher.archive(item.url, in: settings.inboxDirectory)
                    archived = home
                    read.source = .pdf(file: home ?? item.url, pages: pages, ocr: ocr)
                }
                extracted = read
                // Today, not the file's date. `copyItem` preserves a PDF's
                // modification time, so a chapter downloaded three years ago
                // would file itself under that year and never show up in recent
                // work. A reading's date is when it was read, which is also what
                // the link field records — so the two ways in agree.
                day = LectureNote.day()
            } catch let failure as SourceFailure {
                Self.log.error("inbox: \(item.url.lastPathComponent, privacy: .public) unreadable")
                statusLine = failure.message
                inboxWorking = nil
                return
            } catch {
                statusLine = "Couldn't read \(item.url.lastPathComponent)."
                inboxWorking = nil
                return
            }
        }

        let filed = await writeUp(extracted, dated: day, duration: duration(of: item))
        if !filed, let home = archived {
            // The note never reached the vault — a full disk, a permissions
            // change, a vault on a volume that is no longer mounted. Archiving
            // ran before the write so the note's `source:` could name where the
            // PDF really landed, but with no note there is nothing pointing at
            // it: left in `Written up/` it is a file the user never moved,
            // written up nowhere, that no later pass will look at again. Put it
            // back and the next pass finds it.
            try? FileManager.default.moveItem(at: home, to: item.url)
        }
        if filed, item.kind == .audio {
            // A recording is archived only after its note is safely on disk, and
            // is the one thing here that cannot be regenerated: moving it first
            // would lose it if the write failed, where the next pass would
            // otherwise find it still waiting.
            _ = try? InboxWatcher.archive(item.url, in: settings.inboxDirectory)
        }
        inboxWorking = nil
    }

    /// A recording's length, read from the file. Without this the note says
    /// `duration_min: 0`, which is a claim about the lecture rather than an
    /// absence of one, and the library sorts and labels on it.
    ///
    /// Zero for anything that is not audio: a reading never renders the key at
    /// all, so the value is unused there.
    private func duration(of item: InboxWatcher.Pending) -> TimeInterval {
        guard item.kind == .audio else { return 0 }
        return (try? AVAudioFile(forReading: item.url))
            .map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
    }

    /// Detect the course, write the notes, file the note. Shared by audio, PDFs
    /// and web pages — from here on nothing knows which it is handling except
    /// through `extracted.source`.
    ///
    /// Returns whether the note reached disk, which is what tells the caller
    /// whether it may archive the source.
    @discardableResult
    private func writeUp(
        _ extracted: Extracted, dated day: String, duration: TimeInterval
    ) async -> Bool {
        let isReading = extracted.source.isReading

        var note = LectureNote(date: day, course: unsortedFolder, source: extracted.source)
        note.transcript = isReading ? "" : extracted.text
        note.duration = duration
        // A reading's own title, until the detector proposes something better.
        if let title = extracted.title, !title.isEmpty {
            note.topic = PathComponent.sanitised(title, fallback: "Lecture")
        }

        let candidates = CourseDetector.candidates(in: settings.coursesDir)
        if let guess = await CourseDetector(claude: claude).detect(
            text: extracted.text,
            candidates: candidates,
            model: settings.detectModel,
            material: isReading ? .reading : .lecture) {
            note.course = settings.pinnedCourse
                ?? CourseDetector.resolveFolder(guess, candidates: candidates)
            note.topic = guess.topic
            if settings.pinnedCourse == nil {
                note.detectedCourse = guess.course
                note.detectionConfidence = guess.confidence
            }
        }

        let markdown: String?
        if isReading {
            markdown = try? await claude.run(
                prompt: NoteWriterPrompts.readingNotes(
                    text: extracted.text, course: note.course, source: sourceRef(extracted.source)),
                system: Prompts.reading, model: settings.finalModel, timeout: 600)
        } else {
            markdown = try? await claude.run(
                prompt: NoteWriterPrompts.finalNotes(
                    transcript: extracted.text, course: note.course),
                system: Prompts.final, model: settings.finalModel, timeout: 600)
        }
        if let markdown {
            note.finalNotes = fixCallouts(markdown)
        } else if isReading {
            // Nothing is filed. A lecture whose notes pass fails still has a
            // transcript and a set of live sections worth keeping, so its note
            // goes to disk half-written; a reading has neither, and filing one
            // would put a note reading `status: recording` over an empty "Live
            // notes" in the vault — the app claiming to be listening to a PDF,
            // with no second pass that will ever come back to finish it.
            Self.log.error("could not write up \(note.topic, privacy: .public)")
            statusLine = "Couldn't write notes for \(note.topic)."
            return false
        }

        let written = writer.saveAll(&note, settings: settings)
        guard !written.isEmpty else {
            Self.log.error("could not file \(note.topic, privacy: .public)")
            statusLine = "Couldn't write the note into your vault."
            return false
        }
        Self.log.info("filed under \(note.course, privacy: .public)")
        statusLine = "Wrote up \(note.topic)"
        return true
    }

    /// What goes in the note's `Source:` prompt line and its frontmatter.
    private func sourceRef(_ source: NoteSource) -> String {
        switch source {
        case .lecture: ""
        case .pdf(let file, _, _): file.lastPathComponent
        case .web(let page, _): page.absoluteString
        }
    }

    func start() {
        guard !phase.isBusy, phase != .recording else { return }
        phase = .preparing
        reset()

        Task {
            do {
                // The microphone first, before anything slow. macOS shows its
                // permission dialog the moment this is called, so asking here
                // means the user sees it immediately rather than after a
                // two-minute model load they have no reason to wait through —
                // and a session that cannot record does not pay for the load.
                statusLine = "Waiting for microphone access…"
                guard await AudioCapture.requestAccess() else {
                    throw LectureKitError.microphoneDenied
                }

                let work = URL.temporaryDirectory
                    .appending(path: "lecture-notes-\(UUID().uuidString)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                workDirectory = work

                warmUp()
                // Usually already finished, because launch started it. When it
                // has not, the status says what is being waited on rather than
                // leaving "Preparing" to mean anything.
                statusLine = "Loading the transcriber…"
                guard let transcriber = try await warm?.value else {
                    throw LectureKitError.modelsUnavailable("the transcriber never loaded")
                }
                // Consumed: a Transcriber runs one session, so the next recording
                // needs its own. Warming the replacement now means the *second*
                // lecture of a day does not pay the load either.
                warm = nil
                try await transcriber.start()
                self.transcriber = transcriber

                statusLine = "Opening the microphone…"
                let cap = AudioCapture()
                // Feed is nonisolated and synchronous so it is safe to call
                // straight from the capture tap without hopping actors.
                try await cap.start(writingTo: work.appending(path: "capture.wav")) { buffer in
                    transcriber.feed(buffer)
                }
                capture = cap

                phase = .recording
                statusLine = "Recording"
                awake = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled, .userInitiated],
                    reason: "Recording a lecture")
                notePath = try? writer.save(&note, settings: settings)
                observe(capture: cap, transcriber: transcriber)
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

            // Released before the long finishing pass rather than after: once
            // the microphone is closed there is nothing left that sleeping would
            // interrupt, and holding it through a two-minute model call keeps a
            // laptop awake in someone's bag.
            if let awake {
                ProcessInfo.processInfo.endActivity(awake)
                self.awake = nil
            }
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
            warmUp()
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
            .detect(text: note.transcript, candidates: candidates, model: settings.detectModel,
                    material: .lecture)
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

        // `minWordsPerPass` was declared, parsed from the config, and read by
        // nothing — so the setting sat in the UI describing a mechanism that did
        // not exist. It matters in the quiet stretches: a lecturer working
        // through a proof at the board can leave three minutes holding twenty
        // words, and summarising that spends a model call to produce a section
        // saying nothing, which then has to be read around for the rest of the
        // lecture. Below the floor the pass is deferred, not skipped: the timer
        // does not restart, so it fires as soon as enough has been said.
        let newWords = note.transcript.split(whereSeparator: \.isWhitespace).count - wordsSummarised
        guard newWords >= settings.minWordsPerPass else { return }
        lastLivePass = Date()
        wordsSummarised += newWords

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
        note = LectureNote(date: LectureNote.day(), course: settings.pinnedCourse ?? unsortedFolder)
        transcript = ""
        liveNotes = ""
        elapsed = 0
        level = 0
        course = note.course
        topic = note.topic
        notePath = nil
        hasDetected = false
        wordsSummarised = 0
        lastLivePass = Date()
    }

    private func fail(_ error: any Error) {
        if let awake {
            ProcessInfo.processInfo.endActivity(awake)
            self.awake = nil
        }
        let message = (error as? LectureKitError).map(Self.describe) ?? error.localizedDescription
        phase = .failed(message)
        statusLine = message
    }

    static func describe(_ error: LectureKitError) -> String {
        switch error {
        case .microphoneDenied:
            // "System LectureSettings" until now — a global Settings →
            // LectureSettings rename to dodge a SwiftUI collision walked into a
            // user-facing string. The button beside this message is the actual
            // route, so the sentence only has to say what is wrong.
            return "Microphone access is off for Lecture Notes."
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
