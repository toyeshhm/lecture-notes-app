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
                of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>",
                with: "\n",
                options: [.regularExpression])
            // An unclosed one — a <script src=…> with no body is fine, but a
            // truncated page can leave a real one open. Drop to end of input
            // rather than emitting its source as prose.
            working = working.replacingOccurrences(
                of: "(?is)<\(tag)\\b[^>]*>.*",
                with: "\n",
                options: [.regularExpression])
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
            of: "(?s)<!--.*?-->", with: " ", options: [.regularExpression])
        working = working.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: [.regularExpression])

        return tidy(unescape(working))
    }

    public static func title(inHTML html: String) -> String? {
        guard
            let range = html.range(
                of: "(?is)<title\\b[^>]*>(.*?)</title\\s*>",
                options: [.regularExpression])
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
