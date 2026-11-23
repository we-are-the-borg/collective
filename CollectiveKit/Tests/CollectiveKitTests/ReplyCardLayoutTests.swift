import CoreGraphics
import Testing
@testable import CollectiveUI

/// The reply card: 356 pt wide, as tall as its content up to
/// 360 pt and never taller than the window; beyond that the reply scrolls.
@Suite("Reply card layout")
struct ReplyCardLayoutTests {
    @Test func theCardIs356PointsWideAndAtMost360High() {
        #expect(ReplyCardLayout.width == 356)
        #expect(ReplyCardLayout.maxHeight == 360)
    }

    /// The "×" is 12 pt in a 20 pt hit area, which reaches 4 pt into the card's padding at the
    /// right and above the head line no more than the card's top padding: all of it inside the card, so a click on its
    /// edge is the card's and not one beside it, which would only close the card.
    @Test func theCloseButtonStaysInsideTheCard() {
        #expect(ReplyCardLayout.closeButtonSize == 20)
        #expect(ReplyCardLayout.closeIconSize == 12)
        #expect(ReplyCardLayout.closeButtonOverhang == 4)
        #expect(ReplyCardLayout.closeButtonOverhang <= ReplyCardLayout.padding.trailing)
        // Above the head line, as the views centre the button on it: the idle card's line has the
        // text's own height, the subagent card's 16.
        for headLine in [PlexMetrics.naturalLineHeight(size: 10.5, mono: false), 16] {
            #expect((ReplyCardLayout.closeButtonSize - headLine) / 2 <= ReplyCardLayout.padding.top)
        }
    }

    @Test func aShortCardKeepsItsOwnHeight() {
        #expect(ReplyCardLayout.cardHeight(content: 140, container: 800) == 140)
    }

    @Test func aLongCardStopsAt360() {
        #expect(ReplyCardLayout.cardHeight(content: 900, container: 800) == 360)
    }

    @Test func theCardIsNeverTallerThanTheWindow() {
        #expect(ReplyCardLayout.cardHeight(content: 900, container: 240) == 240)
        #expect(ReplyCardLayout.cardHeight(content: 300, container: 240) == 240)
    }

    // Header, footer and padding stay put; only the reply gives way.
    @Test func aReplyThatFitsKeepsItsHeight() {
        #expect(ReplyCardLayout.textHeight(text: 100, fixed: 40, container: 800) == 100)
    }

    @Test func aLongReplyGetsWhatTheCapLeavesBesideHeaderAndFooter() {
        #expect(ReplyCardLayout.textHeight(text: 600, fixed: 40, container: 800) == 320)
    }

    @Test func inALowWindowTheReplyGetsWhatTheWindowLeaves() {
        #expect(ReplyCardLayout.textHeight(text: 600, fixed: 40, container: 200) == 160)
    }

    @Test func aWindowLowerThanHeaderAndFooterLeavesTheReplyNothing() {
        #expect(ReplyCardLayout.textHeight(text: 600, fixed: 40, container: 30) == 0)
    }

    @Test func contentContinuingBelowFades() {
        #expect(ReplyCardLayout.showsFade(contentHeight: 600, viewportHeight: 320, offset: 0))
        #expect(ReplyCardLayout.showsFade(contentHeight: 600, viewportHeight: 320, offset: 200))
    }

    @Test func contentThatFitsOrIsScrolledToTheEndHasNoFade() {
        #expect(!ReplyCardLayout.showsFade(contentHeight: 120, viewportHeight: 120, offset: 0))
        #expect(!ReplyCardLayout.showsFade(contentHeight: 600, viewportHeight: 320, offset: 280))
        // Within half a point of the end counts as the end.
        #expect(!ReplyCardLayout.showsFade(contentHeight: 600, viewportHeight: 320, offset: 279.6))
    }

    @Test func theFadeIsTwelveToFourteenPointsHigh() {
        #expect((12...14).contains(ReplyCardLayout.fadeHeight))
    }

    @Test func theCardsReplyIsTwelvePointTextAtLineHeight17() {
        #expect(ReplyTextStyle.card == ReplyTextStyle(fontSize: 12, lineHeight: 17, role: .text))
    }

    // ↑ ↓ on a held card: 40 pt a press, never past either end.
    @Test func downScrollsFortyPointsFurther() {
        #expect(ReplyCardLayout.offset(after: 1, from: 0, contentHeight: 600, viewportHeight: 320) == 40)
        #expect(ReplyCardLayout.offset(after: -1, from: 100, contentHeight: 600, viewportHeight: 320) == 60)
    }

    @Test func scrollingStopsAtTheEnds() {
        #expect(ReplyCardLayout.offset(after: 1, from: 270, contentHeight: 600, viewportHeight: 320) == 280)
        #expect(ReplyCardLayout.offset(after: -1, from: 20, contentHeight: 600, viewportHeight: 320) == 0)
        // A reply that fits does not move.
        #expect(ReplyCardLayout.offset(after: 1, from: 0, contentHeight: 120, viewportHeight: 320) == 0)
    }
}
