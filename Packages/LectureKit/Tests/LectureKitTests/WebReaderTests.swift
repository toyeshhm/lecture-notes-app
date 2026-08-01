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

    @Test("a page body is capped")
    func capsBodySize() {
        // A large or slow response must fail rather than hang the app.
        #expect(WebReader.maximumBytes == 10 * 1024 * 1024)
    }
}
