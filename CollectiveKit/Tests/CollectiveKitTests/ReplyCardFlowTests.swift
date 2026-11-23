import Foundation
import Testing
@testable import CollectiveKit

/// Which reply card the popover shows: only a
/// deliberate act opens one ("Show more", the menu, Space or Return, VoiceOver), and it stays
/// until Esc, its close button, a click beside it, another row's card or its row going; a click
/// beside it in the popover only closes it.
/// Nothing the pointer does by itself opens or closes it.
@Suite struct ReplyCardFlowTests {
    private let s1 = ReplyCardTarget.session(SessionKey(source: "claude-code", sessionID: "s1"))
    private let s2 = ReplyCardTarget.session(SessionKey(source: "claude-code", sessionID: "s2"))
    private let a1 = ReplyCardTarget.agent(SessionKey(source: "claude-code", sessionID: "s1"), .subagent("a1"))

    /// The card where the host last laid it out, in the popover's coordinates.
    private let cardFrame = CGRect(x: 20, y: 100, width: 356, height: 200)
    private let insideCard = CGPoint(x: 100, y: 150)
    private let besideCard = CGPoint(x: 100, y: 320)

    // MARK: Opening

    @Test func openingShowsTheRowsCard() {
        var flow = ReplyCardFlow()
        #expect(flow.shown == nil)
        flow.open(s1)
        #expect(flow.shown == s1)
    }

    /// One card at a time: another row's replaces it.
    @Test func openingAnotherRowReplacesTheCard() {
        var flow = ReplyCardFlow()
        flow.open(s1)
        flow.open(a1)
        #expect(flow.shown == a1)
    }

    /// Space or Return on the row whose card shows already: it stays.
    @Test func openingTheShownRowAgainKeepsIt() {
        var flow = ReplyCardFlow()
        flow.open(s1)
        flow.open(s1)
        #expect(flow.shown == s1)
    }

    // MARK: "Show more" toggles

    @Test func showMoreOpensAClosedCard() {
        var flow = ReplyCardFlow()
        flow.toggle(s1)
        #expect(flow.shown == s1)
    }

    @Test func showMoreOnTheShownRowClosesItsCard() {
        var flow = ReplyCardFlow()
        flow.toggle(s1)
        flow.toggle(s1)
        #expect(flow.shown == nil)
    }

    @Test func showMoreOnAnotherRowSwitchesTheCard() {
        var flow = ReplyCardFlow()
        flow.toggle(s1)
        flow.toggle(s2)
        #expect(flow.shown == s2)
    }

    /// A click on the shown row's "Show more" lands beside its card: the popover takes it, so
    /// the button never sees it and no toggle follows. The click after it is the row's again:
    /// its "Show more" opens the card.
    @Test func theClickAfterTheClosingOneActs() {
        var flow = ReplyCardFlow()
        flow.open(s1)
        let closing = flow.mouseDown(at: .popover(besideCard), cardFrame: cardFrame)
        #expect(closing)
        #expect(flow.shown == nil)
        let taken = flow.mouseDown(at: .popover(besideCard), cardFrame: nil)
        #expect(!taken)
        flow.toggle(s1)
        #expect(flow.shown == s1)
    }

    /// A menu entry or a key opens, whatever closed the card just before.
    @Test func openingAfterAClickBesideTheCardShowsIt() {
        var flow = ReplyCardFlow()
        flow.open(s1)
        _ = flow.mouseDown(at: .popover(besideCard), cardFrame: cardFrame)
        flow.open(s1)
        #expect(flow.shown == s1)
    }

    // MARK: Closing

    @Test func escapeClosesTheCardAndSaysSo() {
        var flow = ReplyCardFlow()
        flow.open(s1)
        let closed = flow.escape()
        #expect(closed)
        #expect(flow.shown == nil)
    }

    /// Nothing to close: the key is the popover's, which closes.
    @Test func escapeWithoutACardIsNotTaken() {
        var flow = ReplyCardFlow()
        let handled = flow.escape()
        #expect(!handled)
    }

    /// A click into the card, with any button, selects its text, scrolls or opens the text's own
    /// menu: it stays, and the click is the card's.
    @Test func aClickIntoTheCardKeepsIt() {
        var flow = ReplyCardFlow()
        flow.open(s1)
        let taken = flow.mouseDown(at: .popover(insideCard), cardFrame: cardFrame)
        #expect(!taken)
        #expect(flow.shown == s1)
    }

    /// Beside the card in the popover, with any button, a click only closes the card: the
    /// popover takes it, so no row, button, menu or tab under it acts.
    @Test func aClickBesideTheCardOnlyClosesIt() {
        var flow = ReplyCardFlow()
        flow.open(s1)
        let taken = flow.mouseDown(at: .popover(besideCard), cardFrame: cardFrame)
        #expect(taken)
        #expect(flow.shown == nil)
    }

    /// No frame laid out for the shown card yet: nothing to land in, so the click only closes it.
    @Test func aClickWithoutACardFrameOnlyClosesTheCard() {
        var flow = ReplyCardFlow()
        flow.open(s1)
        let taken = flow.mouseDown(at: .popover(insideCard), cardFrame: nil)
        #expect(taken)
        #expect(flow.shown == nil)
    }

    /// A click in another of the app's windows closes the card and stays that window's.
    @Test func aClickInAnotherWindowClosesTheCardAndActsThere() {
        var flow = ReplyCardFlow()
        flow.open(s1)
        let taken = flow.mouseDown(at: .anotherWindow, cardFrame: cardFrame)
        #expect(!taken)
        #expect(flow.shown == nil)
    }

    /// No card: every click acts as it would without one.
    @Test(arguments: [ReplyCardClickLocation.popover(CGPoint(x: 100, y: 320)), .anotherWindow])
    func aClickWithoutACardIsNotTaken(location: ReplyCardClickLocation) {
        var flow = ReplyCardFlow()
        let taken = flow.mouseDown(at: location, cardFrame: nil)
        #expect(!taken)
        #expect(flow.shown == nil)
    }

    /// A tab change, an archived row or a reply that went: the row takes its card along.
    @Test func aRowThatGoesClosesItsCard() {
        var flow = ReplyCardFlow()
        flow.open(s1)
        flow.targetDisappeared(s1)
        #expect(flow.shown == nil)
    }

    @Test func anotherRowGoingKeepsTheCard() {
        var flow = ReplyCardFlow()
        flow.open(s1)
        flow.targetDisappeared(s2)
        #expect(flow.shown == s1)
    }

    // MARK: Key table

    private static let s1Open = ReplyCardKeyAction.open(.session(SessionKey(source: "claude-code", sessionID: "s1")))

    /// The focused row's reply does not fit, no card shows.
    @Test(arguments: [
        (ReplyCardKey.space, s1Open),
        (.return, s1Open),
        (.commandReturn, .showInApp),
        (.upArrow, .moveFocusUp),
        (.downArrow, .moveFocusDown),
        (.escape, .pass),
    ])
    func keysWithoutACard(key: ReplyCardKey, action: ReplyCardKeyAction) {
        #expect(ReplyCardFlow().action(for: key, focusedReply: s1) == action)
    }

    /// A card shows, whatever opened it: ↑ ↓ scroll in it, Esc closes it.
    @Test(arguments: [
        (ReplyCardKey.space, s1Open),
        (.return, s1Open),
        (.commandReturn, .showInApp),
        (.upArrow, .scrollCardUp),
        (.downArrow, .scrollCardDown),
        (.escape, .closeCard),
    ])
    func keysWithACard(key: ReplyCardKey, action: ReplyCardKeyAction) {
        var flow = ReplyCardFlow()
        flow.toggle(s2)
        #expect(flow.action(for: key, focusedReply: s1) == action)
    }

    /// A focused row whose reply fits, or without one, has no card to open; ⌘↩ stays "Show in <App>".
    @Test(arguments: [
        (ReplyCardKey.space, ReplyCardKeyAction.pass),
        (.return, .pass),
        (.commandReturn, .showInApp),
    ])
    func keysOnARowWithoutACardToOpen(key: ReplyCardKey, action: ReplyCardKeyAction) {
        #expect(ReplyCardFlow().action(for: key, focusedReply: nil) == action)
    }
}
