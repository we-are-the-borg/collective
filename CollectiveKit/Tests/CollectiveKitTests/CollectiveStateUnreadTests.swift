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

private func state(_ events: [(AgentEvent.Kind, TimeInterval)], session: SessionKey = key) -> CollectiveState {
    var state = CollectiveState()
    for (kind, seconds) in events { state.apply(event(kind, at: seconds, session: session)) }
    return state
}

@Suite struct CollectiveStateUnreadTests {
    @Test(arguments: [TurnOutcome.completed, .failed])
    func aTurnThatEndsOnItsOwnLeavesTheSessionUnread(outcome: TurnOutcome) {
        let state = state([(.promptSubmitted("go"), 0), (.turnEnded(outcome), 10)])

        #expect(state.isUnread(key))
        #expect(state.sessions[key]?.turnEndedAt == at(10))
    }

    /// The user was there when they stopped it.
    @Test func anInterruptedTurnLeavesNothingUnread() {
        let state = state([(.promptSubmitted("go"), 0), (.turnEnded(.interrupted), 10)])

        #expect(!state.isUnread(key))
        #expect(state.sessions[key]?.turnEndedAt == nil)
    }

    @Test func aSubagentFinishingAloneLeavesNothingUnread() {
        let state = state([
            (.promptSubmitted("go"), 0),
            (.agentSpawned(id: "a", parent: .root, spec: AgentSpec(type: "Explore")), 1),
            (.replied(agent: .subagent("a"), "found it"), 5),
            (.agentFinished(id: "a"), 5),
        ])

        #expect(!state.isUnread(key))
    }

    /// A report that no turn runs is how a source tells of Esc or Ctrl-C.
    @Test func aReportEndingTheTurnLeavesNothingUnread() {
        let state = state([(.promptSubmitted("go"), 0), (.activityReported(.working), 1), (.activityReported(.idle), 10)])

        #expect(state.sessions[key]?.root.status == .waiting)
        #expect(!state.isUnread(key))
    }

    @Test func aTurnTheSweepGuessesInterruptedLeavesNothingUnread() {
        var state = state([(.promptSubmitted("go"), 0)])
        state.markInterrupted(now: at(600), idleTimeout: 60, toolTimeout: 600)

        #expect(state.sessions[key]?.root.status == .waiting)
        #expect(!state.isUnread(key))
    }

    @Test(arguments: [AgentEvent.Kind.promptSubmitted("again"), .turnStarted])
    func theNextTurnsStartMakesTheSessionRead(kind: AgentEvent.Kind) {
        let state = state([(.promptSubmitted("go"), 0), (.turnEnded(), 10), (kind, 20)])

        #expect(!state.isUnread(key))
        #expect(state.sessions[key]?.turnEndedAt == nil)
    }

    /// Hooks run async: the stop of the turn before can arrive after the next prompt.
    @Test func aStopOlderThanTheNewestStartLeavesNothingUnread() {
        let state = state([(.promptSubmitted("go"), 0), (.promptSubmitted("again"), 20), (.turnEnded(), 10)])

        #expect(!state.isUnread(key))
        #expect(state.sessions[key]?.turnEndedAt == nil)
    }

    /// The start of the turn that just ended, arriving after its stop.
    @Test func aStartOlderThanTheEndArrivingLateKeepsTheSessionUnread() {
        let state = state([(.turnEnded(), 10), (.promptSubmitted("go"), 0)])

        #expect(state.isUnread(key))
        #expect(state.sessions[key]?.turnEndedAt == at(10))
    }

    @Test func twoEndsKeepTheNewest() {
        let state = state([(.promptSubmitted("go"), 0), (.turnEnded(), 12), (.turnEnded(.failed), 10)])

        #expect(state.sessions[key]?.turnEndedAt == at(12))
    }

    /// An ended session stays unread in Finished; the end itself isn't news.
    @Test func theSessionsEndKeepsItUnread() {
        let state = state([(.promptSubmitted("go"), 0), (.turnEnded(), 10), (.sessionEnded, 30)])

        #expect(state.sessions[key]?.endedAt == at(30))
        #expect(state.isUnread(key))
    }

    @Test func anEndWithoutATurnLeavesNothingUnread() {
        let state = state([(.promptSubmitted("go"), 0), (.sessionEnded, 30)])

        #expect(!state.isUnread(key))
    }

    @Test func aReadMarkUpToTheEndMakesItReadUntilTheNextEnd() {
        var state = state([(.promptSubmitted("go"), 0), (.turnEnded(), 10)])

        state.markRead(key, upTo: at(10))
        #expect(!state.isUnread(key))

        state.apply(event(.promptSubmitted("again"), at: 20))
        state.apply(event(.turnEnded(), at: 30))
        #expect(state.isUnread(key))
    }

    @Test func aReadMarkNeverMovesBack() {
        var state = state([(.promptSubmitted("go"), 0), (.turnEnded(), 10)])

        state.markRead(key, upTo: at(10))
        state.markRead(key, upTo: at(5))

        #expect(state.readMarks[key] == at(10))
        #expect(!state.isUnread(key))
    }

    @Test func anArchivedSessionIsNeverUnread() {
        var state = state([(.promptSubmitted("go"), 0), (.turnEnded(), 10)])

        state.archive(.session(key), at: at(15))
        #expect(!state.isUnread(key))

        state.unarchive(.session(key))
        #expect(state.isUnread(key))
    }

    @Test func aSessionOnStandbyIsNeverUnread() {
        let state = state([(.promptSubmitted("go"), 0), (.turnEnded(), 10), (.activityReported(.standby), 11)])

        #expect(state.shownSession(key) == nil)
        #expect(!state.isUnread(key))
    }

    @Test func anUnknownSessionIsNotUnread() {
        #expect(!CollectiveState().isUnread(key))
    }

    /// A later run under the same id keeps the mark, and its ends count by date.
    @Test func aLaterRunUnderTheSameKeyFollowsTheSameRule() {
        var state = state([
            (.sessionStarted(cwd: "/work", pid: 1), 0), (.promptSubmitted("go"), 1), (.turnEnded(), 10), (.sessionEnded, 11),
        ])
        state.markRead(key, upTo: at(10))

        state.apply(event(.sessionStarted(cwd: "/work", pid: 2), at: 100))
        #expect(state.sessions[key]?.startedAt == at(100))
        #expect(!state.isUnread(key))

        state.apply(event(.promptSubmitted("more"), at: 101))
        state.apply(event(.turnEnded(), at: 110))
        #expect(state.isUnread(key))
    }

    /// The jump button and a notification click read the session up to its turn end.
    @Test func markingTheTurnReadCoversItsEndAndSaysItChanged() {
        var state = state([(.promptSubmitted("go"), 0), (.turnEnded(), 10)])

        let changed = state.markTurnRead(key)
        #expect(changed)
        #expect(!state.isUnread(key))
        #expect(state.readMarks[key] == at(10))
        let changedAgain = state.markTurnRead(key)
        #expect(!changedAgain)
    }

    @Test func markingATurnReadThatHasNoEndChangesNothing() {
        var state = state([(.promptSubmitted("go"), 0)])

        let changed = state.markTurnRead(key)
        #expect(!changed)
        let changedOther = state.markTurnRead(other)
        #expect(!changedOther)
        #expect(state.readMarks.isEmpty)
    }

    /// Marks restored before the backlog replays keep what they cover read.
    @Test func restoredMarksKeepReplayedEndsUpToThemRead() {
        var state = CollectiveState()
        state.restoreReadMarks([key: at(10), other: at(10)])

        for (kind, seconds) in [(AgentEvent.Kind.promptSubmitted("go"), 0.0), (.turnEnded(), 10)] {
            state.apply(event(kind, at: seconds, session: key))
        }
        for (kind, seconds) in [(AgentEvent.Kind.promptSubmitted("go"), 0.0), (.turnEnded(), 10.5)] {
            state.apply(event(kind, at: seconds, session: other))
        }

        #expect(!state.isUnread(key))
        #expect(state.isUnread(other))
    }

    /// For a first launch without saved marks: what the backlog brought counts as read.
    @Test func markingAllReadCoversEveryTurnEndKnownSoFar() {
        var state = state([(.promptSubmitted("go"), 0), (.turnEnded(), 10)])
        state.apply(event(.promptSubmitted("go"), at: 0, session: other))
        state.apply(event(.turnEnded(.failed), at: 20, session: other))

        state.markAllRead()
        #expect(!state.isUnread(key))
        #expect(!state.isUnread(other))
        #expect(state.readMarks == [key: at(10), other: at(20)])

        state.apply(event(.promptSubmitted("again"), at: 30))
        state.apply(event(.turnEnded(), at: 40))
        #expect(state.isUnread(key))
    }

    /// A source can write the final stop before the session's end but
    /// deliver it after; the turn ended before the session did.
    @Test(arguments: [(TurnOutcome.completed, 25.0), (.failed, 30.0)])
    func aStopArrivingAfterTheEndItPrecedesLeavesTheSessionUnread(outcome: TurnOutcome, seconds: TimeInterval) {
        let state = state([(.promptSubmitted("go"), 0), (.sessionEnded, 30), (.turnEnded(outcome), seconds)])

        #expect(state.isUnread(key))
        #expect(state.sessions[key]?.turnEndedAt == at(seconds))
    }

    @Test func anInterruptionArrivingAfterTheEndLeavesNothingUnread() {
        let state = state([(.promptSubmitted("go"), 0), (.sessionEnded, 30), (.turnEnded(.interrupted), 25)])

        #expect(!state.isUnread(key))
    }

    /// Nothing after its end belongs to the session, a stop included.
    @Test func aStopAfterTheEndChangesNothing() {
        let ended = state([(.promptSubmitted("go"), 0), (.sessionEnded, 30)])
        var stopped = ended
        stopped.apply(event(.turnEnded(), at: 31))

        #expect(!stopped.isUnread(key))
        #expect(stopped == ended)
    }

    /// A late stop of the turn before stays ignored after the end too.
    @Test func aStopOlderThanTheNewestStartArrivingAfterTheEndLeavesNothingUnread() {
        let state = state([
            (.promptSubmitted("go"), 0), (.promptSubmitted("again"), 20), (.sessionEnded, 30), (.turnEnded(), 10),
        ])

        #expect(!state.isUnread(key))
    }
}
