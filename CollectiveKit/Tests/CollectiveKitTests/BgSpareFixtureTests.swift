import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// MARK: - Fixture

/// A live spool: an unclaimed `claude bg-spare` process's hooks.
private enum SpareSpool {
    static let directory = Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures/claude-code/spool-2026-11-01-bg-spare/events")
    static let session = SessionKey(source: "claude-code", sessionID: SpareStatusTests.session)
    /// All three files share the envelope second (see the README).
    static let at = Date(timeIntervalSince1970: 1_793_535_434)

    /// Applies the payloads in arrival order (`NNN-<hook>.json`) through a fresh adapter.
    static func replay(onto state: inout CollectiveState) throws {
        let adapter = ClaudeCodeAdapter(metaReader: NoMeta(), mapping: bundledMapping())
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(files.count == 3)
        for file in files {
            let payload = try Data(contentsOf: directory.appendingPathComponent(file))
            let envelope = Envelope(source: "claude-code", pid: SpareStatusTests.pid, payload: payload, receivedAt: at)
            for event in try adapter.events(from: envelope) { state.apply(event) }
        }
    }

    /// What the status source reports for the spare's file (derived, see `SpareStatusTests`).
    static func standbyReport() throws -> AgentEvent {
        let mapping = try #require(MappingLoader.bundledDocument(named: "claude-code-session"))
        let events = ClaudeCodeSessionStatusSource.events(
            from: try SpareStatusTests.file(), mapping: mapping, processStart: { _ in Date(timeIntervalSince1970: 0) }
        )
        return try #require(events.activity)
    }
}

/// The spare has no transcript, so no subagent meta either.
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

// MARK: - Tests

@Suite struct BgSpareFixtureTests {
    private func model(_ state: CollectiveState) -> PopoverModel {
        PopoverModel(state: state, now: SpareSpool.at.addingTimeInterval(60), settings: PopoverSettings())
    }

    /// Without its status file the spare's hooks alone make a session waiting
    /// for the user, the card a spare showed before standby was known.
    @Test func theHooksAloneShowTheSpare() throws {
        var state = CollectiveState()
        try SpareSpool.replay(onto: &state)

        #expect(state.sessions[SpareSpool.session]?.root.status == .waiting)
        #expect(model(state).sessions.map(\.key) == [SpareSpool.session])
    }

    /// Its own process reports standby: no row, nothing counted or asked,
    /// whether the status file is read before the spool or after it.
    @Test(arguments: [false, true])
    func aSpareShowsNothing(reportFirst: Bool) throws {
        var state = CollectiveState()
        if reportFirst { state.apply(try SpareSpool.standbyReport()) }
        try SpareSpool.replay(onto: &state)
        if !reportFirst { state.apply(try SpareSpool.standbyReport()) }

        let model = model(state)
        #expect(model.sessions.isEmpty)
        #expect(model.finished.isEmpty)
        #expect(state.activeAgentCount == 0)
        #expect(!state.awaitsPermission)
    }
}
