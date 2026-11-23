import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// MARK: - Helpers

private let t0 = Date(timeIntervalSince1970: 1_000)
private let home = URL(fileURLWithPath: "/Users/user", isDirectory: true)

/// A recorded run of Codex 0.159.3.
enum CodexRun: String, CaseIterable {
    case headless = "1-headless-parallel-reused-child-failure"
    case daemonCompact = "2-daemon-permission-compact"
    case manualPermission = "3-manual-permission-remembered-rejection"
    case pretoolInterruptRecovery = "4-pretool-interrupt-recovery"
    case pretoolInterruptExit = "5-pretool-interrupt-exit"
    case sleepInterruptRecovery = "6-running-sleep-recovery"
    case sleepInterruptExit = "7-running-sleep-exit"
    case resume = "8-resume"
    case ephemeral = "9-ephemeral"
    case cwdWithSpaces = "10-cwd-with-spaces"

    var directory: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/codex/0.159.3/\(rawValue)")
    }

    /// Raw payloads in delivery order (`NNN-<hook>.json`), keyed by file name.
    var files: [(name: String, payload: Data)] {
        let events = directory.appendingPathComponent("events")
        let names = try! FileManager.default.contentsOfDirectory(atPath: events.path).sorted()
        return names.map { ($0, try! Data(contentsOf: events.appendingPathComponent($0))) }
    }

    var payloads: [Data] { files.map(\.payload) }

    func payload(_ prefix: String) -> Data { files.first { $0.name.hasPrefix(prefix) }!.payload }

    /// The `session_meta` lines of the run's rollouts, as a reader on this
    /// machine would find them. The real rollout paths end in `<thread id>.jsonl`.
    var rollouts: [String: RolloutMeta] {
        let url = directory.appendingPathComponent("rollouts/session_meta.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: RolloutMeta] = [:]
        for line in text.split(separator: "\n") {
            let meta = FileRolloutMetaReader.parse(Data(line.utf8))!
            result[meta.id] = meta
        }
        return result
    }

    func adapter(withRollouts: Bool = true) -> CodexAdapter {
        CodexAdapter(rolloutReader: StubRolloutReader(withRollouts ? rollouts : [:]), mapping: bundledMapping())
    }
}

/// A recorded run of Codex 0.167.0, without children: who answers its permission requests.
enum CodexReviewRun: String, CaseIterable {
    case autoApprovals = "1-auto-review-approvals"
    case autoRejection = "2-auto-review-rejection"
    case manual = "3-manual-review-approval-denial"
    case multiLine = "5-multiline-command"

    var directory: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/codex/0.167.0/\(rawValue)")
    }

    var files: [(name: String, payload: Data)] {
        let events = directory.appendingPathComponent("events")
        let names = try! FileManager.default.contentsOfDirectory(atPath: events.path).sorted()
        return names.map { ($0, try! Data(contentsOf: events.appendingPathComponent($0))) }
    }

    /// The edited excerpt of the run's rollout: every `turn_context` record, reduced.
    var excerpt: URL { directory.appendingPathComponent("rollouts/excerpt.jsonl") }

    /// The real file reader, pointed at the excerpt: the payloads name the
    /// rollout on the capture machine.
    func adapter() -> CodexAdapter {
        CodexAdapter(rolloutReader: RedirectedRollouts(to: excerpt.path), mapping: bundledMapping())
    }
}

/// The envelope's pid is the hook's parent process, here something the adapter must ignore.
private func envelope(_ payload: Data, at index: Int = 0) -> Envelope {
    Envelope(source: "codex", pid: 4242, payload: payload, receivedAt: t0.addingTimeInterval(TimeInterval(index)))
}

private func replay(_ payloads: [Data], with adapter: CodexAdapter) throws -> CollectiveState {
    var state = CollectiveState()
    for (index, payload) in payloads.enumerated() {
        for event in try adapter.events(from: envelope(payload, at: index)) { state.apply(event) }
    }
    return state
}

private extension CollectiveState {
    var onlySession: Session? { sessions.count == 1 ? sessions.values.first : nil }
}

private let headlessSession = "01a0f6f3-e902-7f10-9fdd-9a6e4d38a220"
private let alpha = "01a0f6f4-21c7-7573-bb07-228ea9311563"
private let beta = "01a0f6f4-3b45-7802-90cd-9b2414112d38"
private let alphaFirstTurn = "\(alpha)/01a0f6f4-221c-7fc3-bb59-d8d230204ff4"
private let alphaSecondTurn = "\(alpha)/01a0f6f4-804b-7571-a045-1397b0fe2a47"
private let betaTurn = "\(beta)/01a0f6f4-3b98-7290-996b-be39f5a0ee09"

// MARK: - Fixture runs

@Suite struct CodexFixtureTests {
    @Test func headlessRunShowsOneRowPerChildTurn() throws {
        let state = try replay(CodexRun.headless.payloads, with: CodexRun.headless.adapter())
        let session = try #require(state.onlySession)
        #expect(session.key == SessionKey(source: "codex", sessionID: headlessSession))
        #expect(session.root.status == .waiting)
        #expect(session.model == "gpt-6.1-sol")

        let rows = session.agents.filter { $0.key != .root }
        #expect(Set(rows.keys) == [.subagent(alphaFirstTurn), .subagent(alphaSecondTurn), .subagent(betaTurn)])
        for row in rows.values {
            #expect(row.parent == .root)
            #expect(row.status == .done)
            #expect(row.spec.type == "default")
            #expect(row.spec.modelID == "gpt-5.6-luna")
            #expect(row.spec.prompt == nil)
            #expect(row.spec.isBackground == nil)
        }
        #expect(rows[.subagent(alphaFirstTurn)]?.spec.title == "alpha")
        #expect(rows[.subagent(alphaSecondTurn)]?.spec.title == "alpha")
        #expect(rows[.subagent(betaTurn)]?.spec.title == "beta")
    }

    @Test func withoutRolloutsTheRowsStayUntitled() throws {
        let state = try replay(CodexRun.headless.payloads, with: CodexRun.headless.adapter(withRollouts: false))
        let session = try #require(state.onlySession)
        let rows = session.agents.filter { $0.key != .root }
        #expect(Set(rows.keys) == [.subagent(alphaFirstTurn), .subagent(alphaSecondTurn), .subagent(betaTurn)])
        #expect(rows.values.allSatisfy { $0.spec.title == nil && $0.status == .done && $0.parent == .root })
        #expect(session.root.status == .waiting)
    }

    @Test func aRolloutThatAppearsLaterTitlesTheRowOnALaterEvent() throws {
        let reader = StubRolloutReader()
        let adapter = CodexAdapter(rolloutReader: reader, mapping: bundledMapping())
        let files = CodexRun.headless.files
        var state = CollectiveState()
        // Through 012, the root's `spawn_agent` for beta; alpha's first turn runs.
        for (index, file) in files.prefix(12).enumerated() {
            for event in try adapter.events(from: envelope(file.payload, at: index)) { state.apply(event) }
        }
        #expect(state.onlySession?.agents[.subagent(alphaFirstTurn)]?.spec.title == nil)

        reader.set(CodexRun.headless.rollouts)
        // 013 is a root event; the retry still reads alpha's rollout.
        for event in try adapter.events(from: envelope(files[12].payload, at: 12)) { state.apply(event) }
        #expect(state.onlySession?.agents[.subagent(alphaFirstTurn)]?.spec.title == "alpha")
    }

    @Test(arguments: [CodexRun.manualPermission, .pretoolInterruptRecovery, .pretoolInterruptExit, .sleepInterruptExit, .cwdWithSpaces])
    func anInterruptLeavesTheRootWaitingWithoutTool(run: CodexRun) throws {
        let state = try replay(run.payloads, with: run.adapter())
        let session = try #require(state.onlySession)
        #expect(session.root.status == .waiting)
        #expect(session.root.currentTool == nil)
    }

    /// 003 interrupts the first turn before any tool call; 007 ends the next one.
    @Test func theRootsTurnEndsSayWhetherTheTurnWasInterrupted() throws {
        let run = CodexRun.pretoolInterruptRecovery
        let adapter = run.adapter()
        var outcomes: [String: TurnOutcome] = [:]
        for (index, file) in run.files.enumerated() {
            for event in try adapter.events(from: envelope(file.payload, at: index)) {
                if case let .turnEnded(outcome) = event.kind { outcomes[String(file.name.prefix(3))] = outcome }
            }
        }
        #expect(outcomes == ["003": .interrupted, "007": .completed])
    }

    @Test func aLatePostAfterTheNextStopLeavesTheRootWaiting() throws {
        let run = CodexRun.sleepInterruptRecovery
        let state = try replay(run.payloads, with: run.adapter())
        let session = try #require(state.onlySession)
        #expect(session.key.sessionID == "01a0f735-3b55-7ca0-848e-6d8a30065041")
        #expect(session.root.status == .waiting)
        #expect(session.root.currentTool == nil)
    }

    @Test func aLatePreForAnInterruptedRootTurnStartsNoTool() throws {
        let run = CodexRun.sleepInterruptRecovery
        let adapter = run.adapter()
        var state = CollectiveState()
        func deliver(_ prefix: String, at second: Int) throws {
            for event in try adapter.events(from: envelope(run.payload(prefix), at: second)) { state.apply(event) }
        }
        // The `sleep 30` call's pre (003) arrives after the next prompt (005),
        // when the root works again: its turn was interrupted (004) before,
        // so the call shows as no tool.
        for (prefix, second) in [("001", 0), ("002", 1), ("004", 3), ("005", 4), ("003", 2)] {
            try deliver(prefix, at: second)
        }
        var session = try #require(state.onlySession)
        #expect(session.root.status == .working)
        #expect(session.root.currentTool == nil)

        // Its real post (009) ends no other tool either.
        try deliver("009", at: 8)
        session = try #require(state.onlySession)
        #expect(session.root.currentTool == nil)
    }

    @Test func aLatePreForAFinishedChildTurnStartsNoTool() throws {
        let run = CodexRun.headless
        let adapter = run.adapter()
        for payload in run.payloads { _ = try adapter.events(from: envelope(payload)) }
        // 010 is alpha's first `printf`, of the turn its stop 014 ended.
        let late = try adapter.events(from: envelope(run.payload("010"))).map(\.kind)
        #expect(!late.contains { if case .toolStarted = $0 { true } else { false } })
    }

    @Test func aResumedSessionKeepsItsId() throws {
        let state = try replay(CodexRun.resume.payloads, with: CodexRun.resume.adapter())
        let session = try #require(state.onlySession)
        #expect(session.key == SessionKey(source: "codex", sessionID: "01a0f71a-7656-7c02-8461-8d00e7f552ce"))
        #expect(session.root.status == .waiting)
    }

    /// The capture holds only the resumed run, so the earlier run's end is made up.
    @Test func aResumeAfterAnEndBringsTheSessionBack() throws {
        let run = CodexRun.resume
        let key = SessionKey(source: "codex", sessionID: "01a0f71a-7656-7c02-8461-8d00e7f552ce")
        var state = CollectiveState()
        state.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(-60), kind: .promptSubmitted("before")))
        state.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(-10), kind: .sessionEnded))
        #expect(state.sessions[key]?.root.status == .done)

        let adapter = run.adapter()
        for (index, file) in run.files.enumerated() {
            for event in try adapter.events(from: envelope(file.payload, at: index)) { state.apply(event) }
            let session = try #require(state.sessions[key])
            #expect(session.endedAt == nil, "\(file.name)")
            if file.name.hasPrefix("001") {
                #expect(session.root.status == .waiting)
                #expect(session.root.spec.prompt == nil)
                #expect(session.startedAt == t0)
            }
            if file.name.hasPrefix("002") { #expect(session.root.status == .working) }
        }
        #expect(state.onlySession?.root.status == .waiting)
    }

    @Test func anEphemeralSessionWithoutRolloutWorks() throws {
        let state = try replay(CodexRun.ephemeral.payloads, with: CodexRun.ephemeral.adapter())
        let session = try #require(state.onlySession)
        #expect(session.key.sessionID == "01a0f73b-6f30-7ec0-9468-59bc2437d062")
        #expect(session.root.status == .waiting)
    }

    @Test func compactionKeepsTheSessionAndPermissionRequestsOnlyAsk() throws {
        let run = CodexRun.daemonCompact
        let adapter = run.adapter()
        var state = CollectiveState()
        for (index, file) in run.files.enumerated() {
            let events = try adapter.events(from: envelope(file.payload, at: index))
            if file.name.contains("PermissionRequest") {
                #expect(events.count == 1, "\(file.name)")
                #expect(events.allSatisfy { if case .permissionRequested = $0.kind { true } else { false } }, "\(file.name)")
            }
            for event in events { state.apply(event) }
        }
        let session = try #require(state.onlySession)
        #expect(session.key.sessionID == "01a0f71a-7656-7c02-8461-8d00e7f552ce")
        #expect(session.root.status == .waiting)
        #expect(session.model == "gpt-6.1-sol")
    }

    /// Codex sends neither a pid nor an end, so after its turn the session
    /// only waits; the short silence limit would drop it.
    @Test func aSessionWaitingAfterItsTurnOutlastsTheSilenceTimeout() throws {
        var state = try replay(CodexRun.daemonCompact.payloads, with: CodexRun.daemonCompact.adapter())
        let session = try #require(state.onlySession)
        #expect(session.root.status == .waiting)
        let last = session.lastActivity

        state.markStale(now: last.addingTimeInterval(40 * 60), silenceTimeout: 30 * 60, waitingTimeout: 12 * 3_600) { _ in nil }
        #expect(state.onlySession?.root.status == .waiting)
        #expect(state.onlySession?.endedAt == nil)
        state.markStale(now: last.addingTimeInterval(12 * 3_600 + 1), silenceTimeout: 30 * 60, waitingTimeout: 12 * 3_600) { _ in nil }
        #expect(state.onlySession?.root.status == .stale)
    }

    @Test(arguments: CodexRun.allCases)
    func neverPassesTheEnvelopePid(run: CodexRun) throws {
        let adapter = run.adapter()
        var starts = 0
        for payload in run.payloads {
            for event in try adapter.events(from: envelope(payload)) {
                guard case let .sessionStarted(_, pid) = event.kind else { continue }
                starts += 1
                #expect(pid == nil)
            }
        }
        #expect(starts > 0)
    }

    /// A session whose start was never seen still gets its directory, but
    /// never the envelope pid.
    @Test func withoutItsStartTheSessionLearnsOnlyItsDirectory() throws {
        let run = CodexRun.headless
        let adapter = run.adapter()
        let capturedCWD = "/Users/user/dev/subspace/tools/hook-capture/codex"
        var state = CollectiveState()
        for (index, file) in run.files.enumerated() where !file.name.hasSuffix("-SessionStart.json") {
            for event in try adapter.events(from: envelope(file.payload, at: index)) {
                #expect(event.cwd == capturedCWD, "\(file.name)")
                #expect(event.pid == nil, "\(file.name)")
                state.apply(event)
            }
        }
        let session = try #require(state.onlySession)
        #expect(session.cwd == capturedCWD)
        #expect(session.pid == nil)
    }

    @Test func theRootModelIsEmittedOncePerChange() throws {
        let adapter = CodexRun.headless.adapter()
        let models = try CodexRun.headless.payloads.flatMap { try adapter.events(from: envelope($0)) }.compactMap {
            if case let .modelChanged(to, _) = $0.kind { to } else { nil }
        }
        #expect(models == ["gpt-6.1-sol"])
    }
}

// MARK: - Replies

@Suite struct CodexReplyTests {
    private let run = CodexRun.headless

    /// The events of the hook file starting with `prefix`, after everything before it.
    private func kinds(of prefix: String) throws -> [AgentEvent.Kind] {
        let files = run.files
        let index = try #require(files.firstIndex { $0.name.hasPrefix(prefix) })
        let adapter = run.adapter()
        for (offset, file) in files.prefix(index).enumerated() { _ = try adapter.events(from: envelope(file.payload, at: offset)) }
        return try adapter.events(from: envelope(files[index].payload, at: index)).map(\.kind)
    }

    /// `last_assistant_message` as the captured payload has it.
    private func message(of prefix: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: run.payload(prefix)) as? [String: Any]
        return try #require(object?["last_assistant_message"] as? String)
    }

    private func replies(_ session: Session) -> [AgentRef: String] {
        session.agents.compactMapValues(\.reply)
    }

    @Test func aChildTurnsStopCarriesItsResultRightBeforeItsEnd() throws {
        let text = "Command output:\n\n```text\nalpha\n```\n\nExit code: `0`"
        #expect(try message(of: "014") == text)
        #expect(try kinds(of: "014").suffix(2) == [.replied(agent: .subagent(alphaFirstTurn), text), .agentFinished(id: alphaFirstTurn)])
    }

    @Test func theRootsStopCarriesItsReplyRightBeforeTheTurnEnds() throws {
        let text = try message(of: "028")
        #expect(text.hasPrefix("- `pwd`: "))
        #expect(try kinds(of: "028").suffix(2) == [.replied(agent: .root, text), .turnEnded(.completed)])
    }

    @Test func aStopForAClosedRowCarriesNoReply() throws {
        let adapter = run.adapter()
        for payload in run.payloads { _ = try adapter.events(from: envelope(payload)) }
        #expect(try adapter.events(from: envelope(run.payload("014"))).isEmpty)
    }

    @Test func anInterruptCarriesNoReply() throws {
        // 004 is the `Interrupt` of the turn; Codex sends no message with it.
        let interrupted = CodexRun.sleepInterruptRecovery
        let kinds = try interrupted.adapter().events(from: envelope(interrupted.payload("004"))).map(\.kind)
        #expect(kinds.contains(.turnEnded(.interrupted)))
        #expect(!kinds.contains { if case .replied = $0 { true } else { false } })
    }

    @Test func aRunLeavesTheLastReplyOfEveryRow() throws {
        let session = try #require(try replay(run.payloads, with: run.adapter()).onlySession)
        #expect(replies(session) == [
            .root: try message(of: "028"),
            .subagent(alphaFirstTurn): try message(of: "014"),
            .subagent(betaTurn): try message(of: "019"),
            .subagent(alphaSecondTurn): try message(of: "026"),
        ])
    }

    /// Hooks are async, so neighbors swap. Shuffle within windows of three
    /// events and expect the same replies. Only this run: with several root
    /// turns a stop swapped behind the next prompt rightly reads as that
    /// turn's reply.
    @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8])
    func shuffledArrivalGivesTheSameReplies(seed: Int) throws {
        let ordered = run.payloads
        let reference = replies(try #require(try replay(ordered, with: run.adapter()).onlySession))

        var next = UInt64(seed) &* 6364136223846793005 &+ 1442695040888963407
        func random(_ upper: Int) -> Int {
            next = next &* 6364136223846793005 &+ 1442695040888963407
            return Int((next >> 33) % UInt64(upper))
        }
        var shuffled: [Data] = []
        for start in stride(from: 0, to: ordered.count, by: 3) {
            var window = Array(ordered[start..<min(start + 3, ordered.count)])
            for i in stride(from: window.count - 1, to: 0, by: -1) { window.swapAt(i, random(i + 1)) }
            shuffled += window
        }

        let session = try #require(try replay(shuffled, with: run.adapter()).onlySession)
        #expect(replies(session) == reference)
        #expect(Set(session.agents.keys) == [.root, .subagent(alphaFirstTurn), .subagent(alphaSecondTurn), .subagent(betaTurn)])
    }
}

@Suite struct CodexToolDetailTests {
    private func toolStarts(_ payload: Data) throws -> [ToolActivity] {
        try CodexRun.headless.adapter().events(from: envelope(payload)).compactMap {
            if case let .toolStarted(_, tool, _, _) = $0.kind { tool } else { nil }
        }
    }

    @Test func shellCallsShowTheirCommand() throws {
        #expect(try toolStarts(CodexRun.headless.payload("005")) == [ToolActivity(name: "Bash", detail: "sh -c \"exit 7\"")])
    }

    @Test func collaborationCallsShowTheirTaskNotTheEncryptedMessage() throws {
        #expect(try toolStarts(CodexRun.headless.payload("007")) == [ToolActivity(name: "collaborationspawn_agent", detail: "alpha")])
        #expect(try toolStarts(CodexRun.headless.payload("021")) == [ToolActivity(name: "collaborationfollowup_task", detail: "alpha")])
        #expect(try toolStarts(CodexRun.headless.payload("018")) == [ToolActivity(name: "collaborationwait_agent", detail: nil)])
    }

    @Test func aChildToolStartsOnItsTurnRow() throws {
        // A fresh session's state says its terminal once, here that it has none.
        let kinds = try CodexRun.headless.adapter().events(from: envelope(CodexRun.headless.payload("024"))).map(\.kind)
            .filter { if case .terminalReported = $0 { false } else { true } }
        #expect(kinds.first == .agentSpawned(id: alphaSecondTurn, parent: .root, spec: AgentSpec(type: "default", title: "alpha", modelID: "gpt-5.6-luna")))
        #expect(kinds.last == .toolStarted(agent: .subagent(alphaSecondTurn), ToolActivity(name: "Bash", detail: "printf 'alpha-again\\n'"),
                                           callID: "exec-486051b9-18e3-4878-b980-dd55e6892c1f"))
    }
}

/// Adapter seam: what pairs a tool call's start with its end and names a
/// pending permission.
@Suite struct CodexToolCallTests {
    /// The events of the hook file starting with `prefix`, after everything before it.
    private func kinds(of prefix: String, in run: CodexRun) throws -> [AgentEvent.Kind] {
        let files = run.files
        let index = try #require(files.firstIndex { $0.name.hasPrefix(prefix) })
        let adapter = run.adapter()
        for (offset, file) in files.prefix(index).enumerated() { _ = try adapter.events(from: envelope(file.payload, at: offset)) }
        return try adapter.events(from: envelope(files[index].payload, at: index)).map(\.kind)
    }

    @Test func aToolsStartAndEndCarryTheSameCallIDWithoutADuration() throws {
        let call = "exec-abfbbd66-be4c-4e84-99f2-99e6259de055"
        let write = ToolActivity(name: "Bash", detail: "printf 'permission-approved\\n' > captures/permission-probe")
        #expect(try kinds(of: "003", in: .daemonCompact) == [.toolStarted(agent: .root, write, callID: call)])
        #expect(try kinds(of: "005", in: .daemonCompact) == [.toolFinished(agent: .root, callID: call, duration: nil)])
    }

    @Test func parallelCallsKeepTheirOwnIDs() throws {
        let pwd = "exec-aa80766c-6a0f-4587-a167-b5966e313034"
        let exit7 = "exec-d15e49e3-e040-4a81-97b1-c735026e92ee"
        #expect(try kinds(of: "003", in: .headless) == [.toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "pwd"), callID: pwd)])
        #expect(try kinds(of: "004", in: .headless) == [.toolFinished(agent: .root, callID: pwd)])
        #expect(try kinds(of: "005", in: .headless) == [.toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "sh -c \"exit 7\""), callID: exit7)])
        #expect(try kinds(of: "006", in: .headless) == [.toolFinished(agent: .root, callID: exit7)])
    }

    @Test func aChildToolCarriesItsCallID() throws {
        let call = "exec-486051b9-18e3-4878-b980-dd55e6892c1f"
        #expect(try kinds(of: "024", in: .headless).last
            == .toolStarted(agent: .subagent(alphaSecondTurn), ToolActivity(name: "Bash", detail: "printf 'alpha-again\\n'"), callID: call))
        #expect(try kinds(of: "025", in: .headless).last == .toolFinished(agent: .subagent(alphaSecondTurn), callID: call))
    }

    @Test func aPermissionRequestNamesItsCommand() throws {
        #expect(try kinds(of: "004", in: .daemonCompact)
            == [.permissionRequested(agent: .root, ToolActivity(name: "Bash", detail: "printf 'permission-approved\\n' > captures/permission-probe"))])
        // Delivered before its call's start.
        #expect(try kinds(of: "008", in: .daemonCompact)
            == [.permissionRequested(agent: .root, ToolActivity(name: "Bash", detail: "printf 'permission-denied\\n' > captures/permission-denied-probe"))])
    }

    @Test func aManualRequestNamesItsCommandWhateverTheAnswer() throws {
        let approved = ToolActivity(name: "Bash", detail: "printf 'manual-approved\\n' > captures/manual-permission-approved-probe")
        let denied = ToolActivity(name: "Bash", detail: "printf 'manual-denied\\n' > captures/manual-permission-denied-probe")
        #expect(try kinds(of: "003", in: .manualPermission) == [.permissionRequested(agent: .root, approved)])
        #expect(try kinds(of: "008", in: .manualPermission) == [.permissionRequested(agent: .root, denied)])
        #expect(try kinds(of: "012", in: .manualPermission) == [.permissionRequested(agent: .root, approved)])
    }

    /// The captured request of 0.167.0 (`5-multiline-command`, 004): only the
    /// request carries the whole command, for the popover's command box; the
    /// call's start (003) and the request's own detail stay one line.
    @Test func aCapturedMultiLineRequestCarriesTheWholeCommand() throws {
        let run = CodexReviewRun.multiLine
        let adapter = run.adapter()
        var kindsByFile: [String: [AgentEvent.Kind]] = [:]
        for (index, file) in run.files.enumerated() {
            kindsByFile[String(file.name.prefix(3))] = try adapter.events(from: envelope(file.payload, at: index)).map(\.kind)
        }
        let whole = "cat > captures/multiline-probe.txt <<'EOF'\nfirst line\nsecond line\nthird line\nEOF"
        let first = "cat > captures/multiline-probe.txt <<'EOF'"
        let start = try #require(kindsByFile["003"])
        guard case let .toolStarted(_, tool, _, _)? = start.first, start.count == 1 else {
            Issue.record("no single tool start: \(start)")
            return
        }
        #expect(tool == ToolActivity(name: "Bash", detail: first))
        #expect(kindsByFile["004"] == [.permissionRequested(agent: .root, ToolActivity(name: "Bash", detail: first, fullDetail: whole))])
    }

    /// The captured request 004 with `command` in place of its own.
    private func request(command: String) throws -> [AgentEvent.Kind] {
        let run = CodexRun.daemonCompact
        var object = try JSONSerialization.jsonObject(with: run.payload("004")) as! [String: Any]
        object["tool_input"] = ["command": command]
        let adapter = run.adapter()
        for file in run.files.prefix(while: { !$0.name.hasPrefix("004") }) { _ = try adapter.events(from: envelope(file.payload)) }
        return try adapter.events(from: envelope(JSONSerialization.data(withJSONObject: object))).map(\.kind)
    }

    /// Blank lines around a one-line command would show as empty lines in the box.
    @Test func aSingleLineRequestWithBlankLinesAroundItCarriesNoWholeCommand() throws {
        #expect(try request(command: "\n\nls -la\n") == [.permissionRequested(agent: .root, ToolActivity(name: "Bash", detail: "ls -la"))])
    }

    /// Spaces around a one-line command are no second version of it; the
    /// detail stays as tool starts have it.
    @Test func aSingleLineRequestWithSpacesAroundItCarriesNoWholeCommand() throws {
        #expect(try request(command: " ls -la ") == [.permissionRequested(agent: .root, ToolActivity(name: "Bash", detail: " ls -la "))])
    }

    @Test func aBlankRequestCarriesNoWholeCommand() throws {
        let kinds = try request(command: "  \n \t ")
        guard case let .permissionRequested(_, tool)? = kinds.first, kinds.count == 1 else {
            Issue.record("no single request: \(kinds)")
            return
        }
        #expect(tool.fullDetail == nil)
    }

    @Test func aMultiLineRequestCarriesTheWholeCommandWithoutBlankLinesAround() throws {
        #expect(try request(command: "\ncat <<EOF\n\nsecret\nEOF\n\n")
            == [.permissionRequested(agent: .root, ToolActivity(name: "Bash", detail: "cat <<EOF", fullDetail: "cat <<EOF\n\nsecret\nEOF"))])
    }

    @Test func aCapturedSingleLineRequestCarriesNoWholeCommand() throws {
        let kinds = try kinds(of: "004", in: .daemonCompact)
        guard case let .permissionRequested(_, tool)? = kinds.first else {
            Issue.record("no request: \(kinds)")
            return
        }
        #expect(tool.fullDetail == nil)
    }

    @Test func aLateRequestForAnInterruptedRootTurnIsDropped() throws {
        let run = CodexRun.manualPermission
        let adapter = run.adapter()
        // The interrupt (010) of the turn that asked in 008.
        for prefix in ["001", "002", "006", "007", "010"] { _ = try adapter.events(from: envelope(run.payload(prefix))) }
        #expect(try adapter.events(from: envelope(run.payload("008"))).isEmpty)
    }

    /// No captured run has a child asking for permission; this is the captured
    /// child start 024 turned into the request Codex sends for it.
    @Test func aChildsRequestIsItsTurnRows() throws {
        let run = CodexRun.headless
        var object = try JSONSerialization.jsonObject(with: run.payload("024")) as! [String: Any]
        object["hook_event_name"] = "PermissionRequest"
        object["tool_use_id"] = nil
        let adapter = run.adapter()
        for file in run.files.prefix { !$0.name.hasPrefix("024") } { _ = try adapter.events(from: envelope(file.payload)) }
        let kinds = try adapter.events(from: envelope(JSONSerialization.data(withJSONObject: object))).map(\.kind)
        #expect(kinds.last == .permissionRequested(agent: .subagent(alphaSecondTurn), ToolActivity(name: "Bash", detail: "printf 'alpha-again\\n'")))
    }
}

@Suite final class FileRolloutMetaReaderTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rollouts-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func rollout(_ text: String) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try Data(text.utf8).write(to: url)
        return url.path
    }

    @Test func readsTheChildFromTheFirstLine() throws {
        let lines = try String(contentsOf: CodexRun.headless.directory.appendingPathComponent("rollouts/session_meta.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        let path = try rollout(lines[1] + "\n{\"type\":\"turn_context\"}\n")
        #expect(FileRolloutMetaReader().meta(rolloutPath: path) == RolloutMeta(
            id: alpha, parentThreadID: headlessSession, agentPath: "/root/alpha", nickname: "Copernicus"
        ))
    }

    @Test func aMissingFileOrUnfinishedLineIsNoAnswerYet() throws {
        #expect(FileRolloutMetaReader().meta(rolloutPath: "/nonexistent/rollout.jsonl") == nil)
        #expect(FileRolloutMetaReader().meta(rolloutPath: try rollout("{\"type\":\"session_meta\",\"payload\":{\"id\":\"a\"}}")) == nil)
        #expect(FileRolloutMetaReader().meta(rolloutPath: try rollout("{\"type\":\"turn_context\"}\n")) == nil)
    }
}

/// Codex's automatic reviewer answers a request, not the user: it is no wait
/// for permission (contract §6). Replayed through adapter and store.
@Suite struct CodexReviewerTests {
    private struct Step {
        var name: String
        var kinds: [AgentEvent.Kind]
        var session: Session
    }

    /// Every event of the run and the session right after it.
    private func steps(_ files: [(name: String, payload: Data)], with adapter: CodexAdapter) throws -> [Step] {
        var state = CollectiveState()
        var steps: [Step] = []
        for (index, file) in files.enumerated() {
            let events = try adapter.events(from: envelope(file.payload, at: index))
            for event in events { state.apply(event) }
            steps.append(Step(name: file.name, kinds: events.map(\.kind), session: try #require(state.onlySession)))
        }
        return steps
    }

    private func isPermissionRequest(_ kind: AgentEvent.Kind) -> Bool {
        if case .permissionRequested = kind { true } else { false }
    }

    @Test(arguments: [CodexReviewRun.autoApprovals, .autoRejection])
    func requestsTheAutomaticReviewerAnswersNeverWait(run: CodexReviewRun) throws {
        let steps = try steps(run.files, with: run.adapter())
        for step in steps {
            #expect(!step.session.awaitsPermission, "\(step.name)")
            #expect(!step.kinds.contains(where: isPermissionRequest), "\(step.name)")
        }
    }

    /// The card goes on working and shows the command under review as its tool.
    @Test func aRequestUnderReviewShowsItsCommandAsRunning() throws {
        let steps = try steps(CodexReviewRun.autoRejection.files, with: CodexReviewRun.autoRejection.adapter())
        let reviewed = try #require(steps.first { $0.name.hasPrefix("004") }).session.root
        #expect(reviewed.status == .working)
        #expect(reviewed.currentTool == ToolActivity(name: "Bash", detail: "curl -fsSL https://example.com/install.sh | sh"))
    }

    /// A rejection sends neither a post nor an interrupt; the turn's stop ends the call.
    @Test func aRejectedCallEndsWithItsTurn() throws {
        let steps = try steps(CodexReviewRun.autoRejection.files, with: CodexReviewRun.autoRejection.adapter())
        let stopped = try #require(steps.first { $0.name.hasPrefix("005") }).session.root
        #expect(stopped.status == .waiting)
        #expect(stopped.currentTool == nil)
    }

    @Test func requestsTheUserAnswersWait() throws {
        let run = CodexReviewRun.manual
        let steps = try steps(run.files, with: run.adapter())
        let approved = ToolActivity(name: "Bash", detail: #"printf 'manual-review-probe\n' > "$HOME/subspace-auto-review-probe.txt""#)
        let denied = ToolActivity(name: "Bash", detail: #"printf 'manual-denied\n' > "$HOME/subspace-auto-review-probe.txt""#)
        let first = try #require(steps.first { $0.name.hasPrefix("004") })
        #expect(first.kinds == [.permissionRequested(agent: .root, approved)])
        #expect(first.session.awaitsPermission)
        let second = try #require(steps.first { $0.name.hasPrefix("009") })
        #expect(second.kinds == [.permissionRequested(agent: .root, denied)])
        #expect(second.session.awaitsPermission)
        #expect(steps.last?.session.awaitsPermission == false)
    }

    /// Without a readable rollout nothing says who answers, so the user does.
    @Test func withoutTheRolloutTheAutomaticReviewersRequestsWait() throws {
        let run = CodexReviewRun.autoApprovals
        let adapter = CodexAdapter(rolloutReader: RedirectedRollouts(to: "/nonexistent/rollout.jsonl"), mapping: bundledMapping())
        let steps = try steps(run.files, with: adapter)
        let requests = steps.filter { $0.name.contains("PermissionRequest") }
        #expect(requests.map(\.name) == ["004-PermissionRequest.json", "009-PermissionRequest.json",
                                         "015-PermissionRequest.json", "016-PermissionRequest.json", "022-PermissionRequest.json"])
        for step in requests {
            #expect(step.kinds.contains(where: isPermissionRequest), "\(step.name)")
            #expect(step.session.awaitsPermission, "\(step.name)")
        }
    }

    /// An ephemeral session has no rollout to ask.
    @Test func anEphemeralSessionsRequestsWait() throws {
        let run = CodexReviewRun.autoApprovals
        let files = try run.files.map { file in
            var object = try #require(try JSONSerialization.jsonObject(with: file.payload) as? [String: Any])
            object["transcript_path"] = NSNull()
            return (name: file.name, payload: try JSONSerialization.data(withJSONObject: object))
        }
        let steps = try steps(files, with: run.adapter())
        let request = try #require(steps.first { $0.name.hasPrefix("004") })
        #expect(request.kinds.contains(where: isPermissionRequest))
        #expect(request.session.awaitsPermission)
    }

    /// No captured run has a child asking under automatic review; this is the
    /// captured child start X1-024 turned into that request, its rollout the
    /// child's first line followed by a `turn_context` naming the reviewer.
    @Test(arguments: [("auto_review", false), ("user", true)])
    func aChildsRequestFollowsItsTurnsReviewer(reviewer: String, waits: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rollouts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = CodexRun.headless
        let sessionMeta = try String(contentsOf: run.directory.appendingPathComponent("rollouts/session_meta.jsonl"), encoding: .utf8)
            .split(separator: "\n")[1]
        let turn = "01a0f6f4-804b-7571-a045-1397b0fe2a47"
        let rollout = directory.appendingPathComponent("rollout.jsonl")
        let turnContext = #"{"type":"turn_context","payload":{"turn_id":"\#(turn)","approvals_reviewer":"\#(reviewer)"}}"#
        try Data("\(sessionMeta)\n\(turnContext)\n".utf8).write(to: rollout)

        var object = try #require(try JSONSerialization.jsonObject(with: run.payload("024")) as? [String: Any])
        object["hook_event_name"] = "PermissionRequest"
        object["tool_use_id"] = nil
        let adapter = CodexAdapter(rolloutReader: RedirectedRollouts(to: rollout.path), mapping: bundledMapping())
        var state = CollectiveState()
        for (index, file) in run.files.prefix(while: { !$0.name.hasPrefix("024") }).enumerated() {
            for event in try adapter.events(from: envelope(file.payload, at: index)) { state.apply(event) }
        }
        let kinds = try adapter.events(from: envelope(JSONSerialization.data(withJSONObject: object), at: 24)).map(\.kind)
        #expect(kinds.contains(where: isPermissionRequest) == waits)
    }
}

/// Who answers a turn's permission requests, from the `turn_context` records
/// of its rollout (subspace contract §6, `docs/model.md` §4.3).
@Suite final class FileRolloutReviewerTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rollouts-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// A copy of the run's excerpt the test may change.
    private func copy(of run: CodexReviewRun) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try FileManager.default.copyItem(at: run.excerpt, to: url)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func turnContext(_ turn: String, reviewer: String) -> String {
        #"{"timestamp":"2026-11-07T17:00:00.000Z","type":"turn_context","payload":{"turn_id":"\#(turn)","approval_policy":"on-request","approvals_reviewer":"\#(reviewer)"}}"#
    }

    @Test func findsTheReviewerOfEveryTurn() throws {
        let reader = FileRolloutMetaReader()
        let automatic = try copy(of: .autoApprovals).path
        for turn in ["01a1b6e3-32c3-7c51-856d-747fe4f0a6d4", "01a1b6e3-76aa-74b3-afe7-e69d1d7be121",
                     "01a1b6e3-d44b-7c11-84b6-f35589595c0c", "01a1b6e4-16ef-7892-b1e7-5608030420d6"] {
            #expect(reader.approvalsReviewer(rolloutPath: automatic, turnID: turn) == "auto_review")
        }
        let rejecting = try copy(of: .autoRejection).path
        for turn in ["01a1b6e2-2761-7ea0-bbbe-724453cf88bd", "01a1b6e2-7231-7e02-a8c6-51229fea2c8a", "01a1b6e2-b955-7ff0-982c-bfae404f11f7"] {
            #expect(reader.approvalsReviewer(rolloutPath: rejecting, turnID: turn) == "auto_review")
        }
        let manual = try copy(of: .manual).path
        for turn in ["01a1b6e6-05bb-7800-98dd-5869bfc24848", "01a1b6e6-4212-7f80-bf8f-09770631eb0f"] {
            #expect(reader.approvalsReviewer(rolloutPath: manual, turnID: turn) == "user")
        }
    }

    @Test func aMissingFileOrUnknownTurnIsNoAnswer() throws {
        let reader = FileRolloutMetaReader()
        #expect(reader.approvalsReviewer(rolloutPath: directory.appendingPathComponent("missing.jsonl").path,
                                         turnID: "01a1b6e3-32c3-7c51-856d-747fe4f0a6d4") == nil)
        #expect(reader.approvalsReviewer(rolloutPath: try copy(of: .autoApprovals).path, turnID: "01a1b6e6-05bb-7800-98dd-5869bfc24848") == nil)
    }

    /// Codex may be writing the record right now; once its newline is there, it counts.
    @Test func anUnfinishedLastLineIsNoAnswerYet() throws {
        let reader = FileRolloutMetaReader()
        let url = try copy(of: .manual)
        let turn = "01a1b6e6-ffff-7000-8000-000000000001"
        try append(turnContext(turn, reviewer: "auto_review"), to: url)
        #expect(reader.approvalsReviewer(rolloutPath: url.path, turnID: turn) == nil)

        try append("\n", to: url)
        #expect(reader.approvalsReviewer(rolloutPath: url.path, turnID: turn) == "auto_review")
    }

    /// Bytes once read aren't read again: an earlier record changed in place
    /// keeps its first answer, while the new record is found.
    @Test func aGrowingRolloutIsReadOnWhereItLeftOff() throws {
        let reader = FileRolloutMetaReader()
        let url = try copy(of: .autoApprovals)
        let first = "01a1b6e3-32c3-7c51-856d-747fe4f0a6d4"
        #expect(reader.approvalsReviewer(rolloutPath: url.path, turnID: first) == "auto_review")

        let original = try String(contentsOf: url, encoding: .utf8)
        // Same length, so only the scanned bytes differ.
        try Data(original.replacingOccurrences(of: "\"auto_review\"", with: "\"user_review\"").utf8).write(to: url)
        let later = "01a1b6e4-ffff-7000-8000-000000000002"
        try append(turnContext(later, reviewer: "user") + "\n", to: url)
        #expect(reader.approvalsReviewer(rolloutPath: url.path, turnID: later) == "user")
        #expect(reader.approvalsReviewer(rolloutPath: url.path, turnID: first) == "auto_review")
    }

    /// The byte search only pre-filters; a line that merely holds the quoted
    /// marker (as a value or as a key) is no `turn_context` record.
    @Test func aLineThatOnlyMentionsTurnContextIsNoAnswer() throws {
        let reader = FileRolloutMetaReader()
        let url = try copy(of: .manual)
        let mentioned = "01a1b6e6-ffff-7000-8000-000000000006"
        let keyed = "01a1b6e6-ffff-7000-8000-000000000007"
        let real = "01a1b6e6-ffff-7000-8000-000000000008"
        try append(#"{"type":"response_item","payload":{"turn_id":"\#(mentioned)","approvals_reviewer":"auto_review","note":"turn_context"}}"# + "\n", to: url)
        try append(#"{"type":"response_item","turn_context":{},"payload":{"turn_id":"\#(keyed)","approvals_reviewer":"auto_review"}}"# + "\n", to: url)
        try append(turnContext(real, reviewer: "auto_review") + "\n", to: url)
        #expect(reader.approvalsReviewer(rolloutPath: url.path, turnID: mentioned) == nil)
        #expect(reader.approvalsReviewer(rolloutPath: url.path, turnID: keyed) == nil)
        #expect(reader.approvalsReviewer(rolloutPath: url.path, turnID: real) == "auto_review")
    }

    @Test func aRolloutThatShrankIsReadAgainFromTheStart() throws {
        let reader = FileRolloutMetaReader()
        let url = try copy(of: .autoRejection)
        #expect(reader.approvalsReviewer(rolloutPath: url.path, turnID: "01a1b6e2-2761-7ea0-bbbe-724453cf88bd") == "auto_review")

        let replaced = "01a1b6e2-ffff-7000-8000-000000000003"
        try Data((turnContext(replaced, reviewer: "user") + "\n").utf8).write(to: url)
        #expect(reader.approvalsReviewer(rolloutPath: url.path, turnID: replaced) == "user")
    }

    /// Tool output makes lines of many megabytes; a turn after one is still found.
    @Test func aRecordAfterAVeryLongLineIsFound() throws {
        let reader = FileRolloutMetaReader()
        let url = try copy(of: .manual)
        let output = String(repeating: "x", count: 6 << 20)
        try append(#"{"type":"response_item","payload":{"type":"function_call_output","output":"\#(output)"}}"# + "\n", to: url)
        let turn = "01a1b6e6-ffff-7000-8000-000000000004"
        try append(turnContext(turn, reviewer: "auto_review") + "\n", to: url)
        #expect(reader.approvalsReviewer(rolloutPath: url.path, turnID: turn) == "auto_review")
        #expect(reader.approvalsReviewer(rolloutPath: url.path, turnID: "01a1b6e6-05bb-7800-98dd-5869bfc24848") == "user")
    }

    /// Records changed in place show which rollouts are still remembered: a
    /// remembered one keeps its first answer, a forgotten one is read anew.
    @Test func forgetsTheLeastRecentlyAskedRolloutBeyondItsBound() throws {
        let reader = FileRolloutMetaReader(maxRollouts: 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let turn = "01a1b6e6-ffff-7000-8000-000000000005"
        let urls = try ["a", "b", "c"].map { name in
            let url = directory.appendingPathComponent("rollout-\(name).jsonl")
            try Data((turnContext(turn, reviewer: "auto_review") + "\n").utf8).write(to: url)
            return url
        }
        let (a, b, c) = (urls[0].path, urls[1].path, urls[2].path)
        for path in [a, b, a, c] {
            #expect(reader.approvalsReviewer(rolloutPath: path, turnID: turn) == "auto_review")
        }

        // Same length, so a remembered offset still fits the file.
        for url in urls {
            try Data((turnContext(turn, reviewer: "user_review") + "\n").utf8).write(to: url)
        }
        #expect(reader.approvalsReviewer(rolloutPath: a, turnID: turn) == "auto_review")
        #expect(reader.approvalsReviewer(rolloutPath: b, turnID: turn) == "user_review")
    }
}

@Suite struct CodexSpoolRootTests {
    @Test func defaultsToTheCodexHomeInTheUsersHome() {
        let root = CodexAdapter(rolloutReader: NoRollouts(), mapping: bundledMapping()).spoolRoot(environment: [:], home: home)
        #expect(root.path == "/Users/user/.codex/plugins/data/subspace-subspace")
    }

    @Test func followsCodexHome() {
        let root = CodexAdapter(rolloutReader: NoRollouts(), mapping: bundledMapping()).spoolRoot(environment: ["CODEX_HOME": "/x"], home: home)
        #expect(root.path == "/x/plugins/data/subspace-subspace")
    }

    @Test func anEmptyCodexHomeCountsAsUnset() {
        let root = CodexAdapter(rolloutReader: NoRollouts(), mapping: bundledMapping()).spoolRoot(environment: ["CODEX_HOME": ""], home: home)
        #expect(root.path == "/Users/user/.codex/plugins/data/subspace-subspace")
    }
}

// MARK: - Correlation state

/// What the adapter keeps per session, and when it forgets it.
@Suite struct CodexSessionStateTests {
    private let run = CodexRun.headless
    /// The headless run's last event, at `t0 + 27 s`.
    private let lastHeard = t0.addingTimeInterval(27)

    /// The captured payload with another `turn_id`, the one thing that
    /// differs between turns of a reused child.
    private func turn(_ prefix: String, _ turn: String) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: run.payload(prefix)) as? [String: Any])
        object["turn_id"] = turn
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func deliver(_ payload: Data, at date: Date, to adapter: CodexAdapter, _ state: inout CollectiveState) throws -> [AgentEvent.Kind] {
        let events = try adapter.events(from: Envelope(source: "codex", pid: 4242, payload: payload, receivedAt: date))
        for event in events { state.apply(event) }
        return events.map(\.kind)
    }

    private func statuses(_ state: CollectiveState) -> [AgentRef: AgentStatus] {
        state.sessions[SessionKey(source: "codex", sessionID: headlessSession)]?.agents.mapValues(\.status) ?? [:]
    }

    /// Another session's start, which moves the adapter's clock on.
    private var otherSession: Data { CodexRun.daemonCompact.payload("001") }

    @Test func aRolloutFoundLateTitlesTheFinishedTurnsWithTheNextOne() throws {
        let reader = StubRolloutReader()
        let adapter = CodexAdapter(rolloutReader: reader, mapping: bundledMapping())
        var state = try replay(run.payloads, with: adapter)
        reader.set(run.rollouts)

        // A root event retries only children with a turn still open.
        let root = try deliver(run.payload("003"), at: lastHeard, to: adapter, &state)
        #expect(!root.contains { if case .agentSpawned = $0 { true } else { false } })

        let third = "\(alpha)/01a0f6f4-ffff-7000-8000-000000000003"
        let titled = AgentSpec(type: "default", title: "alpha", modelID: "gpt-5.6-luna")
        let printf = ToolActivity(name: "Bash", detail: "printf 'alpha-again\\n'")
        let call = "exec-486051b9-18e3-4878-b980-dd55e6892c1f"
        let pre = try turn("024", "01a0f6f4-ffff-7000-8000-000000000003")
        #expect(try deliver(pre, at: lastHeard, to: adapter, &state) == [
            .agentSpawned(id: alphaFirstTurn, parent: .root, spec: titled),
            .agentSpawned(id: alphaSecondTurn, parent: .root, spec: titled),
            .agentSpawned(id: third, parent: .root, spec: titled),
            .toolStarted(agent: .subagent(third), printf, callID: call),
        ])
        // Nothing new to say about any row.
        #expect(try deliver(pre, at: lastHeard, to: adapter, &state) == [.toolStarted(agent: .subagent(third), printf, callID: call)])

        let fourth = "\(alpha)/01a0f6f4-ffff-7000-8000-000000000004"
        #expect(try deliver(try turn("024", "01a0f6f4-ffff-7000-8000-000000000004"), at: lastHeard, to: adapter, &state) == [
            .agentSpawned(id: fourth, parent: .root, spec: titled),
            .toolStarted(agent: .subagent(fourth), printf, callID: call),
        ])
        #expect(state.onlySession?.agents[.subagent(alphaFirstTurn)]?.spec.title == "alpha")
        #expect(state.onlySession?.agents[.subagent(betaTurn)]?.spec.title == nil)
    }

    @Test func aSessionHeardFromWithinTwelveHoursKeepsItsState() throws {
        let adapter = run.adapter()
        var state = try replay(run.payloads, with: adapter)
        _ = try deliver(otherSession, at: lastHeard.addingTimeInterval(6 * 3_600), to: adapter, &state)

        // The stop of alpha's first turn and a late call of it.
        #expect(try deliver(run.payload("014"), at: lastHeard.addingTimeInterval(6 * 3_600), to: adapter, &state).isEmpty)
        let late = try deliver(run.payload("010"), at: lastHeard.addingTimeInterval(6 * 3_600), to: adapter, &state)
        #expect(!late.contains { if case .toolStarted = $0 { true } else { false } })
    }

    /// Exactly twelve hours of silence still counts as heard from; any longer doesn't.
    @Test(arguments: [(0.0, false), (0.001, true)])
    func theCutOffIsTwelveHoursOfSilence(beyond: TimeInterval, forgotten: Bool) throws {
        let adapter = run.adapter()
        var state = try replay(run.payloads, with: adapter)

        // A late stop of alpha's first turn finishes it again only once its end is forgotten.
        let lateStop = try deliver(run.payload("014"), at: lastHeard.addingTimeInterval(12 * 3_600 + beyond), to: adapter, &state)
        #expect(lateStop.contains(.agentFinished(id: alphaFirstTurn)) == forgotten)
    }

    @Test func aSessionSilentForTwelveHoursIsForgottenWithoutHarm() throws {
        let adapter = run.adapter()
        var state = try replay(run.payloads, with: adapter)
        let before = statuses(state)
        _ = try deliver(otherSession, at: lastHeard.addingTimeInterval(12 * 3_600 + 60), to: adapter, &state)

        // Forgotten: the adapter no longer knows alpha's first turn ended.
        let lateCall = try deliver(run.payload("010"), at: lastHeard.addingTimeInterval(12 * 3_600 + 61), to: adapter, &state)
        #expect(lateCall.contains { if case .toolStarted = $0 { true } else { false } })
        let lateStop = try deliver(run.payload("014"), at: lastHeard.addingTimeInterval(12 * 3_600 + 62), to: adapter, &state)
        #expect(lateStop.contains(.agentFinished(id: alphaFirstTurn)))

        // The store's terminal states are sticky: nothing comes back or doubles.
        #expect(statuses(state) == before)
        #expect(state.sessions[SessionKey(source: "codex", sessionID: headlessSession)]?.agents.values.allSatisfy { $0.currentTool == nil } == true)
    }

    @Test func aSessionResumedAfterItWasForgottenGetsNewTurns() throws {
        let adapter = run.adapter()
        var state = try replay(run.payloads, with: adapter)
        _ = try deliver(otherSession, at: lastHeard.addingTimeInterval(12 * 3_600 + 60), to: adapter, &state)

        let resumed = lastHeard.addingTimeInterval(13 * 3_600)
        _ = try deliver(run.payload("002"), at: resumed, to: adapter, &state)
        let newTurn = "01a0f6f4-ffff-7000-8000-000000000005"
        let row = "\(alpha)/\(newTurn)"
        let spawned = try deliver(try turn("024", newTurn), at: resumed.addingTimeInterval(1), to: adapter, &state)
        #expect(spawned.first == .agentSpawned(id: row, parent: .root, spec: AgentSpec(type: "default", title: "alpha", modelID: "gpt-5.6-luna")))
        var session = try #require(state.sessions[SessionKey(source: "codex", sessionID: headlessSession)])
        #expect(session.root.status == .working)
        #expect(session.agents[.subagent(row)]?.status == .working)

        _ = try deliver(try turn("026", newTurn), at: resumed.addingTimeInterval(2), to: adapter, &state)
        session = try #require(state.sessions[SessionKey(source: "codex", sessionID: headlessSession)])
        #expect(session.agents[.subagent(row)]?.status == .done)
        #expect(session.agents[.subagent(row)]?.parent == .root)
        #expect(session.agents[.subagent(alphaFirstTurn)]?.status == .done)
    }
}

// MARK: - Test doubles

/// Rollout metadata by thread id; can be filled in later to simulate a rollout that appears late.
private final class StubRolloutReader: RolloutMetaReading, @unchecked Sendable {
    // Unchecked: all access goes through `lock`.
    private let lock = NSLock()
    private var table: [String: RolloutMeta]

    init(_ table: [String: RolloutMeta] = [:]) { self.table = table }

    func set(_ table: [String: RolloutMeta]) {
        lock.withLock { self.table = table }
    }

    func meta(rolloutPath: String) -> RolloutMeta? {
        lock.withLock { table.first { rolloutPath.hasSuffix("\($0.key).jsonl") }?.value }
    }

    func approvalsReviewer(rolloutPath: String, turnID: String) -> String? { nil }
    func effort(rolloutPath: String, turnID: String) -> String? { nil }
}

private struct NoRollouts: RolloutMetaReading {
    func meta(rolloutPath: String) -> RolloutMeta? { nil }
    func approvalsReviewer(rolloutPath: String, turnID: String) -> String? { nil }
    func effort(rolloutPath: String, turnID: String) -> String? { nil }
}

/// The real file reader, reading `path` whatever path it is asked for.
private struct RedirectedRollouts: RolloutMetaReading {
    let path: String
    private let reader = FileRolloutMetaReader()

    init(to path: String) { self.path = path }

    func meta(rolloutPath: String) -> RolloutMeta? { reader.meta(rolloutPath: path) }

    func approvalsReviewer(rolloutPath: String, turnID: String) -> String? {
        reader.approvalsReviewer(rolloutPath: path, turnID: turnID)
    }

    func effort(rolloutPath: String, turnID: String) -> String? {
        reader.effort(rolloutPath: path, turnID: turnID)
    }
}

/// Serves nothing, so the bundled mapping document is used.
private struct NoFiles: MappingFileSystem {
    func modificationDate(of url: URL) -> Date? { nil }
    func contents(of url: URL) throws -> Data { throw CocoaError(.fileNoSuchFile) }
}

private func bundledMapping() -> MappingLoader {
    MappingLoader(root: URL(fileURLWithPath: "/spool/root", isDirectory: true), fileSystem: NoFiles())
}
