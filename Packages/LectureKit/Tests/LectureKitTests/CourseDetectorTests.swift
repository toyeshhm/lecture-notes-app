import Foundation
import Testing

@testable import LectureKit

/// The roster parser and the folder resolver are the two places where a wrong
/// answer is silent: a misparsed roster line invents a course, and a wrong
/// resolution files a lecture where its owner will never look for it.

private func makeCoursesDir(_ build: (URL) throws -> Void) rethrows -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "lecturekit-tests-\(UUID().uuidString)")
        .appending(path: "Courses")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try build(dir)
    return dir
}

@Suite("Roster parsing")
struct RosterTests {

    @Test("codes and names parse from the bullet shapes users actually write")
    func parsesCodesAndNames() throws {
        let dir = try makeCoursesDir { dir in
            try """
                # Courses

                - CS 314H — Algorithms and Data Structures Honors
                * **M 408D** — Sequences, Series and Multivariable Calculus
                - PHY 303K: Engineering Physics I
                - HIS 315L | United States History
                - CS 429
                """.write(to: dir.appending(path: rosterFilename), atomically: true, encoding: .utf8)
        }

        let roster = CourseDetector.readRoster(in: dir)
        #expect(roster["CS 314H"] == "Algorithms and Data Structures Honors")
        #expect(roster["M 408D"] == "Sequences, Series and Multivariable Calculus")
        #expect(roster["PHY 303K"] == "Engineering Physics I")
        #expect(roster["HIS 315L"] == "United States History")
        #expect(roster["CS 429"] == "")
    }

    @Test("YAML frontmatter items and horizontal rules are not courses")
    func ignoresFrontmatterAndRules() throws {
        // The real bug: an Obsidian file starts with frontmatter, and its list
        // items parse as perfectly plausible course codes. Every one of them
        // became a phantom candidate offered to the model.
        let dir = try makeCoursesDir { dir in
            try """
                ---
                aliases:
                  - Course List 2026
                  - Fall 26 Roster
                tags:
                  - reference
                ---

                # Fall 2026

                - CS 314H — Algorithms and Data Structures Honors
                - M 408D — Multivariable Calculus

                ---

                - ---
                - notacourse
                -
                """.write(to: dir.appending(path: rosterFilename), atomically: true, encoding: .utf8)
        }

        #expect(Set(CourseDetector.readRoster(in: dir).keys) == ["CS 314H", "M 408D"])
    }

    @Test("a missing roster is empty, not an error")
    func missingRosterIsEmpty() {
        let dir = makeCoursesDir { _ in }
        #expect(CourseDetector.readRoster(in: dir).isEmpty)
    }
}

@Suite("Candidate discovery")
struct CandidateTests {

    @Test("underscore and dot folders are ours, not courses")
    func existingCoursesSkipsPrivateFolders() throws {
        let dir = try makeCoursesDir { dir in
            for name in ["CS 314H", "M 408D", unsortedFolder, ".obsidian", "_templates"] {
                try FileManager.default.createDirectory(
                    at: dir.appending(path: name), withIntermediateDirectories: true)
            }
            try "not a folder".write(
                to: dir.appending(path: "loose.md"), atomically: true, encoding: .utf8)
        }

        #expect(CourseDetector.existingCourses(in: dir) == ["CS 314H", "M 408D"])
    }

    @Test("roster names win over bare folder names")
    func rosterWinsOverFolders() throws {
        let dir = try makeCoursesDir { dir in
            try "- CS 314H — Algorithms\n".write(
                to: dir.appending(path: rosterFilename), atomically: true, encoding: .utf8)
            for name in ["CS 314H", "M 408D"] {
                try FileManager.default.createDirectory(
                    at: dir.appending(path: name), withIntermediateDirectories: true)
            }
        }

        let candidates = CourseDetector.candidates(in: dir)
        #expect(candidates["CS 314H"] == "Algorithms")
        #expect(candidates["M 408D"] == "")
    }
}

@Suite("Folder resolution")
struct ResolveFolderTests {
    private let candidates = ["CS 314H": "Algorithms", "M 408D": ""]

    @Test("no guess, or an unsure one, is filed unsorted")
    func unsureGoesToUnsorted() {
        // Misfiling corrupts revision material quietly; not filing is visible.
        #expect(CourseDetector.resolveFolder(nil, candidates: candidates) == unsortedFolder)
        let unsure = CourseGuess(course: "CS 314H", confidence: .low, topic: "Trees")
        #expect(CourseDetector.resolveFolder(unsure, candidates: candidates) == unsortedFolder)
    }

    @Test("a differently-cased guess reuses the existing folder")
    func reusesExistingFolderCaseInsensitively() {
        let guess = CourseGuess(course: "cs 314h", confidence: .high, topic: "Trees")
        #expect(CourseDetector.resolveFolder(guess, candidates: candidates) == "CS 314H")
    }

    @Test("a genuinely new course passes through")
    func newCoursePassesThrough() {
        let guess = CourseGuess(course: "GOV 310L", confidence: .high, topic: "Federalism")
        #expect(CourseDetector.resolveFolder(guess, candidates: candidates) == "GOV 310L")
    }
}

@Suite("Detection", .serialized)
struct DetectionTests {

    @Test("a few words of speech decide nothing")
    func shortTranscriptIsUndecidable() async {
        guard let claude = ClaudeRunner.locate() else { return }
        let guess = await CourseDetector(claude: ClaudeRunner(claudePath: claude))
            .detect(transcript: "okay so today um", candidates: [:], model: "sonnet")
        #expect(guess == nil)
    }

    @Test("a lecture on binary search trees picks the CS course")
    func detectsCourseFromRealTranscript() async {
        guard let claude = ClaudeRunner.locate() else { return }

        let transcript = """
            Okay, so last time we finished up with linked lists, and today we are going to talk
            about binary search trees. The invariant is that every key in the left subtree is
            less than the node's key, and every key in the right subtree is greater. Insert and
            lookup both walk down from the root comparing keys, so they cost O(h) where h is the
            height of the tree. The problem is that if you insert sorted keys you degenerate into
            a linked list and h becomes n, which is why next week we will look at red-black trees
            and how rotations keep the tree balanced. Deletion is the annoying case: when the node
            has two children you have to promote its in-order successor.
            """

        let guess = await CourseDetector(claude: ClaudeRunner(claudePath: claude)).detect(
            transcript: transcript,
            candidates: ["CS 314H": "Algorithms and Data Structures", "M 408D": "Calculus"],
            model: "sonnet"
        )

        #expect(guess?.course == "CS 314H")
        #expect(guess?.confidence == .high)
        #expect(guess?.topic.isEmpty == false)
    }
}
