import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// The reasoning effort of Codex agents against captured runs of Codex
// 0.167.0: R4 (`4-effort-levels`: turn 1 at low, `/model` to high, turn 2,
// then turn 3 spawning one child that runs at its own medium) and R1–R3 (high
// throughout). No hook carries the effort; each turn's `turn_context` record in
// its rollout does (subspace contract §6, `docs/model.md` §4.3).

// MARK: - Fixtures

private let r4 = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/codex/0.167.0/4-effort-levels")

private let rootThread = "01a1c1e8-6082-7422-80f4-53c2796d361e"
private let childThread = "01a1c1e9-2e62-7de3-8d90-cc34bb9539b8"
private let turn1 = "01a1c1e8-78f5-7341-8036-5a7a3d0265f7"
private let turn2 = "01a1c1e9-091e-7eb2-b850-f8bb85d1d4a6"
private let turn3 = "01a1c1e9-2061-7f43-b518-e8515572a23e"
private let childTurn = "01a1c1e9-2e9d-7ac1-ac4c-6edacde01c01"
private let childRow = "\(childThread)/\(childTurn)"

/// R4's two rollouts as files: the excerpt keeps the root's records in lines
/// 1–3 and the child's in line 4 (fixture README). Written to a temporary
/// folder so a test can let a record arrive late.
private final class R4Rollouts {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rollouts-\(UUID().uuidString)")
    let lines: [String]

    /// `rootLines` of the excerpt's three root records go into the root's rollout at first.
    /// `childRecord: false` leaves the child's file empty until the test appends it.
    init(rootLines: Int = 3, childRecord: Bool = true) throws {
        lines = try String(contentsOf: r4.appendingPathComponent("rollouts/excerpt.jsonl"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(lines.prefix(rootLines).map { $0 + "\n" }.joined().utf8).write(to: url(rootThread))
        try Data((childRecord ? lines[3] + "\n" : "").utf8).write(to: url(childThread))
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func url(_ thread: String) -> URL { directory.appendingPathComponent("\(thread).jsonl") }

    /// Codex writing excerpt line `n` (1-based) of the root's rollout.
    func appendRootLine(_ n: Int) throws {
        let handle = try FileHandle(forWritingTo: url(rootThread))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines[n - 1] + "\n").utf8))
    }

    /// Codex writing the child's record (excerpt line 4).
    func appendChildRecord() throws {
        let handle = try FileHandle(forWritingTo: url(childThread))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines[3] + "\n").utf8))
    }

    /// The real file reader, reading a thread's file here for the path on the capture machine.
    var reader: RolloutsByThread { RolloutsByThread(files: [rootThread: url(rootThread).path, childThread: url(childThread).path]) }
}

/// The real file reader; a rollout path ending in `<thread>.jsonl` reads that thread's file.
private struct RolloutsByThread: RolloutMetaReading {
    let files: [String: String]
    private let reader = FileRolloutMetaReader()

    init(files: [String: String]) { self.files = files }

    private func local(_ path: String) -> String {
        files.first { path.hasSuffix("\($0.key).jsonl") }?.value ?? path
    }

    func meta(rolloutPath: String) -> RolloutMeta? { reader.meta(rolloutPath: local(rolloutPath)) }

    func approvalsReviewer(rolloutPath: String, turnID: String) -> String? {
        reader.approvalsReviewer(rolloutPath: local(rolloutPath), turnID: turnID)
    }

    func effort(rolloutPath: String, turnID: String) -> String? {
        reader.effort(rolloutPath: local(rolloutPath), turnID: turnID)
    }
}

// MARK: - Reader

/// Reader seam: the effort of a turn, from the `turn_context` records of its rollout.
@Suite struct CodexRolloutEffortTests {
    @Test func findsEachTurnsEffortInItsOwnRollout() throws {
        let rollouts = try R4Rollouts()
        let reader = FileRolloutMetaReader()
        let root = rollouts.url(rootThread).path
        #expect(reader.effort(rolloutPath: root, turnID: turn1) == "low")
        #expect(reader.effort(rolloutPath: root, turnID: turn2) == "high")
        #expect(reader.effort(rolloutPath: root, turnID: turn3) == "high")
        let child = rollouts.url(childThread).path
        #expect(reader.effort(rolloutPath: child, turnID: childTurn) == "medium")
        // The child's turn is not in the root's rollout.
        #expect(reader.effort(rolloutPath: root, turnID: childTurn) == nil)
    }

    @Test(arguments: [
        ("1-auto-review-approvals", ["01a1b6e3-32c3-7c51-856d-747fe4f0a6d4", "01a1b6e3-76aa-74b3-afe7-e69d1d7be121",
                                     "01a1b6e3-d44b-7c11-84b6-f35589595c0c", "01a1b6e4-16ef-7892-b1e7-5608030420d6"]),
        ("2-auto-review-rejection", ["01a1b6e2-2761-7ea0-bbbe-724453cf88bd", "01a1b6e2-7231-7e02-a8c6-51229fea2c8a",
                                     "01a1b6e2-b955-7ff0-982c-bfae404f11f7"]),
        ("3-manual-review-approval-denial", ["01a1b6e6-05bb-7800-98dd-5869bfc24848", "01a1b6e6-4212-7f80-bf8f-09770631eb0f"]),
    ])
    func theReviewRunsRanAtHigh(run: String, turns: [String]) {
        let reader = FileRolloutMetaReader()
        let excerpt = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/codex/0.167.0/\(run)/rollouts/excerpt.jsonl").path
        for turn in turns {
            #expect(reader.effort(rolloutPath: excerpt, turnID: turn) == "high")
        }
    }

    /// One scan serves both questions: the reviewer of a turn asked first
    /// leaves its effort known, and the other way round.
    @Test func reviewerAndEffortComeFromTheSameRecord() throws {
        let rollouts = try R4Rollouts()
        let reader = FileRolloutMetaReader()
        let root = rollouts.url(rootThread).path
        #expect(reader.approvalsReviewer(rolloutPath: root, turnID: turn2) == "auto_review")
        #expect(reader.effort(rolloutPath: root, turnID: turn2) == "high")
        #expect(reader.effort(rolloutPath: root, turnID: turn1) == "low")
        #expect(reader.approvalsReviewer(rolloutPath: root, turnID: turn1) == "auto_review")
    }
}

// MARK: - Adapter

/// Serves nothing, so the bundled mapping document is used.
private final class NoFiles: MappingFileSystem {
    func modificationDate(of url: URL) -> Date? { nil }
    func contents(of url: URL) throws -> Data { throw CocoaError(.fileNoSuchFile) }
}

private func bundledMapping() -> MappingLoader {
    MappingLoader(root: URL(filePath: "/spool/root", directoryHint: .isDirectory), fileSystem: NoFiles())
}

private let t0 = Date(timeIntervalSince1970: 1_000)

/// R4's hooks in delivery order, `NNN-<hook>.json` with the raw payload.
private var r4Files: [(name: String, payload: Data)] {
    let events = r4.appendingPathComponent("events")
    let names = try! FileManager.default.contentsOfDirectory(atPath: events.path).sorted()
    return names.map { ($0, try! Data(contentsOf: events.appendingPathComponent($0))) }
}

/// Hook `n` of R4 (1-based) one second after the one before it.
private func envelope(_ n: Int) -> Envelope {
    Envelope(source: "codex", pid: 4242, payload: r4Files[n - 1].payload, receivedAt: t0.addingTimeInterval(TimeInterval(n)))
}

/// Only the effort reports among `kinds`.
private func efforts(_ kinds: [AgentEvent.Kind]) -> [AgentEvent.Kind] {
    kinds.filter {
        if case .effortReported = $0 { return true }
        return false
    }
}

private func effort(_ step: Int, _ name: String) -> EffortLevel { EffortLevel(step: step, name: name)! }

/// Adapter seam: which hooks of R4 report whose effort.
@Suite struct CodexEffortAdapterTests {
    /// The effort reports of every hook of R4, by hook number.
    private func reports(_ rollouts: R4Rollouts) throws -> [Int: [AgentEvent.Kind]] {
        let adapter = CodexAdapter(rolloutReader: rollouts.reader, mapping: bundledMapping())
        var reports: [Int: [AgentEvent.Kind]] = [:]
        for n in 1...r4Files.count {
            reports[n] = efforts(try adapter.events(from: envelope(n)).map(\.kind))
        }
        return reports
    }

    /// Each turn says its effort once, with its first hook, the prompt; the
    /// child's row with its start. Every other hook, `session.start` without a
    /// turn included, reports nothing.
    @Test func eachTurnReportsItsEffortOnceWithItsFirstHook() throws {
        let reports = try reports(R4Rollouts())
        #expect(r4Files.count == 19)
        let reporting = [
            2: [AgentEvent.Kind.effortReported(agent: .root, effort(1, "low"))],
            6: [.effortReported(agent: .root, effort(3, "high"))],
            10: [.effortReported(agent: .root, effort(3, "high"))],
            13: [.effortReported(agent: .subagent(childRow), effort(2, "medium"))],
        ]
        for n in 1...19 {
            #expect(reports[n] == (reporting[n] ?? []), "R4-\(n)")
        }
    }

    /// The report comes after the hook's own events, which make the session
    /// and the child's row known to the store.
    @Test(arguments: [2, 13])
    func theReportComesAfterTheHooksOwnEvents(n: Int) throws {
        let rollouts = try R4Rollouts()
        let adapter = CodexAdapter(rolloutReader: rollouts.reader, mapping: bundledMapping())
        for earlier in 1..<n { _ = try adapter.events(from: envelope(earlier)) }
        let kinds = try adapter.events(from: envelope(n)).map(\.kind)
        let report = try #require(kinds.firstIndex { if case .effortReported = $0 { true } else { false } })
        let own = kinds.firstIndex {
            switch $0 {
            case .promptSubmitted, .agentSpawned: true
            default: false
            }
        }
        #expect(own.map { $0 < report } == true)
    }
}

/// Adapter seam: a turn whose record isn't in its rollout yet.
@Suite struct CodexEffortLagTests {
    /// Codex had not written turn 2's record when its prompt and tool start
    /// arrived: those report nothing and leave turn 1's low alone; the next
    /// hook of the turn after the record was written reports it.
    @Test func aRecordWrittenLateIsReportedWithTheTurnsNextHook() throws {
        let rollouts = try R4Rollouts(rootLines: 1)
        let adapter = CodexAdapter(rolloutReader: rollouts.reader, mapping: bundledMapping())
        var state = CollectiveState()
        var reports: [Int: [AgentEvent.Kind]] = [:]
        func deliver(_ n: Int) throws {
            let events = try adapter.events(from: envelope(n))
            for event in events { state.apply(event) }
            reports[n] = efforts(events.map(\.kind))
        }
        for n in 1...7 { try deliver(n) }
        #expect(reports[2] == [.effortReported(agent: .root, effort(1, "low"))])
        #expect(reports[6] == [])
        #expect(reports[7] == [])
        #expect(state.sessions.values.first?.effort == effort(1, "low"))

        try rollouts.appendRootLine(2)
        try deliver(8)
        try deliver(9)
        #expect(reports[8] == [.effortReported(agent: .root, effort(3, "high"))])
        #expect(reports[9] == [])
        #expect(state.sessions.values.first?.effort == effort(3, "high"))
    }

    /// Turn 2's record came only after its stop; a late hook of the ended
    /// turn then would report an older level than what comes next, so it
    /// reports nothing.
    @Test func aLateHookOfAnEndedTurnReportsNothing() throws {
        let rollouts = try R4Rollouts(rootLines: 1)
        let adapter = CodexAdapter(rolloutReader: rollouts.reader, mapping: bundledMapping())
        for n in 1...9 { _ = try adapter.events(from: envelope(n)) }
        try rollouts.appendRootLine(2)
        // R4-008 again: turn 2's tool end, arriving late.
        #expect(efforts(try adapter.events(from: envelope(8)).map(\.kind)) == [])
    }

    /// The child's record came only after its stop closed the row; a late
    /// hook of that row is no news about the turn.
    @Test func aLateHookOfAClosedChildRowReportsNothing() throws {
        let rollouts = try R4Rollouts(childRecord: false)
        let adapter = CodexAdapter(rolloutReader: rollouts.reader, mapping: bundledMapping())
        for n in 1...17 { _ = try adapter.events(from: envelope(n)) }
        try rollouts.appendChildRecord()
        // R4-016 again: the child's tool end, arriving after R4-017 stopped it.
        #expect(efforts(try adapter.events(from: envelope(16)).map(\.kind)) == [])
    }

    /// A record first found with the turn's own Stop still reports, after the
    /// events of the stop.
    @Test func aRecordFoundOnTheStopHookReportsAfterTheTurnEnded() throws {
        let rollouts = try R4Rollouts(rootLines: 1)
        let adapter = CodexAdapter(rolloutReader: rollouts.reader, mapping: bundledMapping())
        for n in 1...8 { _ = try adapter.events(from: envelope(n)) }
        try rollouts.appendRootLine(2)
        // R4-009: turn 2's Stop.
        let kinds = try adapter.events(from: envelope(9)).map(\.kind)
        let ended = try #require(kinds.firstIndex { if case .turnEnded = $0 { true } else { false } })
        let report = try #require(kinds.firstIndex { if case .effortReported = $0 { true } else { false } })
        #expect(ended < report)
    }

    /// No rollout to read (ephemeral, `transcript_path: null`): no hook reports.
    @Test func anEphemeralSessionReportsNoEffort() throws {
        let rollouts = try R4Rollouts()
        let adapter = CodexAdapter(rolloutReader: rollouts.reader, mapping: bundledMapping())
        for n in 1...r4Files.count {
            var object = try #require(try JSONSerialization.jsonObject(with: r4Files[n - 1].payload) as? [String: Any])
            object["transcript_path"] = NSNull()
            if object["agent_transcript_path"] != nil { object["agent_transcript_path"] = NSNull() }
            let payload = try JSONSerialization.data(withJSONObject: object)
            let kinds = try adapter.events(from: Envelope(source: "codex", pid: 4242, payload: payload, receivedAt: t0.addingTimeInterval(TimeInterval(n)))).map(\.kind)
            #expect(efforts(kinds) == [], "R4-\(n)")
        }
    }
}

/// The scale chosen for Codex: the same
/// name on the same step as Claude Code. Only `low`, `medium` and `high` are
/// captured (R1–R4); the other names come from Codex's documentation and its
/// `/model` picker, their stored values unseen, so this is a table test of
/// the names alone, not of a payload.
@Suite struct CodexEffortScaleTests {
    @Test(arguments: [
        ("minimal", 1), ("low", 1), ("medium", 2), ("high", 3), ("xhigh", 4), ("max", 5), ("ultra", 5),
    ])
    func aKnownLevelGetsItsStepAndKeepsItsName(name: String, step: Int) {
        #expect(CodexAdapter.effortLevel(named: name) == effort(step, name))
    }

    /// `none` thinks not at all; an unknown value is off the scale.
    @Test(arguments: ["none", "auto", "High", ""])
    func noneAndUnknownLevelsShowNoGauge(name: String) {
        #expect(CodexAdapter.effortLevel(named: name) == nil)
    }
}

// MARK: - Store

/// Store seam: R4 replayed through adapter and reducer.
@Suite struct CodexEffortStoreTests {
    /// The state after hook `n`.
    private func replay(through n: Int) throws -> Session {
        let rollouts = try R4Rollouts()
        let adapter = CodexAdapter(rolloutReader: rollouts.reader, mapping: bundledMapping())
        var state = CollectiveState()
        for hook in 1...n {
            for event in try adapter.events(from: envelope(hook)) { state.apply(event) }
        }
        return try #require(state.sessions[SessionKey(source: "codex", sessionID: rootThread)])
    }

    @Test func theSessionStartKnowsNoEffort() throws {
        let session = try replay(through: 1)
        #expect(session.effort == nil)
    }

    /// `/model` sent no hook; the change shows with turn 2's prompt (R4-006).
    @Test func aChangeShowsFromTheNextTurn() throws {
        let before = try replay(through: 5)
        #expect(before.effort == effort(1, "low"))
        #expect(before.lastEffortChange == nil)

        let after = try replay(through: 6)
        #expect(after.effort == effort(3, "high"))
        #expect(after.lastEffortChange == EffortChange(from: effort(1, "low"), at: t0.addingTimeInterval(6)))
    }

    /// The child runs at its own medium, its parent stays at high.
    @Test func theChildKeepsItsOwnEffort() throws {
        let session = try replay(through: 19)
        #expect(session.effort == effort(3, "high"))
        #expect(session.lastEffortChange == EffortChange(from: effort(1, "low"), at: t0.addingTimeInterval(6)))
        #expect(session.agents[.subagent(childRow)]?.effort == effort(2, "medium"))
        #expect(Set(session.agents.keys) == [.root, .subagent(childRow)])
    }
}

// MARK: - Presentation

/// Presentation seam: the card's model carries the gauge of turn 2.
@Suite struct CodexEffortPopoverTests {
    @Test func theCardsModelShowsTheTurnsLevel() throws {
        let rollouts = try R4Rollouts()
        let adapter = CodexAdapter(rolloutReader: rollouts.reader, mapping: bundledMapping())
        var state = CollectiveState()
        for n in 1...7 {
            for event in try adapter.events(from: envelope(n)) { state.apply(event) }
        }
        let popover = PopoverModel(state: state, now: t0.addingTimeInterval(8), settings: PopoverSettings())
        let item = try #require((popover.sessions + popover.idle).first)
        let gauge = try #require(item.model?.effort)
        #expect(gauge.step == 3)
        #expect(gauge.name == "high")
    }
}
