import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// The effort level of Claude Code agents against captured runs: S25
// (2.1.319, sonnet through every `/effort` level, then two `Agent` calls, one
// with its own effort) and S16 (2.1.289, a haiku and a sonnet subagent).

// MARK: - Fixtures

private let s25 = Timeline("25-effort", version: "2.1.319")

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

/// The events of hook `n`, after every earlier hook of the run went through
/// the same adapter; `payload` replaces the hook's own.
private func kinds(of n: Int, in run: Timeline, payload: Data? = nil) throws -> [AgentEvent.Kind] {
    let adapter = ClaudeCodeAdapter(metaReader: NoMeta(), mapping: bundledMapping())
    for entry in run.entries where entry.isHook && entry.n < n {
        _ = try adapter.events(from: envelope(run.data(entry), of: run, at: entry))
    }
    let entry = run.entry(n: n)
    return try adapter.events(from: envelope(payload ?? run.data(entry), of: run, at: entry)).map(\.kind)
}

/// Only the effort reports among `kinds`.
private func efforts(_ kinds: [AgentEvent.Kind]) -> [AgentEvent.Kind] {
    kinds.filter {
        if case .effortReported = $0 { return true }
        return false
    }
}

private func effort(_ step: Int, _ name: String) -> EffortLevel { EffortLevel(step: step, name: name)! }

// MARK: - Adapter

/// Adapter seam: which hooks of S25 report whose effort.
@Suite struct ClaudeCodeEffortTests {
    /// Sonnet starts at `medium` before any `/effort`; the report comes after
    /// the hook's own events, which make the session known to the store.
    @Test func aToolStartReportsTheOrchestratorsEffortAfterItself() throws {
        #expect(try kinds(of: 8, in: s25) == [
            .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "echo default"), callID: "toolu_0119TrF48RHTjiFbkEyC96x2"),
            .effortReported(agent: .root, effort(2, "medium")),
        ])
    }

    /// Every `/effort` shows on the next hook carrying the field, the
    /// failing call's end and the turn's stop too.
    @Test(arguments: [
        (18, 1, "low"), (20, 1, "low"), (21, 1, "low"),
        (28, 2, "medium"), (38, 3, "high"), (48, 4, "xhigh"), (57, 5, "max"),
        (66, 5, "max"), (68, 5, "max"),
    ])
    func eachHookCarryingTheLevelReportsTheOrchestrators(n: Int, step: Int, name: String) throws {
        #expect(efforts(try kinds(of: n, in: s25)) == [.effortReported(agent: .root, effort(step, name))])
    }

    /// The subagent started with `effort: "high"` runs at its own level, the
    /// other inherits the orchestrator's `max` for this session, not the
    /// saved `xhigh`.
    @Test(arguments: [
        (80, "abc55eb11550b885d", 3, "high"), (82, "abc55eb11550b885d", 3, "high"), (87, "abc55eb11550b885d", 3, "high"),
        (84, "aaafa080a35df2c26", 5, "max"), (89, "aaafa080a35df2c26", 5, "max"),
    ])
    func aSubagentsHooksReportItsOwnLevel(n: Int, agent: String, step: Int, name: String) throws {
        let kinds = try kinds(of: n, in: s25)
        #expect(efforts(kinds) == [.effortReported(agent: .subagent(agent), effort(step, name))])
        #expect(kinds.last == .effortReported(agent: .subagent(agent), effort(step, name)))
    }

    /// The prompt, a subagent's start and the session's end carry no level:
    /// nothing to report, nothing to clear.
    @Test(arguments: [7, 17, 74, 88, 100])
    func hooksWithoutTheLevelReportNone(n: Int) throws {
        #expect(efforts(try kinds(of: n, in: s25)) == [])
    }

    /// Claude Code's internal agents (`agent_type: ""`) carry the level on
    /// their `SubagentStop` but stay unseen.
    @Test(arguments: [13, 23, 70, 90, 95, 97])
    func anInternalAgentsStopReportsNone(n: Int) throws {
        #expect(try kinds(of: n, in: s25) == [])
    }

    /// No capture has a level off Claude Code's scale; this is S25-057's real
    /// payload with only `effort.level` replaced by one the scale lacks.
    @Test(arguments: ["auto", "turbo"])
    func aLevelOffTheScaleReportsNone(level: String) throws {
        let entry = s25.entry(n: 57)
        var payload = try #require(try JSONSerialization.jsonObject(with: s25.data(entry)) as? [String: Any])
        payload["effort"] = ["level": level]
        let kinds = try kinds(of: 57, in: s25, payload: JSONSerialization.data(withJSONObject: payload))
        #expect(kinds.count == 1)
        #expect(efforts(kinds) == [])
    }
}

/// Adapter seam: haiku has no effort, so its hooks carry none (S16).
@Suite struct ClaudeCodeEffortHaikuTests {
    /// The effort reports of every hook of S16, by file, replayed one second apart.
    private func reports() throws -> [(file: String, kind: AgentEvent.Kind)] {
        let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/claude-code/2.1.289/16-agent-model/events")
        let adapter = ClaudeCodeAdapter(metaReader: NoMeta(), mapping: bundledMapping())
        var reports: [(file: String, kind: AgentEvent.Kind)] = []
        for (index, file) in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted().enumerated() {
            let payload = try Data(contentsOf: directory.appendingPathComponent(file))
            let envelope = Envelope(source: "claude-code", pid: 4242, payload: payload, receivedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index)))
            reports += efforts(try adapter.events(from: envelope).map(\.kind)).map { (file, $0) }
        }
        return reports
    }

    @Test func theHaikuSubagentReportsNoLevelWhileTheSonnetOneDoes() throws {
        let reports = try reports()
        let haiku = AgentRef.subagent("a99b925b23945c344")
        let sonnet = AgentRef.subagent("a2a34e739949f479b")
        #expect(!reports.contains {
            if case .effortReported(haiku, _) = $0.kind { return true }
            return false
        })
        #expect(reports.filter { $0.kind == .effortReported(agent: sonnet, effort(2, "medium")) }.map(\.file) == [
            "016-PreToolUse.json", "017-PostToolUse.json", "019-PostToolBatch.json", "020-SubagentStop.json",
        ])
    }
}

// MARK: - Store

/// The only session of a replayed run.
private func session(_ state: CollectiveState) throws -> Session {
    try #require(state.sessions.values.first)
}

/// Store seam: S25 replayed through adapter and status reports into the state.
@Suite struct ClaudeCodeEffortStoreTests {
    /// `/effort low` fired no hook; the change shows with the next tool start
    /// (018, 1794242526.908 s, whole seconds in the envelope), as of then.
    @Test func aChangeShowsWithTheNextHookCarryingTheLevel() throws {
        let before = try session(s25.replay(through: 17))
        #expect(before.effort == effort(2, "medium"))
        #expect(before.lastEffortChange == nil)

        let after = try session(s25.replay(through: 18))
        #expect(after.effort == effort(1, "low"))
        #expect(after.lastEffortChange == EffortChange(from: effort(2, "medium"), at: Date(timeIntervalSince1970: 1_794_242_526)))
    }

    /// The prompts carry no level and leave the known one alone, the
    /// subagents' hand-back turn too.
    @Test(arguments: [(27, 1, "low"), (88, 5, "max"), (93, 5, "max")])
    func aPromptKeepsTheKnownLevel(n: Int, step: Int, name: String) throws {
        #expect(try session(s25.replay(through: n)).effort == effort(step, name))
    }

    /// Orchestrator and subagents each keep their own; the internal agents
    /// stay unseen, their level with them.
    @Test func eachAgentKeepsItsOwnLevel() throws {
        let session = try session(s25.replay(through: 97))
        #expect(session.effort == effort(5, "max"))
        #expect(session.lastEffortChange == EffortChange(from: effort(4, "xhigh"), at: Date(timeIntervalSince1970: 1_794_242_556)))
        #expect(session.agents[.subagent("abc55eb11550b885d")]?.effort == effort(3, "high"))
        #expect(session.agents[.subagent("aaafa080a35df2c26")]?.effort == effort(5, "max"))
        #expect(Set(session.agents.keys) == [.root, .subagent("abc55eb11550b885d"), .subagent("aaafa080a35df2c26")])
    }
}

// MARK: - Presentation

/// Presentation seam: the card's model carries the gauge mid-run.
@Suite struct ClaudeCodeEffortPopoverTests {
    @Test func theCardsModelShowsTheOrchestratorsLevel() throws {
        let entry = s25.entry(n: 48)
        let popover = PopoverModel(
            state: try s25.replay(through: 48), now: entry.at.addingTimeInterval(1), settings: PopoverSettings(),
            modelNaming: ["claude-code": ClaudeCodeModelNaming()]
        )
        let item = try #require((popover.sessions + popover.idle).first)
        let gauge = try #require(item.model?.effort)
        #expect(gauge.step == 4)
        #expect(gauge.name == "xhigh")
    }
}

