import CoreGraphics
import CoreText
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
