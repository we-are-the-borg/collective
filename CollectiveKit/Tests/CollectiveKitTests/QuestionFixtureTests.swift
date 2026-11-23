import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// MARK: - Fixtures

private let s4 = Timeline("4-waiting-permission-question")
private let s19 = Timeline("19-ask-user-question", version: "2.1.316")

private struct NoMeta: SubagentMetaReading {
    func meta(transcriptPath: String, agentID: String) -> SubagentMeta? { nil }
}

private final class MemoryFileSystem: MappingFileSystem {
    func modificationDate(of url: URL) -> Date? { nil }
    func contents(of url: URL) throws -> Data { throw CocoaError(.fileNoSuchFile) }
}

/// A root without `model/`, so the bundled documents are used.
private func bundledMapping() -> MappingLoader {
    MappingLoader(root: URL(filePath: "/spool/root", directoryHint: .isDirectory), fileSystem: MemoryFileSystem())
}

private func envelope(_ payload: Data, of run: Timeline, at entry: Timeline.Entry) throws -> Envelope {
    Envelope(source: "claude-code", pid: try run.envelopePID(), payload: payload, receivedAt: entry.at)
}

/// The S19 payloads also carry an effort level, which the adapter reports
/// after the question; these tests are about the question's own events.
private func withoutEffort(_ kinds: [AgentEvent.Kind]) -> [AgentEvent.Kind] {
    kinds.filter { if case .effortReported = $0 { false } else { true } }
}

/// The events of hook `n`, after every earlier hook of the run went through
/// the same adapter.
private func kinds(of n: Int, in run: Timeline) throws -> [AgentEvent.Kind] {
    let adapter = ClaudeCodeAdapter(metaReader: NoMeta(), mapping: bundledMapping())
    for entry in run.entries where entry.isHook && entry.n < n {
        _ = try adapter.events(from: envelope(run.data(entry), of: run, at: entry))
    }
    let entry = run.entry(n: n)
    return try adapter.events(from: envelope(run.data(entry), of: run, at: entry)).map(\.kind)
}

private let color = Question(
    header: "Color preference",
    text: "Which color do you like?",
    options: [
        QuestionOption(label: "Red", detail: "A warm, bold color"),
        QuestionOption(label: "Blue", detail: "A cool, calm color"),
    ],
    allowsMultiple: false,
    allowsOwnAnswer: true
)
private let colorCall = "toolu_01XWWJER73MBr9UH78Hqdn4i"

// MARK: - Adapter

/// Adapter seam: what a Claude Code `AskUserQuestion` call reports, from the
/// captured runs S4 (2.1.287) and S19 (2.1.316).
@Suite struct ClaudeCodeQuestionTests {
    /// The call's start asks, besides starting the tool.
    @Test func theCallsStartAsksItsQuestions() throws {
        #expect(try kinds(of: 26, in: s4) == [
            .toolStarted(agent: .root, ToolActivity(name: "AskUserQuestion"), callID: colorCall),
            .questionAsked(agent: .root, [color], callID: colorCall),
        ])
    }

    /// Claude Code asks through the permission dialog, but it is a question.
    /// That hook names no call.
    @Test func thePermissionDialogAsksAgainAndRequestsNoPermission() throws {
        #expect(try kinds(of: 28, in: s4) == [.questionAsked(agent: .root, [color])])
    }

    @Test func theCallsEndAnswersByTheQuestionsText() throws {
        var answered = color
        answered.answer = "Red"
        #expect(try kinds(of: 31, in: s4) == [
            .toolFinished(agent: .root, callID: colorCall, duration: 0),
            .questionAnswered(agent: .root, [answered], callID: colorCall),
        ])
    }

    /// Several picked options come as one text, a typed answer as typed.
    @Test func twoQuestionsAnsweredWithAMultipleChoiceAndFreeText() throws {
        let fruits = Question(
            header: "Fruits",
            text: "Which fruits do you like?",
            options: [
                QuestionOption(label: "apple", detail: "Apple"),
                QuestionOption(label: "banana", detail: "Banana"),
                QuestionOption(label: "cherry", detail: "Cherry"),
            ],
            allowsMultiple: true,
            allowsOwnAnswer: true,
            answer: "apple, cherry"
        )
        let pet = Question(
            header: "Pet",
            text: "Which pet do you prefer?",
            options: [QuestionOption(label: "cat", detail: "Cat"), QuestionOption(label: "dog", detail: "Dog")],
            allowsOwnAnswer: true,
            answer: "a parrot"
        )
        #expect(try withoutEffort(kinds(of: 13, in: s19)).last == .questionAnswered(agent: .root, [fruits, pet], callID: "toolu_01MNW86sGoW8YK1M6F4KFWYw"))
    }

    /// Options with a `preview` and an answer with a note (`annotations`):
    /// neither is part of the question.
    @Test func previewsAndNotesStayOut() throws {
        let layout = Question(
            header: "Layout",
            text: "Which layout do you prefer?",
            options: [
                QuestionOption(label: "Grid", detail: "Items arranged in rows and columns"),
                QuestionOption(label: "List", detail: "Items stacked one below another"),
            ],
            allowsOwnAnswer: true,
            answer: "List"
        )
        #expect(try withoutEffort(kinds(of: 24, in: s19)).last == .questionAnswered(agent: .root, [layout], callID: "toolu_01DUziLVG5d6qZ4Qywd7A61r"))
    }

    /// Hooks run async: a start arriving after its end asks nothing anymore.
    @Test func aStartArrivingAfterItsEndAsksNothing() throws {
        let adapter = ClaudeCodeAdapter(metaReader: NoMeta(), mapping: bundledMapping())
        for entry in s4.entries where entry.isHook && entry.n < 26 {
            _ = try adapter.events(from: envelope(s4.data(entry), of: s4, at: entry))
        }
        let start = s4.entry(n: 26), end = s4.entry(n: 31)
        _ = try adapter.events(from: envelope(s4.data(end), of: s4, at: end))
        let late = try adapter.events(from: envelope(s4.data(start), of: s4, at: start)).map(\.kind)
        #expect(late == [.toolStarted(agent: .root, ToolActivity(name: "AskUserQuestion"), callID: colorCall, alreadyEnded: true)])
    }

    /// A subagent not identified yet has its tool start held
    /// back, but its questions dropped like its permission requests; once
    /// identified, the dialog's hook asks them. No capture has a subagent
    /// asking: the payloads are S4's 026 and 028 with `agent_id` added, and
    /// the agent's start is derived from 026 and so also carries its tool fields.
    @Test func aSubagentNotIdentifiedYetAsksOnlyThroughTheDialog() throws {
        func derived(_ n: Int, _ fields: [String: Any]) throws -> (Data, Timeline.Entry) {
            let entry = s4.entry(n: n)
            let payload = try #require(try JSONSerialization.jsonObject(with: s4.data(entry)) as? [String: Any])
            return (try JSONSerialization.data(withJSONObject: payload.merging(fields) { $1 }), entry)
        }
        let start = try derived(26, ["agent_id": "x1"])
        let dialog = try derived(28, ["agent_id": "x1"])
        let spawn = try derived(26, ["hook_event_name": "SubagentStart", "agent_id": "x1", "agent_type": "general-purpose"])

        let adapter = ClaudeCodeAdapter(metaReader: NoMeta(), mapping: bundledMapping())
        for entry in s4.entries where entry.isHook && entry.n < 26 {
            _ = try adapter.events(from: envelope(s4.data(entry), of: s4, at: entry))
        }
        let kinds = try [start, spawn, dialog].map { payload, entry in
            try adapter.events(from: envelope(payload, of: s4, at: entry)).map(\.kind)
        }
        #expect(kinds == [
            [],
            [
                .agentSpawned(id: "x1", parent: .root, spec: AgentSpec(type: "general-purpose")),
                .toolStarted(agent: .subagent("x1"), ToolActivity(name: "AskUserQuestion"), callID: colorCall),
            ],
            [.questionAsked(agent: .subagent("x1"), [color])],
        ])
    }

    /// The event store keeps mapped results without `tool_response`
    /// (`excludedFields`); the answers come as a field of their own.
    @Test func theAnswerSurvivesTheStoredFieldsLeftOut() throws {
        let adapter = ClaudeCodeAdapter(metaReader: NoMeta(), mapping: bundledMapping())
        let document = try #require(adapter.mappingDocument())
        let entry = s4.entry(n: 31)
        var mapped = MappingInterpreter.apply(document, to: try JSONValue(data: s4.data(entry)))
        #expect(mapped.block["tool_response"] != nil)
        for field in adapter.excludedFields {
            mapped.core[JSONKey(field)] = nil
            mapped.block[JSONKey(field)] = nil
        }
        let kinds = try adapter.events(from: envelope(s4.data(entry), of: s4, at: entry), mapped: mapped).map(\.kind)
        guard case let .questionAnswered(_, questions, _)? = kinds.last else {
            Issue.record("no answer in \(kinds)")
            return
        }
        #expect(questions.map(\.answer) == ["Red"])
    }
}

// MARK: - Store

/// Reducer seam with the captured runs: an open question ends like a
/// permission request, or with its answer.
@Suite struct QuestionWaitTests {
    /// The timeline entries after which the session awaits an answer.
    private func entriesAwaitingAnswer(_ run: Timeline, statuses: Bool = true) throws -> [Int] {
        try run.entries
            .filter { statuses || $0.isHook }
            .filter { try run.replay(through: $0.n, statuses: statuses).awaitsAnswer }
            .map(\.n)
    }

    /// Asked with 026 and again with 028; the status file reports `busy`
    /// with the answer (030), right before its hook (031).
    @Test func aQuestionWaitsUntilTheUserAnswers() throws {
        #expect(try entriesAwaitingAnswer(s4) == [26, 27, 28, 29])
        let asked = try #require(s4.replay(through: 28).sessions.values.first)
        #expect(asked.openQuestions(of: .root) == [color])
        #expect(asked.awaitsAnswer(.root))
    }

    /// Without the status file the answer itself closes it.
    @Test func hooksAloneWaitUntilTheAnswer() throws {
        #expect(try entriesAwaitingAnswer(s4, statuses: false) == [26, 28, 29])
    }

    /// Answered (013, 024), then dismissed with Esc (after 033), which sends
    /// no hook: only the status file going `idle` (035) closes it.
    @Test func aDismissedQuestionWaitsUntilTheStatusFileSaysIdle() throws {
        #expect(try entriesAwaitingAnswer(s19) == [8, 9, 10, 11, 20, 21, 22, 31, 32, 33, 34])
    }

    /// Without the status file the dismissed question waits for the next prompt (037).
    @Test func hooksAloneWaitForTheNextPromptAfterADismissal() throws {
        #expect(try entriesAwaitingAnswer(s19, statuses: false) == [8, 10, 11, 20, 22, 31, 33, 34])
    }

    /// A question is no permission request, though the status file says
    /// `waiting` for both. S4 asks for permission before its question (024).
    @Test func aQuestionAsksNoPermission() throws {
        for entry in s4.entries where entry.n >= 24 {
            #expect(try !s4.replay(through: entry.n).awaitsPermission, "S4 \(entry.n)")
        }
        for entry in s19.entries {
            #expect(try !s19.replay(through: entry.n).awaitsPermission, "S19 \(entry.n)")
        }
    }
}

/// Reducer seam with made-up events of a made-up tool: what the captured
/// runs don't show.
@Suite struct QuestionStateTests {
    private let key = SessionKey(source: "test-tool", sessionID: "s1")
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let question = Question(text: "Tea or coffee?", options: [QuestionOption(label: "tea"), QuestionOption(label: "coffee")])

    private func state(_ events: [(TimeInterval, AgentEvent.Kind)]) -> CollectiveState {
        var state = CollectiveState()
        for (seconds, kind) in events { state.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(seconds), kind: kind)) }
        return state
    }

    private func asking(_ agent: AgentRef = .root) -> CollectiveState {
        var events: [(TimeInterval, AgentEvent.Kind)] = [(0, .promptSubmitted("go"))]
        if case let .subagent(id) = agent { events.append((1, .agentSpawned(id: id, parent: .root, spec: AgentSpec(type: "explore")))) }
        events.append((10, .questionAsked(agent: agent, [question], callID: "c1")))
        return state(events)
    }

    /// The answer ends the question even without the call's end.
    @Test func theAnswerEndsIt() {
        var s = asking()
        #expect(s.awaitsAnswer)
        var answered = question
        answered.answer = "tea"
        s.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(20), kind: .questionAnswered(agent: .root, [answered], callID: "c1")))
        #expect(!s.awaitsAnswer)
        #expect(s.sessions[key]!.openQuestions(of: .root).isEmpty)
    }

    /// The dialog asks the same as the call's start, without its id: one set of questions.
    @Test func theDialogAskingAgainKeepsOneSetOfQuestions() {
        var s = asking()
        s.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(10), kind: .questionAsked(agent: .root, [question])))
        #expect(s.sessions[key]!.openQuestions(of: .root) == [question])
        #expect(s.sessions[key]!.questionRequests[.root]?.callID == "c1")
    }

    /// Like a permission request: an answer that arrives
    /// before its question leaves nothing open.
    @Test func aQuestionArrivingAfterItsAnswerAsksNothing() {
        let s = state([
            (0, .promptSubmitted("go")),
            (20, .questionAnswered(agent: .root, [question], callID: "c1")),
            (10, .questionAsked(agent: .root, [question])),
        ])
        #expect(!s.awaitsAnswer)
    }

    /// A waiting root with nothing running would rest, but not while asked.
    @Test func aSessionAskingDoesNotRest() {
        let ended = state([(0, .promptSubmitted("go")), (5, .turnEnded())])
        #expect(ended.sessions[key]!.rests)

        var s = ended
        s.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(10), kind: .questionAsked(agent: .root, [question])))
        #expect(s.awaitsAnswer)
        #expect(!s.sessions[key]!.rests)
    }

    @Test func aDoneAgentAsksNothing() {
        var s = asking(.subagent("a"))
        #expect(s.sessions[key]!.awaitsAnswer(.subagent("a")))
        s.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(10), kind: .agentFinished(id: "a")))
        #expect(!s.awaitsAnswer)
        #expect(s.sessions[key]!.openQuestions(of: .subagent("a")).isEmpty)
    }

    @Test func anArchivedAgentAsksNothing() {
        var s = asking(.subagent("a"))
        s.archive(.agent(key, .subagent("a")), at: t0.addingTimeInterval(20))
        #expect(s.sessions[key]!.awaitsAnswer)
        #expect(!s.awaitsAnswer)

        var session = asking()
        session.archive(.session(key), at: t0.addingTimeInterval(20))
        #expect(!session.awaitsAnswer)
    }

    /// Without a process the silence timeout would end a session whose user
    /// is asked; it gets the longer wait instead.
    @Test func aSessionAskingOutlastsTheSilenceTimeout() {
        var s = asking()
        s.markStale(now: t0.addingTimeInterval(10 + 40 * 60), silenceTimeout: 30 * 60, waitingTimeout: 12 * 3_600) { _ in nil }
        #expect(s.sessions[key]!.endedAt == nil)
        #expect(s.awaitsAnswer)
    }
}
