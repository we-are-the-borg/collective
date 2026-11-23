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
    _ state: CollectiveState,
    at seconds: TimeInterval = 1_000,
    settings: PopoverSettings = PopoverSettings()
) -> PopoverModel {
    PopoverModel(state: state, now: t0.addingTimeInterval(seconds), settings: settings)
}

private func spawn(_ id: String, parent: AgentRef = .root, type: String = "explore", title: String? = nil, background: Bool? = nil) -> AgentEvent.Kind {
    .agentSpawned(id: id, parent: parent, spec: AgentSpec(type: type, title: title ?? id.uppercased(), isBackground: background))
}

/// A kit text as an English user reads it, resolved from the kit's catalog.
private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

/// Line parts the view joins, written with its separator for readability.
private func en(_ parts: [LocalizedStringResource]) -> String {
    parts.map(en).joined(separator: " | ")
}

private extension ActivityLine {
    /// The English text of a "No activity" line at `seconds` after `t0`, nil
    /// for any other case.
    func noActivityText(at seconds: TimeInterval) -> String? {
        if case let .noActivity(since) = self {
            en(ActivityLine.noActivityText(since: since, at: t0.addingTimeInterval(seconds)))
        } else {
            nil
        }
    }
}

@Suite struct PopoverModelTests {
    // MARK: Mock scenarios

    @Test func empty() {
        let m = model(CollectiveState())
        #expect(m.tabs.map(\.count) == [0, 0, 0])
        #expect(m.content == .dormant)
        #expect(m.sessions.isEmpty)
        #expect(m.finished.isEmpty)
    }

    @Test func single() throws {
        let m = model(state(session("s1", [
            .sessionStarted(cwd: "/Users/user/projects/collective", pid: 1),
            .promptSubmitted("Fix the build"),
            .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "swift test")),
        ])))
        #expect(m.tabs[0].count == 1)
        #expect(m.sessions.map(\.rowStatus) == [.working])

        let item = try #require(m.sessions.first)
        #expect(item.key == key("s1"))
        #expect(item.name == "collective")
        #expect(item.state == .working)
        #expect(item.prompt == "Fix the build")
        #expect(item.activity == .tool(ToolActivity(name: "Bash", detail: "swift test")))
        #expect(item.startedAt == t0)
        #expect(item.lastActivity == t0.addingTimeInterval(2))
        #expect(item.endedAt == nil)
        #expect(item.state != .waiting)
        #expect(item.summary.subagentCount == 0)
    }

    /// A session started ahead of time that waits for work is none the user
    /// started: no row, nothing counted, also once presumed dead.
    @Test(arguments: [false, true])
    func aStandbySessionIsNotListed(stale: Bool) {
        var s = state(
            session("standby", [.sessionStarted(cwd: "/Users/user/projects/spare", pid: 1)]),
            session("s2", start: 5, [.sessionStarted(cwd: "/Users/user/projects/collective", pid: 2), .promptSubmitted("Fix the build")])
        )
        s.apply(AgentEvent(session: key("standby"), timestamp: t0.addingTimeInterval(0.5), kind: .activityReported(.standby), pid: 1))
        s.apply(AgentEvent(session: key("standby"), timestamp: t0.addingTimeInterval(1), kind: .promptSubmitted("go"), pid: 1))
        if stale {
            s.markStale(now: t0.addingTimeInterval(100), silenceTimeout: 60, waitingTimeout: 60) { $0 == 2 ? t0 : nil }
        }
        let m = model(s, at: 120)
        #expect(m.sessions.map(\.key) == [key("s2")])
        #expect(m.finished.isEmpty)
        #expect(m.tabs.map(\.count) == [1, 0, 0])
        #expect(m.sessions.map(\.rowStatus) == [.working])
    }

    /// Ended without ever being given work: not finished work of the user's either.
    @Test func anEndedStandbySessionIsNotFinished() {
        var s = state(session("standby", [.sessionStarted(cwd: "/Users/user/projects/spare", pid: 1)]))
        s.apply(AgentEvent(session: key("standby"), timestamp: t0.addingTimeInterval(0.5), kind: .activityReported(.standby), pid: 1))
        s.apply(AgentEvent(session: key("standby"), timestamp: t0.addingTimeInterval(1), kind: .sessionEnded, pid: 1))
        let m = model(s, at: 120)
        #expect(m.sessions.isEmpty)
        #expect(m.finished.isEmpty)
        #expect(m.tabs.map(\.count) == [0, 0, 0])
    }

    @Test func five() throws {
        let m = model(state(session("s1", [
            .promptSubmitted("Review everything"),
            spawn("a", title: "Check docs"),
            spawn("b"), spawn("c"), spawn("d"), spawn("e"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(prompt: "Read docs/", isBackground: false)),
            .toolStarted(agent: .subagent("a"), ToolActivity(name: "Read", detail: "docs/a.md")),
        ])))
        #expect(m.sessions.map(\.rowStatus) == [.working])

        let item = try #require(m.sessions.first)
        // The detail is the orchestrator's own; the toggle line counts the subagents.
        #expect(item.activity == .noActivity(since: t0))
        #expect(item.subagentToggle?.parts.map { en($0.text) } == ["5 working"])
        #expect(item.summary.subagentCount == 5)
        #expect(item.summary.workingCount == 5)
    }

    @Test func nested() throws {
        let m = model(state(session("s1", [
            .promptSubmitted("Plan and build"),
            spawn("planner", type: "plan"),
            spawn("x", parent: .subagent("planner")),
            spawn("y", parent: .subagent("planner")),
            spawn("builder", type: "build"),
            .toolStarted(agent: .subagent("builder"), ToolActivity(name: "Edit", detail: "main.swift")),
            .agentFinished(id: "y"),
        ])))
        let item = try #require(m.sessions.first)
        #expect(item.summary.subagentCount == 4)
        #expect(item.summary.workingCount == 3)
        #expect(item.summary.doneCount == 1)
        // Working ones at every depth count; the finished one doesn't.
        #expect(item.subagentToggle?.parts.map { en($0.text) } == ["3 working", "1 done"])
    }

    // MARK: Nesting

    @Test func unassigned() throws {
        let m = model(state(session("s1", [
            .promptSubmitted("Go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(type: "general-purpose")),
            .agentSpawned(id: "b", parent: .root, spec: AgentSpec(type: "general-purpose")),
            .agentFinished(id: "b"),
        ])))
        let item = try #require(m.sessions.first)
        // The one without a title yet is still running, so it counts.
        #expect(item.summary.workingCount == 1)
        #expect(item.summary.doneCount == 1)
        #expect(m.sessions.map(\.rowStatus) == [.working])
    }

    @Test func staleSubagentWithoutTitleStaysStale() throws {
        var s = state(session("s1", [
            .sessionStarted(cwd: "/p", pid: 7),
            .promptSubmitted("Go"),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(type: "general-purpose")),
        ]))
        s.markStale(now: t0.addingTimeInterval(10), silenceTimeout: 60, waitingTimeout: 60, processStart: { _ in nil })
        let item = try #require(model(s, at: 20).finished.first)
        #expect(item.state == .stale)
        #expect(item.summary.staleCount == 1)
        #expect(item.summary.workingCount == 0)
    }

    @Test func background() throws {
        let m = model(state(session("s1", [
            .sessionStarted(cwd: "/p", pid: 1),
            .promptSubmitted("Start a background check"),
            spawn("bg", title: "Watch tests", background: true),
            .toolStarted(agent: .subagent("bg"), ToolActivity(name: "Bash", detail: "sleep 30")),
            .turnEnded(),
        ])))
        // Background work counts the session as working.
        #expect(m.sessions.map(\.rowStatus) == [.backgroundAgents(count: 1)])
        #expect(m.tabs[0].count == 1)

        let item = try #require(m.sessions.first)
        #expect(item.state == .backgroundWorking)
        #expect(item.activity == nil)
        #expect(item.state != .waiting)
        #expect(item.summary.workingCount == 1)
        #expect(item.backgroundWorkingCount == 1)
    }

    /// Whom it waits on is for the subagent rows (`aRowCountsOnlyItsForegroundSubagents`).
    @Test func aWorkingOrchestratorWithBackgroundSubagentsShowsItsOwnLine() throws {
        let m = model(state(session("s1", [
            .promptSubmitted("Go"),
            spawn("bg", background: true),
            spawn("fg", background: false),
            spawn("deep", parent: .subagent("fg"), background: true),
        ])))
        let item = try #require(m.sessions.first)
        #expect(item.activity == .noActivity(since: t0))
        // Only a waiting orchestrator gets the waiting line.
        #expect(item.state != .waiting)
    }

    @Test func aWaitingSessionCountsItsWorkingSubagentsAtEveryDepth() throws {
        let m = model(state(session("s1", [
            .promptSubmitted("Go"),
            spawn("bg", background: true),
            spawn("deep", parent: .subagent("bg"), background: true),
            spawn("fg", parent: .subagent("bg"), background: false),
            spawn("done", background: true),
            .agentFinished(id: "done"),
            .turnEnded(),
        ])))
        let item = try #require(m.sessions.first)
        #expect(item.state == .backgroundWorking)
        // The status word counts the background pair only, the nested one included.
        #expect(item.backgroundWorkingCount == 2)
        #expect(item.rowStatus == .backgroundAgents(count: 2))
        // The background pair and the foreground one below it; the finished one is done.
        #expect(item.summary.workingCount == 3)
        #expect(item.summary.doneCount == 1)
    }

    @Test func aWaitingSessionWithoutBackgroundWorkStillGetsItsWaitingLine() throws {
        let m = model(state(session("s1", [.promptSubmitted("Go"), spawn("a"), .agentFinished(id: "a"), .turnEnded()])), settings: PopoverSettings(idleAfter: .never))
        let item = try #require(m.sessions.first)
        #expect(item.state == .waiting)
        #expect(item.summary.workingCount == 0)
    }

    @Test func finishedSessionsHaveNoWaitingLine() throws {
        let m = model(state(session("s1", [.promptSubmitted("Go"), .turnEnded(), .sessionEnded])), at: 10)
        #expect(try #require(m.finished.first).state != .waiting)
    }

    // MARK: Card title

    @Test func theToolsNameWinsOverTheFolder() throws {
        let m = model(state(session("s1", [.sessionStarted(cwd: "/a/collective", pid: 1), .sessionNamed("agent-collective-01")])), settings: PopoverSettings(idleAfter: .never))
        #expect(try #require(m.sessions.first).name == "agent-collective-01")
    }

    @Test func withoutANameTheFolderTitlesTheCard() throws {
        let m = model(state(session("s1", [.sessionStarted(cwd: "/a/collective", pid: 1), .promptSubmitted("Go")])))
        #expect(try #require(m.sessions.first).name == "collective")
    }

    @Test func withoutNameAndFolderTheFirstEightCharactersOfTheIDTitleTheCard() throws {
        let m = model(state(
            session("5e1f9a2c-7b3d-4c5e-9a1b-0123456789ab", [.promptSubmitted("Go")]),
            session("short", [.promptSubmitted("Go")])
        ))
        #expect(Set(m.sessions.map(\.name)) == ["5e1f9a2c", "short"])
    }

    @Test func theArchivedRowNamesTheSessionLikeItsTitle() throws {
        var s = state(session("5e1f9a2c-7b3d", [.promptSubmitted("Go"), .turnEnded(), .sessionEnded]))
        s.apply(AgentEvent(session: key("named"), timestamp: t0, kind: .promptSubmitted("Go")))
        s.apply(AgentEvent(session: key("named"), timestamp: t0, kind: .sessionNamed("agent-collective-01")))
        s.apply(AgentEvent(session: key("named"), timestamp: t0, kind: .sessionEnded))
        var undo = ArchiveUndo()
        _ = undo.archive(.finishedSession(key("5e1f9a2c-7b3d")), in: &s, at: t0.addingTimeInterval(50))
        _ = undo.archive(.finishedSession(key("named")), in: &s, at: t0.addingTimeInterval(50))
        let m = PopoverModel(state: s, now: t0.addingTimeInterval(52), settings: PopoverSettings(), undo: undo)
        let texts = Dictionary(uniqueKeysWithValues: (m.sessions + m.finished).compactMap { item in
            item.undo.map { (item.key.sessionID, en($0.text)) }
        })
        #expect(texts == ["5e1f9a2c-7b3d": "5e1f9a2c archived", "named": "agent-collective-01 archived"])
    }

    // MARK: Order and counts

    @Test func activeSessionsOrderByLastPromptWhateverTheirState() {
        let m = model(state(
            session("waitingOld", start: 0, [.sessionStarted(cwd: "/a/one", pid: 1), .promptSubmitted("x"), .turnEnded()]),
            session("workingOld", start: 10, [.sessionStarted(cwd: "/a/two", pid: 2), .promptSubmitted("x")]),
            session("waitingNew", start: 20, [.sessionStarted(cwd: "/a/one", pid: 3), .promptSubmitted("x"), .turnEnded()]),
            session("workingNew", start: 30, [.promptSubmitted("x")]),
            session("ended", start: 40, [.promptSubmitted("x"), .sessionEnded])
        ), settings: PopoverSettings(idleAfter: .never))
        // Waiting long enough to go idle doesn't matter here (PopoverModelIdleTests).
        // Prompts at 1 s, 11 s, 21 s and 30 s: working and waiting sessions share one list.
        #expect(m.sessions.map(\.key) == ["workingNew", "waitingNew", "workingOld", "waitingOld"].map(key))
        #expect(m.sessions.map(\.state) == [.working, .waiting, .working, .waiting])
        #expect(m.tabs[0].count == 4)
        #expect(m.needYouCount == 2)
        #expect(m.sessions.map(\.name) == ["workingN", "one", "two", "one"])
    }

    /// Everything but a prompt happens to the lower session; it stays put until the user prompts it.
    @Test func onlyAPromptMovesASessionUp() {
        let upper = session("upper", start: 100, [.promptSubmitted("x")])
        let lower = session("lower", start: 0, [.promptSubmitted("x")])
        let later: [(String, [AgentEvent.Kind])] = [
            ("a tool start", [.toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "ls"))]),
            ("a tool end", [.toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "ls")), .toolFinished(agent: .root)]),
            ("the end of the turn", [.turnEnded()]),
            ("a working report", [.activityReported(.working)]),
            ("an idle report", [.activityReported(.idle)]),
            ("a spawned agent", [spawn("a", background: true)]),
            ("a hand-back", [spawn("a", background: true), .turnEnded(), .turnStarted, .agentFinished(id: "a")]),
        ]
        for (name, kinds) in later {
            let m = model(state(upper, lower, session("lower", start: 200, kinds)), at: 300)
            #expect(m.sessions.map(\.key) == [key("upper"), key("lower")], "after \(name)")
        }

        let prompted = model(state(upper, lower, session("lower", start: 200, [.promptSubmitted("again")])), at: 300)
        #expect(prompted.sessions.map(\.key) == [key("lower"), key("upper")])
    }

    @Test func aSessionWithoutAPromptSortsByItsStart() {
        let m = model(state(
            session("old", start: 10, [.promptSubmitted("x")]),
            session("fresh", start: 50, [.sessionStarted(cwd: nil, pid: 1)]),
            session("newest", start: 100, [.promptSubmitted("x")]),
            session("ancient", start: 0, [.sessionStarted(cwd: nil, pid: 2)])
        ), at: 200)
        #expect(m.sessions.map(\.key) == ["newest", "fresh", "old", "ancient"].map(key))
    }

    @Test func theSummaryCountsNestedSubagentsDepthFirst() throws {
        // a ─ a1 (done);  b, with a still waiting on a1's sibling a2.
        let m = model(state(session("s1", [
            .promptSubmitted("x"),
            spawn("a"),
            spawn("a1", parent: .subagent("a")),
            spawn("a2", parent: .subagent("a")),
            spawn("b"),
            .agentFinished(id: "a1"),
        ])))
        let summary = try #require(m.sessions.first).summary
        #expect(summary.subagentCount == 4)
        #expect(summary.workingCount == 3)
        #expect(summary.doneCount == 1)
    }

    /// `impl` with 15 children; the first 13 finish, the last 2 keep working.
    @Test func theSummaryCountsFinishedSubagents() throws {
        let impl = AgentRef.subagent("impl")
        let spawns = [spawn("impl")] + (1...15).map { spawn("a\($0)", parent: impl) }
        let finishes = (1...13).map { AgentEvent.Kind.agentFinished(id: "a\($0)") }
        let s = state(session("s1", [.promptSubmitted("Two tickets")] + spawns + finishes))
        let summary = try #require(model(s).sessions.first).summary
        #expect(summary.subagentCount == 16)
        #expect(summary.workingCount == 3)
    }

    // MARK: The subagent summary line

    /// w1 ─ c (working);  d1, d2 (done);  w2;  d3 ─ x (done), all below the orchestrator.
    private func mixedFirstLevel() -> CollectiveState {
        state(session("s1", [
            .promptSubmitted("Go"), spawn("w1"), spawn("c", parent: .subagent("w1")), spawn("d1"), spawn("d2"), spawn("w2"),
            spawn("d3"), spawn("x", parent: .subagent("d3")),
            .agentFinished(id: "x"), .agentFinished(id: "d1"), .agentFinished(id: "d2"), .agentFinished(id: "d3"),
        ]))
    }

    @Test func theSummaryCountsEverySubagentAtAnyDepth() throws {
        let item = try #require(model(mixedFirstLevel()).sessions.first)
        let header = SubagentsHeader(summary: item.summary)
        #expect(item.summary.subagentCount == 7)
        #expect(header.statusParts.map(en) == ["3 working", "4 done"])
    }

    @Test func theSummaryLeavesOutZeroCountsAndCountsArchivedOnlyAsArchived() throws {
        // a ─ a1 (archived while working);  u (unassigned);  b (done, archived);  c (done)
        var s = state(session("s1", [
            .promptSubmitted("Go"), spawn("a"), spawn("a1", parent: .subagent("a")),
            .agentSpawned(id: "u", parent: .root, spec: AgentSpec()),
            spawn("b"), spawn("c"), .agentFinished(id: "b"), .agentFinished(id: "c"),
        ]))
        s.archive(.agent(key("s1"), .subagent("a1")), at: t0.addingTimeInterval(20))
        s.archive(.agent(key("s1"), .subagent("b")), at: t0.addingTimeInterval(20))
        let item = try #require(model(s).sessions.first)
        let header = SubagentsHeader(summary: item.summary)
        #expect(item.summary.subagentCount == 5)
        #expect(header.statusParts.map(en) == ["1 working", "1 waiting for a type", "1 done", "2 archived"])

        let quiet = state(session("s1", [.promptSubmitted("Go"), spawn("a"), .agentFinished(id: "a")]))
        let quietItem = try #require(model(quiet).sessions.first)
        let single = SubagentsHeader(summary: quietItem.summary)
        #expect(quietItem.summary.subagentCount == 1)
        #expect(single.statusParts.map(en) == ["1 done"])
    }

    @Test func theSummaryHasNoStatusWithoutSubagents() throws {
        let item = try #require(model(state(session("s1", [.promptSubmitted("Alone")]))).sessions.first)
        let header = SubagentsHeader(summary: item.summary)
        #expect(item.summary.subagentCount == 0)
        #expect(header.statusParts.isEmpty)
    }

    @Test func theSummaryCountsLostContact() throws {
        var s = state(session("s1", [.sessionStarted(cwd: "/p", pid: 7), .promptSubmitted("Go"), spawn("a"), spawn("b"), .agentFinished(id: "a")]))
        s.markStale(now: t0.addingTimeInterval(30), silenceTimeout: 20, waitingTimeout: 20, processStart: { _ in nil })
        let header = SubagentsHeader(summary: try #require(model(s, at: 40).finished.first).summary)
        #expect(header.statusParts.map(en) == ["1 done", "1 lost contact"])
    }

    // MARK: Prompts and activity

    @Test func aPromptIsTrimmedOfSurroundingWhitespaceAndKeepsInnerNewlines() throws {
        func prompt(_ text: String) throws -> String? {
            try #require(model(state(session("s1", [.promptSubmitted(text)]))).sessions.first).prompt
        }
        #expect(try prompt("\n# Files mentioned by the user:\n\nhello \n") == "# Files mentioned by the user:\n\nhello")
        #expect(try prompt("  \n\t Fix it") == "Fix it")
        #expect(try prompt(" \n ") == nil)
    }

    @Test func theActivityFollowsTheLatestToolCall() throws {
        let s = state(session("s1", [
            .promptSubmitted("x"),
            spawn("a", background: true),
            .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "swift test")),
            .toolFinished(agent: .root),
            .toolStarted(agent: .root, ToolActivity(name: "Edit", detail: "main.swift")),
            .toolStarted(agent: .subagent("a"), ToolActivity(name: "Grep", detail: "TODO")),
            .toolFinished(agent: .subagent("a")),
            .toolStarted(agent: .subagent("a"), ToolActivity(name: "Read", detail: "Package.swift")),
        ]))
        let item = try #require(model(s).sessions.first)
        #expect(item.activity == .tool(ToolActivity(name: "Edit", detail: "main.swift")))
    }

    // MARK: Ties

    /// Events at one identical timestamp, so only the tiebreak decides the order.
    private func tied(_ source: SourceID, _ id: String, _ kinds: [AgentEvent.Kind]) -> [AgentEvent] {
        kinds.map { AgentEvent(session: SessionKey(source: source, sessionID: id), timestamp: t0, kind: $0) }
    }

    @Test func activeTiesOrderBySourceThenSessionID() {
        let sessions: [(SourceID, String)] = [("b-tool", "2"), ("a-tool", "9"), ("b-tool", "1"), ("a-tool", "3"), ("c-tool", "0")]
        let expected = ["a-tool/3", "a-tool/9", "b-tool/1", "b-tool/2", "c-tool/0"]
        for order in [sessions, sessions.reversed(), Array(sessions[2...] + sessions[..<2])] {
            var state = CollectiveState()
            for (source, id) in order {
                for event in tied(source, id, [.sessionStarted(cwd: nil, pid: nil), .promptSubmitted("p")]) { state.apply(event) }
            }
            let m = model(state)
            #expect(m.sessions.map { "\($0.key.source.rawValue)/\($0.key.sessionID)" } == expected)
        }
    }

    @Test func finishedTiesOrderBySourceThenSessionID() {
        let sessions: [(SourceID, String)] = [("b-tool", "2"), ("a-tool", "9"), ("b-tool", "1"), ("a-tool", "3")]
        let expected = ["a-tool/3", "a-tool/9", "b-tool/1", "b-tool/2"]
        for order in [sessions, sessions.reversed()] {
            var state = CollectiveState()
            for (source, id) in order {
                for event in tied(source, id, [.sessionStarted(cwd: nil, pid: nil), .sessionEnded]) { state.apply(event) }
            }
            let m = model(state, at: 10)
            #expect(m.finished.map { "\($0.key.source.rawValue)/\($0.key.sessionID)" } == expected)
        }
    }

    // MARK: Finished

    @Test func finished() throws {
        // `ended` ends at 2 s, `crashed` is marked stale at 50 s.
        var s = state(
            session("ended", start: 0, [.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("x"), .sessionEnded]),
            session("crashed", start: 10, [.sessionStarted(cwd: "/q", pid: 9), .promptSubmitted("x")]),
            session("live", start: 20, [.promptSubmitted("x")])
        )
        s.markStale(now: t0.addingTimeInterval(50), silenceTimeout: 3_600, waitingTimeout: 3_600, processStart: { $0 == 9 ? nil : t0 })

        let m = model(s, at: 100)
        #expect(m.sessions.map(\.key) == [key("live")])
        #expect(m.finished.map(\.key) == [key("crashed"), key("ended")])
        #expect(m.finished.map(\.state) == [.stale, .done])
        #expect(m.finished[1].endedAt == t0.addingTimeInterval(2))
        #expect(m.finishedRetention == .tenMinutes)
        // Finished sessions count on their own tab only.
        #expect(m.tabs.map(\.count) == [1, 0, 2])
        #expect(m.sessions.map(\.rowStatus) == [.working])
    }

    @Test(arguments: FinishedRetention.allCases)
    func finishedSessionsAreClearedAfterTheRetention(_ retention: FinishedRetention) {
        let s = state(session("ended", [.promptSubmitted("x"), .sessionEnded])) // ends at 1 s
        let settings = PopoverSettings(finishedRetention: retention)
        let endedAt: TimeInterval = 1

        #expect(model(s, at: endedAt + retention.interval, settings: settings).finished.count == 1)
        #expect(model(s, at: endedAt + retention.interval + 1, settings: settings).finished.isEmpty)
        #expect(model(s, settings: settings).finishedRetention == retention)
    }

    // MARK: Background agents working

    @Test func aRestingOrchestratorWithAWorkingBackgroundAgentShowsBackgroundWorking() throws {
        let s = state(session("s1", [.promptSubmitted("go"), spawn("a", background: true), .turnEnded()]))
        let item = try #require(model(s, at: 10).sessions.first)
        #expect(item.state == .backgroundWorking)
        #expect(item.state != .waiting)
        #expect(item.backgroundWorkingCount == 1)
        #expect(item.rowStatus == .backgroundAgents(count: 1))
    }

    @Test func theCardWaitsForYouOnceNoBackgroundAgentWorks() throws {
        let start: [AgentEvent.Kind] = [.promptSubmitted("go"), spawn("a", background: true), .turnEnded()]
        func expectWaiting(_ s: CollectiveState, _ comment: Comment) throws {
            let item = try #require(model(s, at: 10).sessions.first)
            #expect(item.state == .waiting, comment)
            #expect(item.backgroundWorkingCount == 0, comment)
            #expect(item.rowStatus == .waitingForYou, comment)
        }

        try expectWaiting(state(session("s1", start + [.agentFinished(id: "a")])), "last background agent done")

        var archived = state(session("s1", start))
        archived.archive(.agent(key("s1"), .subagent("a")), at: t0.addingTimeInterval(5))
        try expectWaiting(archived, "last background agent archived")

        let notBackground = state(session("s1", [
            .promptSubmitted("go"), spawn("fg", background: false), spawn("unknown", background: nil), .turnEnded(),
        ]))
        try expectWaiting(notBackground, "only agents not known to run in the background work")
    }

    @Test func aRunningTurnWinsOverBackgroundWork() throws {
        let s = state(session("s1", [.promptSubmitted("go"), spawn("a", background: true), spawn("b", background: true)]))
        let item = try #require(model(s, at: 10).sessions.first)
        #expect(item.state == .working)
        #expect(item.backgroundWorkingCount == 2)
        #expect(item.rowStatus == .working)
        #expect(item.state != .waiting)
    }

    @Test func backgroundWorkSortsByPromptLikeAnyActiveSession() {
        // `waiting` has the newest prompt, yet only rests; `bg` and `busy` work.
        let s = state(
            session("bg", start: 0, [.promptSubmitted("x"), spawn("a", background: true), .turnEnded()]),
            session("busy", start: 10, [.promptSubmitted("x")]),
            session("waiting", start: 20, [.promptSubmitted("x"), .turnEnded()])
        )
        let m = model(s, at: 30)
        #expect(m.sessions.map(\.key) == [key("waiting"), key("busy"), key("bg")])
        #expect(m.sessions.map(\.state) == [.waiting, .working, .backgroundWorking])
        // The background agent's session and `busy` work; the resting orchestrator needs you.
        #expect(m.sessions.map(\.rowStatus) == [.waitingForYou, .working, .backgroundAgents(count: 1)])
        #expect(m.needYouCount == 1)
        #expect(m.tabs[0].count == 3)
    }

    // MARK: Captured run

    @Test func capturedBackgroundRunWhileTheOrchestratorWaits() throws {
        var state = CollectiveState()
        let adapter = Run.background.adapter()
        var replayed = 0
        func replay(through count: Int) throws {
            for (index, payload) in Run.background.payloads.enumerated().prefix(count).dropFirst(replayed) {
                let envelope = Envelope(source: "claude-code", pid: 4242, payload: payload, receivedAt: t0.addingTimeInterval(TimeInterval(index)))
                for event in try adapter.events(from: envelope) { state.apply(event) }
            }
            replayed = count
        }

        // Up to and including 014-Stop: the turn is over, both background subagents still run.
        try replay(through: 14)
        let m = model(state, at: 20)

        // The orchestrator rests: its background subagents make the session count as working.
        #expect(m.sessions.map(\.rowStatus) == [.backgroundAgents(count: 2)])
        #expect(m.needYouCount == 0)
        #expect(m.tabs[0].count == 1)

        let item = try #require(m.sessions.first)
        #expect(item.name == "hook-capture")
        #expect(item.state == .backgroundWorking)
        #expect(item.activity == nil)
        #expect(item.state != .waiting)
        #expect(item.backgroundWorkingCount == 2)
        #expect(item.rowStatus == .backgroundAgents(count: 2))
        #expect(item.summary.workingCount == 2)
        #expect(item.prompt?.hasPrefix("Start exactly two general-purpose subagents") == true)

        // 020-SubagentStop: the sleep agent is done, the README agent still reads.
        try replay(through: 20)
        let afterFirstStop = try #require(model(state, at: 30).sessions.first)
        #expect(afterFirstStop.state == .backgroundWorking)
        #expect(afterFirstStop.backgroundWorkingCount == 1)
        #expect(afterFirstStop.rowStatus == .backgroundAgents(count: 1))
        #expect(afterFirstStop.summary.workingCount == 1)
        #expect(afterFirstStop.summary.doneCount == 1)

        // 021-UserPromptSubmit hands the result back: the orchestrator's turn runs again.
        try replay(through: 21)
        let handedBack = model(state, at: 30)
        let woken = try #require(handedBack.sessions.first)
        #expect(woken.state == .working)
        #expect(woken.rowStatus == .working)
        #expect(woken.backgroundWorkingCount == 1)

        // 022-Stop ends that turn again while the README agent still reads.
        try replay(through: 22)
        let rested = try #require(model(state, at: 40).sessions.first)
        #expect(rested.state == .backgroundWorking)
        #expect(rested.state != .waiting)
        #expect(rested.backgroundWorkingCount == 1)
        #expect(rested.rowStatus == .backgroundAgents(count: 1))

        // 023-SubagentStop: the last background agent is done, the orchestrator waits for you.
        try replay(through: 23)
        let finished = try #require(model(state, at: 50).sessions.first)
        #expect(finished.state == .waiting)
        #expect(finished.backgroundWorkingCount == 0)
        #expect(finished.rowStatus == .waitingForYou)
    }

    // MARK: Background shell

    @Test func aBackgroundShellAfterTheTurnIsNoWorkAndNoCallToAct() throws {
        let m = model(state(session("s1", [
            .sessionStarted(cwd: "/p", pid: 1),
            .promptSubmitted("Start a server in the background"),
            .turnEnded(),
            .activityReported(.backgroundShell),
        ])), at: 20 * 60)
        #expect(m.sessions.map(\.rowStatus) == [.shellRunning(several: false)])
        #expect(m.needYouCount == 0)
        #expect(m.tabs[0].count == 1)

        let item = try #require(m.sessions.first)
        #expect(item.state == .backgroundShell)
        #expect(item.state != .waiting)
        #expect(item.rowStatus == .shellRunning(several: false))
        // Long quiet: still no "No activity for …", nothing is meant to work.
        #expect(item.activity == nil)
        let shell = try #require(item.shellPill)
        #expect(en(try #require(item.statusAccessibilityText)) == "shell running")
        // Nothing listed: nothing to say beyond the text.
        #expect(shell.tooltip == nil)
    }

    @Test func aNewerIdleReportEndsTheShell() throws {
        let item = try #require(model(state(session("s1", [
            .promptSubmitted("Go"),
            .turnEnded(),
            .activityReported(.backgroundShell),
            .activityReported(.idle),
        ])), settings: PopoverSettings(idleAfter: .never)).sessions.first)
        #expect(item.state == .waiting)
        #expect(item.rowStatus == .waitingForYou)
        #expect(item.shellPill == nil)
    }

    @Test func workingBackgroundAgentsTakePrecedenceOverTheShell() throws {
        let m = model(state(session("s1", [
            .promptSubmitted("Go"),
            spawn("bg", background: true),
            .turnEnded(),
            .activityReported(.backgroundShell),
        ])))
        #expect(m.sessions.map(\.rowStatus) == [.backgroundAgents(count: 1)])

        let item = try #require(m.sessions.first)
        #expect(item.state == .backgroundWorking)
        #expect(item.rowStatus == .backgroundAgents(count: 1))
        #expect(item.shellPill != nil)
        #expect(item.summary.workingCount == 1)
    }

    /// The shell outlives the turn into the next one, until a report says otherwise.
    @Test func aNewTurnWorksAndKeepsTheShellPill() throws {
        let m = model(state(session("s1", [
            .promptSubmitted("Go"),
            .turnEnded(),
            .activityReported(.backgroundShell),
            .promptSubmitted("And now?"),
        ])))
        #expect(m.sessions.map(\.rowStatus) == [.working])

        let item = try #require(m.sessions.first)
        #expect(item.state == .working)
        #expect(item.rowStatus == .working)
        #expect(item.shellPill != nil)
    }

    @Test func aFinishedSessionHasNoShellPill() throws {
        let m = model(state(session("s1", [
            .promptSubmitted("Go"),
            .turnEnded(),
            .activityReported(.backgroundShell),
            .sessionEnded,
        ])), at: 10)
        #expect(m.sessions.isEmpty)
        let item = try #require(m.finished.first)
        #expect(item.shellPill == nil)
    }

    // MARK: Source names

    @Test func sessionsShowTheirSourceName() throws {
        let other = SessionKey(source: "other-tool", sessionID: "o1")
        let s = state(
            session("s1", start: 0, [.promptSubmitted("x")]),
            [AgentEvent(session: other, timestamp: t0.addingTimeInterval(10), kind: .promptSubmitted("y"))]
        )
        let m = PopoverModel(state: s, now: t0.addingTimeInterval(20), settings: PopoverSettings(), sourceNames: [source: "Test Tool"])
        #expect(m.sessions.map(\.sourceName) == ["other-tool", "Test Tool"])
    }

    @Test func finishedRowsShowTheirSourceName() throws {
        let s = state(session("s1", [.promptSubmitted("x"), .sessionEnded]))
        let m = PopoverModel(state: s, now: t0.addingTimeInterval(20), settings: PopoverSettings(), sourceNames: [source: "Test Tool"])
        #expect(try #require(m.finished.first).sourceName == "Test Tool")
    }

    @Test func claudeCodeSourcesNameThemselves() {
        #expect(ClaudeCodeAdapter().displayName == "Claude Code")
        #expect(ClaudeCodeSessionStatusSource().displayName == "Claude Code")
    }

    // MARK: Activity line

    @Test func aWorkingAgentThinksBeforeItsFirstTool() throws {
        let s = state(session("s1", [.promptSubmitted("go"), spawn("a")]))
        let item = try #require(model(s, at: 10).sessions.first)
        #expect(item.activity == .thinking)

        let alone = state(session("s2", [.promptSubmitted("go")]))
        #expect(try #require(model(alone, at: 10).sessions.first).activity == .thinking)
    }

    @Test func aFinishedToolStaysForItsMinimumTime() throws {
        let s = state(
            session("s1", [.promptSubmitted("go")]),
            session("s1", start: 10, [.toolStarted(agent: .root, ToolActivity(name: "Read", detail: "a.md"))]),
            session("s1", start: 10.5, [.toolFinished(agent: .root)]),
        )
        #expect(ActivityLine.minimumToolDisplay == 1)
        #expect(try #require(model(s, at: 10.9).sessions.first).activity == .tool(ToolActivity(name: "Read", detail: "a.md")))
        #expect(try #require(model(s, at: 11).sessions.first).activity == .thinking)
    }

    @Test func silenceTurnsThinkingIntoNoActivity() throws {
        let s = state(session("s1", [.promptSubmitted("go")]))
        #expect(ActivityLine.quietThreshold == 60)
        #expect(try #require(model(s, at: 59).sessions.first).activity == .thinking)
        let quiet = try #require(model(s, at: 60).sessions.first).activity
        #expect(quiet?.noActivityText(at: 60) == "No activity for 1 min")
    }

    @Test func aRunningToolStaysThroughAnySilence() throws {
        let s = state(session("s1", [.promptSubmitted("go"), .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "sleep 300"))]))
        #expect(try #require(model(s, at: 200).sessions.first).activity == .tool(ToolActivity(name: "Bash", detail: "sleep 300")))
    }

    /// The toggle line says the subagents work; the detail says the orchestrator is quiet.
    @Test func workingChildrenNoLongerHideTheOrchestratorsSilence() throws {
        let s = state(session("s1", [.promptSubmitted("go"), spawn("a")]))
        let item = try #require(model(s, at: 200).sessions.first)
        #expect(item.activity == .noActivity(since: t0))
        #expect(item.subagentToggle?.parts.map { en($0.text) } == ["1 working"])
    }

    @Test func onlyWorkingAgentsHaveAnActivity() throws {
        let waiting = state(session("s1", [.promptSubmitted("go"), .toolStarted(agent: .root, ToolActivity(name: "Bash")), .turnEnded()]))
        #expect(try #require(model(waiting, at: 3.5).sessions.first).activity == nil)

        var archived = state(session("s1", [.promptSubmitted("go"), spawn("a")]))
        archived.archive(.agent(key("s1"), .subagent("a")), at: t0.addingTimeInterval(5))
        let item = try #require(model(archived, at: 10).sessions.first)
        #expect(item.summary.archivedCount == 1)
        #expect(item.activity == .thinking)
    }

    // MARK: Time texts

    @Test(arguments: [
        (0.0, "0 s"), (-3, "0 s"), (5.9, "5 s"), (59, "59 s"), (60, "1 min"),
        (59 * 60 + 59, "59 min"), (60 * 60, "1 h"), (72 * 60, "1 h 12 min"), (120 * 60, "2 h"),
    ] as [(TimeInterval, String)])
    func durationText(_ seconds: TimeInterval, _ expected: String) {
        #expect(en(DurationText.format(seconds)) == expected)
    }

    /// A resting orchestrator's background subagents count its session as
    /// working, at any depth; the session counts once, whatever its subagents.
    @Test func backgroundSubagentsAtAnyDepthCountTheirSessionAsWorking() {
        let one = model(state(session("s1", [.promptSubmitted("Go"), spawn("a", background: true), .turnEnded()])))
        #expect(one.sessions.map(\.rowStatus) == [.backgroundAgents(count: 1)])

        let nested = model(state(session("s1", [
            .promptSubmitted("Go"), spawn("a", background: true), spawn("b", parent: .subagent("a"), background: true), .turnEnded(),
        ])))
        #expect(nested.sessions.map(\.rowStatus) == [.backgroundAgents(count: 2)])
        #expect(nested.sessions.first?.backgroundWorkingCount == 2)
    }

    @Test func clearedAfterLabels() {
        #expect(FinishedRetention.allCases.map { en($0.clearedAfterText) } == [
            "Cleared after 5 min", "Cleared after 10 min", "Cleared after 30 min", "Cleared after 1 h",
        ])
    }

    @Test func activeItemsShowTheirRuntime() throws {
        let m = model(state(session("s1", [.promptSubmitted("x"), spawn("a"), spawn("b"), .agentFinished(id: "a")])), at: 4_321)
        let item = try #require(m.sessions.first)
        let now = t0.addingTimeInterval(4_321)
        #expect(en(item.timeText(at: now)) == "1 h 12 min")
    }

    @Test func finishedItemsSayHowLongAgoTheyEnded() throws {
        // `ended` ends at 2 s, `crashed` is marked stale at 50 s.
        var s = state(
            session("ended", start: 0, [.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("x"), .sessionEnded]),
            session("crashed", start: 10, [.sessionStarted(cwd: "/q", pid: 9), .promptSubmitted("x")])
        )
        s.markStale(now: t0.addingTimeInterval(50), silenceTimeout: 3_600, waitingTimeout: 3_600, processStart: { _ in nil })
        #expect(model(s, at: 55).finished.map { en($0.timeText(at: t0.addingTimeInterval(55))) } == ["Lost contact 5 s ago", "Done 53 s ago"])
        #expect(model(s, at: 410).finished.map { en($0.timeText(at: t0.addingTimeInterval(410))) } == ["Lost contact 6 min ago", "Done 6 min ago"])
    }

    /// The row's head shows the state in its status word, so its time carries none.
    @Test func rowTimesLeaveTheStateToTheStatusWord() throws {
        var s = state(
            session("ended", start: 0, [.sessionStarted(cwd: "/p", pid: nil), .promptSubmitted("x"), .sessionEnded]),
            session("crashed", start: 10, [.sessionStarted(cwd: "/q", pid: 9), .promptSubmitted("x")])
        )
        s.markStale(now: t0.addingTimeInterval(50), silenceTimeout: 3_600, waitingTimeout: 3_600, processStart: { _ in nil })
        let finished = model(s, at: 410).finished
        #expect(finished.map { en($0.rowTimeText(at: t0.addingTimeInterval(410))) } == ["6 min ago", "6 min ago"])
        #expect(finished.map(\.rowTimeCountsFrom) == finished.map(\.timeCountsFrom))

        let active = try #require(model(state(session("s1", [.promptSubmitted("x"), spawn("a")])), at: 1_860).sessions.first)
        #expect(en(active.rowTimeText(at: t0.addingTimeInterval(1_860))) == "31 min")
        #expect(active.rowTimeCountsFrom == active.timeCountsFrom)
    }

    @Test func footerSaysWhenTheLastEventArrived() {
        let now = t0.addingTimeInterval(10_000)
        let working = state(session("s1", [.promptSubmitted("Go")]))
        func footer(_ lastEventAt: Date?) -> String {
            en(PopoverModel(state: working, now: now, settings: PopoverSettings(), lastEventAt: lastEventAt).footerParts(at: now))
        }
        #expect(footer(nil) == "Linked to subspace | listening")
        #expect(footer(now.addingTimeInterval(-2)) == "Linked to subspace | last event 2 s ago")
        #expect(footer(now.addingTimeInterval(-180)) == "Linked to subspace | last event 3 min ago")
        #expect(footer(now.addingTimeInterval(-3_900)) == "Linked to subspace | last event 1 h 5 min ago")
    }

    @Test func footerListensWhileNoSessionIsShown() {
        let started = state(session("s1", [.promptSubmitted("Go")]))
        let ended = state(session("s1", [.promptSubmitted("Go"), .sessionEnded]))
        func footer(_ state: CollectiveState, at seconds: TimeInterval) -> String {
            let now = t0.addingTimeInterval(seconds)
            return en(PopoverModel(state: state, now: now, settings: PopoverSettings(), lastEventAt: t0.addingTimeInterval(1)).footerParts(at: now))
        }
        #expect(footer(CollectiveState(), at: 10) == "Linked to subspace | listening")
        #expect(footer(started, at: 10) == "Linked to subspace | last event 9 s ago")
        // Finished sessions still count while they are shown, not after.
        #expect(footer(ended, at: 10) == "Linked to subspace | last event 9 s ago")
        #expect(footer(ended, at: 10 + FinishedRetention.tenMinutes.interval) == "Linked to subspace | listening")
    }

    @Test func whileTheBacklogIsReadNothingCountsAsEmpty() {
        let started = state(session("s1", [.promptSubmitted("Go")]))
        func popover(_ state: CollectiveState, isLoading: Bool, indicatorVisible: Bool = false) -> PopoverModel {
            PopoverModel(state: state, now: t0.addingTimeInterval(10), settings: PopoverSettings(),
                         lastEventAt: t0.addingTimeInterval(1), isLoading: isLoading,
                         loadingIndicatorVisible: indicatorVisible)
        }
        let loadingEmpty = popover(CollectiveState(), isLoading: true)
        #expect(loadingEmpty.isLoading)
        #expect(loadingEmpty.content == .loading(indicatorVisible: false))
        #expect(en(loadingEmpty.footerParts(at: t0.addingTimeInterval(10))) == "Linked to subspace | reading events…")
        #expect(popover(CollectiveState(), isLoading: true, indicatorVisible: true).content == .loading(indicatorVisible: true))

        // Sessions read so far show at once; the footer still says the backlog is being read.
        let loadingStarted = popover(started, isLoading: true, indicatorVisible: true)
        #expect(loadingStarted.content == .list)
        #expect(loadingStarted.sessions.map(\.rowStatus) == [.working])
        #expect(en(loadingStarted.footerParts(at: t0.addingTimeInterval(10))) == "Linked to subspace | reading events…")

        let loadedEmpty = popover(CollectiveState(), isLoading: false)
        #expect(!loadedEmpty.isLoading)
        #expect(loadedEmpty.content == .dormant)
        #expect(popover(started, isLoading: false).content == .list)
        // The indicator, once shown, stays for its minimum time even after loading ended.
        let lingering = popover(CollectiveState(), isLoading: false, indicatorVisible: true)
        #expect(lingering.content == .loading(indicatorVisible: true))
        #expect(en(lingering.footerParts(at: t0.addingTimeInterval(10))) != "Linked to subspace | reading events…")
        #expect(popover(started, isLoading: false, indicatorVisible: true).content == .list)
        // Loading is off unless the caller says otherwise.
        #expect(!PopoverModel(state: CollectiveState(), now: t0, settings: PopoverSettings()).isLoading)
    }

    @Test func retentionIntervals() {
        #expect(FinishedRetention.allCases.map(\.interval) == [300, 600, 1_800, 3_600])
        #expect(PopoverSettings().finishedRetention == .tenMinutes)
    }
}
