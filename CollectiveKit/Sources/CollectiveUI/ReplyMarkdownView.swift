import CollectiveKit
import SwiftUI
import Synchronization

/// Text metrics and role of a reply's rendered text.
struct ReplyTextStyle: Equatable, Sendable {
    let fontSize: CGFloat
    let lineHeight: CGFloat
    let role: ThemeRole

    /// The reply card's reply: the same size, in `--text`, as the card stands apart from the row.
    static let card = ReplyTextStyle(fontSize: 12, lineHeight: 17, role: .text)
    /// The Release Notes sheet's notes: text to read, so Plex Sans 12.5/18 in `--text-muted`.
    static let releaseNotes = ReplyTextStyle(fontSize: 12.5, lineHeight: 18, role: .textMuted)
}

/// An agent's reply rendered from its Markdown: blocks stacked 5 apart,
/// selectable as text, in Plex and theme roles only. Parsed when the
/// view is made, never in `body`, and through `ReplyBlockCache`, since the
/// popover remakes its views with every event.
struct ReplyMarkdownView: View {
    /// Between blocks and between list items.
    nonisolated static let blockSpacing: CGFloat = 5

    private let blocks: [ReplyBlock]
    private let style: ReplyTextStyle
    @Environment(\.theme) private var theme

    /// - Parameter rendersAsPlainText: The Kit's verdict that the reply must not
    ///   be parsed (`ReplyPreview.rendersAsPlainText`): shown as it is instead.
    init(_ text: String, rendersAsPlainText: Bool, style: ReplyTextStyle) {
        blocks = Self.content(for: text, rendersAsPlainText: rendersAsPlainText)
        self.style = style
    }

    /// Blocks the Kit parsed already, as the release notes are; they skip the cache.
    init(blocks: [ReplyBlock], style: ReplyTextStyle) {
        self.blocks = blocks
        self.style = style
    }

    var body: some View {
        ReplyBlockStack(blocks: blocks, metrics: ReplyMetrics(style: style, theme: theme))
            .foregroundStyle(.role(style.role))
            .textSelection(.enabled)
    }

    /// The blocks to show. A reply that must not be parsed never reaches the
    /// parser: it is one paragraph of its raw text.
    nonisolated static func content(
        for text: String, rendersAsPlainText: Bool, cache: ReplyBlockCache = .shared
    ) -> [ReplyBlock] {
        rendersAsPlainText ? [.paragraph([ReplyRun(text)])] : cache.blocks(for: text)
    }
}

/// The parsed blocks of the replies shown lately, keyed by the whole text. The
/// popover remakes its views with every event, so an open reply of 64 kB would
/// otherwise be parsed again each time.
///
/// Least recently used goes first, and a hit counts as a use. SwiftUI makes
/// these views without a build boundary the cache could see, so it cannot keep
/// exactly the working set as `ReplyPreviewCache` does; but every reply on
/// screen is read again with every remake, so with limits far above what a popover
/// shows the visible ones are always the most recent and never evicted, while
/// replies that left the popover age out. Bounded by entries and by the bytes
/// of the keys, since a key is a whole reply of up to 64 kB.
final class ReplyBlockCache: Sendable {
    static let shared = ReplyBlockCache()

    private struct Entry {
        let blocks: [ReplyBlock]
        var lastUse: UInt64
    }

    private struct State {
        var entries: [String: Entry] = [:]
        /// UTF-8 bytes of all keys.
        var keyBytes = 0
        /// Counts every read, so the smallest `lastUse` is the least recent.
        var clock: UInt64 = 0
        var parseCount = 0
    }

    private let state = Mutex(State())
    private let entryLimit: Int
    private let byteLimit: Int

    /// - Parameters:
    ///   - entryLimit: Far above the replies a popover shows at once.
    ///   - byteLimit: Total UTF-8 bytes of the cached reply texts.
    init(entryLimit: Int = 512, byteLimit: Int = 8 * 1024 * 1024) {
        self.entryLimit = entryLimit
        self.byteLimit = byteLimit
    }

    /// How many replies were parsed rather than found, for the tests.
    var parseCount: Int { state.withLock(\.parseCount) }

    func blocks(for text: String) -> [ReplyBlock] {
        let hit: [ReplyBlock]? = state.withLock { state in
            guard var entry = state.entries[text] else { return nil }
            state.clock &+= 1
            entry.lastUse = state.clock
            state.entries[text] = entry
            return entry.blocks
        }
        if let hit { return hit }
        // Parsed outside the lock; two callers may both parse one new reply,
        // but both get the same blocks.
        let blocks = ReplyBlock.blocks(from: text)
        state.withLock { state in
            state.parseCount += 1
            state.clock &+= 1
            if state.entries.updateValue(Entry(blocks: blocks, lastUse: state.clock), forKey: text) == nil {
                state.keyBytes += text.utf8.count
            }
            // The new entry is the most recent, so it goes last; a scan per
            // eviction is cheap at a few hundred entries and only on a parse.
            while state.entries.count > 1,
                  state.entries.count > self.entryLimit || state.keyBytes > self.byteLimit,
                  let oldest = state.entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
                state.entries[oldest] = nil
                state.keyBytes -= oldest.utf8.count
            }
        }
        return blocks
    }
}

/// Sizes and line spacing the blocks share, derived once from the style.
private struct ReplyMetrics {
    let fontSize: CGFloat
    let lineHeight: CGFloat
    /// Added between lines so they are `lineHeight` apart; half of it above the
    /// first line and below the last keeps every line that high.
    let textSpacing: CGFloat
    let codeSpacing: CGFloat
    let tableSpacing: CGFloat
    /// Behind inline code; `Color`s rather than styles, since the renderer and
    /// an attributed run take no `ShapeStyle`.
    let codeFill: Color
    let link: Color

    /// Code blocks and tables: Plex Mono 11 and Plex Sans 11, both 15 high.
    static let smallSize: CGFloat = 11
    static let smallLineHeight: CGFloat = 15
    /// Inline code: the Plex Mono size the row's details and command box use beside 12 pt text.
    static let inlineCodeSize: CGFloat = 11.5

    init(style: ReplyTextStyle, theme: Theme) {
        fontSize = style.fontSize
        lineHeight = style.lineHeight
        codeFill = Color(theme.roles[RowDetail.boxSurfaceRole])
        link = Color(theme.roles[.accent])
        textSpacing = Self.spacing(lineHeight: style.lineHeight, size: style.fontSize, mono: false)
        codeSpacing = Self.spacing(lineHeight: Self.smallLineHeight, size: Self.smallSize, mono: true)
        tableSpacing = Self.spacing(lineHeight: Self.smallLineHeight, size: Self.smallSize, mono: false)
    }

    /// The difference to the face's natural line height.
    private static func spacing(lineHeight: CGFloat, size: CGFloat, mono: Bool) -> CGFloat {
        max(0, lineHeight - PlexMetrics.naturalLineHeight(size: size, mono: mono))
    }

    /// The runs as one `Text`, every run with its own font, so bold, italic
    /// and code mix within a line. Concatenated rather than one attributed
    /// string: only a `Text` carries the custom attribute that
    /// `InlineCodeRenderer` draws the code's fill behind.
    static func text(
        _ runs: [ReplyRun], size: CGFloat, link: Color, isSemibold: Bool = false, isMonospacedDigit: Bool = false
    ) -> Text {
        var result: Text?
        let tracked = InlineCodeFill.tracksLastCharacter(codeFlags: runs.map(\.isCode))
        for (index, run) in runs.enumerated() {
            var part = attributed(run, size: size, link: link, isSemibold: isSemibold, isMonospacedDigit: isMonospacedDigit)
            // Tracking widens a character without inserting one, so the text,
            // its copy and its line height stay the same, and neighbours keep
            // clear of the fill. Tracking adds its space after the character,
            // also at the end of the text, where kerning between a pair has no
            // second character.
            if tracked[index], let last = part.characters.indices.last {
                part[last...][AttributeScopes.SwiftUIAttributes.TrackingAttribute.self] = InlineCodeFill.padding
            }
            var segment = Text(part)
            if run.isCode { segment = segment.customAttribute(InlineCodeAttribute()) }
            result = result.map { $0 + segment } ?? segment
        }
        return result ?? Text(verbatim: "")
    }

    private static func attributed(
        _ run: ReplyRun, size: CGFloat, link: Color, isSemibold: Bool, isMonospacedDigit: Bool
    ) -> AttributedString {
        var part = AttributedString(run.text)
        let isBold = isSemibold || run.isStrong
        // Plex Mono comes in regular and medium only, so bold code is medium,
        // and emphasized code stays upright.
        var font: Font = run.isCode
            ? .plexMono(size == smallSize ? smallSize : inlineCodeSize, weight: isBold ? .medium : .regular)
            : .plexSans(size, weight: isBold ? .semibold : .regular, italic: run.isEmphasis)
        if isMonospacedDigit { font = font.monospacedDigit() }
        part[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = font
        if let url = run.link {
            // `Text` opens it through `openURL`, in the default browser.
            part[AttributeScopes.FoundationAttributes.LinkAttribute.self] = url
            part[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = link
        }
        return part
    }
}

private struct ReplyBlockStack: View {
    let blocks: [ReplyBlock]
    let metrics: ReplyMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: ReplyMarkdownView.blockSpacing) {
            ForEach(blocks.indices, id: \.self) { index in
                ReplyBlockView(block: blocks[index], metrics: metrics)
            }
        }
    }
}

private struct ReplyBlockView: View {
    let block: ReplyBlock
    let metrics: ReplyMetrics

    var body: some View {
        switch block {
        case let .paragraph(runs):
            ReplyParagraph(runs: runs, isHeading: false, metrics: metrics)
        case let .heading(runs):
            ReplyParagraph(runs: runs, isHeading: true, metrics: metrics)
        case let .list(items):
            VStack(alignment: .leading, spacing: ReplyMarkdownView.blockSpacing) {
                ForEach(items.indices, id: \.self) { index in
                    ReplyListItemView(item: items[index], metrics: metrics)
                }
            }
        case let .quote(blocks):
            ReplyBlockStack(blocks: blocks, metrics: metrics)
                .foregroundStyle(.role(.textSubtle))
                .padding(.leading, 2 + 8)
                .background(alignment: .leading) {
                    Rectangle().fill(.role(.border)).frame(width: 2)
                }
        case let .code(code):
            ReplyCodeBlock(code: code, metrics: metrics)
        case let .table(header, rows):
            ReplyTable(header: header, rows: rows, metrics: metrics)
        }
    }
}

/// A paragraph or heading: body size, headings semibold.
private struct ReplyParagraph: View {
    let runs: [ReplyRun]
    let isHeading: Bool
    let metrics: ReplyMetrics

    var body: some View {
        ReplyMetrics.text(runs, size: metrics.fontSize, link: metrics.link, isSemibold: isHeading)
            .font(.plexSans(metrics.fontSize))
            .lineSpacing(metrics.textSpacing)
            .textRenderer(InlineCodeRenderer(lineHeight: metrics.lineHeight, fill: metrics.codeFill))
            .padding(.vertical, metrics.textSpacing / 2)
            // Every line stays visible; a multi-line Text reports a one-line minimum height.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Marker column at least 10 wide, 6 to the text; a nested list sits in the
/// text column, so it is indented 16.
private struct ReplyListItemView: View {
    let item: ReplyListItem
    let metrics: ReplyMetrics

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.marker)
                .font(.plexSans(metrics.fontSize))
                .foregroundStyle(.role(.textSubtle))
                .padding(.vertical, metrics.textSpacing / 2)
                .frame(minWidth: 10, alignment: .leading)
            ReplyBlockStack(blocks: item.blocks, metrics: metrics)
        }
    }
}

/// Unwrapped and scrolling sideways, without syntax colors or language tag,
/// in the command box's look: `--text` on `--surface-sunken` in a 1 px `--border` frame.
private struct ReplyCodeBlock: View {
    let code: String
    let metrics: ReplyMetrics

    var body: some View {
        ScrollView(.horizontal) {
            text
                .fixedSize()
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.role(.text))
        .rowBox()
    }

    private var text: some View {
        Text(code)
            .font(.plexMono(ReplyMetrics.smallSize))
            .lineSpacing(metrics.codeSpacing)
            .padding(.vertical, metrics.codeSpacing / 2)
    }
}

/// Columns 14 apart, a hairline above every row, scrolling sideways.
private struct ReplyTable: View {
    let header: [[ReplyRun]]
    let rows: [[[ReplyRun]]]
    let metrics: ReplyMetrics

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        cell(header[column], isHeader: true)
                            .foregroundStyle(.role(.textSubtle))
                            .padding(.bottom, 3)
                    }
                }
                ForEach(rows.indices, id: \.self) { row in
                    Rectangle()
                        .fill(.role(.border))
                        .frame(height: 1)
                        .gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(rows[row].indices, id: \.self) { column in
                            cell(rows[row][column], isHeader: false)
                                .padding(.vertical, 3)
                        }
                    }
                }
            }
            .fixedSize()
            // Room for a code fill at a cell's line start, which reaches
            // beyond the text; the scroll view widens by as much.
            .padding(.leading, InlineCodeFill.padding)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        // The scroll view clips 3 pt further left, the table stays where it was.
        .padding(.leading, -InlineCodeFill.padding)
    }

    private func cell(_ runs: [ReplyRun], isHeader: Bool) -> some View {
        ReplyMetrics.text(runs, size: ReplyMetrics.smallSize, link: metrics.link, isSemibold: isHeader, isMonospacedDigit: true)
            .font(.plexSans(ReplyMetrics.smallSize).monospacedDigit())
            .lineSpacing(metrics.tableSpacing)
            .textRenderer(InlineCodeRenderer(lineHeight: ReplyMetrics.smallLineHeight, fill: metrics.codeFill))
            .padding(.vertical, metrics.tableSpacing / 2)
    }
}

#if DEBUG
private let sampleReply = """
## Summary

The build is **green** again after the fix in `ReplyPreview.swift`, see [the issue](https://example.com/issues/53).

`swift test` passes, the fill of code at a line start reaches beyond the text.

- Parser
  - Nested lists keep their depth
  - Tables keep their cells
- Renderer

> The quote is subtle text with a bar.

```swift
let blocks = ReplyBlock.blocks(from: reply) // a long line that scrolls sideways
```

| File | Lines |
|---|---:|
| ReplyBlock.swift | 140 |
| ReplyMarkdownView.swift | 260 |

| Type | Role |
|---|---|
| `InlineCodeFill` | Fill geometry |
| `InlineCodeRenderer` | Draws the fill |
"""

private struct ReplyMarkdownPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ReplyMarkdownView(sampleReply, rendersAsPlainText: false, style: .card)
        }
        .frame(width: 330)
        .padding()
        .background(.role(.surface))
    }
}

#Preview("ReplyMarkdownView · light") { ReplyMarkdownPreview().preferredColorScheme(.light) }
#Preview("ReplyMarkdownView · dark") { ReplyMarkdownPreview().preferredColorScheme(.dark) }
#endif
