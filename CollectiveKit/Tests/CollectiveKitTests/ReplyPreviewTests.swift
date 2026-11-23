import Testing
@testable import CollectiveKit

private func times(_ count: Int, _ unit: String) -> String { String(repeating: unit, count: count) }

private func cachedPreview(_ reply: String, in cache: ReplyPreviewCache) -> ReplyPreview? {
    let build = cache.beginBuild()
    defer { build.finish() }
    return build.preview(of: reply)
}

/// Replies that nest far deeper than any stack carries a parser.
private let hostileReplies: [(name: String, reply: String)] = [
    ("block quotes", times(100_000, ">") + " a"),
    ("block quotes with spaces", times(100_000, "> ") + "a"),
    ("lists on one line", times(20_000, "- ") + "a"),
    ("ordered lists on one line", times(20_000, "1. ") + "a"),
    ("lists by indentation", (0..<1_000).map { times($0, "  ") + "- a" }.joined(separator: "\n")),
    ("lists in quotes in lists", times(20_000, "> - ") + "a"),
    ("one run of asterisks", times(100_000, "*") + "a" + times(100_000, "*")),
    ("one run of underscores", times(100_000, "_") + "a" + times(100_000, "_")),
    ("nested emphasis", times(50_000, "*a ") + times(50_000, "a* ")),
    ("nested strong emphasis", times(50_000, "__a ") + times(50_000, "a__ ")),
    ("nested strikethrough", times(50_000, "~~a ") + times(50_000, "a~~ ")),
    ("nested images", times(50_000, "![") + "a" + times(50_000, "](u)")),
    ("links in images", times(25_000, "![[") + "a" + times(25_000, "](u)](u)")),
    ("emphasis in quotes in lists", times(5_000, "> - ") + times(50_000, "*a ") + times(50_000, "a* ")),
    ("deep only after a harmless start", "All tests pass.\n\n" + times(100_000, ">") + " a"),
]

/// Tables of few bytes that the parser pads to hundreds of thousands of
/// cells: every row gets as many as the header has.
private let paddedTables: [(name: String, reply: String)] = [
    ("150 columns, 3,700 rows in 8 kB", times(150, "|a") + "|\n" + times(150, "|-") + "|\n" + times(3_700, "a\n")),
    ("two tables of 512 columns and 1,020 rows in 8 kB", times(2, times(512, "|a") + "|\n" + times(512, "|-") + "|\n" + times(1_020, "a\n") + "\n")),
    ("sixteen such tables in 64 kB", times(16, times(512, "|a") + "|\n" + times(512, "|-") + "|\n" + times(1_020, "a\n") + "\n")),
]

/// Trees exactly as deep as the limit allows: the document, the paragraph
/// and the text count as well.
private let atTheLimit: [(String, String)] = [
    (times(21, ">") + " still Markdown", "still Markdown"),
    (times(20, ">") + " still *Markdown*", "still Markdown"),
    (times(10, "- ") + "still **Markdown**", "• still Markdown"),
    (times(42, "*") + "still Markdown" + times(42, "*"), "still Markdown"),
    (times(21, "![") + "x" + times(21, "](u)") + " still *Markdown*", "still Markdown"),
]

private let aboveTheLimit: [String] = [
    times(22, ">") + " no longer Markdown",
    times(21, ">") + " no longer *Markdown*",
    times(11, "- ") + "no longer Markdown",
    times(43, "*") + "no longer Markdown" + times(43, "*"),
    times(22, "![") + "x" + times(22, "](u)"),
]

/// A seeded generator, so a generated reply that fails fails every time.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("ReplyPreview")
struct ReplyPreviewTests {
    // MARK: - Missing reply

    @Test("An empty or whitespace-only reply has no preview", arguments: ["", "   ", "\n\n", " \t\n "])
    func emptyReply(reply: String) {
        #expect(ReplyPreview(reply) == nil)
    }

    // MARK: - Joining

    @Test("Blocks join with line breaks for a session and with spaces for a row")
    func joining() throws {
        let preview = try #require(ReplyPreview("First paragraph.\n\nSecond paragraph."))
        #expect(preview.blocks == ["First paragraph.", "Second paragraph."])
        #expect(preview.multiline == "First paragraph.\nSecond paragraph.")
        #expect(preview.singleLine == "First paragraph. Second paragraph.")
    }

    // MARK: - Dropped blocks

    @Test("A heading is dropped")
    func headingDropped() throws {
        let preview = try #require(ReplyPreview("# Summary\n\nAll tests pass."))
        #expect(preview.blocks == ["All tests pass."])
    }

    @Test("A fenced code block is dropped")
    func fencedCodeDropped() throws {
        let preview = try #require(ReplyPreview("Run this:\n\n```sh\nswift test\n```\n\nThen push."))
        #expect(preview.blocks == ["Run this:", "Then push."])
    }

    @Test("An indented code block is dropped")
    func indentedCodeDropped() throws {
        let preview = try #require(ReplyPreview("Run this:\n\n    swift test\n\nThen push."))
        #expect(preview.blocks == ["Run this:", "Then push."])
    }

    @Test("A table is dropped")
    func tableDropped() throws {
        let preview = try #require(ReplyPreview("Results:\n\n| File | Lines |\n| --- | --- |\n| a.swift | 12 |\n\nDone."))
        #expect(preview.blocks == ["Results:", "Done."])
    }

    @Test("An image is dropped, alt text included")
    func imageDropped() throws {
        let preview = try #require(ReplyPreview("Before.\n\n![Screenshot](shot.png)\n\nSee ![the icon](icon.png) here."))
        #expect(preview.blocks == ["Before.", "See here."])
        #expect(!preview.isOnlyParagraphsAndLists)
    }

    @Test("A thematic break is dropped")
    func thematicBreakDropped() throws {
        let preview = try #require(ReplyPreview("Above.\n\n---\n\nBelow."))
        #expect(preview.blocks == ["Above.", "Below."])
    }

    // MARK: - Lists and quotes

    @Test("Unordered list items get a bullet")
    func unorderedList() throws {
        let preview = try #require(ReplyPreview("- first\n- second\n* third"))
        #expect(preview.blocks == ["• first", "• second", "• third"])
    }

    @Test("Ordered list items keep their number")
    func orderedList() throws {
        let preview = try #require(ReplyPreview("1. first\n2. second\n3. third"))
        #expect(preview.blocks == ["1. first", "2. second", "3. third"])
    }

    @Test("An ordered list counts from its start number")
    func orderedListStart() throws {
        let preview = try #require(ReplyPreview("4. fourth\n5. fifth"))
        #expect(preview.blocks == ["4. fourth", "5. fifth"])
    }

    @Test("Nested list items follow their parent, without indentation")
    func nestedList() throws {
        let preview = try #require(ReplyPreview("- outer\n  1. inner one\n  2. inner two\n- last"))
        #expect(preview.blocks == ["• outer", "1. inner one", "2. inner two", "• last"])
    }

    @Test("A list item's paragraphs join with a space")
    func listItemParagraphs() throws {
        let preview = try #require(ReplyPreview("- first paragraph\n\n  second paragraph\n- next"))
        #expect(preview.blocks == ["• first paragraph second paragraph", "• next"])
    }

    @Test("A block quote contributes its text")
    func blockQuote() throws {
        let preview = try #require(ReplyPreview("You wrote:\n\n> keep it **simple**\n> and small"))
        #expect(preview.blocks == ["You wrote:", "keep it simple and small"])
    }

    // MARK: - Inline markup

    @Test("Inline markup is removed", arguments: [
        ("This is **strong** text.", "This is strong text."),
        ("This is __strong__ text.", "This is strong text."),
        ("This is *emphasised* text.", "This is emphasised text."),
        ("This is _emphasised_ text.", "This is emphasised text."),
        ("This is ~~struck~~ text.", "This is struck text."),
        ("Call `apply(event)` once.", "Call apply(event) once."),
        ("See [the contract](https://example.com/contract) first.", "See the contract first."),
        ("See <https://example.com/contract> first.", "See https://example.com/contract first."),
        ("first line\nsecond line", "first line second line"),
        ("first line  \nsecond line", "first line second line"),
        ("first line\\\nsecond line", "first line second line"),
        ("Press <kbd>Esc</kbd> to close.", "Press <kbd>Esc</kbd> to close."),
        ("A ***`nested`*** [**link**](https://example.com).", "A nested link."),
    ])
    func inlineMarkup(reply: String, shown: String) throws {
        let preview = try #require(ReplyPreview(reply))
        #expect(preview.blocks == [shown])
    }

    @Test("A raw HTML block stays as text")
    func htmlBlock() throws {
        let preview = try #require(ReplyPreview("<details>\n<summary>Log</summary>\n</details>"))
        #expect(preview.blocks == ["<details> <summary>Log</summary> </details>"])
    }

    // MARK: - Code or table only

    @Test("A reply of code only shows the first code line")
    func codeOnly() throws {
        let preview = try #require(ReplyPreview("```swift\n\n    let count = 3\nprint(count)\n```"))
        #expect(preview.blocks == ["let count = 3"])
        #expect(preview.isCodeOrTableFallback)
        #expect(!preview.isOnlyParagraphsAndLists)
    }

    @Test("A reply of a table only shows the header cells, two spaces apart")
    func tableOnly() throws {
        let preview = try #require(ReplyPreview("| File | **Lines** | `Kind` |\n| --- | --- | --- |\n| a.swift | 12 | source |"))
        #expect(preview.blocks == ["File  Lines  Kind"])
        #expect(preview.singleLine == "File  Lines  Kind")
        #expect(preview.isCodeOrTableFallback)
        #expect(!preview.isOnlyParagraphsAndLists)
    }

    @Test("Code and table without text: the first in the document wins")
    func codeAndTable() throws {
        let table = "| File | Lines |\n| --- | --- |\n| a.swift | 12 |"
        let code = "```\nswift test\n```"
        let codeFirst = try #require(ReplyPreview("# Result\n\n\(code)\n\n\(table)"))
        #expect(codeFirst.blocks == ["swift test"])
        #expect(codeFirst.isCodeOrTableFallback)
        let tableFirst = try #require(ReplyPreview("\(table)\n\n\(code)"))
        #expect(tableFirst.blocks == ["File  Lines"])
        #expect(tableFirst.isCodeOrTableFallback)
    }

    @Test("Text next to code is no fallback")
    func textBeatsFallback() throws {
        let preview = try #require(ReplyPreview("```\nswift test\n```\n\nAll green."))
        #expect(preview.blocks == ["All green."])
        #expect(!preview.isCodeOrTableFallback)
    }

    @Test("A reply of headings only shows the heading text, and is not short")
    func headingsOnly() throws {
        let preview = try #require(ReplyPreview("# Done\n\n## Nothing *else*"))
        #expect(preview.blocks == ["Done", "Nothing else"])
        #expect(!preview.isCodeOrTableFallback)
        #expect(!preview.isOnlyParagraphsAndLists)
    }

    @Test("A reply with nothing to preview still exists, with empty text", arguments: ["---"])
    func nothingToPreview(reply: String) throws {
        let preview = try #require(ReplyPreview(reply))
        #expect(preview.blocks.isEmpty)
        #expect(preview.multiline == "")
        #expect(!preview.isCodeOrTableFallback)
        #expect(!preview.isOnlyParagraphsAndLists)
    }

    @Test("An image-only reply previews its alt text as ordinary text and is not short", arguments: [
        ("![diagram](d.png)", ["diagram"]),
        ("![a](a.png)\n\n![b](b.png)", ["a b"]),
        ("![a](a.png) ![](x.png) ![b](b.png)", ["a b"]),
        ("---\n\n![diagram](d.png)", ["diagram"]),
    ])
    func imageOnly(reply: String, blocks: [String]) throws {
        let preview = try #require(ReplyPreview(reply))
        #expect(preview.blocks == blocks)
        #expect(!preview.isCodeOrTableFallback)
        #expect(!preview.isOnlyParagraphsAndLists)
    }

    @Test("Images without alt text leave the preview empty")
    func imageWithoutAlt() throws {
        let preview = try #require(ReplyPreview("![](d.png)"))
        #expect(preview.blocks.isEmpty)
        #expect(!preview.isOnlyParagraphsAndLists)
    }

    @Test("Other text keeps the alt text out of the preview")
    func imageBesideText() throws {
        let preview = try #require(ReplyPreview("Look: ![diagram](d.png)"))
        #expect(preview.blocks == ["Look:"])
    }

    @Test("A code block wins over an image's alt text")
    func codeBeatsImage() throws {
        let preview = try #require(ReplyPreview("![diagram](d.png)\n\n```sh\nswift test\n```"))
        #expect(preview.blocks == ["swift test"])
        #expect(preview.isCodeOrTableFallback)
    }

    // MARK: - Only paragraphs and lists

    @Test("Paragraphs and list items alone can be short", arguments: [
        "All tests pass.",
        "Two things:\n\n- **one**\n- `two`\n\nDone.",
        "1. first\n   - nested\n2. second",
        "See [the contract](https://example.com) and <kbd>Esc</kbd>.",
    ])
    func onlyParagraphsAndLists(reply: String) throws {
        let preview = try #require(ReplyPreview(reply))
        #expect(preview.isOnlyParagraphsAndLists)
        #expect(!preview.isCodeOrTableFallback)
    }

    @Test("Any other block rules short out, even when the preview drops it", arguments: [
        "# Summary\n\nAll tests pass.",
        "Run this:\n\n```sh\nswift test\n```",
        "Run this:\n\n    swift test",
        "Results:\n\n| File | Lines |\n| --- | --- |\n| a.swift | 12 |",
        "You wrote:\n\n> keep it simple",
        "Above.\n\n---\n\nBelow.",
        "Look: ![Screenshot](shot.png)",
        "<details>\n<summary>Log</summary>\n</details>\n\nDone.",
        "- item\n\n  ```\n  swift test\n  ```",
    ])
    func notOnlyParagraphsAndLists(reply: String) throws {
        let preview = try #require(ReplyPreview(reply))
        #expect(!preview.isOnlyParagraphsAndLists)
    }

    // MARK: - A whole reply

    @Test("A realistic agent reply")
    func realisticReply() throws {
        let reply = """
            ## Summary

            The reducer now keeps the **last reply** of every agent, see
            [`CollectiveState.swift`](CollectiveKit/Sources/CollectiveKit/Store/CollectiveState.swift).

            - `Agent.reply` holds the text of the final message
            - Subagents get theirs from `SubagentStop`
            - *Nothing* changes for running agents

            Verify with:

            ```sh
            cd CollectiveKit
            swift test
            ```

            """
        let preview = try #require(ReplyPreview(reply))
        #expect(preview.multiline == """
            The reducer now keeps the last reply of every agent, see CollectiveState.swift.
            • Agent.reply holds the text of the final message
            • Subagents get theirs from SubagentStop
            • Nothing changes for running agents
            Verify with:
            """)
        #expect(preview.singleLine == "The reducer now keeps the last reply of every agent, see CollectiveState.swift. "
            + "• Agent.reply holds the text of the final message • Subagents get theirs from SubagentStop "
            + "• Nothing changes for running agents Verify with:")
        #expect(!preview.isCodeOrTableFallback)
        #expect(!preview.isOnlyParagraphsAndLists)
    }

    // MARK: - Cached

    @Test("The cached preview is the parsed one, on the first lookup and on every later one", arguments: [
        "## Summary\n\nAll tests pass, see `CollectiveState.swift`.\n\n- one\n- two",
        "```swift\nlet count = 3\n```",
        " \n\t ",
    ])
    func cachedEqualsParsed(reply: String) {
        let parsed = ReplyPreview(reply)
        let cache = ReplyPreviewCache()
        #expect(cachedPreview(reply, in: cache) == parsed)
        #expect(cachedPreview(reply, in: cache) == parsed)
    }

    @Test("Different replies keep their own cached preview")
    func cachedPerText() {
        let first = "The first reply."
        let second = "The second reply."
        let cache = ReplyPreviewCache()
        let build = cache.beginBuild()
        defer { build.finish() }
        #expect(build.preview(of: first)?.blocks == ["The first reply."])
        #expect(build.preview(of: second)?.blocks == ["The second reply."])
        #expect(build.preview(of: first)?.blocks == ["The first reply."])
    }

    @Test("Concurrent lookups each get the preview of their own reply")
    func cachedConcurrently() async {
        let cache = ReplyPreviewCache()
        let mismatches = await withTaskGroup(of: Int.self) { group in
            for task in 0..<16 {
                group.addTask {
                    let build = cache.beginBuild()
                    defer { build.finish() }
                    // Four texts shared by all tasks, so hits and misses race.
                    return (0..<200).count { round in
                        let number = (task + round) % 4
                        return build.preview(of: "Concurrent reply **\(number)**.")?.blocks
                            != ["Concurrent reply \(number)."]
                    }
                }
            }
            return await group.reduce(0, +)
        }
        #expect(mismatches == 0)
    }

    // MARK: - Long replies

    @Test("A long reply is previewed by its beginning, and is never short")
    func longReply() throws {
        let paragraphs = (0..<2_000).map { "Paragraph \($0)." }
        let reply = paragraphs.joined(separator: "\n\n")
        #expect(reply.utf8.count > 4 * ReplyPreview.parsedLimit)
        let preview = try #require(ReplyPreview(reply))
        #expect(preview.blocks.count > 100)
        #expect(preview.blocks.count < paragraphs.count)
        #expect(preview.blocks == Array(paragraphs.prefix(preview.blocks.count)))
        #expect(!preview.isOnlyParagraphsAndLists)
        #expect(!preview.isCodeOrTableFallback)
        #expect(!preview.rendersAsPlainText)
    }

    @Test("A reply is parsed whole up to the limit")
    func replyAtTheLimit() throws {
        let line = "Twenty bytes a line.\n"
        let atLimit = times(ReplyPreview.parsedLimit / line.utf8.count, line) + times(ReplyPreview.parsedLimit % line.utf8.count, "x")
        #expect(atLimit.utf8.count == ReplyPreview.parsedLimit)
        #expect(try #require(ReplyPreview(atLimit)).isOnlyParagraphsAndLists)
        #expect(try #require(ReplyPreview(atLimit + "x")).isOnlyParagraphsAndLists == false)
    }

    @Test("A long reply cut inside a code block shows the text before it")
    func cutInsideCodeBlock() throws {
        let reply = "Run this:\n\n```swift\n" + times(2_000, "let count = 3\n") + "```\n\nThen push."
        let preview = try #require(ReplyPreview(reply))
        #expect(preview.blocks == ["Run this:"])
        #expect(!preview.isCodeOrTableFallback)
        #expect(!preview.isOnlyParagraphsAndLists)
    }

    @Test("A long reply of code only, cut inside it, shows the first code line")
    func cutInsideCodeOnly() throws {
        let preview = try #require(ReplyPreview("```swift\n" + times(2_000, "let count = 3\n") + "```"))
        #expect(preview.blocks == ["let count = 3"])
        #expect(preview.isCodeOrTableFallback)
    }

    @Test("A single line longer than the limit is cut between two characters")
    func longLine() throws {
        let family = "👨‍👩‍👧‍👦"
        let reply = times(2_000, family)
        let preview = try #require(ReplyPreview(reply))
        #expect(preview.blocks == [times(ReplyPreview.parsedLimit / family.utf8.count, family)])
        #expect(!preview.isOnlyParagraphsAndLists)
    }

    @Test("Blank lines before a line longer than the limit do not cost the preview", arguments: [
        "\n", "\r\n", "  \n", "\n\n \t\r\n", "\u{A0}\n", times(ReplyPreview.parsedLimit, "\n"), times(3_000, " \r\n"),
    ])
    func longLineAfterLeadingBreaks(leading: String) throws {
        let line = times(1_500, "word ") + "end"
        #expect(line.utf8.count > ReplyPreview.parsedLimit / 2)
        for reply in [leading + times(2, line), leading + line + "\n\n" + line] {
            let preview = try #require(ReplyPreview(reply))
            let block = try #require(preview.blocks.first)
            #expect(block.hasPrefix("word word word"))
            #expect(block.utf8.count > ReplyPreview.parsedLimit / 2)
            #expect(preview.blocks.joined().utf8.count <= ReplyPreview.parsedLimit)
            #expect(!preview.isOnlyParagraphsAndLists)
            #expect(!preview.rendersAsPlainText)
        }
    }

    @Test("A long line after a heading is previewed like a short one: by its start, without the heading")
    func longLineAfterHeading() throws {
        #expect(try #require(ReplyPreview("# Result\n\nword word")).blocks == ["word word"])
        let preview = try #require(ReplyPreview("# Result\n\n" + times(1_800, "word ")))
        #expect(preview.blocks.count == 1)
        let block = try #require(preview.blocks.first)
        #expect(block.hasPrefix("word word word"))
        #expect(block.utf8.count > ReplyPreview.parsedLimit - 32)
        #expect(block.utf8.count <= ReplyPreview.parsedLimit)
    }

    @Test("A long line after something the preview drops still shows", arguments: ["![](shot.png)\n\n", "---\n", "# Result\n"])
    func longLineAfterADroppedBlock(start: String) throws {
        let preview = try #require(ReplyPreview(start + times(1_800, "word ")))
        #expect(preview.blocks.count == 1)
        #expect(preview.blocks.first?.hasPrefix("word word word") == true)
    }

    @Test("A long reply whose beginning holds nothing to preview shows its lines as they are")
    func nothingToPreviewBeforeTheCut() throws {
        let images = times(400, "![](shot.png)\n\n")
        #expect(images.utf8.count > ReplyPreview.parsedLimit / 2)
        let preview = try #require(ReplyPreview(images + times(1_800, "word ")))
        #expect(Set(preview.blocks) == ["![](shot.png)"])
        #expect(!preview.rendersAsPlainText)
        #expect(!preview.isCodeOrTableFallback)
        #expect(!preview.isOnlyParagraphsAndLists)
        // Read whole, the same beginning is known to be all there is.
        #expect(try #require(ReplyPreview(times(100, "![](shot.png)\n\n"))).blocks.isEmpty)
    }

    @Test("The cut falls after a whole line while whole lines fill half of what is parsed")
    func cutAfterWholeLines() throws {
        let half = times(ReplyPreview.parsedLimit / 2 - 1, "a")
        let long = times(ReplyPreview.parsedLimit, "b")
        #expect(try #require(ReplyPreview(half + "\n\n" + long)).blocks == [half])
        let shorter = String(half.dropLast(2))
        let blocks = try #require(ReplyPreview(shorter + "\n\n" + long)).blocks
        #expect(blocks.count == 2)
        #expect(blocks.first == shorter)
        #expect(blocks.last == times(ReplyPreview.parsedLimit - shorter.utf8.count - 2, "b"))
    }

    @Test("A single character larger than the limit is cut between two of its scalars", arguments: ["", "\n", "# Result\n\n"])
    func hugeCharacter(start: String) throws {
        // One letter under 5 000 combining marks: 10 kB in a single character.
        let character = "a" + times(5_000, "\u{301}")
        #expect(character.count == 1)
        #expect(character.utf8.count > ReplyPreview.parsedLimit)
        let preview = try #require(ReplyPreview(start + character + " and more"))
        #expect(preview.blocks.count == 1)
        let block = try #require(preview.blocks.first)
        #expect(block.count == 1)
        #expect(block.unicodeScalars.first == "a")
        #expect(block.unicodeScalars.dropFirst().allSatisfy { $0 == "\u{301}" })
        #expect(block.utf8.count > ReplyPreview.parsedLimit - 32)
        #expect(block.utf8.count <= ReplyPreview.parsedLimit)
    }

    @Test("A megabyte in one character is previewed, not hung on")
    func megabyteCharacter() throws {
        let preview = try #require(ReplyPreview("a" + times(500_000, "\u{301}")))
        #expect(preview.blocks.count == 1)
        #expect(preview.blocks.joined().utf8.count <= ReplyPreview.parsedLimit)
    }

    @Test("A table of 64 kB shows its header")
    func bigTable() throws {
        let reply = "| File | Lines |\n| --- | --- |\n" + times(4_000, "| a.swift | 12 |\n")
        #expect(reply.utf8.count > 64_000)
        let preview = try #require(ReplyPreview(reply))
        #expect(preview.blocks == ["File  Lines"])
        #expect(preview.isCodeOrTableFallback)
    }

    @Test("A megabyte of ordinary Markdown is previewed like its beginning, and opens as plain text")
    func megabyte() throws {
        let section = "## Step\n\nFixed the **parser**, see [the docs](https://example.com/a_b).\n\n- `swift test` is green\n\n"
        let reply = times(1_000_000 / section.utf8.count + 1, section)
        let preview = try #require(ReplyPreview(reply))
        #expect(preview.blocks.prefix(3) == ["Fixed the parser, see the docs.", "• swift test is green", "Fixed the parser, see the docs."])
        #expect(preview.rendersAsPlainText)
        #expect(!preview.isCodeOrTableFallback)
        #expect(!preview.isOnlyParagraphsAndLists)
    }

    // MARK: - Replies too large to render

    @Test("A reply is Markdown up to the size limit and plain text above it, with the same preview")
    func sizeLimit() throws {
        let section = "## Step\n\nFixed the **parser**, see [the docs](https://example.com/a_b).\n\n- `swift test` is green\n\n"
        let count = ReplyPreview.markdownLimit / section.utf8.count
        let atLimit = times(count, section) + times(ReplyPreview.markdownLimit - count * section.utf8.count, "x")
        #expect(atLimit.utf8.count == ReplyPreview.markdownLimit)
        let markdown = try #require(ReplyPreview(atLimit))
        #expect(!markdown.rendersAsPlainText)
        #expect(markdown.blocks.prefix(2) == ["Fixed the parser, see the docs.", "• swift test is green"])

        let plain = try #require(ReplyPreview(atLimit + "x"))
        #expect(plain.rendersAsPlainText)
        #expect(plain.blocks == markdown.blocks)
        #expect(plain.isCodeOrTableFallback == markdown.isCodeOrTableFallback)
        #expect(plain.isOnlyParagraphsAndLists == markdown.isOnlyParagraphsAndLists)
    }

    @Test("Below the size limit the nesting of the whole reply still decides")
    func deepBelowTheSizeLimit() throws {
        let deep = "\n\n" + times(100, ">") + " a"
        let start = times((ReplyPreview.markdownLimit - deep.utf8.count) / 12, "Paragraph.\n\n")
        let reply = start + deep
        #expect(reply.utf8.count > ReplyPreview.markdownLimit - 12)
        #expect(reply.utf8.count <= ReplyPreview.markdownLimit)
        let preview = try #require(ReplyPreview(reply))
        #expect(preview.rendersAsPlainText)
        #expect(preview.blocks.first == "Paragraph.")
    }

    @Test("Above the size limit a prefix nested too deep is still not parsed")
    func deepPrefixAboveTheSizeLimit() throws {
        let line = times(ReplyPreview.markdownLimit, ">") + " a"
        let preview = try #require(ReplyPreview(line))
        #expect(preview.rendersAsPlainText)
        #expect(preview.blocks == [times(ReplyPreview.parsedLimit, ">")])
    }

    // MARK: - Hostile nesting

    @Test("A reply nested too deep to parse is shown as plain text", arguments: hostileReplies.map(\.reply))
    func hostile(reply: String) throws {
        let preview = try #require(ReplyPreview(reply))
        #expect(preview.rendersAsPlainText)
        #expect(!preview.isCodeOrTableFallback)
        #expect(!preview.isOnlyParagraphsAndLists)
        // Its first line as it stands, as far as the preview reads.
        let firstLine = String(reply.prefix { !$0.isNewline }).trimmingCharacters(in: .whitespaces)
        let first = try #require(preview.blocks.first)
        #expect(firstLine.hasPrefix(first))
        #expect(first.utf8.count == min(firstLine.utf8.count, ReplyPreview.parsedLimit) || first.utf8.count >= ReplyPreview.parsedLimit - 8)
        #expect(preview.blocks.joined().utf8.count <= ReplyPreview.parsedLimit)
        #expect(cachedPreview(reply, in: ReplyPreviewCache()) == preview)
    }

    @Test("The plain preview is the reply's lines, trimmed and folded")
    func plainFallback() throws {
        let deep = times(40, ">") + " **bold**   text"
        let preview = try #require(ReplyPreview("Deep:\n\n\(deep)\n\n   second\tline  \n"))
        #expect(preview.blocks == ["Deep:", times(40, ">") + " **bold** text", "second line"])
        #expect(preview.rendersAsPlainText)
        #expect(!preview.isCodeOrTableFallback)
        #expect(!preview.isOnlyParagraphsAndLists)
    }

    @Test("Nesting at the limit still parses as Markdown", arguments: atTheLimit)
    func atTheNestingLimit(reply: String, shown: String) throws {
        let preview = try #require(ReplyPreview(reply))
        #expect(preview.blocks == [shown])
        #expect(!preview.rendersAsPlainText)
    }

    @Test("One level above the limit does not", arguments: aboveTheLimit)
    func aboveTheNestingLimit(reply: String) throws {
        let preview = try #require(ReplyPreview(reply))
        #expect(preview.blocks == [reply])
        #expect(preview.rendersAsPlainText)
    }

    @Test("The limit is the depth of the parser's own tree")
    func limitIsATreeDepth() {
        #expect(MarkdownNesting.limit == 24)
        #expect(MarkdownNesting.depth(of: "Just text.") == 3)
        #expect(MarkdownNesting.depth(of: "> - **bold** [link](u)") == 7)
        #expect(MarkdownNesting.depth(of: "| a |\n|---|\n| ~~b~~ |") == 6)
        for (reply, _) in atTheLimit { #expect(MarkdownNesting.depth(of: reply) == 24) }
        for reply in aboveTheLimit { #expect(MarkdownNesting.depth(of: reply) == 25) }
    }

    // Stray asterisks, tildes and brackets nest nothing, however many.

    @Test("Sixty thousand open brackets are text")
    func openBrackets() throws {
        let preview = try #require(ReplyPreview(times(60_000, "[")))
        #expect(!preview.rendersAsPlainText)
        #expect(preview.blocks == [times(ReplyPreview.parsedLimit, "[")])
    }

    @Test("A numbered list of globs and home paths outside code is Markdown")
    func strayDelimitersInANumberedList() throws {
        let reply = (1...20).map { "\($0). Delete *.tmp from ~/build/\($0), keep _private[\($0)" }.joined(separator: "\n")
        let preview = try #require(ReplyPreview(reply))
        #expect(!preview.rendersAsPlainText)
        #expect(preview.blocks.count == 20)
        #expect(preview.blocks.first == "1. Delete *.tmp from ~/build/1, keep _private[1")
        #expect(preview.isOnlyParagraphsAndLists)
    }

    @Test("A table with bold cells in every row is Markdown")
    func boldCellsInEveryRow() throws {
        let rows = (0..<100).map { "| **`row\($0)`** | first<br>second *x* | [l](http://x/\($0)) |" }
        let preview = try #require(ReplyPreview("Rows:\n\n| Name | What | Link |\n|---|---|---|\n" + rows.joined(separator: "\n")))
        #expect(!preview.rendersAsPlainText)
        #expect(preview.blocks == ["Rows:"])
        let tableOnly = try #require(ReplyPreview("| **Name** | What |\n|---|---|\n" + rows.joined(separator: "\n")))
        #expect(!tableOnly.rendersAsPlainText)
        #expect(tableOnly.blocks == ["Name  What"])
    }

    @Test("A tight list with twenty bold labels is Markdown")
    func boldLabelsInATightList() throws {
        let reply = (1...20).map { "- **`step \($0)`**: done (**really**), see [the docs](https://example.com/a_b)." }.joined(separator: "\n")
        let preview = try #require(ReplyPreview(reply))
        #expect(!preview.rendersAsPlainText)
        #expect(preview.blocks.count == 20)
        #expect(preview.blocks.first == "• step 1: done (really), see the docs.")
    }

    @Test("Lists three deep in a quote, with code in a fence in an item, are Markdown")
    func ordinaryNesting() throws {
        let item = "> - **Step**\n>   1. *detail* with [a link](u)\n>      - deeper `x`\n>\n>        ```c\n>        int **p = *q;\n>        ```"
        let preview = try #require(ReplyPreview(times(10, item + "\n")))
        #expect(!preview.rendersAsPlainText)
        #expect(preview.blocks.prefix(3) == ["• Step", "1. detail with a link", "• deeper x"])
    }

    @Test("A reply that turns deep after what the preview reads is plain all the same")
    func deepAfterThePrefix() throws {
        let start = times(1_000, "Paragraph.\n\n")
        #expect(start.utf8.count > ReplyPreview.parsedLimit)
        let preview = try #require(ReplyPreview(start + times(100_000, ">") + " a"))
        #expect(preview.rendersAsPlainText)
        #expect(preview.blocks.first == "Paragraph.")
        #expect(!preview.isOnlyParagraphsAndLists)
        #expect(try #require(ReplyPreview(start + "> a")).rendersAsPlainText == false)
    }

    // MARK: - Huge shallow trees

    @Test("A table padded to many times its text is shown as plain text", arguments: paddedTables.map(\.reply))
    func paddedTable(reply: String) throws {
        #expect(reply.utf8.count <= ReplyPreview.markdownLimit)
        let preview = try #require(ReplyPreview(reply))
        #expect(preview.rendersAsPlainText)
        #expect(!preview.isCodeOrTableFallback)
        #expect(!preview.isOnlyParagraphsAndLists)
        // Its lines as they stand, the header first.
        let lines = reply.split(separator: "\n").map(String.init)
        #expect(preview.blocks.count > 1_000)
        #expect(preview.blocks == Array(lines.prefix(preview.blocks.count)))
        #expect(cachedPreview(reply, in: ReplyPreviewCache()) == preview)
    }

    @Test("A padded table is turned down long before it would have been parsed")
    func paddedTableTakesNoTime() {
        // Parsed, this reply took 2.5 s in a debug build; turned down, 5 ms.
        let reply = paddedTables[0].reply
        let elapsed = ContinuousClock().measure { _ = ReplyPreview(reply) }
        #expect(elapsed < .milliseconds(250))
    }

    @Test("A table that makes the parser look back over itself is shown as plain text", arguments: [
        // Every cell of "^" walks up the column for the cell it extends.
        "a\n:-\n" + times(4_000, "^\n"),
        "|a|b|\n|-|-|\n" + times(1_300, "|^|^|\n"),
        "> |a|b|\n> |-|-|\n" + times(1_000, "> |^|^|\n"),
        // Every empty cell looks back over its row for the cell it widens.
        "|a|b|\n|-|-|\n" + times(8_000, "|"),
        times(2_700, "|") + "\n" + times(2_700, "|-"),
    ])
    func tableLookingBack(reply: String) throws {
        #expect(reply.utf8.count <= ReplyPreview.parsedLimit)
        let preview = try #require(ReplyPreview(reply))
        #expect(preview.rendersAsPlainText)
        #expect(preview.blocks.first == String(reply.prefix { !$0.isNewline }))
        #expect(!preview.isCodeOrTableFallback)
    }

    @Test("A reply of more nodes than a parser converts in time opens as plain text, whatever they are")
    func tooManyNodes() throws {
        // A text and a line break per line: no table, and nothing nested.
        let reply = times(30_000, "a\n")
        #expect(reply.utf8.count <= ReplyPreview.markdownLimit)
        #expect(MarkdownNesting.size(of: reply).nodes == 60_001)
        let preview = try #require(ReplyPreview(reply))
        #expect(preview.rendersAsPlainText)
        // Its lines as they stand, though the part the preview reads is small enough.
        #expect(preview.blocks == Array(repeating: "a", count: ReplyPreview.parsedLimit / 2))
        #expect(!MarkdownNesting.exceedsLimit(times(ReplyPreview.parsedLimit / 2, "a\n")))
    }

    @Test("The node limit counts the parser's own tree, and counting stops above it")
    func limitIsATreeSize() throws {
        #expect(MarkdownNesting.nodeLimit == 16_000)
        #expect(MarkdownNesting.size(of: "Just text.").nodes == 3)
        #expect(MarkdownNesting.size(of: "| a | b |\n|---|---|\n| c |").nodes == 11)
        // The document, the rule, the table and its header are 10, a row 5.
        let atLimit = "---\n\n|a|b|c|\n|-|-|-|\n" + times(3_198, "a\n")
        #expect(MarkdownNesting.size(of: atLimit).nodes == 16_000)
        #expect(!MarkdownNesting.exceedsLimit(atLimit))
        #expect(try #require(ReplyPreview(atLimit)).blocks == ["a  b  c"])
        let above = atLimit + "a"
        #expect(MarkdownNesting.size(of: above).nodes == 16_005)
        #expect(MarkdownNesting.size(of: above, stoppingAbove: MarkdownNesting.nodeLimit).nodes == 16_001)
        #expect(MarkdownNesting.exceedsLimit(above))
        #expect(try #require(ReplyPreview(above)).rendersAsPlainText)
    }

    @Test("The bound on a table's cells holds wherever the table stands", arguments: [
        // The text, and the cells the parser builds for it.
        ("|a|b|c|\n|-|-|-|\nx\nx", 9), ("|a|b|c|\r\n|-|-|-|\r\nx\r\nx\r\n", 9), ("|a|b|c|\r|-|-|-|\rx\rx", 9),
        ("a|b|c\n-|-|-\nx\nx", 9), ("a\n:-\nx\nx", 3), ("intro\n|a|b|c|\n|-|-|-|\nx\nx", 9),
        ("> |a|b|c|\n> |-|-|-|\n> x\n> x", 9), ("- |a|b|c|\n  |-|-|-|\n  x\n  x", 9), ("1. > |a|b|c|\n   > |-|-|-|\n   > x", 6),
        ("|a|b|c|\n|-|-|-|\nx\n\u{0C}\nx", 12), ("|a|b|c|\n \t|:-|-:|:-:|\t \nx", 6),
        ("|a|b|\n|-|-|\nx\n\n|a|b|c|d|\n|-|-|-|-|\nx", 12),
    ])
    func tableCellBound(text: String, cells: Int) {
        let work = MarkdownNesting.tableWork(of: text)
        #expect(work.cells >= cells)
        // Never so loose that an ordinary table would count for many.
        #expect(work.cells <= 2 * cells)
    }

    @Test("However tables are written, the bound is never below the cells they have")
    func tableCellBoundOnRandomTables() {
        // All of these stay rows of the table they follow.
        let rows = ["a", "a", "a", "a|b", "^", "^|^", "a|b|c|d|e|f|g|h|i|j|k|l|m|n", "-|-", "a |", "\\| a"]
        var random = SplitMix64(seed: 53)
        for round in 0..<1_000 {
            let lineEnd = ["\n", "\r\n", "\r"].randomElement(using: &random)!
            let container = ["", "", "> ", ">> ", "   ", "  > "].randomElement(using: &random)!
            var lines: [String] = []
            var cells = 0
            for _ in 0..<Int.random(in: 1...4, using: &random) {
                let columns = Int.random(in: 1...12, using: &random)
                let edge = Bool.random(using: &random) ? "|" : ""
                lines.append(edge + Array(repeating: "a", count: columns).joined(separator: "|") + edge)
                lines.append(edge + Array(repeating: ":-", count: columns).joined(separator: "|") + edge)
                let count = Int.random(in: 0...40, using: &random)
                for _ in 0..<count { lines.append(rows.randomElement(using: &random)!) }
                lines.append("")
                // Every row as wide as the header, however many cells it wrote.
                cells += columns * (1 + count)
            }
            let text = lines.map { container + $0 }.joined(separator: lineEnd)
            // The tables are there: no tree without its cells.
            #expect(MarkdownNesting.size(of: text).nodes > cells, "round \(round): \(text.debugDescription)")
            #expect(MarkdownNesting.tableWork(of: text).cells >= cells, "round \(round): \(text.debugDescription)")
        }
    }

    @Test("Text without a table costs the bound nothing")
    func noTableNoWork() {
        let prose = "Fixed the parser | see the docs.\nRun `a | b | c` and x^2.\n- one\n- two | three\n\n```\ncat a | grep ^b | wc -l\nps | sort\n```\n"
        let work = MarkdownNesting.tableWork(of: times(600, prose))
        #expect(work.cells == 0)
        #expect(work.steps < 20_000)
        #expect(!MarkdownNesting.tableExceedsLimit(times(600, prose)))
    }

    @Test("A long line of pipes costs the bound nothing where no table can read it")
    func pipesOutsideATable() throws {
        // A minified line or a generated alternation, as a code block holds them.
        let line = times(2_000, "|")
        let reply = "All **tests** pass. The pattern is below.\n\n```\n" + line + "\n```\n\nDone."
        #expect(MarkdownNesting.tableWork(of: reply).steps == 0)
        let preview = try #require(ReplyPreview(reply))
        #expect(!preview.rendersAsPlainText)
        #expect(preview.blocks == ["All tests pass. The pattern is below.", "Done."])
        // As lines of a paragraph too, while no delimiter row follows them.
        #expect(MarkdownNesting.tableWork(of: times(90, times(700, "|") + "\n")).steps == 0)
        #expect(!MarkdownNesting.exceedsLimit(times(90, times(700, "|") + "\n")))
    }

    @Test("A long line of pipes a table reads as a row is shown as plain text", arguments: [
        // A row of the table.
        "|a|b|\n|-|-|\n" + times(2_000, "|") + "\n",
        // Its header.
        times(2_000, "|") + "\n|-|-|\n|a|b|\n",
        // A line of the paragraph the header ends: read with it all the same.
        times(2_000, "|") + "\n|a|b|\n|-|-|\n",
    ])
    func pipesReadAsARow(reply: String) throws {
        #expect(MarkdownNesting.tableWork(of: reply).steps > 2_001 * 2_002)
        #expect(MarkdownNesting.tableExceedsLimit(reply))
        #expect(try #require(ReplyPreview(reply)).rendersAsPlainText)
    }

    // Tables people write stay Markdown.

    @Test("A table of twelve columns and two hundred rows is Markdown")
    func wideTable() throws {
        let header = "| " + (1...12).map { "Column \($0)" }.joined(separator: " | ") + " |\n|" + times(12, "---|") + "\n"
        let rows = (1...200).map { row in "| " + (1...12).map { "r\(row)c\($0)" }.joined(separator: " | ") + " |\n" }.joined()
        let reply = header + rows
        #expect(reply.utf8.count < ReplyPreview.markdownLimit)
        let preview = try #require(ReplyPreview(reply))
        #expect(!preview.rendersAsPlainText)
        #expect(preview.blocks == [(1...12).map { "Column \($0)" }.joined(separator: "  ")])
        #expect(preview.isCodeOrTableFallback)
        // With a caret in every row, as a table of patterns has.
        let patterns = try #require(ReplyPreview("Patterns:\n\n" + header + rows.replacingOccurrences(of: "c1 ", with: "`^c1` ")))
        #expect(!patterns.rendersAsPlainText)
        #expect(patterns.blocks == ["Patterns:"])
    }

    @Test("What follows a table after a blank line is not counted as its rows")
    func longLogAfterATable() throws {
        let table = "| File | Lines | State |\n|---|---:|:---|\n| `a.swift` | 12 | ok |\n\n"
        // As rows of that table these lines would be 24,000 cells, and their
        // carets a walk of millions of steps.
        let log = "```\n" + times(6_000, "x^2 | y\n") + "```\n"
        let reply = "Done.\n\n" + table + log
        #expect(reply.utf8.count <= ReplyPreview.markdownLimit)
        // The header and one row, five cells wide by their four pipes; the
        // steps are reading the table's three lines twice, and neither the
        // pipes of the log nor a caret's walk.
        let work = MarkdownNesting.tableWork(of: reply)
        #expect(work.cells == 10)
        #expect(work.steps == 3 * 5 * 6)
        let preview = try #require(ReplyPreview(reply))
        #expect(!preview.rendersAsPlainText)
        #expect(preview.blocks == ["Done."])
        // Right below the table they are counted, and the reply is plain text.
        let attached = "Done.\n\n" + String(table.dropLast()) + log
        #expect(MarkdownNesting.tableWork(of: attached).cells > MarkdownNesting.nodeLimit)
        #expect(try #require(ReplyPreview(attached)).rendersAsPlainText)
    }

    @Test("A reply with thirty small tables is Markdown")
    func manyTables() throws {
        let reply = (1...30).map { table in
            "Step \(table) changed **these** files:\n\n| File | Lines | State |\n|---|---:|:---|\n"
                + (1...8).map { "| `Sources/a\($0).swift` | \($0 * table) | ok |\n" }.joined()
        }.joined(separator: "\n")
        let preview = try #require(ReplyPreview(reply))
        #expect(!preview.rendersAsPlainText)
        #expect(preview.blocks.first == "Step 1 changed these files:")
        #expect(!MarkdownNesting.exceedsLimit(reply))
        // Thirty paragraphs and thirty tables, as far as the preview reads.
        #expect(preview.blocks.allSatisfy { $0.hasPrefix("Step ") })
    }

    // MARK: - Deep only where the preview reads

    @Test("Deep nesting after separators the parser takes for text is not parsed", arguments: [
        (times(2_800, "\u{2028}"), 100), (times(2_800, "\u{2028}"), 300),
        (times(8_200, "\u{0C}"), 100), (times(8_200, "\u{0C}"), 300),
    ])
    func deepAfterUnicodeSeparators(leading: String, quotes: Int) throws {
        let line = times(quotes, ">") + " a"
        let preview = try #require(ReplyPreview(leading + line))
        #expect(preview.blocks == [line])
        #expect(!preview.isCodeOrTableFallback)
        #expect(!preview.isOnlyParagraphsAndLists)
    }

    @Test("Deep nesting after more blank lines than the size limit is not parsed", arguments: [30, 100, 8_000])
    func deepAfterBlankLinesAboveTheSizeLimit(quotes: Int) throws {
        let line = times(quotes, ">") + " a"
        let preview = try #require(ReplyPreview(times(70_000, "\n") + line))
        #expect(preview.blocks == [line])
        #expect(preview.rendersAsPlainText)
        #expect(!preview.isCodeOrTableFallback)
        #expect(!preview.isOnlyParagraphsAndLists)
    }

    @Test("A cut reply whose beginning is only whitespace shows where its text begins", arguments: [
        times(9_000, " "), times(9_000, "\t"), times(3_000, " \t "), times(5_000, "\u{A0}"), times(3_000, "\u{2028}"),
        times(9_000, "\u{0B}"), "\n\n" + times(9_000, " "), times(3_000, "\u{2029}") + "\n" + times(9_000, " "),
    ])
    func textAfterWhitespaceOnly(leading: String) throws {
        #expect(leading.utf8.count > ReplyPreview.parsedLimit)
        let preview = try #require(ReplyPreview(leading + "All tests pass.\nSecond line."))
        #expect(preview.blocks == ["All tests pass.", "Second line."])
        #expect(!preview.isOnlyParagraphsAndLists)
        #expect(!preview.rendersAsPlainText)
        // Deep after it: the same lines, unparsed.
        let deep = times(100, ">") + " a"
        #expect(try #require(ReplyPreview(leading + deep)).blocks == [deep])
    }

    // The megabytes are built in the test: as arguments they would be printed.
    @Test("Megabytes of blanks before the text still show where it begins", arguments: [
        ("", " "), ("", "\t"), ("\n", " "), ("", " \u{A0}\t\u{2028}"),
    ])
    func textAfterMegabytesOfWhitespace(start: String, unit: String) throws {
        let leading = start + times(4_000_000 / unit.utf8.count, unit)
        let preview = try #require(ReplyPreview(leading + "All tests pass.\nSecond line."))
        #expect(preview.blocks == ["All tests pass.", "Second line."])
        #expect(preview.rendersAsPlainText)
    }

    @Test("Blank lines before the text are left out of what is parsed, however many", arguments: ["\n", "\r\n", " \t\n"])
    func blankLinesBeforeTheText(line: String) throws {
        let preview = try #require(ReplyPreview(times(9_000, line) + "All **tests** pass."))
        #expect(preview.blocks == ["All tests pass."])
        #expect(preview.isOnlyParagraphsAndLists)
        #expect(!preview.rendersAsPlainText)
    }

    @Test("Lines the parser takes for text are not left out as blank", arguments: [
        times(8, "\u{0C}") + "\n", times(8, "\u{0B}") + "\n", times(4, "\u{A0}") + "\n",
    ])
    func separatorLinesBeforeTheText(line: String) throws {
        let leading = times(1_100, line)
        #expect(leading.utf8.count > ReplyPreview.parsedLimit)
        // Read from the start, so the Markdown lies beyond what is parsed
        // and is shown as it stands. Parsed it could be: the reply is small.
        let preview = try #require(ReplyPreview(leading + "All **tests** pass."))
        #expect(preview.blocks == ["All **tests** pass."])
        #expect(!preview.isOnlyParagraphsAndLists)
        #expect(!preview.rendersAsPlainText)
    }

    @Test("A mark joined to the last space of a blank beginning is still the reply's text", arguments: ["\u{301}", "\u{200D}", "\u{200C}"])
    func markAfterWhitespaceOnly(mark: String) throws {
        let preview = try #require(ReplyPreview(times(ReplyPreview.parsedLimit, " ") + mark))
        #expect(preview.blocks == [mark])
        let followed = try #require(ReplyPreview(times(ReplyPreview.parsedLimit, " ") + mark + "All tests pass.\nSecond line."))
        #expect(followed.blocks == [mark + "All tests pass.", "Second line."])
    }

    @Test("Whatever blank precedes it, nesting too deep is never parsed")
    func deepAfterAnyLeadingRun() throws {
        let units = ["\n", "\r\n", " ", "\t", "\u{2028}", "\u{2029}", "\u{85}", "\u{0B}", "\u{0C}", "\u{A0}"]
        var random = SplitMix64(seed: 53)
        for round in 0..<300 {
            var leading = ""
            for _ in 0..<Int.random(in: 0...3, using: &random) {
                let unit = units.randomElement(using: &random)!
                // Short, or just around one of the two limits.
                let around = [0, ReplyPreview.parsedLimit, ReplyPreview.markdownLimit].randomElement(using: &random)! / unit.utf8.count
                leading += times(max(0, around + Int.random(in: -40...40, using: &random)), unit)
            }
            let depth = Int.random(in: 0...400, using: &random)
            let tail = Bool.random(using: &random)
                ? times(depth, ">") + " end fin"
                : times(depth, "*a ") + "end" + times(depth, " a*") + " fin"
            let preview = try #require(ReplyPreview(leading + tail), "round \(round)")
            #expect(preview.blocks.contains { !$0.isEmpty }, "round \(round)")
            #expect(preview.blocks.joined().utf8.count <= ReplyPreview.parsedLimit, "round \(round)")
            // Parsed, the nesting is gone from the text: a block that reaches
            // the end of a deep tail has to hold all of it as it was written.
            guard MarkdownNesting.exceedsLimit(tail) else { continue }
            for block in preview.blocks where block.hasSuffix("fin") {
                #expect(block.hasSuffix(tail), "round \(round), depth \(depth)")
            }
        }
    }

    @Test("An older overlapping build cannot evict or insert over the newer working set")
    func olderBuildCannotReplaceNewerWorkingSet() {
        let cache = ReplyPreviewCache()
        let older = cache.beginBuild()
        #expect(older.preview(of: "Old reply.")?.blocks == ["Old reply."])

        let newer = cache.beginBuild()
        #expect(newer.preview(of: "New reply.")?.blocks == ["New reply."])
        newer.finish()
        older.finish()
        #expect(cache.retainedCount == 1)
        let parsedAfterNewer = cache.parseCount

        // The stale build may still produce its own result, but cannot retain it.
        #expect(older.preview(of: "Late old reply.")?.blocks == ["Late old reply."])
        older.finish()
        #expect(cache.retainedCount == 1)

        let next = cache.beginBuild()
        #expect(next.preview(of: "New reply.")?.blocks == ["New reply."])
        next.finish()
        #expect(cache.parseCount == parsedAfterNewer + 1)
        #expect(cache.retainedCount == 1)
    }
}
