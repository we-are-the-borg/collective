import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

private let source: SourceID = "test-tool"
private let t0 = Date(timeIntervalSince1970: 1_000)

private func key(_ id: String) -> SessionKey { SessionKey(source: source, sessionID: id) }

/// Applies each session's events one second apart from `t0` on.
private func state(_ sessions: [String: [AgentEvent.Kind]]) -> CollectiveState {
    var state = CollectiveState()
    for (id, kinds) in sessions.sorted(by: { $0.key < $1.key }) {
        for (offset, kind) in kinds.enumerated() {
            state.apply(AgentEvent(session: key(id), timestamp: t0.addingTimeInterval(TimeInterval(offset)), kind: kind))
        }
    }
    return state
}

private func model(
    _ state: CollectiveState, expansion: PopoverExpansion = PopoverExpansion(), undo: ArchiveUndo = ArchiveUndo()
) -> PopoverModel {
    PopoverModel(
        state: state, now: t0.addingTimeInterval(30), settings: PopoverSettings(finishedRetention: .oneHour, idleAfter: .never),
        expansion: expansion, undo: undo
    )
}

private func spawn(_ id: String, prompt: String? = nil) -> AgentEvent.Kind {
    .agentSpawned(id: id, parent: .root, spec: AgentSpec(type: "explore", title: id.uppercased(), prompt: prompt))
}

private let started: AgentEvent.Kind = .sessionStarted(cwd: "/tmp/alpha", pid: nil)

/// Which rows of the shown tab may have a reply card: a session row while its
/// detail is a reply, in any tab (the view opens it only while the reply does not fit), and a
/// subagent row in an open list with a prompt or a result. A target that leaves this set has
/// gone, and the view closes its card.
@Suite struct ReplyCardTargetTests {
    @Test func aRowShowingAReplyIsATargetOneWithoutIsNot() {
        let s = state([
            "waiting": [started, .promptSubmitted("Fix it"), .replied(agent: .root, "Fixed."), .turnEnded()],
            "working": [started, .promptSubmitted("Go")],
        ])
        #expect(model(s).replyCardTargets == [.session(key("waiting"))])
    }

    @Test func aFinishedRowShowingItsReplyIsATarget() {
        let s = state(["done": [started, .promptSubmitted("Fix it"), .replied(agent: .root, "Fixed."), .turnEnded(), .sessionEnded]])
        var expansion = PopoverExpansion()
        expansion.select(.finished)
        #expect(model(s, expansion: expansion).replyCardTargets == [.session(key("done"))])
    }

    @Test func onlyTheSelectedTabsRowsAreTargets() {
        let s = state(["done": [started, .promptSubmitted("Fix it"), .replied(agent: .root, "Fixed."), .turnEnded(), .sessionEnded]])
        #expect(model(s).replyCardTargets.isEmpty)
    }

    @Test func aSubagentRowWithAPromptInAnOpenListIsATarget() {
        let s = state(["s1": [started, .promptSubmitted("Go"), spawn("a", prompt: "Look around"), spawn("b")]])
        var expansion = PopoverExpansion()
        #expect(model(s, expansion: expansion).replyCardTargets.isEmpty)

        expansion.toggleSubagents(key("s1"), isOpen: false)
        #expect(model(s, expansion: expansion).replyCardTargets == [.agent(key("s1"), .subagent("a"))])
    }

    /// Archived, the row turns into its undo row, which shows no reply: its card went.
    @Test func anArchivedRowIsNoTargetWhileItsUndoRowShows() {
        var s = state(["waiting": [started, .promptSubmitted("Fix it"), .replied(agent: .root, "Fixed."), .turnEnded()]])
        var undo = ArchiveUndo()
        _ = undo.archive(.session(key("waiting")), in: &s, at: t0.addingTimeInterval(20))
        #expect(model(s, undo: undo).replyCardTargets.isEmpty)
    }
}
