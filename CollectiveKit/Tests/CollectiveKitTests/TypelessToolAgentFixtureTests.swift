import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// MARK: - Fixture

/// The live spool of a typeless tool agent: payloads with the envelope second each arrived in.
private struct TypelessSpool {
    struct Event {
        let file: String
        let payload: Data
        let at: Date
    }

    static let directory = Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures/claude-code/spool-2026-10-21-typeless-tool-agent")
    static let pid: Int32 = 47156
    static let session = SessionKey(source: "claude-code", sessionID: "800dce8e-418e-472b-8f66-8b9d20541cdf")

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

    /// Applies `events` to `state` through a fresh adapter, calling `check` after each one.
    static func replay(_ events: [Event], onto state: inout CollectiveState, check: (Event, CollectiveState) -> Void = { _, _ in }) throws {
        let adapter = ClaudeCodeAdapter(metaReader: FixtureMetaReader(), mapping: bundledMapping())
        for event in events {
            let envelope = Envelope(source: "claude-code", pid: pid, payload: event.payload, receivedAt: event.at)
            for agentEvent in try adapter.events(from: envelope) { state.apply(agentEvent) }
            check(event, state)
        }
    }
}

/// The fixture's `subagents/` meta files, as the app would find them next to the transcript.
private struct FixtureMetaReader: SubagentMetaReading {
    func meta(transcriptPath: String, agentID: String) -> SubagentMeta? {
        FileSubagentMetaReader().meta(transcriptPath: TypelessSpool.directory.path + ".jsonl", agentID: agentID)
    }
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

@Suite(.heavy) struct TypelessToolAgentFixtureTests {
    private let first = AgentRef.subagent("a04fa4778180bb7b5")
    private let second = AgentRef.subagent("a4e7313b0f002387e")
    private let third = AgentRef.subagent("adf12bbce1aab5633")

    /// At no point does the popover show or count a typeless agent, nor any
    /// agent as unassigned: the real subagents are named by their meta files.
    @Test func theTypelessAgentsNeverShow() throws {
        var state = CollectiveState()
        try TypelessSpool.replay(try TypelessSpool().events, onto: &state) { event, state in
            let agents = state.sessions[TypelessSpool.session].map { Array($0.agents.values) } ?? []
            #expect(Set(agents.map(\.id)).isSubset(of: [.root, first, second, third]), "\(event.file)")
            // A working subagent without a title shows as unassigned.
            #expect(agents.allSatisfy { $0.id == .root || $0.status != .working || $0.spec.title != nil }, "\(event.file)")

            let model = PopoverModel(state: state, now: event.at, settings: PopoverSettings())
            let items = model.sessions + model.finished
            #expect(items.allSatisfy { $0.summary.subagentCount == agents.count - 1 }, "\(event.file)")
            let working = agents.count { $0.id != .root && $0.status == .working }
            #expect(items.allSatisfy { $0.summary.workingCount == working }, "\(event.file)")
        }
    }

    /// Up to the second implementer's stop (`226`): both implementers, done, and nothing else.
    @Test func twoImplementersEndAndNoTypelessAgentRemains() throws {
        var state = CollectiveState()
        try TypelessSpool.replay(try TypelessSpool().events(through: 226), onto: &state)

        let session = try #require(state.sessions[TypelessSpool.session])
        let subagents = session.children(of: .root)
        #expect(Set(subagents.map(\.id)) == [first, second])
        #expect(subagents.allSatisfy { $0.spec.type == "implementer" && $0.status == .done })
        #expect(session.agents.count == 3)
    }

    /// The whole capture: the third implementer, started at `228`, still works.
    @Test func theThirdImplementerStillWorksAtTheFinalStop() throws {
        var state = CollectiveState()
        try TypelessSpool.replay(try TypelessSpool().events, onto: &state)

        let session = try #require(state.sessions[TypelessSpool.session])
        #expect(Set(session.agents.keys) == [.root, first, second, third])
        #expect(session.agents[first]?.status == .done)
        #expect(session.agents[second]?.status == .done)
        #expect(session.agents[third]?.status == .working)
        #expect(session.agents[third]?.spec.title == "Step C: card name and docs")
    }
}
