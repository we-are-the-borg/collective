import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// The reference for a warm start: one that replays the rows of an
// `EventStore` instead of reading the spool must give the adapters what the
// spool gives them, so the events and the state built from them don't differ
// from a plain sequential replay of the same files (`referenceReplay`).

/// The fields the app will drop before storing: no adapter reads them, and
/// they are the bulk of the payloads. Antigravity's payloads carry no tool
/// output, but a call's whole arguments.
private let exclusions: [SourceID: Set<String>] = [
    "claude-code": ["tool_response"], "codex": ["tool_response"], "antigravity": ["tool_input"],
]

/// Stored rows through one fresh adapter set in the store's order, the way the
/// reader feeds spool files: rows without an adapter and whatever throws skipped.
private func events(replaying rows: [StoredEvent]) -> [AgentEvent] {
    let byID = Dictionary(uniqueKeysWithValues: backlogAdapters().map { ($0.source, $0) })
    var events: [AgentEvent] = []
    for row in rows {
        guard let adapter = byID[row.source] else { continue }
        let batch: [AgentEvent]?
        switch row.content {
        case let .mapped(result): batch = try? adapter.events(from: row.envelope, mapped: result)
        case .whole: batch = try? adapter.events(from: row.envelope)
        case .foreign: batch = nil
        }
        events += batch ?? []
    }
    return events
}

@Suite(.heavy) struct StoreEquivalenceTests {
    private func expectEquivalent(_ runs: [CapturedRun]) async throws {
        let root = try temporaryRoot()
        let storeFolder = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: storeFolder)
        }
        let written = try spool(runs, into: root)
        let reference = try referenceReplay(of: root)
        #expect(reference.events.isEmpty == !runs.contains(where: \.yieldsEvents))

        let path = storeFolder.appendingPathComponent("events.sqlite")
        let documents = Dictionary(uniqueKeysWithValues: backlogAdapters().map { ($0.source, $0.mappingDocument()) })
        #expect(documents.values.allSatisfy { $0 != nil }, "every source maps with its bundled document")
        let result = try await EventStore(path: path, maxAge: nil).ingest(
            root: root, changed: nil, documents: documents, excluding: exclusions)
        // A fresh store: everything is new, nothing re-mapped.
        #expect(result.remapped.isEmpty)
        let ingested = result.new
        #expect(ingested.count == written.count)
        #expect(ingested.allSatisfy { if case .mapped = $0.content { true } else { false } })

        // A new instance, as after a restart.
        let replayed = try await EventStore(path: path, maxAge: nil).replay()
        #expect(replayed == ingested)
        #expect(replayed.map(\.name) == written)

        let produced = events(replaying: replayed)
        #expect(produced.count == reference.events.count)
        #expect(produced == reference.events)
        #expect(state(after: produced) == state(after: reference.events))
    }

    @Test(arguments: CapturedRun.all)
    func theReplayOfOneStoredRunEqualsTheSequentialReplay(run: CapturedRun) async throws {
        try await expectEquivalent([run])
    }

    /// Every capture in one store: many sessions of every source across days.
    @Test func theReplayOfAllStoredRunsTogetherEqualsTheSequentialReplay() async throws {
        try await expectEquivalent(CapturedRun.all)
    }
}
