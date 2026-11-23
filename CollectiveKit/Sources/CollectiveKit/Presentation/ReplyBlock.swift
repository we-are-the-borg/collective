import Foundation
import Markdown

/// A block of an agent's reply as the reply views lay it out, parsed once for
/// the popover's SwiftUI renderer. Apart from any UI so the conversion from
/// Markdown can be tested on its own.
public enum ReplyBlock: Equatable, Sendable {
    case paragraph([ReplyRun])
    /// Any level: shown like a paragraph, only semibold.
    case heading([ReplyRun])
    case list([ReplyListItem])
    case quote([ReplyBlock])
    /// The code without its language, which the view does not show.
    case code(String)
    case table(header: [[ReplyRun]], rows: [[[ReplyRun]]])
}

/// One list item: its marker ("•" or "3.") and its blocks, among them any
/// nested list, so the depth is the structure itself.
public struct ReplyListItem: Equatable, Sendable {
    public var marker: String
    public var blocks: [ReplyBlock]

    public init(marker: String, blocks: [ReplyBlock]) {
        self.marker = marker
        self.blocks = blocks
    }
}

/// A stretch of inline text with one look. Adjacent text of the same look is
/// one run, however the parser split it.
public struct ReplyRun: Equatable, Sendable {
    public var text: String
    public var isStrong = false
    public var isEmphasis = false
    public var isCode = false
    public var link: URL?

    public init(_ text: String, isStrong: Bool = false, isEmphasis: Bool = false, isCode: Bool = false, link: URL? = nil) {
        self.text = text
        self.isStrong = isStrong
        self.isEmphasis = isEmphasis
        self.isCode = isCode
        self.link = link
    }

    func hasSameLook(as other: ReplyRun) -> Bool {
        isStrong == other.isStrong && isEmphasis == other.isEmphasis && isCode == other.isCode && link == other.link
    }
}

extension ReplyBlock {
    /// The reply's blocks in document order. Only for replies the Kit lets be
    /// parsed (`ReplyPreview.rendersAsPlainText` is false): the walk recurses
    /// once per level of nesting, which `MarkdownNesting` bounds.
    public static func blocks(from markdown: String) -> [ReplyBlock] {
        blocks(in: Document(parsing: markdown))
    }

    private static func blocks(in container: any Markup) -> [ReplyBlock] {
        container.children.compactMap(block(from:))
    }

    private static func block(from markup: any Markup) -> ReplyBlock? {
        switch markup {
        case let paragraph as Paragraph:
            let content = runs(in: paragraph)
            // An image without alt text leaves nothing to show.
            return content.isEmpty ? nil : .paragraph(content)
        case let heading as Heading:
            let content = runs(in: heading)
            return content.isEmpty ? nil : .heading(content)
        case let list as UnorderedList:
            return .list(list.listItems.map { ReplyListItem(marker: "•", blocks: blocks(in: $0)) })
        case let list as OrderedList:
            return .list(list.listItems.enumerated().map { offset, item in
                ReplyListItem(marker: "\(list.startIndex + UInt(offset)).", blocks: blocks(in: item))
            })
        case let quote as BlockQuote:
            return .quote(blocks(in: quote))
        case let code as CodeBlock:
            return .code(trimmingTrailingNewlines(code.code))
        case let table as Table:
            return .table(
                header: table.head.cells.map { runs(in: $0) },
                rows: table.body.rows.map { row in row.cells.map { runs(in: $0) } }
            )
        case let html as HTMLBlock:
            let text = trimmingTrailingNewlines(html.rawHTML)
            return text.isEmpty ? nil : .paragraph([ReplyRun(text)])
        default:
            // Thematic breaks and whatever the parser learns later.
            return nil
        }
    }

    private static func runs(in container: any Markup) -> [ReplyRun] {
        var runs: [ReplyRun] = []
        appendRuns(of: container, look: ReplyRun(""), to: &runs)
        return linkingBareURLs(in: runs)
    }

    /// Finds bare URLs in plain text. Made once and shared; `NSDataDetector` is
    /// `Sendable` and its matching is thread-safe, so the cache may parse
    /// replies on any thread.
    private static let urlDetector = try! NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    /// swift-markdown does not autolink a bare URL, so plain text gets its URLs
    /// as link runs here; the text itself stays as written, so a copy is
    /// unchanged. Done on the merged runs, not per `Text` node, so a URL the
    /// parser may have split over several nodes is found whole. Only URLs written with
    /// `http://` or `https://`: the detector also finds `github.com/x` (adding
    /// a scheme) and mail addresses, which stay text to keep this simple.
    /// Inline code and existing links are left alone; code blocks never get here.
    private static func linkingBareURLs(in runs: [ReplyRun]) -> [ReplyRun] {
        var result: [ReplyRun] = []
        for run in runs {
            guard run.link == nil, !run.isCode else {
                append(run.text, look: run, to: &result)
                continue
            }
            let text = run.text
            var start = text.startIndex
            let matches = urlDetector.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
            for match in matches {
                guard let range = Range(match.range, in: text), range.lowerBound >= start else { continue }
                let written = String(text[range])
                let scheme = written.prefix(8).lowercased()
                guard scheme.hasPrefix("http://") || scheme.hasPrefix("https://"),
                      let url = URL(string: written) ?? match.url
                else { continue }
                append(String(text[start..<range.lowerBound]), look: run, to: &result)
                var linked = run
                linked.link = url
                append(written, look: linked, to: &result)
                start = range.upperBound
            }
            append(String(text[start...]), look: run, to: &result)
        }
        return result
    }

    /// `look` is the run the children's text inherits: the emphasis, link and
    /// so on of the markup around them.
    private static func appendRuns(of container: any Markup, look: ReplyRun, to runs: inout [ReplyRun]) {
        for child in container.children {
            var inner = look
            switch child {
            case let text as Markdown.Text:
                append(text.string, look: look, to: &runs)
            case let code as InlineCode:
                inner.isCode = true
                append(code.code, look: inner, to: &runs)
            case is SoftBreak:
                append(" ", look: look, to: &runs)
            case is LineBreak:
                append("\n", look: look, to: &runs)
            case let html as InlineHTML:
                append(html.rawHTML, look: look, to: &runs)
            case is Strong:
                inner.isStrong = true
                appendRuns(of: child, look: inner, to: &runs)
            case is Emphasis:
                inner.isEmphasis = true
                appendRuns(of: child, look: inner, to: &runs)
            case let link as Markdown.Link:
                inner.link = link.destination.flatMap { URL(string: $0) }
                appendRuns(of: child, look: inner, to: &runs)
            default:
                // Images (their children are the alt text), strikethrough and
                // whatever the parser learns later: their text as it is.
                appendRuns(of: child, look: look, to: &runs)
            }
        }
    }

    private static func append(_ text: String, look: ReplyRun, to runs: inout [ReplyRun]) {
        guard !text.isEmpty else { return }
        if let last = runs.last, last.hasSameLook(as: look) {
            runs[runs.count - 1].text += text
        } else {
            var run = look
            run.text = text
            runs.append(run)
        }
    }

    private static func trimmingTrailingNewlines(_ text: String) -> String {
        var text = Substring(text)
        while text.last?.isNewline == true { text = text.dropLast() }
        return String(text)
    }
}
