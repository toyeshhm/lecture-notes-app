import Foundation

/// Turning transcript text into an Obsidian note: the prompts that ask for it,
/// the repair pass over what comes back, and the markdown file itself.

// MARK: - System prompts

/// The two system prompts, tuned against real lectures. Wording here is
/// load-bearing — the structure of every note follows from it, so change these
/// only with transcripts to test against.
public enum Prompts {
    public static let live = """
        You take live lecture notes. You receive a rough speech-to-text \
        transcript chunk from a university lecture, plus the notes so far.

        Extend the notes with the new material. Rules:
        - Output ONLY markdown notes. No preamble, no "here are the notes", no closing remarks.
        - Do NOT restate or rewrite the existing notes; output only what is new.
        - Use `- ` bullets. Bold key terms on first use: **term**.
        - Write maths as LaTeX in $...$ or $$...$$.
        - The transcript is ASR output and contains errors. Silently fix obvious \
        mishearings from context (e.g. "v due" -> "v du", "LIAT" -> "LIATE").
        - If the lecturer signals something is examinable, mark it `> [!important] Likely on exam`.
        - If a chunk is filler (admin, silence, tangent) output nothing at all.
        """

    public static let `final` = """
        You write the definitive study notes for one university lecture, \
        from its full speech-to-text transcript. These replace the student's own notes, so be \
        thorough and well organised.

        Output ONLY markdown -- no preamble, no closing remarks, and do NOT wrap it in a code \
        fence. Do NOT write a top-level `# ` heading; the note already has a title.

        Structure, in this order:

        `> [!abstract] In one line`
        A single sentence naming what the lecture was actually about. EVERY line of a
        callout must begin with `> `, including the body line under the header.

        `## Summary`
        2-4 sentences of what was covered and why it matters.

        `## Notes`
        The substance, under `### ` topic headings that follow the lecture's real structure. \
        Bullets, not prose paragraphs. Nest sub-bullets for detail. Bold each key term on first \
        use. Use numbered lists for anything sequential (algorithms, procedures, proofs). Use a \
        markdown table when comparing three or more things across the same dimensions. Put \
        worked examples in ```code fences``` when they are code, or in $$display maths$$ when \
        they are derivations.

        `## Key terms`
        A markdown table: `| Term | Definition |`. Only terms actually introduced in this lecture.

        `## Likely exam material`
        Anything the lecturer flagged, emphasised, repeated, or told students to practise. Quote \
        their phrasing where it was explicit. Omit this whole heading if there was nothing.

        `## Open questions`
        Threads left unresolved or explicitly deferred to a later lecture. Omit if none.

        Rules:
        - The transcript is ASR output with errors. Silently correct obvious mishearings from \
        context; never quote a garbled phrase as if it were correct.
        - Write ALL maths as LaTeX: $O(\\log n)$, not "O of log n".
        - If the transcript is too short or too garbled to support a section, omit that section \
        rather than padding it. Never invent content that is not in the transcript.
        """
}

// MARK: - User prompts

/// The per-call user prompts. Both models return markdown that must be passed
/// through `fixCallouts` before it reaches a note — the prompt asks for prefixed
/// callout bodies and does not reliably get them.
public enum NoteWriterPrompts {
    public static func summariseChunk(newText: String, notesSoFar: String) -> String {
        // Only the tail of the notes is sent: enough for the model to avoid
        // repeating itself, without re-billing the whole lecture every pass.
        let context = notesSoFar.isEmpty ? "(none yet)" : String(notesSoFar.suffix(2000))
        return """
            Notes so far (for context, do not repeat):
            \(context)

            New transcript chunk:
            \(newText)
            """
    }

    public static func finalNotes(transcript: String, course: String) -> String {
        """
        Course: \(course)

        Full lecture transcript:
        \(transcript)
        """
    }
}

// MARK: - Callout repair

/// Prefix callout continuation lines with `> `.
///
/// Obsidian only renders a line as part of a callout if it starts with `>`.
/// Models reliably emit the `> [!note] Title` header and then an unprefixed
/// body line, which silently renders outside the box. Cheaper to repair here
/// than to keep tightening the prompt.
public func fixCallouts(_ markdown: String) -> String {
    var out: [String] = []
    var inCallout = false
    var inFence = false

    // Split rather than splitlines: keeping empty trailing components makes the
    // pass exactly round-trip a string it has nothing to change.
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
        // A fence line is never callout body — an unprefixed fence sits outside
        // the box, so it both closes the callout and passes through untouched.
        // Checking it before the callout branch is what stops the *closing*
        // fence being rewritten to `> ~~~` while a callout is still open.
        let fence = isFence(line)
        if fence {
            inFence.toggle()
            inCallout = false
        }
        if inFence || fence {
            out.append(String(line))
            continue
        }
        if isCalloutHeader(line) {
            inCallout = true
        } else if inCallout {
            let body = line.drop(while: \.isWhitespace)
            if body.isEmpty {
                inCallout = false  // a blank line closes the callout
            } else if !body.hasPrefix(">") {
                out.append("> \(line)")
                continue
            }
        }
        out.append(String(line))
    }
    return out.joined(separator: "\n")
}

private func isFence(_ line: Substring) -> Bool {
    let s = line.drop(while: \.isWhitespace)
    return s.hasPrefix("```") || s.hasPrefix("~~~")
}

/// Matches `> [!name]`, the only form Obsidian treats as opening a callout.
private func isCalloutHeader(_ line: Substring) -> Bool {
    var s = line.drop(while: \.isWhitespace)
    guard s.first == ">" else { return false }
    s = s.dropFirst().drop(while: \.isWhitespace)
    guard s.hasPrefix("[!") else { return false }
    s = s.dropFirst(2)
    let name = s.prefix { $0.isASCII && $0.isLetter }
    return !name.isEmpty && s.dropFirst(name.count).first == "]"
}

// MARK: - The file

public struct NoteRenderer: Sendable {
    public init() {}

    /// Rebuild the whole markdown file from current state.
    public func render(
        _ note: LectureNote,
        keepTranscript: Bool = true,
        extraFrontmatter: [String: String] = [:]
    ) -> String {
        var front = [
            "---",
            "title: \"\(note.topic)\"",
            "course: \(note.course)",
            "date: \(note.date)",
            "type: lecture",
            "duration_min: \(Int(note.duration / 60))",
            "status: \(note.finalNotes != nil ? "complete" : "recording")",
        ]
        if let detected = note.detectedCourse {
            front.append("detected_course: \(detected)")
            front.append("detection_confidence: \(note.detectionConfidence?.rawValue ?? "unknown")")
        }
        // Sorted, because a dictionary's order would otherwise make every write
        // of an unchanged note look like a change to Obsidian and to git.
        for key in extraFrontmatter.keys.sorted() {
            front.append("\(key): \(extraFrontmatter[key] ?? "")")
        }
        front += [
            "tags:",
            "  - lecture",
            "  - \(note.course.lowercased().replacingOccurrences(of: " ", with: "-"))",
            "---",
            "",
        ]

        var body = ["# \(note.topic)", "", "**\(note.course)** · \(note.date)", ""]
        if let detected = note.detectedCourse, note.detectionConfidence == .low {
            body += [
                "> [!warning] Course not identified confidently",
                "> Best guess was **\(detected)**. Move this note into"
                    + " the right course folder and delete this callout.",
                "",
            ]
        }
        if let finalNotes = note.finalNotes {
            // The final pass replaces the live sections rather than appending to
            // them; the same ground is covered better.
            body += [finalNotes, ""]
        } else {
            let live = note.liveNotes
            body += ["## Live notes", "", live.isEmpty ? "_Listening…_" : live, ""]
        }
        if keepTranscript, !note.transcript.isEmpty {
            body += ["---", "", "## Transcript", "", note.transcript, ""]
        }
        return front.joined(separator: "\n") + body.joined(separator: "\n")
    }
}
