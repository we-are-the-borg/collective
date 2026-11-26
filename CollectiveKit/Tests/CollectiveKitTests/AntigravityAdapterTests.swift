import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// MARK: - Helpers

private let t0 = Date(timeIntervalSince1970: 1_000)
private let home = URL(fileURLWithPath: "/Users/user", isDirectory: true)

/// The store's timeouts as the app passes them (`CollectiveModel`).
private let idleTimeout: TimeInterval = 2 * 60
private let toolTimeout: TimeInterval = 30 * 60
private let silenceTimeout: TimeInterval = 30 * 60
private let waitingTimeout: TimeInterval = 12 * 60 * 60

/// A recorded run of Antigravity CLI 1.5.16 / 1.5.17 or the Desktop App 2.35.1.
enum AntigravityRun: String, CaseIterable {
    case headlessSubagent = "1-headless-tools-failure-subagent"
    case parallelSubagents = "2-parallel-subagents"
    case permission = "3-interactive-permission-approve-deny"
    case interrupt = "4-interactive-interrupt-mid-tool"
    case resume = "5-resume"
    case cwdWithSpaces = "6-cwd-with-spaces"
    case desktopApp = "7-desktop-app-shared-host"

    var directory: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/antigravity/1.5.17/\(rawValue)")
    }

    /// Raw payloads in delivery order (`NNN-<hook>.json`), keyed by file name.
    var files: [(name: String, payload: Data)] {
        let events = directory.appendingPathComponent("events")
        let names = try! FileManager.default.contentsOfDirectory(atPath: events.path).sorted()
        return names.map { ($0, try! Data(contentsOf: events.appendingPathComponent($0))) }
    }

    /// The terminal identifiers the capture recorded for the run, none if it recorded none.
    var terminal: [String: String] {
        let url = directory.appendingPathComponent("terminal.json")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return try! JSONDecoder().decode([String: String].self, from: data)
    }

    /// The payloads wrapped as the spool delivers them, one second apart. The
    /// pid is one for all, as the shared `agy` or `language_server` host
    /// gives every conversation of a run (contract §6); the adapter must ignore it.
    var envelopes: [Envelope] {
        let terminal = terminal
        return files.enumerated().map { index, file in
            Envelope(
                source: "antigravity", pid: 4242, payload: file.payload,
                receivedAt: t0.addingTimeInterval(TimeInterval(index)), terminal: terminal
            )
        }
    }

    /// With `transcripts`, each child's transcript is its lines of the run's
    /// excerpt; without, no transcript ever answers.
    func adapter(transcripts: Bool = true) -> AntigravityAdapter {
        AntigravityAdapter(
            transcriptReader: transcripts ? ExcerptTranscripts(run: self) : NoTranscripts(),
            mapping: bundledMapping()
        )
    }
}

/// Serves each conversation the first of its lines in the run's excerpt. The
/// payloads name transcripts on the capture machine,
/// `…/brain/<conversationId>/.system_generated/logs/transcript_full.jsonl`.
private struct ExcerptTranscripts: AntigravityTranscriptReading {
    let run: AntigravityRun

    func origin(transcriptPath: String) -> AntigravityTranscriptOrigin? {
        let components = transcriptPath.split(separator: "/")
        guard let brain = components.firstIndex(of: "brain"), brain + 1 < components.count else { return nil }
        return antigravityTranscript(of: String(components[brain + 1]), in: run).first.flatMap(FileAntigravityTranscriptReader.parse)
    }
}

/// A transcript that never answers: missing, lagging or in a format not understood.
private struct NoTranscripts: AntigravityTranscriptReading {
    func origin(transcriptPath: String) -> AntigravityTranscriptOrigin? { nil }
}

/// The events of each envelope, in order.
private func translate(_ envelopes: [Envelope], with adapter: AntigravityAdapter) throws -> [[AgentEvent]] {
    try envelopes.map { try adapter.events(from: $0) }
}

private func replay(_ envelopes: [Envelope], with adapter: AntigravityAdapter) throws -> CollectiveState {
    var state = CollectiveState()
    for envelope in envelopes {
        for event in try adapter.events(from: envelope) { state.apply(event) }
    }
    return state
}

private func replay(_ run: AntigravityRun) throws -> CollectiveState {
    try replay(run.envelopes, with: run.adapter())
}

private func key(_ conversation: String) -> SessionKey {
    SessionKey(source: "antigravity", sessionID: conversation)
}

private extension CollectiveState {
    var onlySession: Session? { sessions.count == 1 ? sessions.values.first : nil }
}

private extension AgentEvent.Kind {
    var startedCall: String? {
        if case let .toolStarted(_, _, callID, _) = self { callID } else { nil }
    }

    var finishedCall: String? {
        if case let .toolFinished(_, callID, _) = self { callID } else { nil }
    }

    var isTurnEvent: Bool {
        switch self {
        case .promptSubmitted, .turnStarted, .turnEnded: true
        default: false
        }
    }
}

private let headlessParent = "ea5fa741-34ec-4612-ad24-205289f3eb4b"
private let headlessChild = "bd793872-9200-404c-922e-0d0017b69b7f"
private let parallelParent = "9387948b-0c36-40db-986f-d38d89d7b6dc"
private let parallelChildren = ["91921677-ee57-400f-8371-5ea165c7bfd2", "eb79fbb4-b523-43b2-ba16-e221db8df6f5"]
private let permissionSession = "62896c79-8e97-4cd7-81bd-41df7c086c4a"
private let interruptSession = "18150b75-dc24-4a8f-bcca-b97323c3fffa"
private let desktopSessions = ["c3c435ff-856d-4ef2-bd0d-4a4b0d4e83e5", "a0c7175e-1cd9-4550-b19b-2a96cbe01c90"]

// MARK: - Fixture runs

@Suite struct AntigravityFixtureTests {
    /// Turn 1 is approved and ends with its `Stop`; turn 2's command is
    /// denied, which sends neither `PostToolUse` nor `Stop` (contract §6).
    @Test func aDeniedCommandLeavesItsTurnOpenUntilTheIdleGuess() throws {
        let run = AntigravityRun.permission
        let events = try translate(run.envelopes, with: run.adapter()).flatMap { $0 }.map(\.kind)
        let approved = "call_4354118485226306980"
        let denied = "call_561267951115866283"
        #expect(events.compactMap(\.startedCall) == [approved, denied])
        #expect(events.compactMap(\.finishedCall) == [approved])
        #expect(events.filter { if case .turnEnded = $0 { true } else { false } } == [.turnEnded(.completed)])

        // Turn 1 ends with its `Stop` (008).
        let firstTurn = try #require(try replay(Array(run.envelopes.prefix(8)), with: run.adapter()).onlySession)
        #expect(firstTurn.root.status == .waiting)
        #expect(firstTurn.turnEndedAt == t0.addingTimeInterval(7))

        var state = try replay(run)
        let session = try #require(state.onlySession)
        #expect(session.key == key(permissionSession))
        #expect(session.turnEndedAt == nil)
        #expect(session.root.status == .working)
        #expect(session.root.spec.prompt?.hasPrefix("Use run_command with BypassSandbox=true to run exactly: rm -rf") == true)
        #expect(session.root.currentTool == ToolActivity(name: "run_command", detail: "rm -rf /tmp/subspace-nonexistent-88888"))

        // An open call keeps the turn for the store's tool timeout.
        let last = session.lastActivity
        state.markInterrupted(now: last.addingTimeInterval(idleTimeout + 60), idleTimeout: idleTimeout, toolTimeout: toolTimeout)
        #expect(state.onlySession?.root.status == .working)
        state.markInterrupted(now: last.addingTimeInterval(toolTimeout + 1), idleTimeout: idleTimeout, toolTimeout: toolTimeout)
        #expect(state.onlySession?.root.status == .waiting)
        #expect(state.onlySession?.root.currentTool == nil)
    }

    /// A turn without a fully idle `Stop` is closed by the next turn start:
    /// its open call finishes, the turn is interrupted, the new prompt begins.
    @Test func aNewTurnClosesTheOpenCallsOfTheLeftOne() throws {
        let run = AntigravityRun.permission
        let denied = "call_561267951115866283"
        let envelopes = run.envelopes
        let adapter = run.adapter()
        // Up to and including 010-PreToolUse: the denied call is open.
        var state = try replay(Array(envelopes.prefix(10)), with: adapter)
        #expect(state.onlySession?.root.currentTool != nil)

        let again = try #require(run.files.first { $0.name.hasPrefix("009-") })
        let next = Envelope(
            source: "antigravity", pid: 4242, payload: again.payload,
            receivedAt: t0.addingTimeInterval(10), terminal: run.terminal
        )
        let events = try adapter.events(from: next)
        // The effort report of the new turn is not part of the close-out.
        let kinds = events.map(\.kind).filter { $0.finishedCall != nil || $0.isTurnEvent }
        #expect(kinds.count == 3)
        #expect(kinds.first?.finishedCall == denied)
        #expect(kinds.dropFirst().first == .turnEnded(.interrupted))
        guard case let .promptSubmitted(prompt)? = kinds.last else {
            Issue.record("expected a prompt, got \(String(describing: kinds.last))")
            return
        }
        #expect(prompt.hasPrefix("Use run_command with BypassSandbox=true to run exactly: rm -rf"))

        for event in events { state.apply(event) }
        let session = try #require(state.onlySession)
        #expect(session.root.currentTool == nil)
        #expect(session.root.status == .working)
        #expect(session.turnEndedAt == nil)
    }

    /// The CLI runs in the user's terminal, so its identifiers are the session's own.
    @Test func theCLISessionBringsItsWarpTabToTheFront() throws {
        let session = try #require(try replay(.permission).onlySession)
        let focus = try #require(URL(string: "warp://session/4df17f2797b14668a6880470c7bbee1d"))
        #expect(session.terminalTarget == .url(focus, bundleID: "dev.warp.Warp-Stable"))
    }

    /// `Esc` during a running tool sends nothing more (contract §6).
    @Test func anInterruptedToolFallsBackToTheTimeouts() throws {
        var state = try replay(.interrupt)
        let session = try #require(state.onlySession)
        #expect(session.key == key(interruptSession))
        #expect(session.root.status == .working)
        #expect(session.root.currentTool == ToolActivity(name: "run_command", detail: "sleep 30"))
        #expect(session.turnEndedAt == nil)
        #expect(session.pid == nil)

        let last = session.lastActivity
        var asked: [Int32] = []
        state.markStale(now: last.addingTimeInterval(silenceTimeout - 60), silenceTimeout: silenceTimeout, waitingTimeout: waitingTimeout) {
            asked.append($0)
            return nil
        }
        #expect(state.onlySession?.endedAt == nil)

        let later = last.addingTimeInterval(toolTimeout + 1)
        state.markInterrupted(now: later, idleTimeout: idleTimeout, toolTimeout: toolTimeout)
        #expect(state.onlySession?.root.status == .waiting)
        // Only a guess, so the silence timeout still applies, not the waiting one.
        state.markStale(now: later, silenceTimeout: silenceTimeout, waitingTimeout: waitingTimeout) {
            asked.append($0)
            return nil
        }
        #expect(state.onlySession?.root.status == .stale)
        #expect(asked.isEmpty)
    }

    /// `--conversation` sends no `SessionStart`; the first `PreInvocation` makes the session.
    @Test func aResumedConversationStartsWithItsFirstInvocation() throws {
        let run = AntigravityRun.resume
        let first = try #require(try translate(run.envelopes, with: run.adapter()).first).map(\.kind)
        #expect(!first.contains { if case .sessionStarted = $0 { true } else { false } })
        #expect(first.contains(.promptSubmitted("Run pwd using run_command and report it. Do not edit files.")))

        let session = try #require(try replay(run).onlySession)
        #expect(session.key == key(headlessParent))
        #expect(session.cwd == "/Users/user/dev/subspace/tools/hook-capture/antigravity")
        #expect(session.root.spec.prompt == "Run pwd using run_command and report it. Do not edit files.")
        #expect(session.root.status == .waiting)
        #expect(session.turnEndedAt == t0.addingTimeInterval(6))
    }

    /// The same conversation resumed after its first run ended: a new turn, nothing carried over open.
    @Test func aResumeAfterTheFirstRunOpensANewTurn() throws {
        let adapter = AntigravityRun.headlessSubagent.adapter()
        let envelopes = AntigravityRun.headlessSubagent.envelopes + AntigravityRun.resume.envelopes.map {
            Envelope(source: $0.source, pid: $0.pid, payload: $0.payload, receivedAt: $0.receivedAt.addingTimeInterval(3_600))
        }
        let state = try replay(envelopes, with: adapter)
        let session = try #require(state.sessions[key(headlessParent)])
        #expect(session.root.spec.prompt == "Run pwd using run_command and report it. Do not edit files.")
        #expect(session.root.status == .waiting)
        #expect(session.turnEndedAt == t0.addingTimeInterval(3_600 + 6))
    }

    @Test func theCwdWithSpacesIsTheSessionsCwd() throws {
        let session = try #require(try replay(.cwdWithSpaces).onlySession)
        #expect(session.cwd == "/Users/user/dev/subspace/tools/hook-capture/antigravity/captures/project with spaces")
        #expect(session.root.spec.prompt == "Run pwd using run_command and report its output. Do not edit files.")
        #expect(session.root.status == .waiting)
        #expect(session.turnEndedAt != nil)
    }

    /// Two conversations of the app share one host process; each is its own session.
    @Test func desktopAppConversationsAreSessionsOfTheirOwn() throws {
        let state = try replay(.desktopApp)
        #expect(Set(state.sessions.keys) == Set(desktopSessions.map(key)))
        for session in state.sessions.values {
            #expect(session.pid == nil)
            #expect(session.root.status == .waiting)
            #expect(session.turnEndedAt != nil)
            #expect(session.model == "gemini-4-neon-high")
            #expect(session.effort == EffortLevel(step: 3, name: "high"))
            #expect(session.terminalTarget == .app(bundleID: "com.google.antigravity"))
        }
    }

    /// A tool call ends in the conversation that started it.
    @Test(arguments: [AntigravityRun.headlessSubagent, .parallelSubagents])
    func everyCallOfASubagentRunCloses(run: AntigravityRun) throws {
        let batches = try translate(run.envelopes, with: run.adapter())
        let events = batches.flatMap { $0 }
        for conversation in Set(events.map(\.session)) {
            let kinds = events.filter { $0.session == conversation }.map(\.kind)
            #expect(Set(kinds.compactMap(\.startedCall)) == Set(kinds.compactMap(\.finishedCall)))
        }
        let state = try replay(run)
        for session in state.sessions.values {
            #expect(session.root.status == .waiting)
            #expect(session.root.currentTool == nil)
            #expect(session.turnEndedAt != nil)
        }
    }

    /// The parent's `Stop` with `fullyIdle: false` (030) waits for its child;
    /// the wakeup (033) continues the same turn, which ends with 043.
    @Test func aParentWaitingForItsSubagentKeepsItsTurn() throws {
        let run = AntigravityRun.headlessSubagent
        let envelopes = run.envelopes
        let adapter = run.adapter()
        var state = CollectiveState()
        var prompts = 0
        for (index, envelope) in envelopes.enumerated() {
            let events = try adapter.events(from: envelope)
            let number = index + 1
            if events.first?.session == key(headlessParent) {
                prompts += events.count { if case .promptSubmitted = $0.kind { true } else { false } }
                if number == 30 || number == 33 { #expect(!events.contains { $0.kind.isTurnEvent }) }
            }
            for event in events { state.apply(event) }
            let parent = try #require(state.sessions[key(headlessParent)])
            switch number {
            case 30, 33, 42:
                #expect(parent.root.status == .working)
                #expect(parent.turnEndedAt == nil)
            case 43:
                #expect(parent.root.status == .waiting)
                #expect(parent.turnEndedAt == t0.addingTimeInterval(42))
            default:
                break
            }
        }
        #expect(prompts == 1)
        #expect(state.sessions[key(headlessParent)]?.effort == EffortLevel(step: 1, name: "low"))
    }

    @Test(arguments: AntigravityRun.allCases)
    func neverPassesTheEnvelopePid(run: AntigravityRun) throws {
        let events = try translate(run.envelopes, with: run.adapter()).flatMap { $0 }
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.pid == nil })
        for case let .sessionStarted(_, pid) in events.map(\.kind) { #expect(pid == nil) }
    }

    /// The model goes into every payload; only the first and a change are news.
    @Test(arguments: AntigravityRun.allCases)
    func reportsTheModelOncePerConversation(run: AntigravityRun) throws {
        let events = try translate(run.envelopes, with: run.adapter()).flatMap { $0 }
        let changes = events.filter { if case .modelChanged = $0.kind { true } else { false } }
        #expect(changes.count == Set(events.map(\.session)).count)
    }

    /// One report per conversation: the terminal stays the same throughout a run.
    @Test(arguments: AntigravityRun.allCases)
    func reportsTheTerminalOncePerConversation(run: AntigravityRun) throws {
        let events = try translate(run.envelopes, with: run.adapter()).flatMap { $0 }
        let reports = events.compactMap { if case let .terminalReported(ownership) = $0.kind { ownership } else { nil } }
        #expect(reports.count == Set(events.map(\.session)).count)
        #expect(Set(reports) == [run.terminal.isEmpty ? .unusable : .session])
    }
}

// MARK: - Subagents

@Suite struct AntigravitySubagentTests {
    /// The child (025–039) is a subagent of its parent's root, from its
    /// transcript's first step on; it never shows as a session of its own.
    @Test func runOnesChildIsASubagentOfItsParent() throws {
        let run = AntigravityRun.headlessSubagent
        let adapter = run.adapter()
        var state = CollectiveState()
        let child = AgentRef.subagent(headlessChild)
        for (index, envelope) in run.envelopes.enumerated() {
            for event in try adapter.events(from: envelope) { state.apply(event) }
            let number = index + 1
            #expect(Set(state.sessions.keys) == [key(headlessParent)], "after \(number)")
            let parent = try #require(state.sessions[key(headlessParent)])
            switch number {
            case 25...38:
                #expect(parent.agents[child]?.status == .working, "after \(number)")
                #expect(parent.root.status == .working, "after \(number)")
            case 39:
                #expect(parent.agents[child]?.status == .done)
                #expect(parent.agents[child]?.endedAt == t0.addingTimeInterval(38))
            default:
                break
            }
            if number == 31 {
                #expect(parent.agents[child]?.currentTool == ToolActivity(name: "send_message"))
            }
        }
        let session = try #require(state.onlySession)
        let agent = try #require(session.agents[child])
        #expect(agent.parent == .root)
        #expect(agent.spec.type == "research")
        #expect(agent.spec.title == "Capture Verification Subagent")
        #expect(agent.spec.prompt == #"Reply strictly with "sub-ok". Do not call any tools or edit any files."#)
        #expect(agent.spec.modelAlias == nil)
        #expect(agent.spec.modelID == "gemini-3.8-flash-low")
        #expect(agent.effort == EffortLevel(step: 1, name: "low"))
        #expect(agent.startedAt == t0.addingTimeInterval(24))
        #expect(agent.lastToolCall?.tool == ToolActivity(name: "send_message"))
        #expect(agent.currentTool == nil)
        #expect(session.root.status == .waiting)
        #expect(session.turnEndedAt == t0.addingTimeInterval(42))
    }

    /// Each child matches the spawn call with its transcript's prompt.
    @Test func runTwosChildrenMatchTheirSpawnCalls() throws {
        let run = AntigravityRun.parallelSubagents
        let adapter = run.adapter()
        var state = CollectiveState()
        for (index, envelope) in run.envelopes.enumerated() {
            for event in try adapter.events(from: envelope) { state.apply(event) }
            let number = index + 1
            #expect(Set(state.sessions.keys) == [key(parallelParent)], "after \(number)")
            if (2..<45).contains(number) { #expect(state.sessions[key(parallelParent)]?.root.status == .working, "after \(number)") }
        }
        let session = try #require(state.onlySession)
        let alpha = try #require(session.agents[.subagent(parallelChildren[0])])
        let beta = try #require(session.agents[.subagent(parallelChildren[1])])
        #expect(alpha.spec.title == "Alpha Runner")
        #expect(alpha.spec.type == "research")
        #expect(alpha.lastToolCall?.tool == ToolActivity(name: "send_message"))
        #expect(alpha.endedAt == t0.addingTimeInterval(36))
        #expect(beta.spec.title == "Beta Reader")
        #expect(beta.endedAt == t0.addingTimeInterval(38))
        #expect([alpha.status, beta.status] == [.done, .done])
        #expect(session.root.status == .waiting)
        #expect(session.turnEndedAt == t0.addingTimeInterval(44))
    }

    /// Without transcripts each child links at its `send_message` (run 1 031,
    /// run 2 025 and 029), and what it did before shows then.
    @Test(arguments: [AntigravityRun.headlessSubagent, .parallelSubagents])
    func withoutTranscriptsChildrenLinkAtTheirMessage(run: AntigravityRun) throws {
        let linked = try translate(run.envelopes, with: run.adapter()).flatMap { $0 }
        let late = try translate(run.envelopes, with: run.adapter(transcripts: false)).flatMap { $0 }
        #expect(Set(late.map(\.session)) == Set(linked.map(\.session)))
        #expect(late.compactMap(\.kind.startedCall) .sorted() == linked.compactMap(\.kind.startedCall).sorted())
        #expect(late.compactMap(\.kind.finishedCall).sorted() == linked.compactMap(\.kind.finishedCall).sorted())

        let state = try replay(run.envelopes, with: run.adapter(transcripts: false))
        let session = try #require(state.onlySession)
        let children = session.agents.values.filter { $0.id != .root }
        #expect(children.count == (run == .headlessSubagent ? 1 : 2))
        for child in children {
            #expect(child.status == .done)
            #expect(child.spec.type == "research")
            #expect(child.lastToolCall?.tool == ToolActivity(name: "send_message"))
        }
        #expect(session.root.status == .waiting)
    }

    /// The fallback link comes when the child already ran: its spawn carries
    /// its first hook's time, its tools theirs.
    @Test func aLateLinkKeepsTheChildsOwnTimes() throws {
        let run = AntigravityRun.parallelSubagents
        let state = try replay(Array(run.envelopes.prefix(25)), with: run.adapter(transcripts: false))
        let session = try #require(state.onlySession)
        let beta = try #require(session.agents[.subagent(parallelChildren[1])])
        #expect(beta.startedAt == t0.addingTimeInterval(10))
        #expect(beta.currentTool == ToolActivity(name: "send_message"))
        #expect(session.agents[.subagent(parallelChildren[0])] == nil)
    }

    /// Without Alpha's hooks, Beta links first, while both spawn calls wait:
    /// its transcript's prompt picks its own.
    @Test func theTranscriptsPromptPicksTheSpawnCall() throws {
        let run = AntigravityRun.parallelSubagents
        let state = try replay(run.envelopes.without(parallelChildren[0]), with: run.adapter())
        let beta = try #require(state.onlySession?.agents[.subagent(parallelChildren[1])])
        #expect(beta.spec.title == "Beta Reader")
        #expect(beta.spec.prompt == "Read lines 1-3 of README.md using read_file and report the first heading found.")
    }

    /// Without a prompt to match, the oldest waiting spawn call is taken, here
    /// Alpha's: the hooks can't tell the two apart.
    @Test func withoutAPromptTheOldestSpawnCallIsTaken() throws {
        let run = AntigravityRun.parallelSubagents
        let state = try replay(run.envelopes.without(parallelChildren[0]), with: run.adapter(transcripts: false))
        #expect(state.onlySession?.agents[.subagent(parallelChildren[1])]?.spec.title == "Alpha Runner")
    }

    /// A child whose transcript's prompt matches no waiting spawn call takes
    /// none: the one waiting is another child's. Run 2 without Alpha's spawn
    /// call (005, 006) and with Beta's (008) moved before Alpha's first hook
    /// (007), so Alpha links while only Beta's waits.
    @Test func aPromptMatchingNoSpawnCallTakesNone() throws {
        let run = AntigravityRun.parallelSubagents
        let hooks = run.envelopes
        let envelopes = Array(hooks[0..<4]) + [hooks[7], hooks[6]] + Array(hooks[8...])
        let session = try #require(try replay(envelopes, with: run.adapter()).onlySession)
        let alpha = try #require(session.agents[.subagent(parallelChildren[0])])
        #expect(alpha.spec == AgentSpec(prompt: "Run the command `pwd` using run_command and report the exact output.", modelID: "gemini-3.8-flash-low"))
        let beta = try #require(session.agents[.subagent(parallelChildren[1])])
        #expect(beta.spec.title == "Beta Reader")
        #expect(beta.spec.type == "research")
    }

    /// A spawn call that arrives after its child linked by its transcript
    /// still gives that child its spec, and waits for no other. Run 1 with
    /// the child's first hooks (025, 027) moved before the parent's spawn
    /// call (023). Then a second child takes the call if it were left: run
    /// 1's child hooks again with only their `conversationId` value replaced
    /// by one of run 2's children, whose transcript (still run 1's child's)
    /// names the same prompt.
    @Test func aLateSpawnCallGivesTheLinkedChildItsSpec() throws {
        let run = AntigravityRun.headlessSubagent
        let hooks = run.envelopes
        let reordered = Array(hooks[0..<22]) + [hooks[24], hooks[26], hooks[22], hooks[23], hooks[25]] + Array(hooks[27...])
        let adapter = run.adapter()
        let batches = try translate(reordered, with: adapter)
        // The child links at its first hook, before any spawn call.
        #expect(batches[22].first?.kind == .agentSpawned(id: headlessChild, parent: .root, spec: AgentSpec(
            prompt: #"Reply strictly with "sub-ok". Do not call any tools or edit any files."#, modelID: "gemini-3.8-flash-low")))

        var state = CollectiveState()
        for event in batches.flatMap({ $0 }) { state.apply(event) }
        let agent = try #require(state.onlySession?.agents[.subagent(headlessChild)])
        #expect(agent.spec.type == "research")
        #expect(agent.spec.title == "Capture Verification Subagent")
        #expect(agent.spec.prompt == #"Reply strictly with "sub-ok". Do not call any tools or edit any files."#)
        #expect(agent.spec.modelID == "gemini-3.8-flash-low")
        #expect(agent.status == .done)

        let second = [hooks[24], hooks[26]].map {
            $0.replacingConversation(headlessChild, with: parallelChildren[0])
        }
        for envelope in second {
            for event in try adapter.events(from: envelope) { state.apply(event) }
        }
        let other = try #require(state.onlySession?.agents[.subagent(parallelChildren[0])])
        #expect(other.spec.type == nil)
        #expect(other.spec.title == nil)
    }

    /// A parent whose spawn call wasn't seen gives no spec but the transcript's prompt.
    @Test func withoutASpawnCallTheSubagentHasNoSpec() throws {
        let run = AntigravityRun.headlessSubagent
        let envelopes = run.envelopes.enumerated().filter { ![23, 24].contains($0.offset + 1) }.map(\.element)
        let agent = try #require(try replay(envelopes, with: run.adapter()).onlySession?.agents[.subagent(headlessChild)])
        #expect(agent.spec == AgentSpec(prompt: #"Reply strictly with "sub-ok". Do not call any tools or edit any files."#, modelID: "gemini-3.8-flash-low"))
        #expect(agent.status == .done)
    }

    /// A child that names no parent, neither in its transcript nor with a
    /// `send_message`, is shown as a session of its own at its fully idle
    /// `Stop`, with everything it did; until then it isn't shown.
    @Test func anUnlinkedChildShowsOnItsOwnAtItsStop() throws {
        let run = AntigravityRun.headlessSubagent
        // Without the child's `send_message` (031, 032), its `Stop` (039) is the 37th envelope.
        let envelopes = run.envelopes.enumerated().filter { ![31, 32].contains($0.offset + 1) }.map(\.element)
        let adapter = run.adapter(transcripts: false)
        var state = CollectiveState()
        for (index, envelope) in envelopes.enumerated() {
            for event in try adapter.events(from: envelope) { state.apply(event) }
            let expected = index + 1 < 37 ? [key(headlessParent)] : [key(headlessParent), key(headlessChild)]
            #expect(Set(state.sessions.keys) == Set(expected), "after \(index + 1)")
        }
        let child = try #require(state.sessions[key(headlessChild)])
        #expect(child.startedAt == t0.addingTimeInterval(24))
        #expect(child.model == "gemini-3.8-flash-low")
        #expect(child.root.status == .waiting)
        #expect(child.turnEndedAt == t0.addingTimeInterval(38))
        #expect(state.sessions[key(headlessParent)]?.agents.count == 1)
    }

    /// A conversation whose first hook has an empty input but a later one a
    /// prompt is a root that started without text (e.g. an image only): its
    /// kept hooks show as its own session, from then on it is a root. No
    /// capture has one, so it is built from real payloads: run 1's child
    /// `SessionStart` (025), then run 6's root hooks from its first
    /// `PreInvocation` on (002–008), with only their `conversationId` value
    /// replaced by the child's.
    @Test func aConversationThatStartedEmptyIsARootOnceItHasAPrompt() throws {
        let start = AntigravityRun.headlessSubagent.envelopes[24]
        let root = AntigravityRun.cwdWithSpaces.envelopes.dropFirst().map {
            $0.replacingConversation("edadbd46-6c1a-4057-b1ac-5bf66451d9d9", with: headlessChild)
        }
        let envelopes = ([start] + root).enumerated().map { index, envelope in
            Envelope(source: envelope.source, pid: envelope.pid, payload: envelope.payload,
                     receivedAt: t0.addingTimeInterval(TimeInterval(index)), terminal: envelope.terminal)
        }
        let batches = try translate(envelopes, with: AntigravityRun.headlessSubagent.adapter(transcripts: false))
        #expect(batches[0].isEmpty)
        let revealed = batches[1]
        #expect(revealed.first?.kind == .sessionStarted(cwd: "/Users/user/dev/subspace/tools/hook-capture/antigravity", pid: nil))
        #expect(revealed.first?.timestamp == t0)
        #expect(revealed.contains { $0.kind == .promptSubmitted("Run pwd using run_command and report its output. Do not edit files.") })

        var state = CollectiveState()
        for event in batches.flatMap({ $0 }) { state.apply(event) }
        let session = try #require(state.onlySession)
        #expect(session.key == key(headlessChild))
        #expect(session.startedAt == t0)
        #expect(session.root.spec.prompt == "Run pwd using run_command and report its output. Do not edit files.")
        #expect(session.agents.count == 1)
        #expect(session.root.status == .waiting)
        #expect(session.turnEndedAt == t0.addingTimeInterval(7))
    }

    /// One that keeps sending without a link shows on its own before its `Stop`.
    @Test func anUnlinkedChildThatRunsLongShowsOnItsOwn() throws {
        let run = AntigravityRun.headlessSubagent
        let hooks = run.envelopes
        // The child's start (025, 027), then its next step (034, 035) over and over.
        let payloads = [hooks[24], hooks[26]] + Array(repeating: [hooks[33], hooks[34]], count: 200).flatMap { $0 }
        let adapter = run.adapter(transcripts: false)
        var shownAt: Int?
        var state = CollectiveState()
        for (index, hook) in payloads.enumerated() {
            let envelope = Envelope(source: hook.source, pid: hook.pid, payload: hook.payload, receivedAt: t0.addingTimeInterval(TimeInterval(index)))
            let events = try adapter.events(from: envelope)
            if shownAt == nil, !events.isEmpty { shownAt = index + 1 }
            for event in events { state.apply(event) }
        }
        #expect(shownAt == 257)
        let child = try #require(state.onlySession)
        #expect(child.key == key(headlessChild))
        #expect(child.startedAt == t0)
        #expect(child.root.status == .working)
    }

    /// While the parent waits for its child, the child's hooks are its
    /// session's activity: the idle guess doesn't take the parent for
    /// interrupted, though between its call's end (024) and its next call
    /// (036) the parent itself sends nothing the store counts for over the
    /// idle timeout. The child's do, at most six hooks apart (025–031).
    @Test func aParentWaitingForAnActiveChildIsNotGuessedInterrupted() throws {
        let run = AntigravityRun.headlessSubagent
        let spacing: TimeInterval = 18
        let envelopes = run.envelopes.enumerated().map { index, envelope in
            Envelope(source: envelope.source, pid: envelope.pid, payload: envelope.payload, receivedAt: t0.addingTimeInterval(TimeInterval(index) * spacing), terminal: envelope.terminal)
        }
        let adapter = run.adapter()
        var state = CollectiveState()
        for (index, envelope) in envelopes.enumerated() {
            state.markInterrupted(now: envelope.receivedAt.addingTimeInterval(-1), idleTimeout: idleTimeout, toolTimeout: toolTimeout)
            if (3...43).contains(index + 1) {
                #expect(state.sessions[key(headlessParent)]?.root.status == .working, "before \(index + 1)")
            }
            for event in try adapter.events(from: envelope) { state.apply(event) }
        }
        #expect(state.onlySession?.root.status == .waiting)
    }

    /// A start with another prompt while the parent waits for its subagents
    /// is the user's: the waiting turn ends interrupted. Here the resumed
    /// run (5) of run 1's parent follows its `Stop` that wasn't fully idle (030).
    @Test func anotherPromptWhileWaitingForSubagentsStartsANewTurn() throws {
        let waiting = Array(AntigravityRun.headlessSubagent.envelopes.prefix(30))
        let resumed = AntigravityRun.resume.envelopes.map {
            Envelope(source: $0.source, pid: $0.pid, payload: $0.payload, receivedAt: $0.receivedAt.addingTimeInterval(60), terminal: $0.terminal)
        }
        let adapter = AntigravityRun.headlessSubagent.adapter()
        _ = try translate(waiting, with: adapter)
        let start = try adapter.events(from: resumed[0]).map(\.kind).filter(\.isTurnEvent)
        #expect(start == [.turnEnded(.interrupted), .promptSubmitted("Run pwd using run_command and report it. Do not edit files.")])

        let state = try replay(waiting + resumed, with: AntigravityRun.headlessSubagent.adapter())
        let session = try #require(state.onlySession)
        #expect(session.root.spec.prompt == "Run pwd using run_command and report it. Do not edit files.")
        #expect(session.root.status == .waiting)
        #expect(session.turnEndedAt == t0.addingTimeInterval(60 + 6))
    }
}

private extension [Envelope] {
    /// Without the hooks of one conversation.
    func without(_ conversation: String) -> [Envelope] {
        filter { !String(decoding: $0.payload, as: UTF8.self).contains(conversation) }
    }
}

private extension Envelope {
    /// The same hook with only its `conversationId` value replaced; the
    /// paths that name the conversation stay as captured.
    func replacingConversation(_ conversation: String, with other: String) -> Envelope {
        let text = String(decoding: payload, as: UTF8.self)
        let field = #""conversationId":"\#(conversation)""#
        precondition(text.contains(field), "no conversationId \(conversation)")
        let replaced = text.replacingOccurrences(of: field, with: #""conversationId":"\#(other)""#)
        return Envelope(source: source, pid: pid, payload: Data(replaced.utf8), receivedAt: receivedAt, terminal: terminal)
    }
}

// MARK: - Tool calls

@Suite struct AntigravityToolCallTests {
    /// The store drops `tool_input` (`excludedFields`), a call's whole
    /// arguments, e.g. all of a `write_file`'s content: what the adapter
    /// needs of them comes as target fields of their own.
    @Test(arguments: AntigravityRun.allCases)
    func theEventsDontNeedTheExcludedFields(run: AntigravityRun) throws {
        let whole = run.adapter()
        let stripped = run.adapter()
        #expect(stripped.excludedFields == ["tool_input"])
        let document = try #require(stripped.mappingDocument())
        var dropped = 0
        for envelope in run.envelopes {
            var mapped = MappingInterpreter.apply(document, to: try JSONValue(data: envelope.payload))
            for field in stripped.excludedFields {
                if mapped.block.removeValue(forKey: JSONKey(field)) != nil { dropped += 1 }
                mapped.core[JSONKey(field)] = nil
            }
            #expect(try stripped.events(from: envelope, mapped: mapped) == whole.events(from: envelope))
        }
        #expect(dropped > 0, "every run has tool calls")
    }

    /// An `invoke_subagent` call shows the role it gives its subagent.
    @Test func aSpawnCallShowsTheSubagentsRole() throws {
        let headless = AntigravityRun.headlessSubagent
        // Up to and including the spawn call (023).
        let waiting = try replay(Array(headless.envelopes.prefix(23)), with: headless.adapter())
        #expect(waiting.sessions[key(headlessParent)]?.root.currentTool
            == ToolActivity(name: "invoke_subagent", detail: "Capture Verification Subagent"))

        let parallel = AntigravityRun.parallelSubagents
        let spawns = try translate(parallel.envelopes, with: parallel.adapter()).flatMap { $0 }.compactMap { event in
            if case let .toolStarted(_, tool, _, _) = event.kind, tool.name == "invoke_subagent" { tool } else { nil }
        }
        #expect(spawns == [
            ToolActivity(name: "invoke_subagent", detail: "Alpha Runner"),
            ToolActivity(name: "invoke_subagent", detail: "Beta Reader"),
        ])
    }
}

// MARK: - Effort

@Suite struct AntigravityEffortTests {
    @Test(arguments: [
        ("gemini-3.8-flash-low", 1, "low"),
        ("gemini-4-neon-high", 3, "high"),
        ("gemini-4-neon-minimal", 1, "minimal"),
        ("gemini-4-neon-medium", 2, "medium"),
        ("gemini-4-neon-xhigh", 4, "xhigh"),
        ("gemini-4-neon-max", 5, "max"),
        ("gemini-4-neon-ultra", 5, "ultra"),
    ])
    func readsAKnownSuffix(model: String, step: Int, name: String) {
        #expect(AntigravityAdapter.effortLevel(model: model) == EffortLevel(step: step, name: name))
    }

    @Test(arguments: ["gemini-4-neon", "gemini-3.8-flash", "high", "-high", "gemini-4-neon-High", ""])
    func readsNoUnknownSuffix(model: String) {
        #expect(AntigravityAdapter.effortLevel(model: model) == nil)
    }
}

// MARK: - Roots and identity

@Suite struct AntigravityAdapterIdentityTests {
    @Test func spoolsIntoTheCLIPluginData() {
        let root = AntigravityAdapter(mapping: bundledMapping()).spoolRoot(environment: [:], home: home)
        #expect(root.path == "/Users/user/.gemini/antigravity-cli/plugin_data/subspace")
    }

    @Test func spoolsIntoTheCLIAndTheDesktopAppPluginData() {
        let roots = AntigravityAdapter(mapping: bundledMapping()).spoolRoots(environment: [:], home: home)
        #expect(roots.map(\.path) == [
            "/Users/user/.gemini/antigravity-cli/plugin_data/subspace",
            "/Users/user/.gemini/antigravity/plugin_data/subspace",
        ])
    }

    @Test func aChosenFolderOrSUBSPACE_DIRReplacesBothRoots() {
        let adapter = AntigravityAdapter(mapping: bundledMapping())
        let chosen = URL(fileURLWithPath: "/chosen", isDirectory: true)
        #expect(SubspaceRoot.resolveAll(adapter: adapter, environment: [:], home: home).count == 2)
        #expect(SubspaceRoot.resolveAll(adapter: adapter, chosen: chosen, environment: ["SUBSPACE_DIR": "/shared"], home: home)
            .map(\.path) == ["/chosen"])
        #expect(SubspaceRoot.resolveAll(adapter: adapter, environment: ["SUBSPACE_DIR": "/shared"], home: home)
            .map(\.path) == ["/shared"])
    }

    /// The plugin writes its mapping into whichever root it runs in, so the
    /// desktop app's copy counts as much as the CLI's.
    @Test func theDefaultMappingTakesTheHighestRevisionOfBothRoots() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let text = try String(contentsOf: try #require(MappingLoader.bundledURL(named: "antigravity")), encoding: .utf8)
        let bundledRevision = try #require(MappingLoader.bundledDocument(named: "antigravity")?.revision)
        for (folder, revision) in [("antigravity-cli", 98), ("antigravity", 99)] {
            let model = home.appendingPathComponent(".gemini/\(folder)/plugin_data/subspace/model", isDirectory: true)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            let drifted = text.replacingOccurrences(of: #""revision": \#(bundledRevision),"#, with: #""revision": \#(revision),"#)
            try Data(drifted.utf8).write(to: model.appendingPathComponent("antigravity.json"))
        }
        let loader = AntigravityAdapter.defaultMapping(environment: [:], home: home)
        #expect(loader.document(named: "antigravity")?.revision == 99)
        // A chosen folder is the only root then: neither copy counts.
        let chosen = AntigravityAdapter.defaultMapping(chosen: URL(fileURLWithPath: "/nowhere"), environment: [:], home: home)
        #expect(chosen.document(named: "antigravity")?.revision == bundledRevision)
    }

    @Test func resumesWithTheConversationID() {
        let adapter = AntigravityAdapter(mapping: bundledMapping())
        #expect(adapter.source == "antigravity")
        #expect(adapter.displayName == "Antigravity")
        #expect(adapter.logoName == "antigravity")
        #expect(adapter.resumeCommand?.arguments(sessionID: headlessParent) == ["agy", "--conversation", headlessParent])
    }

    @Test func readsThroughTheBundledMapping() {
        #expect(AntigravityAdapter(mapping: bundledMapping()).mappingDocument()?.source == "antigravity")
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
