import Foundation
import Testing

@testable import LectureKit

@Suite("Callout repair")
struct FixCalloutsTests {

    @Test("an unprefixed body line is pulled into the callout")
    func prefixesBodyLines() {
        // Obsidian drops unprefixed lines out of the callout box.
        let fixed = fixCallouts("> [!abstract] In one line\nBinary search trees.\n\nAfter.")
        #expect(fixed == "> [!abstract] In one line\n> Binary search trees.\n\nAfter.")
    }

    @Test("already-correct callouts are left alone")
    func leavesCorrectCalloutsAlone() {
        let ok = "> [!note] T\n> body\n\nplain"
        #expect(fixCallouts(ok) == ok)
    }

    @Test("code fences are never rewritten")
    func doesNotTouchFences() {
        // A fence right after a callout is the case that catches a naive
        // implementation: the callout is still "open" when the fence starts.
        let fenced = "> [!tip] X\n> a\n\n```py\nnot > a callout\n```"
        #expect(fixCallouts(fenced) == fenced)

        let tilde = "> [!tip] X\n~~~\nnot > a callout\n~~~"
        #expect(fixCallouts(tilde) == tilde)
    }
}

@Suite("Note rendering")
struct NoteRendererTests {

    private let renderer = NoteRenderer()

    private func note(
        finalNotes: String? = nil,
        sections: [String] = ["- live material"],
        transcript: String = "raw words",
        duration: TimeInterval = 125,
        detectedCourse: String? = nil,
        confidence: Confidence? = nil
    ) -> LectureNote {
        LectureNote(
            date: "2026-09-02",
            course: "CS 314H",
            topic: "Binary search trees",
            sections: sections,
            finalNotes: finalNotes,
            transcript: transcript,
            duration: duration,
            detectedCourse: detectedCourse,
            detectionConfidence: confidence
        )
    }

    @Test("duration is reported in whole minutes, truncated")
    func durationInMinutes() {
        #expect(renderer.render(note()).contains("duration_min: 2\n"))
        // 3210s is 53.5 minutes: the one length that tells truncation from
        // rounding. Every note in the vault is rewritten through render and the
        // library sorts and labels on this key, so a drift to a rounding form
        // would silently relabel every lecture that is not a whole number of
        // minutes long.
        #expect(renderer.render(note(duration: 3_210)).contains("duration_min: 53\n"))
    }

    @Test("status flips to complete once the final pass lands")
    func statusTracksFinalNotes() {
        #expect(renderer.render(note()).contains("status: recording"))
        #expect(renderer.render(note(finalNotes: "## Summary")).contains("status: complete"))
    }

    @Test("final notes replace the live ones")
    func finalReplacesLive() {
        let rendered = renderer.render(note(finalNotes: "## Summary\n\nIt was about trees."))
        #expect(rendered.contains("It was about trees."))
        // Keeping both would double every fact in the note.
        #expect(!rendered.contains("- live material"))
        #expect(!rendered.contains("## Live notes"))
    }

    @Test("the placeholder stands in until the first live pass")
    func placeholderWhenEmpty() {
        let rendered = renderer.render(note(sections: []))
        #expect(rendered.contains("## Live notes"))
        #expect(rendered.contains("_Listening…_"))
    }

    @Test("the transcript is omitted when not wanted")
    func transcriptIsOptional() {
        #expect(renderer.render(note(), keepTranscript: true).contains("## Transcript"))
        #expect(!renderer.render(note(), keepTranscript: false).contains("## Transcript"))
        #expect(!renderer.render(note(), keepTranscript: false).contains("raw words"))
    }

    @Test("extra frontmatter is merged, in a stable order")
    func extraFrontmatter() throws {
        let rendered = renderer.render(
            note(),
            extraFrontmatter: ["source": "agent", "author": "toyeshh"]
        )
        #expect(rendered.contains("source: agent"))
        #expect(rendered.contains("author: toyeshh"))
        // Sorted by key, so an unchanged note renders byte-identically.
        let author = try #require(rendered.range(of: "author: toyeshh"))
        let source = try #require(rendered.range(of: "source: agent"))
        #expect(author.lowerBound < source.lowerBound)
    }

    @Test("a low-confidence guess is flagged in the note itself")
    func lowConfidenceWarning() {
        let rendered = renderer.render(note(detectedCourse: "CS 429", confidence: .low))
        #expect(rendered.contains("detected_course: CS 429"))
        #expect(rendered.contains("detection_confidence: low"))
        #expect(rendered.contains("> [!warning] Course not identified confidently"))
        #expect(rendered.contains("> Best guess was **CS 429**."))

        // A confident guess must not nag.
        let confident = renderer.render(note(detectedCourse: "CS 429", confidence: .high))
        #expect(!confident.contains("[!warning]"))
    }

    @Test("the header carries course and date")
    func headerLine() {
        let rendered = renderer.render(note())
        #expect(rendered.hasPrefix("---\ntitle: \"Binary search trees\"\n"))
        #expect(rendered.contains("**CS 314H** · 2026-09-02"))
        #expect(rendered.contains("  - cs-314h"))
    }
}

@Suite("Prompts")
struct PromptsTests {

    @Test("the system prompts survived the port intact")
    func systemPromptsAreIntact() {
        #expect(!Prompts.live.isEmpty)
        #expect(!Prompts.final.isEmpty)
        #expect(Prompts.live.contains("You take live lecture notes."))
        #expect(Prompts.live.contains("`> [!important] Likely on exam`"))
        #expect(Prompts.live.contains("\"LIAT\" -> \"LIATE\""))
        #expect(Prompts.final.contains("You write the definitive study notes"))
        #expect(Prompts.final.contains("`> [!abstract] In one line`"))
        #expect(Prompts.final.contains("| Term | Definition |"))
        #expect(Prompts.final.contains("$O(\\log n)$"))
    }

    @Test("the chunk prompt sends only the tail of the notes")
    func chunkPromptTruncatesContext() {
        let long = String(repeating: "x", count: 5000) + "TAIL"
        let prompt = NoteWriterPrompts.summariseChunk(newText: "new words", notesSoFar: long)
        #expect(prompt.contains("TAIL"))
        #expect(prompt.contains("new words"))
        #expect(prompt.count < 2500)

        let first = NoteWriterPrompts.summariseChunk(newText: "new words", notesSoFar: "")
        #expect(first.contains("(none yet)"))
    }

    @Test("the final prompt names the course")
    func finalPromptCarriesCourse() {
        let prompt = NoteWriterPrompts.finalNotes(transcript: "words", course: "CS 314H")
        #expect(prompt.hasPrefix("Course: CS 314H"))
        #expect(prompt.contains("Full lecture transcript:\nwords"))
    }
}

@Suite("Rendering a reading")
struct ReadingRenderTests {

    private let renderer = NoteRenderer()

    private func reading(source: NoteSource) -> LectureNote {
        LectureNote(
            date: "2026-09-02",
            course: "CS 314H",
            topic: "Dynamic programming",
            finalNotes: "## Summary\n\nSubproblems.",
            // A reading never carries one, but the field exists and a stray
            // value must not reach the file.
            transcript: "should not appear",
            duration: 3_180,
            source: source)
    }

    @Test("a PDF is typed as a reading and records where it came from")
    func rendersPDFFrontmatter() {
        let note = reading(
            source: .pdf(file: URL(fileURLWithPath: "/vault/_Inbox/dp notes.pdf"),
                         pages: 24, ocr: false))
        let out = renderer.render(note, keepTranscript: true)

        #expect(out.contains("\ntype: reading\n"))
        #expect(out.contains("\nsource: \"/vault/_Inbox/dp notes.pdf\"\n"))
        #expect(out.contains("\npages: 24\n"))
        #expect(out.contains("\n  - reading\n"))
        #expect(out.contains("\n  - cs-314h\n"))
    }

    @Test("a reading has no duration, because it has no length")
    func omitsDuration() {
        // Zero is a claim about the material. Absence is a claim about the file,
        // which is the true one — and the library reads this key.
        let out = renderer.render(
            reading(source: .web(page: URL(string: "https://example.com/dp")!, siteTitle: "DP")),
            keepTranscript: true)
        #expect(!out.contains("duration_min"))
    }

    @Test("a reading never carries a transcript section")
    func neverWritesTranscript() {
        // The source is on disk or at a URL recorded in the frontmatter.
        // Embedding it would double the vault and make the note unreadable.
        let out = renderer.render(
            reading(source: .pdf(file: URL(fileURLWithPath: "/a.pdf"), pages: 2, ocr: false)),
            keepTranscript: true)
        #expect(!out.contains("## Transcript"))
        #expect(!out.contains("should not appear"))
    }

    @Test("OCR is recorded only when it was used")
    func recordsOCROnlyWhenUsed() {
        // Worth knowing when reading the note back: OCR text has errors that
        // text-layer extraction does not.
        let scanned = renderer.render(
            reading(source: .pdf(file: URL(fileURLWithPath: "/a.pdf"), pages: 2, ocr: true)),
            keepTranscript: true)
        let clean = renderer.render(
            reading(source: .pdf(file: URL(fileURLWithPath: "/a.pdf"), pages: 2, ocr: false)),
            keepTranscript: true)
        #expect(scanned.contains("\nocr: true\n"))
        #expect(!clean.contains("ocr:"))
    }

    @Test("a web reading records its URL and no page count")
    func rendersWebFrontmatter() {
        let out = renderer.render(
            reading(source: .web(page: URL(string: "https://example.com/dp?a=1")!,
                                 siteTitle: "DP")),
            keepTranscript: true)
        #expect(out.contains("\nsource: \"https://example.com/dp?a=1\"\n"))
        #expect(!out.contains("pages:"))
    }
}
