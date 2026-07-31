import Foundation
import Testing

@testable import LectureKit

/// These pin four defects found by adversarial review of the original contract.
/// Each one silently loses or misplaces the user's notes, so none of them fail
/// loudly on their own.

@Suite("Path safety")
struct PathSafetyTests {

    @Test("a model-supplied course cannot escape the vault")
    func traversalIsNeutralised() {
        let vault = URL(fileURLWithPath: "/tmp/vault")
        let settings = Settings(vault: vault)

        for hostile in ["../../../../etc", "..", "../..", "/etc/passwd", "a/../../b"] {
            let url = settings.noteURL(course: hostile, date: "2026-09-02", topic: "T")
            #expect(
                url.path.hasPrefix("/tmp/vault/"),
                "course \(hostile) escaped the vault: \(url.path)"
            )
            #expect(!url.path.contains(".."), "unresolved traversal in \(url.path)")
        }
    }

    @Test("a model-supplied topic cannot escape the vault")
    func topicTraversalIsNeutralised() {
        let settings = Settings(vault: URL(fileURLWithPath: "/tmp/vault"))
        let url = settings.noteURL(course: "CS 314H", date: "2026-09-02", topic: "../../evil")
        #expect(url.path.hasPrefix("/tmp/vault/"))
        #expect(url.deletingLastPathComponent().lastPathComponent == "Lectures")
    }

    @Test("an empty course lands in _Unsorted, not a collapsed path")
    func emptyCourseDoesNotCollapse() {
        // appending(path: "") is a no-op, which would drop every unfiled note
        // into one directory where same-date lectures overwrite each other.
        let settings = Settings(vault: URL(fileURLWithPath: "/tmp/vault"))
        for empty in ["", "   ", "...", "///"] {
            let dir = settings.lectureDirectory(course: empty)
            #expect(
                dir.path == "/tmp/vault/Courses/\(unsortedFolder)/Lectures",
                "empty course \(empty.debugDescription) collapsed to \(dir.path)"
            )
        }
    }

    @Test("sanitiser strips separators and leading dots")
    func sanitiserBasics() {
        #expect(PathComponent.sanitised("Trees / Graphs", fallback: "X") == "Trees Graphs")
        #expect(PathComponent.sanitised("../../etc/passwd", fallback: "X") == "etcpasswd")
        #expect(PathComponent.sanitised("..", fallback: "X") == "X")
        // dot-runs collapse: "a/../../b" must not keep a ".." sequence
        #expect(PathComponent.sanitised("a/../../b", fallback: "X") == "a.b")
        #expect(PathComponent.sanitised("  Binary  Search  ", fallback: "X") == "Binary Search")
        #expect(PathComponent.sanitised("", fallback: "X") == "X")
    }

    @Test("a course of dots and spaces cannot reduce to a bare \".\"")
    func dottedCourseDoesNotCollapseALevel() {
        // Trimming dots and whitespace in sequence left ". . ." as ".": the dot
        // trim took the outer dots, the whitespace trim then exposed the middle
        // one. A "." component drops a directory level, so every such lecture
        // lands in <vault>/Courses/Lectures instead of its own folder — and
        // relocation pruning then walks up to the courses directory itself.
        for dotty in [". . .", "... ... ...", ".  .  ."] {
            #expect(
                PathComponent.sanitised(dotty, fallback: "X") == "X",
                "\(dotty.debugDescription) survived as a path component"
            )
        }
        let settings = Settings(vault: URL(fileURLWithPath: "/tmp/vault"))
        #expect(
            settings.lectureDirectory(course: ". . .").path
                == "/tmp/vault/Courses/\(unsortedFolder)/Lectures"
        )
    }

    @Test("a truncated name never ends in a dot or a space")
    func truncationLeavesAWritableName() {
        // Trimming before truncating let the 120-character cut land on a dot,
        // which some volumes refuse outright.
        let name = String(repeating: "a", count: 119) + ".bcd"
        let safe = PathComponent.sanitised(name, fallback: "X")
        #expect(safe.count <= 120)
        #expect(!safe.hasSuffix("."))
        #expect(!safe.hasSuffix(" "))
    }
}

@Suite("Write-target identity")
struct TargetIdentityTests {

    @Test("a mirror equal to the primary is the same target")
    func mirrorEqualToPrimaryCollapses() {
        // Same key AND same file. If these were distinct, the mirror would
        // rewrite the primary with keepTranscript=false and silently drop the
        // transcript, which exists only in memory.
        let vault = URL(fileURLWithPath: "/tmp/vault")
        let settings = Settings(vault: vault, coursesSubdir: "Courses")
        let mirror = MirrorTarget(vault: vault, coursesSubdir: "Courses")
        #expect(settings.targetID == mirror.targetID)
    }

    @Test("same vault with a different subdir is a different target")
    func sameVaultDifferentSubdirStaysDistinct() {
        // Two real files. Keyed on vault alone, the second write would evict the
        // first's tracked URL and orphan it permanently on the next relocation.
        let vault = URL(fileURLWithPath: "/tmp/vault")
        let a = Settings(vault: vault, coursesSubdir: "Courses")
        let b = MirrorTarget(vault: vault, coursesSubdir: "02 Areas/Courses")
        #expect(a.targetID != b.targetID)
    }

    @Test("target identity survives a course change")
    func identityIsStableAcrossRelocation() {
        // The whole point: the note moves, the target does not.
        let settings = Settings(vault: URL(fileURLWithPath: "/tmp/vault"))
        let before = settings.targetID
        _ = settings.noteURL(course: unsortedFolder, date: "2026-09-02", topic: "Lecture")
        _ = settings.noteURL(course: "CS 314H", date: "2026-09-02", topic: "BST")
        #expect(settings.targetID == before)
    }

    @Test("equivalent vault paths produce one identity")
    func vaultPathsAreNormalised() {
        // A settings file rewritten with a trailing slash would otherwise make
        // every previously tracked copy unrecognisable.
        let plain = Settings(vault: URL(fileURLWithPath: "/tmp/vault"))
        let slash = Settings(vault: URL(fileURLWithPath: "/tmp/vault/"))
        let dotted = Settings(vault: URL(fileURLWithPath: "/tmp/./vault"))
        #expect(plain.targetID == slash.targetID)
        #expect(plain.targetID == dotted.targetID)
        #expect(plain.noteURL(course: "C", date: "d", topic: "t")
            == dotted.noteURL(course: "C", date: "d", topic: "t"))
    }
}

@Suite("Note model")
struct NoteModelTests {

    @Test("CourseGuess sanitises at the boundary")
    func guessSanitises() {
        let g = CourseGuess(course: "../../etc", confidence: .high, topic: "a/b")
        #expect(!g.course.contains("/"))
        #expect(!g.course.contains(".."))
        #expect(!g.topic.contains("/"))
    }

    @Test("empty model output falls back rather than collapsing")
    func emptyGuessFallsBack() {
        let g = CourseGuess(course: "   ", confidence: .low, topic: "")
        #expect(g.course == unsortedFolder)
        #expect(g.topic == "Lecture")
    }

    @Test("sections join in order and blanks are ignored")
    func sectionHandling() {
        var note = LectureNote(date: "2026-09-02", course: "CS 314H")
        note.addSection("- one")
        note.addSection("   ")
        note.addSection("- two")
        #expect(note.sections.count == 2)
        #expect(note.liveNotes == "- one\n\n- two")
    }

    @Test("today is local-time YYYY-MM-DD")
    func todayFormat() {
        let s = LectureNote.today()
        #expect(s.count == 10)
        #expect(s.dropFirst(4).first == "-")
    }
}

@Suite("Nested subdirectories")
struct NestedSubdirTests {

    @Test("a nested courses subdir keeps its levels")
    func nestedSubdirSurvives() {
        // Real config: the Toyo Brain mirror files under "02 Areas/Courses".
        // Running it through the single-component sanitiser produced the single
        // folder "02 AreasCourses" and wrote to the wrong place.
        let s = Settings(vault: URL(fileURLWithPath: "/tmp/v"), coursesSubdir: "02 Areas/Courses")
        #expect(s.coursesDirectory.path == "/tmp/v/02 Areas/Courses")
        let note = s.noteURL(course: "CS 314H", date: "2026-09-02", topic: "BST")
        #expect(note.path == "/tmp/v/02 Areas/Courses/CS 314H/Lectures/2026-09-02 — BST.md")
    }

    @Test("a nested subdir still cannot traverse")
    func nestedSubdirCannotEscape() {
        let s = Settings(vault: URL(fileURLWithPath: "/tmp/v"), coursesSubdir: "../../etc/x")
        #expect(s.coursesDirectory.path.hasPrefix("/tmp/v/"))
        #expect(!s.coursesDirectory.path.contains(".."))
    }

    @Test("subdirs differing only in stripped characters are one target")
    func subdirAliasesCollapseToOneIdentity() {
        // Same file on disk. Two identities would let a mirror overwrite the
        // primary with keepTranscript=false and destroy the transcript.
        let v = URL(fileURLWithPath: "/tmp/v")
        let base = Settings(vault: v, coursesSubdir: "Courses")
        for alias in ["Courses/", "Courses", "/Courses", "Courses?"] {
            let m = MirrorTarget(vault: v, coursesSubdir: alias)
            #expect(
                m.targetID == base.targetID,
                "\(alias) should be the same target as Courses"
            )
            #expect(
                m.noteURL(course: "C", date: "d", topic: "t")
                    == base.noteURL(course: "C", date: "d", topic: "t")
            )
        }
    }
}
