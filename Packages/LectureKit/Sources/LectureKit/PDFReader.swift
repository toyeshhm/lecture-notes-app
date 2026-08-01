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
        // `isLocked`, not `isEncrypted`: the latter is true of any document
        // carrying an encryption dictionary, which includes the ordinary
        // publisher chapter encrypted with an owner password only to disallow
        // printing. Those read perfectly — refusing them tells the user a
        // readable file needs a password. `isLocked` is the one that means the
        // text is unreachable without one, and reaching it here saves the OCR
        // path a minute spent rasterising pages it cannot decrypt.
        guard !document.isLocked else { throw SourceFailure.encrypted }

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
        //
        // Which branch won is carried as a Bool, never re-derived by comparing
        // the strings: when Vision reads back exactly what the thin text layer
        // already held, `best == recognised` is true while `best` is the layer,
        // and the note then claims OCR on text that was never recognised. The
        // whole point of the flag is to warn that the text may carry
        // recognition errors, so a false positive is the expensive direction.
        let usedOCR = recognised.count > layer.count
        let best = usedOCR ? recognised : layer
        guard !best.isEmpty else { throw SourceFailure.noText(name: name) }

        return Extracted(
            text: best,
            title: title(of: document),
            source: .pdf(file: url, pages: pages, ocr: usedOCR))
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
