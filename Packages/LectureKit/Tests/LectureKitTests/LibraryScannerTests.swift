import Foundation
import Testing

@testable import LectureKit

/// Real vaults in a temp directory. The scanner's entire job is to report what
/// is on disk, so anything short of actual files and folders would be testing a
/// different function.
private final class ScanSandbox {
    let vault: URL

    init() throws {
        vault = FileManager.default.temporaryDirectory
            .appending(path: "LibraryScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    }

    var settings: Settings { Settings(vault: vault) }

    /// Write an arbitrary file, creating its parents. Used for the notes the
    /// scanner must *not* treat as lectures.
    func write(_ contents: String, to relativePath: String) throws {
        let url = vault.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: vault)
    }
}

/// 120 words over 60 minutes, so the expected words-per-minute is exactly 2.
private func lecture(
    course: String, topic: String = "Eigenvalues", date: String = "2026-07-30"
) -> LectureNote {
    LectureNote(
        date: date,
        course: course,
        topic: topic,
        finalNotes: "## Summary\n\nDeterminants vanish.",
        transcript: Array(repeating: "word", count: 120).joined(separator: " "),
        duration: 3600,
        detectedCourse: course,
        detectionConfidence: .high
    )
}

/// A lecture with nothing in it but the two fields the filing order reads.
private func stub(_ topic: String, date: String = "2026-07-30") -> LibraryLecture {
    LibraryLecture(
        url: URL(fileURLWithPath: "/tmp/\(date) — \(topic).md"),
        course: "MATH 101", date: date, topic: topic, durationMinutes: nil,
        status: nil, detectionConfidence: nil, audioURL: nil, wordsPerMinute: nil)
}

@Test("a rendered note comes back out of the scanner with every field intact")
func roundTrip() throws {
    let sandbox = try ScanSandbox()
    var note = lecture(course: "MATH 101")
    let written = try VaultWriter().save(&note, settings: sandbox.settings)

    let courses = LibraryScanner.scan(settings: sandbox.settings)
    #expect(courses.map(\.name) == ["MATH 101"])

    let found = try #require(courses.first?.lectures.first)
    #expect(found.url.standardizedFileURL == written.standardizedFileURL)
    #expect(found.course == "MATH 101")
    #expect(found.date == "2026-07-30")
    #expect(found.topic == "Eigenvalues")
    #expect(found.durationMinutes == 60)
    #expect(found.status == "complete")
    #expect(found.detectionConfidence == .high)
    #expect(found.wordsPerMinute == 2)
    #expect(found.audioURL == nil)
}

@Test("a hand-written note outside Lectures/ is not a lecture")
func nonLectureFileIsExcluded() throws {
    let sandbox = try ScanSandbox()
    var note = lecture(course: "CS 314H", topic: "Balanced trees")
    try VaultWriter().save(&note, settings: sandbox.settings)
    // The shape the real vault actually has: a reading note filed by hand.
    try sandbox.write("# Chapter 2\n", to: "Courses/CS 314H/Weiss Java/Chapter 2.md")

    let courses = LibraryScanner.scan(settings: sandbox.settings)
    let cs = try #require(courses.first { $0.name == "CS 314H" })
    #expect(cs.lectures.map(\.topic) == ["Balanced trees"])
}

@Test("courses.md is the roster, not a course")
func rosterIsNotACourse() throws {
    let sandbox = try ScanSandbox()
    try sandbox.write("- MATH 101\n", to: "Courses/\(rosterFilename)")
    try sandbox.write("", to: "Courses/MATH 101/Lectures/2026-07-30 — Eigenvalues.md")

    #expect(LibraryScanner.scan(settings: sandbox.settings).map(\.name) == ["MATH 101"])
}

@Test("_Unsorted is a course folder and appears like any other")
func unsortedIsACourse() throws {
    let sandbox = try ScanSandbox()
    var note = lecture(course: unsortedFolder)
    try VaultWriter().save(&note, settings: sandbox.settings)

    let courses = LibraryScanner.scan(settings: sandbox.settings)
    #expect(courses.map(\.name) == [unsortedFolder])
    #expect(courses.first?.lectures.count == 1)
}

@Test("a note with no frontmatter still appears, dated and titled from its name")
func filenameFallback() throws {
    let sandbox = try ScanSandbox()
    try sandbox.write(
        "just some markdown, no frontmatter at all\n",
        to: "Courses/MATH 101/Lectures/2026-07-29 — Change of basis.md"
    )

    let found = try #require(
        LibraryScanner.scan(settings: sandbox.settings).first?.lectures.first
    )
    #expect(found.date == "2026-07-29")
    #expect(found.topic == "Change of basis")
    #expect(found.durationMinutes == nil)
    #expect(found.status == nil)
    #expect(found.wordsPerMinute == nil)
}

@Test("the folder wins when the course: key disagrees with it")
func folderBeatsFrontmatter() throws {
    let sandbox = try ScanSandbox()
    // What a note dragged from _Unsorted into MATH 101 in Obsidian looks like.
    var note = lecture(course: unsortedFolder)
    let rendered = NoteRenderer().render(note)
    try sandbox.write(rendered, to: "Courses/MATH 101/Lectures/2026-07-30 — Eigenvalues.md")
    note.course = unsortedFolder

    let found = try #require(
        LibraryScanner.scan(settings: sandbox.settings).first?.lectures.first
    )
    #expect(found.course == "MATH 101")
}

@Test("audio is reported only when the sibling .wav is really there")
func audioFoundOnlyWhenPresent() throws {
    let sandbox = try ScanSandbox()
    var withAudio = lecture(course: "MATH 101", topic: "Eigenvalues", date: "2026-07-30")
    var without = lecture(course: "MATH 101", topic: "Change of basis", date: "2026-07-29")
    let audible = try VaultWriter().save(&withAudio, settings: sandbox.settings)
    try VaultWriter().save(&without, settings: sandbox.settings)

    let wav = audible.deletingPathExtension().appendingPathExtension("wav")
    try Data().write(to: wav)

    let lectures = LibraryScanner.scan(settings: sandbox.settings).first?.lectures ?? []
    // Newest first, so the note with audio leads.
    #expect(lectures.map(\.topic) == ["Eigenvalues", "Change of basis"])
    #expect(lectures.first?.audioURL?.standardizedFileURL == wav.standardizedFileURL)
    #expect(lectures.last?.audioURL == nil)
}

@Test("a mirror written without a transcript has no speech density to report")
func transcriptlessMirrorHasNoWPM() throws {
    let sandbox = try ScanSandbox()
    var note = lecture(course: "MATH 101")
    let mirror = MirrorTarget(vault: sandbox.vault, keepTranscript: false)
    let rendered = NoteRenderer().render(note, keepTranscript: mirror.keepTranscript)
    try sandbox.write(rendered, to: "Courses/MATH 101/Lectures/2026-07-30 — Eigenvalues.md")
    note.transcript = ""

    let found = try #require(
        LibraryScanner.scan(settings: sandbox.settings).first?.lectures.first
    )
    #expect(found.durationMinutes == 60)
    #expect(found.wordsPerMinute == nil)
}

@Test("two lectures on one day are ordered by filename, not by arrival")
func sameDayOrderIsStable() {
    // Fed in reverse, which is the one thing a scan cannot produce:
    // `contentsOfDirectory` returns alphabetical entries on APFS and Swift's sort
    // is stable, so a scan-level version of this test passes with the tie-break
    // deleted. Reversed input is what makes the assertion mean anything.
    let sorted = LibraryScanner.inFilingOrder([stub("Zeta"), stub("Alpha")])
    #expect(sorted.map(\.topic) == ["Alpha", "Zeta"])
}

@Test("a newer lecture outranks an older one regardless of filename")
func newerLectureLeads() {
    let sorted = LibraryScanner.inFilingOrder([
        stub("Alpha", date: "2026-07-29"), stub("Zeta", date: "2026-07-30"),
    ])
    #expect(sorted.map(\.topic) == ["Zeta", "Alpha"])
}

@Test("a note that arrives CRLF-terminated is read, not silently blanked")
func crlfNoteIsRead() throws {
    let sandbox = try ScanSandbox()
    var note = lecture(course: "MATH 101")
    // What a Windows Obsidian, a Syncthing round-trip or a CRLF-defaulted editor
    // hands back. Splitting on "\n" leaves a "\r" that stops `---` matching, and
    // every field reads as absent while the note still lists.
    let rendered = NoteRenderer().render(note)
        .replacingOccurrences(of: "\n", with: "\r\n")
    try sandbox.write(rendered, to: "Courses/MATH 101/Lectures/2026-07-30 — Eigenvalues.md")
    note.transcript = ""

    let found = try #require(
        LibraryScanner.scan(settings: sandbox.settings).first?.lectures.first
    )
    #expect(found.durationMinutes == 60)
    #expect(found.status == "complete")
    #expect(found.detectionConfidence == .high)
    #expect(found.wordsPerMinute == 2)
}

@Test("a title with a quote in it survives being written and read back")
func escapedTitleRoundTrips() throws {
    let sandbox = try ScanSandbox()
    // The renderer escapes these so a stray quote cannot take the whole
    // frontmatter block down. Reading them back unescaped is the other half of
    // that: without it the library shows the backslashes, and re-running the
    // note feeds them to the renderer again — which escapes them again, every
    // time, without bound.
    let topic = #"Trees "and" \graphs"#
    let note = lecture(course: "MATH 101", topic: topic)
    try sandbox.write(
        NoteRenderer().render(note),
        to: "Courses/MATH 101/Lectures/2026-07-30 — Trees.md")

    let found = try #require(
        LibraryScanner.scan(settings: sandbox.settings).first?.lectures.first
    )
    #expect(found.topic == topic)

    // Rendering what was read produces the same file, which is what makes a
    // re-run a repair rather than a slow corruption.
    var again = note
    again.topic = found.topic
    #expect(NoteRenderer().render(again) == NoteRenderer().render(note))
}

@Test("a frontmatter date of the wrong shape falls back to the filename")
func malformedDateFallsBack() throws {
    let sandbox = try ScanSandbox()
    // A date the user retyped by hand. Trusting it would sort this note into the
    // wrong place and drag the surrounding list with it.
    try sandbox.write(
        "---\ntitle: \"Eigenvalues\"\ndate: 30/07/2026\n---\n\n# Eigenvalues\n",
        to: "Courses/MATH 101/Lectures/2026-07-30 — Eigenvalues.md"
    )

    let found = try #require(
        LibraryScanner.scan(settings: sandbox.settings).first?.lectures.first
    )
    #expect(found.date == "2026-07-30")
}

@Test("an empty title falls back to the filename rather than showing nothing")
func emptyTitleFallsBack() throws {
    let sandbox = try ScanSandbox()
    try sandbox.write(
        "---\ntitle: \"\"\ndate: 2026-07-30\n---\n\n# untitled\n",
        to: "Courses/MATH 101/Lectures/2026-07-30 — Change of basis.md"
    )

    let found = try #require(
        LibraryScanner.scan(settings: sandbox.settings).first?.lectures.first
    )
    #expect(found.topic == "Change of basis")
}

@Test("a topic that starts with a hyphen keeps it")
func leadingHyphenSurvives() throws {
    let sandbox = try ScanSandbox()
    try sandbox.write("", to: "Courses/MATH 101/Lectures/2026-07-30 — -1 eigenvalues.md")

    let found = try #require(
        LibraryScanner.scan(settings: sandbox.settings).first?.lectures.first
    )
    #expect(found.topic == "-1 eigenvalues")
}

@Test("a ## Transcript line inside a fenced block is sample text, not a heading")
func fencedTranscriptHeadingIsNotStructure() throws {
    let sandbox = try ScanSandbox()
    try sandbox.write(
        """
        ---
        title: "Markdown"
        date: 2026-07-30
        duration_min: 10
        ---

        ```
        ## Transcript
        one two three four five
        ```
        """,
        to: "Courses/MATH 101/Lectures/2026-07-30 — Markdown.md"
    )

    let found = try #require(
        LibraryScanner.scan(settings: sandbox.settings).first?.lectures.first
    )
    #expect(found.wordsPerMinute == nil)
}

@Test("a missing vault yields no courses rather than a crash")
func missingVaultIsEmpty() {
    let absent = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    #expect(LibraryScanner.scan(settings: Settings(vault: absent)).isEmpty)
}
