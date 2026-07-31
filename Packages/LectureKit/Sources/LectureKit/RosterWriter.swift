import Foundation

/// Writes the course roster back to `courses.md`.
///
/// The roster is a plain markdown list in the vault, read by
/// `CourseDetector.readRoster` and edited by hand in Obsidian long before this
/// app existed. So writing it has one hard requirement that is not "produce valid
/// markdown": **do not destroy what is already in the file.** A roster commonly
/// carries YAML frontmatter, a heading, notes to self, and links to other notes,
/// none of which this app understands and all of which belong to the user.
///
/// The strategy is therefore surgical rather than generative. Course lines are
/// replaced in place; every other line is copied through untouched, in order.
public enum RosterWriter {

    /// Rewrite the roster to exactly `courses`, preserving everything else.
    ///
    /// - Parameter courses: code to full name. An empty name writes a bare code.
    public static func write(
        _ courses: [String: String], in coursesDir: URL
    ) throws {
        let path = coursesDir.appending(path: rosterFilename)
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        try FileManager.default.createDirectory(
            at: coursesDir, withIntermediateDirectories: true)
        try render(courses, into: existing).write(to: path, atomically: true, encoding: .utf8)
    }

    /// The new file contents. Separated from the write so it can be tested
    /// without a filesystem, and so the preservation guarantee is checkable.
    static func render(_ courses: [String: String], into existing: String) -> String {
        let ordered = courses.keys.sorted { first, second in
            let firstIsUnsorted = first == unsortedFolder
            let secondIsUnsorted = second == unsortedFolder
            if firstIsUnsorted != secondIsUnsorted { return secondIsUnsorted }
            return first.localizedStandardCompare(second) == .orderedAscending
        }
        let lines = ordered.map { code -> String in
            let name = courses[code] ?? ""
            return name.isEmpty ? "- \(code)" : "- \(code) — \(name)"
        }

        guard !existing.isEmpty else {
            return (["# Courses", ""] + lines + [""]).joined(separator: "\n")
        }

        // Splice the new list in where the old one was, and keep the rest.
        var out: [String] = []
        var wroteList = false
        var index = 0
        let source = existing.components(separatedBy: .newlines)
        let inFrontmatter = frontmatterRange(source)

        while index < source.count {
            let line = source[index]
            if inFrontmatter.contains(index) || !isCourseLine(line) {
                out.append(line)
                index += 1
                continue
            }
            // The first course line becomes the whole list; the rest are dropped,
            // which is what makes this a rewrite rather than an append.
            if !wroteList {
                out.append(contentsOf: lines)
                wroteList = true
            }
            index += 1
        }

        if !wroteList {
            // No list to replace — a roster that is only frontmatter and prose.
            // Append rather than prepend: whatever is at the top was put there
            // deliberately.
            if out.last?.isEmpty == false { out.append("") }
            out.append(contentsOf: lines)
        }
        return out.joined(separator: "\n")
    }

    /// A list item that `readRoster` would take as a course.
    ///
    /// Matched with the *same* shape the reader uses rather than a looser "starts
    /// with a dash": a roster can contain bullet lists that are not courses, and
    /// a writer that removed those would silently eat the user's own notes.
    private static func isCourseLine(_ line: String) -> Bool {
        let lead = line.drop(while: \.isWhitespace).first
        guard lead == "-" || lead == "*" else { return false }
        let entry = /^\s*[-*]\s*(?:\*\*)?([^*—:|]+?)(?:\*\*)?\s*(?:[—:|]\s*(.*))?$/
        guard let match = line.wholeMatch(of: entry) else { return false }
        let code = match.1.trimmingCharacters(in: .whitespaces)
        let notACourse = /^[-\s]*$|^[a-z]+$/
        return !code.isEmpty && code.firstMatch(of: notACourse) == nil
    }

    /// Indices covered by a leading YAML frontmatter block, whose list items are
    /// tags rather than courses.
    private static func frontmatterRange(_ lines: [String]) -> Range<Int> {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return 0..<0 }
        for index in 1..<lines.count
        where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
            return 0..<(index + 1)
        }
        return 0..<0
    }
}
