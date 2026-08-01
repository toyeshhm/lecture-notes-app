# Readings: PDFs and web pages

**Status:** approved, not yet implemented
**Date:** 2026-07-31

Write up a PDF or a web page the same way a lecture is written up: extract its
text, work out which course it belongs to, have Claude write structured study
notes, and file it in the vault under that course.

This is **additive**. Recording, transcription, the live pass, the audio inbox,
course detection, and every note already on disk behave exactly as they do
today. Section 8 states that as a set of checks rather than as an intention.

---

## 1. Why this is small

The pipeline is already source-agnostic past its first step. There is one way to
produce text today and this adds two more; nothing downstream is aware of the
difference.

```
audio ──▶ Transcriber ────┐
PDF   ──▶ PDFReader ──────┼──▶ text ──▶ CourseDetector ──▶ ClaudeRunner ──▶ NoteRenderer ──▶ VaultWriter
URL   ──▶ WebReader ──────┘
```

`SessionModel.writeUp(_ item:)` hardcodes "transcribe, then everything else". It
splits into `writeUp(extracted:dated:)`, which takes text already in hand, and
three thin callers that produce it. The three sources differ only in how they
make a string, so that is the only place they differ in code.

---

## 2. Data model

`LectureNote` gains one field. A parallel `ReadingNote` type was rejected: it
would fork `VaultWriter`, `NoteRenderer`, and the per-target relocation
tracking, three things that are subtle and correct today, in exchange for
nothing.

```swift
public enum NoteSource: Sendable, Equatable {
    case lecture                              // recorded, or audio from the inbox
    case pdf(file: URL, pages: Int, ocr: Bool)
    case web(page: URL, siteTitle: String?)
}
```

`LectureNote.source` defaults to `.lecture`, so every existing construction site
compiles and behaves unchanged.

`NoteRenderer` branches on it for frontmatter and for whether the transcript
section is written. Nothing else in the renderer changes.

| | `.lecture` | `.pdf` / `.web` |
|---|---|---|
| `type:` | `lecture` | `reading` |
| `duration_min:` | minutes | omitted |
| `source:` | — | file path or URL |
| `pages:` | — | page count (`.pdf` only) |
| `ocr:` | — | `true` only when OCR ran |
| `tags:` | `lecture`, course | `reading`, course |
| `## Transcript` | per `keepTranscript` | never written |

**The extracted text is not embedded in the note.** The PDF is already on disk
and the URL is in the frontmatter; copying the source in would double the vault
and make the file unreadable in Obsidian. One consequence falls out for free:
`LectureActions.canRerun` keys on `wordsPerMinute != nil`, which is nil for a
note with no transcript, so "write the notes again" correctly does not offer
itself on a reading without that code being touched.

---

## 3. Extraction

Two new files in `LectureKit`. Both return the same struct so `writeUp` cannot
tell them apart:

```swift
public struct Extracted: Sendable, Equatable {
    public var text: String
    public var title: String?      // <title>, or the PDF's title metadata
    public var source: NoteSource
}
```

### 3.1 `PDFReader.swift`

`PDFDocument.string` first. When it returns fewer than **100 characters per
page** the PDF is a scan with no text layer: rasterise each page at 2× and run
`VNRecognizeTextRequest` at `.accurate`, joining the recognised lines.

PDFKit and Vision both ship with macOS. Nothing is added to `Package.swift`, and
OCR runs on device — the README's claim that no recording leaves the machine
extends to scans without qualification.

The threshold is per page, not per document, so a 40-page scan with one text
cover page does not read as a text PDF.

Rejected: encrypted PDFs (`PDFDocument.isEncrypted`) fail before any work.

### 3.2 `WebReader.swift`

`URLSession` GET, then:

1. drop `<script>`, `<style>`, `<nav>`, `<header>`, `<footer>` and their contents
2. strip remaining tags
3. unescape HTML entities
4. collapse whitespace runs

Title from `<title>`. Boilerplate that survives (a breadcrumb, a cookie line) is
left alone — the model is summarising and ignores it, and a readability
heuristic is a large amount of code to remove text that costs nothing.

**A typed URL is untrusted input.** Three rules at the boundary:

- **Scheme allowlist: `http` and `https` only.** `file://` would make the field
  a local file reader, `javascript:` and `data:` are rejected outright. Checked
  before any request is made.
- **10 MB body cap and a 30s timeout.** A large or slow response must fail, not
  hang the app.
- **`Content-Type: application/pdf` hands off to `PDFReader`.** Linked lecture
  slides are usually a PDF at an `https://` URL, and stripping tags off a binary
  produces plausible-looking garbage rather than an error.

### 3.3 Prompts

`Prompts.reading`, a sibling of `Prompts.final`. Same skeleton — Summary,
Notes, Key terms, Open questions — with two changes:

- The ASR-repair rules are removed. "Silently fix obvious mishearings" applied
  to a PDF instructs the model to correct text that is already correct.
- **`## Likely exam material` is dropped.** A lecturer flags things out loud; a
  PDF does not. Keeping the heading invites the model to invent emphasis that
  is not in the source.

`CourseDetector.detectSystem` says "lecture transcript" and "The transcript is
ASR output and may contain errors", both wrong for a reading. It takes a
material-kind parameter. **The string produced for a lecture stays
byte-identical** — see §8.

---

## 4. Surfaces

### 4.1 Record screen

A "Something to read" block below the existing "Recorded somewhere else"
section in `RecordView.swift`, built from the same `sectionRule` and
`quietAction` helpers already there:

```
── Recorded somewhere else ─────────────────
Audio dropped into the inbox folder in your vault…
  Add a recording…     Show the inbox folder

── Something to read ───────────────────────
A PDF or a web page is read and written up the
same way, filed under the course it belongs to.

  Add a PDF…
  ┌─ https://… ──────────────────┐  ⌈Write up⌋
  └──────────────────────────────┘
```

Plus `.dropDestination` on the window for PDFs.

### 4.2 Inbox

`InboxWatcher` accepts `.pdf`. `Pending` gains a `kind` so `writeUp` knows
whether to transcribe or extract.

`minimumBytes` (60 KB, derived from twenty seconds of AAC at a voice bitrate)
**applies to audio only**. A legitimate one-page PDF is 8 KB and the audio floor
would silently discard it. PDFs get a much smaller floor, enough to reject a
zero-byte placeholder.

The 20-second settle wait, the `Written up/` archive, and the ordering (archive
only after the note is on disk) are unchanged and apply to both kinds.

### 4.3 Library row

DESIGN.md §5.4 puts mean speech density in the left 24pt hatch swatch. A reading
has no speech, and an empty swatch is a claim that the lecture was silent.

A reading gets a distinct engraved mark: a ruled sheet outline in `inkSoft`,
same weight as the hatch hairlines. No new token, no hue, survives greyscale —
consistent with DESIGN.md §2's colour discipline and the rule that course
identity is never carried by colour.

The caption line substitutes the duration field:

```
lecture   CS 331 · 31 JUL · 52 min
PDF       CS 331 · 31 JUL · PDF · 24 pp
web       CS 331 · 31 JUL · web · arxiv.org
```

### 4.4 Not changing

The menu bar popover. A clipboard-reading "write up this link" item was
considered and cut — it is a second surface to keep coherent for a case the
Record screen already covers.

---

## 5. Failure modes

Each lands in `statusLine` as a sentence a person can act on. Nothing is filed
and nothing is archived when any of these fire:

| Condition | Message |
|---|---|
| Encrypted PDF | "That PDF is password-protected." |
| Empty after OCR | "Couldn't find any text in *name* — even after reading it as a scan." |
| Non-2xx response | "*host* returned *code*." |
| Strips to nothing | "Nothing to read at *host* — the page builds itself in JavaScript." |
| Unreachable host | "Couldn't reach *host*." |
| Over 10 MB | "That page is too large to read." |
| Bad scheme | "Only http and https links can be written up." |

The JS-only case gets its own message rather than falling into "nothing to
read", because the cause is specific and otherwise indistinguishable from a
broken feature.

Files chosen in the picker or dropped on the window are **copied** into the
inbox, never moved — same as `addRecordings` today, for the same reason: the
file belongs to the user and may be their only copy.

---

## 6. Files touched

| File | Change |
|---|---|
| `LectureKit/PDFReader.swift` | new |
| `LectureKit/WebReader.swift` | new |
| `LectureKit/Models.swift` | `NoteSource`, `LectureNote.source`, `Extracted` |
| `LectureKit/NoteRenderer.swift` | frontmatter branch, `Prompts.reading`, `NoteWriterPrompts.readingNotes` |
| `LectureKit/CourseDetector.swift` | material-kind parameter |
| `LectureKit/InboxWatcher.swift` | `.pdf` extension, `Pending.kind`, per-kind size floor |
| `LectureKit/LibraryScanner.swift` | read `type:`, `source:`, `pages:` onto `LibraryLecture` |
| `App/SessionModel.swift` | split `writeUp`, add PDF and URL entry points |
| `App/Views/RecordView.swift` | "Something to read" block, drop target |
| `App/Views/LibraryView.swift` | reading mark and caption line |
| `App/Components/SheetMark.swift` | new — the reading's row mark |

`HatchSwatch.swift` is **not** modified. Its one job is speech density; a mode
where it draws something that is not hatching would be a second job hidden
inside it. The reading mark is a sibling file at the same 24pt width and in the
same `inkSoft`, so the two read as one system without either knowing about the
other.

No changes to `AudioCapture`, `Transcriber`, `VaultWriter`, `RosterWriter`,
`ConfigImport`, `Preflight`, `DesignTokens`, or any recording code path.

---

## 7. Tests

New:

- **`PDFReaderTests`** — text PDF generated in-test; per-page threshold triggers
  OCR on a rasterised page and does not on a text page; encrypted PDF fails.
- **`WebReaderTests`** — script/style/nav stripping, entity unescaping, title
  extraction, `file://` and `javascript:` rejection, `application/pdf` handoff,
  a body that strips to empty.
- **`NoteRendererTests`** — reading frontmatter for both `.pdf` and `.web`; no
  `## Transcript` section; no `duration_min` key.

`make check` runs `lint`, `app`, and `test`, which covers all of it.

---

## 8. Regression checks

The constraint is that everything that worked before works identically. These
are the checks that hold it, not an assurance that it does.

1. **`NoteRenderer.render` is byte-identical for a lecture.** A golden test
   pins the current output of a fully populated `LectureNote` — frontmatter key
   order, the `tags:` block, the transcript section — and fails on any drift.
   This is the single highest-value check here: every note in the vault is
   rewritten through this function.

2. **`CourseDetector.detectSystem` for a lecture is byte-identical.** Asserted
   against the current literal. Detection quality was tuned against real
   transcripts; a reworded prompt is a silent quality regression with no visible
   symptom.

3. **The audio path through the refactored `writeUp` is unchanged.** The split
   into `writeUp(extracted:dated:)` is a pure refactor for audio: same
   transcription call, same date (the file's own modification date, not today),
   same duration read from `AVAudioFile`, same pinned-course handling, same
   archive-after-write ordering.

4. **`InboxWatcher.pending` returns the same result for audio.** The existing
   `InboxWatcherTests` must pass untouched: the 20-second settle wait, the
   60 KB floor, oldest-first ordering, and the extension set all unchanged for
   audio. The PDF floor is a separate value on a separate branch.

5. **Notes already on disk read as lectures.** No existing note has a `type:`
   key. `LibraryScanner` treats absent `type:` as a lecture — never as an
   unknown or a reading — so a term of existing notes keeps its hatch swatch,
   its duration, and its re-run action.

6. **The recording pipeline is not touched.** `AudioCapture`, `Transcriber`,
   the live chunk pass, and `Prompts.live` have no changes in this work. The
   file list in §6 is the whole diff.

7. **`LectureNote.source` defaults to `.lecture`.** Every existing construction
   site — the recorder, the inbox, `LectureActions.rerun` — is unmodified and
   produces the note it produces today.

---

## 9. Deliberately out of scope

- **Re-running a reading's notes** by re-fetching its recorded `source:`. It is
  possible and cleaner than the lecture path, and nothing needs it yet.
- **YouTube URLs.** A different problem — a transcript API, not HTML — and
  pretending otherwise would produce a note written from a consent banner.
- **JavaScript-rendered pages.** An offscreen `WKWebView` was considered and
  rejected: it costs a hidden web view in a menu bar app and a "settled"
  heuristic that is always a guess. §5 gives this case its own error message
  instead of silently producing a thin note.
- **Readability-style boilerplate removal.** The model tolerates a nav menu.
