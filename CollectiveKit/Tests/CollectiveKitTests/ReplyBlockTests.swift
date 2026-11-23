import Foundation
import Testing
import CollectiveKit

private func run(
    _ text: String, strong: Bool = false, emphasis: Bool = false, code: Bool = false, link: String? = nil
) -> ReplyRun {
    ReplyRun(text, isStrong: strong, isEmphasis: emphasis, isCode: code, link: link.flatMap { URL(string: $0) })
}

private func paragraph(_ text: String) -> ReplyBlock { .paragraph([run(text)]) }

@Suite("Reply Markdown blocks")
struct ReplyBlockTests {
    // MARK: Blocks

    @Test func aParagraphIsOneBlockOfText() {
        #expect(ReplyBlock.blocks(from: "All tests pass.") == [paragraph("All tests pass.")])
    }

    @Test func headingsOfAnyLevelAreFlaggedAndKeepTheirText() {
        #expect(ReplyBlock.blocks(from: "# Summary\n\n### Details") == [
            .heading([run("Summary")]),
            .heading([run("Details")]),
        ])
    }

    @Test func anUnorderedListNestsItsItemsWithBullets() {
        #expect(ReplyBlock.blocks(from: "- one\n  - inner\n- two") == [
            .list([
                ReplyListItem(marker: "•", blocks: [
                    paragraph("one"),
                    .list([ReplyListItem(marker: "•", blocks: [paragraph("inner")])]),
                ]),
                ReplyListItem(marker: "•", blocks: [paragraph("two")]),
            ]),
        ])
    }

    @Test func anOrderedListCountsFromItsStart() {
        #expect(ReplyBlock.blocks(from: "3. three\n4. four\n   1. nested") == [
            .list([
                ReplyListItem(marker: "3.", blocks: [paragraph("three")]),
                ReplyListItem(marker: "4.", blocks: [
                    paragraph("four"),
                    .list([ReplyListItem(marker: "1.", blocks: [paragraph("nested")])]),
                ]),
            ]),
        ])
    }

    @Test func aBlockQuoteHoldsBlocks() {
        #expect(ReplyBlock.blocks(from: "> quoted\n>\n> - item") == [
            .quote([
                paragraph("quoted"),
                .list([ReplyListItem(marker: "•", blocks: [paragraph("item")])]),
            ]),
        ])
    }

    @Test func aCodeBlockKeepsItsTextWithoutTheLanguage() {
        #expect(ReplyBlock.blocks(from: "```swift\nlet a = 1\n  let b = **2**\n```") == [
            .code("let a = 1\n  let b = **2**"),
        ])
    }

    @Test func aTableKeepsHeaderAndRowsOfCells() {
        #expect(ReplyBlock.blocks(from: "| File | Lines |\n|---|---:|\n| `a.swift` | 12 |\n| b | **3** |") == [
            .table(
                header: [[run("File")], [run("Lines")]],
                rows: [
                    [[run("a.swift", code: true)], [run("12")]],
                    [[run("b")], [run("3", strong: true)]],
                ]
            ),
        ])
    }

    @Test func aThematicBreakIsDropped() {
        #expect(ReplyBlock.blocks(from: "before\n\n---\n\nafter") == [paragraph("before"), paragraph("after")])
    }

    @Test func anHTMLBlockIsShownAsText() {
        #expect(ReplyBlock.blocks(from: "<div>raw</div>") == [paragraph("<div>raw</div>")])
    }

    @Test func anImageShowsItsAltTextInline() {
        #expect(ReplyBlock.blocks(from: "See ![the chart](chart.png) here.") == [paragraph("See the chart here.")])
    }

    // MARK: Inline

    @Test func boldIsStrong() {
        #expect(ReplyBlock.blocks(from: "**Done** now") == [.paragraph([run("Done", strong: true), run(" now")])])
    }

    @Test func emphasisIsItalic() {
        #expect(ReplyBlock.blocks(from: "a *word*") == [.paragraph([run("a "), run("word", emphasis: true)])])
    }

    @Test func inlineCodeIsFlagged() {
        #expect(ReplyBlock.blocks(from: "Run `swift test` now") == [
            .paragraph([run("Run "), run("swift test", code: true), run(" now")]),
        ])
    }

    @Test func aLinkShowsItsTextAndKeepsTheURL() {
        #expect(ReplyBlock.blocks(from: "See [the docs](https://example.com/docs).") == [
            .paragraph([run("See "), run("the docs", link: "https://example.com/docs"), run(".")]),
        ])
    }

    @Test func aBareURLAloneIsOneLinkedRunOfTheSameText() {
        let url = "https://github.com/example/project/issues/105"
        #expect(ReplyBlock.blocks(from: url) == [.paragraph([run(url, link: url)])])
    }

    @Test func onlyTheBareURLInTextIsLinked() {
        #expect(ReplyBlock.blocks(from: "See https://example.com/a for details") == [
            .paragraph([run("See "), run("https://example.com/a", link: "https://example.com/a"), run(" for details")]),
        ])
    }

    @Test func aBareURLInBoldStaysStrong() {
        #expect(ReplyBlock.blocks(from: "**https://example.com/a**") == [
            .paragraph([run("https://example.com/a", strong: true, link: "https://example.com/a")]),
        ])
    }

    @Test func aBareURLWithUnderscoresIsLinkedWhole() {
        let url = "https://example.com/a_b_c"
        #expect(ReplyBlock.blocks(from: url) == [.paragraph([run(url, link: url)])])
    }

    @Test func aURLInCodeIsNotLinked() {
        #expect(ReplyBlock.blocks(from: "Run `https://example.com/a` now") == [
            .paragraph([run("Run "), run("https://example.com/a", code: true), run(" now")]),
        ])
        #expect(ReplyBlock.blocks(from: "```\nhttps://example.com/a\n```") == [.code("https://example.com/a")])
    }

    @Test func aURLWithoutSchemeIsNotLinked() {
        #expect(ReplyBlock.blocks(from: "See github.com/x") == [paragraph("See github.com/x")])
    }

    @Test func trailingPunctuationIsNotPartOfTheBareURL() {
        #expect(ReplyBlock.blocks(from: "(see https://example.com/a).") == [
            .paragraph([run("(see "), run("https://example.com/a", link: "https://example.com/a"), run(").")]),
        ])
    }

    @Test func aMarkdownLinkStaysOneLinkedRun() {
        #expect(ReplyBlock.blocks(from: "[text](https://a.b)") == [.paragraph([run("text", link: "https://a.b")])])
    }

    @Test func aSoftBreakIsASpace() {
        #expect(ReplyBlock.blocks(from: "one\ntwo") == [paragraph("one two")])
    }

    @Test func aLineBreakIsANewline() {
        #expect(ReplyBlock.blocks(from: "one  \ntwo") == [paragraph("one\ntwo")])
    }

    @Test func inlineHTMLIsShownAsText() {
        #expect(ReplyBlock.blocks(from: "a <b>bold</b> tag") == [paragraph("a <b>bold</b> tag")])
    }
}
