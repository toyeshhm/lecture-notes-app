import AVFoundation
import AppKit
import LectureKit
import Observation

/// The four things you can do to a lecture that is already on disk: open it in
/// Obsidian, show it in Finder, play its audio, and write its notes again.
///
/// None of this goes through `VaultWriter`. That derives a destination from
/// `Settings` and deletes the target's previous copy, which is exactly right
/// while a recording is still deciding where it belongs and exactly wrong for a
/// note the library found at a path — the user may have dragged it somewhere
/// else in Obsidian since, and rewriting it "where settings say it goes" would
/// leave the moved file behind and a second one beside it. A file found at a
/// path is rewritten at that path or not at all.
enum LectureActions {}

// MARK: - Open in Obsidian

extension LectureActions {

    /// Which application ended up with the note. The fallback to Finder is
    /// otherwise indistinguishable from a broken button, so the caller is given
    /// the reason to put on screen rather than left to invent one.
    enum OpenOutcome: Equatable {
        case obsidian(vault: String)
        case finder(reason: String)
    }

    /// Open the note in Obsidian, falling back to Finder.
    ///
    /// `obsidian://open` keys on the vault *name* Obsidian registered, not on a
    /// path, and a name it does not know produces no window and no error — the
    /// click simply does nothing. So the vault is resolved from Obsidian's own
    /// registry first, and anything short of a confirmed match reveals the file
    /// instead.
    @MainActor
    static func open(_ entry: LibraryLecture) -> OpenOutcome {
        guard let match = ObsidianRegistry.locate(entry.url) else {
            reveal(entry)
            return .finder(reason: "No Obsidian vault contains this note.")
        }
        guard
            let url = URL(
                string: "obsidian://open?vault=\(escaped(match.vault))&file=\(escaped(match.file))"),
            NSWorkspace.shared.open(url)
        else {
            reveal(entry)
            return .finder(reason: "Obsidian didn’t open the link.")
        }
        return .obsidian(vault: match.vault)
    }

    @MainActor
    static func reveal(_ entry: LibraryLecture) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    /// Percent-encode a query value.
    ///
    /// Deliberately not `.urlQueryAllowed`, which permits `&`, `=`, `+` and `/`
    /// — all four occur in real vault names and lecture paths, and each of them
    /// silently changes what Obsidian parses. Unreserved characters only: over-
    /// encoding is invisible after the receiver decodes, under-encoding is not.
    /// Topics carry em dashes, so this must also be doing UTF-8, which it is.
    private static func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }
}

/// Obsidian's list of vaults it knows about.
///
/// `obsidian.json` maps an opaque per-vault ID to `{"path": …, "ts": …}`; the
/// name Obsidian shows, and the only name the URL scheme accepts, is the last
/// component of that path. There is no API for this and no guarantee the file
/// exists — Obsidian may not be installed — so every failure here is a missing
/// vault, never an error.
private enum ObsidianRegistry {

    private struct File: Decodable {
        struct Vault: Decodable { let path: String }
        let vaults: [String: Vault]
    }

    private static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Application Support/obsidian/obsidian.json")
    }

    /// The registered vault holding `note`, and the note's path within it.
    static func locate(_ note: URL) -> (vault: String, file: String)? {
        guard let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(File.self, from: data)
        else { return nil }

        // Compared component-wise on resolved paths, for the same two reasons
        // VaultWriter resolves before its containment check: a string prefix
        // makes `/vaults/notes-old` look like it is inside `/vaults/notes`, and
        // a vault reached through a symlink (an external volume, `/tmp`) reads
        // as outside itself.
        let noteParts = note.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var best: (depth: Int, vault: String, file: String)?

        for vault in file.vaults.values {
            let root = URL(fileURLWithPath: vault.path)
                .resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard let name = root.last, noteParts.count > root.count,
                Array(noteParts.prefix(root.count)) == root
            else { continue }
            // Deepest match wins: a vault opened on a subfolder of another vault
            // is ordinary, and the shallower one would address the note by a
            // path the deeper vault cannot resolve.
            guard best.map({ root.count > $0.depth }) ?? true else { continue }
            best = (root.count, name, noteParts.dropFirst(root.count).joined(separator: "/"))
        }
        return best.map { ($0.vault, $0.file) }
    }
}

// MARK: - Audio

/// Playback for one lecture's kept audio.
///
/// One instance, held by whatever owns the library, because a second lecture
/// starting is always a request to replace the first rather than to hear both.
/// Not a singleton: a global would outlive the window and keep a `.wav` open on
/// a volume the user is trying to eject.
@MainActor
@Observable
final class LecturePlayer {

    /// The lecture loaded, playing or paused. Nil when nothing is.
    private(set) var lecture: LibraryLecture?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    /// AVAudioPlayer publishes nothing, so position is polled. 100 ms is a
    /// position readout for the gutter scrub in DESIGN.md §5.5, not an
    /// animation; a tick finer than the eye resolves buys nothing and wakes the
    /// main actor ten times as often.
    private static let tick = Duration.milliseconds(100)

    init() {}

    /// Play `entry`, or pause it if it is the one already playing.
    func toggle(_ entry: LibraryLecture) {
        if lecture == entry, let player {
            if player.isPlaying { pause() } else { resume() }
            return
        }
        load(entry)
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.cancel()
        ticker = nil
    }

    func stop() {
        pause()
        player = nil
        lecture = nil
        currentTime = 0
        duration = 0
    }

    /// Scrub, clamped. §5.5 hands the gutter a drag position, and a drag that
    /// runs off the end of the hatching would otherwise set a time past the
    /// file, which AVAudioPlayer treats as "at the end" and stops.
    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(time, 0), player.duration)
        player.currentTime = clamped
        currentTime = clamped
    }

    private func load(_ entry: LibraryLecture) {
        stop()
        // `keepAudio` is off by default, so a lecture with no audio is the
        // ordinary case rather than a failure worth reporting — and so is a
        // `.wav` on a volume that is no longer mounted. Both leave the player
        // holding nothing, and the view shows no control at all rather than a
        // dead one.
        guard let audio = entry.audioURL, let opened = try? AVAudioPlayer(contentsOf: audio) else {
            return
        }
        player = opened
        lecture = entry
        duration = opened.duration
        resume()
    }

    private func resume() {
        guard let player, player.play() else { return }
        isPlaying = true
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tick)
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                // Reaching the end leaves the player stopped with `currentTime`
                // at the duration, where a further `play()` returns true having
                // played nothing. Rewinding here is what makes the button work
                // a second time.
                if !player.isPlaying {
                    player.currentTime = 0
                    self.currentTime = 0
                    self.isPlaying = false
                    return
                }
            }
        }
    }
}

// MARK: - Re-run the notes pass

extension LectureActions {

    enum RerunFailure: Error, Equatable {
        case unreadable
        case noTranscript
    }

    /// Whether the notes can be written again at all.
    ///
    /// `wordsPerMinute` is the scanner's transcript signal: nil exactly when the
    /// note carries no transcript, which is every note in a mirror vault, by
    /// configuration. Reading it off the entry rather than off the disk is what
    /// lets a library row decide whether to offer the action at all — the point
    /// being that an impossible re-run is absent, not present and failing.
    static func canRerun(_ entry: LibraryLecture) -> Bool {
        entry.wordsPerMinute != nil
    }

    /// The note as it would be, rewritten from its own transcript.
    ///
    /// Returns the markdown instead of writing it. The final pass replaces the
    /// whole body, including anything typed into it in Obsidian since, so the
    /// decision to overwrite belongs to whoever can put the result in front of
    /// the user. `apply` does the writing, and nothing else here touches disk.
    ///
    /// This is the recovery path for a session that died mid-lecture: such a
    /// note has its transcript and no final pass, and that is all this needs.
    static func rerun(_ entry: LibraryLecture, settings: LectureSettings) async throws -> String {
        guard let text = try? String(contentsOf: entry.url, encoding: .utf8) else {
            throw RerunFailure.unreadable
        }
        guard let transcript = transcript(in: text) else { throw RerunFailure.noTranscript }

        let markdown = try await ClaudeRunner(claudePath: settings.claudePath).run(
            prompt: NoteWriterPrompts.finalNotes(transcript: transcript, course: entry.course),
            system: Prompts.final,
            model: settings.finalModel,
            // The 600s the live pipeline allows, for the same reason: a two-hour
            // transcript is past the 240s default before the model has finished
            // reading it, and a timeout here throws away the only copy of a
            // pass the user waited minutes for.
            timeout: 600)

        let front = frontmatter(in: text)
        let note = LectureNote(
            date: entry.date,
            course: entry.course,
            topic: entry.topic,
            finalNotes: fixCallouts(markdown),
            transcript: transcript,
            // Zero when the note never carried a duration. The renderer writes
            // `duration_min` unconditionally, so the alternative is inventing a
            // number for a lecture whose length nothing recorded.
            duration: TimeInterval((entry.durationMinutes ?? 0) * 60),
            detectedCourse: front.detectedCourse,
            detectionConfidence: entry.detectionConfidence)
        // Rendered by the same renderer the recording pipeline uses, so a
        // repaired note is byte-identical to one that never crashed. Rebuilding
        // the file whole is also what makes `status: recording` become
        // `status: complete` without anyone editing that line by hand.
        return NoteRenderer().render(note, keepTranscript: true, extraFrontmatter: front.extra)
    }

    /// Overwrite the note with markdown the caller has confirmed.
    ///
    /// Straight to `entry.url`. Mirrors are not written: a mirror is the
    /// fan-out of a live recording, and re-running is a repair on the one file
    /// the user picked. Rewriting mirrors from here would need their relocation
    /// history, which lived in the session that has long since exited.
    static func apply(_ markdown: String, to entry: LibraryLecture) throws {
        try markdown.write(to: entry.url, atomically: true, encoding: .utf8)
    }

    /// The text under `## Transcript`, or nil when the note carries none.
    ///
    /// A whole-line heading match: `NoteRenderer` writes the transcript last and
    /// it runs to the end of the file, so there is no closing delimiter to find
    /// and nothing after it to preserve.
    private static func transcript(in markdown: String) -> String? {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard
            let heading = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == "## Transcript"
            })
        else { return nil }
        let body = lines[lines.index(after: heading)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A heading with nothing under it is the same as no transcript: there is
        // nothing to send, and the pass would come back with invented content.
        return body.isEmpty ? nil : body
    }

    /// Frontmatter that a `LibraryLecture` cannot carry back into the renderer:
    /// keys added by hand in Obsidian, which must survive a rewrite, and
    /// `detected_course`, which the renderer emits but the entry does not hold.
    ///
    /// ponytail: scalar `key: value` lines only. A multi-line YAML value added
    /// by hand (`aliases:` with a list under it) is dropped — write a real
    /// parser if that ever shows up; the renderer's own `tags:` block is the
    /// only multi-line key this app writes, and it is regenerated anyway.
    private static func frontmatter(in markdown: String) -> (
        detectedCourse: String?, extra: [String: String]
    ) {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, [:]) }

        var pairs: [(key: String, value: String)] = []
        var closed = false
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                closed = true
                break
            }
            // Indented lines and `- ` items belong to the key above them, and an
            // empty line has no key at all.
            guard line.first?.isWhitespace == false, let colon = line.firstIndex(of: ":") else {
                continue
            }
            pairs.append(
                (
                    String(line[..<colon]),
                    String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                ))
        }
        // An unterminated block is not frontmatter, it is a truncated file, and
        // scanning on would pull body lines in as keys. Carrying nothing forward
        // costs the user a hand-added field; guessing costs them a corrupt one.
        guard closed else { return (nil, [:]) }

        let generated: Set<String> = [
            "title", "course", "date", "type", "duration_min", "status",
            "detected_course", "detection_confidence", "tags",
        ]
        var detected: String?
        var extra: [String: String] = [:]
        for pair in pairs {
            if pair.key == "detected_course" {
                detected = pair.value.isEmpty ? nil : pair.value
            } else if !generated.contains(pair.key) {
                extra[pair.key] = pair.value
            }
        }
        return (detected, extra)
    }
}
