import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// MARK: - Helpers

private let t0 = Date(timeIntervalSince1970: 1_000)
private let source: SourceID = "claude-code"

/// Meta files by agent id; can be filled in later to simulate a file that appears late.
private final class StubMetaReader: SubagentMetaReading, @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: SubagentMeta]

    init(_ table: [String: SubagentMeta] = [:]) { self.table = table }

    func set(_ id: String, _ meta: SubagentMeta) {
        lock.withLock { table[id] = meta }
    }

    func meta(transcriptPath: String, agentID: String) -> SubagentMeta? {
        lock.withLock { table[agentID] }
    }
}

private func envelope(_ payload: Data, at index: Int = 0, pid: Int32? = 4242) -> Envelope {
    Envelope(source: source, pid: pid, payload: payload, receivedAt: t0.addingTimeInterval(TimeInterval(index)))
}

private func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

/// A synthetic hook payload of session `s1`.
private func hook(_ name: String, _ fields: [String: Any] = [:]) -> Data {
    json(["hook_event_name": name, "session_id": "s1", "transcript_path": "/t/s1.jsonl"].merging(fields) { $1 })
}

private let key = SessionKey(source: source, sessionID: "s1")

private func replay(_ payloads: [Data], with adapter: ClaudeCodeAdapter) throws -> CollectiveState {
    var state = CollectiveState()
    for (index, payload) in payloads.enumerated() {
        for event in try adapter.events(from: envelope(payload, at: index)) {
            state.apply(event)
        }
    }
    return state
}

// MARK: Fixtures

enum Run: String, CaseIterable {
    case headless = "1-headless-parallel-subagents"
    case background = "2-interactive-background-subagents-compact-exit"
    case permission = "3-interactive-permission-ctrl-c"

    var directory: URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/claude-code/2.1.285")
            .appendingPathComponent(rawValue)
    }

    /// Raw payloads in arrival order (`NNN-<hook>.json`).
    var payloads: [Data] {
        let files = try! FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("events").path)
        return files.sorted().map { try! Data(contentsOf: directory.appendingPathComponent("events/\($0)")) }
    }

    /// What the real meta reader would find on disk.
    var metas: [String: SubagentMeta] {
        let dir = directory.appendingPathComponent("subagents")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var result: [String: SubagentMeta] = [:]
        for file in files where file.hasSuffix(".meta.json") {
            let id = String(file.dropFirst("agent-".count).dropLast(".meta.json".count))
            let object = try! JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(file))) as! [String: Any]
            result[id] = SubagentMeta(
                toolUseID: object["toolUseId"] as! String,
                description: object["description"] as? String,
                isBackground: (object["requestShape"] as? String).map { $0 == "background" }
            )
        }
        return result
    }

    func adapter(withMeta: Bool = true) -> ClaudeCodeAdapter {
        ClaudeCodeAdapter(metaReader: StubMetaReader(withMeta ? metas : [:]), mapping: bundledMapping())
    }
}

/// Everything about a session that must not depend on arrival order.
private struct AgentShape: Equatable {
    var parent: AgentRef?
    var type: String?
    var title: String?
    var prompt: String?
    var isBackground: Bool?
    var modelAlias: String?
    var modelID: String?
    var status: AgentStatus
    var reply: String?
}

private func shape(_ session: Session) -> [AgentRef: AgentShape] {
    session.agents.mapValues {
        AgentShape(parent: $0.parent, type: $0.spec.type, title: $0.spec.title, prompt: $0.spec.prompt,
                   isBackground: $0.spec.isBackground, modelAlias: $0.spec.modelAlias, modelID: $0.spec.modelID,
                   status: $0.status, reply: $0.reply)
    }
}

// MARK: - Fixture runs

private extension CollectiveState {
    /// Fixture sessions carry their real ids; each run has exactly one.
    var onlySession: Session? { sessions.count == 1 ? sessions.values.first : nil }
}

@Suite struct ClaudeCodeFixtureTests {
    @Test func headlessRunWithParallelSubagents() throws {
        let state = try replay(Run.headless.payloads, with: Run.headless.adapter())
        let session = try #require(state.onlySession)

        #expect(session.pid == 4242)
        #expect(session.root.status == .done)
        #expect(session.endedAt != nil)
        #expect(state.activeAgentCount == 0)
        #expect(session.agents.count == 3)

        let subagents = session.children(of: .root)
        #expect(subagents.map(\.spec.title) == ["Run command and report output", "Read README.md and report content"])
        #expect(subagents.allSatisfy { $0.spec.type == "general-purpose" && $0.status == .done && $0.spec.isBackground == false })
        #expect(subagents[0].spec.prompt?.contains("sleep 3; echo alpha") == true)
        #expect(subagents[1].spec.prompt?.contains("README.md") == true)
    }

    @Test func parallelSubagentsOfTheSameTypeStayUnassignedUntilLinked() throws {
        // No meta files: only `tool_response.agentId` links them, and for foreground
        // subagents that arrives after they finish.
        let payloads = Run.headless.payloads
        let adapter = Run.headless.adapter(withMeta: false)

        let started = try replay(Array(payloads.prefix(8)), with: adapter) // both SubagentStarts seen
        let early = try #require(started.onlySession).children(of: .root)
        #expect(early.count == 2)
        #expect(early.allSatisfy { $0.spec.type == "general-purpose" && $0.spec.title == nil })

        let end = try replay(payloads, with: Run.headless.adapter(withMeta: false))
        let titles = try #require(end.onlySession).children(of: .root).map(\.spec.title)
        #expect(titles == ["Run command and report output", "Read README.md and report content"])
    }

    @Test func metaFileLinksSubagentsWhileTheyRun() throws {
        let started = try replay(Array(Run.headless.payloads.prefix(8)), with: Run.headless.adapter())
        let titles = try #require(started.onlySession).children(of: .root).map(\.spec.title)
        #expect(titles == ["Run command and report output", "Read README.md and report content"])
    }

    @Test func backgroundRunKeepsSubagentsWorkingAfterTheTurnEnds() throws {
        let payloads = Run.background.payloads
        // Up to and including 014-Stop: the orchestrator finished its turn.
        let state = try replay(Array(payloads.prefix(14)), with: Run.background.adapter())
        let session = try #require(state.onlySession)

        #expect(session.root.status == .waiting)
        let subagents = session.children(of: .root)
        #expect(subagents.count == 2)
        #expect(subagents.allSatisfy { $0.status == .working && $0.spec.isBackground == true && $0.spec.title != nil })
        #expect(state.activeAgentCount == 2)
        #expect(subagents.contains { $0.currentTool?.name == "Bash" })
    }

    @Test func taskNotificationWakesTheOrchestratorWithoutReplacingItsPrompt() throws {
        // Up to and including 021-UserPromptSubmit, a `<task-notification>`.
        let state = try replay(Array(Run.background.payloads.prefix(21)), with: Run.background.adapter())
        let session = try #require(state.onlySession)
        let root = session.root

        #expect(root.status == .working)
        #expect(root.spec.prompt?.hasPrefix("Start exactly two general-purpose subagents") == true)
        // The user's prompt is 005, the fifth payload; the hand-back doesn't count.
        #expect(session.lastPromptAt == t0.addingTimeInterval(4))
    }

    @Test func backgroundRunIgnoresInternalAgentsAndEndsCleanly() throws {
        let state = try replay(Run.background.payloads, with: Run.background.adapter())
        let session = try #require(state.onlySession)

        // Three internal agents (empty `agent_type`) stopped without starting.
        #expect(session.agents.count == 3)
        #expect(session.agents.values.allSatisfy { $0.status == .done })
        #expect(state.activeAgentCount == 0)
        #expect(session.children(of: .root).allSatisfy { $0.spec.isBackground == true })
    }

    @Test func permissionRunHasNoSubagents() throws {
        let state = try replay(Run.permission.payloads, with: Run.permission.adapter())
        let session = try #require(state.onlySession)

        #expect(session.agents.count == 1)
        #expect(session.root.status == .done)
        #expect(session.root.spec.prompt == "hi")
    }

    @Test func crashedRunIsFoundByItsProcessAndEndsWithALateSessionEnd() throws {
        // Without the final `SessionEnd`, as after a crash or a killed terminal.
        let payloads = Run.headless.payloads
        let sessionEnd = try #require(payloads.last)
        let hook = try JSONSerialization.jsonObject(with: sessionEnd) as? [String: Any]
        #expect(hook?["hook_event_name"] as? String == "SessionEnd")

        let adapter = Run.headless.adapter()
        let crashed = try replay(Array(payloads.dropLast()), with: adapter)
        let session = try #require(crashed.onlySession)
        #expect(session.pid == 4242)
        #expect(session.endedAt == nil)

        let now = t0.addingTimeInterval(120)
        var alive = crashed
        alive.markStale(now: now, silenceTimeout: 3_600, waitingTimeout: 3_600) { $0 == 4242 ? t0.addingTimeInterval(-30) : nil }
        #expect(alive == crashed)

        var reused = crashed
        reused.markStale(now: now, silenceTimeout: 3_600, waitingTimeout: 3_600) { _ in t0.addingTimeInterval(60) }
        #expect(reused.onlySession?.root.status == .stale)

        var gone = crashed
        gone.markStale(now: now, silenceTimeout: 3_600, waitingTimeout: 3_600) { _ in nil }
        #expect(gone.onlySession?.root.status == .stale)
        #expect(gone.onlySession?.endedAt == now)

        for event in try adapter.events(from: envelope(sessionEnd, at: payloads.count - 1)) {
            gone.apply(event)
        }
        let ended = try #require(gone.onlySession)
        #expect(ended.agents.values.allSatisfy { $0.status == .done })
        #expect(ended.endedAt == t0.addingTimeInterval(TimeInterval(payloads.count - 1)))

        let final = gone
        gone.markStale(now: now.addingTimeInterval(60), silenceTimeout: 3_600, waitingTimeout: 3_600) { _ in nil }
        for event in try adapter.events(from: envelope(payloads[3], at: payloads.count)) {
            gone.apply(event)
        }
        #expect(gone == final)
    }

    @Test(arguments: Run.allCases)
    func everyRunEndsWithNothingRunning(run: Run) throws {
        let state = try replay(run.payloads, with: run.adapter())
        #expect(state.activeAgentCount == 0)
        #expect(state.sessions.values.allSatisfy { $0.endedAt != nil })
    }

    /// Hooks are async, so neighbors swap. Shuffle within windows of three events
    /// (the final `SessionEnd` stays last: nothing counts after a session ended)
    /// and expect the same result.
    @Test(arguments: Run.allCases, [1, 2, 3, 4, 5, 6, 7, 8])
    func shuffledArrivalGivesTheSameTree(run: Run, seed: Int) throws {
        let ordered = run.payloads
        let reference = shape(try #require(try replay(ordered, with: run.adapter()).onlySession))

        var next = UInt64(seed) &* 6364136223846793005 &+ 1442695040888963407
        func random(_ upper: Int) -> Int {
            next = next &* 6364136223846793005 &+ 1442695040888963407
            return Int((next >> 33) % UInt64(upper))
        }
        var shuffled: [Data] = []
        let body = Array(ordered.dropLast())
        for start in stride(from: 0, to: body.count, by: 3) {
            var window = Array(body[start..<min(start + 3, body.count)])
            for i in stride(from: window.count - 1, to: 0, by: -1) { window.swapAt(i, random(i + 1)) }
            shuffled += window
        }
        shuffled.append(ordered.last!)

        let result = shape(try #require(try replay(shuffled, with: run.adapter()).onlySession))
        #expect(result == reference)
    }
}

// MARK: - Replies

@Suite struct ClaudeCodeReplyTests {
    /// The events of the hook file starting with `prefix`, after everything before it.
    private func kinds(of prefix: String, in run: Run) throws -> [AgentEvent.Kind] {
        let directory = run.directory.appendingPathComponent("events")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let index = try #require(names.firstIndex { $0.hasPrefix(prefix) })
        let adapter = run.adapter()
        for (offset, payload) in run.payloads.prefix(index).enumerated() { _ = try adapter.events(from: envelope(payload, at: offset)) }
        return try adapter.events(from: envelope(run.payloads[index], at: index)).map(\.kind)
    }

    /// `last_assistant_message` as the captured payload has it.
    private func message(of prefix: String, in run: Run) throws -> String {
        let directory = run.directory.appendingPathComponent("events")
        let name = try #require(try FileManager.default.contentsOfDirectory(atPath: directory.path).first { $0.hasPrefix(prefix) })
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(name))) as? [String: Any]
        return try #require(object?["last_assistant_message"] as? String)
    }

    private func events(_ payload: Data) throws -> [AgentEvent.Kind] {
        try ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping()).events(from: envelope(payload)).map(\.kind)
    }

    @Test func aSubagentsStopCarriesItsResultRightBeforeItsEnd() throws {
        let id = "ace844c63d8963861"
        let text = "The exact output is:\n\n```\nalpha\n```"
        #expect(try message(of: "015", in: .headless) == text)
        #expect(try kinds(of: "015", in: .headless).suffix(3) == [
            .replied(agent: .subagent(id), text), .agentFinished(id: id), .backgroundShellsListed([]),
        ])
    }

    @Test func theRootsStopCarriesItsReplyRightBeforeTheTurnEnds() throws {
        let text = try message(of: "020", in: .headless)
        #expect(text.hasPrefix("## Results from both agents:"))
        #expect(try kinds(of: "020", in: .headless).prefix(2) == [.replied(agent: .root, text), .turnEnded(.completed)])
    }

    @Test func aStopWithoutAMessageCarriesNoReply() throws {
        // 027 is an internal agent's stop; its `last_assistant_message` is null.
        let stop = try kinds(of: "027", in: .background)
        #expect(!stop.contains { if case .replied = $0 { true } else { false } })
    }

    @Test func aBlankMessageIsNoReply() throws {
        #expect(try events(hook("Stop", ["last_assistant_message": " \n\t"])) == [.turnEnded()])
        #expect(try events(hook("SubagentStop", ["agent_id": "a1", "agent_type": "Explore", "last_assistant_message": "\n"]))
            == [.agentSpawned(id: "a1", parent: .root, spec: AgentSpec(type: "Explore")), .agentFinished(id: "a1")])
    }

    @Test func theReplyIsKeptAsSent() throws {
        #expect(try events(hook("Stop", ["last_assistant_message": "\n  done\n"])) == [.replied(agent: .root, "\n  done\n"), .turnEnded()])
    }

    @Test func aDroppedInternalStopCarriesNoReply() throws {
        #expect(try events(hook("SubagentStop", ["agent_id": "x", "agent_type": "", "last_assistant_message": "summary"])).isEmpty)
    }

    @Test func aRunLeavesTheLastReplyOfEveryAgent() throws {
        let session = try #require(try replay(Run.headless.payloads, with: Run.headless.adapter()).onlySession)
        #expect(session.root.reply == (try message(of: "020", in: .headless)))
        #expect(session.agents[.subagent("ace844c63d8963861")]?.reply == (try message(of: "015", in: .headless)))
        #expect(session.agents[.subagent("a89ee3c49b791e40d")]?.reply == (try message(of: "017", in: .headless)))
    }

    @Test func theLastStopCanArriveAfterSessionEndWithoutLosingItsReply() throws {
        let payloads = Run.headless.payloads
        let stopIndex = payloads.count - 2
        let endIndex = payloads.count - 1
        let stop = try #require(JSONSerialization.jsonObject(with: payloads[stopIndex]) as? [String: Any])
        #expect(stop["hook_event_name"] as? String == "Stop")
        let expectedReply = try #require(stop["last_assistant_message"] as? String)
        let adapter = Run.headless.adapter()
        var state = CollectiveState()

        for index in Array(payloads.indices.dropLast(2)) + [endIndex, stopIndex] {
            for event in try adapter.events(from: envelope(payloads[index], at: index)) {
                state.apply(event)
            }
        }

        let session = try #require(state.onlySession)
        #expect(session.root.reply == expectedReply)
        #expect(session.root.status == .done)
        #expect(session.endedAt == t0.addingTimeInterval(TimeInterval(endIndex)))
        #expect(session.lastActivity == t0.addingTimeInterval(TimeInterval(endIndex)))
    }
}

// MARK: - Mapping and linking (synthetic payloads)

@Suite struct ClaudeCodeAdapterTests {
    private func events(_ payload: Data, with adapter: ClaudeCodeAdapter = ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping())) throws -> [AgentEvent.Kind] {
        try adapter.events(from: envelope(payload)).map(\.kind)
    }

    @Test func mapsTheLifecycleHooks() throws {
        #expect(try events(hook("SessionStart", ["cwd": "/p"])) == [.sessionStarted(cwd: "/p", pid: 4242)])
        #expect(try events(hook("UserPromptSubmit", ["prompt": "go"])) == [.promptSubmitted("go")])
        #expect(try events(hook("UserPromptSubmit", ["prompt": "<task-notification>x"])) == [.turnStarted])
        #expect(try events(hook("Stop")) == [.turnEnded(.completed)])
        #expect(try events(hook("StopFailure")) == [.turnEnded(.failed)])
        #expect(try events(hook("SessionEnd")) == [.sessionEnded])
    }

    @Test func ignoresUnknownAndIrrelevantHooks() throws {
        for name in ["InstructionsLoaded", "PostToolBatch", "PreCompact", "SomethingNew"] {
            #expect(try events(hook(name, ["whatever": 1])).isEmpty)
        }
    }

    @Test func rejectsPayloadsItCannotUse() {
        let adapter = ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping())
        #expect(throws: (any Error).self) { try adapter.events(from: envelope(Data("nope".utf8))) }
        #expect(throws: ClaudeCodeAdapterError.notAJSONObject) { try adapter.events(from: envelope(Data("[1]".utf8))) }
        #expect(throws: ClaudeCodeAdapterError.missingField("session")) {
            try adapter.events(from: envelope(json(["hook_event_name": "Stop"])))
        }
        // Without a hook name the payload is just an unknown hook.
        #expect((try? adapter.events(from: envelope(json(["session_id": "s1"])))) == [])
    }

    @Test func toolCallsBelongToTheAgentThatMadeThem() throws {
        let adapter = ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping())
        let main = hook("PreToolUse", ["tool_name": "Read", "tool_use_id": "t1", "tool_input": ["file_path": "/a/b.txt"]])
        let sub = hook("PreToolUse", [
            "tool_name": "Bash", "tool_use_id": "t2", "agent_id": "a1", "agent_type": "explore",
            "tool_input": ["command": "ls -la\nsecond line", "description": "List"],
        ])
        #expect(try events(main, with: adapter) == [.toolStarted(agent: .root, ToolActivity(name: "Read", detail: "/a/b.txt"), callID: "t1")])
        #expect(try events(sub, with: adapter) == [
            .agentSpawned(id: "a1", parent: .root, spec: AgentSpec(type: "explore")),
            .toolStarted(agent: .subagent("a1"), ToolActivity(name: "Bash", detail: "ls -la"), callID: "t2"),
        ])
        #expect(try events(hook("PostToolUse", ["tool_name": "Read", "tool_use_id": "t1"]), with: adapter) == [.toolFinished(agent: .root, callID: "t1")])
        #expect(try events(hook("PostToolUseFailure", ["tool_name": "Bash", "tool_use_id": "t2", "agent_id": "a1"]), with: adapter)
            == [.toolFinished(agent: .subagent("a1"), callID: "t2")])
    }

    @Test func aToolStartArrivingAfterItsEndDoesNotLeaveItRunning() throws {
        let adapter = ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping())
        _ = try events(hook("PostToolUse", ["tool_name": "Read", "tool_use_id": "t1"]), with: adapter)
        let late = hook("PreToolUse", ["tool_name": "Read", "tool_use_id": "t1", "tool_input": ["file_path": "/a"]])
        #expect(try events(late, with: adapter) == [
            .toolStarted(agent: .root, ToolActivity(name: "Read", detail: "/a"), callID: "t1", alreadyEnded: true),
        ])
    }

    @Test func parentToolUseIdLinksASubagentToItsCall() throws {
        let adapter = ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping())
        let state = try replay([
            hook("PreToolUse", ["tool_name": "Agent", "tool_use_id": "T1",
                                "tool_input": ["description": "Find colors", "prompt": "Search src/", "run_in_background": true]]),
            hook("SubagentStart", ["agent_id": "a1", "agent_type": "Explore", "parent_tool_use_id": "T1"]),
        ], with: adapter)
        let agent = try #require(state.sessions[key]?.agents[.subagent("a1")])
        #expect(agent.spec == AgentSpec(type: "Explore", title: "Find colors", prompt: "Search src/", isBackground: true))
        #expect(agent.parent == .root)
    }

    @Test func aSubagentStartedByASubagentIsNested() throws {
        let adapter = ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping())
        let state = try replay([
            hook("SubagentStart", ["agent_id": "a", "agent_type": "implementer"]),
            hook("PreToolUse", ["tool_name": "Agent", "tool_use_id": "T2", "agent_id": "a", "agent_type": "implementer",
                                "tool_input": ["description": "Write tests", "prompt": "p"]]),
            hook("SubagentStart", ["agent_id": "b", "agent_type": "general-purpose", "parent_tool_use_id": "T2"]),
        ], with: adapter)
        let session = try #require(state.sessions[key])
        #expect(session.agents[.subagent("b")]?.parent == .subagent("a"))
        #expect(session.agents[.subagent("b")]?.spec.title == "Write tests")
        #expect(session.children(of: .subagent("a")).map(\.id) == [.subagent("b")])
        #expect(session.children(of: .root).map(\.id) == [.subagent("a")])
    }

    @Test func aMetaFileThatAppearsLaterIsPickedUpByLaterEvents() throws {
        let reader = StubMetaReader()
        let adapter = ClaudeCodeAdapter(metaReader: reader, mapping: bundledMapping())
        var state = try replay([
            hook("PreToolUse", ["tool_name": "Agent", "tool_use_id": "T1", "tool_input": ["description": "D", "prompt": "P"]]),
            hook("SubagentStart", ["agent_id": "a1", "agent_type": "Explore"]),
        ], with: adapter)
        #expect(state.sessions[key]?.agents[.subagent("a1")]?.spec.title == nil)

        reader.set("a1", SubagentMeta(toolUseID: "T1", description: "D"))
        for event in try adapter.events(from: envelope(hook("PreToolUse", ["tool_name": "Bash", "tool_use_id": "t9", "agent_id": "a1"]))) {
            state.apply(event)
        }
        let spec = try #require(state.sessions[key]?.agents[.subagent("a1")]).spec
        #expect(spec.title == "D")
        #expect(spec.prompt == "P")
    }

    /// The start fired first and carries the earlier `ts`, it only arrives
    /// late; a start later than the stop would be a resume.
    @Test func aStopBeforeItsStartStillEndsTheSubagent() throws {
        let adapter = ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping())
        var state = CollectiveState()
        for envelope in [
            envelope(hook("SubagentStop", ["agent_id": "a1", "agent_type": "Explore"]), at: 1),
            envelope(hook("SubagentStart", ["agent_id": "a1", "agent_type": "Explore"]), at: 0),
        ] {
            for event in try adapter.events(from: envelope) { state.apply(event) }
        }
        #expect(state.sessions[key]?.agents[.subagent("a1")]?.status == .done)
        #expect(state.activeAgentCount == 0)
    }

    @Test func internalAgentsAreNotShown() throws {
        let adapter = ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping())
        #expect(try events(hook("SubagentStop", ["agent_id": "x", "agent_type": ""]), with: adapter).isEmpty)
    }

    @Test func sessionsDoNotShareState() throws {
        let adapter = ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping())
        _ = try adapter.events(from: envelope(hook("PreToolUse", [
            "tool_name": "Agent", "tool_use_id": "T1", "tool_input": ["description": "Only in s1"],
        ])))
        let other = json(["hook_event_name": "SubagentStart", "session_id": "s2", "agent_id": "a1",
                          "agent_type": "Explore", "parent_tool_use_id": "T1"])
        let kinds = try adapter.events(from: envelope(other)).map(\.kind)
        #expect(kinds == [.agentSpawned(id: "a1", parent: .root, spec: AgentSpec(type: "Explore"))])
    }
}

// MARK: - Mapping documents

/// Serves files from memory; everything else does not exist.
private final class MemoryFileSystem: MappingFileSystem {
    private let files: [URL: Data]

    init(_ files: [URL: Data] = [:]) { self.files = files }

    func modificationDate(of url: URL) -> Date? { files[url] == nil ? nil : t0 }

    func contents(of url: URL) throws -> Data {
        guard let data = files[url] else { throw CocoaError(.fileNoSuchFile) }
        return data
    }
}

private let mappingRoot = URL(filePath: "/spool/root", directoryHint: .isDirectory)

/// A root without `model/`, so the bundled document is used.
private func bundledMapping() -> MappingLoader {
    MappingLoader(root: mappingRoot, fileSystem: MemoryFileSystem())
}

/// `document` served as `$ROOT/model/claude-code.json`.
private func rootMapping(_ document: Data) -> MappingLoader {
    MappingLoader(root: mappingRoot, fileSystem: MemoryFileSystem([mappingRoot.appending(path: "model/claude-code.json"): document]))
}

/// The bundled claude-code document as text, to derive drifted copies from.
private func bundledDocumentText() throws -> String {
    let url = try #require(MappingLoader.bundledURL(named: "claude-code"))
    return try String(contentsOf: url, encoding: .utf8)
}

/// The bundled Claude Code document's revision, derived so that updating the
/// bundled copy in SubspaceKit needs no test change here.
private let bundledRevision = MappingLoader.bundledDocument(named: "claude-code")?.revision ?? 0

/// Runs of 2.1.287 that have no subagent meta files.
enum Run287: String {
    case interruptMidTurn = "2-interrupt-mid-turn"
    case waitingPermissionQuestion = "4-waiting-permission-question"
    case backgroundSubagents = "6-background-subagents"
    case backgroundShell = "6a-background-shell-exit-dialog-killed"
    case exitWithoutPrompt = "11-exit-without-prompt"
    case toolFailure = "12-tool-failure"
    case sigtermWithoutInput = "14-sigterm-without-input"

    var directory: URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/claude-code/2.1.287")
            .appendingPathComponent(rawValue)
            .appendingPathComponent("events")
    }

    /// Raw payloads in arrival order, up to and including the file starting with `last`.
    func payloads(through last: String? = nil) -> [Data] {
        var files = try! FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        if let last, let end = files.firstIndex(where: { $0.hasPrefix(last) }) { files = Array(files[...end]) }
        return files.map { try! Data(contentsOf: directory.appendingPathComponent($0)) }
    }

    func adapter() -> ClaudeCodeAdapter {
        ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping())
    }
}

@Suite struct ClaudeCodeMappingTests {
    @Test func withoutAnyMappingDocumentPayloadsAreRejected() {
        let none = MappingLoader(root: mappingRoot, fileSystem: MemoryFileSystem()) { _ in nil }
        let adapter = ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: none)
        #expect(throws: ClaudeCodeAdapterError.noMapping) {
            try adapter.events(from: envelope(hook("SessionStart", ["cwd": "/p"])))
        }
    }

    @Test func theDefaultMappingComesFromTheRootTheEventsComeFrom() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("model"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let drifted = try bundledDocumentText().replacingOccurrences(of: #""revision": \#(bundledRevision)"#, with: #""revision": 99"#)
        try Data(drifted.utf8).write(to: dir.appendingPathComponent("model/claude-code.json"))

        let loader = ClaudeCodeAdapter.defaultMapping(environment: ["SUBSPACE_DIR": dir.path], home: URL(filePath: "/nowhere"))
        #expect(loader.document(named: "claude-code")?.revision == 99)
    }

    @Test func theDefaultMappingComesFromAChosenFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("model"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let drifted = try bundledDocumentText().replacingOccurrences(of: #""revision": \#(bundledRevision)"#, with: #""revision": 99"#)
        try Data(drifted.utf8).write(to: dir.appendingPathComponent("model/claude-code.json"))

        let loader = ClaudeCodeAdapter.defaultMapping(chosen: dir, environment: ["SUBSPACE_DIR": "/nowhere"], home: URL(filePath: "/nowhere"))
        #expect(loader.document(named: "claude-code")?.revision == 99)
    }

    @Test func aFailedToolClosesItsStart() throws {
        let running = try replay(Run287.toolFailure.payloads(through: "008"), with: Run287.toolFailure.adapter())
        #expect(try #require(running.onlySession).root.currentTool?.name == "Bash")
        // Up to and including 009-PostToolUseFailure, before the turn ends.
        let failed = try replay(Run287.toolFailure.payloads(through: "009"), with: Run287.toolFailure.adapter())
        let root = try #require(failed.onlySession).root
        #expect(root.currentTool == nil)
        #expect(root.status == .working)

        let end = try replay(Run287.toolFailure.payloads(), with: Run287.toolFailure.adapter())
        let session = try #require(end.onlySession)
        #expect(session.root.currentTool == nil)
        #expect(session.root.status == .done)
        #expect(end.activeAgentCount == 0)
    }

    /// Hooks run async: the `Bash` call's end (013) may arrive before its
    /// start (009). Each keeps its place in time, only the arrival swaps.
    @Test func aStartArrivingAfterItsEndShowsNoTool() throws {
        let run = Run287.waitingPermissionQuestion
        let adapter = run.adapter()
        var timed = Array(run.payloads(through: "013").enumerated())
        timed.append(timed.remove(at: 4)) // 009-PreToolUse, after 013-PostToolUse
        var state = CollectiveState()
        for (second, payload) in timed {
            for event in try adapter.events(from: envelope(payload, at: second)) { state.apply(event) }
        }

        let session = try #require(state.onlySession)
        #expect(session.root.status == .working)
        #expect(session.root.currentTool == nil)
    }

    @Test func anAgentMessageWakesTheOrchestratorWithoutReplacingItsPrompt() throws {
        let run = Run287.backgroundSubagents
        let waiting = try replay(run.payloads(through: "024"), with: run.adapter())
        #expect(try #require(waiting.onlySession).root.status == .waiting)

        let state = try replay(run.payloads(through: "025"), with: run.adapter())
        let root = try #require(state.onlySession).root
        #expect(root.status == .working)
        #expect(root.spec.prompt?.hasPrefix("Call the Agent tool once with subagent_type general-purpose and run_in_background true") == true)
    }

    @Test func backgroundSubagentsOf2_1_287AreLinkedAndEndCleanly() throws {
        let run = Run287.backgroundSubagents
        let state = try replay(run.payloads(), with: run.adapter())
        let session = try #require(state.onlySession)
        let subagents = session.children(of: .root)
        #expect(subagents.map(\.spec.title) == ["Run sleep command", "Run sleep command bg"])
        #expect(subagents.allSatisfy { $0.spec.type == "general-purpose" && $0.spec.isBackground == true && $0.status == .done })
        #expect(state.activeAgentCount == 0)
        #expect(session.endedAt != nil)
    }

    @Test func exitWithoutAPromptStartsAndEndsTheSession() throws {
        let state = try replay(Run287.exitWithoutPrompt.payloads(), with: Run287.exitWithoutPrompt.adapter())
        let session = try #require(state.onlySession)
        #expect(session.root.spec.prompt == nil)
        #expect(session.endedAt != nil)
        #expect(state.activeAgentCount == 0)
    }

    @Test func aSessionTerminatedBeforeAnyInputEnds() throws {
        let run = Run287.sigtermWithoutInput
        let payloads = run.payloads()

        // The case this run proves: its SessionEnd carries no prompt_id.
        let document = try #require(bundledMapping().document(named: "claude-code"))
        let end = MappingInterpreter.apply(document, to: try JSONValue(data: #require(payloads.last)))
        #expect(end.block["prompt_id"] == nil)
        #expect(end.block["kind"] == .string("session.end"))

        let state = try replay(payloads, with: run.adapter())
        let session = try #require(state.onlySession)
        #expect(session.root.spec.prompt == nil)
        #expect(session.endedAt != nil)
        #expect(state.activeAgentCount == 0)
    }

    @Test func aRenamedPayloadPathIsAbsorbedByTheMapping() throws {
        let text = try bundledDocumentText()
        func drifted(_ path: String) throws -> Data {
            let replaced = text
                .replacingOccurrences(of: #""path": "/tool_use_id""#, with: #""path": \#(path)"#)
                .replacingOccurrences(of: #""revision": \#(bundledRevision)"#, with: #""revision": \#(bundledRevision + 1)"#)
            #expect(replaced != text)
            return Data(replaced.utf8)
        }
        let fallback = rootMapping(try drifted(#"["/tool_call_id", "/tool_use_id"]"#))
        #expect(fallback.document(named: "claude-code")?.revision == bundledRevision + 1)

        for run in Run.allCases {
            let reference = try replay(run.payloads, with: ClaudeCodeAdapter(metaReader: StubMetaReader(run.metas), mapping: bundledMapping()))
            let withFallback = ClaudeCodeAdapter(metaReader: StubMetaReader(run.metas), mapping: rootMapping(try drifted(#"["/tool_call_id", "/tool_use_id"]"#)))
            #expect(try replay(run.payloads, with: withFallback) == reference)
        }

        // The served copy is what the adapter reads: with only the new path, tool calls no longer pair.
        let onlyNew = ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: rootMapping(try drifted(#""/tool_call_id""#)))
        let broken = try replay(Run.background.payloads.prefix(14).map { $0 }, with: onlyNew)
        let reference = try replay(Run.background.payloads.prefix(14).map { $0 }, with: ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping()))
        #expect(broken != reference)
    }
}

// MARK: - Tool calls and permission requests

/// Adapter seam: what pairs a tool call's start with its end and names a
/// pending permission, from captured 2.1.287 runs.
@Suite struct ClaudeCodeToolCallTests {
    /// The events of the hook file starting with `prefix`, after everything before it.
    private func kinds(of prefix: String, in run: Run287) throws -> [AgentEvent.Kind] {
        let files = try FileManager.default.contentsOfDirectory(atPath: run.directory.path).sorted()
        let index = try #require(files.firstIndex { $0.hasPrefix(prefix) })
        let payloads = run.payloads()
        let adapter = run.adapter()
        for (offset, payload) in payloads.prefix(index).enumerated() { _ = try adapter.events(from: envelope(payload, at: offset)) }
        return try adapter.events(from: envelope(payloads[index], at: index)).map(\.kind)
    }

    @Test func aToolStartCarriesItsCallID() throws {
        let bash = ToolActivity(name: "Bash", detail: "touch captures/perm-one")
        #expect(try kinds(of: "009", in: .waitingPermissionQuestion)
            == [.toolStarted(agent: .root, bash, callID: "toolu_012Q93n9wBTeQBzbT1oLNzHS")])
    }

    @Test func aToolEndCarriesTheCallIDOfItsStartAndTheMeasuredDuration() throws {
        let question = "toolu_01XWWJER73MBr9UH78Hqdn4i"
        // The question's own events follow, see `ClaudeCodeQuestionTests`.
        #expect(try kinds(of: "026", in: .waitingPermissionQuestion).first
            == .toolStarted(agent: .root, ToolActivity(name: "AskUserQuestion"), callID: question))
        #expect(try kinds(of: "031", in: .waitingPermissionQuestion).first == .toolFinished(agent: .root, callID: question, duration: 0))
        #expect(try kinds(of: "013", in: .waitingPermissionQuestion)
            == [.toolFinished(agent: .root, callID: "toolu_012Q93n9wBTeQBzbT1oLNzHS", duration: 0.565)])
    }

    @Test func aFailedToolEndCarriesItsCallIDAndDuration() throws {
        #expect(try kinds(of: "009", in: .toolFailure) == [.toolFinished(agent: .root, callID: "toolu_01PQ9mmE9EfdjVEwS2DkCSmi", duration: 0.578)])
    }

    @Test func aPermissionRequestNamesTheToolLikeItsStart() throws {
        #expect(try kinds(of: "010", in: .waitingPermissionQuestion)
            == [.permissionRequested(agent: .root, ToolActivity(name: "Bash", detail: "touch captures/perm-one"))])
        // The second request, which the user rejects.
        #expect(try kinds(of: "021", in: .waitingPermissionQuestion)
            == [.permissionRequested(agent: .root, ToolActivity(name: "Bash", detail: "touch captures/perm-two"))])
    }

    @Test func aFileToolsRequestNamesItsFile() throws {
        let adapter = Run.permission.adapter()
        let payloads = Run.permission.payloads
        for (index, payload) in payloads.prefix(5).enumerated() { _ = try adapter.events(from: envelope(payload, at: index)) }
        #expect(try adapter.events(from: envelope(payloads[5], at: 5)).map(\.kind)
            == [.permissionRequested(agent: .root, ToolActivity(name: "Read", detail: "/Users/user/dev/subspace/notes/todo.md"))])
    }

    /// `AskUserQuestion` asks through the permission dialog, but it is a question.
    @Test func aQuestionIsNoPermissionRequest() throws {
        let kinds = try kinds(of: "028", in: .waitingPermissionQuestion)
        #expect(!kinds.contains { if case .permissionRequested = $0 { true } else { false } })
    }
}

/// No captured run has a subagent asking for permission; these follow the
/// shape of the captured root request with `agent_id` added.
@Suite struct ClaudeCodeSubagentPermissionTests {
    private let bash = ToolActivity(name: "Bash", detail: "ls")

    private func request(type: String? = nil) -> Data {
        var fields: [String: Any] = ["agent_id": "x1", "tool_name": "Bash", "tool_input": ["command": "ls", "description": "List"]]
        if let type { fields["agent_type"] = type }
        return hook("PermissionRequest", fields)
    }

    /// The events of each payload in turn, through one adapter.
    private func kinds(_ payloads: [Data]) throws -> [[AgentEvent.Kind]] {
        let adapter = ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping())
        return try payloads.enumerated().map { index, payload in
            try adapter.events(from: envelope(payload, at: index)).map(\.kind)
        }
    }

    @Test func anIdentifiedSubagentsRequestIsItsOwn() throws {
        let start = hook("SubagentStart", ["agent_id": "x1", "agent_type": "general-purpose"])
        #expect(try kinds([start, request()]).last == [.permissionRequested(agent: .subagent("x1"), bash)])
    }

    /// A typeless agent stays invisible, and its request carries no call id, so a
    /// parked one could not be matched to its answer; it is dropped instead.
    @Test func aTypelessAgentsRequestIsDroppedForGood() throws {
        let start = hook("SubagentStart", ["agent_id": "x1", "agent_type": "general-purpose"])
        #expect(try kinds([request(), start]) == [[], [.agentSpawned(id: "x1", parent: .root, spec: AgentSpec(type: "general-purpose"))]])
    }

    @Test func aTypedRequestIdentifiesItsAgent() throws {
        #expect(try kinds([request(type: "implementer")]) == [[
            .agentSpawned(id: "x1", parent: .root, spec: AgentSpec(type: "implementer")),
            .permissionRequested(agent: .subagent("x1"), bash),
        ]])
    }

    @Test func aRequestAfterATypelessStopKeepsItHidden() throws {
        let stop = hook("SubagentStop", ["agent_id": "x1", "agent_type": ""])
        #expect(try kinds([stop, request(type: "implementer")]) == [[], []])
    }
}

// MARK: - Unseen session start

/// A session that ran before subspace was installed, or whose start fell out
/// of the spool: its hooks arrive without the `SessionStart`.
@Suite struct ClaudeCodeUnseenStartTests {
    private let run = Run287.interruptMidTurn
    /// The `cwd` every hook of the run carries.
    private let capturedCWD = "/Users/user/dev/subspace/tools/hook-capture/claude-code"

    private var payloadsWithoutStart: [Data] {
        let files = try! FileManager.default.contentsOfDirectory(atPath: run.directory.path).sorted()
        return files.filter { !$0.hasSuffix("-SessionStart.json") }
            .map { try! Data(contentsOf: run.directory.appendingPathComponent($0)) }
    }

    @Test func everyEventCarriesTheDirectoryAndTheEnvelopePid() throws {
        let adapter = run.adapter()
        let events = try payloadsWithoutStart.flatMap { try adapter.events(from: envelope($0)) }
        #expect(!events.isEmpty)
        for event in events {
            #expect(event.cwd == capturedCWD, "\(event.kind)")
            #expect(event.pid == 4242, "\(event.kind)")
        }
    }

    @Test func theSessionKnowsItsDirectoryAndProcessFromItsFirstPrompt() throws {
        // Two `InstructionsLoaded`, then the first prompt; the session ends later.
        let payloads = Array(payloadsWithoutStart.prefix(3))
        let state = try replay(payloads, with: run.adapter())
        let session = try #require(state.onlySession)
        #expect(session.root.spec.prompt != nil)
        #expect(session.endedAt == nil)
        #expect(session.cwd == capturedCWD)
        #expect(session.pid == 4242)
    }
}

// MARK: - Stopped background agents

/// Run 15 of 2.1.288: a background agent stopped by the user, which sends no `SubagentStop`.
private func run15Payloads(through last: String? = nil) -> [Data] {
    let directory = Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures/claude-code/2.1.288/15-stop-background-agent/events")
    var files = try! FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    if let last, let end = files.firstIndex(where: { $0.hasPrefix(last) }) { files = Array(files[...end]) }
    return files.map { try! Data(contentsOf: directory.appendingPathComponent($0)) }
}

@Suite struct ClaudeCodeBackgroundStopTests {
    private let stopped = AgentRef.subagent("a80f925acc1e94159")

    private func adapter() -> ClaudeCodeAdapter {
        ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping())
    }

    @Test func aStoppedBackgroundAgentEndsWhenItLeavesTheSnapshot() throws {
        let listed = try replay(run15Payloads(through: "017"), with: adapter())
        #expect(try #require(listed.onlySession).agents[stopped]?.status == .working)

        let state = try replay(run15Payloads(through: "018"), with: adapter())
        let session = try #require(state.onlySession)
        #expect(session.agents[stopped]?.status == .done)
        #expect(session.agents.values.allSatisfy { $0.id == .root || !$0.status.isActive })
    }

    @Test func run15EndsWithNothingRunning() throws {
        let state = try replay(run15Payloads(), with: adapter())
        let session = try #require(state.onlySession)
        #expect(state.activeAgentCount == 0)
        #expect(session.agents[stopped]?.status == .done)
        #expect(session.endedAt != nil)
    }

    /// Payloads with the envelope second each arrives in.
    private func replayTimed(_ timed: [(payload: Data, second: Int)]) throws -> CollectiveState {
        let adapter = adapter()
        var state = CollectiveState()
        for (payload, second) in timed {
            for event in try adapter.events(from: envelope(payload, at: second)) { state.apply(event) }
        }
        return state
    }

    private let start = hook("SubagentStart", ["agent_id": "a1", "agent_type": "general-purpose"])

    private func agentPost(async: Bool) -> Data {
        var response: [String: Any] = ["agentId": "a1", "status": async ? "async_launched" : "completed"]
        if async { response["isAsync"] = true }
        return hook("PostToolUse", ["tool_name": "Agent", "tool_use_id": "T1",
                                    "tool_input": ["description": "D", "prompt": "P"], "tool_response": response])
    }

    /// A root `Stop` whose snapshot lists only another background agent.
    private let stopWithoutA1 = hook("Stop", ["background_tasks": [
        ["id": "a2", "type": "subagent", "status": "running", "description": "Other", "agent_type": "general-purpose"],
    ]])

    @Test func aSnapshotFromTheSameSecondAsTheLaunchKeepsTheAgentOpen() throws {
        let same = try replayTimed([(start, 0), (agentPost(async: true), 1), (stopWithoutA1, 1)])
        #expect(same.sessions[key]?.agents[.subagent("a1")]?.status == .working)

        let later = try replayTimed([(start, 0), (agentPost(async: true), 1), (stopWithoutA1, 2)])
        #expect(later.sessions[key]?.agents[.subagent("a1")]?.status == .done)
    }

    @Test func aForegroundAgentIsNeverEndedByItsAbsence() throws {
        let state = try replayTimed([(start, 0), (agentPost(async: false), 1), (hook("Stop", ["background_tasks": []]), 2)])
        #expect(state.sessions[key]?.agents[.subagent("a1")]?.status == .working)
    }

    @Test func aStopWithoutASnapshotEndsNothing() throws {
        let state = try replayTimed([(start, 0), (agentPost(async: true), 1), (hook("Stop"), 2)])
        #expect(state.sessions[key]?.agents[.subagent("a1")]?.status == .working)
    }

    @Test func aStoppingAgentIsEndedOnce() throws {
        let adapter = adapter()
        _ = try adapter.events(from: envelope(start, at: 0))
        _ = try adapter.events(from: envelope(agentPost(async: true), at: 1))
        let stop = hook("SubagentStop", ["agent_id": "a1", "agent_type": "general-purpose", "background_tasks": []])
        let kinds = try adapter.events(from: envelope(stop, at: 2)).map(\.kind)
        #expect(kinds.filter { $0 == .agentFinished(id: "a1") }.count == 1)
    }
}

// MARK: - Background shells

/// Run 6a of 2.1.287: a shell started in the background outlives the turn
/// that started it (subspace `docs/model.md` §3.2, S6a).
@Suite struct ClaudeCodeBackgroundShellTests {
    private let run = Run287.backgroundShell
    private let shell = BackgroundShell(
        id: "b1030i5uk", command: "sleep 30; echo bg", description: "Background command that sleeps 30 seconds then echoes"
    )

    /// The listings each hook file yields, by the file's number, replaying the run in order.
    private func listings() throws -> [String: [[BackgroundShell]]] {
        let files = try FileManager.default.contentsOfDirectory(atPath: run.directory.path).sorted()
        let adapter = run.adapter()
        var listings: [String: [[BackgroundShell]]] = [:]
        for (index, file) in files.enumerated() {
            let payload = try Data(contentsOf: run.directory.appendingPathComponent(file))
            for event in try adapter.events(from: envelope(payload, at: index)) {
                guard case let .backgroundShellsListed(shells) = event.kind else { continue }
                listings[String(file.prefix(3)), default: []].append(shells)
            }
        }
        return listings
    }

    @Test func everyStopListsTheShellsRunningThen() throws {
        let listings = try listings()
        #expect(listings["013"] == [[]])
        #expect(listings["020"] == [[shell]])
        #expect(listings["021"] == [[shell]])
        #expect(listings["024"] == [[shell]])
    }

    @Test func hooksWithoutASnapshotListNothing() throws {
        #expect(try Set(listings().keys) == ["013", "020", "021", "024"])
    }

    /// The `Bash` call with `run_in_background` (016) starts the shell its
    /// later snapshots list; the subagent's foreground `Bash` (018) starts none.
    @Test func theBackgroundCallsPostStartsTheShell() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: run.directory.path).sorted()
        let adapter = run.adapter()
        var started: [String: [AgentEvent.Kind]] = [:]
        for (index, file) in files.enumerated() {
            let payload = try Data(contentsOf: run.directory.appendingPathComponent(file))
            let kinds = try adapter.events(from: envelope(payload, at: index)).map(\.kind)
            if file.hasPrefix("016") {
                #expect(kinds == [.toolFinished(agent: .root, callID: "toolu_01DhKsBhcugKFaoKB5S6oYp1", duration: 0.011),
                                  .backgroundShellStarted(id: shell.id)])
            }
            for kind in kinds { if case .backgroundShellStarted = kind { started[String(file.prefix(3)), default: []].append(kind) } }
        }
        #expect(started == ["016": [.backgroundShellStarted(id: shell.id)]])
    }
}

// MARK: - Agents that never identify themselves

/// Claude Code's internal agents may send tool hooks without ever naming a
/// type. Such an agent stays invisible until it identifies itself.
@Suite struct ClaudeCodeTypelessAgentTests {
    private let agent = AgentRef.subagent("x1")
    private let bash = ToolActivity(name: "Bash", detail: "ls")

    private func adapter() -> ClaudeCodeAdapter {
        ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping())
    }

    private func toolStart(type: String? = nil, call: String = "U1") -> Data {
        var fields: [String: Any] = ["agent_id": "x1", "tool_name": "Bash", "tool_use_id": call, "tool_input": ["command": "ls"]]
        if let type { fields["agent_type"] = type }
        return hook("PreToolUse", fields)
    }

    private func toolEnd(type: String? = nil, call: String = "U1") -> Data {
        var fields: [String: Any] = ["agent_id": "x1", "tool_name": "Bash", "tool_use_id": call]
        if let type { fields["agent_type"] = type }
        return hook("PostToolUse", fields)
    }

    /// The events of each payload in turn, through one adapter.
    private func kinds(_ payloads: [Data]) throws -> [[AgentEvent.Kind]] {
        let adapter = adapter()
        return try payloads.enumerated().map { index, payload in
            try adapter.events(from: envelope(payload, at: index)).map(\.kind)
        }
    }

    @Test func aTypelessToolNeverShowsTheAgent() throws {
        let batch = hook("PostToolBatch", ["agent_id": "x1"])
        let rootStop = hook("Stop", ["background_tasks": []])
        #expect(try kinds([toolStart(), batch, rootStop]) == [[], [], [.turnEnded(), .backgroundShellsListed([])]])
    }

    @Test func aLaterStartShowsItWithTheToolStillOpen() throws {
        let start = hook("SubagentStart", ["agent_id": "x1", "agent_type": "general-purpose"])
        #expect(try kinds([toolStart(), start]) == [
            [], [.agentSpawned(id: "x1", parent: .root, spec: AgentSpec(type: "general-purpose")), .toolStarted(agent: agent, bash, callID: "U1")],
        ])
        // A tool that ended meanwhile is not brought back.
        #expect(try kinds([toolStart(), toolEnd(), start]).last == [
            .agentSpawned(id: "x1", parent: .root, spec: AgentSpec(type: "general-purpose")),
        ])
    }

    /// Synthetic payloads shaped like the decision-25 ones above: no capture
    /// holds a typeless agent's start arriving after its end.
    @Test func aLateStartOfAnEndedToolIsNotBroughtBackWhenItIdentifies() throws {
        let start = hook("SubagentStart", ["agent_id": "x1", "agent_type": "general-purpose"])
        let spawned = AgentEvent.Kind.agentSpawned(id: "x1", parent: .root, spec: AgentSpec(type: "general-purpose"))
        #expect(try kinds([toolEnd(), toolStart(), start]) == [[], [], [spawned]])
    }

    @Test func theAgentCallNamingItShowsItWithTheToolStillOpen() throws {
        let input: [String: Any] = ["subagent_type": "general-purpose", "description": "D", "prompt": "P"]
        let call = hook("PreToolUse", ["tool_name": "Agent", "tool_use_id": "T1", "tool_input": input])
        let post = hook("PostToolUse", ["tool_name": "Agent", "tool_use_id": "T1", "tool_input": input,
                                        "tool_response": ["agentId": "x1", "status": "completed"]])
        let spec = AgentSpec(type: "general-purpose", title: "D", prompt: "P")
        #expect(try kinds([call, toolStart(), post]).last == [
            .toolFinished(agent: .root, callID: "T1"), .agentSpawned(id: "x1", parent: .root, spec: spec), .toolStarted(agent: agent, bash, callID: "U1"),
        ])
    }

    @Test func aTypedToolHookIdentifiesItWithThatTool() throws {
        let start = hook("SubagentStart", ["agent_id": "x1", "agent_type": "implementer"])
        let spawned = AgentEvent.Kind.agentSpawned(id: "x1", parent: .root, spec: AgentSpec(type: "implementer"))
        #expect(try kinds([toolStart(type: "implementer"), start]) == [[spawned, .toolStarted(agent: agent, bash, callID: "U1")], []])

        // Its end first: the late start leaves no tool running.
        let ended = try kinds([toolEnd(type: "implementer"), toolStart(type: "implementer"), start])
        #expect(ended == [[spawned, .toolFinished(agent: agent, callID: "U1")], [.toolStarted(agent: agent, bash, callID: "U1", alreadyEnded: true)], []])
    }

    @Test func aTypedStopShowsItFinishedWithoutItsTool() throws {
        let stop = hook("SubagentStop", ["agent_id": "x1", "agent_type": "general-purpose"])
        #expect(try kinds([toolStart(), stop]).last == [
            .agentSpawned(id: "x1", parent: .root, spec: AgentSpec(type: "general-purpose")), .agentFinished(id: "x1"),
        ])
    }

    @Test func aTypelessStopKeepsItHiddenForGood() throws {
        let stop = hook("SubagentStop", ["agent_id": "x1", "agent_type": ""])
        #expect(try kinds([toolStart(), stop, toolStart(call: "U2"), toolEnd(call: "U2")]) == [[], [], [], []])
    }

    /// Hooks run async: a tool hook naming the type may come after the stop.
    @Test func aTypedToolStartAfterATypelessStopKeepsItHidden() throws {
        let stop = hook("SubagentStop", ["agent_id": "x1", "agent_type": ""])
        #expect(try kinds([stop, toolStart(type: "implementer")]) == [[], []])
    }

    @Test func aTypedToolEndAfterATypelessStopKeepsItHidden() throws {
        let stop = hook("SubagentStop", ["agent_id": "x1", "agent_type": ""])
        #expect(try kinds([stop, toolEnd(type: "implementer")]) == [[], []])
    }

    @Test func theAgentCallNamingItShowsItWithoutAToolThatEnded() throws {
        let input: [String: Any] = ["subagent_type": "general-purpose", "description": "D", "prompt": "P"]
        let call = hook("PreToolUse", ["tool_name": "Agent", "tool_use_id": "T1", "tool_input": input])
        let post = hook("PostToolUse", ["tool_name": "Agent", "tool_use_id": "T1", "tool_input": input,
                                        "tool_response": ["agentId": "x1", "status": "completed"]])
        let spec = AgentSpec(type: "general-purpose", title: "D", prompt: "P")
        #expect(try kinds([call, toolStart(), toolEnd(), post]).last == [
            .toolFinished(agent: .root, callID: "T1"), .agentSpawned(id: "x1", parent: .root, spec: spec),
        ])
    }
}

// MARK: - Internal agents

/// An internal agent (no `SubagentStart`, no `agent_type`) that ran a tool, captured from a live spool.
private let internalAgentToolPayloads: [Data] = {
    let directory = Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures/claude-code/spool-2026-10-03-internal-agent-tool/events")
    let files = try! FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    return files.map { try! Data(contentsOf: directory.appendingPathComponent($0)) }
}()

/// The captured `PreToolUse` and `SubagentStop`, with the `PostToolUse` of the same call in between.
private let internalAgentToolUsePayloads: [Data] = {
    var post = try! JSONSerialization.jsonObject(with: internalAgentToolPayloads[0]) as! [String: Any]
    post["hook_event_name"] = "PostToolUse"
    post["tool_response"] = ["stdout": "", "stderr": "", "interrupted": false]
    return [internalAgentToolPayloads[0], json(post), internalAgentToolPayloads[2]]
}()

private func permutations<T>(_ items: [T]) -> [[T]] {
    guard items.count > 1 else { return [items] }
    return items.indices.flatMap { index in
        var rest = items
        let first = rest.remove(at: index)
        return permutations(rest).map { [first] + $0 }
    }
}

@Suite struct ClaudeCodeInternalAgentTests {
    private let internalAgent = AgentRef.subagent("afb31d63fec7d2988")

    private func adapter() -> ClaudeCodeAdapter {
        ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping())
    }

    /// The capture holds nothing but the internal agent, so nothing shows.
    @Test func anInternalAgentThatUsedAToolNeverShows() throws {
        let state = try replay(internalAgentToolPayloads, with: adapter())
        #expect(state.sessions.isEmpty)
    }

    @Test(arguments: permutations(Array(internalAgentToolPayloads.indices)))
    func anyArrivalOrderLeavesNoPhantom(order: [Int]) throws {
        try expectNoPhantom(order.map { internalAgentToolPayloads[$0] })
    }

    /// `PostToolBatch` is not a tool end for the adapter, so the fixture alone never
    /// sends the internal agent's tool end before its start. This adds the
    /// `PostToolUse` of the same call, derived from the captured `PreToolUse`.
    @Test(arguments: permutations(Array(internalAgentToolUsePayloads.indices)))
    func anyArrivalOrderWithAToolEndLeavesNoPhantom(order: [Int]) throws {
        try expectNoPhantom(order.map { internalAgentToolUsePayloads[$0] })
    }

    /// The captured typeless stop carries `background_tasks`, but an internal
    /// agent's stop stays unseen, its shell snapshot with it.
    @Test func anInternalAgentsStopListsNoShells() throws {
        let adapter = adapter()
        let events = try internalAgentToolPayloads.enumerated().flatMap { index, payload in
            try adapter.events(from: envelope(payload, at: index))
        }
        #expect(!events.contains { if case .backgroundShellsListed = $0.kind { true } else { false } })
    }

    /// The internal agent never identifies itself, so it never appears.
    private func expectNoPhantom(_ payloads: [Data]) throws {
        let adapter = adapter()
        var state = CollectiveState()
        for (index, payload) in payloads.enumerated() {
            for event in try adapter.events(from: envelope(payload, at: index)) {
                state.apply(event)
                #expect(state.sessions.values.allSatisfy { $0.agents[internalAgent] == nil })
            }
        }
        let agents = state.sessions.values.flatMap(\.agents.values)
        #expect(agents.allSatisfy { $0.id == .root || !$0.status.isActive })
    }
}

// MARK: - Meta files

@Suite struct FileSubagentMetaReaderTests {
    @Test func readsTheMetaFileNextToTheTranscript() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subagents = dir.appendingPathComponent("abc/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"agentType":"x","description":"Do it","toolUseId":"toolu_1","requestShape":"background"}"#.utf8)
            .write(to: subagents.appendingPathComponent("agent-a1.meta.json"))

        let reader = FileSubagentMetaReader()
        let meta = reader.meta(transcriptPath: dir.appendingPathComponent("abc.jsonl").path, agentID: "a1")
        #expect(meta == SubagentMeta(toolUseID: "toolu_1", description: "Do it", isBackground: true))
    }

    @Test func missingOrBrokenFilesGiveNil() throws {
        let reader = FileSubagentMetaReader()
        #expect(reader.meta(transcriptPath: "/does/not/exist.jsonl", agentID: "a1") == nil)
        #expect(reader.meta(transcriptPath: "/no-jsonl-suffix", agentID: "a1") == nil)
    }
}

// MARK: - Models

/// Run 16 of 2.1.289: two `Agent` calls, the first with `model: haiku`, the second inheriting.
private func run16Payloads() -> [Data] {
    run289Events("16-agent-model").map(\.payload)
}

/// The payloads of a 2.1.289 run in arrival order, by their `NNN` prefix.
private func run289Events(_ run: String) -> [(file: String, payload: Data)] {
    let directory = Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures/claude-code/2.1.289/\(run)/events")
    let files = try! FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    return files.map { (String($0.prefix(3)), try! Data(contentsOf: directory.appendingPathComponent($0))) }
}

@Suite struct ClaudeCodeModelTests {
    private let haiku = "claude-haiku-4-5-20251001"
    private let sonnet = "claude-sonnet-5-5"

    private func adapter() -> ClaudeCodeAdapter {
        ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping())
    }

    /// Run C2 of 2.1.285: start (001), `/model` (030), and the restart after
    /// `/compact` (032), which still names the model from before the switch.
    @Test func sessionStartsAndSwitchesReportTheModel() throws {
        let adapter = Run.background.adapter()
        var reported: [String: [AgentEvent.Kind]] = [:]
        let files = try FileManager.default.contentsOfDirectory(atPath: Run.background.directory.appendingPathComponent("events").path).sorted()
        for (file, payload) in zip(files, Run.background.payloads) {
            let models = try adapter.events(from: envelope(payload)).map(\.kind).filter {
                if case .modelChanged = $0 { return true } else { return false }
            }
            if !models.isEmpty { reported[String(file.prefix(3))] = models }
        }
        #expect(reported == [
            "001": [.modelChanged(to: haiku, from: nil)],
            "030": [.modelChanged(to: sonnet, from: haiku)],
            "032": [.modelChanged(to: haiku, from: nil)],
        ])
    }

    @Test func aSubagentCarriesTheModelItWasAskedForAndTheOneItRuns() throws {
        let state = try replay(run16Payloads(), with: adapter())
        let session = try #require(state.onlySession)
        #expect(session.model == sonnet)

        let chosen = try #require(session.agents[.subagent("a99b925b23945c344")])
        #expect(chosen.spec.modelAlias == "haiku")
        #expect(chosen.spec.modelID == haiku)
        let inherited = try #require(session.agents[.subagent("a2a34e739949f479b")])
        #expect(inherited.spec.modelAlias == nil)
        #expect(inherited.spec.modelID == sonnet)
    }

    /// Run C1 of 2.1.285: the `PostToolUse` naming the model (016, 018)
    /// comes after the foreground subagent's `SubagentStop` (015, 017).
    @Test func aForegroundSubagentGetsItsModelAfterItsStop() throws {
        let state = try replay(Run.headless.payloads, with: Run.headless.adapter())
        let subagents = try #require(state.onlySession).children(of: .root)
        #expect(subagents.count == 2)
        for agent in subagents {
            #expect(agent.status == .done)
            #expect(agent.spec.modelID == haiku)
            #expect(agent.spec.modelAlias == nil)
        }
    }
}

/// The model belongs to the `claude` process, not the session: `/clear`
/// carries it over to the new session, a resume doesn't (subspace contract §6,
/// "Session model"). S17 is one process; S18 a later one resuming S17's second session.
@Suite struct ClaudeCodeClearModelTests {
    private let haiku = "claude-haiku-4-5-20251001"
    private let sonnet = "claude-sonnet-5-5"
    private let first = SessionKey(source: source, sessionID: "31d88d15-f725-441b-8f42-88443f5fd7d1")
    private let second = SessionKey(source: source, sessionID: "53d29d64-7546-4aef-91e7-22dc7213f0bf")
    private let s17 = run289Events("17-model-clear")
    private let s18 = run289Events("18-continue-other-model")

    private struct Reported: Equatable {
        var session: SessionKey
        var kind: AgentEvent.Kind
    }

    /// The `modelChanged` events by `<run>-<file>`, replayed with one pid per run.
    private func reportedModels(
        _ runs: [(events: [(file: String, payload: Data)], pid: Int32)]
    ) throws -> [String: [Reported]] {
        let adapter = ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping())
        var reported: [String: [Reported]] = [:]
        var index = 0
        for (run, (events, pid)) in runs.enumerated() {
            for (file, payload) in events {
                let models = try adapter.events(from: envelope(payload, at: index, pid: pid)).filter {
                    if case .modelChanged = $0.kind { return true } else { return false }
                }
                if !models.isEmpty { reported["\(run)-\(file)"] = models.map { Reported(session: $0.session, kind: $0.kind) } }
                index += 1
            }
        }
        return reported
    }

    /// Stops after file `last` of the last run when given.
    private func replay(
        _ runs: [(events: [(file: String, payload: Data)], pid: Int32)], through last: String? = nil
    ) throws -> CollectiveState {
        let adapter = ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping())
        var state = CollectiveState()
        var index = 0
        for (run, (events, pid)) in runs.enumerated() {
            for (file, payload) in events {
                for event in try adapter.events(from: envelope(payload, at: index, pid: pid)) { state.apply(event) }
                index += 1
                if run == runs.count - 1, file == last { return state }
            }
        }
        return state
    }

    @Test func clearCarriesTheProcessModelOverToTheNewSession() throws {
        let reported = try reportedModels([(s17, 1701)])
        #expect(reported == [
            "0-002": [Reported(session: first, kind: .modelChanged(to: haiku, from: nil))],
            "0-011": [Reported(session: first, kind: .modelChanged(to: sonnet, from: haiku))],
            "0-015": [Reported(session: second, kind: .modelChanged(to: sonnet, from: nil))],
        ])
    }

    /// 014 (`SessionEnd`, `clear`) and 015 (`SessionStart`, `clear`) come
    /// within milliseconds and may arrive either way round.
    @Test func clearCarriesTheModelOverWhenTheNewStartComesFirst() throws {
        var swapped = s17
        let end = try #require(swapped.firstIndex { $0.file == "014" })
        let start = try #require(swapped.firstIndex { $0.file == "015" })
        swapped.swapAt(end, start)

        let reported = try reportedModels([(swapped, 1701)])
        #expect(reported["0-015"] == [Reported(session: second, kind: .modelChanged(to: sonnet, from: nil))])
    }

    @Test func theClearedSessionShowsTheCarriedModelWithoutASwitch() throws {
        let state = try replay([(s17, 1701)])
        let session = try #require(state.sessions[second])
        #expect(session.model == sonnet)
        #expect(session.lastModelSwitch == nil)
    }

    @Test func aResumedSessionInANewProcessHasNoModel() throws {
        #expect(try reportedModels([(s18, 1801)]).isEmpty)
        #expect(try #require(replay([(s18, 1801)]).sessions[second]).model == nil)
    }

    /// S18 resumes S17's second session, which last ran on Sonnet, in a new
    /// process; also when that process got the same pid.
    @Test func aResumeAfterTheEarlierProcessCarriesNothingOver() throws {
        for pid: Int32 in [1801, 1701] {
            let reported = try reportedModels([(s17, 1701), (s18, pid)])
            #expect(reported.keys.filter { $0.hasPrefix("1-") }.isEmpty, "pid \(pid)")
        }
    }

    /// S17 ends the session with 022; S18 continues it in another process.
    @Test func aResumedSessionShowsUpAgainAsAFreshRun() throws {
        let runs = [(s17, Int32(1701)), (s18, Int32(1801))]
        let ended = try #require(replay([(s17, 1701)]).sessions[second])
        #expect(ended.root.status == .done)
        #expect(ended.model == sonnet)

        let resumed = try #require(replay(runs, through: "003").sessions[second])
        #expect(resumed.endedAt == nil)
        #expect(resumed.pid == 1801)
        #expect(resumed.root.status == .waiting)
        #expect(resumed.model == nil)
        #expect(resumed.lastModelSwitch == nil)
        // The resume's start is envelope number `s17.count`, one a second.
        #expect(resumed.startedAt == t0.addingTimeInterval(TimeInterval(s17.count)))
        #expect(resumed.startedAt > ended.startedAt)

        #expect(try replay(runs, through: "008").sessions[second]?.root.status == .working)
        #expect(try replay(runs, through: "009").sessions[second]?.root.status == .waiting)

        let done = try #require(replay(runs, through: "011").sessions[second])
        #expect(done.root.status == .done)
        #expect(done.endedAt != nil)
    }

    @Test func aResumedSessionIsCheckedAgainstItsNewProcess() throws {
        var state = try replay([(s17, 1701), (s18, 1801)], through: "009")
        let start = try #require(state.sessions[second]).startedAt
        // 1701 is gone; 1801 started just before its first hook, long after S17 began.
        state.markStale(now: start.addingTimeInterval(60), silenceTimeout: 600, waitingTimeout: 600) {
            $0 == 1801 ? start.addingTimeInterval(-0.5) : nil
        }
        let session = try #require(state.sessions[second])
        #expect(session.endedAt == nil)
        #expect(session.root.status == .waiting)
    }

    @Test func aClearWithoutAKnownModelCarriesNothingOver() throws {
        let start = try #require(s17.first { $0.file == "015" })
        #expect(try reportedModels([([start], 1701)]).isEmpty)
    }

    /// S17 ends with 022 (`prompt_input_exit`); a `clear` start on that pid afterwards
    /// belongs to a new process that reused it.
    @Test func aProcessEndForgetsItsModel() throws {
        let start = try #require(s17.first { $0.file == "015" })
        let reported = try reportedModels([(s17, 1701), ([start], 1701)])
        #expect(reported["1-015"] == nil)
    }

    /// A crashed process sends no `SessionEnd`. When a new process reuses its pid,
    /// starts without a model and then clears, the dead process's model must not
    /// carry over.
    @Test func aStartWithoutAModelForgetsACrashedProcessModel() throws {
        let crashed = s17.filter { ["002", "011"].contains($0.file) }
        let resume = try #require(s18.first { $0.file == "003" })
        let clear = try #require(s17.first { $0.file == "015" })
        let reported = try reportedModels([(crashed, 1701), ([resume], 1701), ([clear], 1701)])
        #expect(reported["0-011"] != nil)
        #expect(reported["2-015"] == nil)
    }
}
