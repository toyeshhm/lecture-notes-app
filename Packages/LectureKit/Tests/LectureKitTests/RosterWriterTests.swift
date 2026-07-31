import Foundation
import Testing

@testable import LectureKit

@Test("a roster round-trips through the reader")
func rosterRoundTrips() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "roster-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let courses = ["CS 314H": "Data Structures", "M 340L": "Linear Algebra", "HIS 315K": ""]
    try RosterWriter.write(courses, in: dir)

    #expect(CourseDetector.readRoster(in: dir) == courses)
}

@Test("everything that is not a course line survives a rewrite")
func rewritePreservesTheRestOfTheFile() {
    // The shape a real roster has: frontmatter whose list items are tags, a
    // heading, prose, and a link the user put there. None of it is this app's,
    // and losing any of it would be losing the user's own writing.
    let existing = """
        ---
        tags:
          - courses
          - meta
        ---

        # My courses

        Remember to update this when registration changes.

        - CS 314H — Data Structures
        - M 340L — Linear Algebra

        See also [[Degree plan]].
        """

    let out = RosterWriter.render(["CS 314H": "Data Structures", "PHY 303K": "Mechanics"], into: existing)

    #expect(out.contains("tags:"))
    #expect(out.contains("  - meta"))
    #expect(out.contains("# My courses"))
    #expect(out.contains("Remember to update this when registration changes."))
    #expect(out.contains("See also [[Degree plan]]."))
    #expect(out.contains("- PHY 303K — Mechanics"))
    // The removed course is gone, and gone only once.
    #expect(!out.contains("M 340L"))
}

@Test("a tag list inside frontmatter is not mistaken for the course list")
func frontmatterTagsAreNotCourses() {
    let existing = """
        ---
        tags:
          - courses
        ---

        - CS 314H — Data Structures
        """
    let out = RosterWriter.render(["M 340L": "Linear Algebra"], into: existing)

    // The frontmatter list survives; the course list is the one replaced.
    #expect(out.contains("  - courses"))
    #expect(out.contains("- M 340L — Linear Algebra"))
    #expect(!out.contains("CS 314H"))
}

@Test("the new list lands where the old one was, not at the end")
func listKeepsItsPosition() {
    let existing = """
        # Courses

        - CS 314H — Data Structures

        Some trailing prose.
        """
    let out = RosterWriter.render(["M 340L": ""], into: existing)
    let lines = out.components(separatedBy: .newlines)
    let course = try? #require(lines.firstIndex(of: "- M 340L"))
    let prose = try? #require(lines.firstIndex(of: "Some trailing prose."))
    #expect((course ?? 99) < (prose ?? 0))
}

@Test("a roster with prose but no list gets one appended")
func appendsWhenThereIsNoList() {
    let out = RosterWriter.render(["CS 314H": "Data Structures"], into: "# Courses\n\nNothing here yet.")
    #expect(out.hasPrefix("# Courses"))
    #expect(out.contains("Nothing here yet."))
    #expect(out.contains("- CS 314H — Data Structures"))
}

@Test("an empty roster file gets a whole document")
func writesAFreshFile() {
    let out = RosterWriter.render(["CS 314H": ""], into: "")
    #expect(out.contains("# Courses"))
    #expect(out.contains("- CS 314H"))
}

@Test("_Unsorted sorts last, as it does everywhere else")
func unsortedTrails() {
    let out = RosterWriter.render([unsortedFolder: "", "M 340L": ""], into: "")
    let lines = out.components(separatedBy: .newlines)
    #expect((lines.firstIndex(of: "- M 340L") ?? 99) < (lines.firstIndex(of: "- \(unsortedFolder)") ?? 0))
}
