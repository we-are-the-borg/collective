import Foundation
import Markdown
import Synchronization

/// An agent's reply as the popover shows it while the reply is closed: plain
/// text without Markdown. The reply itself is rendered only once it is opened,
/// so the preview keeps what reads as a sentence and drops what needs layout
/// (headings, code blocks, tables, images).
public struct ReplyPreview: Equatable, Sendable {
    /// The preview's blocks in document order, each a single line: paragraphs,
    /// list items ("• item", "1. item"), block quotes and raw HTML as text.
    /// Empty when the reply holds nothing a preview can show (only a rule, or
    /// images without alt text); the reply still exists and can be opened.
    /// Images appear only as a last resort, when nothing else is left: their
    /// alt texts in document order, joined by a space, as one block of
    /// ordinary text.
    public let blocks: [String]

    /// The reply has no text of its own, so `blocks` holds the first line of
    /// its first code block or the header row of its first table, whichever
    /// comes first. Shown monospaced and always treated as long.
    public let isCodeOrTableFallback: Bool

    /// The reply consists of paragraphs and list items only, so the preview
    /// already says everything: the precondition for showing it without a way
    /// to open it. Whether it also fits the available height is the layout's
    /// call.
    public let isOnlyParagraphsAndLists: Bool

    /// The reply nests deeper than a Markdown parser can take without
    /// overflowing the stack, or makes a tree larger than it converts in
    /// time (`MarkdownNesting`). Views must not parse this reply as Markdown
    /// when true, and show its text as it is instead. Decided for the whole
    /// reply, not only for the part the preview reads. A reply larger than
    /// `markdownLimit` counts as too much without being measured.
    public let rendersAsPlainText: Bool

    /// How much of a reply the preview parses, in UTF-8 bytes. A closed reply
    /// shows four lines at most (the Idle preview; the card excerpt shows two,
    /// a finished row one), which this covers a hundred times over,
    /// while a preview stays within three frames whatever the reply holds,
    /// since `MarkdownNesting` turns down what would cost more. Of what it
    /// lets pass, the slowest that was found is a table padded right up to
    /// its limits: 37 ms in a release build (93 ms in a debug build). Text
    /// without a table took 17 ms (43) at most.
    static let parsedLimit = 8 * 1024

    /// The largest reply that is still rendered as Markdown, in UTF-8 bytes.
    /// An open reply scrolls in a box 240 pt high: 64 kB are more than a
    /// thousand lines of it, far beyond the reports agents write. What a
    /// view converts of it is bounded by `MarkdownNesting.nodeLimit`, not by
    /// this. Measuring a reply is a parse of the whole of it by cmark-gfm:
    /// 12 ms at most for 64 kB in a release build (28 ms in a debug build),
    /// which with the preview of its beginning made 48 ms (121) for the
    /// slowest reply that was found, but 130 ms for a megabyte of the deepest
    /// nesting and half a second for four.
    static let markdownLimit = 64 * 1024

    /// `nil` when the reply is empty after trimming: nothing is shown then.
    public init?(_ reply: String) {
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let prefix = Self.parsedPrefix(of: reply)
        let isCut = prefix.endIndex < reply.endIndex
        let isWhole = !isCut && prefix.startIndex == reply.startIndex
        let isTooLarge = reply.utf8.count > Self.markdownLimit
        // Measured whole unless the prefix is the whole reply, which is
        // measured below, or the reply is too large to render anyway.
        let restNestsTooDeep = !isWhole && !isTooLarge && MarkdownNesting.exceedsLimit(reply)
        // A prefix can read deeper than the whole, so it is measured itself.
        let document = restNestsTooDeep ? nil : Self.document(parsing: String(prefix))
        rendersAsPlainText = isTooLarge || restNestsTooDeep || (isWhole && document == nil)
        guard let document else {
            // Not parsed at all: its lines as they are.
            blocks = Self.lines(of: prefix, in: reply)
            isCodeOrTableFallback = false
            isOnlyParagraphsAndLists = false
            return
        }
        var collector = Collector()
        collector.collect(childrenOf: document)
        if !collector.text.isEmpty {
            blocks = collector.text
            isCodeOrTableFallback = false
            // A reply too long to be parsed whole is never short.
            isOnlyParagraphsAndLists = collector.isOnlyParagraphsAndLists && !isCut
        } else if let first = collector.codeOrTable.first {
            blocks = [first]
            isCodeOrTableFallback = true
            isOnlyParagraphsAndLists = false
        } else if !collector.headings.isEmpty {
            // Only headings left: better their text than a blank preview.
            blocks = collector.headings
            isCodeOrTableFallback = false
            isOnlyParagraphsAndLists = false
        } else if !collector.imageAlts.isEmpty {
            // An image-only reply: the alt text is what Markdown offers where
            // the image cannot show. Not the code styling: it is ordinary text.
            blocks = [collector.imageAlts.joined(separator: " ")]
            isCodeOrTableFallback = false
            isOnlyParagraphsAndLists = false
        } else if !isCut {
            blocks = []
            isCodeOrTableFallback = false
            isOnlyParagraphsAndLists = false
        } else {
            // Nothing to show in the part that was read, which says nothing
            // about the rest: its lines as they are, rather than no reply.
            blocks = Self.lines(of: prefix, in: reply)
            isCodeOrTableFallback = false
            isOnlyParagraphsAndLists = false
        }
    }

    /// The parsed text, or `nil` when it nests too deep or makes too large a
    /// tree to be parsed. The only place a reply is handed to the parser, so
    /// that what is parsed is always the very string that was measured,
    /// whatever led here.
    private static func document(parsing text: String) -> Document? {
        MarkdownNesting.exceedsLimit(text) ? nil : Document(parsing: text)
    }

    /// The prefix line by line without parsing it, blank lines left out. A
    /// prefix of nothing but whitespace says nothing about a reply that has
    /// text: the lines are then read from where that text begins. That is
    /// looked for scalar by scalar: a mark joined to the last space makes one
    /// character with it, which counts as whitespace like the space alone.
    /// ASCII is told from its byte alone, since asking every scalar for its
    /// properties took 40 ms for each megabyte of spaces, at every launch.
    private static func lines(of prefix: Substring, in reply: String) -> [String] {
        let lines = lines(of: prefix)
        guard lines.isEmpty else { return lines }
        let utf8 = reply.utf8, scalars = reply.unicodeScalars
        var text = prefix.endIndex
        while text < utf8.endIndex {
            let byte = utf8[text]
            if byte < 0x80 {
                // Tab to carriage return and the space: all of ASCII that is whitespace.
                guard 0x09...0x0D ~= byte || byte == 0x20 else { break }
                text = utf8.index(after: text)
            } else {
                guard scalars[text].properties.isWhitespace else { break }
                text = scalars.index(after: text)
            }
        }
        guard text < reply.endIndex else { return lines }
        return Self.lines(of: bounded(reply, from: text))
    }

    /// The text line by line without parsing it, blank lines left out.
    private static func lines(of text: Substring) -> [String] {
        text.split(whereSeparator: \.isNewline).map { Collector.singleLine(String($0)) }.filter { !$0.isEmpty }
    }

    /// The reply up to `parsedLimit`, see `bounded(_:from:)`. Blank lines at
    /// the start mean nothing to Markdown and are left out before measuring,
    /// however many there are. Blank is what cmark takes for blank (spaces,
    /// tabs and line endings): any other separator is text to it, and the
    /// prefix has to begin where the parser sees the text begin.
    private static func parsedPrefix(of reply: String) -> Substring {
        guard reply.utf8.count > parsedLimit else { return reply[...] }
        let utf8 = reply.utf8
        let blank = utf8.prefix { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        let start = blank.lastIndex { $0 == 0x0A || $0 == 0x0D }.map(utf8.index(after:)) ?? reply.startIndex
        return bounded(reply, from: start)
    }

    /// The reply from `start` up to `parsedLimit`, cut after a whole line so
    /// that no block before the cut reads differently. That holds while the
    /// whole lines fill at least half of the limit. Below that the line the
    /// limit falls into is a long one, and may be all there is to preview
    /// after a blank line or a heading: it is cut between two characters
    /// instead, and a single character larger than what is left between two
    /// of its scalars.
    private static func bounded(_ reply: String, from start: String.Index) -> Substring {
        let utf8 = reply.utf8[start...]
        guard utf8.count > parsedLimit else { return reply[start...] }
        let limit = utf8.index(start, offsetBy: parsedLimit)
        let lineEnd = utf8[..<limit].lastIndex { $0 == 0x0A || $0 == 0x0D }
        if let lineEnd, utf8.distance(from: start, to: lineEnd) >= parsedLimit / 2 {
            return reply[start..<lineEnd]
        }
        let lineStart = lineEnd.map(utf8.index(after:)) ?? start
        var cut = lineStart
        while case let next = reply.index(after: cut), next <= limit { cut = next }
        if cut == lineStart {
            // Not one character fits: back to where a scalar starts.
            cut = limit
            while utf8[cut] & 0xC0 == 0x80 { cut = utf8.index(before: cut) }
        }
        return reply[start..<cut]
    }

    /// The preview of a session card: one block per line.
    public var multiline: String { blocks.joined(separator: "\n") }

    /// The preview of a subagent or finished row: all blocks on one line.
    public var singleLine: String { blocks.joined(separator: " ") }
}

/// Parsed previews retained for one popover's current working set. The app
/// owns one cache and passes it into every rebuild; each build records only the
/// replies it actually represents, then drops previews that left the popover.
/// This bounds the cache by current UI state without making a large current
/// set churn through an arbitrary entry limit.
public final class ReplyPreviewCache: Sendable {
    private struct State {
        /// Keyed by the whole text, so equal replies can share their parse.
        var entries: [String: ReplyPreview] = [:]
        var parseCount = 0
        var generation: UInt64 = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// How many replies were parsed rather than found, for the tests.
    var parseCount: Int { state.withLock(\.parseCount) }
    var retainedCount: Int { state.withLock { $0.entries.count } }

    /// One model build's independent record of the replies it uses. Keeping
    /// this set here rather than in the cache makes overlapping builds safe:
    /// either may finish first without changing what the other returns.
    final class Build: Sendable {
        private let cache: ReplyPreviewCache
        private let generation: UInt64
        private let used = Mutex<Set<String>>([])

        fileprivate init(cache: ReplyPreviewCache, generation: UInt64) {
            self.cache = cache
            self.generation = generation
        }

        func preview(of reply: String) -> ReplyPreview? {
            used.withLock { _ = $0.insert(reply) }
            return cache.preview(of: reply, generation: generation)
        }

        func finish() {
            cache.retain(used.withLock { $0 }, generation: generation)
        }
    }

    func beginBuild() -> Build {
        let generation = state.withLock { state in
            state.generation &+= 1
            return state.generation
        }
        return Build(cache: self, generation: generation)
    }

    private func preview(of reply: String, generation: UInt64) -> ReplyPreview? {
        let hit = state.withLock { $0.entries[reply] }
        if let hit { return hit }
        // Parsed outside the lock; overlapping builds may both parse one new
        // reply, but each receives the same immutable value.
        let preview = ReplyPreview(reply)
        state.withLock { state in
            state.parseCount += 1
            if generation == state.generation, let preview { state.entries[reply] = preview }
        }
        return preview
    }

    private func retain(_ replies: Set<String>, generation: UInt64) {
        state.withLock { state in
            guard generation == state.generation else { return }
            state.entries = state.entries.filter { replies.contains($0.key) }
        }
    }
}

/// Walks the parsed reply once and sorts what it finds into the three things
/// a preview can be made of. The walk recurses once per level of nesting, like
/// the parser before it: `MarkdownNesting.limit` bounds both.
private struct Collector {
    var text: [String] = []
    var codeOrTable: [String] = []
    var headings: [String] = []
    /// Alt texts of the images, which the preview uses only as a last resort.
    var imageAlts: [String] = []
    var isOnlyParagraphsAndLists = true

    mutating func collect(childrenOf container: any Markup) {
        for child in container.children { collect(block: child) }
    }

    private mutating func collect(block: any Markup) {
        switch block {
        case let paragraph as Paragraph:
            append(plainText(of: paragraph), to: \.text)
        case let list as UnorderedList:
            for item in list.listItems { collect(item: item, marker: "•") }
        case let list as OrderedList:
            for (offset, item) in list.listItems.enumerated() {
                collect(item: item, marker: "\(list.startIndex + UInt(offset)).")
            }
        case let quote as BlockQuote:
            isOnlyParagraphsAndLists = false
            collect(childrenOf: quote)
        case let html as HTMLBlock:
            isOnlyParagraphsAndLists = false
            append(Self.singleLine(html.rawHTML), to: \.text)
        case let heading as Heading:
            isOnlyParagraphsAndLists = false
            append(plainText(of: heading), to: \.headings)
        case let code as CodeBlock:
            isOnlyParagraphsAndLists = false
            let lines = code.code.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            append(lines.first { !$0.isEmpty } ?? "", to: \.codeOrTable)
        case let table as Table:
            isOnlyParagraphsAndLists = false
            var cells: [String] = []
            for cell in table.head.cells { cells.append(plainText(of: cell)) }
            if cells.contains(where: { !$0.isEmpty }) {
                append(cells.joined(separator: "  "), to: \.codeOrTable)
            }
        default:
            // Thematic breaks and whatever the parser learns later.
            isOnlyParagraphsAndLists = false
        }
    }

    /// The item's own paragraphs make one block; anything else inside it
    /// (nested lists, quotes) follows as blocks of its own.
    private mutating func collect(item: ListItem, marker: String) {
        let position = text.count
        var own: [String] = []
        for child in item.children {
            if let paragraph = child as? Paragraph {
                own.append(plainText(of: paragraph))
            } else {
                collect(block: child)
            }
        }
        let line = own.filter { !$0.isEmpty }.joined(separator: " ")
        if !line.isEmpty { text.insert("\(marker) \(line)", at: position) }
    }

    private mutating func append(_ block: String, to list: WritableKeyPath<Collector, [String]>) {
        if !block.isEmpty { self[keyPath: list].append(block) }
    }

    private mutating func plainText(of container: any Markup) -> String {
        Self.singleLine(inlineText(of: container))
    }

    private mutating func inlineText(of container: any Markup) -> String {
        var result = ""
        for child in container.children {
            switch child {
            case let text as Markdown.Text: result += text.string
            case let code as InlineCode: result += code.code
            case let html as InlineHTML: result += html.rawHTML
            case is SoftBreak, is LineBreak: result += " "
            case let image as Markdown.Image:
                // Not even the alt text: it would read as part of the sentence.
                isOnlyParagraphsAndLists = false
                append(Self.singleLine(Self.altText(of: image)), to: \.imageAlts)
            default: result += inlineText(of: child)
            }
        }
        return result
    }

    /// The text an image stands for; an image inside it adds nothing.
    private static func altText(of container: any Markup) -> String {
        var result = ""
        for child in container.children {
            switch child {
            case let text as Markdown.Text: result += text.string
            case let code as InlineCode: result += code.code
            case is SoftBreak, is LineBreak: result += " "
            case is Markdown.Image: break
            default: result += altText(of: child)
            }
        }
        return result
    }

    /// Trims and folds every run of whitespace into one space, so a block
    /// stays one line however it was wrapped in the source.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
