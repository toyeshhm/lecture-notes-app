import Foundation
import Network
import Testing

@testable import LectureKit

/// An HTTP server on the loopback interface, for the cases that are about the
/// socket rather than the string.
///
/// Not a `URLProtocol` stand-in: a body that declares no length and never ends,
/// and a server that answers its headers and then goes quiet, are both shapes a
/// stub handing `URLSession` a finished `Data` cannot produce — and they are
/// exactly the two the size cap and the deadline exist for.
/// Lets the first caller through and nobody after it.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func enter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

private final class LocalServer: @unchecked Sendable {

    enum Answer: Sendable {
        case ok(contentType: String, body: Data)
        case status(Int)
        /// Headers with no length and a body that never stops arriving.
        case endless
        /// Headers, then silence.
        case stall
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "local-server")
    private let lock = NSLock()
    private var stopped = false

    init(_ answer: Answer) throws {
        listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            // The request is read and discarded: each server here answers one
            // way, and parsing it would test this file rather than the reader.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                self.reply(answer, on: connection)
            }
        }
    }

    /// The address to ask, once the port is actually bound.
    func start() async throws -> String {
        // `stateUpdateHandler` fires more than once and a continuation may be
        // resumed exactly once; the gate is which of those two wins.
        let gate = Gate()
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if gate.enter() { continuation.resume(returning: listener.port ?? 0) }
                case .failed(let error):
                    if gate.enter() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        listener.cancel()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func reply(_ answer: Answer, on connection: NWConnection) {
        switch answer {
        case .ok(let contentType, let body):
            let head = """
                HTTP/1.1 200 OK\r
                Content-Type: \(contentType)\r
                Content-Length: \(body.count)\r
                Connection: close\r
                \r\n
                """
            connection.send(
                content: Data(head.utf8) + body,
                completion: .contentProcessed { _ in connection.cancel() })
        case .status(let code):
            let head = """
                HTTP/1.1 \(code) Nope\r
                Content-Type: text/html\r
                Content-Length: 0\r
                Connection: close\r
                \r\n
                """
            connection.send(
                content: Data(head.utf8),
                completion: .contentProcessed { _ in connection.cancel() })
        case .endless:
            // No Content-Length and no chunking, so the body runs until the
            // connection closes: the one shape a declared-length check cannot
            // see through, and the reason the count has to run as bytes arrive.
            connection.send(
                content: Data(openHeaders.utf8),
                completion: .contentProcessed { [weak self] _ in self?.pump(connection) })
        case .stall:
            connection.send(
                content: Data(openHeaders.utf8), completion: .contentProcessed { _ in })
        }
    }

    private var openHeaders: String {
        "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n"
    }

    private func pump(_ connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }
        connection.send(
            content: Data(repeating: UInt8(ascii: "a"), count: 64 * 1024),
            completion: .contentProcessed { [weak self] error in
                guard error == nil, let self else {
                    connection.cancel()
                    return
                }
                self.pump(connection)
            })
    }
}

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

    @Test("a link in the path or query is not a scheme")
    func schemeIsReadAtTheFront() throws {
        // What the Wayback Machine and Scholar hand out. Searching the whole
        // string for "://" calls these bad schemes, which is a refusal the user
        // cannot act on: the link is plainly http.
        #expect(
            try WebReader.validate("web.archive.org/web/20240101/https://example.com/paper")
                .host() == "web.archive.org")
        #expect(
            try WebReader.validate("scholar.google.com/scholar?q=https://arxiv.org/abs/1234")
                .host() == "scholar.google.com")
        // A colon before digits is a port, not a scheme.
        #expect(try WebReader.validate("cs.example.edu:8080/notes").port == 8080)
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

    @Test("a script spanning many lines is dropped whole")
    func dropsMultiLineScript() {
        // The shape every real page has, and the one the single-line test above
        // cannot see: `.` does not match a newline unless the pattern says so,
        // and without that the closing tag is never found — the fallback then
        // eats only the opening line and spills the rest of the source as prose.
        let html = """
            <body><p>Before.</p>
            <script>
              var tracker = 1;
              function boot() { render(); }
            </script>
            <p>After.</p></body>
            """
        let text = WebReader.plainText(fromHTML: html)
        #expect(text.contains("Before."))
        #expect(text.contains("After."))
        #expect(!text.contains("tracker"))
        #expect(!text.contains("boot"))
    }

    @Test("one unclosed script does not swallow the page before it")
    func unclosedScriptKeepsEarlierText() {
        // A truncated page leaves a real element open. Everything after it is
        // lost by design — but a greedy match would take the material before it
        // too, which is the whole page.
        let html = "<body><p>The material.</p><script>\n  var x = 1;\n  more(x);"
        let text = WebReader.plainText(fromHTML: html)
        #expect(text == "The material.")
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
        let text = WebReader.plainText(
            fromHTML: "<p>a &lt; b &amp;&amp; c &gt; d&nbsp;e &#39;f&#39;</p>")
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
        #expect(
            WebReader.title(inHTML: "<head><title> Dynamic  Programming </title></head>")
                == "Dynamic Programming")
        #expect(WebReader.title(inHTML: "<head></head>") == nil)
    }

    @Test("a self-closing script does not take the page with it")
    func selfClosingScriptKeepsTheBody() {
        // Valid polyglot markup, and common. The unclosed-element fallback used
        // to fire on it and drop everything to end of input — leaving the
        // title, which is not empty, so nothing failed and the page was written
        // up as a reading whose whole body was its own heading.
        let html = """
            <html><head><title>Lecture 7</title><script src="/app.js"/></head>
            <body><h1>Dynamic Programming</h1><p>Overlapping subproblems.</p></body></html>
            """
        let text = WebReader.plainText(fromHTML: html)
        #expect(text.contains("Dynamic Programming"))
        #expect(text.contains("Overlapping subproblems."))
    }
}

@Suite("Fetching a page")
struct WebReaderFetchTests {

    @Test("a body past the cap fails before it is all in memory")
    func capsBodySize() async throws {
        // The server writes 64 KB at a time and never stops, declaring no
        // length. Buffering first and checking after cannot fail this — it
        // accepts gigabytes — and neither can `timeoutInterval`, which only
        // measures silence. Elapsed time is asserted because the failure has to
        // arrive while the body is still arriving.
        let server = try LocalServer(.endless)
        defer { server.stop() }
        let address = try await server.start()

        let started = Date()
        await #expect(throws: SourceFailure.tooLarge) {
            _ = try await WebReader.read(address, deadline: 60)
        }
        #expect(Date().timeIntervalSince(started) < 30)
    }

    @Test("a server that answers and then goes quiet fails on the deadline")
    func stallingServerFails() async throws {
        // Headers arrive, the body never does. `URLRequest.timeoutInterval`
        // would eventually fire here; the reason the deadline exists is that it
        // would not for a server sending one slow byte at a time, and the two
        // cases must not behave differently to the person waiting.
        let server = try LocalServer(.stall)
        defer { server.stop() }
        let address = try await server.start()

        await #expect(throws: SourceFailure.unreachable(host: "127.0.0.1")) {
            _ = try await WebReader.read(address, deadline: 1)
        }
    }

    @Test("a non-2xx answer names the code")
    func reportsStatus() async throws {
        let server = try LocalServer(.status(404))
        defer { server.stop() }
        let address = try await server.start()

        await #expect(throws: SourceFailure.httpStatus(code: 404, host: "127.0.0.1")) {
            _ = try await WebReader.read(address)
        }
    }

    @Test("a PDF served over http is read as a PDF, not stripped as HTML")
    func handsPDFToThePDFReader() async throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "slides.pdf")
        let body = String(repeating: "Dynamic programming solves subproblems once. ", count: 8)
        try makePDF(pages: [.text(body)], at: file)

        // No `.pdf` on the path: the content type is the only signal, which is
        // the case linked lecture slides actually arrive in.
        let server = try LocalServer(
            .ok(contentType: "application/pdf", body: try Data(contentsOf: file)))
        defer { server.stop() }
        let address = try await server.start()

        let out = try await WebReader.read("\(address)/handout")

        #expect(out.text.contains("Dynamic programming"))
        // The web address, not the temp file it was written to: that is where
        // the user goes back to.
        guard case .web(let page, _) = out.source else {
            Issue.record("expected a web source")
            return
        }
        #expect(page.path() == "/handout")
    }

    @Test("a .pdf link that is not a PDF names the link, not a temp file")
    func namesTheAddressNotTheTempFile() async throws {
        // A login wall or a CDN interstitial: 200, HTML, at a `.pdf` address.
        // The user never saw `web-A185DE60….pdf` and cannot act on its name.
        let server = try LocalServer(
            .ok(contentType: "text/html", body: Data("<html>Sign in to continue</html>".utf8)))
        defer { server.stop() }
        let address = try await server.start()

        await #expect(throws: SourceFailure.noText(name: "2401.pdf")) {
            _ = try await WebReader.read("\(address)/papers/2401.pdf")
        }
    }

    @Test("a page with no declared charset keeps its accents")
    func decodesLatin1() async throws {
        // Still ordinary on department servers. Falling back to UTF-8 twice
        // substitutes U+FFFD for every byte it cannot read, which destroys each
        // accented character in the document before Claude ever sees it.
        var bytes = Data("<html><body><p>Un caf".utf8)
        bytes.append(0xE9)  // é in ISO-8859-1, and not valid UTF-8
        bytes.append(contentsOf: Data(" noir</p></body></html>".utf8))
        let server = try LocalServer(.ok(contentType: "text/html", body: bytes))
        defer { server.stop() }
        let address = try await server.start()

        let out = try await WebReader.read(address)

        #expect(out.text.contains("Un café"))
    }
}
