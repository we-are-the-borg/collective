import Foundation
import Testing
@testable import CollectiveKit

private let key = SessionKey(source: "test-tool", sessionID: "s1")
private let other = SessionKey(source: "test-tool", sessionID: "s2")
private let t0 = Date(timeIntervalSince1970: 1_000)

private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func event(_ kind: AgentEvent.Kind, at seconds: TimeInterval, session: SessionKey = key) -> AgentEvent {
    AgentEvent(session: session, timestamp: at(seconds), kind: kind)
}

/// A working orchestrator with two working subagents `a` and `b`, last event at 2 s.
private func busySession(_ session: SessionKey = key) -> CollectiveState {
    var state = CollectiveState()
    state.apply(event(.promptSubmitted("go"), at: 0, session: session))
    state.apply(event(.agentSpawned(id: "a", parent: .root, spec: AgentSpec()), at: 1, session: session))
    state.apply(event(.agentSpawned(id: "b", parent: .root, spec: AgentSpec()), at: 2, session: session))
    return state
}

@Suite struct CollectiveStateArchiveTests {
    @Test func archivingASessionStopsCountingAllItsAgents() {
        var state = busySession()
        state.apply(event(.promptSubmitted("other"), at: 0, session: other))
        #expect(state.activeAgentCount == 4)

        state.archive(.session(key), at: at(10))
        #expect(state.activeAgentCount == 1)
        #expect(state.isArchived(key))
        #expect(state.isArchived(.subagent("a"), in: key))
        #expect(!state.isArchived(other))
        #expect(state.sessions[key]?.root.status == .working)

        state.unarchive(.session(key))
        #expect(state.activeAgentCount == 4)
        #expect(!state.isArchived(key))
    }

    @Test func archivingOneSubagentStopsCountingOnlyIt() {
        var state = busySession()
        state.archive(.agent(key, .subagent("a")), at: at(10))

        #expect(state.activeAgentCount == 2)
        #expect(state.isArchived(.subagent("a"), in: key))
        #expect(!state.isArchived(.subagent("b"), in: key))
        #expect(!state.isArchived(.root, in: key))
        #expect(!state.isArchived(key))
    }

    @Test(arguments: [
        AgentEvent.Kind.promptSubmitted("again"),
        .turnStarted,
        .toolStarted(agent: .root, ToolActivity(name: "Bash")),
        .agentSpawned(id: "c", parent: .root, spec: AgentSpec()),
    ])
    func newWorkAfterTheMarkUnarchivesTheSession(kind: AgentEvent.Kind) {
        var state = busySession()
        state.apply(event(.turnEnded(), at: 3))
        state.archive(.session(key), at: at(10))

        state.apply(event(kind, at: 11))
        #expect(!state.isArchived(key))
        #expect(state.archiveMarks.isEmpty)
    }

    @Test(arguments: [
        AgentEvent.Kind.promptSubmitted("again"),
        .turnStarted,
        .toolStarted(agent: .root, ToolActivity(name: "Bash")),
        .agentSpawned(id: "c", parent: .root, spec: AgentSpec()),
    ])
    func workNoNewerThanTheMarkKeepsTheSessionArchived(kind: AgentEvent.Kind) {
        var state = busySession()
        state.apply(event(.turnEnded(), at: 3))
        state.archive(.session(key), at: at(10))

        state.apply(event(kind, at: 10))
        #expect(state.isArchived(key))
        // The event still counts underneath.
        #expect(state.sessions[key]?.lastActivity == at(10))
        #expect(state.activeAgentCount == 0)
    }

    @Test func anArchivedSessionStaysArchivedWhenResumedUntilItsNextPrompt() {
        var state = busySession()
        state.archive(.agent(key, .subagent("a")), at: at(4))
        state.apply(event(.sessionEnded, at: 5))
        state.archive(.session(key), at: at(10))
        let marks = state.archiveMarks

        state.apply(event(.sessionStarted(cwd: nil, pid: 7), at: 20))
        #expect(state.sessions[key]?.endedAt == nil)
        #expect(state.isArchived(key))
        #expect(state.archiveMarks == marks)

        state.apply(event(.promptSubmitted("again"), at: 21))
        #expect(!state.isArchived(key))
        #expect(state.activeAgentCount == 1)
    }

    @Test func anOldPromptStillUpdatesTheArchivedSession() {
        var state = busySession()
        state.apply(event(.turnEnded(), at: 3))
        state.archive(.session(key), at: at(10))

        state.apply(event(.promptSubmitted("late"), at: 9))
        #expect(state.isArchived(key))
        #expect(state.sessions[key]?.root.status == .working)
        #expect(state.sessions[key]?.root.spec.prompt == "late")
    }

    @Test(arguments: [
        AgentEvent.Kind.sessionEnded,
        .turnEnded(),
        .activityReported(.working),
        .modelChanged(to: "m2", from: "m1"),
        .sessionStarted(cwd: "/p", pid: 1),
        .toolFinished(agent: .root),
        .agentFinished(id: "a"),
        .replied(agent: .root, "answer"),
        .replied(agent: .subagent("a"), "result"),
    ])
    func otherEventsNeverUnarchiveTheSession(kind: AgentEvent.Kind) {
        var state = busySession()
        state.archive(.session(key), at: at(10))

        state.apply(event(kind, at: 11))
        #expect(state.isArchived(key))
        #expect(state.activeAgentCount == 0)
    }

    @Test func aLateEndIsRecordedButKeepsTheSessionArchived() {
        var state = busySession()
        state.archive(.session(key), at: at(10))

        state.apply(event(.sessionEnded, at: 11))
        #expect(state.isArchived(key))
        #expect(state.sessions[key]?.endedAt == at(11))
    }

    @Test func processDetectionNeverUnarchives() {
        var state = busySession()
        state.archive(.session(key), at: at(10))

        state.markStale(now: at(1_000), silenceTimeout: 60, waitingTimeout: 60) { _ in nil }
        #expect(state.sessions[key]?.root.status == .stale)
        #expect(state.isArchived(key))
    }

    @Test func onlyNewWorkOfTheArchivedAgentItselfUnarchivesIt() {
        var state = busySession()
        state.archive(.agent(key, .subagent("a")), at: at(10))

        state.apply(event(.toolStarted(agent: .subagent("b"), ToolActivity(name: "Read")), at: 11))
        state.apply(event(.promptSubmitted("again"), at: 12))
        #expect(state.isArchived(.subagent("a"), in: key))

        state.apply(event(.toolStarted(agent: .subagent("a"), ToolActivity(name: "Read")), at: 10))
        #expect(state.isArchived(.subagent("a"), in: key))

        state.apply(event(.toolStarted(agent: .subagent("a"), ToolActivity(name: "Read")), at: 13))
        #expect(!state.isArchived(.subagent("a"), in: key))
        #expect(state.activeAgentCount == 3)
    }

    @Test func aReplyNeverUnarchivesItsAgent() {
        var state = busySession()
        state.archive(.agent(key, .subagent("a")), at: at(10))

        state.apply(event(.replied(agent: .subagent("a"), "result"), at: 11))
        #expect(state.isArchived(.subagent("a"), in: key))
        #expect(state.sessions[key]?.agents[.subagent("a")]?.reply == "result")
        #expect(state.activeAgentCount == 2)
    }

    @Test func archivingASubagentArchivesItsWholeSubtree() {
        var state = busySession()
        state.apply(event(.agentSpawned(id: "c", parent: .subagent("a"), spec: AgentSpec()), at: 3))
        state.apply(event(.agentSpawned(id: "d", parent: .subagent("c"), spec: AgentSpec()), at: 4))
        #expect(state.activeAgentCount == 5)

        state.archive(.agent(key, .subagent("a")), at: at(10))
        #expect(state.isArchived(.subagent("c"), in: key))
        #expect(state.isArchived(.subagent("d"), in: key))
        #expect(!state.isArchived(.subagent("b"), in: key))
        #expect(state.activeAgentCount == 2)

        state.unarchive(.agent(key, .subagent("a")))
        #expect(!state.isArchived(.subagent("c"), in: key))
        #expect(state.activeAgentCount == 5)
    }

    @Test func newWorkOfADescendantKeepsTheArchivedSubtreeHidden() {
        var state = busySession()
        state.apply(event(.agentSpawned(id: "c", parent: .subagent("a"), spec: AgentSpec()), at: 3))
        state.archive(.agent(key, .subagent("a")), at: at(10))

        state.apply(event(.toolStarted(agent: .subagent("c"), ToolActivity(name: "Read")), at: 11))
        state.apply(event(.agentSpawned(id: "d", parent: .subagent("c"), spec: AgentSpec()), at: 12))
        #expect(state.isArchived(.subagent("a"), in: key))
        #expect(state.isArchived(.subagent("c"), in: key))
        #expect(state.isArchived(.subagent("d"), in: key))
        #expect(state.activeAgentCount == 2)
    }

    @Test func aRepeatedSpawnUnarchivesTheAgent() {
        var state = busySession()
        state.archive(.agent(key, .subagent("a")), at: at(10))

        state.apply(event(.agentSpawned(id: "a", parent: .root, spec: AgentSpec(title: "A")), at: 11))
        #expect(!state.isArchived(.subagent("a"), in: key))
    }

    @Test func restoredMarksSurviveTheReplayedBacklog() {
        var state = CollectiveState()
        state.restoreArchive([.session(key): at(10), .agent(other, .subagent("a")): at(10)])
        #expect(state.isArchived(key))

        for backlog in [
            event(.promptSubmitted("go"), at: 0),
            event(.agentSpawned(id: "a", parent: .root, spec: AgentSpec()), at: 1),
            event(.promptSubmitted("x"), at: 0, session: other),
            event(.agentSpawned(id: "a", parent: .root, spec: AgentSpec()), at: 10, session: other),
        ] { state.apply(backlog) }

        #expect(state.isArchived(key))
        #expect(state.isArchived(.subagent("a"), in: other))
        #expect(state.activeAgentCount == 1)
    }

    @Test func pruneKeepsTheMarksOfTheSessionsItRemoves() {
        var state = busySession()
        state.archive(.session(key), at: at(10))
        state.apply(event(.sessionEnded, at: 20))

        state.prune(now: at(20 + 3_601), retention: 3_600)
        #expect(state.sessions[key] == nil)
        #expect(state.archiveMarks == [.session(key): at(10)])

        // The spool replays the older events once more, e.g. at the next start.
        state.apply(event(.promptSubmitted("go"), at: 0))
        state.apply(event(.agentSpawned(id: "a", parent: .root, spec: AgentSpec()), at: 1))
        #expect(state.sessions[key] != nil)
        #expect(state.isArchived(key))
        #expect(state.activeAgentCount == 0)
    }
}

@Suite struct AgentLastActivityTests {
    private func agent(_ ref: AgentRef, in state: CollectiveState) -> Agent? {
        state.sessions[key]?.agents[ref]
    }

    @Test func startsWithTheAgent() {
        let state = busySession()
        #expect(agent(.subagent("a"), in: state)?.lastActivity == at(1))
        #expect(agent(.root, in: state)?.lastActivity == at(0))
    }

    @Test func followsOnlyTheEventsOfThatAgent() {
        var state = busySession()
        state.apply(event(.toolStarted(agent: .subagent("a"), ToolActivity(name: "Read")), at: 5))
        #expect(agent(.subagent("a"), in: state)?.lastActivity == at(5))
        #expect(agent(.subagent("b"), in: state)?.lastActivity == at(2))

        state.apply(event(.toolFinished(agent: .subagent("b")), at: 6))
        state.apply(event(.agentSpawned(id: "a", parent: .root, spec: AgentSpec()), at: 7))
        state.apply(event(.agentFinished(id: "b"), at: 8))
        #expect(agent(.subagent("a"), in: state)?.lastActivity == at(7))
        #expect(agent(.subagent("b"), in: state)?.lastActivity == at(8))
        // Subagent events alone don't move the orchestrator's.
        #expect(agent(.root, in: state)?.lastActivity == at(0))
    }

    @Test func theRootFollowsSessionEvents() {
        var state = busySession()
        state.apply(event(.turnEnded(), at: 5))
        #expect(agent(.root, in: state)?.lastActivity == at(5))
        state.apply(event(.toolStarted(agent: .root, ToolActivity(name: "Bash")), at: 6))
        #expect(agent(.root, in: state)?.lastActivity == at(6))
        state.apply(event(.sessionEnded, at: 9))
        #expect(agent(.root, in: state)?.lastActivity == at(9))
    }

    @Test func aLateEventDoesNotMoveItBack() {
        var state = busySession()
        state.apply(event(.toolStarted(agent: .subagent("a"), ToolActivity(name: "Read")), at: 5))
        state.apply(event(.toolFinished(agent: .subagent("a")), at: 3))
        #expect(agent(.subagent("a"), in: state)?.lastActivity == at(5))
    }
}

@Suite struct ArchiveRestartFixtureTests {
    /// The app restarts after the user archived the captured session: the
    /// marks come back first, then the whole spool replays underneath them.
    @Test func anArchivedSessionStaysArchivedAcrossARestart() throws {
        let spool = try OrphanSpool()
        let last = try #require(spool.events.map(\.at).max())
        let mark = last.addingTimeInterval(60)

        var state = CollectiveState()
        state.restoreArchive([.session(OrphanSpool.session): mark])
        try OrphanSpool.replay(spool.events, onto: &state)
        #expect(state.isArchived(OrphanSpool.session))

        // A turn running when the spool ends would still count without the mark.
        state.apply(AgentEvent(session: OrphanSpool.session, timestamp: mark, kind: .turnStarted))
        #expect(state.sessions[OrphanSpool.session]?.root.status == .working)
        #expect(state.activeAgentCount == 0)

        state.apply(AgentEvent(session: OrphanSpool.session, timestamp: mark.addingTimeInterval(1),
                               kind: .promptSubmitted("back")))
        #expect(!state.isArchived(OrphanSpool.session))
        #expect(state.activeAgentCount == 1)
    }
}
