import Foundation

/// Reads the library back out of the vault.
///
/// There is no index and no cache: the notes on disk *are* the library. Obsidian
/// is the primary interface, so notes are renamed, moved and deleted behind this
/// app's back; a separate index drifts on the first such edit with no reliable
/// way to notice it happened. Scanning also means the notes written by the
/// Python CLI that preceded this app appear without a migration step.

// MARK: - What a scan returns

/// One lecture note as it exists on disk right now.
///
/// Every field except `url` and `course` can be absent, because every one of
/// them comes from a file a person is free to edit. A lecture you cannot see is
/// worse than one with a blank duration.
public struct LibraryLecture: Sendable, Equatable, Identifiable {
    public var id: URL { url }
    public let url: URL
    /// The containing course *folder*, not the `course:` key. See `LibraryScanner`.
    public let course: String
    /// `yyyy-MM-dd`, or empty when neither frontmatter nor filename supplied one.
    public let date: String
    public let topic: String
    public let durationMinutes: Int?
    /// `complete`, `recording`, or whatever else the file says: an unrecognised
    /// value is still information, and mapping it onto an enum would discard it.
    public let status: String?
    public let detectionConfidence: Confidence?
    /// Sibling `.wav`, only when it is actually there.
    public let audioURL: URL?
    /// Mean speech density, which the library row's hatch swatch encodes.
    public let wordsPerMinute: Double?
}

/// A course folder and the lectures filed under it.
public struct LibraryCourse: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let url: URL
    /// Newest first.
    public let lectures: [LibraryLecture]
}

// MARK: - The scan

public enum LibraryScanner {

    /// Every course folder under `coursesSubdir`, alphabetical, each with its
    /// lectures newest first.
    ///
    /// A course with no lectures is still a course: the folder is the user's
    /// declaration that it exists, and hiding it would make a newly created
    /// course look like a failure.
    public static func scan(settings: Settings) -> [LibraryCourse] {
        let lecturesSubdir = PathComponent.relativePath(
            settings.lecturesSubdir, fallback: "Lectures"
        )
        // `courses.md` — the roster — falls out here for free by not being a
        // directory, along with any other stray file the user keeps alongside.
        return children(of: settings.coursesDirectory)
            .filter(isDirectory)
            .map { folder in
                LibraryCourse(
                    name: folder.lastPathComponent,
                    url: folder,
                    lectures: lectures(in: folder.appending(path: lecturesSubdir), course: folder.lastPathComponent)
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Notes directly inside the course's `Lectures` folder and nowhere else.
    ///
    /// The real vault has `CS 314H/Weiss Java/Chapter 2.md`: a hand-written note
    /// that is not a lecture. Anything outside `Lectures/` belongs to the user,
    /// not to this app, and listing it as a lecture would be a lie about where
    /// it came from.
    private static func lectures(in directory: URL, course: String) -> [LibraryLecture] {
        inFilingOrder(
            children(of: directory)
                .filter { $0.pathExtension.lowercased() == "md" }
                .map { read($0, course: course) })
    }

    /// Newest first, filename breaking ties.
    ///
    /// `date` is `yyyy-MM-dd`, so it sorts as a plain string and no DateFormatter
    /// is needed. The tie-break matters because two lectures on one day would
    /// otherwise swap places between scans and the list would jump under the
    /// pointer.
    ///
    /// Split out because it cannot be tested through `scan`: `contentsOfDirectory`
    /// hands back alphabetical entries on APFS, and Swift's sort is stable, so a
    /// scan-level test passes with the tie-break deleted entirely. It has to be
    /// fed input the filesystem would never produce.
    static func inFilingOrder(_ lectures: [LibraryLecture]) -> [LibraryLecture] {
        lectures.sorted {
            $0.date == $1.date
                ? $0.url.lastPathComponent < $1.url.lastPathComponent
                : $0.date > $1.date
        }
    }

    private static func read(_ url: URL, course: String) -> LibraryLecture {
        // A note that is not valid UTF-8 still gets listed, from its filename
        // alone. Rendering it is the reader's problem; hiding it is worse.
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let parsed = Parsed(text)
        let (filenameDate, filenameTopic) = splitFilename(url.deletingPathExtension().lastPathComponent)

        let duration = parsed.front["duration_min"].flatMap(Int.init)
        let audio = url.deletingPathExtension().appendingPathExtension("wav")
        // A frontmatter date of another shape is treated as absent, not trusted:
        // it would sort into the wrong place and drag the whole list with it.
        let date = parsed.front["date"].flatMap { isISODate($0) ? $0 : nil } ?? filenameDate
        let topic = parsed.front["title"].flatMap { $0.isEmpty ? nil : $0 } ?? filenameTopic

        return LibraryLecture(
            url: url,
            // The folder wins over the `course:` key deliberately: dragging a
            // note into another course folder in Obsidian *is* recategorising
            // it, and from that moment the frontmatter is stale.
            course: course,
            date: date,
            topic: topic,
            durationMinutes: duration,
            status: parsed.front["status"],
            detectionConfidence: parsed.front["detection_confidence"].flatMap(Confidence.init(rawValue:)),
            audioURL: FileManager.default.fileExists(atPath: audio.path) ? audio : nil,
            wordsPerMinute: wpm(words: parsed.transcriptWords, minutes: duration)
        )
    }

    /// Nil rather than zero when it cannot be known: a mirror written without a
    /// transcript, or a note whose duration never got recorded, has no density
    /// to draw, and drawing an empty hatch would claim it was a silent lecture.
    private static func wpm(words: Int?, minutes: Int?) -> Double? {
        guard let words, let minutes, minutes > 0 else { return nil }
        return Double(words) / Double(minutes)
    }

    private static func children(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

// MARK: - Reading one file

/// Frontmatter keys and the transcript's word count, from a single pass.
///
/// One pass because the transcript is the bulk of the file — it is the whole
/// lecture — and walking it twice to get a word count doubles the cost of every
/// scan for a number that is a by-product of the walk we already do.
private struct Parsed {
    var front: [String: String] = [:]
    /// Nil when there is no `## Transcript` section at all, which is how a
    /// mirror written with `keepTranscript: false` looks.
    var transcriptWords: Int?

    init(_ text: String) {
        enum Region { case frontmatter, body, fenced, transcript }
        // Split on the whole newline set, not on "\n". A vault is a folder of
        // text files that syncs between machines, so a note may well come back
        // CRLF-terminated — Obsidian on Windows, a Syncthing round-trip, an
        // editor with CRLF defaults. Splitting on "\n" leaves a trailing "\r" on
        // every line, and `CharacterSet.whitespaces` is Zs-plus-tab and does not
        // contain it, so `"---\r" != "---"`: frontmatter never opens, the
        // transcript heading never matches, and every field silently reads as
        // absent. Exactly the "edited behind this app's back" case this file
        // exists to survive.
        var lines = text.split(whereSeparator: \.isNewline)[...]
        var region: Region = .body
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            region = .frontmatter
            lines = lines.dropFirst()
        }

        for line in lines {
            switch region {
            case .frontmatter:
                if line.trimmingCharacters(in: .whitespaces) == "---" {
                    region = .body
                } else if line.first?.isWhitespace == false, let colon = line.firstIndex(of: ":") {
                    // Indented lines are list items under `tags:`; taking them
                    // as keys lets a nested value overwrite a top-level one.
                    front[String(line[..<colon])] = unquote(line[line.index(after: colon)...])
                }
            case .body:
                // A fenced block can contain anything, including a line that
                // reads `## Transcript`. `fixCallouts` in NoteRenderer already
                // tracks fences for the same reason; a heading inside a fence is
                // sample text, not structure.
                if line.hasPrefix("```") {
                    region = .fenced
                } else if line.trimmingCharacters(in: .whitespaces) == "## Transcript" {
                    region = .transcript
                    transcriptWords = 0
                }
            case .fenced:
                if line.hasPrefix("```") { region = .body }
            case .transcript:
                if line.hasPrefix("## ") {
                    region = .body
                } else {
                    transcriptWords = (transcriptWords ?? 0) + line.split(whereSeparator: \.isWhitespace).count
                }
            }
        }
    }

    /// The renderer quotes `title` and nothing else, but stripping a matched
    /// pair everywhere costs one line and survives a user quoting another key.
    private func unquote(_ raw: Substring) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
    }
}

/// Split `YYYY-MM-DD — Topic` back into its two halves.
///
/// The writer's filename format is the last line of defence for a note whose
/// frontmatter was deleted or mangled. Both halves are optional: a file called
/// `Notes.md` yields no date and the topic `Notes`.
private func splitFilename(_ name: String) -> (date: String, topic: String) {
    let prefix = String(name.prefix(10))
    guard isISODate(prefix) else { return ("", name) }
    // Strip one separator, not a character set. Trimming `" —-"` from both ends
    // eats the topic's own leading and trailing hyphens: `2026-07-30 — -1
    // eigenvalues` came back as `1 eigenvalues`, which is a different claim.
    // Em dash as written; hyphen because hand-renamed files use one.
    var rest = name.dropFirst(10).drop(while: \.isWhitespace)
    if let first = rest.first, first == "—" || first == "-" {
        rest = rest.dropFirst().drop(while: \.isWhitespace)
    }
    return (prefix, rest.isEmpty ? name : String(rest))
}

/// Shape only, not validity. Sorting depends on `yyyy-MM-dd` ordering
/// lexicographically, so a value of another shape must not reach it; whether
/// month 19 exists is not this function's problem.
private func isISODate(_ s: String) -> Bool {
    let parts = s.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return false }
    let widths = [4, 2, 2]
    return zip(parts, widths).allSatisfy { part, width in
        part.count == width && part.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
