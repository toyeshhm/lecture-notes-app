import LectureKit
import Markdown
import SwiftUI

/// Renders a lecture note's markdown in the Hortus Siccus system.
///
/// The notes are markdown and were being shown as literal source — "### Deletion"
/// and "- **Leaf.**" on screen, which defeats the point of generating them. The
/// text comes from a model, so it is parsed with Apple's CommonMark parser
/// rather than pattern-matched: nested lists, mid-word emphasis and GFM tables
/// all turn up and a line-based reader gets them subtly wrong.
///
/// Two things CommonMark does not cover and this adds:
/// - **Obsidian callouts.** `> [!important] Title` parses as a plain blockquote;
///   the first line is lifted into a titled callout so the note reads the way it
///   will in Obsidian.
/// - **Maths.** `$…$` and `$$…$$` are set apart typographically. This is not a
///   typesetter: fractions and integrals stay as source. Setting them in a serif
///   italic at least stops them reading as prose, and full layout would mean a
///   maths engine, which is not worth it before the notes are being read daily.
struct NoteMarkdown: View {
    let source: String

    /// Prose is held to the measure; wide blocks opt out individually.
    var measure: CGFloat = Spacing.measure

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                block.view(measure: measure)
            }
        }
    }

    private var blocks: [NoteBlock] {
        NoteBlock.parse(source)
    }
}

// MARK: - Blocks

/// One rendered block. Flattened from the parse tree so the view layer is a
/// simple list rather than a recursive walk with layout state threaded through.
enum NoteBlock {
    case heading(level: Int, inline: AttributedString)
    case paragraph(AttributedString)
    case bullets(items: [AttributedString], ordered: Bool, start: Int)
    case callout(kind: String, title: String, body: [AttributedString])
    case quote([AttributedString])
    case code(String, language: String?)
    case table(head: [String], rows: [[String]])
    case rule

    static func parse(_ source: String) -> [NoteBlock] {
        Document(parsing: separateCalloutTitles(source)).children.flatMap { convert($0) }
    }

    /// Splits an Obsidian callout's title from its body before parsing.
    ///
    /// CommonMark folds a soft break inside a paragraph into a space — correct
    /// for prose, wrong here: it collapses
    ///
    ///     > [!important] Likely on exam
    ///     > "Comes up on the final."
    ///
    /// into one paragraph, so the title swallowed the body and both rendered on
    /// one line in the caption face. Inserting a blank quote line makes the
    /// parser produce two paragraphs, which is what the callout wants anyway.
    static func separateCalloutTitles(_ source: String) -> String {
        var lines = source.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            defer { index += 1 }
            guard lines[index].firstMatch(of: /^\s*>\s*\[!\w+\]/) != nil else { continue }
            let next = index + 1
            guard next < lines.count else { continue }
            // Only when a body line actually follows; a lone title needs nothing.
            let body = lines[next].trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix(">"), body != ">" else { continue }
            lines.insert(">", at: next)
            index += 1
        }
        return lines.joined(separator: "\n")
    }

    private static func convert(_ markup: any Markup) -> [NoteBlock] {
        switch markup {
        case let heading as Heading:
            return [.heading(level: heading.level, inline: inline(heading))]

        case let paragraph as Paragraph:
            return [.paragraph(inline(paragraph))]

        case let list as UnorderedList:
            return [.bullets(items: list.listItems.map { inline($0) }, ordered: false, start: 1)]

        case let list as OrderedList:
            return [.bullets(
                items: list.listItems.map { inline($0) },
                ordered: true,
                start: Int(list.startIndex))]

        case let quote as BlockQuote:
            return [callout(from: quote)]

        case let code as CodeBlock:
            return [.code(code.code.trimmingCharacters(in: .newlines), language: code.language)]

        case let table as Markdown.Table:
            let head = Array(table.head.cells.map { plain($0) })
            let rows = table.body.rows.map { row in Array(row.cells.map { plain($0) }) }
            let rowsArray = Array(rows)
            return [.table(head: head, rows: rowsArray)]

        case is ThematicBreak:
            return [.rule]

        default:
            // Anything unmodelled still has to reach the reader, so fall back to
            // its children rather than dropping the content on the floor.
            return markup.children.flatMap { convert($0) }
        }
    }

    /// `> [!important] Likely on exam` is an Obsidian callout, not a quotation.
    private static func callout(from quote: BlockQuote) -> NoteBlock {
        var paragraphs = quote.children.flatMap { block -> [AttributedString] in
            if let paragraph = block as? Paragraph { return [inline(paragraph)] }
            return block.children.compactMap { ($0 as? Paragraph).map { inline($0) } }
        }
        guard let first = paragraphs.first else { return .quote([]) }

        let text = String(first.characters)
        guard let match = text.firstMatch(of: /^\[!(\w+)\]\s*(.*)/) else {
            return .quote(paragraphs)
        }
        let kind = String(match.1).lowercased()
        var title = String(match.2).trimmingCharacters(in: .whitespaces)

        // The title may sit on the callout's first line, with the body following
        // after a soft break inside the same paragraph.
        var remainder: [AttributedString] = []
        if let newline = title.firstIndex(of: "\n") {
            remainder.append(AttributedString(String(title[title.index(after: newline)...])))
            title = String(title[..<newline])
        }
        paragraphs.removeFirst()
        return .callout(kind: kind, title: title, body: remainder + paragraphs)
    }

    // MARK: Inline

    private static func plain(_ markup: any Markup) -> String {
        String(inline(markup).characters)
    }

    /// Flattens inline markup into one styled string.
    ///
    /// AttributedString rather than concatenated `Text`: it wraps as a single
    /// paragraph, so a bolded run mid-sentence cannot break the line where the
    /// run ends.
    static func inline(_ markup: any Markup) -> AttributedString {
        var out = AttributedString()
        for child in markup.children {
            switch child {
            case let text as Markdown.Text:
                out += maths(in: text.string)
            case let strong as Strong:
                var run = inline(strong)
                run.inlinePresentationIntent = .stronglyEmphasized
                out += run
            case let emphasis as Emphasis:
                var run = inline(emphasis)
                run.inlinePresentationIntent = .emphasized
                out += run
            case let code as InlineCode:
                var run = AttributedString(code.code)
                run.inlinePresentationIntent = .code
                out += run
            case let link as Markdown.Link:
                var run = inline(link)
                if let destination = link.destination, let url = URL(string: destination) {
                    run.link = url
                }
                out += run
            case is SoftBreak:
                out += AttributedString(" ")
            case is LineBreak:
                out += AttributedString("\n")
            default:
                out += inline(child)
            }
        }
        return out
    }

    /// Marks `$…$` spans so the view can set them apart.
    private static func maths(in string: String) -> AttributedString {
        guard string.contains("$") else { return AttributedString(string) }
        var out = AttributedString()
        var rest = Substring(string)
        while let open = rest.firstIndex(of: "$") {
            out += AttributedString(String(rest[..<open]))
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "$") else {
                out += AttributedString(String(rest[open...]))
                return out
            }
            var run = AttributedString(String(rest[after..<close]))
            // No maths engine here, so the marker is typographic: a reader can
            // tell notation from prose even though it is not typeset.
            run.inlinePresentationIntent = .emphasized
            out += run
            rest = rest[rest.index(after: close)...]
        }
        out += AttributedString(String(rest))
        return out
    }
}

// MARK: - Views

extension NoteBlock {
    @ViewBuilder func view(measure: CGFloat) -> some View {
        switch self {
        case let .heading(level, inline):
            SwiftUI.Text(inline)
                .font(level <= 2 ? Typography.h2 : Typography.h3)
                // `h3` is Charter and tracks at zero; only the display face at
                // `h2` is tightened.
                .tracking(level <= 2 ? Typography.h2Tracking : 0)
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: measure, alignment: .leading)
                .padding(.top, level <= 2 ? Spacing.lg : Spacing.sm)
                // Without this a note is one flat run of paragraphs to VoiceOver
                // and the rotor's heading list is empty, which is how you read
                // forty thousand words with no way to skip a section.
                .accessibilityAddTraits(.isHeader)

        case let .paragraph(inline):
            SwiftUI.Text(inline)
                .font(Typography.bodyText)
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: measure, alignment: .leading)

        case let .bullets(items, ordered, start):
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        SwiftUI.Text(ordered ? "\(start + index)." : "—")
                            .font(ordered ? Typography.ui : Typography.bodyText)
                            .foregroundStyle(Palette.inkSoft)
                            .frame(minWidth: Spacing.lg, alignment: .trailing)
                            // A numeral is part of what the item says; the dash
                            // is the mark that makes it a list, and spoken it is
                            // just "dash" in front of every line.
                            .accessibilityHidden(!ordered)
                        SwiftUI.Text(item)
                            .font(Typography.bodyText)
                            .foregroundStyle(Palette.ink)
                            .textSelection(.enabled)
                    }
                    // One item is one idea, not a marker stop and a text stop.
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: measure, alignment: .leading)

        case let .callout(kind, title, body):
            CalloutBlock(kind: kind, title: title, paragraphs: body, measure: measure)

        case let .quote(paragraphs):
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    SwiftUI.Text(paragraph)
                        .font(Typography.bodyText)
                        .italic()
                        .foregroundStyle(Palette.inkSoft)
                }
            }
            .padding(.leading, Spacing.lg)
            .frame(maxWidth: measure, alignment: .leading)

        case let .code(code, language):
            // Wide content is the explicit exception to the measure, and scrolls
            // inside its own container rather than widening the sheet.
            ScrollView(.horizontal, showsIndicators: false) {
                SwiftUI.Text(code)
                    .font(Typography.code)
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .padding(Spacing.md)
            }
            .background(Palette.wash)
            .overlay { Rectangle().strokeBorder(Palette.rule, lineWidth: Spacing.hair) }
            // A 100-column block is core material here (PRODUCT.md), so the part
            // hanging off the right edge has to be reachable without a trackpad.
            // Focus is what puts a scroll view in the responder chain, and macOS
            // 14 draws the ring around it, so the stop is visible as well as
            // reachable.
            .focusable()
            // `.contain` rather than `.combine`: the code itself stays one
            // navigable element, and the group only announces what it is, which
            // is the thing a reader cannot infer from a monospaced voice.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(language.map { "\($0) code" } ?? "Code")

        case let .table(head, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: Spacing.lg, verticalSpacing: Spacing.sm) {
                    GridRow {
                        ForEach(Array(head.enumerated()), id: \.offset) { _, cell in
                            SwiftUI.Text(cell)
                                .font(Typography.uiBold)
                                .foregroundStyle(Palette.ink)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                    Rectangle().fill(Palette.rule).frame(height: Spacing.hair)
                        .gridCellColumns(max(head.count, 1))
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                                SwiftUI.Text(cell)
                                    .font(Typography.ui)
                                    .foregroundStyle(Palette.inkSoft)
                                    // A six-column complexity table read cell by
                                    // cell is six numbers with nothing saying
                                    // which column each came from, and combining
                                    // the row instead makes one run-on sentence.
                                    // Carrying the header into the cell is what
                                    // keeps "O(log n)" attached to "Average".
                                    .accessibilityLabel(
                                        column < head.count && !head[column].isEmpty
                                            ? "\(head[column]), \(cell)"
                                            : cell)
                            }
                        }
                    }
                }
                .padding(.vertical, Spacing.sm)
            }

        case .rule:
            Rectangle()
                .fill(Palette.rule)
                .frame(maxWidth: measure)
                .frame(height: Spacing.hair)
                .padding(.vertical, Spacing.sm)
        }
    }
}

/// An Obsidian callout, set as a determination slip rather than a coloured box.
private struct CalloutBlock: View {
    let kind: String
    let title: String
    let paragraphs: [AttributedString]
    let measure: CGFloat

    /// `important` and `warning` are the two kinds Obsidian's callouts use for
    /// examinable material; every other kind is a plain slip, so the mark keeps
    /// meaning something.
    private var isExaminable: Bool {
        kind == "important" || kind == "warning"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                if isExaminable {
                    Circle()
                        .fill(Palette.stamp)
                        .frame(width: Spacing.sm, height: Spacing.sm)
                        .accessibilityHidden(true)
                }
                // The slip sits on `wash`, and `stamp` is never text on `wash`
                // (3.80:1 in dark, under the 4.5:1 floor — DESIGN.md §2, §7).
                // The pigment stays on the disc and the left rule, which are
                // marks and legal on any plane; the title takes the value step
                // from `inkSoft` to `ink` instead.
                SwiftUI.Text(title.isEmpty ? kind.capitalized : title)
                    .font(Typography.caption.smallCaps())
                    .tracking(Typography.captionTracking)
                    .foregroundStyle(isExaminable ? Palette.ink : Palette.inkSoft)
            }
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                SwiftUI.Text(paragraph)
                    .font(Typography.bodyText)
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: measure, alignment: .leading)
        .background(Palette.wash)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isExaminable ? Palette.stamp : Palette.rule)
                .frame(width: Spacing.plateBorderOuter)
                .padding(.vertical, Spacing.hair)
                .padding(.leading, Spacing.hair)
        }
        // Colour alone never carries the meaning: the slip is titled, so an
        // examinable note reads as examinable in greyscale too.
        //
        // `.contain`, not `.combine`. Combining flattened the slip into one
        // element and the label below then replaced it outright, so the body
        // paragraphs — the part that is actually on the exam — were spoken
        // nowhere. As a labelled group the title announces the slip and the
        // paragraphs stay navigable inside it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isExaminable ? "Likely on exam. \(title)" : title)
    }
}
