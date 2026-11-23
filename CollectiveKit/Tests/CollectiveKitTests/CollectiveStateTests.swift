import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

private let source: SourceID = "test-tool"
private let key = SessionKey(source: source, sessionID: "s1")
private let t0 = Date(timeIntervalSince1970: 1_000)

private func event(_ kind: AgentEvent.Kind, at seconds: TimeInterval = 0, session: SessionKey = key) -> AgentEvent {
    AgentEvent(session: session, timestamp: t0.addingTimeInterval(seconds), kind: kind)
}

private func state(_ kinds: [AgentEvent.Kind]) -> CollectiveState {
    var state = CollectiveState()
    for (offset, kind) in kinds.enumerated() {
        state.apply(event(kind, at: TimeInterval(offset)))
    }
    return state
}

@Suite struct CollectiveStateTests {
    @Test func promptMakesOrchestratorWork() {
        let s = state([.sessionStarted(cwd: "/p", pid: 42), .promptSubmitted("do it")])
        let session = s.sessions[key]!
        #expect(session.root.status == .working)
        #expect(session.root.spec.prompt == "do it")
        #expect(session.cwd == "/p")
        #expect(session.pid == 42)
        #expect(s.activeAgentCount == 1)
    }

    @Test func parallelSubagentsCountAndFinish() {
        var s = state([
            .promptSubmitted("orchestrate"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(type: "explore", title: "A")),
            .agentSpawned(id: "b", parent: .root, spec: AgentSpec(type: "review", title: "B")),
        ])
        #expect(s.activeAgentCount == 3)
        #expect(s.sessions[key]!.children(of: .root).map(\.spec.title) == ["A", "B"])

        s.apply(event(.agentFinished(id: "a"), at: 10))
        #expect(s.activeAgentCount == 2)
        #expect(s.sessions[key]!.agents[.subagent("a")]!.status == .done)
    }

    @Test func nestedSubagentsFormATree() {
        let s = state([
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec()),
            .agentSpawned(id: "a1", parent: .subagent("a"), spec: AgentSpec()),
        ])
        let session = s.sessions[key]!
        #expect(session.children(of: .subagent("a")).map(\.id) == [.subagent("a1")])
    }

    @Test func finishingAParentFinishesItsDescendants() {
        let s = state([
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec()),
            .agentSpawned(id: "a1", parent: .subagent("a"), spec: AgentSpec()),
            .agentFinished(id: "a"),
        ])
        #expect(s.sessions[key]!.agents[.subagent("a1")]!.status == .done)
    }

    @Test func unknownParentFallsBackToRoot() {
        let s = state([.agentSpawned(id: "x", parent: .subagent("ghost"), spec: AgentSpec())])
        #expect(s.sessions[key]!.agents[.subagent("x")]!.parent == .root)
    }

    @Test func toolActivityOfUnseenSubagentCreatesIt() {
        let s = state([.toolStarted(agent: .subagent("late"), ToolActivity(name: "Bash", detail: "ls"))])
        let agent = s.sessions[key]!.agents[.subagent("late")]!
        #expect(agent.currentTool == ToolActivity(name: "Bash", detail: "ls"))
        #expect(agent.status == .working)
    }

    @Test func lastToolCallOutlivesItsFinishUntilTheNextStart() {
        var s = state([
            .promptSubmitted("go"),
            .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "ls")),
            .toolFinished(agent: .root),
        ])
        var root = s.sessions[key]!.root
        #expect(root.currentTool == nil)
        #expect(root.lastToolCall == ToolCall(tool: ToolActivity(name: "Bash", detail: "ls"), startedAt: t0.addingTimeInterval(1)))

        s.apply(event(.toolStarted(agent: .root, ToolActivity(name: "Read")), at: 5))
        root = s.sessions[key]!.root
        #expect(root.lastToolCall == ToolCall(tool: ToolActivity(name: "Read"), startedAt: t0.addingTimeInterval(5)))
    }

    @Test func respawnMergesSpecInsteadOfDuplicating() {
        let s = state([
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(type: "explore", title: "A")),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(prompt: "full prompt")),
        ])
        let spec = s.sessions[key]!.agents[.subagent("a")]!.spec
        #expect(spec == AgentSpec(type: "explore", title: "A", prompt: "full prompt"))
        #expect(s.sessions[key]!.agents.count == 2)
    }

    @Test func turnEndKeepsBackgroundSubagentsRunning() {
        let s = state([
            .promptSubmitted("go"),
            .agentSpawned(id: "bg", parent: .root, spec: AgentSpec()),
            .turnEnded(),
        ])
        let session = s.sessions[key]!
        #expect(session.root.status == .waiting)
        #expect(session.agents[.subagent("bg")]!.status == .working)
        #expect(s.activeAgentCount == 1)
    }

    @Test func sessionEndFinishesEverything() {
        let s = state([
            .promptSubmitted("go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec()),
            .sessionEnded,
        ])
        #expect(s.activeAgentCount == 0)
        #expect(s.sessions[key]!.endedAt != nil)
    }

    @Test func deadProcessMakesSessionStale() {
        var s = state([
            .sessionStarted(cwd: nil, pid: 99),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec()),
        ])
        s.markStale(now: t0.addingTimeInterval(5), silenceTimeout: 600, waitingTimeout: 600) { $0 == 99 ? nil : t0 }
        let session = s.sessions[key]!
        #expect(session.agents[.subagent("a")]!.status == .stale)
        #expect(session.endedAt != nil)
        #expect(s.activeAgentCount == 0)
    }

    @Test func livingProcessIsNeverStaleEvenWhenSilent() {
        var s = state([.sessionStarted(cwd: nil, pid: 99), .promptSubmitted("go")])
        s.markStale(now: t0.addingTimeInterval(10_000), silenceTimeout: 600, waitingTimeout: 600) { _ in t0.addingTimeInterval(-60) }
        #expect(s.sessions[key]!.root.status == .working)
    }

    @Test func processStartedLaterThanTheSessionIsAReusedPid() {
        var s = state([.sessionStarted(cwd: nil, pid: 99), .promptSubmitted("go")])
        s.markStale(now: t0.addingTimeInterval(60), silenceTimeout: 600, waitingTimeout: 600) { _ in t0.addingTimeInterval(3) }
        #expect(s.sessions[key]!.root.status == .stale)
    }

    @Test func processStartingWithinTheTimestampToleranceIsTheSessionsOwn() {
        // Event times are truncated to whole seconds, so the real process can
        // seem to start shortly after the session's first event.
        var s = state([.sessionStarted(cwd: nil, pid: 99), .promptSubmitted("go")])
        s.markStale(now: t0.addingTimeInterval(60), silenceTimeout: 600, waitingTimeout: 600) { _ in t0.addingTimeInterval(2) }
        #expect(s.sessions[key]!.root.status == .working)
    }

    @Test func silenceWithoutPidMakesSessionStale() {
        var s = state([.promptSubmitted("go")])
        s.markStale(now: t0.addingTimeInterval(599), silenceTimeout: 600, waitingTimeout: 600) { _ in nil }
        #expect(s.activeAgentCount == 1)
        s.markStale(now: t0.addingTimeInterval(700), silenceTimeout: 600, waitingTimeout: 600) { _ in nil }
        #expect(s.activeAgentCount == 0)
    }

    /// Some tools never send a session end, so a session waiting for the user
    /// would otherwise vanish after the short silence limit.
    @Test func waitingAfterTurnEndWithoutPidUsesTheWaitingTimeout() {
        var s = state([.promptSubmitted("go"), .turnEnded()])
        s.markStale(now: t0.addingTimeInterval(1 + 40 * 60), silenceTimeout: 30 * 60, waitingTimeout: 12 * 3_600) { _ in nil }
        #expect(s.sessions[key]!.root.status == .waiting)
        #expect(s.sessions[key]!.endedAt == nil)
        s.markStale(now: t0.addingTimeInterval(1 + 12 * 3_600 + 1), silenceTimeout: 30 * 60, waitingTimeout: 12 * 3_600) { _ in nil }
        #expect(s.sessions[key]!.root.status == .stale)
    }

    /// How a turn ended is for notification rules and for whether it leaves
    /// the session unread; the store shows every end alike.
    @Test(arguments: [TurnOutcome.interrupted, .failed])
    func everyTurnOutcomeLeavesTheSameState(outcome: TurnOutcome) {
        let before: [AgentEvent.Kind] = [
            .sessionStarted(cwd: "/p", pid: 42),
            .promptSubmitted("go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(isBackground: true)),
            .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "make"), callID: "c1"),
            .permissionRequested(agent: .root, ToolActivity(name: "Bash", detail: "make")),
            .replied(agent: .root, "stopped"),
        ]
        // `sessions` is `private(set)`: compare all sessions with only
        // `turnEndedAt` neutralised, plus the marks.
        let ended = state(before + [.turnEnded(outcome)])
        let completed = state(before + [.turnEnded(.completed)])
        func neutral(_ s: CollectiveState) -> [SessionKey: Session] {
            s.sessions.mapValues { var v = $0; v.turnEndedAt = nil; return v }
        }
        #expect(neutral(ended) == neutral(completed))
        #expect(ended.archiveMarks == completed.archiveMarks)
        #expect(ended.readMarks == completed.readMarks)
    }

    @Test func runningTurnWithoutPidKeepsTheSilenceTimeout() {
        var s = state([.promptSubmitted("go"), .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "make"))])
        s.markStale(now: t0.addingTimeInterval(1 + 30 * 60 + 1), silenceTimeout: 30 * 60, waitingTimeout: 12 * 3_600) { _ in nil }
        #expect(s.sessions[key]!.root.status == .stale)
    }

    /// A permission dialog waits for the user like a turn's end: nothing is due.
    @Test func aRequestWithoutPidUsesTheWaitingTimeout() {
        var s = state([.promptSubmitted("go"), .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "make"))])
        s.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash", detail: "make")), at: 1))
        s.markStale(now: t0.addingTimeInterval(1 + 40 * 60), silenceTimeout: 30 * 60, waitingTimeout: 12 * 3_600) { _ in nil }
        #expect(s.sessions[key]!.endedAt == nil)
        #expect(s.awaitsPermission)
        s.markStale(now: t0.addingTimeInterval(1 + 12 * 3_600 + 1), silenceTimeout: 30 * 60, waitingTimeout: 12 * 3_600) { _ in nil }
        #expect(s.sessions[key]!.root.status == .stale)
        #expect(!s.awaitsPermission)
    }

    /// Guessed waiting is only a guess: the turn may still run.
    @Test func guessedInterruptionWithoutPidKeepsTheSilenceTimeout() {
        var s = state([.promptSubmitted("go")])
        s.markInterrupted(now: t0.addingTimeInterval(200), idleTimeout: 2 * 60, toolTimeout: 30 * 60)
        #expect(s.sessions[key]!.root.status == .waiting)
        s.markStale(now: t0.addingTimeInterval(30 * 60 + 1), silenceTimeout: 30 * 60, waitingTimeout: 12 * 3_600) { _ in nil }
        #expect(s.sessions[key]!.root.status == .stale)
    }

    @Test func workingSubagentWithoutPidKeepsTheSilenceTimeout() {
        var s = state([
            .promptSubmitted("go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(type: "explore", title: "A", isBackground: true)),
            .turnEnded(),
        ])
        #expect(s.sessions[key]!.root.status == .waiting)
        #expect(s.sessions[key]!.agents[.subagent("a")]!.status == .working)
        s.markStale(now: t0.addingTimeInterval(2 + 30 * 60 + 1), silenceTimeout: 30 * 60, waitingTimeout: 12 * 3_600) { _ in nil }
        #expect(s.sessions[key]!.root.status == .stale)
    }

    @Test func freshSessionWithoutPidWaitsForItsFirstPrompt() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil)])
        s.markStale(now: t0.addingTimeInterval(40 * 60), silenceTimeout: 30 * 60, waitingTimeout: 12 * 3_600) { _ in nil }
        #expect(s.sessions[key]!.root.status == .waiting)
        #expect(s.sessions[key]!.endedAt == nil)
    }

    @Test func endedSessionStaysDoneWhenSwept() {
        var s = state([.sessionStarted(cwd: nil, pid: 99), .promptSubmitted("go"), .sessionEnded])
        let before = s
        s.markStale(now: t0.addingTimeInterval(60), silenceTimeout: 600, waitingTimeout: 600) { _ in nil }
        #expect(s == before)
        #expect(s.sessions[key]!.root.status == .done)
    }

    @Test func pruneDropsOnlyLongEndedSessions() {
        let other = SessionKey(source: "other-tool", sessionID: "s1")
        var s = CollectiveState()
        s.apply(event(.sessionEnded, at: 0))
        s.apply(event(.promptSubmitted("still running"), at: 0, session: other))

        s.prune(now: t0.addingTimeInterval(30), retention: 60)
        #expect(s.sessions.count == 2)
        s.prune(now: t0.addingTimeInterval(61), retention: 60)
        #expect(Array(s.sessions.keys) == [other])
    }

    @Test func sameSessionIdFromDifferentSourcesStaysSeparate() {
        var s = CollectiveState()
        s.apply(event(.promptSubmitted("a")))
        s.apply(event(.promptSubmitted("b"), session: SessionKey(source: "other-tool", sessionID: "s1")))
        #expect(s.sessions.count == 2)
        #expect(s.activeAgentCount == 2)
    }

    // MARK: Final states

    @Test func finishedSubagentStaysDoneWhenLateToolEventsArrive() {
        let s = state([
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec()),
            .agentFinished(id: "a"),
            .toolStarted(agent: .subagent("a"), ToolActivity(name: "Bash")),
        ])
        let agent = s.sessions[key]!.agents[.subagent("a")]!
        #expect(agent.status == .done)
        #expect(agent.currentTool == nil)
    }

    @Test func toolStartedDoesNotReviveWaitingOrchestrator() {
        let s = state([
            .promptSubmitted("go"),
            .turnEnded(),
            .toolStarted(agent: .root, ToolActivity(name: "Read")),
        ])
        let root = s.sessions[key]!.root
        #expect(root.status == .waiting)
        #expect(root.currentTool == nil)
    }

    @Test func lateSpawnDoesNotReviveFinishedOrWaitingParents() {
        let s = state([
            .promptSubmitted("go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec()),
            .agentFinished(id: "a"),
            .turnEnded(),
            .agentSpawned(id: "a1", parent: .subagent("a"), spec: AgentSpec()),
            .agentSpawned(id: "b", parent: .root, spec: AgentSpec()),
        ])
        let session = s.sessions[key]!
        #expect(session.agents[.subagent("a")]!.status == .done)
        #expect(session.root.status == .waiting)
    }

    @Test func respawnOfFinishedSubagentKeepsItDone() {
        let s = state([
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(type: "explore")),
            .agentFinished(id: "a"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(title: "late title")),
        ])
        let agent = s.sessions[key]!.agents[.subagent("a")]!
        #expect(agent.status == .done)
        #expect(agent.spec == AgentSpec(type: "explore", title: "late title"))
    }

    @Test func nextPromptRevivesOrchestratorBeforeSessionEnd() {
        let s = state([.promptSubmitted("one"), .turnEnded(), .promptSubmitted("two")])
        #expect(s.sessions[key]!.root.status == .working)
    }

    @Test func nothingChangesAfterSessionEnded() {
        var s = state([
            .promptSubmitted("go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec()),
            .sessionEnded,
        ])
        let before = s
        let late: [AgentEvent.Kind] = [
            .promptSubmitted("again"),
            .agentSpawned(id: "b", parent: .root, spec: AgentSpec()),
            .toolStarted(agent: .subagent("a"), ToolActivity(name: "Bash")),
            .toolStarted(agent: .subagent("ghost"), ToolActivity(name: "Bash")),
            .turnEnded(),
        ]
        for (offset, kind) in late.enumerated() {
            s.apply(event(kind, at: 100 + TimeInterval(offset)))
        }
        #expect(s == before)
    }

    // MARK: Revocable stale

    /// Root working, `a` working, `b` done, `bg` working in the background
    /// while the orchestrator waits; then the sweep finds the process gone.
    private func swept() -> CollectiveState {
        var s = state([
            .sessionStarted(cwd: nil, pid: 99),
            .promptSubmitted("go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec()),
            .agentSpawned(id: "b", parent: .root, spec: AgentSpec()),
            .agentFinished(id: "b"),
        ])
        s.markStale(now: t0.addingTimeInterval(50), silenceTimeout: 600, waitingTimeout: 600) { _ in nil }
        return s
    }

    private func statuses(_ s: CollectiveState) -> [AgentRef: AgentStatus] {
        s.sessions[key]!.agents.mapValues(\.status)
    }

    @Test func laterEventRevokesStale() {
        var s = swept()
        #expect(statuses(s) == [.root: .stale, .subagent("a"): .stale, .subagent("b"): .done])

        s.apply(event(.toolStarted(agent: .subagent("a"), ToolActivity(name: "Bash")), at: 60))
        let session = s.sessions[key]!
        #expect(session.endedAt == nil)
        #expect(statuses(s) == [.root: .working, .subagent("a"): .working, .subagent("b"): .done])
        #expect(session.root.endedAt == nil)
        #expect(session.agents[.subagent("a")]!.endedAt == nil)
        #expect(session.agents[.subagent("a")]!.currentTool == ToolActivity(name: "Bash"))
        #expect(session.agents[.subagent("b")]!.endedAt == t0.addingTimeInterval(4))
        #expect(s.activeAgentCount == 2)
    }

    @Test func revokedStaleRestoresTheStatusBeforeTheEvent() {
        // The root was waiting when swept; the event then applies on top of that.
        var s = state([.sessionStarted(cwd: nil, pid: 99), .promptSubmitted("one"), .turnEnded()])
        s.markStale(now: t0.addingTimeInterval(50), silenceTimeout: 600, waitingTimeout: 600) { _ in nil }
        s.apply(event(.toolStarted(agent: .root, ToolActivity(name: "Read")), at: 60))
        #expect(s.sessions[key]!.root.status == .waiting)

        s.markStale(now: t0.addingTimeInterval(70), silenceTimeout: 600, waitingTimeout: 600) { _ in nil }
        s.apply(event(.promptSubmitted("two"), at: 80))
        #expect(s.sessions[key]!.root.status == .working)
        #expect(s.sessions[key]!.root.spec.prompt == "two")
    }

    @Test func turnEndOnAStaleSessionLeavesSubagentsRunning() {
        var s = swept()
        s.apply(event(.turnEnded(), at: 60))
        #expect(statuses(s) == [.root: .waiting, .subagent("a"): .working, .subagent("b"): .done])
        #expect(s.sessions[key]!.endedAt == nil)
    }

    @Test func sessionEndOnAStaleSessionIsFinal() {
        var s = swept()
        s.apply(event(.sessionEnded, at: 60))
        let session = s.sessions[key]!
        #expect(statuses(s) == [.root: .done, .subagent("a"): .done, .subagent("b"): .done])
        #expect(session.endedAt == t0.addingTimeInterval(60))
        #expect(session.root.endedAt == t0.addingTimeInterval(60))
        #expect(session.agents[.subagent("a")]!.endedAt == t0.addingTimeInterval(60))
        #expect(session.agents[.subagent("b")]!.endedAt == t0.addingTimeInterval(4))

        let before = s
        s.apply(event(.promptSubmitted("zombie"), at: 70))
        s.apply(event(.toolStarted(agent: .subagent("a"), ToolActivity(name: "Bash")), at: 71))
        s.markStale(now: t0.addingTimeInterval(80), silenceTimeout: 600, waitingTimeout: 600) { _ in nil }
        #expect(s == before)
    }

    // MARK: Parent backfill

    @Test func respawnCanSetTheParentLater() {
        let s = state([
            .agentSpawned(id: "p", parent: .root, spec: AgentSpec()),
            .agentSpawned(id: "c", parent: .root, spec: AgentSpec()),
            .agentSpawned(id: "c", parent: .subagent("p"), spec: AgentSpec()),
        ])
        let session = s.sessions[key]!
        #expect(session.agents[.subagent("c")]!.parent == .subagent("p"))
        #expect(session.children(of: .root).map(\.id) == [.subagent("p")])
        #expect(session.children(of: .subagent("p")).map(\.id) == [.subagent("c")])
    }

    @Test func backfillWithUnknownParentKeepsCurrentParent() {
        let s = state([
            .toolStarted(agent: .subagent("c"), ToolActivity(name: "Bash")),
            .agentSpawned(id: "c", parent: .subagent("p"), spec: AgentSpec()),
        ])
        // "p" is unknown, so the parent stays at the root.
        #expect(s.sessions[key]!.agents[.subagent("c")]!.parent == .root)
    }

    @Test func parentBackfillRejectsCycles() {
        let s = state([
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec()),
            .agentSpawned(id: "b", parent: .subagent("a"), spec: AgentSpec()),
            .agentSpawned(id: "a", parent: .subagent("b"), spec: AgentSpec()),
            .agentSpawned(id: "a", parent: .subagent("a"), spec: AgentSpec()),
        ])
        #expect(s.sessions[key]!.agents[.subagent("a")]!.parent == .root)
        #expect(s.sessions[key]!.agents[.subagent("b")]!.parent == .subagent("a"))
    }

    // MARK: Turns without a prompt

    @Test func turnStartedRevivesOrchestratorAndKeepsItsPrompt() {
        let s = state([.promptSubmitted("original"), .turnEnded(), .turnStarted])
        let root = s.sessions[key]!.root
        #expect(root.status == .working)
        #expect(root.spec.prompt == "original")
    }

    @Test func turnStartedIsIgnoredAfterSessionEnd() {
        let s = state([.promptSubmitted("go"), .sessionEnded, .turnStarted])
        #expect(s.sessions[key]!.root.status == .done)
    }

    @Test func respawnKeepsBackgroundFlagWhenLaterSpecOmitsIt() {
        let s = state([
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(isBackground: true)),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(title: "T")),
        ])
        #expect(s.sessions[key]!.agents[.subagent("a")]!.spec.isBackground == true)
    }

    // MARK: Turn ends out of order

    /// Hooks run async, so the stop of a turn can arrive after the next
    /// prompt; it must not end the turn that is running now.
    @Test(arguments: [[1.0, 10, 8], [1, 8, 10]])
    func aLateTurnEndLeavesTheNewerTurnRunning(arrival: [TimeInterval]) {
        let kinds: [TimeInterval: AgentEvent.Kind] = [1: .promptSubmitted("one"), 8: .turnEnded(), 10: .promptSubmitted("two")]
        var s = CollectiveState()
        for seconds in arrival { s.apply(event(kinds[seconds]!, at: seconds)) }
        s.apply(event(.toolStarted(agent: .root, ToolActivity(name: "Bash")), at: 11))
        let root = s.sessions[key]!.root
        #expect(root.status == .working)
        #expect(root.currentTool == ToolActivity(name: "Bash"))
        #expect(s.activeAgentCount == 1)
    }

    @Test func aTurnEndInTimeEndsTheTurn() {
        var s = CollectiveState()
        s.apply(event(.promptSubmitted("go"), at: 1))
        s.apply(event(.turnEnded(), at: 8))
        #expect(s.sessions[key]!.root.status == .waiting)
        #expect(s.activeAgentCount == 0)
    }

    /// Hook times are whole seconds, so within one the later applied wins.
    @Test(arguments: [
        ([AgentEvent.Kind.promptSubmitted("go"), .turnEnded()], AgentStatus.waiting),
        ([.turnEnded(), .promptSubmitted("go")], .working),
    ])
    func withinOneSecondTheLaterAppliedWins(kinds: [AgentEvent.Kind], status: AgentStatus) {
        var s = CollectiveState()
        for kind in kinds { s.apply(event(kind, at: 10)) }
        #expect(s.sessions[key]!.root.status == status)
    }
}

// MARK: Last prompt

@Suite struct LastPromptTests {
    private func lastPrompt(_ s: CollectiveState) -> Date? {
        s.sessions[key]!.lastPromptAt
    }

    @Test func noPromptNoTime() {
        let s = state([
            .sessionStarted(cwd: "/p", pid: 1),
            .toolStarted(agent: .root, ToolActivity(name: "Bash")),
            .toolFinished(agent: .root),
        ])
        #expect(lastPrompt(s) == nil)
    }

    @Test func eachPromptAdvancesIt() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1), .promptSubmitted("first")])
        #expect(lastPrompt(s) == t0.addingTimeInterval(1))

        s.apply(event(.promptSubmitted("second"), at: 10))
        #expect(lastPrompt(s) == t0.addingTimeInterval(10))
    }

    @Test func aLateOlderPromptDoesNotMoveItBack() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1)])
        s.apply(event(.promptSubmitted("newer"), at: 10))
        s.apply(event(.promptSubmitted("older"), at: 5))
        #expect(lastPrompt(s) == t0.addingTimeInterval(10))
    }

    /// Only the user's prompt counts, not a background agent handing back
    /// or the work that follows.
    @Test(arguments: [
        AgentEvent.Kind.turnStarted, .toolStarted(agent: .root, ToolActivity(name: "Bash")), .toolFinished(agent: .root),
        .agentSpawned(id: "a", parent: .root, spec: AgentSpec()), .replied(agent: .root, "done"), .turnEnded(),
        .activityReported(.working), .activityReported(.waiting), .activityReported(.idle),
    ])
    func nothingButAPromptMovesIt(kind: AgentEvent.Kind) {
        var s = state([.sessionStarted(cwd: "/p", pid: 1), .promptSubmitted("go")])
        s.apply(event(kind, at: 10))
        #expect(lastPrompt(s) == t0.addingTimeInterval(1))
    }

    @Test func anEndedSessionKeepsItsLastPrompt() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1), .promptSubmitted("go"), .sessionEnded])
        s.apply(event(.promptSubmitted("late"), at: 10))
        #expect(lastPrompt(s) == t0.addingTimeInterval(1))
    }
}

// MARK: Replies

@Suite struct ReplyTests {
    private func reply(_ s: CollectiveState, of agent: AgentRef = .root) -> String? {
        s.sessions[key]!.agents[agent]?.reply
    }

    /// One finished turn: the root answered "one" at 1 s, subagent `a` gave "result".
    private func answered() -> CollectiveState {
        var s = CollectiveState()
        s.apply(event(.promptSubmitted("go"), at: 0))
        s.apply(event(.agentSpawned(id: "a", parent: .root, spec: AgentSpec()), at: 0))
        s.apply(event(.replied(agent: .subagent("a"), "result"), at: 1))
        s.apply(event(.agentFinished(id: "a"), at: 1))
        s.apply(event(.replied(agent: .root, "one"), at: 1))
        s.apply(event(.turnEnded(), at: 1))
        return s
    }

    @Test func aReplyStaysAfterTheTurnEnded() {
        let s = answered()
        #expect(reply(s) == "one")
        #expect(reply(s, of: .subagent("a")) == "result")
        #expect(s.sessions[key]!.root.status == .waiting)
    }

    @Test(arguments: [AgentEvent.Kind.promptSubmitted("next"), .turnStarted])
    func aNewTurnClearsTheRootsReplyAndKeepsTheSubagents(start: AgentEvent.Kind) {
        var s = answered()
        s.apply(event(start, at: 5))
        #expect(reply(s) == nil)
        #expect(reply(s, of: .subagent("a")) == "result")
    }

    /// A turn started by a prompt and one the orchestrator starts on its own
    /// each get a reply of their own: told apart by when it was given.
    @Test func promptsAndHandBacksBothStartATurnWithItsOwnReply() {
        var s = CollectiveState()
        s.apply(event(.sessionStarted(cwd: nil, pid: nil)))
        s.apply(event(.promptSubmitted("go"), at: 1))
        s.apply(event(.replied(agent: .root, "one"), at: 2))
        s.apply(event(.turnEnded(), at: 2))
        #expect(s.sessions[key]!.rootRepliedAt == t0.addingTimeInterval(2))
        s.apply(event(.turnStarted, at: 3))
        #expect(reply(s) == nil)
        #expect(s.sessions[key]!.rootRepliedAt == nil)
        s.apply(event(.replied(agent: .root, "two"), at: 4))
        s.apply(event(.turnEnded(), at: 4))
        // A tool call is no turn of its own.
        s.apply(event(.toolStarted(agent: .root, ToolActivity(name: "Bash")), at: 5))
        #expect(reply(s) == "two")
        #expect(s.sessions[key]!.rootRepliedAt == t0.addingTimeInterval(4))
    }

    /// The status rule for a report newer than the hook is about the status
    /// only: the turn still happened, and takes the reply before it away.
    @Test func aTurnOlderThanAReportStillClearsTheReply() {
        var s = answered()
        s.apply(event(.activityReported(.idle), at: 9))
        s.apply(event(.promptSubmitted("late"), at: 5))
        #expect(s.sessions[key]!.root.status == .waiting)
        #expect(reply(s) == nil)
        #expect(s.sessions[key]!.rootRepliedAt == nil)
    }

    // Hook times are whole seconds, so within one second the order of
    // arrival decides. Both tests pin what that costs.

    /// A prompt in the second of the reply clears it, as the later applied.
    @Test func aPromptInTheSecondOfTheReplyClearsIt() {
        var s = state([.promptSubmitted("go")])
        s.apply(event(.replied(agent: .root, "one"), at: 5))
        s.apply(event(.turnEnded(), at: 5))
        s.apply(event(.promptSubmitted("next"), at: 5))
        #expect(reply(s) == nil)
        #expect(s.sessions[key]!.rootRepliedAt == nil)
    }

    /// A reply in the second of the newest turn's start counts as that
    /// turn's, even when it is the turn before's arriving late.
    @Test func aLateReplyFromTheSecondOfTheNextPromptIsTakenAsCurrent() {
        var s = state([.promptSubmitted("go")])
        s.apply(event(.promptSubmitted("next"), at: 5))
        s.apply(event(.replied(agent: .root, "one"), at: 5))
        #expect(reply(s) == "one")
        #expect(s.sessions[key]!.rootRepliedAt == t0.addingTimeInterval(5))
    }

    /// A stop can arrive after the next prompt; it must not bring the old reply back.
    @Test func aReplyOlderThanTheCurrentTurnIsDropped() {
        var s = answered()
        s.apply(event(.promptSubmitted("next"), at: 5))
        s.apply(event(.replied(agent: .root, "late"), at: 4))
        #expect(reply(s) == nil)

        s.apply(event(.replied(agent: .root, "two"), at: 5))
        #expect(reply(s) == "two")
    }

    @Test func aTurnStartArrivingAfterItsReplyKeepsIt() {
        var s = CollectiveState()
        s.apply(event(.replied(agent: .root, "one"), at: 3))
        s.apply(event(.turnEnded(), at: 3))
        s.apply(event(.promptSubmitted("go"), at: 1))
        #expect(reply(s) == "one")
        #expect(s.sessions[key]!.rootRepliedAt == t0.addingTimeInterval(3))
    }

    @Test func aReplyOlderThanTheShownOneIsDropped() {
        var s = answered()
        s.apply(event(.replied(agent: .root, "two"), at: 9))
        s.apply(event(.replied(agent: .root, "late"), at: 8))
        #expect(reply(s) == "two")
    }

    @Test func aLateOlderTurnDoesNotMoveTheCurrentOneBack() {
        var s = answered()
        s.apply(event(.promptSubmitted("next"), at: 5))
        s.apply(event(.turnStarted, at: 3))
        s.apply(event(.replied(agent: .root, "late"), at: 4))
        #expect(reply(s) == nil)
        #expect(s.sessions[key]!.rootRepliedAt == nil)
    }

    @Test func aSubagentOnlySeenReplyingKeepsItsResult() {
        var s = state([.promptSubmitted("go")])
        s.apply(event(.replied(agent: .subagent("ghost"), "result"), at: 3))
        s.apply(event(.agentFinished(id: "ghost"), at: 3))
        let agent = s.sessions[key]!.agents[.subagent("ghost")]!
        #expect(agent.reply == "result")
        #expect(agent.parent == .root)
        #expect(agent.status == .done)
    }

    @Test func aReplyLeavesEveryStatusAlone() {
        let before = state([
            .promptSubmitted("go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec()),
            .agentSpawned(id: "b", parent: .root, spec: AgentSpec()),
            .agentFinished(id: "b"),
            .toolStarted(agent: .root, ToolActivity(name: "Bash")),
        ])
        var after = before
        for agent in [AgentRef.root, .subagent("a"), .subagent("b")] {
            after.apply(event(.replied(agent: agent, "text"), at: 10))
        }
        let statuses = { (s: CollectiveState) in s.sessions[key]!.agents.mapValues(\.status) }
        #expect(statuses(after) == statuses(before))
        #expect(after.sessions[key]!.root.currentTool == ToolActivity(name: "Bash"))
        #expect(after.activeAgentCount == before.activeAgentCount)
    }

    @Test func repliesSurviveTheSessionsEnd() {
        var s = answered()
        s.apply(event(.sessionEnded, at: 9))
        #expect(reply(s) == "one")
        #expect(reply(s, of: .subagent("a")) == "result")
    }

    @Test func aReplyThatPrecedesTheSessionsEndCanArriveAfterIt() {
        var s = state([
            .promptSubmitted("go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec()),
        ])
        s.archive(.agent(key, .subagent("a")), at: t0.addingTimeInterval(7))
        s.apply(event(.sessionEnded, at: 10))
        let endedAt = s.sessions[key]!.endedAt
        let lastActivity = s.sessions[key]!.lastActivity
        let marks = s.archiveMarks

        // Equal is accepted: hook timestamps have whole-second precision.
        s.apply(event(.replied(agent: .root, "answer"), at: 10))
        s.apply(event(.replied(agent: .subagent("a"), "result"), at: 9))

        let session = s.sessions[key]!
        #expect(session.root.reply == "answer")
        #expect(session.rootRepliedAt == t0.addingTimeInterval(10))
        #expect(session.agents[.subagent("a")]?.reply == "result")
        #expect(session.root.status == .done)
        #expect(session.agents[.subagent("a")]?.status == .done)
        #expect(session.endedAt == endedAt)
        #expect(session.lastActivity == lastActivity)
        #expect(session.agents.values.allSatisfy { $0.currentTool == nil })
        #expect(s.archiveMarks == marks)
    }

    @Test func aLateReplyDoesNotAddAnUnknownSubagentToAnEndedSession() {
        var s = state([.promptSubmitted("go")])
        s.apply(event(.sessionEnded, at: 10))
        let before = s

        s.apply(event(.replied(agent: .subagent("ghost"), "result"), at: 9))

        #expect(s == before)
    }

    @Test func aReplyFromBeforeALaterRunDoesNotEnterThatRun() {
        var s = state([.sessionStarted(cwd: nil, pid: 1), .promptSubmitted("old")])
        s.apply(event(.sessionEnded, at: 5))
        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 10))
        let before = s

        s.apply(event(.replied(agent: .root, "old answer"), at: 9))

        #expect(s == before)
    }

    @Test func aReplyFromAnOlderTurnStaysRejectedAfterTheSessionEnded() {
        var s = state([.promptSubmitted("old")])
        s.apply(event(.promptSubmitted("new"), at: 8))
        s.apply(event(.sessionEnded, at: 10))

        s.apply(event(.replied(agent: .root, "old answer"), at: 7))

        #expect(reply(s) == nil)
        #expect(s.sessions[key]!.rootRepliedAt == nil)
    }

    @Test func repliesSurviveGoingStale() {
        var s = answered()
        s.markStale(now: t0.addingTimeInterval(900), silenceTimeout: 600, waitingTimeout: 600) { _ in nil }
        #expect(s.sessions[key]!.root.status == .stale)
        #expect(reply(s) == "one")
        #expect(reply(s, of: .subagent("a")) == "result")
    }

    @Test func nothingRepliesAfterTheSessionEnded() {
        var s = state([.promptSubmitted("go"), .agentSpawned(id: "a", parent: .root, spec: AgentSpec()), .sessionEnded])
        let before = s
        for agent in [AgentRef.root, .subagent("a"), .subagent("ghost")] {
            s.apply(event(.replied(agent: agent, "late"), at: 100))
        }
        #expect(s == before)
    }

    /// The end event follows at once and takes the guess back anyway.
    @Test func aReplyTakesTheInterruptionGuessBack() {
        var s = state([.promptSubmitted("go")])
        s.markInterrupted(now: t0.addingTimeInterval(500), idleTimeout: 120, toolTimeout: 1800)
        #expect(s.sessions[key]!.root.status == .waiting)
        s.apply(event(.replied(agent: .root, "one"), at: 510))
        #expect(s.sessions[key]!.root.status == .working)
        #expect(s.sessions[key]!.lastActivity == t0.addingTimeInterval(510))
    }
}

// MARK: Interrupted turns

@Suite struct InterruptedTurnTests {
    private func interrupt(_ s: inout CollectiveState, at seconds: TimeInterval) {
        s.markInterrupted(now: t0.addingTimeInterval(seconds), idleTimeout: 120, toolTimeout: 1800)
    }

    @Test func silentWorkingRootIsGuessedWaitingAfterIdleTimeout() {
        var s = state([.promptSubmitted("go")])
        interrupt(&s, at: 119)
        #expect(s.sessions[key]!.root.status == .working)
        #expect(s.activeAgentCount == 1)
        interrupt(&s, at: 121)
        #expect(s.sessions[key]!.root.status == .waiting)
        #expect(s.activeAgentCount == 0)
    }

    @Test func openToolUsesTheLongerToolTimeout() {
        var s = state([.promptSubmitted("go"), .toolStarted(agent: .root, ToolActivity(name: "Bash"))])
        interrupt(&s, at: 1 + 29 * 60 + 59)
        #expect(s.sessions[key]!.root.status == .working)
        interrupt(&s, at: 1 + 30 * 60 + 1)
        #expect(s.sessions[key]!.root.status == .waiting)
        #expect(s.sessions[key]!.root.currentTool == nil)
    }

    @Test func openToolOfASubagentAlsoUsesTheToolTimeout() {
        var s = state([
            .promptSubmitted("go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec()),
            .toolStarted(agent: .subagent("a"), ToolActivity(name: "Bash")),
        ])
        interrupt(&s, at: 600)
        #expect(s.sessions[key]!.root.status == .working)
    }

    @Test func guessLeavesSubagentsAlone() {
        var s = state([.promptSubmitted("go"), .agentSpawned(id: "a", parent: .root, spec: AgentSpec())])
        interrupt(&s, at: 200)
        #expect(s.sessions[key]!.root.status == .waiting)
        #expect(s.sessions[key]!.agents[.subagent("a")]!.status == .working)
    }

    @Test func laterEventRevokesTheGuessAndRestoresTheTool() {
        var s = state([.promptSubmitted("go"), .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "make"))])
        interrupt(&s, at: 2000)
        s.apply(event(.toolStarted(agent: .subagent("late"), ToolActivity(name: "Read")), at: 2010))
        let root = s.sessions[key]!.root
        #expect(root.status == .working)
        #expect(root.currentTool == ToolActivity(name: "Bash", detail: "make"))

        // The event was new activity, so the same moment is no silence.
        interrupt(&s, at: 2010)
        #expect(s.sessions[key]!.root.status == .working)
    }

    @Test func toolFinishedAfterTheGuessLeavesTheRootWorking() {
        var s = state([.promptSubmitted("go"), .toolStarted(agent: .root, ToolActivity(name: "Bash"))])
        interrupt(&s, at: 2000)
        s.apply(event(.toolFinished(agent: .root), at: 2010))
        #expect(s.sessions[key]!.root.status == .working)
        #expect(s.sessions[key]!.root.currentTool == nil)
    }

    @Test func aTurnEndAfterTheGuessEndsTheTurnForReal() {
        var s = CollectiveState()
        s.apply(event(.promptSubmitted("one"), at: 1))
        s.apply(event(.promptSubmitted("two"), at: 10))
        interrupt(&s, at: 200)
        s.apply(event(.turnEnded(), at: 201))
        let session = s.sessions[key]!
        #expect(session.root.status == .waiting)
        #expect(session.reallyWaits)
    }

    /// A start the source knows is over, e.g. arriving after its end, shows
    /// no tool, makes no agent, takes back no interruption guess and brings
    /// nothing back from the archive.
    @Test func aCallOverAlreadyChangesNothingButActivity() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1), .promptSubmitted("go")])
        s.archive(.session(key), at: t0.addingTimeInterval(1.5))
        interrupt(&s, at: 500)
        s.apply(event(.toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "make"), callID: "c1", alreadyEnded: true), at: 2))
        s.apply(event(.toolStarted(agent: .subagent("a"), ToolActivity(name: "Read"), callID: "s1", alreadyEnded: true), at: 2))

        let session = s.sessions[key]!
        #expect(session.root.status == .waiting)
        #expect(session.root.currentTool == nil)
        #expect(session.root.lastToolCall == nil)
        #expect(session.agents.count == 1)
        #expect(s.isArchived(key))
    }

    @Test func waitingAndEndedSessionsAreNotTouched() {
        var waiting = state([.promptSubmitted("go"), .turnEnded()])
        let before = waiting
        interrupt(&waiting, at: 5000)
        #expect(waiting == before)

        var ended = state([.promptSubmitted("go"), .sessionEnded])
        let endedBefore = ended
        interrupt(&ended, at: 5000)
        #expect(ended == endedBefore)
    }
}

// MARK: Permission requests

/// Reducer seam: a permission request is no new work and changes no status
/// (whether the session waits is the source's to report); it passes the path
/// every event takes and leaves its agent awaiting permission until answered.
@Suite struct PermissionRequestTests {
    private let request = AgentEvent.Kind.permissionRequested(agent: .subagent("a"), ToolActivity(name: "Bash", detail: "make"))

    @Test func aRequestChangesNoStatusToolOrReply() {
        var s = state([
            .promptSubmitted("go"),
            .toolStarted(agent: .root, ToolActivity(name: "Agent")),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(type: "explore")),
            .toolStarted(agent: .subagent("a"), ToolActivity(name: "Read", detail: "a.txt")),
            .replied(agent: .root, "earlier"),
        ])
        let before = s
        var expected = s.sessions[key]!
        expected.lastActivity = t0.addingTimeInterval(50)
        expected.agents[.subagent("a")]!.lastActivity = t0.addingTimeInterval(50)

        s.apply(event(request, at: 50))
        let session = s.sessions[key]!
        #expect(session.agents == expected.agents)
        #expect(session.lastActivity == expected.lastActivity)
        #expect(session.awaitsPermission(.subagent("a")))
        #expect(!session.awaitsPermission(.root))
        #expect(s.archiveMarks == before.archiveMarks)
    }

    @Test func aRequestTakesTheInterruptionGuessBack() {
        var s = state([.promptSubmitted("go"), .agentSpawned(id: "a", parent: .root, spec: AgentSpec())])
        s.markInterrupted(now: t0.addingTimeInterval(500), idleTimeout: 120, toolTimeout: 1800)
        #expect(s.sessions[key]!.root.status == .waiting)
        s.apply(event(request, at: 510))
        #expect(s.sessions[key]!.root.status == .working)
    }

    @Test func aRequestMakesAnUnknownSessionKnown() {
        let s = state([.permissionRequested(agent: .root, ToolActivity(name: "Bash"))])
        #expect(s.sessions[key]?.lastActivity == t0)
        #expect(s.sessions[key]?.root.currentTool == nil)
    }

    @Test func aRequestLeavesTheSessionAwaitingPermission() {
        var s = state([.promptSubmitted("go")])
        #expect(!s.awaitsPermission)
        s.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 10))
        #expect(s.sessions[key]!.awaitsPermission)
        #expect(s.awaitsPermission)
    }

    private func awaits(_ s: CollectiveState, _ ref: AgentRef = .root) -> Bool {
        s.sessions[key]!.awaitsPermission(ref)
    }

    /// The call's own start comes with the request, in its second.
    @Test func aRequestWaitsThroughItsCallsStartUntilItsEnd() {
        var s = state([.promptSubmitted("go")])
        s.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 10))
        s.apply(event(.toolStarted(agent: .root, ToolActivity(name: "Bash"), callID: "c1"), at: 10))
        #expect(awaits(s))
        s.apply(event(.toolFinished(agent: .root, callID: "c1"), at: 30))
        #expect(!awaits(s))
    }

    @Test func aLaterStartOfTheAgentAnswersIt() {
        var s = state([.promptSubmitted("go")])
        s.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 10))
        s.apply(event(.toolStarted(agent: .root, ToolActivity(name: "Read")), at: 11))
        #expect(!awaits(s))
    }

    /// Hooks run async: what answered a request can arrive before it.
    @Test func aRequestArrivingAfterItsAnswerDoesNotWait() {
        var s = state([.promptSubmitted("go")])
        s.apply(event(.toolFinished(agent: .root, callID: "c1"), at: 30))
        s.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 10))
        #expect(!awaits(s))
        #expect(!s.awaitsPermission)
    }

    @Test func aWorkingReportAnswersFromTheNextSecondOn() {
        var s = state([.promptSubmitted("go")])
        s.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 10))
        s.apply(event(.activityReported(.waiting), at: 10.2))
        s.apply(event(.activityReported(.working), at: 10.6))
        #expect(awaits(s))
        s.apply(event(.activityReported(.working), at: 11.1))
        #expect(!awaits(s))
    }

    /// Waiting stands for any dialog, not only a permission's.
    @Test func aWaitingReportIsNoRequest() {
        let s = state([.promptSubmitted("go"), .activityReported(.waiting)])
        #expect(!s.awaitsPermission)
    }

    @Test func aWaitingReportAnswersNoRequest() {
        var s = state([.promptSubmitted("go")])
        s.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 10))
        s.apply(event(.activityReported(.waiting), at: 11.5))
        #expect(awaits(s))
    }

    @Test func anIdleReportAnswersEveryAgent() {
        var s = state([.promptSubmitted("go"), .agentSpawned(id: "a", parent: .root, spec: AgentSpec())])
        s.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 10))
        s.apply(event(.permissionRequested(agent: .subagent("a"), ToolActivity(name: "Bash")), at: 10))
        s.apply(event(.activityReported(.idle), at: 20.5))
        #expect(!s.awaitsPermission)
    }

    /// Hook times are whole seconds, so a report from the request's second
    /// may well be older than the request.
    @Test func anIdleOrBackgroundShellReportAnswersFromTheNextSecondOn() {
        var s = state([.promptSubmitted("go")])
        s.apply(event(.activityReported(.idle), at: 10.2))
        s.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 10))
        #expect(awaits(s))
        s.apply(event(.activityReported(.backgroundShell), at: 10.7))
        #expect(awaits(s))
        s.apply(event(.activityReported(.backgroundShell), at: 11.1))
        #expect(!awaits(s))
    }

    /// Only a background shell runs: the turn is over, a subagent may still ask.
    @Test func aBackgroundShellReportAnswersOnlyTheOrchestrator() {
        var s = state([.promptSubmitted("go"), .agentSpawned(id: "a", parent: .root, spec: AgentSpec(isBackground: true))])
        s.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 10))
        s.apply(event(request, at: 10))
        s.apply(event(.activityReported(.backgroundShell), at: 20.5))
        #expect(!awaits(s))
        #expect(awaits(s, .subagent("a")))
    }

    @Test func anotherAgentGoingOnAnswersNothing() {
        var s = state([.promptSubmitted("go"), .agentSpawned(id: "a", parent: .root, spec: AgentSpec())])
        s.apply(event(request, at: 10))
        s.apply(event(.toolStarted(agent: .root, ToolActivity(name: "Read")), at: 20))
        s.apply(event(.toolFinished(agent: .root), at: 21))
        #expect(awaits(s, .subagent("a")))
    }

    /// A background subagent can outlive the turn and its request with it.
    @Test func theTurnsEndAnswersOnlyTheOrchestrator() {
        var s = state([.promptSubmitted("go"), .agentSpawned(id: "a", parent: .root, spec: AgentSpec(isBackground: true))])
        s.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 10))
        s.apply(event(request, at: 10))
        s.apply(event(.turnEnded(), at: 20))
        #expect(!awaits(s))
        #expect(awaits(s, .subagent("a")))
    }

    /// A hand-back drops the open requests like any turn start, but no one
    /// answered them: the user's last input stays the prompt.
    @Test func aHandBackDropsARequestWithoutBeingInput() {
        var s = state([.promptSubmitted("go"), .agentSpawned(id: "a", parent: .root, spec: AgentSpec(isBackground: true))])
        s.apply(event(request, at: 10))
        s.apply(event(.turnEnded(), at: 20))
        s.apply(event(.turnStarted, at: 30))
        #expect(!awaits(s, .subagent("a")))
        #expect(s.sessions[key]!.lastInputAt == t0)
    }

    @Test func theNextPromptAnswersIt() {
        var s = state([.promptSubmitted("go")])
        s.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 10))
        s.apply(event(.promptSubmitted("again"), at: 20))
        #expect(!awaits(s))
    }

    @Test func aStaleSessionWaitsNoMoreUntilItComesBack() {
        var s = state([.promptSubmitted("go")])
        s.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 10))
        s.markStale(now: t0.addingTimeInterval(50_000), silenceTimeout: 1800, waitingTimeout: 43_200, processStart: { _ in nil })
        #expect(!s.awaitsPermission)
        // An event that answers nothing brings the session back with its request.
        s.apply(event(.modelChanged(to: "m", from: nil), at: 50_010))
        #expect(s.awaitsPermission)
    }

    @Test func anEndedSessionWaitsNoMore() {
        var s = state([.promptSubmitted("go")])
        s.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 10))
        s.apply(event(.sessionEnded, at: 20))
        #expect(!s.awaitsPermission)
    }

    @Test func aNewRunAsksNothingOfTheOneBefore() {
        var s = state([.sessionStarted(cwd: nil, pid: 1), .promptSubmitted("go")])
        s.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 10))
        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 20))
        #expect(!s.awaitsPermission)
    }

    @Test func archivedRequestsDontCount() {
        var s = state([.promptSubmitted("go"), .agentSpawned(id: "a", parent: .root, spec: AgentSpec())])
        s.apply(event(request, at: 10))
        s.archive(.agent(key, .subagent("a")), at: t0.addingTimeInterval(20))
        #expect(awaits(s, .subagent("a")))
        #expect(!s.awaitsPermission)

        s.unarchive(.agent(key, .subagent("a")))
        s.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 30))
        s.archive(.session(key), at: t0.addingTimeInterval(40))
        #expect(!s.awaitsPermission)
    }

    @Test func aRequestBringsNothingArchivedBack() {
        var s = state([.promptSubmitted("go"), .agentSpawned(id: "a", parent: .root, spec: AgentSpec())])
        s.archive(.agent(key, .subagent("a")), at: t0.addingTimeInterval(10))
        s.archive(.session(key), at: t0.addingTimeInterval(10))
        s.apply(event(request, at: 20))
        #expect(s.isArchived(key))
        #expect(s.isArchived(.subagent("a"), in: key))
    }
}

// MARK: Activity reports

@Suite struct ActivityReportTests {
    private func report(_ activity: SessionActivity, at seconds: TimeInterval) -> AgentEvent {
        event(.activityReported(activity), at: seconds)
    }

    /// Root working with a tool, a foreground and a background subagent working.
    private func busy() -> CollectiveState {
        state([
            .sessionStarted(cwd: nil, pid: nil),
            .promptSubmitted("go"),
            .agentSpawned(id: "fg", parent: .root, spec: AgentSpec()),
            .agentSpawned(id: "bg", parent: .root, spec: AgentSpec(isBackground: true)),
            .toolStarted(agent: .root, ToolActivity(name: "Bash")),
            .toolStarted(agent: .subagent("fg"), ToolActivity(name: "Read")),
        ])
    }

    @Test func idleReportEndsTheTurnAndEveryRunningSubagent() {
        var s = busy()
        s.apply(report(.idle, at: 10.5))
        let session = s.sessions[key]!
        #expect(session.root.status == .waiting)
        #expect(session.root.currentTool == nil)
        for id in ["fg", "bg"] {
            let agent = session.agents[.subagent(id)]!
            #expect(agent.status == .done)
            #expect(agent.endedAt == t0.addingTimeInterval(10.5))
            #expect(agent.currentTool == nil)
        }
        #expect(session.endedAt == nil)
        #expect(session.lastActivity == t0.addingTimeInterval(10.5))
        #expect(s.activeAgentCount == 0)
    }

    @Test func lateIdleReportSparesSubagentsStartedAfterIt() {
        var s = CollectiveState()
        s.apply(event(.promptSubmitted("go"), at: 0))
        s.apply(event(.agentSpawned(id: "a", parent: .root, spec: AgentSpec()), at: 1))
        s.apply(event(.agentSpawned(id: "b", parent: .root, spec: AgentSpec()), at: 5))
        s.apply(report(.idle, at: 3))
        let session = s.sessions[key]!
        #expect(session.agents[.subagent("a")]!.status == .done)
        #expect(session.agents[.subagent("a")]!.endedAt == t0.addingTimeInterval(3))
        #expect(session.agents[.subagent("b")]!.status == .working)
        #expect(session.agents[.subagent("b")]!.endedAt == nil)
    }

    @Test func waitingReportPausesOnlyTheRoot() {
        var s = busy()
        s.apply(report(.waiting, at: 10.5))
        let session = s.sessions[key]!
        #expect(session.root.status == .waiting)
        #expect(session.root.currentTool == nil)
        #expect(session.agents[.subagent("fg")]!.status == .working)
        #expect(session.agents[.subagent("fg")]!.currentTool == ToolActivity(name: "Read"))
        #expect(session.agents[.subagent("bg")]!.status == .working)
    }

    @Test func backgroundShellReportPausesOnlyTheRoot() {
        var s = busy()
        s.apply(report(.backgroundShell, at: 10.5))
        let session = s.sessions[key]!
        #expect(session.root.status == .waiting)
        #expect(session.root.currentTool == nil)
        #expect(session.runsBackgroundShell)
        // A shell says nothing about subagents: they keep running.
        for id in ["fg", "bg"] {
            #expect(session.agents[.subagent(id)]!.status == .working)
        }
        #expect(session.agents[.subagent("fg")]!.currentTool == ToolActivity(name: "Read"))
    }

    /// Standby too: a process never given work runs nothing.
    @Test func aNewerReportThatTheSessionWaitsOrIdlesEndsTheBackgroundShell() {
        for activity in [SessionActivity.waiting, .idle, .standby] {
            var s = state([.promptSubmitted("go"), .turnEnded()])
            s.apply(report(.backgroundShell, at: 1.5))
            s.apply(report(activity, at: 2.5))
            #expect(!s.sessions[key]!.runsBackgroundShell, "\(activity)")
        }
    }

    /// A turn running says nothing about the shell: it runs on.
    @Test func aNewerWorkingReportKeepsTheBackgroundShell() {
        var s = state([.promptSubmitted("go"), .turnEnded()])
        s.apply(report(.backgroundShell, at: 1.5))
        s.apply(report(.working, at: 2.5))
        let session = s.sessions[key]!
        #expect(session.root.status == .working)
        #expect(session.runsBackgroundShell)
    }

    /// The shell runs on into the next turn; only the next report tells.
    @Test func aNewerPromptWorksWhileTheShellRuns() {
        var s = state([.promptSubmitted("go"), .turnEnded()])
        s.apply(report(.backgroundShell, at: 1.5))
        s.apply(event(.promptSubmitted("next"), at: 3))
        let session = s.sessions[key]!
        #expect(session.root.status == .working)
        #expect(session.runsBackgroundShell)
    }

    @Test func anOlderBackgroundShellReportLeavesTheRootAsTheHookSetIt() {
        var s = state([.sessionStarted(cwd: nil, pid: nil), .promptSubmitted("go")])
        s.apply(report(.backgroundShell, at: 0.5))
        #expect(s.sessions[key]!.root.status == .working)
        // Still stored as the last report: the shell counts as running until a report says otherwise.
        #expect(s.sessions[key]!.runsBackgroundShell)
    }

    @Test func anEndedSessionRunsNoShell() {
        var s = state([.promptSubmitted("go"), .turnEnded()])
        s.apply(report(.backgroundShell, at: 1.5))
        s.apply(event(.sessionEnded, at: 3))
        #expect(!s.sessions[key]!.runsBackgroundShell)
    }

    @Test func workingReportNewerThanTurnEndWins() {
        var s = state([.promptSubmitted("go"), .turnEnded()])
        s.apply(report(.working, at: 1.5))
        #expect(s.sessions[key]!.root.status == .working)
    }

    @Test func turnEndNewerThanWorkingReportWins() {
        var s = state([.promptSubmitted("go")])
        s.apply(report(.working, at: 1.5))
        s.apply(event(.turnEnded(), at: 2))
        #expect(s.sessions[key]!.root.status == .waiting)
    }

    /// Newer than the report, the late stop is still older than the prompt.
    @Test func aLateTurnEndNewerThanTheReportLeavesTheNewerTurnRunning() {
        var s = CollectiveState()
        s.apply(event(.promptSubmitted("one"), at: 1))
        s.apply(report(.waiting, at: 5.5))
        s.apply(event(.promptSubmitted("two"), at: 10))
        s.apply(event(.turnEnded(), at: 8))
        #expect(s.sessions[key]!.root.status == .working)
    }

    @Test func aReportNewerThanTheNextPromptStillWinsOverALateTurnEnd() {
        var s = CollectiveState()
        s.apply(event(.promptSubmitted("one"), at: 1))
        s.apply(event(.promptSubmitted("two"), at: 10))
        s.apply(report(.waiting, at: 10.5))
        s.apply(event(.turnEnded(), at: 8))
        #expect(s.sessions[key]!.root.status == .waiting)
        s.apply(report(.working, at: 11.5))
        #expect(s.sessions[key]!.root.status == .working)
    }

    @Test func reportNotNewerThanTheLastHookChangesNothing() {
        var s = state([.sessionStarted(cwd: nil, pid: nil), .promptSubmitted("go")])
        s.apply(report(.idle, at: 1))
        #expect(s.sessions[key]!.root.status == .working)
    }

    @Test func olderReportDoesNotReplaceANewerOne() {
        var s = state([.promptSubmitted("go")])
        s.apply(report(.waiting, at: 5))
        s.apply(report(.working, at: 3))
        #expect(s.sessions[key]!.root.status == .waiting)
        // The older report must not make the newer one look outdated either.
        s.apply(event(.turnStarted, at: 4))
        #expect(s.sessions[key]!.root.status == .waiting)
    }

    @Test func olderPromptStoresItsTextButNotItsStatus() {
        var s = state([.sessionStarted(cwd: nil, pid: nil)])
        s.apply(report(.idle, at: 5.5))
        s.apply(event(.promptSubmitted("late"), at: 5))
        #expect(s.sessions[key]!.root.status == .waiting)
        #expect(s.sessions[key]!.root.spec.prompt == "late")
    }

    @Test func hookAndReportGiveTheSameResultInEitherOrder() {
        let events = [event(.promptSubmitted("go"), at: 5), report(.idle, at: 5.5)]
        var forward = state([.sessionStarted(cwd: nil, pid: nil)])
        var backward = forward
        events.forEach { forward.apply($0) }
        events.reversed().forEach { backward.apply($0) }
        #expect(forward.sessions[key]!.root.status == .waiting)
        #expect(backward.sessions[key]!.root.status == .waiting)
    }

    @Test func reportWithinTheHooksSecondWins() {
        // Hook times are whole seconds, report times are not.
        var s = state([.sessionStarted(cwd: nil, pid: nil)])
        s.apply(report(.waiting, at: 5.2))
        s.apply(event(.turnStarted, at: 5))
        #expect(s.sessions[key]!.root.status == .waiting)
    }

    @Test func reportAfterSessionEndIsIgnored() {
        var s = state([.promptSubmitted("go"), .sessionEnded])
        let before = s
        s.apply(report(.working, at: 5))
        // The report itself is kept for a possible next run.
        #expect(s.sessions == before.sessions)
        #expect(s.sessions[key]!.root.status == .done)
    }

    @Test func reportRevivesAStaleSession() {
        var s = state([.promptSubmitted("go")])
        s.markStale(now: t0.addingTimeInterval(700), silenceTimeout: 600, waitingTimeout: 600) { _ in nil }
        s.apply(report(.waiting, at: 710))
        #expect(s.sessions[key]!.endedAt == nil)
        #expect(s.sessions[key]!.root.status == .waiting)
    }

    @Test func reportForAnUnknownSessionWaitsForItsFirstEvent() {
        var s = CollectiveState()
        s.apply(report(.waiting, at: 5.5))
        #expect(s.sessions.isEmpty)
        #expect(s.activeAgentCount == 0)

        s.apply(event(.sessionStarted(cwd: "/p", pid: nil), at: 5))
        s.apply(event(.promptSubmitted("older than the report"), at: 5))
        let session = s.sessions[key]!
        #expect(session.root.status == .waiting)
        #expect(session.root.spec.prompt == "older than the report")
        #expect(session.lastActivity == t0.addingTimeInterval(5.5))
    }

    @Test func earlyReportLosesToANewerFirstEvent() {
        var s = CollectiveState()
        s.apply(report(.idle, at: 3.5))
        s.apply(event(.promptSubmitted("go"), at: 4))
        #expect(s.sessions[key]!.root.status == .working)
    }

    @Test func earlyReportKeepsOnlyTheNewest() {
        var s = CollectiveState()
        s.apply(report(.working, at: 3.5))
        s.apply(report(.waiting, at: 2.5))
        s.apply(event(.sessionStarted(cwd: nil, pid: nil), at: 1))
        #expect(s.sessions[key]!.root.status == .working)
    }

    /// An idle session's status file can be hours old when its report is
    /// parked, and the source won't send it again: its age must not count
    /// against it.
    @Test func pruneKeepsAnEarlyReportOlderThanTheRetention() {
        var s = CollectiveState()
        s.apply(report(.idle, at: 0))
        s.prune(now: t0.addingTimeInterval(7_200), retention: 3_600)
        s.apply(event(.sessionStarted(cwd: nil, pid: nil), at: 7_210))
        #expect(s.sessions[key]!.lastReport == ActivityReport(activity: .idle, date: t0))
    }

    @Test func pruneDropsAnEarlyReportParkedLongerThanTheRetention() {
        var s = CollectiveState()
        s.apply(report(.working, at: 0))
        s.prune(now: t0.addingTimeInterval(100), retention: 60)
        s.prune(now: t0.addingTimeInterval(160), retention: 60)
        s.apply(event(.sessionStarted(cwd: nil, pid: nil), at: 165))
        #expect(s.sessions[key]!.root.status == .working)

        var late = CollectiveState()
        late.apply(report(.working, at: 0))
        late.prune(now: t0.addingTimeInterval(100), retention: 60)
        late.prune(now: t0.addingTimeInterval(161), retention: 60)
        late.apply(event(.sessionStarted(cwd: nil, pid: nil), at: 165))
        #expect(late.sessions[key]!.root.status == .waiting)
    }

    @Test func pruneKeepsRecentEarlyReports() {
        var s = CollectiveState()
        s.apply(report(.working, at: 0))
        s.prune(now: t0.addingTimeInterval(60), retention: 60)
        s.apply(event(.sessionStarted(cwd: nil, pid: nil), at: 0))
        #expect(s.sessions[key]!.root.status == .working)
    }

    @Test func earlyReportLeavesASessionThatStartsEndedAlone() {
        var s = CollectiveState()
        s.apply(report(.working, at: 0.5))
        s.apply(event(.sessionEnded, at: 1))
        #expect(s.sessions[key]!.root.status == .done)
    }

    @Test func reportedSessionsAreNeverGuessedInterrupted() {
        var s = state([.promptSubmitted("go")])
        s.apply(report(.working, at: 1.5))
        s.markInterrupted(now: t0.addingTimeInterval(5000), idleTimeout: 120, toolTimeout: 1800)
        #expect(s.sessions[key]!.root.status == .working)
    }

    @Test func reportRevokesTheInterruptionGuessFirst() {
        var s = state([.promptSubmitted("go")])
        s.markInterrupted(now: t0.addingTimeInterval(500), idleTimeout: 120, toolTimeout: 1800)
        #expect(s.sessions[key]!.root.status == .waiting)
        s.apply(report(.working, at: 510))
        #expect(s.sessions[key]!.root.status == .working)
    }

    /// The app started while the session sat idle: the report came before the backlog.
    private func idleBeforeBacklog(_ reports: [(SessionActivity, TimeInterval)] = [(.idle, 10)]) -> CollectiveState {
        var s = CollectiveState()
        for (activity, at) in reports { s.apply(report(activity, at: at)) }
        s.apply(event(.promptSubmitted("go"), at: 1))
        return s
    }

    @Test(arguments: [
        AgentEvent.Kind.toolStarted(agent: .subagent("x"), ToolActivity(name: "Bash")),
        .agentSpawned(id: "x", parent: .root, spec: AgentSpec()),
    ])
    func backlogOlderThanAnIdleReportCreatesFinishedSubagents(kind: AgentEvent.Kind) {
        var s = idleBeforeBacklog()
        s.apply(event(kind, at: 5))
        let agent = s.sessions[key]!.agents[.subagent("x")]!
        #expect(agent.status == .done)
        #expect(agent.endedAt == t0.addingTimeInterval(10))
        #expect(agent.currentTool == nil)
        #expect(s.activeAgentCount == 0)
    }

    @Test func backlogInTheIdleReportsSecondCreatesWorkingSubagents() {
        var s = idleBeforeBacklog([(.idle, 10.5)])
        s.apply(event(.toolStarted(agent: .subagent("x"), ToolActivity(name: "Bash")), at: 10))
        #expect(s.sessions[key]!.agents[.subagent("x")]!.status == .working)
    }

    @Test(arguments: [
        [(SessionActivity.idle, 10.0), (.working, 11.0)],
        [(SessionActivity.waiting, 10.0)],
    ])
    func backlogCreatesWorkingSubagentsUnlessTheLatestReportIsIdle(reports: [(SessionActivity, TimeInterval)]) {
        var s = idleBeforeBacklog(reports)
        s.apply(event(.toolStarted(agent: .subagent("x"), ToolActivity(name: "Bash")), at: 5))
        #expect(s.sessions[key]!.agents[.subagent("x")]!.status == .working)
    }

    @Test func idleReportLeavesSubagentsCreatedAfterItAlone() {
        var s = idleBeforeBacklog()
        s.apply(event(.agentSpawned(id: "x", parent: .root, spec: AgentSpec()), at: 12))
        s.apply(event(.toolStarted(agent: .subagent("x"), ToolActivity(name: "Bash")), at: 13))
        s.apply(event(.agentSpawned(id: "x", parent: .root, spec: AgentSpec(title: "X")), at: 14))
        let agent = s.sessions[key]!.agents[.subagent("x")]!
        #expect(agent.status == .working)
        #expect(agent.currentTool == ToolActivity(name: "Bash"))
        #expect(agent.endedAt == nil)
    }
}

@Suite struct SessionModelTests {
    private let haiku = "claude-haiku-4-5-20251001"
    private let sonnet = "claude-sonnet-5-5"

    @Test func firstModelIsNoSwitch() {
        let session = state([.modelChanged(to: haiku, from: nil)]).sessions[key]!
        #expect(session.model == haiku)
        #expect(session.lastModelSwitch == nil)
    }

    /// Capture C2 of 2.1.285: the `SessionStart` after `/compact` (t0+46)
    /// arrives after the switch (t0+52) and still names the old model.
    @Test func aLateOlderReportDoesNotUndoASwitch() {
        var s = CollectiveState()
        s.apply(event(.modelChanged(to: haiku, from: nil), at: 0))
        s.apply(event(.modelChanged(to: sonnet, from: haiku), at: 52))
        s.apply(event(.modelChanged(to: haiku, from: nil), at: 46))
        let session = s.sessions[key]!
        #expect(session.model == sonnet)
        #expect(session.lastModelSwitch == ModelSwitch(from: haiku, at: t0.addingTimeInterval(52)))
    }

    @Test func withinTheSameSecondTheLaterAppliedWins() {
        var s = CollectiveState()
        s.apply(event(.modelChanged(to: haiku, from: nil), at: 0))
        s.apply(event(.modelChanged(to: sonnet, from: haiku), at: 5))
        s.apply(event(.modelChanged(to: haiku, from: nil), at: 5))
        let session = s.sessions[key]!
        #expect(session.model == haiku)
        #expect(session.lastModelSwitch == ModelSwitch(from: sonnet, at: t0.addingTimeInterval(5)))
    }

    @Test func theSameModelAgainKeepsTheLastSwitch() {
        var s = CollectiveState()
        s.apply(event(.modelChanged(to: haiku, from: nil), at: 0))
        s.apply(event(.modelChanged(to: sonnet, from: haiku), at: 10))
        s.apply(event(.modelChanged(to: sonnet, from: nil), at: 20))
        let session = s.sessions[key]!
        #expect(session.model == sonnet)
        #expect(session.lastModelSwitch == ModelSwitch(from: haiku, at: t0.addingTimeInterval(10)))
    }

    @Test func withoutAKnownModelTheSourcesPreviousOneIsTheSwitch() {
        let session = state([.promptSubmitted("go"), .modelChanged(to: sonnet, from: haiku)]).sessions[key]!
        #expect(session.model == sonnet)
        #expect(session.lastModelSwitch == ModelSwitch(from: haiku, at: t0.addingTimeInterval(1)))
    }

    @Test func anEndedSessionKeepsItsModel() {
        var s = state([.modelChanged(to: haiku, from: nil), .sessionEnded])
        s.apply(event(.modelChanged(to: sonnet, from: haiku), at: 10))
        let session = s.sessions[key]!
        #expect(session.model == haiku)
        #expect(session.lastModelSwitch == nil)
    }

    @Test func aModelChangeLeavesEveryStatusAlone() {
        let before = state([
            .promptSubmitted("go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec()),
            .agentSpawned(id: "b", parent: .root, spec: AgentSpec()),
            .agentFinished(id: "b"),
            .turnEnded(),
        ])
        var after = before
        after.apply(event(.modelChanged(to: sonnet, from: haiku), at: 10))
        let statuses = { (s: CollectiveState) in s.sessions[key]!.agents.mapValues(\.status) }
        #expect(statuses(after) == statuses(before))
        #expect(statuses(after)[.root] == .waiting)
        #expect(statuses(after)[.subagent("a")] == .working)
    }

    /// A `/model` switch happens at the prompt, so it is no evidence the
    /// turn still runs; only a later real event takes the guess back.
    @Test func aModelChangeKeepsTheInterruptionGuess() {
        var s = state([.promptSubmitted("go"), .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "make"))])
        s.markInterrupted(now: t0.addingTimeInterval(2000), idleTimeout: 120, toolTimeout: 1800)
        s.apply(event(.modelChanged(to: sonnet, from: haiku), at: 2010))
        var session = s.sessions[key]!
        #expect(session.root.status == .waiting)
        #expect(session.root.currentTool == nil)
        #expect(session.model == sonnet)

        s.apply(event(.toolStarted(agent: .subagent("late"), ToolActivity(name: "Read")), at: 2020))
        session = s.sessions[key]!
        #expect(session.root.status == .working)
        #expect(session.root.currentTool == ToolActivity(name: "Bash", detail: "make"))
    }

    @Test func aModelChangeRevivesAStaleSession() {
        var s = state([.sessionStarted(cwd: nil, pid: 99), .promptSubmitted("go")])
        s.markStale(now: t0.addingTimeInterval(50), silenceTimeout: 600, waitingTimeout: 600) { _ in nil }
        s.apply(event(.modelChanged(to: sonnet, from: haiku), at: 60))
        let session = s.sessions[key]!
        #expect(session.endedAt == nil)
        #expect(session.root.status == .working)
        #expect(session.model == sonnet)
    }

    @Test func aLateSpawnFillsTheModelOfAFinishedSubagent() {
        let s = state([
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(type: "explore", modelAlias: "haiku")),
            .agentFinished(id: "a"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(modelID: haiku)),
        ])
        let agent = s.sessions[key]!.agents[.subagent("a")]!
        #expect(agent.status == .done)
        #expect(agent.spec == AgentSpec(type: "explore", modelAlias: "haiku", modelID: haiku))
    }
}

// MARK: Resumed sessions

/// A tool can continue a session under its id in a new process, after an end
/// or after a crash that sent none.
@Suite struct ResumedSessionTests {
    /// Ran with a model switch, a report and two subagents, then ended at 6 s.
    private func ended() -> CollectiveState {
        var s = state([
            .sessionStarted(cwd: "/p", pid: 1),
            .promptSubmitted("go"),
            .modelChanged(to: "m1", from: nil),
            .modelChanged(to: "m2", from: nil),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec()),
            .agentSpawned(id: "b", parent: .subagent("a"), spec: AgentSpec()),
        ])
        s.apply(event(.activityReported(.working), at: 5.5))
        s.apply(event(.replied(agent: .subagent("a"), "result"), at: 5.6))
        s.apply(event(.replied(agent: .root, "answer"), at: 5.7))
        s.apply(event(.sessionEnded, at: 6))
        return s
    }

    /// Nothing of the earlier run is left but the working directory.
    private func expectFreshRun(
        _ s: CollectiveState, startedAt seconds: TimeInterval, pid: Int32, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let session = s.sessions[key]!
        let start = t0.addingTimeInterval(seconds)
        #expect(session.startedAt == start, sourceLocation: sourceLocation)
        #expect(session.lastActivity == start, sourceLocation: sourceLocation)
        #expect(session.endedAt == nil, sourceLocation: sourceLocation)
        #expect(session.cwd == "/p", sourceLocation: sourceLocation)
        #expect(session.pid == pid, sourceLocation: sourceLocation)
        #expect(Array(session.agents.keys) == [.root], sourceLocation: sourceLocation)
        #expect(
            session.root == Agent(id: .root, parent: nil, spec: AgentSpec(), status: .waiting, startedAt: start),
            sourceLocation: sourceLocation
        )
        #expect(session.model == nil, sourceLocation: sourceLocation)
        #expect(session.lastModelSwitch == nil, sourceLocation: sourceLocation)
        #expect(session.rootRepliedAt == nil, sourceLocation: sourceLocation)
        #expect(session.lastPromptAt == nil, sourceLocation: sourceLocation)
        #expect(s.activeAgentCount == 0, sourceLocation: sourceLocation)
    }

    @Test func aStartAfterTheEndOpensAFreshRun() {
        var s = ended()
        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 20))

        expectFreshRun(s, startedAt: 20, pid: 2)
    }

    @Test func aStartAfterTheEndWithoutAPidOpensAFreshRunToo() {
        var s = ended()
        s.apply(event(.sessionStarted(cwd: "/q", pid: nil), at: 20))
        s.apply(event(.promptSubmitted("again"), at: 21))

        let session = s.sessions[key]!
        #expect(session.startedAt == t0.addingTimeInterval(20))
        #expect(session.cwd == "/q")
        #expect(session.pid == nil)
        #expect(session.root.status == .working)
        #expect(s.activeAgentCount == 1)
    }

    @Test func aReportOfTheOldRunDoesNotOutrankTheNewRunsHooks() {
        var s = ended()
        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 20))
        s.apply(event(.promptSubmitted("again"), at: 21))
        // The old run's report was at 5.5 s; a hook of the new run older than
        // a report would lose against it.
        #expect(s.sessions[key]!.root.status == .working)
        s.apply(event(.activityReported(.idle), at: 22))
        #expect(s.sessions[key]!.root.status == .waiting)
    }

    @Test(arguments: [
        AgentEvent.Kind.promptSubmitted("late"),
        .turnStarted,
        .toolStarted(agent: .root, ToolActivity(name: "Bash")),
        .activityReported(.working),
        .agentSpawned(id: "c", parent: .root, spec: AgentSpec()),
    ])
    func nothingButAStartBringsAnEndedSessionBack(kind: AgentEvent.Kind) {
        var s = ended()
        let before = s
        s.apply(event(kind, at: 20))
        if case .activityReported = kind {
            // Not the whole state: a report is kept for a possible next run.
            #expect(s.sessions == before.sessions)
            #expect(s.archiveMarks == before.archiveMarks)
        } else {
            #expect(s == before)
        }
    }

    @Test(arguments: [0, 6] as [TimeInterval])
    func aStartNoNewerThanTheEndIsIgnored(seconds: TimeInterval) {
        // Hook times are whole seconds: a start within the end's second may
        // just as well be the ended run's own, arriving late.
        var s = ended()
        let before = s
        s.apply(event(.sessionStarted(cwd: "/q", pid: 2), at: seconds))
        #expect(s == before)
    }

    @Test(arguments: [
        AgentEvent.Kind.sessionEnded,
        .turnEnded(),
        .promptSubmitted("late"),
        .activityReported(.working),
        .modelChanged(to: "m3", from: nil),
        .sessionStarted(cwd: "/old", pid: 1),
    ])
    func lateEventsOfTheOldRunLeaveTheNewRunAlone(kind: AgentEvent.Kind) {
        var s = ended()
        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 20))
        s.apply(event(.promptSubmitted("again"), at: 21))
        let before = s
        s.apply(event(kind, at: 19))
        #expect(s == before)
    }

    @Test func anEventInTheNewRunsFirstSecondCounts() {
        var s = ended()
        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 20))
        s.apply(event(.promptSubmitted("again"), at: 20))
        #expect(s.sessions[key]!.root.status == .working)
    }

    @Test func aFirstRunStillAcceptsEventsOlderThanItsFirst() {
        var s = CollectiveState()
        s.apply(event(.turnEnded(), at: 10))
        s.apply(event(.promptSubmitted("go"), at: 5))
        s.apply(event(.sessionStarted(cwd: "/p", pid: 1), at: 4))
        let session = s.sessions[key]!
        #expect(session.root.spec.prompt == "go")
        #expect(session.pid == 1)
        #expect(session.startedAt == t0.addingTimeInterval(10))
    }

    @Test func aNewRunCanEndAndBeResumedAgain() {
        var s = ended()
        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 20))
        s.apply(event(.sessionEnded, at: 25))
        #expect(s.sessions[key]!.root.status == .done)
        #expect(s.sessions[key]!.endedAt == t0.addingTimeInterval(25))

        s.apply(event(.sessionStarted(cwd: nil, pid: 3), at: 30))
        #expect(s.sessions[key]!.endedAt == nil)
        #expect(s.sessions[key]!.pid == 3)
    }

    // MARK: Reports around a new run

    @Test func aReportOfTheNewRunSurvivesTheReplacement() {
        let newRun = [
            event(.sessionStarted(cwd: "/p", pid: 2), at: 20),
            event(.promptSubmitted("again"), at: 21),
            event(.toolStarted(agent: .subagent("x"), ToolActivity(name: "Bash")), at: 22),
        ]
        // The report is quicker than the backlog, whose first event is the
        // earlier run's.
        var s = CollectiveState()
        s.apply(event(.activityReported(.idle), at: 30))
        s.apply(event(.sessionStarted(cwd: "/p", pid: 1), at: 0))
        s.apply(event(.promptSubmitted("go"), at: 1))
        s.apply(event(.sessionEnded, at: 6))
        newRun.forEach { s.apply($0) }

        var alone = CollectiveState()
        alone.apply(event(.activityReported(.idle), at: 30))
        newRun.forEach { alone.apply($0) }

        let session = s.sessions[key]!
        #expect(session.root.status == .waiting)
        #expect(session.agents[.subagent("x")]?.status == .done)
        #expect(session.agents[.subagent("x")]?.endedAt == t0.addingTimeInterval(30))
        #expect(s.activeAgentCount == 0)
        #expect(session.root.status == alone.sessions[key]!.root.status)
        #expect(session.agents[.subagent("x")] == alone.sessions[key]!.agents[.subagent("x")])
        #expect(s.activeAgentCount == alone.activeAgentCount)
    }

    @Test func aReportArrivingAfterTheEndReachesTheNewRun() {
        // The new process can report before its start hook arrives.
        var s = ended()
        let before = s
        s.apply(event(.activityReported(.working), at: 21))
        #expect(s.sessions == before.sessions)

        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 20))
        let session = s.sessions[key]!
        #expect(session.endedAt == nil)
        #expect(session.pid == 2)
        #expect(session.root.status == .working)
        #expect(s.activeAgentCount == 1)
    }

    @Test func aReportOlderThanTheNewRunArrivingAfterTheEndIsDiscarded() {
        var s = ended()
        s.apply(event(.activityReported(.working), at: 19))
        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 20))
        expectFreshRun(s, startedAt: 20, pid: 2)

        var unreported = ended()
        unreported.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 20))
        #expect(s == unreported)
    }

    @Test func aReportKeptForAnEndedSessionGoesWithItWhenPruned() {
        // The report alone is still within the retention when the session goes.
        var s = ended()
        s.apply(event(.activityReported(.working), at: 21))
        s.prune(now: t0.addingTimeInterval(67), retention: 60)
        #expect(s.sessions.isEmpty)
        s.apply(event(.sessionStarted(cwd: "/p", pid: 2), at: 100))

        var unreported = ended()
        unreported.prune(now: t0.addingTimeInterval(67), retention: 60)
        unreported.apply(event(.sessionStarted(cwd: "/p", pid: 2), at: 100))

        #expect(s.sessions[key]!.root.status == .waiting)
        #expect(s.activeAgentCount == 0)
        #expect(s == unreported)
    }

    @Test func aReportOutlivesAnEndThatIsTheOldRunsOnlyEvent() {
        // The report is quicker than the backlog, of which only the earlier
        // run's end is left.
        var s = CollectiveState()
        s.apply(event(.activityReported(.idle), at: 30))
        s.apply(event(.sessionEnded, at: 6))
        s.apply(event(.sessionStarted(cwd: "/p", pid: 2), at: 20))
        s.apply(event(.promptSubmitted("again"), at: 21))
        s.apply(event(.toolStarted(agent: .subagent("x"), ToolActivity(name: "Bash")), at: 22))

        let session = s.sessions[key]!
        #expect(session.root.status == .waiting)
        #expect(session.agents[.subagent("x")]?.status == .done)
        #expect(s.activeAgentCount == 0)
    }

    // MARK: A new process without an end

    /// pid 1 working with a subagent, declared dead at 50 s.
    private func crashed() -> CollectiveState {
        var s = state([
            .sessionStarted(cwd: "/p", pid: 1),
            .promptSubmitted("go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec()),
        ])
        s.markStale(now: t0.addingTimeInterval(50), silenceTimeout: 600, waitingTimeout: 600) { _ in nil }
        return s
    }

    @Test func aStartInANewProcessReplacesAStaleSession() {
        var s = crashed()
        #expect(s.sessions[key]!.root.status == .stale)

        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 100))
        expectFreshRun(s, startedAt: 100, pid: 2)

        // Process 2 started around the resume, long after the session's first event.
        s.markStale(now: t0.addingTimeInterval(160), silenceTimeout: 600, waitingTimeout: 600) { $0 == 2 ? t0.addingTimeInterval(99.4) : nil }
        #expect(s.sessions[key]!.endedAt == nil)
        #expect(s.sessions[key]!.root.status == .waiting)
    }

    @Test func aStartInANewProcessReplacesAnOpenSession() {
        var s = state([
            .sessionStarted(cwd: "/p", pid: 1),
            .promptSubmitted("go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec()),
        ])
        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 100))
        expectFreshRun(s, startedAt: 100, pid: 2)

        // The old process's end, arriving late.
        s.apply(event(.sessionEnded, at: 99))
        #expect(s.sessions[key]!.endedAt == nil)
    }

    @Test func aStartOfAnotherProcessNoNewerThanTheRunIsNotANewRun() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1), .promptSubmitted("go")])
        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 0))
        let session = s.sessions[key]!
        #expect(session.root.spec.prompt == "go")
        #expect(session.root.status == .working)
        #expect(session.startedAt == t0)
    }

    @Test(arguments: [1, nil] as [Int32?])
    func aStartInTheSameProcessKeepsTheRun(pid: Int32?) {
        var s = state([
            .sessionStarted(cwd: "/p", pid: 1),
            .promptSubmitted("go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec()),
        ])
        s.apply(event(.sessionStarted(cwd: nil, pid: pid), at: 100))

        let session = s.sessions[key]!
        #expect(session.startedAt == t0)
        #expect(session.pid == 1)
        #expect(session.root.status == .working)
        #expect(session.root.spec.prompt == "go")
        #expect(session.agents[.subagent("a")]?.status == .working)
    }

    @Test func aStartWithoutAPidRevivesAStaleSessionAsBefore() {
        var s = state([
            .sessionStarted(cwd: "/p", pid: nil),
            .promptSubmitted("go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec()),
        ])
        s.markStale(now: t0.addingTimeInterval(700), silenceTimeout: 600, waitingTimeout: 600) { _ in nil }
        s.apply(event(.sessionStarted(cwd: nil, pid: nil), at: 800))

        let session = s.sessions[key]!
        #expect(session.endedAt == nil)
        #expect(session.startedAt == t0)
        #expect(session.root.status == .working)
        #expect(session.agents[.subagent("a")]?.status == .working)
    }
}

/// A session whose start the app never saw learns its directory and process
/// from whatever event comes first.
@Suite struct UnseenStartTests {
    private func event(
        _ kind: AgentEvent.Kind, at seconds: TimeInterval = 0, cwd: String?, pid: Int32?
    ) -> AgentEvent {
        AgentEvent(session: key, timestamp: t0.addingTimeInterval(seconds), kind: kind, cwd: cwd, pid: pid)
    }

    @Test func anyEventFillsTheUnknownDirectoryAndProcess() {
        var s = CollectiveState()
        s.apply(event(.promptSubmitted("go"), cwd: "/p", pid: 42))
        let session = s.sessions[key]!
        #expect(session.cwd == "/p")
        #expect(session.pid == 42)
    }

    @Test func aLaterEventLeavesKnownValuesAlone() {
        var s = CollectiveState()
        s.apply(event(.promptSubmitted("go"), cwd: "/p", pid: 42))
        s.apply(event(.toolStarted(agent: .root, ToolActivity(name: "Bash")), at: 1, cwd: "/elsewhere", pid: 43))
        let session = s.sessions[key]!
        #expect(session.cwd == "/p")
        #expect(session.pid == 42)
    }

    @Test func aLaterEventKeepsWhatTheStartSet() {
        var s = state([.sessionStarted(cwd: "/p", pid: 42)])
        s.apply(event(.promptSubmitted("go"), at: 1, cwd: "/elsewhere", pid: 43))
        let session = s.sessions[key]!
        #expect(session.cwd == "/p")
        #expect(session.pid == 42)
    }

    @Test func aBackfilledPidStartsNoNewRun() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go")])
        s.apply(event(.toolStarted(agent: .root, ToolActivity(name: "Bash")), at: 5, cwd: nil, pid: 42))
        let session = s.sessions[key]!
        #expect(session.startedAt == t0)
        #expect(session.pid == 42)
        #expect(session.root.spec.prompt == "go")
        #expect(session.root.currentTool?.name == "Bash")
    }

    @Test func anEndedSessionLearnsNothing() {
        var s = state([.promptSubmitted("go"), .sessionEnded])
        let before = s
        s.apply(event(.replied(agent: .root, "late"), at: 1, cwd: "/p", pid: 42))
        s.apply(event(.toolStarted(agent: .root, ToolActivity(name: "Bash")), at: 2, cwd: "/p", pid: 42))
        #expect(s.sessions[key]?.cwd == nil)
        #expect(s.sessions[key]?.pid == nil)
        #expect(s.sessions[key]?.endedAt == before.sessions[key]?.endedAt)
    }

    @Test func aStaleSessionRevivedByTheEventLearnsItsProcess() {
        var s = state([.promptSubmitted("go")])
        s.markStale(now: t0.addingTimeInterval(700), silenceTimeout: 600, waitingTimeout: 600) { _ in nil }
        s.apply(event(.toolStarted(agent: .root, ToolActivity(name: "Bash")), at: 800, cwd: "/p", pid: 42))
        let session = s.sessions[key]!
        #expect(session.endedAt == nil)
        #expect(session.cwd == "/p")
        #expect(session.pid == 42)
    }

    /// The process ran long before the first event the app saw.
    @Test func aBackfilledPidOfAnOlderProcessKeepsTheSessionAlive() {
        var s = CollectiveState()
        s.apply(event(.promptSubmitted("go"), cwd: "/p", pid: 42))
        s.markStale(now: t0.addingTimeInterval(10_000), silenceTimeout: 600, waitingTimeout: 600) { _ in t0.addingTimeInterval(-3_600) }
        #expect(s.sessions[key]!.root.status == .working)
    }

    @Test func aBackfilledPidWhoseProcessIsGoneMakesTheSessionStale() {
        var s = CollectiveState()
        s.apply(event(.promptSubmitted("go"), cwd: "/p", pid: 42))
        s.markStale(now: t0.addingTimeInterval(5), silenceTimeout: 600, waitingTimeout: 600) { _ in nil }
        #expect(s.sessions[key]!.root.status == .stale)
    }
}

// MARK: Session names

/// A source can name a session, e.g. with a name the user can change in the
/// tool. A name is no sign of activity.
@Suite struct SessionNameTests {
    private func named(_ name: String, at seconds: TimeInterval) -> AgentEvent {
        event(.sessionNamed(name), at: seconds)
    }

    @Test func aNameNamesTheSession() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1)])
        #expect(s.sessions[key]!.name == nil)
        s.apply(named("project-01", at: 1))
        #expect(s.sessions[key]!.name == "project-01")
    }

    @Test func aNewerNameReplacesIt() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1)])
        s.apply(named("project-01", at: 1))
        s.apply(named("renamed", at: 5))
        #expect(s.sessions[key]!.name == "renamed")
    }

    @Test func anOlderNameArrivingLateDoesNot() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1)])
        s.apply(named("renamed", at: 5))
        s.apply(named("project-01", at: 1))
        #expect(s.sessions[key]!.name == "renamed")
    }

    @Test func withinTheSameMomentTheLaterAppliedWins() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1)])
        s.apply(named("first", at: 5))
        s.apply(named("second", at: 5))
        #expect(s.sessions[key]!.name == "second")
    }

    @Test func aNameIsNoActivity() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1), .promptSubmitted("go")])
        let before = s.sessions[key]!
        s.apply(named("project-01", at: 50))
        var session = s.sessions[key]!
        #expect(session.lastActivity == before.lastActivity)
        #expect(session.root.lastActivity == before.root.lastActivity)
        session.name = nil
        session.nameSetAt = nil
        #expect(session == before)
    }

    @Test func aNameDoesNotRevokeTheInterruptionGuess() {
        var s = state([.promptSubmitted("go")])
        s.markInterrupted(now: t0.addingTimeInterval(200), idleTimeout: 120, toolTimeout: 1800)
        s.apply(named("project-01", at: 210))
        #expect(s.sessions[key]!.root.status == .waiting)
        #expect(s.activeAgentCount == 0)
    }

    @Test func aNameDoesNotReviveAStaleSession() {
        var s = state([.promptSubmitted("go")])
        s.markStale(now: t0.addingTimeInterval(700), silenceTimeout: 600, waitingTimeout: 600) { _ in nil }
        s.apply(named("project-01", at: 710))
        let session = s.sessions[key]!
        #expect(session.root.status == .stale)
        #expect(session.endedAt == t0.addingTimeInterval(700))
        #expect(session.name == "project-01")
    }

    @Test func aNameDoesNotBringAnArchivedSessionBack() {
        var s = state([.promptSubmitted("go")])
        s.archive(.session(key), at: t0.addingTimeInterval(10))
        s.apply(named("project-01", at: 20))
        #expect(s.isArchived(key))
    }

    // MARK: Before the session appears

    @Test func aNameForAnUnknownSessionWaitsForItsFirstEvent() {
        var s = CollectiveState()
        s.apply(named("project-01", at: 0.5))
        #expect(s.sessions.isEmpty)
        #expect(s.activeAgentCount == 0)

        s.apply(event(.promptSubmitted("go"), at: 2))
        let session = s.sessions[key]!
        #expect(session.name == "project-01")
        #expect(session.lastActivity == t0.addingTimeInterval(2))
    }

    @Test func anEarlyNameKeepsOnlyTheNewest() {
        var s = CollectiveState()
        s.apply(named("renamed", at: 3.5))
        s.apply(named("project-01", at: 0.5))
        s.apply(event(.sessionStarted(cwd: nil, pid: nil), at: 1))
        #expect(s.sessions[key]!.name == "renamed")
    }

    @Test func anEarlyNameLosesToANewerOneAfterTheSessionAppears() {
        var s = CollectiveState()
        s.apply(named("project-01", at: 0.5))
        s.apply(event(.sessionStarted(cwd: nil, pid: nil), at: 1))
        s.apply(named("renamed", at: 3))
        #expect(s.sessions[key]!.name == "renamed")
    }

    /// An idle session's name can be hours old when it is parked, and the
    /// source won't send it again: its age must not count against it.
    @Test func pruneKeepsAnEarlyNameOlderThanTheRetention() {
        var s = CollectiveState()
        s.apply(named("project-01", at: 0))
        s.prune(now: t0.addingTimeInterval(7_200), retention: 3_600)
        s.apply(event(.promptSubmitted("go"), at: 7_210))
        #expect(s.sessions[key]!.name == "project-01")
    }

    @Test func pruneDropsAnEarlyNameParkedLongerThanTheRetention() {
        var s = CollectiveState()
        s.apply(named("project-01", at: 0))
        s.prune(now: t0.addingTimeInterval(100), retention: 60)
        s.prune(now: t0.addingTimeInterval(160), retention: 60)
        s.apply(event(.sessionStarted(cwd: nil, pid: nil), at: 165))
        #expect(s.sessions[key]!.name == "project-01")

        var late = CollectiveState()
        late.apply(named("project-01", at: 0))
        late.prune(now: t0.addingTimeInterval(100), retention: 60)
        late.prune(now: t0.addingTimeInterval(161), retention: 60)
        late.apply(event(.sessionStarted(cwd: nil, pid: nil), at: 165))
        #expect(late.sessions[key]!.name == nil)
    }

    @Test func pruneKeepsRecentEarlyNames() {
        var s = CollectiveState()
        s.apply(named("project-01", at: 0))
        s.prune(now: t0.addingTimeInterval(60), retention: 60)
        s.apply(event(.sessionStarted(cwd: nil, pid: nil), at: 0))
        #expect(s.sessions[key]!.name == "project-01")
    }

    // MARK: Ended sessions and new runs

    /// Named at 1 s, ended at 6 s.
    private func ended() -> CollectiveState {
        var s = state([.sessionStarted(cwd: "/p", pid: 1), .promptSubmitted("go")])
        s.apply(named("old-run", at: 1))
        s.apply(event(.sessionEnded, at: 6))
        return s
    }

    @Test func anEndedSessionIgnoresAName() {
        var s = ended()
        let before = s
        s.apply(named("renamed", at: 7))
        // The name itself is kept for a possible next run.
        #expect(s.sessions == before.sessions)
        #expect(s.sessions[key]!.name == "old-run")
    }

    @Test func theOldRunsNameCarriesOver() {
        // Same session id: the earlier run's name is the title until the new
        // run's process writes its own.
        var s = ended()
        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 20))
        #expect(s.sessions[key]!.name == "old-run")

        s.apply(named("new-run", at: 21))
        #expect(s.sessions[key]!.name == "new-run")
    }

    @Test func aNameArrivingAfterTheEndReachesTheNewRun() {
        // The new process names the session as it starts, before its start
        // event arrives.
        var s = ended()
        s.apply(named("new-run", at: 20.5))
        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 20))
        #expect(s.sessions[key]!.name == "new-run")
        #expect(s.sessions[key]!.endedAt == nil)
    }

    /// Times of the capture `7-continue` (Claude Code 2.1.287): the process
    /// started at 214.945 s and wrote the session's name at 214.997 s; its
    /// start hook ran at 215.090 s and carries 215 s, as hook times are whole
    /// seconds.
    @Test func aNameWrittenJustBeforeTheStartIsTheNewRuns() {
        var s = ended()
        s.apply(named("new-run", at: 19.997))
        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 20))
        #expect(s.sessions[key]!.name == "new-run")

        var late = ended()
        late.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 20))
        late.apply(named("new-run", at: 19.997))
        #expect(late.sessions[key]!.name == "new-run")
    }

    /// A slow start (plugins, MCP servers) can put the new process's name
    /// well before its start event, and the source won't send it again.
    @Test func aNameWrittenLongBeforeTheStartIsTheNewRuns() {
        var s = ended()
        s.apply(named("new-run", at: 10))
        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 20))
        #expect(s.sessions[key]!.name == "new-run")

        var late = ended()
        late.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 20))
        late.apply(named("new-run", at: 10))
        #expect(late.sessions[key]!.name == "new-run")
    }

    @Test func aNameWrittenLongBeforeTheStartOfAStaleRunsSuccessorIsItsName() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1), .promptSubmitted("go")])
        s.apply(named("old-run", at: 1))
        s.markStale(now: t0.addingTimeInterval(700), silenceTimeout: 600, waitingTimeout: 600) { _ in nil }
        s.apply(named("new-run", at: 710))
        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 720))
        let session = s.sessions[key]!
        #expect(session.startedAt == t0.addingTimeInterval(720))
        #expect(session.name == "new-run")
    }

    @Test func aNameOlderThanTheCarriedOneIsDiscarded() {
        var s = ended()
        s.apply(named("new-run", at: 15))
        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 20))
        s.apply(named("stale-name", at: 10))
        #expect(s.sessions[key]!.name == "new-run")
    }

    @Test func aNameKeptForAnEndedSessionGoesWithItWhenPruned() {
        var s = ended()
        s.apply(named("new-run", at: 21))
        s.prune(now: t0.addingTimeInterval(67), retention: 60)
        #expect(s.sessions.isEmpty)
        s.apply(event(.sessionStarted(cwd: "/p", pid: 2), at: 100))
        #expect(s.sessions[key]!.name == nil)
    }
}

// MARK: Reports from another process

/// A source can name the process a report or name comes from. Only the
/// session's own process speaks for it: another one, e.g. a daemon's for a
/// moment, would rename the session for good or end its turn.
@Suite struct ReportingProcessTests {
    private func named(_ name: String, at seconds: TimeInterval, by pid: Int32?) -> AgentEvent {
        AgentEvent(session: key, timestamp: t0.addingTimeInterval(seconds), kind: .sessionNamed(name), pid: pid)
    }

    private func report(_ activity: SessionActivity, at seconds: TimeInterval, by pid: Int32?) -> AgentEvent {
        AgentEvent(session: key, timestamp: t0.addingTimeInterval(seconds), kind: .activityReported(activity), pid: pid)
    }

    @Test func onlyTheSessionsOwnProcessNamesIt() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1)])
        s.apply(named("project-01", at: 1, by: 1))
        s.apply(named("bg-spare", at: 5, by: 9))
        #expect(s.sessions[key]!.name == "project-01")

        s.apply(named("renamed", at: 6, by: 1))
        #expect(s.sessions[key]!.name == "renamed")
    }

    /// pid 1 with a working root and subagent, the root asking to run a tool.
    private func busy() -> CollectiveState {
        var s = state([
            .sessionStarted(cwd: "/p", pid: 1),
            .promptSubmitted("go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec()),
        ])
        s.apply(report(.working, at: 2.5, by: 1))
        s.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 3))
        return s
    }

    @Test func anIdleReportOfAnotherProcessEndsNothing() {
        var s = busy()
        let before = s
        s.apply(report(.idle, at: 10.5, by: 9))
        #expect(s.sessions == before.sessions)
        #expect(s.activeAgentCount == 2)
        #expect(s.awaitsPermission)
    }

    @Test func anIdleReportOfTheOwnProcessEndsTheTurn() {
        var s = busy()
        s.apply(report(.idle, at: 10.5, by: 1))
        let session = s.sessions[key]!
        #expect(session.root.status == .waiting)
        #expect(session.agents[.subagent("a")]?.status == .done)
        #expect(session.lastReport == ActivityReport(activity: .idle, date: t0.addingTimeInterval(10.5), pid: 1))
        #expect(session.lastActivity == t0.addingTimeInterval(10.5))
        #expect(!s.awaitsPermission)
    }

    @Test func anotherProcessMakesNoSessionAppear() {
        var s = CollectiveState()
        s.apply(report(.working, at: 1, by: 9))
        s.apply(named("bg-spare", at: 1, by: 9))
        #expect(s.sessions.isEmpty)
        #expect(s.activeAgentCount == 0)
    }

    @Test func anotherProcessDoesNotReviveAStaleSession() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1), .promptSubmitted("go")])
        s.markStale(now: t0.addingTimeInterval(700), silenceTimeout: 600, waitingTimeout: 600) { _ in nil }
        let before = s
        s.apply(report(.working, at: 710, by: 9))
        s.apply(named("bg-spare", at: 710, by: 9))
        #expect(s.sessions == before.sessions)
        #expect(s.sessions[key]!.root.status == .stale)
    }

    @Test func anotherProcessDoesNotBecomeTheSessionsProcess() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go")])
        let before = s
        s.apply(report(.idle, at: 5.5, by: 9))
        s.apply(named("bg-spare", at: 5.5, by: 9))
        #expect(s.sessions == before.sessions)
        #expect(s.sessions[key]!.pid == nil)
    }

    // MARK: A resume in another process

    /// pid 1, named and working, then ended at 6 s or found dead at 700 s.
    private func over(stale: Bool) -> CollectiveState {
        var s = state([.sessionStarted(cwd: "/p", pid: 1), .promptSubmitted("go")])
        s.apply(named("old-run", at: 1.5, by: 1))
        s.apply(report(.working, at: 1.6, by: 1))
        if stale {
            s.markStale(now: t0.addingTimeInterval(700), silenceTimeout: 600, waitingTimeout: 600) { _ in nil }
        } else {
            s.apply(event(.sessionEnded, at: 6))
        }
        return s
    }

    /// The new process names the session and reports before its start
    /// arrives; the session isn't its own yet.
    @Test(arguments: [false, true])
    func theNewProcessesNameAndReportReachItsRun(stale: Bool) {
        var s = over(stale: stale)
        let before = s
        s.apply(named("new-run", at: 799.5, by: 2))
        s.apply(report(.working, at: 800.5, by: 2))
        #expect(s.sessions == before.sessions)

        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 800))
        let session = s.sessions[key]!
        #expect(session.pid == 2)
        #expect(session.startedAt == t0.addingTimeInterval(800))
        #expect(session.name == "new-run")
        #expect(session.lastReport == ActivityReport(activity: .working, date: t0.addingTimeInterval(800.5), pid: 2))
        #expect(session.root.status == .working)
    }

    @Test(arguments: [false, true])
    func theNewProcessesReportAfterItsStartReachesItsRun(stale: Bool) {
        var s = over(stale: stale)
        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 800))
        s.apply(report(.working, at: 800.5, by: 2))
        s.apply(named("new-run", at: 800.6, by: 2))
        let session = s.sessions[key]!
        #expect(session.name == "new-run")
        #expect(session.root.status == .working)
        #expect(s.activeAgentCount == 1)
    }

    /// As for a report naming no process: one older than the new run's
    /// start is discarded with the replacement, whoever reported it.
    @Test(arguments: [false, true])
    func theNewProcessesReportOlderThanItsStartIsDiscarded(stale: Bool) {
        var s = over(stale: stale)
        s.apply(report(.working, at: 799, by: 2))
        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 800))

        var unreported = over(stale: stale)
        unreported.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 800))
        #expect(s == unreported)
        #expect(s.sessions[key]!.lastReport == nil)
    }

    @Test(arguments: [false, true])
    func theOldProcessNoLongerSpeaksForTheNewRun(stale: Bool) {
        var s = over(stale: stale)
        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 800))
        s.apply(event(.promptSubmitted("again"), at: 801))
        s.apply(report(.idle, at: 801.5, by: 1))
        s.apply(named("old-process", at: 801.5, by: 1))
        let session = s.sessions[key]!
        #expect(session.name == "old-run")
        #expect(session.root.status == .working)
    }

    /// The old process is still the session's when it reports, so the old
    /// run takes the report; its date alone doesn't make it the new run's.
    @Test func theOldProcessesReportStaysWithTheOldRun() {
        var s = over(stale: true)
        s.apply(report(.working, at: 800.5, by: 1))
        #expect(s.sessions[key]!.lastReport == ActivityReport(activity: .working, date: t0.addingTimeInterval(800.5), pid: 1))

        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 800))
        var unreported = over(stale: true)
        unreported.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 800))
        let session = s.sessions[key]!
        #expect(session.pid == 2)
        #expect(session.lastReport == nil)
        #expect(session.root.status == .waiting)
        #expect(s.activeAgentCount == 0)
        #expect(s.sessions == unreported.sessions)
    }

    // MARK: While the session's process is unknown

    /// Every hook of a source that names processes brings the session's, so
    /// a report waits for the next one rather than guessing.
    @Test func aReportWaitsUntilAHookNamesItsProcess() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go")])
        s.apply(report(.idle, at: 2.5, by: 1))
        s.apply(named("project-01", at: 2.5, by: 1))
        #expect(s.sessions[key]!.root.status == .working)
        #expect(s.sessions[key]!.name == nil)

        s.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(2), kind: .toolFinished(agent: .root), pid: 1))
        let session = s.sessions[key]!
        #expect(session.pid == 1)
        #expect(session.root.status == .waiting)
        #expect(session.lastReport == ActivityReport(activity: .idle, date: t0.addingTimeInterval(2.5), pid: 1))
        #expect(session.name == "project-01")
    }

    @Test func aReportStaysParkedWhenAHookNamesAnotherProcess() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go")])
        s.apply(report(.idle, at: 2.5, by: 9))
        s.apply(named("bg-spare", at: 2.5, by: 9))
        s.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(2), kind: .toolFinished(agent: .root), pid: 3))
        #expect(s.sessions[key]!.pid == 3)
        #expect(s.sessions[key]!.root.status == .working)
        #expect(s.sessions[key]!.name == nil)

        s.apply(event(.turnStarted, at: 3))
        #expect(s.sessions[key]!.lastReport == nil)
        #expect(s.sessions[key]!.name == nil)
    }

    // MARK: Pruning

    @Test(arguments: [(160, true), (161, false)] as [(TimeInterval, Bool)])
    func whatAnotherProcessReportedWaitsNoLongerThanTheRetention(lastPrune: TimeInterval, kept: Bool) {
        var s = state([.sessionStarted(cwd: "/p", pid: 1), .promptSubmitted("go")])
        s.apply(report(.idle, at: 300, by: 2))
        s.apply(named("new-run", at: 300, by: 2))
        s.prune(now: t0.addingTimeInterval(100), retention: 60)
        s.prune(now: t0.addingTimeInterval(lastPrune), retention: 60)

        s.apply(event(.sessionStarted(cwd: nil, pid: 2), at: 200))
        let session = s.sessions[key]!
        #expect(session.pid == 2)
        #expect(session.name == (kept ? "new-run" : nil))
        #expect(session.lastReport == (kept ? ActivityReport(activity: .idle, date: t0.addingTimeInterval(300), pid: 2) : nil))
    }

    @Test func whatAnotherProcessReportedGoesWithAPrunedSession() {
        var s = over(stale: false)
        s.apply(report(.working, at: 21, by: 2))
        s.apply(named("new-run", at: 21, by: 2))
        s.prune(now: t0.addingTimeInterval(67), retention: 60)
        #expect(s.sessions.isEmpty)

        s.apply(event(.sessionStarted(cwd: "/p", pid: 2), at: 100))
        let session = s.sessions[key]!
        #expect(session.name == nil)
        #expect(session.lastReport == nil)
        #expect(session.root.status == .waiting)
    }
}

// MARK: Standby

/// A tool can start a session's process ahead of time, waiting to be given
/// work. That session is none the user started: while its own process
/// reports standby it is hidden and counts nothing.
@Suite struct StandbyTests {
    private let other = SessionKey(source: source, sessionID: "s2")

    private func report(_ activity: SessionActivity, at seconds: TimeInterval, by pid: Int32?, session: SessionKey = key) -> AgentEvent {
        AgentEvent(session: session, timestamp: t0.addingTimeInterval(seconds), kind: .activityReported(activity), pid: pid)
    }

    /// pid 1 on standby, though something asks to run a tool and a turn runs.
    private func standby() -> CollectiveState {
        var s = state([.sessionStarted(cwd: "/p", pid: 1)])
        s.apply(report(.standby, at: 0.5, by: 1))
        s.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 1))
        s.apply(event(.promptSubmitted("go"), at: 2))
        return s
    }

    @Test func aStandbySessionCountsNothing() {
        let s = standby()
        #expect(s.sessions[key]!.isStandby)
        #expect(s.sessions[key]!.root.status == .working)
        #expect(s.activeAgentCount == 0)
        #expect(!s.awaitsPermission)
        #expect(s.shownSessions.isEmpty)
        #expect(s.shownSession(key) == nil)
    }

    /// Like an idle report, standby ends what a late backlog event starts.
    @Test func backlogOlderThanAStandbyReportCreatesFinishedSubagents() {
        var s = CollectiveState()
        s.apply(report(.standby, at: 10, by: nil))
        s.apply(event(.promptSubmitted("go"), at: 1))
        s.apply(event(.toolStarted(agent: .subagent("x"), ToolActivity(name: "Bash")), at: 5))
        let agent = s.sessions[key]!.agents[.subagent("x")]!
        #expect(agent.status == .done)
        #expect(agent.endedAt == t0.addingTimeInterval(10))
    }

    @Test func aStandbyReportPutsTheRootToRest() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1), .promptSubmitted("go")])
        s.apply(report(.standby, at: 1.5, by: 1))
        #expect(s.sessions[key]!.root.status == .waiting)
    }

    @Test func aStandbyReportBeforeTheSessionAppliesOnceItAppears() {
        var s = CollectiveState()
        s.apply(report(.standby, at: 0.5, by: 1))
        s.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(1), kind: .sessionStarted(cwd: "/p", pid: 1), pid: 1))
        #expect(s.sessions[key]!.isStandby)
        #expect(s.shownSessions.isEmpty)
    }

    @Test func aStandbyReportOfAnotherProcessHidesNothing() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1), .promptSubmitted("go")])
        s.apply(report(.standby, at: 1.5, by: 9))
        #expect(!s.sessions[key]!.isStandby)
        #expect(s.activeAgentCount == 1)
        #expect(s.shownSession(key) != nil)
    }

    /// The process takes on another session; the one it waited with is
    /// never continued and stays hidden.
    @Test func aClaimShowsTheNewSessionOnly() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1)])
        s.apply(report(.standby, at: 0.5, by: 1))
        s.apply(AgentEvent(session: other, timestamp: t0.addingTimeInterval(10), kind: .sessionStarted(cwd: "/p", pid: 1), pid: 1))
        s.apply(report(.idle, at: 10.5, by: 1, session: other))
        s.apply(AgentEvent(session: other, timestamp: t0.addingTimeInterval(11), kind: .promptSubmitted("job"), pid: 1))
        s.apply(report(.working, at: 11.5, by: 1, session: other))

        #expect(s.sessions[key]!.isStandby)
        #expect(!s.sessions[other]!.isStandby)
        #expect(s.shownSessions.map(\.key) == [other])
        #expect(s.activeAgentCount == 1)
    }

    @Test(arguments: [SessionActivity.idle, .working])
    func aLaterReportOfTheOwnProcessShowsTheSessionAgain(activity: SessionActivity) {
        var s = standby()
        s.apply(report(activity, at: 3, by: 1))
        #expect(!s.sessions[key]!.isStandby)
        #expect(s.shownSession(key) != nil)
    }

    /// Ending without ever being given work doesn't make it one the user started.
    @Test func anEndedStandbySessionStaysHidden() {
        var s = standby()
        s.apply(event(.sessionEnded, at: 3))
        #expect(s.sessions[key]!.root.status == .done)
        #expect(s.sessions[key]!.isStandby)
        #expect(s.shownSessions.isEmpty)
        #expect(s.shownSession(key) == nil)
    }

    /// A report sent before the end shows the session as ended; ended, it
    /// takes no later one, as any ended session.
    @Test func aStandbySessionThatWorkedBeforeItsEndIsShownAsEnded() {
        var s = standby()
        s.apply(report(.working, at: 2.5, by: 1))
        s.apply(event(.sessionEnded, at: 3))
        #expect(!s.sessions[key]!.isStandby)
        #expect(s.shownSession(key)?.root.status == .done)
    }

    /// A new run under the same id starts without the old run's report.
    @Test func aNewRunOfAnEndedStandbySessionIsShown() {
        var s = standby()
        s.apply(event(.sessionEnded, at: 3))
        s.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(10), kind: .sessionStarted(cwd: "/p", pid: 2), pid: 2))
        #expect(!s.sessions[key]!.isStandby)
        #expect(s.shownSession(key) != nil)
    }

    @Test func anEndedStandbySessionIsPrunedLikeAnyEnded() {
        var s = standby()
        s.apply(event(.sessionEnded, at: 3))
        s.prune(now: t0.addingTimeInterval(3 + 61), retention: 60)
        #expect(s.sessions[key] == nil)
    }

    /// Stale is only a guess, and a session on standby that went quiet is
    /// still none the user started.
    @Test func aStaleStandbySessionStaysHidden() {
        var s = standby()
        s.markStale(now: t0.addingTimeInterval(100), silenceTimeout: 60, waitingTimeout: 60) { _ in nil }
        #expect(s.sessions[key]!.root.status == .stale)
        #expect(s.sessions[key]!.isStandby)
        #expect(s.shownSessions.isEmpty)
    }
}

// MARK: Rest

/// When a session began to wait for nothing but the next prompt; the popover
/// moves it to the "Idle" group by it.
@Suite struct RestTests {
    private func restingSince(_ s: CollectiveState) -> TimeInterval? {
        s.sessions[key]!.restingSince.map { $0.timeIntervalSince(t0) }
    }

    @Test func aTurnEndStartsTheRestAndAPromptEndsIt() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go")])
        #expect(restingSince(s) == nil)
        s.apply(event(.turnEnded(), at: 5))
        #expect(restingSince(s) == 5)
        s.apply(event(.promptSubmitted("more"), at: 9))
        #expect(restingSince(s) == nil)
    }

    /// Nothing that leaves the session resting moves the start: not a reply
    /// arriving late, a model or name report, or a call that is over already.
    @Test func eventsThatChangeNothingLeaveTheRest() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go"), .turnEnded()])
        s.apply(event(.replied(agent: .root, "done"), at: 10))
        s.apply(event(.modelChanged(to: "m", from: nil), at: 20))
        s.apply(event(.sessionNamed("name"), at: 30))
        s.apply(event(.toolStarted(agent: .root, ToolActivity(name: "Read"), alreadyEnded: true), at: 40))
        s.apply(event(.activityReported(.idle), at: 50))
        s.apply(event(.activityReported(.idle), at: 60))
        #expect(restingSince(s) == 2)
    }

    @Test func aPermissionRequestInterruptsTheRest() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go"), .turnEnded()])
        s.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 10))
        #expect(restingSince(s) == nil)
        s.apply(event(.activityReported(.idle), at: 20))
        #expect(restingSince(s) == 20)
    }

    /// A source reporting that the session needs the user, e.g. for a dialog,
    /// ends the rest; the next idle report begins a new one.
    @Test func aWaitingReportInterruptsTheRest() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go"), .turnEnded()])
        s.apply(event(.activityReported(.waiting), at: 10))
        #expect(restingSince(s) == nil)
        s.apply(event(.activityReported(.idle), at: 20))
        #expect(restingSince(s) == 20)
    }

    /// The guess that the user stopped the turn makes the root wait; the rest
    /// counts from the last event, when the turn went silent.
    @Test func anInterruptionGuessRestsFromTheLastEvent() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go")])
        s.markInterrupted(now: t0.addingTimeInterval(200), idleTimeout: 120, toolTimeout: 1800)
        #expect(restingSince(s) == 1)
        s.apply(event(.toolStarted(agent: .root, ToolActivity(name: "Bash")), at: 210))
        #expect(restingSince(s) == nil)
    }

    /// A session the sweep took for dead and that turns out alive rests on
    /// from where it was, yet counts the rest as begun anew: the open
    /// popover must not take it into the "Idle" group again.
    @Test func aRevivedSessionKeepsItsRest() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go"), .turnEnded()])
        let begun = s.sessions[key]!.restsBegun
        s.markStale(now: t0.addingTimeInterval(100), silenceTimeout: 60, waitingTimeout: 60) { _ in nil }
        s.apply(event(.modelChanged(to: "m", from: nil), at: 120))
        #expect(s.sessions[key]!.endedAt == nil)
        #expect(restingSince(s) == 2)
        #expect(s.sessions[key]!.restsBegun > begun)
    }
}

// MARK: Background shells

/// The background shells a session listed at its last turn end: a
/// snapshot, kept with its time, that says nothing about activity.
@Suite struct BackgroundShellListingTests {
    private let build = BackgroundShell(id: "b1", command: "make build", description: "Build")
    private let watch = BackgroundShell(id: "b2", command: "npm run watch")

    private func listed(_ shells: [BackgroundShell], at seconds: TimeInterval) -> AgentEvent {
        event(.backgroundShellsListed(shells), at: seconds)
    }

    private func listedAt(_ s: CollectiveState) -> TimeInterval? {
        s.sessions[key]!.backgroundShellsListedAt.map { $0.timeIntervalSince(t0) }
    }

    @Test func aListingIsKeptWithItsTime() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go"), .turnEnded()])
        s.apply(listed([build, watch], at: 2))
        #expect(s.sessions[key]!.backgroundShells == [build, watch])
        #expect(listedAt(s) == 2)
    }

    @Test func anOlderListingArrivingLateDoesNotReplaceIt() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go"), .turnEnded()])
        s.apply(listed([watch], at: 8))
        s.apply(listed([build, watch], at: 5))
        #expect(s.sessions[key]!.backgroundShells == [watch])
        #expect(listedAt(s) == 8)
    }

    /// Hook times are whole seconds: within one, the later arrived wins.
    @Test func withinOneSecondTheLaterArrivedWins() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go"), .turnEnded()])
        s.apply(listed([build, watch], at: 5))
        s.apply(listed([watch], at: 5))
        #expect(s.sessions[key]!.backgroundShells == [watch])
    }

    @Test func aNewerEmptyListingClearsIt() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go"), .turnEnded()])
        s.apply(listed([build], at: 5))
        s.apply(listed([], at: 9))
        #expect(s.sessions[key]!.backgroundShells.isEmpty)
        #expect(listedAt(s) == 9)
    }

    /// Resting, with a guessed interruption, presumed dead: a listing of
    /// none leaves each session as it was but for what it lists and that no
    /// shell runs, which none did.
    @Test func aListingChangesNothingElse() {
        let resting = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go"), .turnEnded()])
        var interrupted = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go")])
        interrupted.markInterrupted(now: t0.addingTimeInterval(200), idleTimeout: 120, toolTimeout: 1800)
        var stale = state([.sessionStarted(cwd: "/p", pid: 7), .promptSubmitted("go")])
        stale.markStale(now: t0.addingTimeInterval(100), silenceTimeout: 60, waitingTimeout: 60) { _ in nil }

        for before in [resting, interrupted, stale] {
            var after = before
            after.apply(listed([], at: 300))
            var session = after.sessions[key]!
            #expect(listedAt(after) == 300)
            session.backgroundShellsListedAt = nil
            session.backgroundShellSign = nil
            #expect(session == before.sessions[key]!)
            #expect(after.activeAgentCount == before.activeAgentCount)
        }
    }

    /// It comes after its hook's own events, which make the session known.
    @Test func aListingAloneMakesNoSessionAppear() {
        var s = CollectiveState()
        s.apply(listed([build], at: 1))
        #expect(s.sessions.isEmpty)
    }

    @Test func anEndedSessionListsNoMore() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1), .promptSubmitted("go"), .turnEnded()])
        s.apply(listed([build], at: 3))
        s.apply(event(.sessionEnded, at: 4))
        s.apply(listed([], at: 5))
        #expect(s.sessions[key]!.backgroundShells == [build])
        #expect(listedAt(s) == 3)
    }

    /// A new run under the same id starts with nothing listed, and what the
    /// run before listed late stays the run before's.
    @Test func aNewRunListsNothingOfTheRunBefore() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1), .promptSubmitted("go"), .turnEnded()])
        s.apply(listed([build], at: 3))
        s.apply(event(.sessionEnded, at: 4))
        s.apply(event(.sessionStarted(cwd: "/p", pid: 2), at: 10))
        #expect(s.sessions[key]!.backgroundShells.isEmpty)
        #expect(listedAt(s) == nil)
        s.apply(listed([watch], at: 9))
        #expect(s.sessions[key]!.backgroundShells.isEmpty)
    }
}

/// Whether a background shell runs: set by a report of one, a shell's
/// start or a listing naming any; kept while a turn runs; cleared by a report
/// that the session waits, idles or stands by, an empty listing, the
/// session's end or a new run. The newest sign wins, by event time.
@Suite struct BackgroundShellRunsTests {
    private let build = BackgroundShell(id: "b1", command: "make build", description: "Build")

    private func report(_ activity: SessionActivity, at seconds: TimeInterval) -> AgentEvent {
        event(.activityReported(activity), at: seconds)
    }

    private func listed(_ shells: [BackgroundShell], at seconds: TimeInterval) -> AgentEvent {
        event(.backgroundShellsListed(shells), at: seconds)
    }

    private func started(at seconds: TimeInterval) -> AgentEvent {
        event(.backgroundShellStarted(id: "b1"), at: seconds)
    }

    /// Prompted at 1, turn ended at 2.
    private func turnOver() -> CollectiveState {
        state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go"), .turnEnded()])
    }

    /// Prompted at 1, working.
    private func working() -> CollectiveState {
        state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go")])
    }

    private func runs(_ s: CollectiveState) -> Bool { s.sessions[key]!.runsBackgroundShell }

    @Test func noSignNoShell() {
        #expect(!runs(working()))
        #expect(!runs(turnOver()))
    }

    @Test func aShellsStartSetsItWhileTheTurnRuns() {
        var s = working()
        s.apply(started(at: 3))
        #expect(runs(s))
        #expect(s.sessions[key]!.root.status == .working)
    }

    @Test func aListingNamingAShellSetsIt() {
        var s = turnOver()
        s.apply(listed([build], at: 2))
        #expect(runs(s))
    }

    @Test func itIsKeptAcrossANewTurn() {
        var s = working()
        s.apply(started(at: 3))
        s.apply(event(.turnEnded(), at: 4))
        s.apply(listed([build], at: 4))
        s.apply(event(.promptSubmitted("next"), at: 6))
        s.apply(report(.working, at: 6.2))
        let session = s.sessions[key]!
        #expect(session.root.status == .working)
        #expect(session.runsBackgroundShell)
    }

    @Test func aWaitingOrIdleReportClearsAStartedShell() {
        for activity in [SessionActivity.waiting, .idle] {
            var s = working()
            s.apply(started(at: 3))
            s.apply(event(.turnEnded(), at: 4))
            s.apply(report(activity, at: 4.5))
            #expect(!runs(s), "\(activity)")
        }
    }

    @Test func anEmptyListingClearsIt() {
        var s = working()
        s.apply(started(at: 3))
        s.apply(event(.turnEnded(), at: 5))
        s.apply(listed([], at: 5))
        #expect(!runs(s))
    }

    @Test func theSessionsEndClearsIt() {
        var s = turnOver()
        s.apply(listed([build], at: 2))
        s.apply(event(.sessionEnded, at: 3))
        #expect(!runs(s))
    }

    /// The run before's shell is not the new run's, nor is what it said late.
    @Test func aNewRunStartsWithoutIt() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1), .promptSubmitted("go")])
        s.apply(started(at: 2))
        s.apply(event(.sessionEnded, at: 3))
        s.apply(event(.sessionStarted(cwd: "/p", pid: 2), at: 10))
        #expect(!runs(s))
        s.apply(started(at: 9))
        s.apply(listed([build], at: 9))
        #expect(!runs(s))
    }

    /// Turn end with a shell running: the hook's listing and the report that
    /// follows it agree, whichever arrives first.
    @Test func theStopsListingAndTheShellReportAgreeInEitherOrder() {
        for reportFirst in [false, true] {
            var s = turnOver()
            let signs = [listed([build], at: 5), report(.backgroundShell, at: 5.4)]
            for sign in reportFirst ? signs.reversed() : signs { s.apply(sign) }
            #expect(runs(s), "report first: \(reportFirst)")
        }
    }

    /// Turn end without shells: the empty listing and the idle report agree
    /// too, and an earlier start doesn't outlive them.
    @Test func theStopsEmptyListingAndTheIdleReportAgreeInEitherOrder() {
        for reportFirst in [false, true] {
            var s = working()
            s.apply(started(at: 3))
            let signs = [listed([], at: 5), report(.idle, at: 5.4)]
            for sign in reportFirst ? signs.reversed() : signs { s.apply(sign) }
            #expect(!runs(s), "report first: \(reportFirst)")
        }
    }

    /// Hooks run async: what arrives late from before the newest sign leaves it.
    @Test func olderSignsArrivingLateDontFlipIt() {
        var cleared = working()
        cleared.apply(report(.idle, at: 6.5))
        cleared.apply(started(at: 3))
        cleared.apply(listed([build], at: 5))
        cleared.apply(report(.backgroundShell, at: 6))
        #expect(!runs(cleared))

        var set = turnOver()
        set.apply(report(.backgroundShell, at: 8.5))
        set.apply(listed([], at: 5))
        set.apply(report(.idle, at: 7))
        #expect(runs(set))
    }

    /// Hook times are whole seconds: within one, the later arrived wins. A
    /// report has milliseconds, so one in the hook's second is newer.
    @Test func withinOneSecondTheLaterArrivedWins() {
        var s = turnOver()
        s.apply(listed([build], at: 5))
        s.apply(listed([], at: 5))
        #expect(!runs(s))
        s.apply(started(at: 5))
        #expect(runs(s))

        var reported = turnOver()
        reported.apply(report(.idle, at: 5.3))
        reported.apply(listed([build], at: 5))
        #expect(!runs(reported))
    }

    /// A wait within the turn, for a permission or a question, says nothing
    /// about the shell the turn started: the turn's end lists what runs.
    @Test func aWaitWithinTheTurnKeepsTheShell() {
        let asks: [AgentEvent.Kind] = [
            .permissionRequested(agent: .root, ToolActivity(name: "Bash", detail: "rm -rf build")),
            .questionAsked(agent: .root, [Question(text: "Which?", options: [QuestionOption(label: "A")])]),
        ]
        for ask in asks {
            var s = working()
            s.apply(started(at: 3))
            s.apply(event(ask, at: 4))
            s.apply(report(.waiting, at: 4.5))
            #expect(runs(s), "\(ask)")
            s.apply(report(.working, at: 5.5))
            s.apply(report(.waiting, at: 6.5))
            s.apply(report(.waiting, at: 7.5))
            #expect(runs(s), "\(ask)")
            s.apply(event(.turnEnded(), at: 9))
            s.apply(listed([build], at: 9))
            #expect(runs(s), "\(ask)")
        }
    }

    /// A hand-back runs a turn too.
    @Test func aWaitWithinAHandBackTurnKeepsTheShell() {
        var s = turnOver()
        s.apply(listed([build], at: 2))
        s.apply(event(.turnStarted, at: 5))
        s.apply(report(.waiting, at: 6.5))
        #expect(runs(s))
    }

    /// The `Stop` came first, in the report's second: the turn is over.
    @Test func aWaitJustAfterTheTurnsEndClearsTheShell() {
        var s = working()
        s.apply(started(at: 3))
        s.apply(event(.turnEnded(), at: 5))
        s.apply(report(.waiting, at: 5.3))
        #expect(!runs(s))
    }

    /// The report came first, the turn still running as far as known: the
    /// `Stop` arriving late decides with its listing.
    @Test func aStopArrivingAfterTheWaitDecidesWithItsListing() {
        for shells in [[], [build]] {
            var s = working()
            s.apply(started(at: 3))
            s.apply(report(.waiting, at: 5.3))
            #expect(runs(s))
            s.apply(event(.turnEnded(), at: 5))
            s.apply(listed(shells, at: 5))
            #expect(runs(s) == !shells.isEmpty, "\(shells)")
        }
    }

    /// No `Stop` after an interrupt, but a report that no turn runs: a wait
    /// after it is no longer within the turn.
    @Test func aWaitAfterAReportThatNoTurnRunsClearsTheShell() {
        var s = working()
        s.apply(started(at: 3))
        s.apply(report(.backgroundShell, at: 4.5))
        s.apply(report(.waiting, at: 6.5))
        #expect(!runs(s))
    }

    /// A shell keeps the session out of "Idle" however it became known.
    @Test func aListedShellKeepsTheSessionFromResting() {
        var s = turnOver()
        #expect(s.sessions[key]!.rests)
        s.apply(listed([build], at: 2))
        #expect(!s.sessions[key]!.rests)
        #expect(s.sessions[key]!.restingSince == nil)
        s.apply(report(.idle, at: 9))
        #expect(s.sessions[key]!.rests)
        #expect(s.sessions[key]!.restingSince == t0.addingTimeInterval(9))
    }

    /// No sign of activity: a shell's start changes no status, time or count.
    @Test func aShellsStartChangesNothingElse() {
        let before = working()
        var after = before
        after.apply(started(at: 50))
        var session = after.sessions[key]!
        #expect(session.backgroundShellStartedAt == t0.addingTimeInterval(50))
        session.backgroundShellStartedAt = nil
        session.backgroundShellSign = nil
        #expect(session == before.sessions[key]!)
    }

    @Test func aShellsStartAloneMakesNoSessionAppear() {
        var s = CollectiveState()
        s.apply(started(at: 1))
        #expect(s.sessions.isEmpty)
    }
}

// MARK: Effort

@Suite struct EffortTests {
    private let high = EffortLevel(step: 3, name: "high")!
    private let max = EffortLevel(step: 5, name: "max")!

    private func reported(_ level: EffortLevel, by agent: AgentRef = .root, at seconds: TimeInterval) -> AgentEvent {
        event(.effortReported(agent: agent, level), at: seconds)
    }

    @Test func aFirstReportIsTheEffortAndNoChange() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go")])
        s.apply(reported(high, at: 2))
        let session = s.sessions[key]!
        #expect(session.effort == EffortLevel(step: 3, name: "high"))
        #expect(session.lastEffortChange == nil)
    }

    @Test func anotherLevelIsAChangeFromThePreviousOne() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go")])
        s.apply(reported(high, at: 2))
        s.apply(reported(max, at: 10))
        let session = s.sessions[key]!
        #expect(session.effort == EffortLevel(step: 5, name: "max"))
        #expect(session.lastEffortChange == EffortChange(from: EffortLevel(step: 3, name: "high")!, at: t0.addingTimeInterval(10)))
    }

    @Test func theSameLevelAgainKeepsTheLastChange() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go")])
        s.apply(reported(high, at: 2))
        s.apply(reported(max, at: 10))
        s.apply(reported(max, at: 20))
        let session = s.sessions[key]!
        #expect(session.effort == EffortLevel(step: 5, name: "max"))
        #expect(session.lastEffortChange == EffortChange(from: EffortLevel(step: 3, name: "high")!, at: t0.addingTimeInterval(10)))
    }

    @Test func aLateOlderReportDoesNotUndoAChange() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go")])
        s.apply(reported(high, at: 2))
        s.apply(reported(max, at: 10))
        s.apply(reported(high, at: 6))
        let session = s.sessions[key]!
        #expect(session.effort == EffortLevel(step: 5, name: "max"))
        #expect(session.lastEffortChange == EffortChange(from: EffortLevel(step: 3, name: "high")!, at: t0.addingTimeInterval(10)))
    }

    @Test func withinTheSameSecondTheLaterAppliedWins() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go")])
        s.apply(reported(high, at: 2))
        s.apply(reported(max, at: 5))
        s.apply(reported(high, at: 5))
        let session = s.sessions[key]!
        #expect(session.effort == EffortLevel(step: 3, name: "high"))
        #expect(session.lastEffortChange == EffortChange(from: EffortLevel(step: 5, name: "max")!, at: t0.addingTimeInterval(5)))
    }

    @Test func aSubagentsEffortIsItsOwn() {
        var s = state([
            .sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(type: "explore")),
        ])
        s.apply(reported(max, by: .subagent("a"), at: 3))
        var session = s.sessions[key]!
        #expect(session.agents[.subagent("a")]!.effort == EffortLevel(step: 5, name: "max"))
        #expect(session.effort == nil)

        s.apply(reported(high, at: 4))
        session = s.sessions[key]!
        #expect(session.effort == EffortLevel(step: 3, name: "high"))
        #expect(session.lastEffortChange == nil)
        #expect(session.agents[.subagent("a")]!.effort == EffortLevel(step: 5, name: "max"))
        #expect(session.root.effort == nil)
    }

    @Test func aLateOlderReportOfASubagentDoesNotReplaceItsEffort() {
        var s = state([
            .sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(type: "explore")),
        ])
        s.apply(reported(max, by: .subagent("a"), at: 10))
        s.apply(reported(high, by: .subagent("a"), at: 6))
        #expect(s.sessions[key]!.agents[.subagent("a")]!.effort == EffortLevel(step: 5, name: "max"))
        s.apply(reported(high, by: .subagent("a"), at: 10))
        #expect(s.sessions[key]!.agents[.subagent("a")]!.effort == EffortLevel(step: 3, name: "high"))
    }

    /// An effort is no sign of work, so it invents no agent; the hook's own
    /// events come first and make it known.
    @Test func aReportOfAnUnknownSubagentIsDropped() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go")])
        s.apply(reported(max, by: .subagent("ghost"), at: 3))
        let session = s.sessions[key]!
        #expect(session.agents[.subagent("ghost")] == nil)
        #expect(session.effort == nil)
    }

    @Test func aReportLeavesAWaitingSessionWaitingAndItsTimesAlone() {
        var s = state([
            .sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(type: "explore")),
            .turnEnded(),
        ])
        s.apply(reported(high, at: 30))
        s.apply(reported(max, by: .subagent("a"), at: 40))
        let session = s.sessions[key]!
        #expect(session.root.status == .waiting)
        #expect(session.agents[.subagent("a")]!.status == .working)
        #expect(session.lastActivity == t0.addingTimeInterval(3))
        #expect(session.root.lastActivity == t0.addingTimeInterval(3))
        #expect(session.agents[.subagent("a")]!.lastActivity == t0.addingTimeInterval(2))
    }

    /// The silence that makes `markInterrupted` guess counts from the last
    /// real event, not from a report of the effort.
    @Test func aReportIsNoActivityThatPutsOffTheInterruptionGuess() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go")])
        s.apply(reported(high, at: 100))
        s.markInterrupted(now: t0.addingTimeInterval(122), idleTimeout: 120, toolTimeout: 1800)
        #expect(s.sessions[key]!.root.status == .waiting)
    }

    @Test func aReportKeepsTheInterruptionGuess() {
        var s = state([.promptSubmitted("go"), .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "make"))])
        s.markInterrupted(now: t0.addingTimeInterval(2000), idleTimeout: 120, toolTimeout: 1800)
        s.apply(reported(high, at: 2010))
        var session = s.sessions[key]!
        #expect(session.root.status == .waiting)
        #expect(session.root.currentTool == nil)
        #expect(session.effort == EffortLevel(step: 3, name: "high"))

        s.apply(event(.toolStarted(agent: .subagent("late"), ToolActivity(name: "Read")), at: 2020))
        session = s.sessions[key]!
        #expect(session.root.status == .working)
        #expect(session.root.currentTool == ToolActivity(name: "Bash", detail: "make"))
    }

    @Test func aReportDoesNotReviveAStaleSession() {
        var s = state([.sessionStarted(cwd: nil, pid: 99), .promptSubmitted("go")])
        s.markStale(now: t0.addingTimeInterval(50), silenceTimeout: 600, waitingTimeout: 600) { _ in nil }
        s.apply(reported(high, at: 60))
        let session = s.sessions[key]!
        #expect(session.root.status == .stale)
        #expect(session.endedAt == t0.addingTimeInterval(50))
        // A stale session can come back, so it keeps receiving the value.
        #expect(session.effort == EffortLevel(step: 3, name: "high"))
    }

    @Test func aReportForAnArchivedSubagentLeavesItArchived() {
        var s = state([.promptSubmitted("go"), .agentSpawned(id: "a", parent: .root, spec: AgentSpec())])
        s.archive(.agent(key, .subagent("a")), at: t0.addingTimeInterval(10))
        s.apply(reported(max, by: .subagent("a"), at: 20))
        #expect(s.isArchived(.subagent("a"), in: key))
        #expect(s.sessions[key]!.agents[.subagent("a")]!.effort == EffortLevel(step: 5, name: "max"))
    }

    @Test func anEndedSessionKeepsItsEffortAgainstReportsAfterTheEnd() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go")])
        s.apply(reported(high, at: 2))
        s.apply(event(.sessionEnded, at: 3))
        s.apply(reported(max, at: 10))
        let session = s.sessions[key]!
        #expect(session.effort == EffortLevel(step: 3, name: "high"))
        #expect(session.lastEffortChange == nil)
    }

    /// As with a reply, a report can arrive after the end it predates; it
    /// still belongs to the run, and the session stays over.
    @Test(arguments: [4.0, 5.0])
    func aLateReportStampedUpToTheEndStillCounts(at seconds: TimeInterval) {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go")])
        s.apply(reported(high, at: 2))
        s.apply(event(.sessionEnded, at: 5))
        s.apply(reported(max, at: seconds))
        let session = s.sessions[key]!
        #expect(session.effort == EffortLevel(step: 5, name: "max"))
        #expect(session.lastEffortChange == EffortChange(from: EffortLevel(step: 3, name: "high")!, at: t0.addingTimeInterval(seconds)))
        #expect(session.endedAt == t0.addingTimeInterval(5))
        #expect(session.lastActivity == t0.addingTimeInterval(5))
    }

    @Test func aReportDoesNotBringAnArchivedSessionBack() {
        var s = state([.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("go")])
        s.archive(.session(key), at: t0.addingTimeInterval(10))
        s.apply(reported(high, at: 20))
        #expect(s.isArchived(key))
        #expect(s.sessions[key]!.effort == EffortLevel(step: 3, name: "high"))
    }

    @Test func aReportAloneMakesNoSessionAppear() {
        var s = CollectiveState()
        s.apply(reported(high, at: 0))
        #expect(s.sessions.isEmpty)
    }

    /// A run continued under the session's id starts without the earlier
    /// run's effort, and a late report of that run doesn't reach the new one.
    @Test func aLaterRunStartsWithoutTheEarlierRunsEffort() {
        var s = state([.sessionStarted(cwd: "/p", pid: 1), .promptSubmitted("go")])
        s.apply(reported(high, at: 2))
        s.apply(event(.sessionEnded, at: 3))
        s.apply(event(.sessionStarted(cwd: "/p", pid: 2), at: 20))
        #expect(s.sessions[key]!.effort == nil)
        s.apply(reported(max, at: 10))
        #expect(s.sessions[key]!.effort == nil)
        s.apply(reported(max, at: 20))
        #expect(s.sessions[key]!.effort == EffortLevel(step: 5, name: "max"))
    }

    @Test(arguments: [0, 6, -1])
    func aStepOutsideTheScaleIsNoLevel(step: Int) {
        #expect(EffortLevel(step: step, name: "high") == nil)
    }

    @Test(arguments: [1, 5])
    func aStepOnTheScaleIsALevel(step: Int) {
        let level = EffortLevel(step: step, name: "high")
        #expect(level?.step == step)
        #expect(level?.name == "high")
    }
}
