import CoreGraphics
import Testing
@testable import CollectiveUI

/// Where an idle row's reply preview goes in the popover window: the
/// window is only as tall as its content, so the preview picks the side with room;
/// the last of several rows tries above first.
@Suite("Idle preview placement")
struct IdlePreviewPlacementTests {
    private let row = CGRect(x: 8, y: 100, width: 364, height: 29)

    @Test func itOpensBelowTheRowWhenThereIsRoom() {
        // 2 pt over the row's bottom edge.
        #expect(IdlePreviewPlacement.top(row: row, height: 98, container: 400, isLastOfSeveral: false) == 127)
    }

    @Test func itOpensBelowWhenItFitsExactly() {
        #expect(IdlePreviewPlacement.top(row: row, height: 98, container: 225, isLastOfSeveral: false) == 127)
    }

    @Test func itOpensAboveWhenOnlyTheSpaceAboveFits() {
        let last = CGRect(x: 8, y: 250, width: 364, height: 29)
        // 2 pt over the row's top edge.
        #expect(IdlePreviewPlacement.top(row: last, height: 98, container: 300, isLastOfSeveral: false) == 154)
    }

    @Test func neitherSideFitsAndMoreRoomIsAboveSoItStaysAtTheWindowTop() {
        // One resting session in an otherwise empty popover.
        let single = CGRect(x: 8, y: 64, width: 364, height: 29)
        #expect(IdlePreviewPlacement.top(row: single, height: 98, container: 134, isLastOfSeveral: false) == 0)
    }

    @Test func neitherSideFitsAndMoreRoomIsBelowSoItEndsAtTheWindowBottom() {
        let high = CGRect(x: 8, y: 20, width: 364, height: 29)
        #expect(IdlePreviewPlacement.top(row: high, height: 120, container: 140, isLastOfSeveral: false) == 20)
    }

    @Test func aPreviewTallerThanTheWindowStartsAtItsTop() {
        #expect(IdlePreviewPlacement.top(row: row, height: 300, container: 200, isLastOfSeveral: false) == 0)
    }

    // MARK: The last of several rows

    @Test func theLastOfSeveralRowsOpensAboveWhenItFits() {
        // Below would fit as well; above wins.
        #expect(IdlePreviewPlacement.top(row: row, height: 98, container: 400, isLastOfSeveral: true) == 4)
    }

    @Test func theLastOfSeveralRowsOpensAboveWhenItFitsExactly() {
        let low = CGRect(x: 8, y: 96, width: 364, height: 29)
        #expect(IdlePreviewPlacement.top(row: low, height: 98, container: 400, isLastOfSeveral: true) == 0)
    }

    @Test func theLastOfSeveralRowsOpensBelowWhenOnlyBelowFits() {
        let high = CGRect(x: 8, y: 40, width: 364, height: 29)
        #expect(IdlePreviewPlacement.top(row: high, height: 98, container: 400, isLastOfSeveral: true) == 67)
    }

    @Test func theLastOfSeveralRowsFallsBackToTheRoomierSideWhenNeitherFits() {
        let high = CGRect(x: 8, y: 20, width: 364, height: 29)
        #expect(IdlePreviewPlacement.top(row: high, height: 120, container: 140, isLastOfSeveral: true) == 20)
        let single = CGRect(x: 8, y: 64, width: 364, height: 29)
        #expect(IdlePreviewPlacement.top(row: single, height: 98, container: 134, isLastOfSeveral: true) == 0)
    }

    // MARK: Against the reply text

    /// A card with its reply, subagents and jump line below the text.
    private let card = CGRect(x: 8, y: 100, width: 364, height: 160)
    private let replyText = CGRect(x: 52, y: 130, width: 312, height: 68)

    @Test func itOpensRightBelowTheReplyTextRatherThanTheCard() {
        let band = IdlePreviewPlacement.band(row: card, reply: replyText)
        // 2 pt over the text's bottom edge at 198.
        #expect(IdlePreviewPlacement.top(row: band, height: 98, container: 400, isLastOfSeveral: false) == 196)
    }

    @Test func itOpensRightAboveTheReplyTextWhenBelowHasNoRoom() {
        let band = IdlePreviewPlacement.band(row: card, reply: replyText)
        // 2 pt over the text's top edge at 130.
        #expect(IdlePreviewPlacement.top(row: band, height: 98, container: 270, isLastOfSeveral: false) == 34)
    }

    @Test func theLastOfSeveralCardsOpensAboveTheReplyText() {
        let band = IdlePreviewPlacement.band(row: card, reply: replyText)
        #expect(IdlePreviewPlacement.top(row: band, height: 98, container: 400, isLastOfSeveral: true) == 34)
    }

    @Test func theBandKeepsTheCardsHorizontalExtent() {
        let band = IdlePreviewPlacement.band(row: card, reply: replyText)
        #expect(band.minX == card.minX)
        #expect(band.width == card.width)
    }

    @Test func neitherSideFitsSoTheRoomierSideOfTheReplyTextWins() {
        let band = IdlePreviewPlacement.band(row: card, reply: replyText)
        // 142 below the text's bottom at 198 against 130 above it: below, kept
        // inside the window. Against the whole card it would be above, at 0.
        #expect(IdlePreviewPlacement.top(row: band, height: 200, container: 340, isLastOfSeveral: false) == 140)
    }

    @Test func withoutAReplyTextTheRowIsTheReference() {
        #expect(IdlePreviewPlacement.band(row: card, reply: nil) == card)
    }

    // MARK: Leading edge

    @Test func itIsIndented22FromTheRowAndKeptInsideTheWindow() {
        #expect(IdlePreviewPlacement.leading(row: row, width: 300, container: 380) == 30)
        #expect(IdlePreviewPlacement.leading(row: row, width: 300, container: 320) == 20)
        #expect(IdlePreviewPlacement.leading(row: row, width: 300, container: 200) == 0)
    }
}
