import Foundation
import SubspaceKit
import Synchronization
import Testing
@testable import CollectiveKit

// The reference: whatever makes the backlog faster, `SpoolReader` must
// still yield exactly what a plain sequential replay of the same files gives, in
// the contract's order (§6), and the state built from it must not differ.

// MARK: - Deterministic adapters

private struct NoMeta: SubagentMetaReading {
    func meta(transcriptPath: String, agentID: String) -> SubagentMeta? { nil }
}

private struct NoRollouts: RolloutMetaReading {
    func meta(rolloutPath: String) -> RolloutMeta? { nil }
    func approvalsReviewer(rolloutPath: String, turnID: String) -> String? { nil }
    func effort(rolloutPath: String, turnID: String) -> String? { nil }
}

private final class NoDisk: MappingFileSystem {
    func modificationDate(of url: URL) -> Date? { nil }
    func contents(of url: URL) throws -> Data { throw CocoaError(.fileNoSuchFile) }
}

/// A root without `model/`, so the bundled documents are used.
private func bundledMapping() -> MappingLoader {
    MappingLoader(root: URL(filePath: "/spool/root", directoryHint: .isDirectory), fileSystem: NoDisk())
}

/// Fresh adapters keep per-session memory, so the reader and the reference need one set each.
private func adapters() -> [any PushAdapter] {
    [ClaudeCodeAdapter(metaReader: NoMeta(), mapping: bundledMapping()),
     CodexAdapter(rolloutReader: NoRollouts(), mapping: bundledMapping())]
}

/// `adapters()` for other files; that name is taken there by private helpers.
func backlogAdapters() -> [any PushAdapter] { adapters() }

// MARK: - Fixtures as spool roots

/// A captured run: payload files in arrival order, and the source that sent them.
struct CapturedRun: CustomTestStringConvertible {
    let name: String
    let source: String
    let payloads: [Data]
    var testDescription: String { name }
    /// Whether the adapters show anything of it: the internal agent in
    /// `spool-2026-10-03-internal-agent-tool` is all there is, and it never
    /// identifies itself.
    var yieldsEvents: Bool { name != "claude-code/spool-2026-10-03-internal-agent-tool" }

    /// Every `events/` folder below `Fixtures/claude-code` and `Fixtures/codex`
    /// (version captures and spool captures alike); their files hold bare payloads.
    static let all: [CapturedRun] = {
        let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures", isDirectory: true)
        var runs: [CapturedRun] = []
        for source in ["claude-code", "codex"] {
            let base = fixtures.appendingPathComponent(source, isDirectory: true)
            let paths = (FileManager.default.subpaths(atPath: base.path) ?? []).sorted()
            for path in paths where path.hasSuffix("/events") {
                let events = base.appendingPathComponent(path, isDirectory: true)
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: events.path)) ?? [])
                    .filter { $0.hasSuffix(".json") }.sorted()
                guard !names.isEmpty else { continue }
                runs.append(CapturedRun(
                    name: "\(source)/\(path.dropLast("/events".count))", source: source,
                    payloads: names.map { try! Data(contentsOf: events.appendingPathComponent($0)) }))
            }
        }
        return runs
    }()
}

/// Spools `runs` one after the other the way subspace lays them out: one file per
/// event in `events/<day>/`, a few days, and each mtime shared by three files so the
/// name tie-break matters. Returns the file names in the intended read order.
@discardableResult
func spool(_ runs: [CapturedRun], into root: URL) throws -> [String] {
    var names: [String] = []
    var index = 0
    for run in runs {
        for payload in run.payloads {
            let day = "2026-10-\(String(format: "%02d", 1 + index / 40))"
            let name = "\(String(format: "%06d", index))-4242-\(index)"
            let folder = root.appendingPathComponent("events/\(day)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let object: [String: Any] = [
                "v": 1, "source": run.source, "ts": 1_790_000_000 + index, "pid": 4242,
                "payload": try JSONSerialization.jsonObject(with: payload),
            ]
            let file = folder.appendingPathComponent("\(name).json")
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_790_000_000 + Double(index / 3))],
                ofItemAtPath: file.path)
            names.append("\(name).json")
            index += 1
        }
    }
    return names
}

// MARK: - Reader and reference

/// A watcher that never reports anything.
private struct SilentWatcher: DirectoryWatching {
    func changes(under directory: URL) -> AsyncStream<Set<URL>?> { AsyncStream { _ in } }
}

/// What the reader yields until `backlogFinished`, flattened.
private func readerBacklog(of root: URL) async -> [AgentEvent] {
    let reader = SpoolReader(adapters: adapters(), environment: ["SUBSPACE_DIR": root.path],
                             watcher: SilentWatcher(), pollInterval: .milliseconds(20))
    var events: [AgentEvent] = []
    for await output in await reader.events() {
        switch output {
        case .events(let batch), .replay(let batch, _): events += batch
        case .backlogFinished:
            await reader.stop()
            return events
        }
    }
    return events
}

/// The plain replay: the files in the contract's order, one at a time through
/// one fresh adapter set, whatever throws skipped.
func referenceReplay(of root: URL) throws -> (files: [String], events: [AgentEvent]) {
    var scanner = SpoolScanner(root: root)
    let files = scanner.scanAll()
    let byID = Dictionary(uniqueKeysWithValues: adapters().map { ($0.source, $0) })
    var events: [AgentEvent] = []
    for file in files {
        guard let envelope = try? SpoolFile.envelope(from: Data(contentsOf: file)),
              let adapter = byID[envelope.source],
              let batch = try? adapter.events(from: envelope) else { continue }
        events += batch
    }
    return (files.map(\.lastPathComponent), events)
}

func state(after events: [AgentEvent]) -> CollectiveState {
    var state = CollectiveState()
    for event in events { state.apply(event) }
    return state
}

func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CollectiveKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Tests

@Suite(.heavy) struct BacklogEquivalenceTests {
    private func expectEquivalent(_ runs: [CapturedRun]) async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let written = try spool(runs, into: root)

        let reference = try referenceReplay(of: root)
        #expect(reference.files == written, "the reference must list the files in the intended order")
        #expect(reference.events.isEmpty == !runs.contains(where: \.yieldsEvents))

        let backlog = await readerBacklog(of: root)
        #expect(backlog.count == reference.events.count)
        #expect(backlog == reference.events)
        #expect(state(after: backlog) == state(after: reference.events))
    }

    @Test func thereAreCapturedRunsOfBothSources() {
        #expect(Set(CapturedRun.all.map(\.source)) == ["claude-code", "codex"])
    }

    @Test(arguments: CapturedRun.all)
    func theBacklogOfOneRunEqualsTheSequentialReplay(run: CapturedRun) async throws {
        try await expectEquivalent([run])
    }

    /// Every capture in one root: many sessions of both sources across days.
    @Test func theBacklogOfAllRunsTogetherEqualsTheSequentialReplay() async throws {
        try await expectEquivalent(CapturedRun.all)
    }

    /// Files the reader must skip without disturbing the rest: a foreign source,
    /// an unknown version and garbage between good files.
    @Test func skippedFilesChangeNothing() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runs = Array(CapturedRun.all.prefix(3))
        try spool(runs, into: root)
        let folder = root.appendingPathComponent("events/2026-10-01", isDirectory: true)
        let bad: [(String, String)] = [
            ("000001-4242-x", #"{"v":1,"source":"other-tool","ts":1790000000,"payload":{"a":1}}"#),
            ("000002-4242-x", #"{"v":2,"source":"claude-code","ts":1790000000,"payload":{}}"#),
            ("000003-4242-x", "not json"),
        ]
        for (name, text) in bad {
            let file = folder.appendingPathComponent("\(name).json")
            try Data(text.utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_790_000_000)], ofItemAtPath: file.path)
        }

        let reference = try referenceReplay(of: root)
        let backlog = await readerBacklog(of: root)
        #expect(!backlog.isEmpty)
        #expect(backlog == reference.events)
        #expect(state(after: backlog) == state(after: reference.events))
    }
}

// MARK: - Store

/// What a reader that keeps its events in `store` yields until `backlogFinished`,
/// flattened; it has stopped then, so the next one has the store to itself.
private func readerBacklog(of root: URL, store: URL) async -> [AgentEvent] {
    let reader = SpoolReader(adapters: adapters(), environment: ["SUBSPACE_DIR": root.path],
                             watcher: SilentWatcher(), pollInterval: .milliseconds(20), store: SpoolReader.Store(path: store, maxAge: nil))
    var events: [AgentEvent] = []
    for await output in await reader.events() {
        switch output {
        case .events(let batch), .replay(let batch, _): events += batch
        case .backlogFinished:
            await reader.stop()
            return events
        }
    }
    return events
}

/// Two starts on one store and the plain replay of the same spool.
private struct StoredStarts: Sendable {
    let reference: [AgentEvent]
    let first: [AgentEvent]
    /// What the store held after the first start.
    let rows: [StoredEvent]
    let second: [AgentEvent]

    /// Spools `runs` into a fresh root and starts a reader on it twice, on one fresh store.
    init(_ runs: [CapturedRun]) async throws {
        let root = try temporaryRoot()
        let storeFolder = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: storeFolder)
        }
        try spool(runs, into: root)
        reference = try referenceReplay(of: root).events
        let store = storeFolder.appendingPathComponent("events.sqlite")
        first = await readerBacklog(of: root, store: store)
        rows = try await EventStore(path: store, maxAge: nil).replay()
        second = await readerBacklog(of: root, store: store)
    }

    /// Every capture in one root. Made once for the tests that read it:
    /// spooling and storing all of them is most of what each would do.
    static let ofAllRuns = Task { try await StoredStarts(CapturedRun.all) }
}

/// Seam `SpoolReader.events()` with a real `EventStore`: a first start stores the
/// spool, a second one replays the store, and both give the reference's events.
@Suite(.heavy) struct StoredBacklogEquivalenceTests {
    private func expectEquivalent(_ starts: StoredStarts, yieldsEvents: Bool = true) {
        #expect(starts.reference.isEmpty == !yieldsEvents)

        #expect(starts.first.count == starts.reference.count)
        #expect(starts.first == starts.reference)
        #expect(state(after: starts.first) == state(after: starts.reference))
        #expect(!starts.rows.isEmpty, "the first start must store the spool")

        #expect(starts.second.count == starts.reference.count)
        #expect(starts.second == starts.reference)
        #expect(state(after: starts.second) == state(after: starts.reference))
    }

    @Test(arguments: CapturedRun.all)
    func theStoredBacklogOfOneRunEqualsTheSequentialReplay(run: CapturedRun) async throws {
        expectEquivalent(try await StoredStarts([run]), yieldsEvents: run.yieldsEvents)
    }

    /// Every capture in one root: many sessions of both sources across days.
    @Test func theStoredBacklogOfAllRunsTogetherEqualsTheSequentialReplay() async throws {
        expectEquivalent(try await StoredStarts.ofAllRuns.value)
    }

    /// Seam `PushAdapter.excludedFields`, read back through the store: a tool's
    /// output is the bulk of the payloads and no adapter reads it, so no row keeps it.
    @Test func noStoredRowKeepsAToolResponse() async throws {
        // The captures do hold tool responses, of both sources.
        for source in ["claude-code", "codex"] {
            let payloads = CapturedRun.all.filter { $0.source == source }.flatMap(\.payloads)
            #expect(try payloads.contains { payload in
                let object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
                return object["hook_event_name"] as? String == "PostToolUse" && object["tool_response"] != nil
            }, "no PostToolUse with a tool_response among the \(source) captures")
        }
        let starts = try await StoredStarts.ofAllRuns.value
        #expect(!starts.first.isEmpty)

        var posts = 0
        for row in starts.rows {
            guard case let .mapped(result) = row.content else {
                Issue.record("\(row.name) is not mapped")
                continue
            }
            if result.block["kind"] == .string("tool.post") { posts += 1 }
            #expect(result.core["tool_response"] == nil, "\(row.name)")
            #expect(result.block["tool_response"] == nil, "\(row.name)")
        }
        #expect(posts > 0)
    }
}

// MARK: - Mapped entry point

@Suite(.heavy) struct MappedEventsTests {
    /// `events(from:mapped:)` with the mapping applied up front gives what
    /// `events(from:)` gives, payload by payload, errors included.
    @Test(arguments: CapturedRun.all)
    func eventsFromAMappedPayloadEqualEventsFromTheEnvelope(run: CapturedRun) throws {
        let plain = try #require(adapters().first { $0.source.rawValue == run.source })
        let mapped = try #require(adapters().first { $0.source.rawValue == run.source })
        let document = try #require(mapped.mappingDocument())
        var compared = 0
        for (index, payload) in run.payloads.enumerated() {
            let envelope = Envelope(source: plain.source, pid: 4242, payload: payload,
                                    receivedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)))
            let expected = Result { try plain.events(from: envelope) }
            let result = MappingInterpreter.apply(document, to: try JSONValue(data: payload))
            let actual = Result { try mapped.events(from: envelope, mapped: result) }
            #expect(String(describing: actual) == String(describing: expected), "payload \(index)")
            compared += 1
        }
        #expect(compared == run.payloads.count)
    }
}

// MARK: - Mapping fetched once per pass

/// Counts the stats of each mapping file; reports none, so the bundled documents win.
private final class CountingFileSystem: MappingFileSystem, Sendable {
    private let counts = Mutex<[String: Int]>([:])

    func modificationDate(of url: URL) -> Date? {
        counts.withLock { $0[url.lastPathComponent, default: 0] += 1 }
        return nil
    }

    func contents(of url: URL) throws -> Data { throw CocoaError(.fileNoSuchFile) }

    func count(_ name: String) -> Int { counts.withLock { $0[name, default: 0] } }
}

@Suite(.heavy) struct MappingPerPassTests {
    @Test func theBacklogFetchesEachMappingDocumentOncePerPass() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let written = try spool(CapturedRun.all, into: root)
        #expect(written.count > 100)

        let fileSystem = CountingFileSystem()
        let mapping = { MappingLoader(root: URL(filePath: "/spool/root", directoryHint: .isDirectory), fileSystem: fileSystem) }
        let reader = SpoolReader(
            adapters: [ClaudeCodeAdapter(metaReader: NoMeta(), mapping: mapping()),
                       CodexAdapter(rolloutReader: NoRollouts(), mapping: mapping())],
            environment: ["SUBSPACE_DIR": root.path], watcher: SilentWatcher())
        var events: [AgentEvent] = []
        for await output in await reader.events() {
            if case .events(let batch) = output { events += batch } else { await reader.stop() }
        }
        #expect(!events.isEmpty)
        #expect(fileSystem.count("claude-code.json") <= 1)
        #expect(fileSystem.count("codex.json") <= 1)
    }

    /// With a store the pass is the root's ingest.
    @Test func theStoredBacklogFetchesEachMappingDocumentOncePerPass() async throws {
        let root = try temporaryRoot()
        let storeFolder = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: storeFolder)
        }
        let written = try spool(CapturedRun.all, into: root)
        #expect(written.count > 100)

        let fileSystem = CountingFileSystem()
        let mapping = { MappingLoader(root: URL(filePath: "/spool/root", directoryHint: .isDirectory), fileSystem: fileSystem) }
        let reader = SpoolReader(
            adapters: [ClaudeCodeAdapter(metaReader: NoMeta(), mapping: mapping()),
                       CodexAdapter(rolloutReader: NoRollouts(), mapping: mapping())],
            environment: ["SUBSPACE_DIR": root.path], watcher: SilentWatcher(),
            store: SpoolReader.Store(path: storeFolder.appendingPathComponent("events.sqlite"), maxAge: nil))
        var events: [AgentEvent] = []
        for await output in await reader.events() {
            switch output {
            case .events(let batch), .replay(let batch, _): events += batch
            case .backlogFinished: await reader.stop()
            }
        }
        #expect(!events.isEmpty)
        #expect(fileSystem.count("claude-code.json") <= 1)
        #expect(fileSystem.count("codex.json") <= 1)
    }
}
