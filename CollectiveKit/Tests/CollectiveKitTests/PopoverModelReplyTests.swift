import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

private let source: SourceID = "test-tool"
private let t0 = Date(timeIntervalSince1970: 1_000)

private func key(_ id: String) -> SessionKey { SessionKey(source: source, sessionID: id) }

/// Events of one session, one second apart starting at `start`.
private func session(_ id: String, start: TimeInterval = 0, _ kinds: [AgentEvent.Kind]) -> [AgentEvent] {
    kinds.enumerated().map { offset, kind in
        AgentEvent(session: key(id), timestamp: t0.addingTimeInterval(start + TimeInterval(offset)), kind: kind)
    }
}

/// Applies the events sorted by time, so sessions can interleave.
private func state(_ events: [AgentEvent]...) -> CollectiveState {
    var state = CollectiveState()
    for event in events.flatMap({ $0 }).sorted(by: { $0.timestamp < $1.timestamp }) {
        state.apply(event)
    }
    return state
}

private func model(
    _ state: CollectiveState, at seconds: TimeInterval = 100, expansion: PopoverExpansion = PopoverExpansion(),
    replyPreviewCache: ReplyPreviewCache = ReplyPreviewCache()
) -> PopoverModel {
    PopoverModel(
        state: state, now: t0.addingTimeInterval(seconds), settings: PopoverSettings(),
        expansion: expansion, replyPreviewCache: replyPreviewCache
    )
}

private func spawn(_ id: String, parent: AgentRef = .root, title: String? = nil, background: Bool? = nil) -> AgentEvent.Kind {
    .agentSpawned(id: id, parent: parent, spec: AgentSpec(type: "explore", title: title ?? id.uppercased(), isBackground: background))
}

/// The orchestrator answers and ends its turn.
private func answer(_ text: String) -> [AgentEvent.Kind] {
    [.replied(agent: .root, text), .turnEnded()]
}

private extension PopoverModel {
    /// The session wherever it is listed, active or finished.
    func item(_ id: String = "s1") throws -> SessionItem {
        try #require((sessions + finished).first { $0.key == key(id) })
    }
}

/// The id of the session's reply given `seconds` after `t0`.
private func replyID(_ id: String = "s1", at seconds: TimeInterval) -> ReplyID {
    .session(key(id), repliedAt: t0.addingTimeInterval(seconds))
}

/// The id of the finished session's reply given `seconds` after `t0`.
private func finishedReplyID(_ id: String = "s1", at seconds: TimeInterval) -> ReplyID {
    .finished(key(id), repliedAt: t0.addingTimeInterval(seconds))
}

private let markdown = "Fixed the **parser**.\n\n- two tests added\n- `swift test` is green"

@Suite struct PopoverModelReplyTests {
    // MARK: Session cards

    @Test func aWaitingSessionShowsTheReplyOfItsEndedTurn() throws {
        let s = state(session("s1", [.promptSubmitted("Fix it")] + answer(markdown)))
        let item = try model(s).item()
        #expect(item.state == .waiting)
        let reply = try #require(item.reply)
        #expect(reply.id == replyID(at: 1))
        #expect(reply.text == markdown)
        #expect(reply.preview == ReplyPreview(markdown))
        #expect(reply.preview.blocks == ["Fixed the parser.", "• two tests added", "• swift test is green"])
    }

    @Test func aSessionWithBackgroundWorkShowsTheReplyAndKeepsItOnceItWaits() throws {
        let turn: [AgentEvent.Kind] = [.promptSubmitted("Go"), spawn("bg", background: true)] + answer(markdown)
        let busy = state(session("s1", turn))
        var item = try model(busy).item()
        #expect(item.state == .backgroundWorking)
        let reply = try #require(item.reply)
        #expect(reply.id == replyID(at: 2))
        #expect(reply.text == markdown)

        // The background agent finishes without the orchestrator taking a turn.
        item = try model(state(session("s1", turn + [.agentFinished(id: "bg")]))).item()
        #expect(item.state == .waiting)
        #expect(item.reply?.id == reply.id)
        #expect(item.reply?.text == markdown)
    }

    @Test func aSessionWithABackgroundShellShowsTheReplyOfItsEndedTurn() throws {
        let s = state(session("s1", [.promptSubmitted("Go")] + answer(markdown) + [.activityReported(.backgroundShell)]))
        let item = try model(s).item()
        #expect(item.state == .backgroundShell)
        #expect(item.reply?.id == replyID(at: 1))
        #expect(item.reply?.text == markdown)
    }

    @Test func aWorkingSessionShowsNoReply() throws {
        // A reply can arrive while the turn still runs, before its end.
        let s = state(session("s1", [.promptSubmitted("Go"), .replied(agent: .root, markdown)]))
        let item = try model(s).item()
        #expect(item.state == .working)
        #expect(item.reply == nil)
    }

    @Test func aNewPromptDropsTheReplyUntilTheNextOne() throws {
        let first: [AgentEvent.Kind] = [.promptSubmitted("One")] + answer("First answer.")
        let before = try #require(model(state(session("s1", first))).item().reply)

        let prompted = first + [.promptSubmitted("Two")]
        #expect(try model(state(session("s1", prompted))).item().reply == nil)

        let after = try #require(model(state(session("s1", prompted + answer("Second answer.")))).item().reply)
        #expect(after.text == "Second answer.")
        #expect(before.id == replyID(at: 1))
        #expect(after.id == replyID(at: 4))
    }

    @Test func aWaitingCardsReplyIsKeyedByItsSessionAndShowsInTwoLines() throws {
        let s = state(session("s1", [.promptSubmitted("Fix it")] + answer(markdown)))
        let item = try model(s).item()
        #expect(item.reply?.id == replyID(at: 1))
        #expect(item.rowDetail == .reply(try #require(item.reply), lineLimit: 2))
    }

    @Test func aTurnTheOrchestratorStartsOnItsOwnGetsAReplyOfItsOwnToo() throws {
        let kinds: [AgentEvent.Kind] = [.promptSubmitted("One")] + answer("First answer.") + [.turnStarted] + answer("Second answer.")
        let reply = try #require(model(state(session("s1", kinds))).item().reply)
        #expect(reply.id == replyID(at: 4))
        #expect(reply.text == "Second answer.")
    }

    @Test func aResumedRunShowsItsNewReply() throws {
        var s = state(session("s1", [.promptSubmitted("One")] + answer("First answer.")))
        let before = try #require(model(s).item().reply)

        let resumed: [AgentEvent.Kind] = [.sessionEnded, .sessionStarted(cwd: nil, pid: 2), .promptSubmitted("Two")] + answer("Second answer.")
        for event in session("s1", start: 10, resumed) { s.apply(event) }
        let after = try #require(model(s).item().reply)
        #expect(after.text == "Second answer.")
        #expect(after.id != before.id)
    }

    @Test func aSessionPrunedAndSeenAgainShowsItsNewReply() throws {
        var s = state(session("s1", [.promptSubmitted("One")] + answer("First answer.")))
        let before = try #require(model(s).item().reply)

        for event in session("s1", start: 10, [.sessionEnded]) { s.apply(event) }
        s.prune(now: t0.addingTimeInterval(500), retention: 60)
        #expect(s.sessions.isEmpty)

        for event in session("s1", start: 600, [.promptSubmitted("Two")] + answer("Second answer.")) { s.apply(event) }
        let after = try #require(model(s, at: 700).item().reply)
        #expect(after.text == "Second answer.")
        #expect(after.id != before.id)
    }

    /// Hooks run async: the start of an older turn can arrive after the
    /// newest reply. It leaves the reply alone, so the reply stays as it is.
    @Test(arguments: [AgentEvent.Kind.promptSubmitted("Late"), .turnStarted])
    func aLateOlderTurnStartLeavesTheReplyAlone(start: AgentEvent.Kind) throws {
        var s = state(session("s1", start: 10, [.promptSubmitted("One")] + answer("First answer.")))
        let before = try #require(model(s).item().reply)

        s.apply(AgentEvent(session: key("s1"), timestamp: t0.addingTimeInterval(5), kind: start))
        s.apply(AgentEvent(session: key("s1"), timestamp: t0.addingTimeInterval(6), kind: .turnEnded()))
        let after = try #require(model(s).item().reply)
        #expect(after.text == "First answer.")
        #expect(after.id == before.id)
    }

    @Test func aSessionWithoutAReplyShowsNone() throws {
        let item = try model(state(session("s1", [.promptSubmitted("Go"), .turnEnded()]))).item()
        #expect(item.state == .waiting)
        #expect(item.reply == nil)
    }

    // MARK: Finished rows

    @Test func aFinishedSessionShowsItsReply() throws {
        let s = state(session("s1", [.promptSubmitted("Go")] + answer(markdown) + [.sessionEnded]))
        let item = try #require(model(s).finished.first)
        #expect(item.state == .done)
        let reply = try #require(item.reply)
        #expect(reply.id == finishedReplyID(at: 1))
        #expect(reply.text == markdown)
        #expect(reply.preview.singleLine == "Fixed the parser. • two tests added • swift test is green")
    }

    @Test func allCurrentRepliesStayWarmAndRemovedRepliesAreEvicted() {
        var s = CollectiveState()
        for number in 0..<257 {
            for event in session("finished-\(number)", [
                .promptSubmitted("Go"),
                .replied(agent: .root, "Reply **\(number)**."),
                .turnEnded(),
                .sessionEnded,
            ]) {
                s.apply(event)
            }
        }
        let cache = ReplyPreviewCache()

        let first = model(s, replyPreviewCache: cache)
        #expect(!first.tabs[2].isSelected)
        #expect(first.finished.count == 257)
        #expect(cache.parseCount == 257)
        #expect(cache.retainedCount == 257)

        _ = model(s, replyPreviewCache: cache)
        #expect(cache.parseCount == 257)
        #expect(cache.retainedCount == 257)

        s.prune(now: t0.addingTimeInterval(1_000), retention: 0)
        _ = model(s, at: 1_000, replyPreviewCache: cache)
        #expect(cache.retainedCount == 0)
    }

    @Test func aSessionThatLostContactShowsItsReply() throws {
        var s = state(session("s1", [.promptSubmitted("Go")] + answer(markdown)))
        s.markStale(now: t0.addingTimeInterval(30), silenceTimeout: 20, waitingTimeout: 20, processStart: { _ in nil })
        let item = try #require(model(s, at: 40).finished.first)
        #expect(item.state == .stale)
        #expect(item.reply?.id == finishedReplyID(at: 1))
        #expect(item.reply?.text == markdown)
    }

    @Test func aFinishedSessionWithoutAReplyShowsNone() throws {
        let s = state(session("s1", [.promptSubmitted("Go"), .turnEnded(), .sessionEnded]))
        #expect(try #require(model(s).finished.first).reply == nil)
    }

    @Test func aFinishedRowsReplyKeepsItsIDWhileItIsTheSameReply() throws {
        let s = state(session("s1", [.promptSubmitted("Go")] + answer(markdown) + [.sessionEnded]))
        for seconds in [100.0, 101, 160] {
            let reply = try #require(model(s, at: seconds).finished.first?.reply)
            #expect(reply.id == finishedReplyID(at: 1))
        }
    }

    @Test func aSessionResumedAndFinishedAgainHasANewReply() throws {
        var s = state(session("s1", [.promptSubmitted("One")] + answer("First answer.") + [.sessionEnded]))
        let before = try #require(model(s).finished.first?.reply)

        let resumed: [AgentEvent.Kind] = [.sessionStarted(cwd: nil, pid: 2), .promptSubmitted("Two")] + answer("Second answer.") + [.sessionEnded]
        for event in session("s1", start: 10, resumed) { s.apply(event) }
        let after = try #require(model(s).finished.first?.reply)
        #expect(after.text == "Second answer.")
        #expect(before.id == finishedReplyID(at: 1))
        #expect(after.id == finishedReplyID(at: 12))
    }

    /// Lost contact and heard from again: the reply is the one it was.
    @Test func aSessionThatFinishesAgainWithTheSameReplyKeepsItsID() throws {
        var s = state(session("s1", [.promptSubmitted("Go")] + answer(markdown)))
        s.markStale(now: t0.addingTimeInterval(30), silenceTimeout: 20, waitingTimeout: 20, processStart: { _ in nil })
        #expect(try #require(model(s, at: 40).finished.first?.reply).id == finishedReplyID(at: 1))

        for event in session("s1", start: 50, [.sessionEnded]) { s.apply(event) }
        let reply = try #require(model(s, at: 60).finished.first?.reply)
        #expect(reply.id == finishedReplyID(at: 1))
    }

    // MARK: Nothing to show

    @Test(arguments: ["", "  \n\t\n"])
    func aReplyWithoutTextShowsNothing(text: String) throws {
        let s = state(session("s1", [.promptSubmitted("Go")] + answer(text)))
        let item = try model(s).item()
        #expect(item.state == .waiting)
        #expect(item.reply == nil)

        let ended = state(session("s1", [.promptSubmitted("Go")] + answer(text) + [.sessionEnded]))
        #expect(try #require(model(ended).finished.first).reply == nil)
    }

    @Test(arguments: [
        ("![diagram](diagram.png)", ["diagram"]),
        ("![](diagram.png)", []),
        ("---", []),
    ])
    func aNonblankReplyIsPreservedEvenWhenItsPlainPreviewWouldBeEmpty(text: String, blocks: [String]) throws {
        let s = state(session("s1", [.promptSubmitted("Go")] + answer(text)))
        let item = try model(s).item()
        let rootReply = try #require(item.reply)
        #expect(rootReply.text == text)
        #expect(rootReply.preview.blocks == blocks)

        let ended = state(session("s1", [.promptSubmitted("Go")] + answer(text) + [.sessionEnded]))
        let finishedReply = try #require(model(ended).finished.first?.reply)
        #expect(finishedReply.text == text)
        #expect(finishedReply.preview.blocks == blocks)
    }

    @Test func aReplyOfCodeOnlyStillShows() throws {
        let code = "```sh\nswift test\n```"
        let reply = try #require(model(state(session("s1", [.promptSubmitted("Go")] + answer(code)))).item().reply)
        #expect(reply.text == code)
        #expect(reply.preview.blocks == ["swift test"])
        #expect(reply.preview.isCodeOrTableFallback)
    }
}
