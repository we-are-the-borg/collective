import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

private let source: SourceID = "test-tool"
private let key = SessionKey(source: source, sessionID: "s1")
private let t0 = Date(timeIntervalSince1970: 1_000)

private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func event(_ kind: AgentEvent.Kind, at seconds: TimeInterval) -> AgentEvent {
    AgentEvent(session: key, timestamp: at(seconds), kind: kind)
}

private func spawn(_ id: String, background: Bool? = nil) -> AgentEvent.Kind {
    .agentSpawned(id: id, parent: .root, spec: AgentSpec(type: "explore", title: id.uppercased(), isBackground: background))
}

/// A working orchestrator whose subagent `a` started at 1 s and handed back at 10 s.
private func finishedSubagent(background: Bool? = nil) -> CollectiveState {
    var state = CollectiveState()
    state.apply(event(.promptSubmitted("go"), at: 0))
    state.apply(event(spawn("a", background: background), at: 1))
    state.apply(event(.agentFinished(id: "a"), at: 10))
    return state
}

private func agent(_ id: String, in state: CollectiveState) throws -> Agent {
    try #require(state.sessions[key]?.agents[.subagent(id)])
}

/// A subagent that had finished works again when its orchestrator sends it a
/// follow-up: the source says so, since a repeated spawn never changes status.
@Suite struct ResumedSubagentTests {
    @Test func aResumeMakesAFinishedSubagentWorkAgainFromTheResume() throws {
        var state = finishedSubagent()
        state.apply(event(.agentResumed(id: "a"), at: 20))

        let a = try agent("a", in: state)
        #expect(a.status == .working)
        #expect(a.endedAt == nil)
        #expect(a.currentTool == nil)
        #expect(a.startedAt == at(1))
        #expect(a.runStartedAt == at(20))
    }

    /// The hand-back's stop can arrive after the resume; it ended the run before.
    @Test func aStopOlderThanTheResumeLeavesItWorkingANewerOneEndsIt() throws {
        var state = finishedSubagent()
        state.apply(event(.agentResumed(id: "a"), at: 20))
        state.apply(event(.agentFinished(id: "a"), at: 10))
        #expect(try agent("a", in: state).status == .working)

        state.apply(event(.agentFinished(id: "a"), at: 20))
        let a = try agent("a", in: state)
        #expect(a.status == .done)
        #expect(a.endedAt == at(20))
    }

    /// A resume delivered after a later end belongs to a run that is over
    /// already. Hook times are whole seconds: one from the end's second
    /// may be newer.
    @Test func aResumeSurelyOlderThanTheEndLeavesItDone() throws {
        var state = finishedSubagent()
        state.apply(event(.agentResumed(id: "a"), at: 9))
        let a = try agent("a", in: state)
        #expect(a.status == .done)
        #expect(a.endedAt == at(10))
        #expect(a.runStartedAt == at(1))

        state.apply(event(.agentResumed(id: "a"), at: 10))
        let resumed = try agent("a", in: state)
        #expect(resumed.status == .working)
        #expect(resumed.runStartedAt == at(10))
    }

    @Test func aResumeOfAnUnknownSubagentStartsItWorkingFromTheResume() throws {
        var state = CollectiveState()
        state.apply(event(.promptSubmitted("go"), at: 0))
        state.apply(event(.agentResumed(id: "late"), at: 20))
        let late = try agent("late", in: state)
        #expect(late.status == .working)
        #expect(late.parent == .root)
        #expect(late.runStartedAt == at(20))
    }

    /// The orchestrator ends its turn right after it sends the follow-up:
    /// the session works in the background, it doesn't wait for the user.
    @Test func aResumedBackgroundSubagentKeepsTheCardWorkingAfterTheTurn() throws {
        var state = finishedSubagent(background: true)
        state.apply(event(.agentResumed(id: "a"), at: 20))
        state.apply(event(.turnEnded(), at: 21))

        let popover = PopoverModel(state: state, now: at(30), settings: PopoverSettings(idleAfter: .never))
        let item = try #require(popover.sessions.first)
        #expect(item.state == .backgroundWorking)
        #expect(item.cardState == .working)
        #expect(item.rowStatus == .backgroundAgents(count: 1))
        #expect(popover.needYouCount == 0)
    }

    /// An idle report surely newer than the resume ended the new run already.
    @Test func aResumeSurelyOlderThanAnIdleReportLeavesItDone() throws {
        var state = finishedSubagent()
        state.apply(event(.activityReported(.idle), at: 21))
        state.apply(event(.agentResumed(id: "a"), at: 20))
        #expect(try agent("a", in: state).status == .done)
    }

    @Test func anIdleReportOlderThanTheResumeLeavesTheNewRunWorking() throws {
        var state = finishedSubagent()
        state.apply(event(.agentResumed(id: "a"), at: 20))
        state.apply(event(.activityReported(.idle), at: 15))
        let a = try agent("a", in: state)
        #expect(a.status == .working)
        #expect(a.endedAt == nil)

        state.apply(event(.activityReported(.idle), at: 22))
        #expect(try agent("a", in: state).status == .done)
    }

    @Test func aResumeAfterTheArchiveUnarchivesTheSubagent() {
        var state = finishedSubagent()
        state.archive(.agent(key, .subagent("a")), at: at(15))
        state.apply(event(.agentResumed(id: "a"), at: 20))
        #expect(!state.isArchived(.subagent("a"), in: key))
    }

    /// Strictly newer only, so the replayed backlog keeps the mark.
    @Test func aResumeNotNewerThanTheArchiveKeepsItArchived() {
        var state = finishedSubagent()
        state.archive(.agent(key, .subagent("a")), at: at(20))
        state.apply(event(.agentResumed(id: "a"), at: 20))
        #expect(state.isArchived(.subagent("a"), in: key))
    }

    /// A session presumed dead comes back with the event; the resumed
    /// subagent works, with nothing left of the sweep's guess.
    @Test func aResumeInAStaleSessionMakesTheSubagentWork() throws {
        var state = finishedSubagent()
        state.apply(event(spawn("b"), at: 11))
        state.markStale(now: at(15), silenceTimeout: 1, waitingTimeout: 1) { _ in nil }
        #expect(try agent("b", in: state).status == .stale)

        state.apply(event(.agentResumed(id: "a"), at: 20))
        state.apply(event(.agentResumed(id: "b"), at: 20))
        #expect(state.sessions[key]?.root.status == .working)
        #expect(try agent("a", in: state).status == .working)
        #expect(try agent("b", in: state).status == .working)

        // Nothing for a later revival to bring back.
        state.apply(event(.agentFinished(id: "b"), at: 22))
        state.markStale(now: at(30), silenceTimeout: 1, waitingTimeout: 1) { _ in nil }
        state.apply(event(.toolStarted(agent: .root, ToolActivity(name: "Read")), at: 31))
        #expect(try agent("b", in: state).status == .done)
    }

    /// The row counts the runtime from the resume, but keeps
    /// its place by the first start.
    @Test func aResumedRowCountsFromTheResumeAndKeepsItsPosition() throws {
        var state = finishedSubagent()
        state.apply(event(spawn("b"), at: 5))
        state.apply(event(.agentResumed(id: "a"), at: 20))

        var expansion = PopoverExpansion()
        expansion.toggleSubagents(key, isOpen: false)
        let popover = PopoverModel(
            state: state, now: at(30), settings: PopoverSettings(idleAfter: .never), expansion: expansion
        )
        let list = try #require(popover.sessions.first?.subagentToggle?.list)
        let rows = list.entries.compactMap(\.row)
        let a = try #require(rows.first { $0.ref == .subagent("a") })
        #expect(a.runningSince == at(20))
        #expect((a.position, a.total) == (1, 2))
        #expect(rows.map(\.ref) == [.subagent("b"), .subagent("a")])
    }
}
