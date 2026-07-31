import Foundation

/// Work out which course a lecture belongs to.
///
/// Candidates come from two places: folders that already exist under the courses
/// directory, and an optional hand-written roster. Claude then matches the
/// transcript against them, and may propose a course that doesn't exist yet.
public struct CourseDetector: Sendable {
    private let claude: ClaudeRunner

    public init(claude: ClaudeRunner) {
        self.claude = claude
    }

    static let detectSystem = """
        You identify which university course a lecture transcript belongs to.

        Reply with ONLY a JSON object, no prose and no code fence:
        {"course": "<course code>", "confidence": "high"|"low", "topic": "<3-6 word topic>"}

        Rules:
        - Prefer a course from the provided list. Use its code EXACTLY as given.
        - Only invent a new course code if the material clearly fits none of them. Use the
          code the lecturer says (e.g. "CS 314H"), or a short subject name if none is said.
        - confidence is "high" only if the subject matter clearly matches one course.
          A generic or administrative transcript is "low".
        - topic is what THIS lecture covered, for use as a filename: title case, no dates,
          no course code, no punctuation beyond spaces and hyphens.
        - The transcript is ASR output and may contain errors.
        """

    // MARK: - Candidates

    /// Course folders already in the vault.
    ///
    /// Course folders are the source of truth for candidates, but plenty of
    /// things in a vault are not courses. Anything starting with a dot or
    /// underscore is ours.
    public static func existingCourses(in coursesDir: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: coursesDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        )) ?? []

        return contents
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && !url.lastPathComponent.hasPrefix("_")
                    && !url.lastPathComponent.hasPrefix(".")
            }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// Parse an optional `courses.md` roster of `- CODE — Full Name` bullets.
    ///
    /// Free-form on purpose: the file is for the user, not for the parser.
    /// Anything it can't read is skipped rather than raising.
    public static func readRoster(in coursesDir: URL) -> [String: String] {
        let rosterPath = coursesDir.appending(path: rosterFilename)
        guard let text = try? String(contentsOf: rosterPath, encoding: .utf8) else { return [:] }

        let entry = /^\s*[-*]\s*(?:\*\*)?([^*—:|]+?)(?:\*\*)?\s*(?:[—:|]\s*(.*))?$/
        // A course code has at least one letter and one digit-or-space; bare
        // words like the `- meta` of a YAML tags list, or a `---` rule, are not
        // courses.
        let notACourse = /^[-\s]*$|^[a-z]+$/

        var roster: [String: String] = [:]
        for line in stripFrontmatter(text.components(separatedBy: .newlines)) {
            let lead = line.drop(while: \.isWhitespace).first
            guard lead == "-" || lead == "*" else { continue }
            guard let match = line.wholeMatch(of: entry) else { continue }

            let code = match.1.trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty, code.firstMatch(of: notACourse) == nil else { continue }
            roster[code] = (match.2 ?? "").trimmingCharacters(in: .whitespaces)
        }
        return roster
    }

    /// Drop a leading YAML frontmatter block, whose list items are not courses.
    private static func stripFrontmatter(_ lines: [String]) -> [String] {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return lines }
        for (i, line) in lines.enumerated().dropFirst()
        where line.trimmingCharacters(in: .whitespaces) == "---" {
            return Array(lines[(i + 1)...])
        }
        return lines
    }

    /// Every known course: roster entries plus existing folders.
    public static func candidates(in coursesDir: URL) -> [String: String] {
        var candidates = readRoster(in: coursesDir)
        for name in existingCourses(in: coursesDir) where candidates[name] == nil {
            candidates[name] = ""
        }
        return candidates
    }

    // MARK: - Detection

    /// Identify the course and topic for a transcript. Nil if undecidable.
    public func detect(
        transcript: String,
        candidates: [String: String],
        model: String
    ) async -> CourseGuess? {
        let words = transcript.split(whereSeparator: \.isWhitespace)
        guard words.count >= 20 else { return nil }  // too little speech to judge anything
        let excerpt = words.prefix(1200).joined(separator: " ")

        let listing: String
        if candidates.isEmpty {
            listing = "(none on record yet — propose a code from what the lecturer says)"
        } else {
            // Sorted, because a dictionary has no insertion order: an unstable
            // listing would reword the prompt between runs on identical input.
            listing = candidates.keys.sorted().map { code in
                let name = candidates[code] ?? ""
                return "- \(code)" + (name.isEmpty ? "" : " — \(name)")
            }.joined(separator: "\n")
        }

        let prompt = "Known courses:\n\(listing)\n\nLecture transcript:\n\(excerpt)"
        // Detection is an optimisation, never a precondition for keeping notes:
        // any failure means _Unsorted, not a lost lecture.
        guard let raw = try? await claude.run(
            prompt: prompt, system: Self.detectSystem, model: model, timeout: 240
        ) else { return nil }
        return Self.parseGuess(raw)
    }

    private struct Reply: Decodable {
        var course: String?
        var confidence: String?
        var topic: String?
    }

    /// Pull the JSON object out of the model's reply.
    static func parseGuess(_ raw: String) -> CourseGuess? {
        // `start < end` is not paranoia: a reply of "} {" would slice backwards,
        // which traps on String indices rather than merely failing to decode.
        guard let start = raw.firstIndex(of: "{"),
            let end = raw.lastIndex(of: "}"),
            start < end,
            let data = raw[start...end].data(using: .utf8),
            let reply = try? JSONDecoder().decode(Reply.self, from: data)
        else { return nil }

        let course = reply.course ?? ""
        // An unusable course is a non-answer, so report nothing rather than
        // letting CourseGuess substitute _Unsorted and pass it off as a guess.
        guard !PathComponent.sanitised(course, fallback: "").isEmpty else { return nil }

        return CourseGuess(
            course: course,
            confidence: (reply.confidence ?? "").lowercased() == "high" ? .high : .low,
            topic: reply.topic ?? ""
        )
    }

    /// Decide the folder name to file under.
    ///
    /// A low-confidence guess goes to _Unsorted rather than risking a lecture
    /// landing in the wrong course, where it would quietly corrupt revision notes.
    public static func resolveFolder(_ guess: CourseGuess?, candidates: [String: String]) -> String {
        guard let guess, guess.isConfident else { return unsortedFolder }
        // Match case-insensitively so "cs 314h" reuses the existing "CS 314H"
        // folder instead of creating a near-duplicate. Sorted so two candidates
        // differing only in case resolve the same way every time.
        //
        // Compare the *sanitised* roster key: guess.course was sanitised at the
        // CourseGuess boundary, so a roster code containing a stripped character
        // ("CS/ML 101") could never match its own folder and would silently
        // spawn a duplicate on every lecture.
        for known in candidates.keys.sorted() {
            let normalised = PathComponent.sanitised(known, fallback: "")
            if normalised.caseInsensitiveCompare(guess.course) == .orderedSame {
                return normalised
            }
        }
        return guess.course
    }
}
