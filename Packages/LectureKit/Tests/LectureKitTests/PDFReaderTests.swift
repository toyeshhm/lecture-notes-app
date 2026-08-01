import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import LectureKit

/// One generated page: words in the text layer, or the same words rasterised
/// into an image, which is all a scanned chapter is.
enum PDFPage {
    case text(String)
    case scan([String])
}

/// Builds real PDFs on disk. No fixtures checked in: a generated file is
/// readable in the test that uses it, and CoreGraphics is already here.
///
/// `passwords` goes straight into the auxiliary info, which is the only way to
/// produce the two encrypted shapes that behave differently: an owner password
/// restricts printing and leaves the text readable, a user password does not.
func makePDF(pages: [PDFPage], at url: URL, passwords: [CFString: String] = [:]) throws {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let auxiliary = passwords.isEmpty ? nil : passwords as CFDictionary
    guard let context = CGContext(url as CFURL, mediaBox: &box, auxiliary) else {
        throw SourceFailure.noText(name: "could not create context")
    }
    for page in pages {
        context.beginPDFPage(nil)
        switch page {
        case .text(let text) where !text.isEmpty:
            draw(text, at: CGPoint(x: 40, y: 700), size: 12, in: context)
        case .text:
            break
        case .scan(let lines):
            if let image = rasterise(lines, size: box.size) { context.draw(image, in: box) }
        }
        context.endPDFPage()
    }
    context.closePDF()
}

private func draw(_ text: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    let attributed = NSAttributedString(
        string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
    context.textPosition = point
    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
}

/// Words with no text layer behind them.
///
/// Large type on a 2× canvas because the point is to be legible to Vision after
/// `PDFReader` rasterises the page again — a scan photographed at 300 dpi is
/// the case this stands in for, not a screenshot of a phone.
private func rasterise(_ lines: [String], size: CGSize) -> CGImage? {
    let scale: CGFloat = 2
    let width = Int(size.width * scale)
    let height = Int(size.height * scale)
    guard
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(gray: 0, alpha: 1)
    var baseline = CGFloat(height) - 140
    for line in lines {
        draw(line, at: CGPoint(x: 80, y: baseline), size: 48, in: context)
        baseline -= 100
    }
    return context.makeImage()
}

func sandbox() throws -> URL {
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
        try makePDF(pages: [.text(body)], at: url)

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
        try makePDF(pages: [.text(dense), .text(dense), .text(dense)], at: url)

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
        try makePDF(pages: [.text(""), .text(""), .text("")], at: url)

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

    @Test("a typed cover page does not make a scan read as a text PDF")
    func thresholdIsPerPage() throws {
        // The shape the threshold exists for, in miniature: one page with a
        // text layer and two with none. Its 168 characters clear a
        // whole-document floor of 100 and fall well short of 100 a page, so
        // this passes only while the comparison divides by the page count —
        // and it reaches the text through OCR, which asserting the constant
        // never does.
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "chapter.pdf")
        let cover = String(repeating: "Chapter four, memoisation. ", count: 6)
        let scanned = [
            "Memoisation trades space for time",
            "Overlapping subproblems repeat work",
            "A table records each answer once",
            "Optimal substructure makes it sound",
            "Bottom up removes the recursion",
        ]
        try makePDF(pages: [.text(cover), .scan(scanned), .scan(scanned)], at: url)

        let out = try PDFReader.read(url)

        #expect(out.source == .pdf(file: url, pages: 3, ocr: true))
        #expect(out.text.lowercased().contains("subproblems"))
    }

    @Test("a PDF that needs a password is reported, not guessed at")
    func lockedPDFFails() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "locked.pdf")
        let body = String(repeating: "Dynamic programming solves subproblems once. ", count: 8)
        try makePDF(
            pages: [.text(body)], at: url,
            passwords: [kCGPDFContextUserPassword: "letmein", kCGPDFContextOwnerPassword: "owner"])

        #expect(throws: SourceFailure.encrypted) { try PDFReader.read(url) }
    }

    @Test("a PDF that only restricts printing is read, not refused")
    func ownerPasswordPDFReads() throws {
        // The normal shape of a publisher's chapter: encrypted, permissions
        // restricted, no password needed to read a word of it. `isEncrypted` is
        // true here and refusing on it tells the user a file they can open in
        // Preview is password-protected.
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "chapter.pdf")
        let body = String(repeating: "Dynamic programming solves subproblems once. ", count: 8)
        try makePDF(
            pages: [.text(body)], at: url, passwords: [kCGPDFContextOwnerPassword: "owner"])

        let out = try PDFReader.read(url)

        #expect(out.text.contains("Dynamic programming"))
    }
}
