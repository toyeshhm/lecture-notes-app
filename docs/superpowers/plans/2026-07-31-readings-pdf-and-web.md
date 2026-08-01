# Readings (PDF and web) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write up a PDF or a web page into the vault the same way a lecture is written up, without changing any existing behaviour.

**Architecture:** The pipeline is already source-agnostic after its first step. Two new extractors (`PDFReader`, `WebReader`) produce an `Extracted` value; `SessionModel.writeUp` is split so audio, PDF and web share one path from that point on. `LectureNote` gains a `source: NoteSource` field defaulting to `.lecture`, and `NoteRenderer` branches on it for three frontmatter lines and the transcript section.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`import Testing`, `@Test`, `#expect`), PDFKit and Vision (both system frameworks, no new package dependency).

**Spec:** `docs/superpowers/specs/2026-07-31-readings-pdf-and-web-design.md`

## Global Constraints

- **Nothing in the recording path changes.** `AudioCapture.swift`, `Transcriber.swift`, `VaultWriter.swift`, `RosterWriter.swift`, `ConfigImport.swift`, `Preflight.swift` and `DesignTokens.swift` are not edited by any task in this plan.
- **`NoteRenderer.render` output for a `.lecture` note must stay byte-identical.** Task 1 pins it; every later task must keep that test green.
- **`CourseDetector.detectSystem` for a lecture must stay byte-identical.** Task 1 pins it.
- **Notes with no `type:` frontmatter key are lectures**, never readings and never unknown.
- **`LectureNote.source` defaults to `.lecture`** so existing construction sites are untouched.
- **No new package dependencies.** `Packages/LectureKit/Package.swift` is not edited. PDFKit and Vision are system frameworks available under `platforms: [.macOS(.v14)]`.
- **Swift Testing, not XCTest.** Match the existing suites: `import Testing`, `@Test("sentence describing behaviour")`, `#expect(...)`.
- **Verification command is `make check`** (runs `lint`, `app`, `test`). Individual package tests: `swift test --package-path Packages/LectureKit --filter <name>`.
- **Two-space indent, comments explain *why*.** Match surrounding style.

---

### Task 1: Regression backstop

Pins today's behaviour before anything is touched. No production code changes — this task adds tests only, and every later task must keep them green.

**Files:**
- Create: `Packages/LectureKit/Tests/LectureKitTests/RegressionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks. It is a gate, not a dependency.

- [ ] **Step 1: Write the golden tests**

Create `Packages/LectureKit/Tests/LectureKitTests/RegressionTests.swift`:

```swift
import Foundation
import Testing

@testable import LectureKit

/// What a lecture note looked like before readings existed.
///
/// Every note in the vault is rewritten through `NoteRenderer.render`, and the
/// detection prompt was tuned against real transcripts. Both are the kind of
/// thing that drifts by a character during unrelated work and produces no
/// visible symptom until a term of notes has been rewritten wrongly. These two
/// tests exist to make that drift loud.
@Suite("Regression: pre-readings behaviour")
struct RegressionTests {

    @Test("a lecture note renders byte-for-byte as it did before readings")
    func lectureRenderIsUnchanged() {
        let note = LectureNote(
            date: "2026-09-02",
            course: "CS 314H",
            topic: "Binary search trees",
            sections: ["- live"],
            finalNotes: "## Summary\n\nTrees.",
            transcript: "raw words",
            duration: 3_180,
            detectedCourse: "CS 314H",
            detectionConfidence: .high)

        let expected = """
            ---
            title: "Binary search trees"
            course: CS 314H
            date: 2026-09-02
            type: lecture
            duration_min: 53
            status: complete
            detected_course: CS 314H
            detection_confidence: high
            tags:
              - lecture
              - cs-314h
            ---
            # Binary search trees

            **CS 314H** · 2026-09-02

            ## Summary

            Trees.

            ---

            ## Transcript

            raw words

            """

        #expect(NoteRenderer().render(note, keepTranscript: true) == expected)
    }

    @Test("the lecture detection prompt is unchanged")
    func detectionPromptIsUnchanged() {
        // Detection quality was tuned against real transcripts. A reworded
        // prompt is a silent quality regression, so the literal is pinned here
        // rather than trusted to review.
        let expected = """
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

        #expect(CourseDetector.detectSystem == expected)
    }
}
```

- [ ] **Step 2: Run them and confirm they pass against unmodified code**

```bash
swift test --package-path Packages/LectureKit --filter RegressionTests
```

Expected: **PASS**, both tests. These describe code that already exists, so a failure here means the literal above is wrong, not that the code is — fix the literal to match what the code actually produces, and do not touch `NoteRenderer.swift` or `CourseDetector.swift`.

- [ ] **Step 3: Commit**

```bash
git add Packages/LectureKit/Tests/LectureKitTests/RegressionTests.swift
git commit -m "Pin the lecture note and detection prompt before adding readings"
```

---

### Task 2: `NoteSource`, `Extracted`, `SourceFailure`

The data model. No behaviour changes yet — Task 1's golden test passing unchanged is the proof.

**Files:**
- Modify: `Packages/LectureKit/Sources/LectureKit/Models.swift` (add types; add `source` to `LectureNote` at lines 302-342; add nothing to `LectureKitError`)
- Test: `Packages/LectureKit/Tests/LectureKitTests/ModelsTests.swift`

**Interfaces:**
- Produces:
  - `NoteSource.lecture`, `.pdf(file: URL, pages: Int, ocr: Bool)`, `.web(page: URL, siteTitle: String?)`
  - `NoteSource.isReading: Bool`
  - `Extracted(text: String, title: String?, source: NoteSource)`
  - `SourceFailure` with `.message: String`
  - `LectureNote.source: NoteSource` (defaults to `.lecture`)

- [ ] **Step 1: Write the failing test**

Append to `Packages/LectureKit/Tests/LectureKitTests/ModelsTests.swift`:

```swift
@Suite("Note sources")
struct NoteSourceTests {

    @Test("a note is a lecture unless it says otherwise")
    func defaultsToLecture() {
        // Every existing construction site omits `source`, and each of them is a
        // recorded lecture. The default is what keeps those sites correct.
        let note = LectureNote(date: "2026-09-02", course: "CS 314H")
        #expect(note.source == .lecture)
        #expect(note.source.isReading == false)
    }

    @Test("PDFs and pages are readings")
    func readingsAreReadings() {
        let pdf = NoteSource.pdf(file: URL(fileURLWithPath: "/tmp/a.pdf"), pages: 24, ocr: false)
        let web = NoteSource.web(page: URL(string: "https://example.com/x")!, siteTitle: "X")
        #expect(pdf.isReading)
        #expect(web.isReading)
    }

    @Test("every failure carries a sentence a person can act on")
    func failuresReadAsSentences() {
        // The copy is specified in the design doc; pinning it here keeps the two
        // in step, and keeps error text out of call sites.
        #expect(SourceFailure.encrypted.message == "That PDF is password-protected.")
        #expect(SourceFailure.badScheme.message
            == "Only http and https links can be written up.")
        #expect(SourceFailure.tooLarge.message == "That page is too large to read.")
        #expect(SourceFailure.noText(name: "handout.pdf").message
            == "Couldn’t find any text in handout.pdf — even after reading it as a scan.")
        #expect(SourceFailure.httpStatus(code: 404, host: "example.com").message
            == "example.com returned 404.")
        #expect(SourceFailure.unreachable(host: "example.com").message
            == "Couldn’t reach example.com.")
        #expect(SourceFailure.emptyPage(host: "example.com").message
            == "Nothing to read at example.com — the page builds itself in JavaScript.")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
swift test --package-path Packages/LectureKit --filter NoteSourceTests
```

Expected: FAIL — `cannot find 'NoteSource' in scope`.

- [ ] **Step 3: Add the types**

In `Packages/LectureKit/Sources/LectureKit/Models.swift`, add above the `LectureNote` declaration:

```swift
// MARK: - Where a note's text came from

/// What was read to produce a note.
///
/// A reading has no audio, no duration and no speech density, so the three
/// things a lecture row draws from those are absent rather than zero. Keeping
/// this on `LectureNote` rather than forking a second note type is deliberate:
/// `VaultWriter`, `NoteRenderer` and the per-target relocation tracking are
/// subtle and correct, and a parallel type would fork all three.
public enum NoteSource: Sendable, Equatable {
    /// Recorded in the app, or audio picked up from the inbox.
    case lecture
    /// `ocr` is true when the PDF had no text layer and Vision read it instead.
    case pdf(file: URL, pages: Int, ocr: Bool)
    case web(page: URL, siteTitle: String?)

    /// Anything that was read rather than heard.
    public var isReading: Bool {
        self != .lecture
    }
}

/// Text pulled out of a PDF or a web page, ready to be written up.
///
/// The two readers return the same shape on purpose: from here on the pipeline
/// cannot tell them apart, which is what keeps the audio path and the reading
/// path one path.
public struct Extracted: Sendable, Equatable {
    public var text: String
    /// The document's own title, when it has one. Used only as a fallback topic
    /// — the detector's topic wins, because it describes the material rather
    /// than whatever the site put in its `<title>`.
    public var title: String?
    public var source: NoteSource

    public init(text: String, title: String?, source: NoteSource) {
        self.text = text
        self.title = title
        self.source = source
    }
}

/// Why a PDF or a page could not be read.
///
/// Distinct cases rather than one string, so tests can assert the condition;
/// `message` keeps the wording in one place instead of scattered across throw
/// sites. Every one of these is shown to the user verbatim.
public enum SourceFailure: Error, Sendable, Equatable {
    case encrypted
    case noText(name: String)
    case badScheme
    case tooLarge
    case httpStatus(code: Int, host: String)
    case unreachable(host: String)
    case emptyPage(host: String)

    public var message: String {
        switch self {
        case .encrypted:
            "That PDF is password-protected."
        case .noText(let name):
            "Couldn’t find any text in \(name) — even after reading it as a scan."
        case .badScheme:
            "Only http and https links can be written up."
        case .tooLarge:
            "That page is too large to read."
        case .httpStatus(let code, let host):
            "\(host) returned \(code)."
        case .unreachable(let host):
            "Couldn’t reach \(host)."
        case .emptyPage(let host):
            // Its own message rather than falling into "nothing to read": the
            // cause is specific, and without saying so it is indistinguishable
            // from a broken feature.
            "Nothing to read at \(host) — the page builds itself in JavaScript."
        }
    }
}
```

Then in `LectureNote` (line 302), add the stored property after `detectionConfidence`:

```swift
    /// What was read or heard to produce this note. Defaults to `.lecture`, so
    /// every site that predates readings keeps producing the note it always did.
    public var source: NoteSource
```

and in its `init`, add the parameter after `detectionConfidence` and before `writtenPaths`:

```swift
        source: NoteSource = .lecture,
```

with the matching assignment `self.source = source` before `self.writtenPaths = writtenPaths`.

- [ ] **Step 4: Run tests and confirm the backstop still passes**

```bash
swift test --package-path Packages/LectureKit
```

Expected: PASS, including `RegressionTests` from Task 1 — the golden note is unchanged because `render` does not read `source` yet.

- [ ] **Step 5: Commit**

```bash
git add Packages/LectureKit/Sources/LectureKit/Models.swift \
        Packages/LectureKit/Tests/LectureKitTests/ModelsTests.swift
git commit -m "Give a note a source: lecture, PDF or web page"
```

---

### Task 3: Render a reading

**Files:**
- Modify: `Packages/LectureKit/Sources/LectureKit/NoteRenderer.swift:167-219`
- Test: `Packages/LectureKit/Tests/LectureKitTests/NoteRendererTests.swift`

**Interfaces:**
- Consumes: `NoteSource`, `LectureNote.source` (Task 2).
- Produces: reading frontmatter — `type: reading`, quoted `source:`, `pages:`, `ocr:`; no `duration_min`; no `## Transcript` section.

- [ ] **Step 1: Write the failing test**

Append to `Packages/LectureKit/Tests/LectureKitTests/NoteRendererTests.swift`:

```swift
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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
swift test --package-path Packages/LectureKit --filter ReadingRenderTests
```

Expected: FAIL — the renderer still writes `type: lecture`, a `duration_min` key and a transcript section.

- [ ] **Step 3: Implement the branch**

In `NoteRenderer.render`, replace the opening `var front = [...]` block (lines 172-180) with:

```swift
        var front = [
            "---",
            "title: \"\(note.topic)\"",
            "course: \(note.course)",
            "date: \(note.date)",
        ]
        switch note.source {
        case .lecture:
            front.append("type: lecture")
            front.append("duration_min: \(Int(note.duration / 60))")
        case .pdf(let file, let pages, let ocr):
            front.append("type: reading")
            // Quoted: a vault path legitimately contains a colon or a `#`, both
            // of which end a bare YAML scalar early and silently truncate it.
            front.append("source: \"\(yamlSafe(file.path(percentEncoded: false)))\"")
            front.append("pages: \(pages)")
            // Only when true. OCR text carries recognition errors that a text
            // layer does not, and a reader of the note deserves to know which
            // they are looking at — but `ocr: false` on every clean PDF is noise.
            if ocr { front.append("ocr: true") }
        case .web(let page, _):
            front.append("type: reading")
            front.append("source: \"\(yamlSafe(page.absoluteString))\"")
        }
        front.append("status: \(note.finalNotes != nil ? "complete" : "recording")")
```

Change the `tags:` block (lines 190-196) so the first tag follows the source:

```swift
        front += [
            "tags:",
            "  - \(note.source.isReading ? "reading" : "lecture")",
            "  - \(note.course.lowercased().replacingOccurrences(of: " ", with: "-"))",
            "---",
            "",
        ]
```

Change the transcript condition (line 215) so a reading never writes one:

```swift
        if keepTranscript, !note.transcript.isEmpty, !note.source.isReading {
```

And add this helper at file scope, next to `fixCallouts`:

```swift
/// Make a value safe inside a double-quoted YAML scalar.
///
/// Only two characters can end one early. A vault path or a URL is not attacker
/// input here, but a filename with a quote in it is ordinary and would produce
/// frontmatter Obsidian cannot parse — which hides the whole note's metadata.
func yamlSafe(_ raw: String) -> String {
    raw
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}
```

- [ ] **Step 4: Run the whole suite**

```bash
swift test --package-path Packages/LectureKit
```

Expected: PASS. `RegressionTests.lectureRenderIsUnchanged` must still pass — the `.lecture` branch emits `type:` then `duration_min:` then `status:` in the same order as before, and the `lecture` tag is unchanged.

- [ ] **Step 5: Commit**

```bash
git add Packages/LectureKit/Sources/LectureKit/NoteRenderer.swift \
        Packages/LectureKit/Tests/LectureKitTests/NoteRendererTests.swift
git commit -m "Render a reading: no duration, no transcript, a source instead"
```

---

### Task 4: `PDFReader`

**Files:**
- Create: `Packages/LectureKit/Sources/LectureKit/PDFReader.swift`
- Test: `Packages/LectureKit/Tests/LectureKitTests/PDFReaderTests.swift`

**Interfaces:**
- Consumes: `Extracted`, `NoteSource`, `SourceFailure` (Task 2).
- Produces: `PDFReader.read(_ url: URL) throws -> Extracted`, `PDFReader.minimumCharactersPerPage: Int`.

- [ ] **Step 1: Write the failing test**

Create `Packages/LectureKit/Tests/LectureKitTests/PDFReaderTests.swift`:

```swift
import CoreGraphics
import Foundation
import Testing

@testable import LectureKit

/// Builds real PDFs on disk. No fixtures checked in: a generated file is
/// readable in the test that uses it, and CoreGraphics is already here.
private func makePDF(pages: [String], at url: URL) throws {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
        throw SourceFailure.noText(name: "could not create context")
    }
    for text in pages {
        context.beginPDFPage(nil)
        if !text.isEmpty {
            let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            let attributed = NSAttributedString(
                string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 40, y: 700)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
    }
    context.closePDF()
}

private func sandbox() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "pdf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("Reading a PDF")
struct PDFReaderTests {

    @Test("text is taken straight from the text layer")
    func readsTextLayer() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "notes.pdf")
        let body = String(repeating: "Dynamic programming solves subproblems once. ", count: 8)
        try makePDF(pages: [body], at: url)

        let out = try PDFReader.read(url)

        #expect(out.text.contains("Dynamic programming"))
        #expect(out.source == .pdf(file: url, pages: 1, ocr: false))
    }

    @Test("the page count is the document's, not the number of pages with text")
    func countsEveryPage() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "notes.pdf")
        let dense = String(repeating: "Subproblems and memoisation together. ", count: 8)
        try makePDF(pages: [dense, dense, dense], at: url)

        let out = try PDFReader.read(url)

        guard case .pdf(_, let pages, _) = out.source else {
            Issue.record("expected a pdf source")
            return
        }
        #expect(pages == 3)
    }

    @Test("a PDF with no text at all is reported, not written up")
    func emptyPDFFails() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "blank.pdf")
        // Three blank pages: no text layer, and nothing for OCR to find either.
        try makePDF(pages: ["", "", ""], at: url)

        #expect(throws: SourceFailure.noText(name: "blank.pdf")) {
            try PDFReader.read(url)
        }
    }

    @Test("a file that is not a PDF is reported, not guessed at")
    func nonPDFFails() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "notes.pdf")
        try Data("this is not a pdf".utf8).write(to: url)

        #expect(throws: SourceFailure.noText(name: "notes.pdf")) {
            try PDFReader.read(url)
        }
    }

    @Test("the scan threshold is measured per page, not per document")
    func thresholdIsPerPage() {
        // A 40-page scan with one typed cover page has plenty of characters in
        // total and nothing on 39 of its pages. Dividing by the page count is
        // what stops that reading as a text PDF.
        #expect(PDFReader.minimumCharactersPerPage == 100)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
swift test --package-path Packages/LectureKit --filter PDFReaderTests
```

Expected: FAIL — `cannot find 'PDFReader' in scope`.

- [ ] **Step 3: Implement**

Create `Packages/LectureKit/Sources/LectureKit/PDFReader.swift`:

```swift
import CoreGraphics
import Foundation
import PDFKit
import Vision

/// Text out of a PDF, by whichever of the two ways works.
///
/// Most PDFs carry a text layer and `PDFDocument.string` is the whole job. A
/// scan — a photographed handout, a scanned chapter — carries none, and that is
/// not an error the user can do anything about, so Vision reads it instead.
/// Both frameworks ship with macOS: nothing is added to `Package.swift`, and
/// recognition runs on device, so the app's claim that nothing leaves the Mac
/// survives unqualified.
public enum PDFReader {

    /// Below this many characters per page, the document is treated as a scan.
    ///
    /// Per page, never per document: a 40-page scan with one typed cover page
    /// clears any whole-document threshold while being 39/40 unreadable.
    public static let minimumCharactersPerPage = 100

    public static func read(_ url: URL) throws -> Extracted {
        let name = url.lastPathComponent
        guard let document = PDFDocument(url: url) else {
            throw SourceFailure.noText(name: name)
        }
        // Checked before any reading: an encrypted document returns empty text
        // rather than failing, which would otherwise send it down the OCR path
        // to spend a minute rasterising pages it cannot decrypt.
        guard !document.isEncrypted else { throw SourceFailure.encrypted }

        let pages = document.pageCount
        guard pages > 0 else { throw SourceFailure.noText(name: name) }

        let layer = (document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if layer.count >= minimumCharactersPerPage * pages {
            return Extracted(
                text: layer,
                title: title(of: document),
                source: .pdf(file: url, pages: pages, ocr: false))
        }

        let recognised = ocr(document).trimmingCharacters(in: .whitespacesAndNewlines)
        // The longer of the two. A mostly-blank PDF with a real cover page beats
        // whatever OCR made of the blank pages, and vice versa for a scan.
        let best = recognised.count > layer.count ? recognised : layer
        guard !best.isEmpty else { throw SourceFailure.noText(name: name) }

        return Extracted(
            text: best,
            title: title(of: document),
            source: .pdf(file: url, pages: pages, ocr: best == recognised))
    }

    /// The document's own title, when it has a usable one.
    ///
    /// Plenty of PDFs carry a title of "Microsoft Word - draft3.docx", which is
    /// worse than nothing as a note title — but it is only ever a fallback for
    /// the detector's topic, so it is not worth filtering.
    private static func title(of document: PDFDocument) -> String? {
        guard let raw = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Rasterise each page and recognise the text on it.
    ///
    /// 2× scale: Vision's accuracy falls off sharply below roughly 150 dpi, and
    /// a 612×792 page at 1× is 72. Failures are per page and silent — one page
    /// that will not render is not a reason to lose the other thirty-nine.
    private static func ocr(_ document: PDFDocument) -> String {
        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let image = render(page, scale: 2)
            else { continue }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // On by default, and wrong here: a lecture handout is full of terms
            // no language model expects, and correction rewrites them into
            // ordinary words that read as plausible and are not what the page says.
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let results = request.results
            else { continue }

            let lines = results.compactMap { $0.topCandidates(1).first?.string }
            if !lines.isEmpty { pages.append(lines.joined(separator: "\n")) }
        }
        // Blank line between pages: it is the only structural signal OCR
        // recovers, and it keeps a heading from running into the paragraph that
        // ended the page before.
        return pages.joined(separator: "\n\n")
    }

    private static func render(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }

        // White, because a PDF page's own background is transparent and Vision
        // reads black-on-black as nothing at all.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --package-path Packages/LectureKit --filter PDFReaderTests
```

Expected: PASS, all five.

- [ ] **Step 5: Commit**

```bash
git add Packages/LectureKit/Sources/LectureKit/PDFReader.swift \
        Packages/LectureKit/Tests/LectureKitTests/PDFReaderTests.swift
git commit -m "Read a PDF, falling back to on-device OCR for scans"
```

---

### Task 5: `WebReader`

**Files:**
- Create: `Packages/LectureKit/Sources/LectureKit/WebReader.swift`
- Test: `Packages/LectureKit/Tests/LectureKitTests/WebReaderTests.swift`

**Interfaces:**
- Consumes: `Extracted`, `NoteSource`, `SourceFailure` (Task 2); `PDFReader.read` (Task 4).
- Produces: `WebReader.read(_ raw: String) async throws -> Extracted`, `WebReader.validate(_ raw: String) throws -> URL`, `WebReader.plainText(fromHTML:) -> String`, `WebReader.title(inHTML:) -> String?`, `WebReader.maximumBytes: Int`.

- [ ] **Step 1: Write the failing test**

Create `Packages/LectureKit/Tests/LectureKitTests/WebReaderTests.swift`:

```swift
import Foundation
import Testing

@testable import LectureKit

@Suite("Validating a link")
struct WebReaderValidationTests {

    @Test("http and https are accepted")
    func acceptsWebSchemes() throws {
        #expect(try WebReader.validate("https://example.com/a").scheme == "https")
        #expect(try WebReader.validate("http://example.com/a").scheme == "http")
    }

    @Test("a bare host is treated as https")
    func addsHTTPS() throws {
        // What a person pastes out of a browser bar. Assuming https rather than
        // http, because guessing the insecure one silently downgrades them.
        let url = try WebReader.validate("example.com/notes")
        #expect(url.absoluteString == "https://example.com/notes")
    }

    @Test("anything that is not the web is refused")
    func rejectsOtherSchemes() {
        // file:// would turn this field into a local file reader, which is a
        // different feature with different consequences. Refused before any
        // request is made, not after.
        for raw in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,<b>x"] {
            #expect(throws: SourceFailure.badScheme) { try WebReader.validate(raw) }
        }
    }

    @Test("empty input is refused")
    func rejectsEmpty() {
        #expect(throws: SourceFailure.badScheme) { try WebReader.validate("   ") }
    }
}

@Suite("Turning HTML into text")
struct WebReaderStripTests {

    @Test("script and style contents never reach the text")
    func dropsScriptAndStyle() {
        let html = """
            <html><head><style>body { color: red }</style></head>
            <body><script>var x = 1;</script><p>Real content here.</p></body></html>
            """
        let text = WebReader.plainText(fromHTML: html)
        #expect(text.contains("Real content here."))
        #expect(!text.contains("color: red"))
        #expect(!text.contains("var x"))
    }

    @Test("navigation furniture is dropped")
    func dropsChrome() {
        let html = """
            <body><nav>Home About</nav><header>Site name</header>
            <p>The actual lecture material.</p>
            <footer>Copyright 2026</footer></body>
            """
        let text = WebReader.plainText(fromHTML: html)
        #expect(text.contains("The actual lecture material."))
        #expect(!text.contains("Home About"))
        #expect(!text.contains("Site name"))
        #expect(!text.contains("Copyright 2026"))
    }

    @Test("entities are unescaped")
    func unescapesEntities() {
        let text = WebReader.plainText(fromHTML: "<p>a &lt; b &amp;&amp; c &gt; d&nbsp;e &#39;f&#39;</p>")
        #expect(text == "a < b && c > d e 'f'")
    }

    @Test("whitespace collapses but paragraphs stay apart")
    func collapsesWhitespace() {
        // Block boundaries are the only structure worth keeping: without them
        // a heading runs into the sentence after it and the model reads them
        // as one clause.
        let text = WebReader.plainText(fromHTML: "<h2>Heading</h2>\n\n   <p>Body    text</p>")
        #expect(text == "Heading\n\nBody text")
    }

    @Test("a page that is all chrome strips to nothing")
    func stripsToNothing() {
        // The JavaScript-rendered case, which must be detectable so it gets its
        // own message rather than producing a note about a nav bar.
        #expect(WebReader.plainText(fromHTML: "<body><div id=\"root\"></div></body>").isEmpty)
    }

    @Test("the title comes off the title tag")
    func readsTitle() {
        #expect(WebReader.title(inHTML: "<head><title> Dynamic  Programming </title></head>")
            == "Dynamic Programming")
        #expect(WebReader.title(inHTML: "<head></head>") == nil)
    }

    @Test("a page body is capped")
    func capsBodySize() {
        // A large or slow response must fail rather than hang the app.
        #expect(WebReader.maximumBytes == 10 * 1024 * 1024)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
swift test --package-path Packages/LectureKit --filter WebReader
```

Expected: FAIL — `cannot find 'WebReader' in scope`.

- [ ] **Step 3: Implement**

Create `Packages/LectureKit/Sources/LectureKit/WebReader.swift`:

```swift
import Foundation

/// Text out of a web page.
///
/// A deliberate tag-strip rather than a readability heuristic: the model is
/// summarising, and it ignores a breadcrumb or a cookie line without being
/// asked. Removing them properly is a large amount of code to delete text that
/// costs nothing.
///
/// Pages that build themselves in JavaScript return nothing here, and that is
/// the accepted limit — see the design doc. An offscreen `WKWebView` would
/// handle them at the cost of a hidden web view in a menu bar app and a
/// "settled" heuristic that is always a guess.
public enum WebReader {

    /// Bodies larger than this are refused rather than read.
    public static let maximumBytes = 10 * 1024 * 1024

    private static let timeout: TimeInterval = 30

    // MARK: - The boundary

    /// Parse and vet a URL the user typed.
    ///
    /// This is the trust boundary for the whole feature: the string comes
    /// straight off a text field. Checked before any request is made.
    public static func validate(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SourceFailure.badScheme }

        // A pasted address usually has no scheme. Assuming https rather than
        // http: guessing the insecure one silently downgrades the request.
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host()?.isEmpty == false
        else { throw SourceFailure.badScheme }
        return url
    }

    // MARK: - Fetch

    public static func read(_ raw: String, session: URLSession = .shared) async throws -> Extracted {
        let url = try validate(raw)
        let host = url.host() ?? url.absoluteString

        var request = URLRequest(url: url, timeoutInterval: timeout)
        // Some sites serve a stub to an unrecognised agent, which strips to
        // nothing and reads to the user as the JavaScript case.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) LectureNotes",
            forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SourceFailure.unreachable(host: host)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceFailure.httpStatus(code: http.statusCode, host: host)
        }
        guard data.count <= maximumBytes else { throw SourceFailure.tooLarge }

        // Linked lecture slides are usually a PDF behind an https:// URL, and
        // stripping tags off a binary produces plausible-looking garbage rather
        // than an error. Hand it to the reader that knows the format.
        let mime = (response.mimeType ?? "").lowercased()
        if mime.contains("application/pdf") || url.pathExtension.lowercased() == "pdf" {
            return try readDownloadedPDF(data, from: url)
        }

        let html = decode(data, response: response)
        let text = plainText(fromHTML: html)
        guard !text.isEmpty else { throw SourceFailure.emptyPage(host: host) }

        return Extracted(
            text: text,
            title: title(inHTML: html),
            source: .web(page: url, siteTitle: title(inHTML: html)))
    }

    /// Run a downloaded PDF through `PDFReader`, keeping the web URL as the
    /// note's source — that is the address the user can go back to, not a
    /// temporary file that is about to be deleted.
    private static func readDownloadedPDF(_ data: Data, from url: URL) throws -> Extracted {
        let temp = FileManager.default.temporaryDirectory
            .appending(path: "web-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try data.write(to: temp)
        } catch {
            throw SourceFailure.unreachable(host: url.host() ?? url.absoluteString)
        }
        let pdf = try PDFReader.read(temp)
        return Extracted(
            text: pdf.text,
            title: pdf.title,
            source: .web(page: url, siteTitle: pdf.title))
    }

    /// Decode using the charset the server declared, falling back to UTF-8 and
    /// then to Latin-1, which cannot fail. A page that decodes to nothing is
    /// indistinguishable from a JavaScript page, and the wrong message is worse
    /// than a slightly mangled accent.
    private static func decode(_ data: Data, response: URLResponse) -> String {
        if let name = response.textEncodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(
                    rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        return String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: - Stripping

    /// Elements whose *contents* are furniture, not material.
    private static let discarded = ["script", "style", "nav", "header", "footer", "noscript"]

    /// Elements after which a line break is real structure rather than layout.
    private static let blocks: Set<String> = [
        "p", "div", "br", "li", "tr", "section", "article", "blockquote", "pre",
        "h1", "h2", "h3", "h4", "h5", "h6",
    ]

    public static func plainText(fromHTML html: String) -> String {
        var working = html
        for tag in discarded {
            // Non-greedy, case-insensitive, `.` matching newlines: these
            // elements routinely span hundreds of lines, and a greedy match
            // would swallow the page from the first <script> to the last.
            working = working.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>.*?</\(tag)\\s*>",
                with: "\n",
                options: [.regularExpression, .caseInsensitive])
            // An unclosed one — a <script src=…> with no body is fine, but a
            // truncated page can leave a real one open. Drop to end of input
            // rather than emitting its source as prose.
            working = working.replacingOccurrences(
                of: "<\(tag)\\b[^>]*>.*",
                with: "\n",
                options: [.regularExpression, .caseInsensitive])
        }

        // Block elements become newlines before tags are stripped wholesale, so
        // a heading does not weld itself to the paragraph beneath it.
        for tag in blocks {
            working = working.replacingOccurrences(
                of: "</?\(tag)\\b[^>]*>",
                with: "\n\n",
                options: [.regularExpression, .caseInsensitive])
        }

        working = working.replacingOccurrences(
            of: "<!--.*?-->", with: " ", options: [.regularExpression])
        working = working.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: [.regularExpression])

        return tidy(unescape(working))
    }

    public static func title(inHTML html: String) -> String? {
        guard let range = html.range(
            of: "<title\\b[^>]*>(.*?)</title\\s*>",
            options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let inner = html[range]
            .replacingOccurrences(of: "<[^>]+>", with: "", options: [.regularExpression])
        let cleaned = tidy(unescape(inner))
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The five named entities that carry meaning in prose, plus numeric refs.
    ///
    /// Not the full HTML5 table: everything outside this set renders as an
    /// accented letter or a symbol, and a stray `&eacute;` in text the model is
    /// summarising costs nothing. `&amp;` is unescaped **last**, or `&amp;lt;`
    /// — the escaped form of the literal text "&lt;" — wrongly becomes `<`.
    private static func unescape(_ text: String) -> String {
        var out = text
        for (entity, replacement) in [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
        ] {
            out = out.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        out = numericEntitiesReplaced(in: out)
        return out.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    }

    /// Replace `&#39;` and `&#x27;` with the character they name.
    ///
    /// Plain regex substitution cannot do this — the replacement depends on the
    /// matched digits — so the matches are walked in **reverse**, which keeps
    /// every earlier range valid as the string shortens under them.
    private static func numericEntitiesReplaced(in text: String) -> String {
        var out = text
        let pattern = /&#(x?)([0-9A-Fa-f]+);/
        for match in out.matches(of: pattern).reversed() {
            let radix = match.1.isEmpty ? 10 : 16
            guard let value = UInt32(String(match.2), radix: radix),
                  let scalar = Unicode.Scalar(value)
            else { continue }
            out.replaceSubrange(match.range, with: String(Character(scalar)))
        }
        return out
    }

    /// Collapse runs of spaces within a line and runs of blank lines between
    /// them, then trim. Paragraph breaks survive; layout whitespace does not.
    private static func tidy(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .reduce(into: [String]()) { lines, line in
                if line.isEmpty && lines.last?.isEmpty == true { return }
                lines.append(line)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Run tests**

```bash
swift test --package-path Packages/LectureKit --filter WebReader
```

Expected: PASS, all eleven across both suites. None of them makes a network request — `read` is exercised end to end in Task 9's manual check.

- [ ] **Step 5: Commit**

```bash
git add Packages/LectureKit/Sources/LectureKit/WebReader.swift \
        Packages/LectureKit/Tests/LectureKitTests/WebReaderTests.swift
git commit -m "Read a web page: fetch, strip, and refuse anything that is not http"
```

---

### Task 6: Prompts and detection for readings

**Files:**
- Modify: `Packages/LectureKit/Sources/LectureKit/NoteRenderer.swift:11-98` (add `Prompts.reading`, `NoteWriterPrompts.readingNotes`)
- Modify: `Packages/LectureKit/Sources/LectureKit/CourseDetector.swift:16-31,104-133`
- Modify: `App/Sources/SessionModel.swift:306,472` (pass `material:` at both existing call sites)
- Test: `Packages/LectureKit/Tests/LectureKitTests/CourseDetectorTests.swift`

**Interfaces:**
- Produces:
  - `Prompts.reading: String`
  - `NoteWriterPrompts.readingNotes(text: String, course: String, source: String) -> String`
  - `CourseDetector.Material` (`.lecture`, `.reading`)
  - `CourseDetector.detectSystem(for: Material) -> String`
  - `CourseDetector.detect(text:candidates:model:material:) async -> CourseGuess?` — the `transcript:` label is renamed to `text:` and `material:` has no default.

- [ ] **Step 1: Write the failing test**

Append to `Packages/LectureKit/Tests/LectureKitTests/CourseDetectorTests.swift`:

```swift
@Suite("Prompts for readings")
struct ReadingPromptTests {

    @Test("the lecture detection prompt is what it always was")
    func lecturePromptUnchanged() {
        // `detectSystem` is now a function of the material; the lecture case
        // must produce the exact string the old constant did.
        #expect(CourseDetector.detectSystem(for: .lecture) == CourseDetector.detectSystem)
    }

    @Test("the reading prompt does not describe its input as speech")
    func readingPromptIsNotAboutSpeech() {
        let prompt = CourseDetector.detectSystem(for: .reading)
        #expect(!prompt.contains("ASR"))
        #expect(!prompt.contains("lecturer"))
        #expect(!prompt.contains("transcript"))
        #expect(prompt.contains("JSON"))
    }

    @Test("the reading notes prompt drops the ASR repair rules")
    func readingNotesPromptDropsASRRules() {
        // "Silently fix obvious mishearings", applied to a PDF, instructs the
        // model to correct text that is already correct.
        #expect(!Prompts.reading.contains("mishearing"))
        #expect(!Prompts.reading.contains("ASR"))
    }

    @Test("the reading notes prompt has no exam section")
    func readingNotesPromptHasNoExamSection() {
        // A lecturer flags things out loud. A PDF does not, and keeping the
        // heading invites the model to invent emphasis that is not in the source.
        #expect(!Prompts.reading.contains("Likely exam material"))
        #expect(Prompts.reading.contains("## Key terms"))
        #expect(Prompts.reading.contains("## Summary"))
    }

    @Test("the reading user prompt names where the material came from")
    func readingUserPromptCarriesSource() {
        let prompt = NoteWriterPrompts.readingNotes(
            text: "Subproblems.", course: "CS 314H", source: "https://example.com/dp")
        #expect(prompt.contains("CS 314H"))
        #expect(prompt.contains("https://example.com/dp"))
        #expect(prompt.contains("Subproblems."))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
swift test --package-path Packages/LectureKit --filter ReadingPromptTests
```

Expected: FAIL — `detectSystem(for:)` and `Prompts.reading` do not exist.

- [ ] **Step 3: Implement**

In `CourseDetector.swift`, keep the existing `static let detectSystem` literal exactly as it is, and add beneath it:

```swift
    /// What was read or heard. The detection prompt describes its input, and
    /// describing a PDF as an ASR transcript tells the model to correct text
    /// that is already correct.
    public enum Material: Sendable, Equatable {
        case lecture
        case reading
    }

    /// The detection prompt for one kind of material.
    ///
    /// The `.lecture` case returns `detectSystem` unchanged rather than
    /// rebuilding it: that literal was tuned against real transcripts, and
    /// `RegressionTests` pins it.
    static func detectSystem(for material: Material) -> String {
        switch material {
        case .lecture:
            detectSystem
        case .reading:
            """
            You identify which university course a piece of course material belongs to.

            Reply with ONLY a JSON object, no prose and no code fence:
            {"course": "<course code>", "confidence": "high"|"low", "topic": "<3-6 word topic>"}

            Rules:
            - Prefer a course from the provided list. Use its code EXACTLY as given.
            - Only invent a new course code if the material clearly fits none of them. Use the
              code the material states (e.g. "CS 314H"), or a short subject name if none appears.
            - confidence is "high" only if the subject matter clearly matches one course.
              Generic or administrative material is "low".
            - topic is what THIS material covers, for use as a filename: title case, no dates,
              no course code, no punctuation beyond spaces and hyphens.
            """
        }
    }
```

Change `detect` (line 105) to:

```swift
    /// Identify the course and topic for a piece of material. Nil if undecidable.
    public func detect(
        text: String,
        candidates: [String: String],
        model: String,
        material: Material
    ) async -> CourseGuess? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 20 else { return nil }  // too little material to judge anything
        let excerpt = words.prefix(1200).joined(separator: " ")
```

and inside it, replace the prompt line and the `system:` argument:

```swift
        let heading = material == .lecture ? "Lecture transcript" : "Course material"
        let prompt = "Known courses:\n\(listing)\n\n\(heading):\n\(excerpt)"
        // Detection is an optimisation, never a precondition for keeping notes:
        // any failure means _Unsorted, not a lost lecture.
        guard let raw = try? await claude.run(
            prompt: prompt, system: Self.detectSystem(for: material), model: model, timeout: 240
        ) else { return nil }
```

In `NoteRenderer.swift`, add to `enum Prompts` after `final`:

```swift
    /// The reading counterpart of ``final``.
    ///
    /// Same skeleton, two deliberate differences: no ASR-repair rules, because
    /// the text is not speech and telling the model to fix mishearings makes it
    /// rewrite correct text; and no "Likely exam material", because a lecturer
    /// flags things out loud and a document does not — keeping that heading is
    /// an invitation to invent emphasis.
    public static let reading = """
        You write the definitive study notes for one piece of university course material \
        — a PDF, a chapter, a set of slides, or a web page. These replace the student's own \
        notes, so be thorough and well organised.

        Output ONLY markdown -- no preamble, no closing remarks, and do NOT wrap it in a code \
        fence. Do NOT write a top-level `# ` heading; the note already has a title.

        Structure, in this order:

        `> [!abstract] In one line`
        A single sentence naming what this material is actually about. EVERY line of a
        callout must begin with `> `, including the body line under the header.

        `## Summary`
        2-4 sentences of what it covers and why it matters.

        `## Notes`
        The substance, under `### ` topic headings that follow the material's real structure. \
        Bullets, not prose paragraphs. Nest sub-bullets for detail. Bold each key term on first \
        use. Use numbered lists for anything sequential (algorithms, procedures, proofs). Use a \
        markdown table when comparing three or more things across the same dimensions. Put \
        worked examples in ```code fences``` when they are code, or in $$display maths$$ when \
        they are derivations.

        `## Key terms`
        A markdown table: `| Term | Definition |`. Only terms actually introduced here.

        `## Open questions`
        Threads the material leaves unresolved, or explicitly defers. Omit if none.

        Rules:
        - Write ALL maths as LaTeX: $O(\\log n)$, not "O of log n".
        - The text may have been extracted from a PDF or stripped from a web page, so it can \
        carry running heads, page numbers, or navigation fragments. Ignore them; never treat \
        them as content.
        - If the material is too short or too fragmentary to support a section, omit that \
        section rather than padding it. Never invent content that is not in the source.
        """
```

and to `enum NoteWriterPrompts`:

```swift
    public static func readingNotes(text: String, course: String, source: String) -> String {
        """
        Course: \(course)
        Source: \(source)

        Material:
        \(text)
        """
    }
```

Finally, update the two existing `detect` call sites in `App/Sources/SessionModel.swift` (lines 306 and 472) to use the new label and pass the material explicitly:

```swift
            .detect(text: transcript, candidates: candidates, model: settings.detectModel,
                    material: .lecture)
```

```swift
            .detect(text: note.transcript, candidates: candidates, model: settings.detectModel,
                    material: .lecture)
```

- [ ] **Step 4: Run the whole suite and build the app**

```bash
make check
```

Expected: PASS. `RegressionTests.detectionPromptIsUnchanged` must still pass — the `.lecture` literal was not edited.

- [ ] **Step 5: Commit**

```bash
git add Packages/LectureKit/Sources/LectureKit/NoteRenderer.swift \
        Packages/LectureKit/Sources/LectureKit/CourseDetector.swift \
        Packages/LectureKit/Tests/LectureKitTests/CourseDetectorTests.swift \
        App/Sources/SessionModel.swift
git commit -m "Prompt for readings without describing them as speech"
```

---

### Task 7: The inbox accepts PDFs

**Files:**
- Modify: `Packages/LectureKit/Sources/LectureKit/InboxWatcher.swift:16-99`
- Test: `Packages/LectureKit/Tests/LectureKitTests/InboxWatcherTests.swift`

**Interfaces:**
- Produces: `InboxWatcher.Kind` (`.audio`, `.pdf`), `InboxWatcher.Pending.kind`, `InboxWatcher.minimumAudioBytes`, `InboxWatcher.minimumPDFBytes`. `pending(in:settledFor:)` and `archive(_:in:)` keep their signatures.

- [ ] **Step 1: Write the failing test**

Append to `Packages/LectureKit/Tests/LectureKitTests/InboxWatcherTests.swift`:

```swift
@Test("a PDF in the inbox is picked up alongside recordings")
func picksUpPDFs() throws {
    let box = try InboxSandbox()
    try box.drop("chapter 4.pdf", bytes: 40_000)
    try box.drop("lecture.m4a")

    let pending = InboxWatcher.pending(in: box.dir)

    #expect(pending.count == 2)
    #expect(pending.first(where: { $0.url.pathExtension == "pdf" })?.kind == .pdf)
    #expect(pending.first(where: { $0.url.pathExtension == "m4a" })?.kind == .audio)
}

@Test("a small PDF is still a PDF")
func acceptsSmallPDFs() throws {
    // The 60 KB floor is twenty seconds of AAC at a voice bitrate. A legitimate
    // one-page PDF is a few kilobytes, and the audio floor would discard it in
    // silence.
    let box = try InboxSandbox()
    try box.drop("one page.pdf", bytes: 8_000)

    #expect(InboxWatcher.pending(in: box.dir).count == 1)
}

@Test("an empty PDF is not")
func rejectsEmptyPDFs() throws {
    let box = try InboxSandbox()
    try box.drop("placeholder.pdf", bytes: 100)

    #expect(InboxWatcher.pending(in: box.dir).isEmpty)
}

@Test("a small audio file is still discarded")
func stillRejectsShortAudio() throws {
    // The audio floor is unchanged. This is the regression guard on splitting it.
    let box = try InboxSandbox()
    try box.drop("misfire.m4a", bytes: 8_000)

    #expect(InboxWatcher.pending(in: box.dir).isEmpty)
}

@Test("a PDF still being synced is left alone")
func waitsForPDFsToSettle() throws {
    let box = try InboxSandbox()
    try box.drop("arriving.pdf", bytes: 40_000, ageSeconds: 2)

    #expect(InboxWatcher.pending(in: box.dir).isEmpty)
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
swift test --package-path Packages/LectureKit --filter InboxWatcher
```

Expected: FAIL — `Pending` has no `kind`, and PDFs are not in the extension set.

- [ ] **Step 3: Implement**

In `InboxWatcher.swift`, after the `audioExtensions` declaration add:

```swift
    /// What kind of thing is waiting. The two are processed differently — one is
    /// transcribed, the other read — and everything after that is shared.
    public enum Kind: String, Sendable, Equatable {
        case audio
        case pdf
    }
```

Add `kind` to `Pending`:

```swift
        public var kind: Kind
```

placed after `modified`, and update the memberwise use in `pending(in:)` below.

Rename `minimumBytes` and add the PDF floor:

```swift
    /// Roughly twenty seconds of AAC at a voice bitrate. Below this there is
    /// nothing to summarise.
    static let minimumAudioBytes = 60_000

    /// A PDF gets its own floor, and a far smaller one: a legitimate one-page
    /// handout is a few kilobytes, and applying the audio figure would discard
    /// it silently. This only has to reject a zero-byte sync placeholder.
    static let minimumPDFBytes = 1_000
```

Replace the body of the `compactMap` in `pending(in:settledFor:)`:

```swift
        return names.compactMap { url -> Pending? in
            let ext = url.pathExtension.lowercased()
            let kind: Kind
            if audioExtensions.contains(ext) {
                kind = .audio
            } else if ext == "pdf" {
                kind = .pdf
            } else {
                return nil
            }

            guard let values = try? url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
            ]), values.isRegularFile == true,
                let size = values.fileSize, let modified = values.contentModificationDate
            else { return nil }

            // A file still being written keeps moving its modification date. A
            // sync client that has finished leaves it alone.
            guard now.timeIntervalSince(modified) >= settledFor else { return nil }
            // Anything this small is not material — an interrupted share, a
            // zero-byte placeholder, or a two-second misfire. Processing one
            // spends a model call to produce a note about nothing.
            let floor = kind == .audio ? minimumAudioBytes : minimumPDFBytes
            guard size >= floor else { return nil }

            return Pending(url: url, bytes: Int64(size), modified: modified, kind: kind)
        }
```

Update the README text written by `prepare` so the folder still explains itself:

```swift
        try """
            # Lecture inbox

            Audio dropped in here is transcribed and written up by Lecture Notes,
            then filed under the course it worked out, exactly as if you had
            recorded it in the app. A PDF dropped in here is read and written up
            the same way.

            The point of this folder is your phone. Record a lecture with Voice
            Memos, share it into this folder, and it syncs here. Nothing needs to
            be installed on the phone and nothing needs to be paired.

            Processing happens when the Mac is awake and the app is running. The
            file itself is moved into `Written up/` rather than deleted.
            """.write(to: readme, atomically: true, encoding: .utf8)
```

- [ ] **Step 4: Run tests**

```bash
swift test --package-path Packages/LectureKit --filter InboxWatcher
```

Expected: PASS, including every pre-existing test in the file unchanged.

- [ ] **Step 5: Commit**

```bash
git add Packages/LectureKit/Sources/LectureKit/InboxWatcher.swift \
        Packages/LectureKit/Tests/LectureKitTests/InboxWatcherTests.swift
git commit -m "Let the inbox take PDFs, with a floor that suits them"
```

---

### Task 8: The library reads readings back

**Files:**
- Modify: `Packages/LectureKit/Sources/LectureKit/LibraryScanner.swift:18-35,106-134`
- Test: `Packages/LectureKit/Tests/LectureKitTests/LibraryScannerTests.swift`

**Interfaces:**
- Produces: `LibraryLecture.noteType: String?`, `.sourceRef: String?`, `.pages: Int?`, `.isReading: Bool`.

- [ ] **Step 1: Write the failing test**

Append to `Packages/LectureKit/Tests/LectureKitTests/LibraryScannerTests.swift`. The file already has a `ScanSandbox` helper with a `write(_:to:)` method and a `settings` property — use it; do not add a second sandbox type.

```swift
@Suite("Scanning readings")
struct LibraryScannerReadingTests {

    @Test("a note with no type key is a lecture")
    func absentTypeIsALecture() throws {
        // Every note written before this feature existed. Treating an absent
        // key as unknown would strip a term of notes of their duration, their
        // hatch swatch and their re-run action.
        let box = try ScanSandbox()
        try box.write(
            """
            ---
            title: "Trees"
            course: CS 314H
            date: 2026-09-02
            duration_min: 52
            ---
            # Trees
            """,
            to: "Courses/CS 314H/Lectures/2026-09-02 Trees.md")

        let lecture = try #require(
            LibraryScanner.scan(settings: box.settings).first?.lectures.first)
        #expect(lecture.noteType == nil)
        #expect(lecture.isReading == false)
        #expect(lecture.durationMinutes == 52)
    }

    @Test("a reading is read back with its source and page count")
    func readsReadingFrontmatter() throws {
        let box = try ScanSandbox()
        try box.write(
            """
            ---
            title: "Dynamic programming"
            course: CS 314H
            date: 2026-09-02
            type: reading
            source: "/vault/_Inbox/dp.pdf"
            pages: 24
            ---
            # Dynamic programming
            """,
            to: "Courses/CS 314H/Lectures/2026-09-02 Dynamic programming.md")

        let reading = try #require(
            LibraryScanner.scan(settings: box.settings).first?.lectures.first)
        #expect(reading.isReading)
        #expect(reading.noteType == "reading")
        #expect(reading.sourceRef == "/vault/_Inbox/dp.pdf")
        #expect(reading.pages == 24)
        // No transcript and no duration, so nothing draws a density it does not have.
        #expect(reading.durationMinutes == nil)
        #expect(reading.wordsPerMinute == nil)
    }

    @Test("a quoted source is unquoted")
    func stripsQuotesFromSource() throws {
        // The renderer quotes it, because a path can contain a colon. The
        // scanner has to undo that or every source reads with quotes around it.
        let box = try ScanSandbox()
        try box.write(
            """
            ---
            type: reading
            source: "https://example.com/a"
            ---
            """,
            to: "Courses/CS 314H/Lectures/a.md")

        #expect(LibraryScanner.scan(settings: box.settings).first?.lectures.first?.sourceRef
            == "https://example.com/a")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
swift test --package-path Packages/LectureKit --filter LibraryScannerReadingTests
```

Expected: FAIL — `LibraryLecture` has no `noteType`.

- [ ] **Step 3: Implement**

Add to `LibraryLecture` (after `wordsPerMinute`):

```swift
    /// The `type:` key verbatim, or nil when the note has none.
    ///
    /// Nil is not "unknown": every note written before readings existed omits
    /// this key and every one of them is a lecture. `isReading` encodes that.
    public let noteType: String?
    /// The `source:` key — a file path or a URL — for readings.
    public let sourceRef: String?
    /// Page count, for PDF readings.
    public let pages: Int?

    /// Only an explicit `type: reading` is a reading.
    public var isReading: Bool { noteType == "reading" }
```

In `read(_:course:)`, add before the `return`:

```swift
        // Quoted by the renderer, because a vault path can contain a colon.
        let sourceRef = parsed.front["source"].map { raw -> String in
            var value = raw
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
```

and extend the `LibraryLecture(...)` construction with:

```swift
            noteType: parsed.front["type"].flatMap { $0.isEmpty ? nil : $0 },
            sourceRef: sourceRef.flatMap { $0.isEmpty ? nil : $0 },
            pages: parsed.front["pages"].flatMap(Int.init)
```

- [ ] **Step 4: Run the whole suite**

```bash
swift test --package-path Packages/LectureKit
```

Expected: PASS. Every pre-existing `LibraryScannerTests` case must pass untouched.

- [ ] **Step 5: Commit**

```bash
git add Packages/LectureKit/Sources/LectureKit/LibraryScanner.swift \
        Packages/LectureKit/Tests/LectureKitTests/LibraryScannerTests.swift
git commit -m "Read a reading's type, source and page count back off disk"
```

---

### Task 9: One write-up path for three sources

The refactor. For audio this is behaviour-preserving by construction: the same transcription call, the same date, the same duration, the same pinned-course handling, the same archive-after-write ordering.

**Files:**
- Modify: `App/Sources/SessionModel.swift:226-331`

**Interfaces:**
- Consumes: `Extracted`, `SourceFailure`, `PDFReader.read`, `WebReader.read`, `Prompts.reading`, `NoteWriterPrompts.readingNotes`, `CourseDetector.Material`, `InboxWatcher.Kind`.
- Produces: `SessionModel.addPDFs(_ urls: [URL]) async`, `SessionModel.writeUpLink(_ raw: String) async`, `SessionModel.isReadingLink: Bool`.

- [ ] **Step 1: Split `writeUp`**

Replace `writeUp(_ item:)` (line 277) with the three functions below. `runInbox` keeps calling `writeUp(item)`.

```swift
    private func writeUp(_ item: InboxWatcher.Pending) async {
        inboxWorking = item.url.lastPathComponent
        statusLine = "Writing up \(item.url.lastPathComponent)…"

        let extracted: Extracted
        let day: String
        switch item.kind {
        case .audio:
            Self.log.info("inbox: transcribing \(item.url.lastPathComponent, privacy: .public)")
            guard let transcript = try? await Transcriber.transcribeFile(item.url),
                  !transcript.split(whereSeparator: \.isWhitespace).isEmpty
            else {
                // Left in place rather than archived: an empty transcript is more
                // often a file that has not finished syncing than a silent lecture,
                // and the next pass should try again.
                Self.log.error("inbox: no speech in \(item.url.lastPathComponent, privacy: .public)")
                statusLine = "Couldn't read \(item.url.lastPathComponent)."
                inboxWorking = nil
                return
            }
            extracted = Extracted(text: transcript, title: nil, source: .lecture)
            // The file's own date, not today's. A lecture shared on Friday for a
            // Wednesday recording belongs to Wednesday, and the date is what the
            // note is filed and sorted by.
            day = LectureNote.day(of: item.modified)

        case .pdf:
            Self.log.info("inbox: reading \(item.url.lastPathComponent, privacy: .public)")
            do {
                extracted = try PDFReader.read(item.url)
            } catch let failure as SourceFailure {
                Self.log.error("inbox: \(item.url.lastPathComponent, privacy: .public) unreadable")
                statusLine = failure.message
                inboxWorking = nil
                return
            } catch {
                statusLine = "Couldn't read \(item.url.lastPathComponent)."
                inboxWorking = nil
                return
            }
            day = LectureNote.day(of: item.modified)
        }

        let filed = await writeUp(extracted, dated: day, duration: duration(of: item))
        if filed {
            // Archived only after the note is safely on disk. Moving first would
            // lose the file if the write failed.
            _ = try? InboxWatcher.archive(item.url, in: settings.inboxDirectory)
        }
        inboxWorking = nil
    }

    /// A recording's length, read from the file. Zero for anything that is not
    /// audio: `duration_min: 0` on a lecture is a claim about the lecture, but a
    /// reading never renders the key at all, so the value is unused there.
    private func duration(of item: InboxWatcher.Pending) -> TimeInterval {
        guard item.kind == .audio else { return 0 }
        return (try? AVAudioFile(forReading: item.url))
            .map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
    }

    /// Detect the course, write the notes, file the note. Shared by audio, PDFs
    /// and web pages — from here on nothing knows which it is handling except
    /// through `extracted.source`.
    ///
    /// Returns whether the note reached disk, which is what tells the caller
    /// whether it may archive the source.
    @discardableResult
    private func writeUp(
        _ extracted: Extracted, dated day: String, duration: TimeInterval
    ) async -> Bool {
        let isReading = extracted.source.isReading

        var note = LectureNote(date: day, course: unsortedFolder, source: extracted.source)
        note.transcript = isReading ? "" : extracted.text
        note.duration = duration
        // A reading's own title, until the detector proposes something better.
        if let title = extracted.title, !title.isEmpty {
            note.topic = PathComponent.sanitised(title, fallback: "Lecture")
        }

        let candidates = CourseDetector.candidates(in: settings.coursesDir)
        if let guess = await CourseDetector(claude: claude).detect(
            text: extracted.text,
            candidates: candidates,
            model: settings.detectModel,
            material: isReading ? .reading : .lecture) {
            note.course = settings.pinnedCourse
                ?? CourseDetector.resolveFolder(guess, candidates: candidates)
            note.topic = guess.topic
            if settings.pinnedCourse == nil {
                note.detectedCourse = guess.course
                note.detectionConfidence = guess.confidence
            }
        }

        let markdown: String?
        if isReading {
            markdown = try? await claude.run(
                prompt: NoteWriterPrompts.readingNotes(
                    text: extracted.text, course: note.course, source: sourceRef(extracted.source)),
                system: Prompts.reading, model: settings.finalModel, timeout: 600)
        } else {
            markdown = try? await claude.run(
                prompt: NoteWriterPrompts.finalNotes(
                    transcript: extracted.text, course: note.course),
                system: Prompts.final, model: settings.finalModel, timeout: 600)
        }
        if let markdown { note.finalNotes = fixCallouts(markdown) }

        let written = writer.saveAll(&note, settings: settings)
        guard !written.isEmpty else {
            Self.log.error("could not file \(note.topic, privacy: .public)")
            statusLine = "Couldn't write the note into your vault."
            return false
        }
        Self.log.info("filed under \(note.course, privacy: .public)")
        statusLine = "Wrote up \(note.topic)"
        return true
    }

    /// What goes in the note's `Source:` prompt line and its frontmatter.
    private func sourceRef(_ source: NoteSource) -> String {
        switch source {
        case .lecture: ""
        case .pdf(let file, _, _): file.lastPathComponent
        case .web(let page, _): page.absoluteString
        }
    }
```

- [ ] **Step 2: Add the PDF and link entry points**

Add after `addRecordings` (line 275):

```swift
    /// Copy PDFs into the inbox and read them now.
    ///
    /// Copied, never moved, and `settledFor: 0` — both for the same reasons as
    /// `addRecordings`: the file is the user's and may be their only copy, and a
    /// file chosen in a panel or dropped on the window is finished by definition.
    func addPDFs(_ urls: [URL]) async {
        let inbox = settings.inboxDirectory
        try? InboxWatcher.prepare(inbox)
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            var destination = inbox.appending(path: url.lastPathComponent)
            var suffix = 2
            while FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                let stem = url.deletingPathExtension().lastPathComponent
                destination = inbox.appending(path: "\(stem) \(suffix).pdf")
                suffix += 1
            }
            do {
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                Self.log.error("inbox: could not copy \(url.lastPathComponent, privacy: .public)")
                statusLine = "Couldn't add \(url.lastPathComponent)."
            }
        }
        await processInbox(settledFor: 0)
    }

    /// Whether a link is being fetched right now, so the field can disable itself.
    private(set) var isReadingLink = false

    /// Read a web page and write it up.
    ///
    /// Nothing is copied into the inbox: there is no file, and the URL recorded
    /// in the note's frontmatter is the way back to the source.
    func writeUpLink(_ raw: String) async {
        guard !isReadingLink, phase == .idle else { return }
        isReadingLink = true
        defer { isReadingLink = false }

        statusLine = "Reading the page…"
        let extracted: Extracted
        do {
            extracted = try await WebReader.read(raw)
        } catch let failure as SourceFailure {
            statusLine = failure.message
            return
        } catch {
            statusLine = "Couldn't read that link."
            return
        }
        await writeUp(extracted, dated: LectureNote.day(), duration: 0)
    }
```

- [ ] **Step 3: Build**

```bash
make check
```

Expected: PASS. `CourseDetector.candidates(in:)` and `CourseDetector.resolveFolder(_:candidates:)` are both existing public statics with exactly these signatures — the detection block is moved from the old `writeUp` unchanged apart from the `text:` and `material:` labels added in Task 6.

- [ ] **Step 4: Verify the audio path by hand**

Drop a real `.m4a` into the vault inbox and confirm it is transcribed, filed under the detected course, and moved into `Written up/` exactly as before. This is the one part of the refactor no unit test covers.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/SessionModel.swift
git commit -m "One write-up path for audio, PDFs and pages"
```

---

### Task 10: The Record screen takes a PDF or a link

**Files:**
- Modify: `App/Sources/Views/RecordView.swift:239-306`

**Interfaces:**
- Consumes: `SessionModel.addPDFs`, `.writeUpLink`, `.isReadingLink` (Task 9).

- [ ] **Step 1: Add the section**

In `RecordView`, add the state property beside the view's other `@State`:

```swift
    @State private var link = ""
```

Add `readingSection` to `readyNotes` after `fromPhone`:

```swift
            fromPhone.padding(.top, Spacing.lg)
            readingSection.padding(.top, Spacing.lg)
```

and add the view itself next to `fromPhone`:

```swift
    /// PDFs and web pages.
    ///
    /// A sibling of `fromPhone` rather than part of it: both are "material that
    /// did not come from the microphone", but one is a folder you point a share
    /// sheet at once and forget, and the other is a thing you do deliberately
    /// each time. Sharing a section would bury the folder.
    private var readingSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionRule("Something to read")
            Text("A PDF or a web page is read and written up the same way, filed under the course it belongs to. PDFs dropped into the inbox folder work too.")
                .font(Typography.bodyText)
                .foregroundStyle(Palette.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            quietAction("Add a PDF…") { choosePDFs() }

            HStack(spacing: Spacing.md) {
                TextField("https://…", text: $link)
                    .textFieldStyle(.plain)
                    .font(Typography.ui)
                    .foregroundStyle(Palette.ink)
                    .padding(.vertical, Spacing.sm)
                    .padding(.horizontal, Spacing.md)
                    // A hairline, per DESIGN.md §2: `rule` is never the sole
                    // boundary of an interactive control, so the field also
                    // carries a `wash` fill.
                    .background(Palette.wash)
                    .overlay(Rectangle().stroke(Palette.rule, lineWidth: Spacing.hair))
                    .frame(maxWidth: 320)
                    .onSubmit(submitLink)
                    .disabled(session.isReadingLink)

                quietAction(session.isReadingLink ? "Reading…" : "Write up", run: submitLink)
                    .disabled(session.isReadingLink || link.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func submitLink() {
        let raw = link
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Cleared straight away: the write-up takes a minute, and a field still
        // holding the last URL reads as though nothing happened.
        link = ""
        Task { await session.writeUpLink(raw) }
    }

    /// PDFs only, several at once — a term's backlog of handouts is a realistic
    /// first use, the same as the recordings picker beside it.
    private func choosePDFs() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "Add"
        panel.message = "PDFs are copied into your vault's inbox and written up."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { await session.addPDFs(urls) }
    }
```

`NSOpenPanel.allowedContentTypes` needs `import UniformTypeIdentifiers` at the top of the file if it is not already there.

- [ ] **Step 2: Add the drop target**

On the view's outermost container in `body`, add:

```swift
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            guard !pdfs.isEmpty else { return false }
            Task { await session.addPDFs(pdfs) }
            return true
        }
```

- [ ] **Step 3: Build and run**

```bash
make check && make app
```

Then launch the app, open the Record screen, and confirm: the section renders, "Add a PDF…" opens a panel filtered to PDFs, a dropped PDF is accepted, and a typed URL disables the field while it works.

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Views/RecordView.swift
git commit -m "Take a PDF or a link from the Record screen"
```

---

### Task 11: A reading looks like a reading in the library

**Files:**
- Create: `App/Sources/Components/SheetMark.swift`
- Modify: `App/Sources/Views/LibraryView.swift:273-344`

**Interfaces:**
- Consumes: `LibraryLecture.isReading`, `.pages`, `.sourceRef` (Task 8).

- [ ] **Step 1: Create the mark**

Create `App/Sources/Components/SheetMark.swift`:

```swift
import LectureKit
import SwiftUI

/// The row-scale mark for a reading, standing where ``HatchSwatch`` stands for
/// a lecture.
///
/// A reading has no speech, so it has no density to hatch, and drawing an empty
/// swatch would state that the lecture was silent. This draws a mounted sheet
/// instead: a ruled rectangle with two lines of text on it, at the same 24pt
/// width and in the same `inkSoft` as the hatching, so the two marks read as
/// members of one system rather than as an icon set.
///
/// Per DESIGN.md §2, course identity is never a hue and this adds no token.
/// Like the hatching it is duplicative — the caption line beside it says "PDF"
/// in words — so it is hidden from the accessibility tree.
struct SheetMark: View {

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 2
            let sheet = CGRect(
                x: inset, y: inset,
                width: size.width - inset * 2, height: size.height - inset * 2)

            context.stroke(
                Path(sheet), with: .color(Palette.inkSoft), lineWidth: Spacing.hair)

            // Three short rules for the text on the sheet, inset from its edge
            // by the same amount the sheet is inset from the gutter.
            let margin: CGFloat = 4
            let top = sheet.minY + margin
            let spacing = (sheet.height - margin * 2) / 3
            for line in 0..<3 {
                let y = (top + spacing * CGFloat(line)).rounded()
                // The last rule is short, the way a final line of a paragraph is.
                let width = line == 2 ? (sheet.width - margin * 2) * 0.55
                                      : sheet.width - margin * 2
                var path = Path()
                path.move(to: CGPoint(x: sheet.minX + margin, y: y))
                path.addLine(to: CGPoint(x: sheet.minX + margin + width, y: y))
                context.stroke(path, with: .color(Palette.inkSoft), lineWidth: Spacing.hair)
            }
        }
        .frame(width: Spacing.gutterWidth)
        .accessibilityHidden(true)
    }
}
```

- [ ] **Step 2: Use it in the row**

In `LibraryView`, replace the `HatchSwatch(...)` line (line 301) with:

```swift
                if lecture.isReading {
                    SheetMark()
                } else {
                    HatchSwatch(wordsPerMinute: lecture.wordsPerMinute)
                }
```

Add a caption detail that substitutes the duration, next to `durationText` (line 279):

```swift
    /// What stands where a lecture's duration stands.
    ///
    /// A reading has no length, so the field carries what it does have: the
    /// format, and either its extent or where it came from.
    private var sourceText: String {
        guard lecture.isReading else { return durationText }
        if let pages = lecture.pages, pages > 0 {
            return "PDF · \(pages) pp"
        }
        if let ref = lecture.sourceRef, let host = URL(string: ref)?.host() {
            return "web · \(host)"
        }
        return "reading"
    }
```

and use it in the `SpecimenLabel` (line 328):

```swift
                        detail: "\(lecture.date) · \(sourceText)")
```

- [ ] **Step 3: Fix the accessibility label**

`accessibilityLabel` builds on `spokenDuration`, which is empty for a reading. Find it in the same file and make the duration clause conditional, so a reading is announced as what it is:

```swift
        // A reading has no duration to announce, and an empty clause leaves a
        // dangling separator mid-sentence.
        let extent = lecture.isReading ? sourceText : spokenDuration
```

then use `extent` where `spokenDuration` was used.

- [ ] **Step 4: Build**

```bash
make check
```

Expected: PASS.

- [ ] **Step 5: Verify by eye**

```bash
make app
```

Launch, write up one PDF, and confirm the library row shows the sheet mark, `CS 331 · 2026-07-31 · PDF · 24 pp`, and no audio control.

- [ ] **Step 6: Commit**

```bash
git add App/Sources/Components/SheetMark.swift App/Sources/Views/LibraryView.swift
git commit -m "Give a reading its own mark and caption in the library"
```

---

### Task 12: End-to-end check and README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Run the full check**

```bash
make check
```

Expected: PASS, every suite.

- [ ] **Step 2: Walk the regression list from the spec**

Confirm each by hand:

1. `RegressionTests.lectureRenderIsUnchanged` passes.
2. `RegressionTests.detectionPromptIsUnchanged` passes.
3. Record a short lecture in the app end to end: transcript streams, live notes appear, the final pass files it under the detected course.
4. Drop an `.m4a` in the inbox: written up and moved to `Written up/`.
5. Open the library: every pre-existing note still shows its duration and hatch swatch, and still offers "write the notes again".
6. `git diff --stat <first-commit-of-this-branch>..HEAD` touches no file outside the list in the spec's §6, plus `RegressionTests.swift`, `SheetMark.swift` and this plan's own docs.

- [ ] **Step 3: Update the README**

In the opening paragraph, after the sentence describing what gets filed, add:

```markdown
A PDF or a web page can be written up the same way: its text is read on this Mac
— including scans, which are read with on-device OCR — and the notes are filed
under the course it belongs to, exactly as a lecture is. As with a lecture, the
**text** is sent to Claude because that is what the notes are written from; the
PDF and the page are read locally.
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "Say that PDFs and pages can be written up too"
```

---

## Notes for the implementer

- **`make check` is the gate, not `swift test`.** `check` also compiles `App/Sources`, which the package tests never touch. Two thirds of this codebase is the app target.
- **Task 1's two tests must never be edited** after Task 1 commits. If a later task makes one fail, the later task is wrong.
- **The spec's §9 is out of scope on purpose**: re-running a reading from its recorded `source:`, YouTube URLs, JavaScript-rendered pages, and readability-style boilerplate removal. Do not add them.
