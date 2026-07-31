import Foundation
import Testing

@testable import LectureKit

/// These tests are pure filesystem: real directories under a temp root, no fakes.
/// Relocation is the whole point of `VaultWriter`, and it is only observable by
/// looking at what is actually left on disk afterwards.
private final class Sandbox {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "VaultWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func vault(_ name: String) -> URL { root.appending(path: name) }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Collects mirror failures from a `@Sendable` callback. Locked because the
/// callback's contract permits any thread, even though `saveAll` is synchronous.
private final class FailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var vaults: [URL] = []

    func record(_ vault: URL) {
        lock.lock()
        defer { lock.unlock() }
        vaults.append(vault)
    }

    var recorded: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return vaults
    }
}

private func markdownFiles(under url: URL) -> [URL] {
    guard
        let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil
        )
    else { return [] }
    return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }
}

private func note(course: String, topic: String = "Lecture") -> LectureNote {
    LectureNote(
        date: "2026-07-30",
        course: course,
        topic: topic,
        sections: ["- eigenvalues are **scalars**"],
        transcript: "SO THE DETERMINANT VANISHES",
        duration: 3600
    )
}

@Test("primary lands at <vault>/<courses>/<course>/<lectures>/<date> — <topic>.md")
func primaryPath() throws {
    let sandbox = try Sandbox()
    let settings = Settings(vault: sandbox.vault("Primary"))
    var lecture = note(course: "MATH 101", topic: "Eigenvalues")

    let written = try VaultWriter().save(&lecture, settings: settings)

    let expected = sandbox.vault("Primary")
        .appending(path: "Courses")
        .appending(path: "MATH 101")
        .appending(path: "Lectures")
        .appending(path: "2026-07-30 — Eigenvalues.md")
    #expect(written.standardizedFileURL == expected.standardizedFileURL)
    #expect(FileManager.default.fileExists(atPath: expected.path))
    #expect(lecture.writtenPaths[settings.targetID]?.standardizedFileURL == expected.standardizedFileURL)
}

@Test("a mirror gets its own path, its own keepTranscript and its own frontmatter")
func mirrorRendersIndependently() throws {
    let sandbox = try Sandbox()
    let mirror = MirrorTarget(
        vault: sandbox.vault("Mirror"),
        coursesSubdir: "Modules",
        lecturesSubdir: "Sessions",
        keepTranscript: false,
        frontmatter: ["agent": "true"]
    )
    let settings = Settings(
        vault: sandbox.vault("Primary"), keepTranscript: true, mirrors: [mirror]
    )
    var lecture = note(course: "MATH 101", topic: "Eigenvalues")

    let written = VaultWriter().saveAll(&lecture, settings: settings)
    #expect(written.count == 2)

    let primaryText = try String(contentsOf: written[0], encoding: .utf8)
    let mirrorText = try String(contentsOf: written[1], encoding: .utf8)

    #expect(primaryText.contains("SO THE DETERMINANT VANISHES"))
    #expect(!primaryText.contains("agent: true"))
    #expect(!mirrorText.contains("SO THE DETERMINANT VANISHES"))
    #expect(mirrorText.contains("agent: true"))

    #expect(
        written[1].standardizedFileURL
            == sandbox.vault("Mirror")
            .appending(path: "Modules")
            .appending(path: "MATH 101")
            .appending(path: "Sessions")
            .appending(path: "2026-07-30 — Eigenvalues.md")
            .standardizedFileURL
    )
}

@Test("course detected mid-recording relocates every copy, leaving no duplicate")
func relocationLeavesNoDuplicate() throws {
    let sandbox = try Sandbox()
    let mirror = MirrorTarget(vault: sandbox.vault("Mirror"))
    let settings = Settings(vault: sandbox.vault("Primary"), mirrors: [mirror])
    var lecture = note(course: unsortedFolder)

    let before = VaultWriter().saveAll(&lecture, settings: settings)
    #expect(before.count == 2)

    lecture.course = "MATH 101"
    lecture.topic = "Eigenvalues"
    let after = VaultWriter().saveAll(&lecture, settings: settings)
    #expect(after.count == 2)

    for old in before {
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }
    for new in after {
        #expect(FileManager.default.fileExists(atPath: new.path))
    }
    #expect(markdownFiles(under: sandbox.root).count == 2)
}

@Test("the vacated _Unsorted tree is removed, not left as empty folders")
func vacatedFoldersArePruned() throws {
    let sandbox = try Sandbox()
    let settings = Settings(vault: sandbox.vault("Primary"))
    var lecture = note(course: unsortedFolder)

    try VaultWriter().save(&lecture, settings: settings)
    lecture.course = "MATH 101"
    try VaultWriter().save(&lecture, settings: settings)

    let unsorted = settings.coursesDirectory.appending(path: unsortedFolder)
    #expect(!FileManager.default.fileExists(atPath: unsorted.path))
    #expect(!FileManager.default.fileExists(atPath: unsorted.appending(path: "Lectures").path))
    // The courses directory is still in use by the new course, so it stays.
    #expect(FileManager.default.fileExists(atPath: settings.coursesDirectory.path))
}

@Test("an unwritable mirror is reported and skipped, and the primary still lands")
func brokenMirrorDoesNotCostThePrimary() throws {
    let sandbox = try Sandbox()
    // A regular file cannot have children, so any mkdir beneath it fails.
    let blocker = sandbox.vault("blocker.txt")
    try "not a directory".write(to: blocker, atomically: true, encoding: .utf8)

    let log = FailureLog()
    let mirror = MirrorTarget(vault: blocker.appending(path: "Vault"))
    let settings = Settings(vault: sandbox.vault("Primary"), mirrors: [mirror])
    var lecture = note(course: "MATH 101", topic: "Eigenvalues")

    let writer = VaultWriter(onMirrorFailure: { vault, _ in log.record(vault) })
    let written = writer.saveAll(&lecture, settings: settings)

    #expect(written.count == 1)
    #expect(FileManager.default.fileExists(atPath: written[0].path))
    #expect(log.recorded.count == 1)
    #expect(lecture.writtenPaths[mirror.targetID] == nil)
}

@Test("a mirror identical to the primary is skipped, so the transcript survives")
func duplicateTargetDoesNotEraseTheTranscript() throws {
    let sandbox = try Sandbox()
    // Same vault and subdirs as the primary: same targetID, same file on disk.
    // Writing it again with keepTranscript=false would silently drop a transcript
    // that exists nowhere else.
    let mirror = MirrorTarget(vault: sandbox.vault("Primary"), keepTranscript: false)
    let settings = Settings(
        vault: sandbox.vault("Primary"), keepTranscript: true, mirrors: [mirror]
    )
    var lecture = note(course: "MATH 101", topic: "Eigenvalues")

    let written = VaultWriter().saveAll(&lecture, settings: settings)

    #expect(written.count == 1)
    let text = try String(contentsOf: written[0], encoding: .utf8)
    #expect(text.contains("SO THE DETERMINANT VANISHES"))
}

@Test("a topic that changes only in case does not delete the note just written")
func caseOnlyRelocationKeepsTheNote() throws {
    // macOS volumes are case-insensitive by default, so these two destinations
    // are one file. Relocation compared paths as strings, decided the note had
    // moved, and removed the "old" path — which was the copy it had just
    // written. The lecture existed nowhere else.
    let sandbox = try Sandbox()
    let settings = Settings(vault: sandbox.vault("Primary"))
    var lecture = note(course: "MATH 101", topic: "eigenvalues")

    try VaultWriter().save(&lecture, settings: settings)
    lecture.topic = "Eigenvalues"
    let after = try VaultWriter().save(&lecture, settings: settings)

    #expect(FileManager.default.fileExists(atPath: after.path))
    let text = try String(contentsOf: after, encoding: .utf8)
    #expect(text.contains("SO THE DETERMINANT VANISHES"))
    #expect(markdownFiles(under: sandbox.root).count == 1)
}

@Test("pruning does not follow a symlinked course folder out of the vault")
func pruneStaysInsideTheVaultThroughSymlinks() throws {
    // `standardizedFileURL` resolves "." and ".." but not symlinks, so a course
    // folder linked elsewhere reads as inside the vault while the delete lands
    // wherever the link points.
    let sandbox = try Sandbox()
    let fm = FileManager.default
    let vault = sandbox.vault("Primary")
    let outside = sandbox.root.appending(path: "Outside/CS 314H")
    try fm.createDirectory(at: vault.appending(path: "Courses"), withIntermediateDirectories: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    try fm.createSymbolicLink(
        at: vault.appending(path: "Courses/CS 314H"), withDestinationURL: outside
    )

    let settings = Settings(vault: vault)
    var lecture = note(course: "CS 314H", topic: "Eigenvalues")
    try VaultWriter().save(&lecture, settings: settings)
    #expect(fm.fileExists(atPath: outside.appending(path: "Lectures").path))

    lecture.course = "MATH 101"
    try VaultWriter().save(&lecture, settings: settings)

    #expect(
        fm.fileExists(atPath: outside.appending(path: "Lectures").path),
        "pruning deleted a directory outside the vault"
    )
    #expect(fm.fileExists(atPath: outside.path))
}
