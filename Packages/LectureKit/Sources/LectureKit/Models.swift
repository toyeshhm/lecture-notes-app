import Foundation

/// Shared value types. Every module depends on these and nothing else, so they
/// can be built and tested independently.

// MARK: - Path safety

/// Sanitising for strings that become filesystem path components.
///
/// `course` and `topic` originate from a language model, and both end up in a
/// path. `URL.appending(path:)` preserves `/` as a separator and does not
/// resolve `..`, so an unsanitised value writes wherever it likes — outside the
/// vault entirely. Everything that builds a path goes through here.
public enum PathComponent {
    /// Characters that are illegal, or dangerous, in a path component.
    private static let illegal = CharacterSet(charactersIn: #"<>:"/\|?*"#)
        .union(.controlCharacters)

    /// Make `raw` safe to use as a single folder or file name.
    ///
    /// Returns `fallback` when nothing usable survives, because an empty
    /// component silently collapses the path: `appending(path: "")` is a no-op,
    /// so an empty course would drop every note into one shared directory where
    /// same-date lectures overwrite each other.
    public static func sanitised(_ raw: String, fallback: String) -> String {
        let stripped = raw.unicodeScalars
            .filter { !illegal.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }

        // Collapse runs of dots to one. Removing separators from "a/../../b"
        // leaves "a....b", which cannot traverse but is still nonsense; a single
        // dot is kept so legitimate names like "Lecture 3.2" survive.
        var dedotted = ""
        var lastWasDot = false
        for ch in stripped {
            if ch == "." {
                if !lastWasDot { dedotted.append(ch) }
                lastWasDot = true
            } else {
                dedotted.append(ch)
                lastWasDot = false
            }
        }

        // Trim dots and whitespace *together*, in one pass. Trimming them in
        // sequence leaves ". . ." as ".": the dot trim strips the outer dots,
        // the whitespace trim then exposes the middle one, and a component of
        // "." silently drops a directory level — every such lecture collides in
        // one folder, and relocation pruning walks a level higher than the
        // layout it is meant to clean up.
        //
        // Truncating before the trim, so a name cut at the limit cannot end in
        // a dot or a space, which some volumes refuse outright.
        let collapsed = dedotted
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .prefix(120)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespaces))

        if collapsed.isEmpty { return fallback }
        return collapsed
    }

    /// Sanitise a *relative path* of one or more components.
    ///
    /// Subdirectories come from user configuration, not from a model, and are
    /// legitimately nested: "02 Areas/Courses" must stay two levels deep.
    /// Running them through `sanitised` collapsed the separator and produced the
    /// single folder "02 AreasCourses". Each component is sanitised on its own
    /// and rejoined, so nesting survives while traversal still cannot: a ".."
    /// component reduces to nothing and is dropped.
    public static func relativePath(_ raw: String, fallback: String) -> String {
        let parts = raw
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { sanitised(String($0), fallback: "") }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? fallback : parts.joined(separator: "/")
    }

    /// Normalise a vault URL so the same directory always yields the same value.
    ///
    /// `/a/b`, `/a/b/` and `/a/./b` denote one directory but produce different
    /// strings. Relocation tracking is keyed off this, so an unnormalised path
    /// makes previously-tracked copies unrecognisable and orphans them.
    public static func normalised(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path, isDirectory: true).standardizedFileURL
    }
}

// MARK: - Settings

/// Identifies one write destination, stably across course and topic changes.
///
/// Relocation tracking cannot key on the note's current path (that changes when
/// the course is detected) nor on the vault alone (two targets can share a vault
/// but differ in subdirectory). It keys on the target's *configuration*.
public struct VaultTargetID: Hashable, Sendable, Codable {
    public let rawValue: String

    /// Hashes the *sanitised* components. Keying on the raw strings meant two
    /// configs differing only in characters the sanitiser strips ("Courses" vs
    /// "Courses/" vs "Courses?") were one file on disk but two identities, so
    /// relocation tracked one file twice and a mirror could overwrite the
    /// primary while believing it was a separate target.
    init(vault: URL, coursesSubdir: String, lecturesSubdir: String) {
        rawValue = [
            PathComponent.normalised(vault).path,
            PathComponent.relativePath(coursesSubdir, fallback: "Courses"),
            PathComponent.relativePath(lecturesSubdir, fallback: "Lectures"),
        ].joined(separator: "\u{1F}")
    }
}

/// A second vault that receives a copy of every note.
///
/// Deliberate duplication: each copy is written from the same source in one
/// pass, never synced from another copy.
public struct MirrorTarget: Sendable, Codable, Equatable {
    public var vault: URL
    public var coursesSubdir: String
    public var lecturesSubdir: String
    public var keepTranscript: Bool
    /// Extra frontmatter merged into this copy, e.g. marking it agent-generated.
    public var frontmatter: [String: String]

    public init(
        vault: URL,
        coursesSubdir: String = "Courses",
        lecturesSubdir: String = "Lectures",
        keepTranscript: Bool = false,
        frontmatter: [String: String] = [:]
    ) {
        self.vault = PathComponent.normalised(vault)
        self.coursesSubdir = coursesSubdir
        self.lecturesSubdir = lecturesSubdir
        self.keepTranscript = keepTranscript
        self.frontmatter = frontmatter
    }

    public var targetID: VaultTargetID {
        VaultTargetID(vault: vault, coursesSubdir: coursesSubdir, lecturesSubdir: lecturesSubdir)
    }

    public func noteURL(course: String, date: String, topic: String) -> URL {
        NotePath.url(
            vault: vault, coursesSubdir: coursesSubdir, lecturesSubdir: lecturesSubdir,
            course: course, date: date, topic: topic
        )
    }
}

/// One implementation of destination-path building, shared by every target.
///
/// Duplicating it guarantees the sanitiser gets applied inconsistently: a fix in
/// one builder silently misses the other.
enum NotePath {
    static func directory(
        vault: URL, coursesSubdir: String, lecturesSubdir: String, course: String
    ) -> URL {
        PathComponent.normalised(vault)
            .appending(path: PathComponent.relativePath(coursesSubdir, fallback: "Courses"))
            .appending(path: PathComponent.sanitised(course, fallback: unsortedFolder))
            .appending(path: PathComponent.relativePath(lecturesSubdir, fallback: "Lectures"))
    }

    static func url(
        vault: URL, coursesSubdir: String, lecturesSubdir: String,
        course: String, date: String, topic: String
    ) -> URL {
        let safeDate = PathComponent.sanitised(date, fallback: "undated")
        let safeTopic = PathComponent.sanitised(topic, fallback: "Lecture")
        return directory(
            vault: vault, coursesSubdir: coursesSubdir,
            lecturesSubdir: lecturesSubdir, course: course
        )
        .appending(path: "\(safeDate) — \(safeTopic).md")
    }
}

public struct Settings: Sendable, Codable, Equatable {
    public var vault: URL
    public var coursesSubdir: String
    public var lecturesSubdir: String
    /// Seconds of speech to accumulate before asking Claude for interim notes.
    public var liveInterval: TimeInterval
    /// Skip a live pass that would summarise fewer than this many new words.
    public var minWordsPerPass: Int
    public var liveModel: String
    public var finalModel: String
    public var detectModel: String
    public var keepTranscript: Bool
    public var keepAudio: Bool
    public var mirrors: [MirrorTarget]
    /// Explicit path to the `claude` binary. Nil means search known locations.
    public var claudePath: URL?
    /// Pin the course instead of detecting it. Detection still supplies the topic.
    public var pinnedCourse: String?
    /// Watch the inbox for recordings made elsewhere, typically on a phone.
    public var watchesInbox: Bool

    public init(
        vault: URL,
        coursesSubdir: String = "Courses",
        lecturesSubdir: String = "Lectures",
        liveInterval: TimeInterval = 180,
        minWordsPerPass: Int = 40,
        liveModel: String = "sonnet",
        finalModel: String = "opus",
        detectModel: String = "sonnet",
        keepTranscript: Bool = true,
        keepAudio: Bool = false,
        mirrors: [MirrorTarget] = [],
        claudePath: URL? = nil,
        pinnedCourse: String? = nil,
        watchesInbox: Bool = true
    ) {
        self.vault = PathComponent.normalised(vault)
        self.coursesSubdir = coursesSubdir
        self.lecturesSubdir = lecturesSubdir
        self.liveInterval = liveInterval
        self.minWordsPerPass = minWordsPerPass
        self.liveModel = liveModel
        self.finalModel = finalModel
        self.detectModel = detectModel
        self.keepTranscript = keepTranscript
        self.keepAudio = keepAudio
        self.mirrors = mirrors
        self.claudePath = claudePath
        self.pinnedCourse = pinnedCourse
        self.watchesInbox = watchesInbox
    }

    public var targetID: VaultTargetID {
        VaultTargetID(vault: vault, coursesSubdir: coursesSubdir, lecturesSubdir: lecturesSubdir)
    }

    /// Where recordings made elsewhere are dropped.
    ///
    /// At the vault root, deliberately outside `coursesSubdir`: everything under
    /// the courses folder is treated as a course, so an inbox in there would
    /// appear in the sidebar as a course named after the folder.
    public var inboxDirectory: URL {
        PathComponent.normalised(vault).appending(path: "_Lecture Inbox")
    }

    public var coursesDirectory: URL {
        PathComponent.normalised(vault)
            .appending(path: PathComponent.relativePath(coursesSubdir, fallback: "Courses"))
    }

    public func lectureDirectory(course: String) -> URL {
        NotePath.directory(
            vault: vault, coursesSubdir: coursesSubdir,
            lecturesSubdir: lecturesSubdir, course: course
        )
    }

    public func noteURL(course: String, date: String, topic: String) -> URL {
        NotePath.url(
            vault: vault, coursesSubdir: coursesSubdir, lecturesSubdir: lecturesSubdir,
            course: course, date: date, topic: topic
        )
    }
}

// MARK: - Courses

public enum Confidence: String, Sendable, Codable, Equatable {
    case high, low
}

/// Folder used when the course could not be identified confidently. A misfiled
/// lecture quietly corrupts revision material, so an unfiled one is preferable.
public let unsortedFolder = "_Unsorted"

/// Filename of the roster inside the courses directory.
public let rosterFilename = "courses.md"

public struct CourseGuess: Sendable, Equatable {
    public var course: String
    public var confidence: Confidence
    public var topic: String

    /// Sanitises at the boundary where the model's answer is first accepted, so
    /// no downstream path builder can be handed a traversal.
    public init(course: String, confidence: Confidence, topic: String) {
        self.course = PathComponent.sanitised(course, fallback: unsortedFolder)
        self.confidence = confidence
        self.topic = PathComponent.sanitised(topic, fallback: "Lecture")
    }

    public var isConfident: Bool { confidence == .high }
}

// MARK: - The note

/// The note's content, rebuilt whole from state on every write.
///
/// Whole-file rewriting is deliberate: the live pass, the final pass and the
/// transcript never have to parse or splice each other's markdown, and Obsidian
/// reloads an externally-changed file automatically.
public struct LectureNote: Sendable, Equatable {
    public var date: String
    public var course: String
    public var topic: String
    /// Incremental notes from live passes, in order.
    public var sections: [String]
    /// The full-lecture pass. When present it replaces the live sections.
    public var finalNotes: String?
    public var transcript: String
    public var duration: TimeInterval
    public var detectedCourse: String?
    public var detectionConfidence: Confidence?
    /// Where this note currently lives for each write target, so a later course
    /// change relocates every copy independently. Keyed by target configuration
    /// rather than by current path, which changes, or by vault, which two
    /// targets can share.
    public var writtenPaths: [VaultTargetID: URL]

    public init(
        date: String,
        course: String,
        topic: String = "Lecture",
        sections: [String] = [],
        finalNotes: String? = nil,
        transcript: String = "",
        duration: TimeInterval = 0,
        detectedCourse: String? = nil,
        detectionConfidence: Confidence? = nil,
        writtenPaths: [VaultTargetID: URL] = [:]
    ) {
        self.date = date
        self.course = course
        self.topic = topic
        self.sections = sections
        self.finalNotes = finalNotes
        self.transcript = transcript
        self.duration = duration
        self.detectedCourse = detectedCourse
        self.detectionConfidence = detectionConfidence
        self.writtenPaths = writtenPaths
    }

    public var liveNotes: String {
        sections.joined(separator: "\n\n")
    }

    public mutating func addSection(_ markdown: String) {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { sections.append(trimmed) }
    }

    /// A date as YYYY-MM-DD in local time.
    ///
    /// Named for the argument rather than for the default: a recording written
    /// up from the inbox is dated when it was *made*, which can be days before
    /// the Mac ever saw it, and `today(someOldDate)` reads like a bug.
    public static func day(of moment: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day], from: moment)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - Errors

public enum LectureKitError: Error, Sendable, Equatable {
    case claudeNotFound
    case claudeFailed(String)
    case claudeNotLoggedIn
    case microphoneDenied
    case modelsUnavailable(String)
    case captureFailed(String)
}
