import Foundation
import Testing

@testable import LectureKit

private final class InboxSandbox {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Writes a file of `bytes` and back-dates it, because "settled" is measured
    /// from the modification date and a test cannot wait twenty seconds.
    @discardableResult
    func drop(_ name: String, bytes: Int = 200_000, ageSeconds: TimeInterval = 60) throws -> URL {
        let url = dir.appending(path: name)
        try Data(repeating: 0, count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ageSeconds)], ofItemAtPath: url.path)
        return url
    }

    deinit { try? FileManager.default.removeItem(at: dir) }
}

@Test("a settled recording is picked up")
func picksUpSettledAudio() throws {
    let box = try InboxSandbox()
    try box.drop("2026-09-02 lecture.m4a")

    let pending = InboxWatcher.pending(in: box.dir)
    #expect(pending.count == 1)
    #expect(pending.first?.url.lastPathComponent == "2026-09-02 lecture.m4a")
}

@Test("a file still being synced is left alone")
func skipsFilesStillArriving() throws {
    let box = try InboxSandbox()
    // Just written, so a sync client may still be extending it. Reading this now
    // transcribes part of a lecture and produces a short note that looks whole,
    // which is the failure this guard exists to prevent.
    try box.drop("arriving.m4a", ageSeconds: 0)

    #expect(InboxWatcher.pending(in: box.dir).isEmpty)
}

@Test("a file too small to be a lecture is ignored")
func skipsTinyFiles() throws {
    let box = try InboxSandbox()
    try box.drop("misfire.m4a", bytes: 4_000)

    // Processing this would spend a model call to summarise two seconds of room
    // noise.
    #expect(InboxWatcher.pending(in: box.dir).isEmpty)
}

@Test("only audio is considered")
func ignoresNonAudio() throws {
    let box = try InboxSandbox()
    try box.drop("README.md")
    try box.drop("notes.pdf")
    try box.drop("lecture.m4a")

    #expect(InboxWatcher.pending(in: box.dir).map(\.url.lastPathComponent) == ["lecture.m4a"])
}

@Test("oldest first, so lectures are written up in the order they happened")
func oldestFirst() throws {
    let box = try InboxSandbox()
    try box.drop("second.m4a", ageSeconds: 120)
    try box.drop("first.m4a", ageSeconds: 600)
    try box.drop("third.m4a", ageSeconds: 60)

    #expect(InboxWatcher.pending(in: box.dir).map(\.url.lastPathComponent)
        == ["first.m4a", "second.m4a", "third.m4a"])
}

@Test("an archived recording is moved, not deleted, and stops being pending")
func archiveMovesAndClears() throws {
    let box = try InboxSandbox()
    let url = try box.drop("lecture.m4a")

    let moved = try InboxWatcher.archive(url, in: box.dir)

    #expect(FileManager.default.fileExists(atPath: moved.path(percentEncoded: false)))
    #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    #expect(moved.deletingLastPathComponent().lastPathComponent == "Written up")
    // The point of moving rather than deleting: the recording is the only part
    // of a lecture that cannot be regenerated.
    #expect(InboxWatcher.pending(in: box.dir).isEmpty)
}

@Test("two recordings with the same name both survive archiving")
func archiveDoesNotOverwrite() throws {
    let box = try InboxSandbox()
    let first = try box.drop("Voice Memo.m4a")
    _ = try InboxWatcher.archive(first, in: box.dir)
    let second = try box.drop("Voice Memo.m4a")

    let moved = try InboxWatcher.archive(second, in: box.dir)

    #expect(moved.lastPathComponent == "Voice Memo 2.m4a")
    let done = box.dir.appending(path: "Written up")
    let names = try FileManager.default.contentsOfDirectory(atPath: done.path).sorted()
    #expect(names == ["Voice Memo 2.m4a", "Voice Memo.m4a"])
}

@Test("the archive folder is not itself scanned as pending work")
func archiveIsNotRescanned() throws {
    let box = try InboxSandbox()
    let url = try box.drop("lecture.m4a")
    _ = try InboxWatcher.archive(url, in: box.dir)

    // Would otherwise be an infinite loop: process, archive, find it again.
    #expect(InboxWatcher.pending(in: box.dir).isEmpty)
}

@Test("a missing inbox is empty rather than an error")
func missingDirectoryIsEmpty() {
    #expect(InboxWatcher.pending(in: URL(fileURLWithPath: "/nope-\(UUID().uuidString)")).isEmpty)
}

@Test("preparing the inbox explains itself to anyone browsing the vault")
func prepareWritesAReadme() throws {
    let box = try InboxSandbox()
    let inbox = box.dir.appending(path: "_Lecture Inbox")
    try InboxWatcher.prepare(inbox)

    // Whitespace-collapsed before matching: the source string is hard-wrapped,
    // so "Voice Memos" is split across a line break and a naive `contains` for
    // it fails against a README that plainly says it.
    let readme = try String(contentsOf: inbox.appending(path: "README.md"), encoding: .utf8)
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    #expect(readme.contains("Voice Memos"))
    #expect(readme.contains("Written up"))
}

@Test("the inbox sits outside the courses folder")
func inboxIsNotACourse() {
    let settings = Settings(vault: URL(fileURLWithPath: "/tmp/v"), coursesSubdir: "00 - Courses")
    let inbox = settings.inboxDirectory.path(percentEncoded: false)
    let courses = settings.coursesDirectory.path(percentEncoded: false)

    // `CourseDetector` treats every directory under the courses folder as a
    // course, so an inbox inside it would appear in the sidebar as one.
    #expect(!inbox.hasPrefix(courses))
}
