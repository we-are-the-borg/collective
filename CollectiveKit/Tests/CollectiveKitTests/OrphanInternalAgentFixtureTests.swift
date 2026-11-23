import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// MARK: - Fixture

/// The live spool of an orphaned internal agent: payloads with the envelope second each arrived in.
struct OrphanSpool {
    struct Event {
        let file: String
        let payload: Data
        let at: Date
    }

    static let directory = Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures/claude-code/spool-2026-10-05-orphan-internal-agent")
    static let pid: Int32 = 70960
    static let session = SessionKey(source: "claude-code", sessionID: "ac6ac571-b59d-48b9-ae1b-55601ac47b4b")

    /// All events in arrival order (`NNN-<hook>.json`).
    let events: [Event]

    init() throws {
        // The payload files carry no envelope; the README table gives each one's spool file `<ts>-<pid>-<id>.json`.
        let readme = try String(contentsOf: Self.directory.appendingPathComponent("README.md"), encoding: .utf8)
        var seconds: [String: TimeInterval] = [:]
        for line in readme.split(separator: "\n") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`")) }
            guard cells.count == 2, cells[0].hasPrefix("events/"),
                  let ts = cells[1].split(separator: "-").first.flatMap({ TimeInterval($0) }) else { continue }
            seconds[cells[0]] = ts
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: Self.directory.appendingPathComponent("events").path).sorted()
        events = try files.map { name in
            let file = "events/\(name)"
            let ts = try #require(seconds[file], "no README row for \(file)")
            let payload = try Data(contentsOf: Self.directory.appendingPathComponent(file))
            return Event(file: file, payload: payload, at: Date(timeIntervalSince1970: ts))
        }
    }

    /// Events whose number `NNN` is at most `last`.
    func events(through last: Int) -> [Event] {
        events.filter { Int($0.file.dropFirst("events/".count).prefix(3))! <= last }
    }

    /// Applies `events` to `state` through a fresh adapter.
    static func replay(_ events: [Event], onto state: inout CollectiveState) throws {
        let adapter = ClaudeCodeAdapter(metaReader: StubMetaReader(), mapping: bundledMapping())
        for event in events {
            let envelope = Envelope(source: "claude-code", pid: pid, payload: event.payload, receivedAt: event.at)
            for agentEvent in try adapter.events(from: envelope) { state.apply(agentEvent) }
        }
    }
}

/// No meta files: the orphan has none, and the test needs none of the others'.
private struct StubMetaReader: SubagentMetaReading {
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

// MARK: - Tests

@Suite(.heavy) struct OrphanInternalAgentFixtureTests {
    private let orphan = AgentRef.subagent("a068855c370ce0be8")

    /// The app starts while the session sits idle and the status file is read
    /// before the backlog. `036-PreToolUse`/`037-PostToolBatch` are all the
    /// orphan ever sends; it never identifies itself, so it never shows.
    @Test func appStartWhileIdleNeverShowsTheOrphan() throws {
        var state = CollectiveState()
        state.apply(AgentEvent(session: OrphanSpool.session, timestamp: Date(timeIntervalSince1970: 1_791_191_065),
                               kind: .activityReported(.idle)))
        try OrphanSpool.replay(OrphanSpool().events(through: 37), onto: &state)

        let session = try #require(state.sessions[OrphanSpool.session])
        #expect(session.agents[orphan] == nil)
        #expect(session.agents.values.allSatisfy { $0.id == .root || !$0.status.isActive })
    }

    /// The whole capture: the orphan never shows; the real subagents end with
    /// their own stops.
    @Test func theOrphanNeverShowsAndTheSubagentsEndWithTheirStops() throws {
        let spool = try OrphanSpool()
        var state = CollectiveState()
        try OrphanSpool.replay(spool.events, onto: &state)

        let session = try #require(state.sessions[OrphanSpool.session])
        #expect(state.activeAgentCount == 0)
        #expect(session.agents[orphan] == nil)

        var firstStops: [AgentRef: Date] = [:]
        var started: Set<AgentRef> = []
        for event in spool.events {
            let hook = try #require(JSONSerialization.jsonObject(with: event.payload) as? [String: Any])
            guard let id = hook["agent_id"] as? String else { continue }
            switch hook["hook_event_name"] as? String {
            case "SubagentStop": if firstStops[.subagent(id)] == nil { firstStops[.subagent(id)] = event.at }
            case "SubagentStart": started.insert(.subagent(id))
            default: break
            }
        }
        #expect(started.count == 6)
        for (ref, stoppedAt) in firstStops {
            guard let agent = session.agents[ref] else { continue }
            #expect(agent.endedAt == stoppedAt, "\(ref)")
        }
        // Agents that never identify themselves stay invisible.
        #expect(Set(session.agents.keys) == started.union([.root]))
    }

    /// Each background subagent shows its model once its `Agent` call has
    /// returned, long before it stops. Two calls set no `model` and inherit.
    @Test func backgroundSubagentsCarryTheirModelFromTheLaunch() throws {
        let spool = try OrphanSpool()
        let launches: [(post: Int, agent: String, alias: String?, id: String)] = [
            (3, "a80d1cef23c24d600", "opus", "claude-opus-5-5"),
            (88, "ab88253cd3480cf7e", "sonnet", "claude-sonnet-5-5"),
            (126, "a0d14a7fef7966135", nil, "claude-opus-5-5"),
            (167, "a5e7b06ea373d4a2a", "sonnet", "claude-sonnet-5-5"),
            (190, "a4a30a463628f63c2", nil, "claude-opus-5-5"),
            (244, "a057bec6d7d6745bc", "sonnet", "claude-sonnet-5-5"),
        ]
        for launch in launches {
            var state = CollectiveState()
            try OrphanSpool.replay(spool.events(through: launch.post), onto: &state)
            let agent = try #require(state.sessions[OrphanSpool.session]?.agents[.subagent(launch.agent)])
            #expect(agent.status == .working, "\(launch.agent)")
            #expect(agent.spec.modelAlias == launch.alias, "\(launch.agent)")
            #expect(agent.spec.modelID == launch.id, "\(launch.agent)")
        }
    }
}
