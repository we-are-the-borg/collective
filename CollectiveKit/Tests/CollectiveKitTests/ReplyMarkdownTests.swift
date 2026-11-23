import Foundation
import Testing
import CollectiveKit
@testable import CollectiveUI

private func run(_ text: String) -> ReplyRun { ReplyRun(text) }

private func paragraph(_ text: String) -> ReplyBlock { .paragraph([run(text)]) }

@Suite("Reply Markdown view")
struct ReplyMarkdownTests {
    // MARK: Plain text

    @Test func aReplyRenderedAsPlainTextIsNeverParsed() {
        let text = "# Not a heading\n- not a list\n**not bold**"
        #expect(ReplyMarkdownView.content(for: text, rendersAsPlainText: true) == [paragraph(text)])
    }

    @Test func anyOtherReplyIsParsed() {
        #expect(ReplyMarkdownView.content(for: "# Heading", rendersAsPlainText: false) == [.heading([run("Heading")])])
    }

    // MARK: Cache

    /// The popover remakes the reply view every second; an unchanged reply
    /// must not be parsed again, and a plain one never.
    @Test func theCacheParsesAReplyOnceAndPlainTextNever() {
        let cache = ReplyBlockCache()
        let text = "## Summary\n\n- one\n- two"
        let first = ReplyMarkdownView.content(for: text, rendersAsPlainText: false, cache: cache)
        let second = ReplyMarkdownView.content(for: text, rendersAsPlainText: false, cache: cache)
        #expect(first == second)
        #expect(first == ReplyBlock.blocks(from: text))
        #expect(cache.parseCount == 1)
        _ = ReplyMarkdownView.content(for: "**plain**", rendersAsPlainText: true, cache: cache)
        #expect(cache.parseCount == 1)
    }

    /// The popover reads every visible reply again each second: a cache as
    /// large as their number parses none of them twice.
    @Test func aFullCacheReadAgainParsesNothing() {
        let cache = ReplyBlockCache(entryLimit: 4)
        let replies = (0..<4).map { "Reply **\($0)**" }
        for reply in replies { _ = cache.blocks(for: reply) }
        for reply in replies { _ = cache.blocks(for: reply) }
        #expect(cache.parseCount == 4)
    }

    @Test func evictionDropsTheLeastRecentlyUsedNotARecentHit() {
        let cache = ReplyBlockCache(entryLimit: 2)
        _ = cache.blocks(for: "first")
        _ = cache.blocks(for: "second")
        // A hit makes "first" the most recent, so "second" goes for "third".
        _ = cache.blocks(for: "first")
        _ = cache.blocks(for: "third")
        #expect(cache.parseCount == 3)
        _ = cache.blocks(for: "first")
        #expect(cache.parseCount == 3)
        _ = cache.blocks(for: "second")
        #expect(cache.parseCount == 4)
    }

    @Test func theKeysBytesBoundTheCacheToo() {
        // Room for two of the three 4-byte replies.
        let cache = ReplyBlockCache(entryLimit: 10, byteLimit: 8)
        for reply in ["aaaa", "bbbb", "cccc"] { _ = cache.blocks(for: reply) }
        #expect(cache.parseCount == 3)
        _ = cache.blocks(for: "cccc")
        _ = cache.blocks(for: "bbbb")
        #expect(cache.parseCount == 3)
        _ = cache.blocks(for: "aaaa")
        #expect(cache.parseCount == 4)
    }

    // MARK: Inline code

    @Test func theCodeFillReachesThreePointsLeftOfTheRun() {
        // The run already holds the 3 pt on its right, as tracking on its last character.
        let run = CGRect(x: 40, y: 2, width: 30, height: 13)
        #expect(InlineCodeFill.codeBackground(runRect: run, lineHeight: 17) == CGRect(x: 37, y: 2, width: 33, height: 13))
    }

    @Test func theCodeFillIsNoHigherThanALine() {
        let run = CGRect(x: 0, y: 0, width: 20, height: 19)
        let fill = InlineCodeFill.codeBackground(runRect: run, lineHeight: 15)
        #expect(fill.height == 15)
        #expect(fill.midY == run.midY)
    }

    @Test func touchingCodeRunsOfALineShareOneFill() {
        // The layout splits a span at its tracked last character.
        let fills = InlineCodeFill.codeBackgrounds(
            runRects: [CGRect(x: 52, y: 2, width: 9, height: 13), CGRect(x: 20, y: 2, width: 32, height: 13)],
            lineHeight: 17
        )
        #expect(fills == [CGRect(x: 17, y: 2, width: 44, height: 13)])
    }

    @Test func separateCodeSpansOfALineGetOneFillEach() {
        let fills = InlineCodeFill.codeBackgrounds(
            runRects: [CGRect(x: 10, y: 2, width: 20, height: 13), CGRect(x: 60, y: 2, width: 20, height: 13)],
            lineHeight: 17
        )
        #expect(fills == [CGRect(x: 7, y: 2, width: 23, height: 13), CGRect(x: 57, y: 2, width: 23, height: 13)])
    }

    @Test func theTextBeforeCodeAndTheCodeCarryThePadding() {
        #expect(InlineCodeFill.tracksLastCharacter(codeFlags: [false, true, false]) == [true, true, false])
    }

    @Test func codeAtTheStartHasNoCharacterBeforeItToCarryThePadding() {
        #expect(InlineCodeFill.tracksLastCharacter(codeFlags: [true, false]) == [true, false])
    }

    @Test func twoCodeRunsApartPadTheTextBetweenThem() {
        #expect(InlineCodeFill.tracksLastCharacter(codeFlags: [true, false, true, false]) == [true, true, true, false])
    }

    @Test func consecutiveCodeRunsEachCarryThePadding() {
        #expect(InlineCodeFill.tracksLastCharacter(codeFlags: [false, true, true]) == [true, true, true])
    }

    @Test func noCodeMeansNoPadding() {
        #expect(InlineCodeFill.tracksLastCharacter(codeFlags: [false, false]) == [false, false])
        #expect(InlineCodeFill.tracksLastCharacter(codeFlags: []) == [])
    }
}
