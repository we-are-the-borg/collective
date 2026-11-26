import Foundation
import SubspaceKit
import Synchronization
import Testing
@testable import CollectiveKit
// For `EventStore`'s initializer with `readFile`, which counts the files a store opens.
@testable import SubspaceKit

// MARK: - Helpers

/// A fresh, empty directory; removed when the test's `defer` runs.
private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CollectiveKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func envelopeJSON(source: String = "claude-code", v: Any = 1, ts: Int = 1_790_000_000,
                          pid: Any = 4242, payload: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: ["v": v, "source": source, "ts": ts, "pid": pid, "payload": payload])
}

private func payload(_ hook: String, session: String = "s1") -> [String: Any] {
    ["hook_event_name": hook, "session_id": session]
}

/// Writes an event file the way subspace does: a dot-file renamed into place (contract §4).
@discardableResult
private func writeEvent(_ data: Data, in root: URL, day: String = "2026-10-01", name: String,
                        mtime: Date? = nil) throws -> URL {
    let folder = root.appendingPathComponent("events/\(day)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let temporary = folder.appendingPathComponent(".\(name).tmp")
    let file = folder.appendingPathComponent("\(name).json")
    try data.write(to: temporary)
    if let mtime { try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: temporary.path) }
    try FileManager.default.moveItem(at: temporary, to: file)
    return file
}

/// Writes an event into a root that doesn't exist yet, so the root appears with the
/// event already in it. Otherwise a polling reader could find the root still empty and,
/// with a `ManualWatcher` that never reports the write, miss the event.
private func writeEvent(_ data: Data, creatingRoot root: URL, name: String) throws {
    let staging = root.deletingLastPathComponent()
        .appendingPathComponent(".\(root.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
    try writeEvent(data, in: staging, name: name)
    // A sibling on the same volume, so the move is an atomic rename.
    try FileManager.default.moveItem(at: staging, to: root)
}

/// A watcher the test drives by hand.
private final class ManualWatcher: DirectoryWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<Set<URL>?>.Continuation] = []
    private var watched: [URL] = []

    var directories: [URL] { lock.withLock { watched } }

    func changes(under directory: URL) -> AsyncStream<Set<URL>?> {
        let (stream, continuation) = AsyncStream.makeStream(of: Set<URL>?.self)
        lock.withLock {
            watched.append(directory)
            continuations.append(continuation)
        }
        return stream
    }

    func send(_ changed: Set<URL>? = nil) {
        lock.withLock { continuations }.forEach { $0.yield(changed) }
    }
}

/// Collects a stream's batches in the background.
private actor Recorder {
    private(set) var batches: [[AgentEvent]] = []
    /// For each replay, the newest time per source of the events whose file a root still holds.
    private(set) var fresh: [LastEventTimes] = []
    /// For each `backlogFinished`, how many batches had arrived before it.
    private(set) var backlogFinished: [Int] = []
    private var task: Task<Void, Never>?

    /// All events in arrival order, regardless of how they were batched.
    var events: [AgentEvent] { batches.flatMap { $0 } }

    init(_ stream: AsyncStream<SpoolReader.Output>) {
        Task { await self.start(stream) }
    }

    private func start(_ stream: AsyncStream<SpoolReader.Output>) {
        task = Task { for await output in stream { self.record(output) } }
    }

    private func record(_ output: SpoolReader.Output) {
        switch output {
        case .events(let batch): batches.append(batch)
        case .replay(let batch, let fresh):
            batches.append(batch)
            self.fresh.append(fresh)
        case .backlogFinished: backlogFinished.append(batches.count)
        }
    }

    func stop() { task?.cancel() }

    /// Waits until at least `count` events arrived, at most `timeout`: long
    /// enough that only a reader that never yields them runs into it, however
    /// busy the machine is. The wait ends as soon as they are there.
    func waitFor(_ count: Int, timeout: Duration = .seconds(30)) async -> [AgentEvent] {
        let deadline = ContinuousClock.now + timeout
        while events.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(events.count >= count, "timed out waiting for \(count) events, got \(events.count)")
        return events
    }
}

/// Polls until `condition` holds, at most `timeout`, which is as generous as
/// in `Recorder.waitFor` for the same reason.
private func eventually(timeout: Duration = .seconds(30), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while await !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// An adapter for a second source with a fixed root.
private final class StubAdapter: PushAdapter {
    let source: SourceID
    let displayName = "Stub"
    let root: URL
    init(source: SourceID, root: URL) { self.source = source; self.root = root }
    func events(from envelope: Envelope) throws -> [AgentEvent] {
        [AgentEvent(session: SessionKey(source: source, sessionID: "x"), timestamp: envelope.receivedAt, kind: .turnStarted)]
    }
    func spoolRoot(environment: [String: String], home: URL) -> URL { root }
}

/// An adapter whose source spools into several roots, the first its primary.
private final class MultiRootAdapter: PushAdapter {
    let source: SourceID
    let displayName = "Multi"
    let roots: [URL]
    init(source: SourceID = "multi", roots: [URL]) { self.source = source; self.roots = roots }
    /// One event per envelope, told apart by its `ts`.
    func events(from envelope: Envelope) throws -> [AgentEvent] {
        [AgentEvent(session: SessionKey(source: source, sessionID: "x"), timestamp: envelope.receivedAt, kind: .turnStarted)]
    }
    func spoolRoot(environment: [String: String], home: URL) -> URL { roots[0] }
    func spoolRoots(environment: [String: String], home: URL) -> [URL] { roots }
}

private let home = URL(fileURLWithPath: "/Users/user", isDirectory: true)

/// The adapter reads its mapping from the same root the reader reads its events from, as in production,
/// and never from the real environment or home directory.
private func claudeCode(environment: [String: String]) -> ClaudeCodeAdapter {
    ClaudeCodeAdapter(mapping: ClaudeCodeAdapter.defaultMapping(environment: environment, home: home))
}

// MARK: - Roots

@Suite struct SpoolRootTests {
    @Test func claudeCodeDefaultsToItsPluginDataFolder() {
        let root = claudeCode(environment: [:]).spoolRoot(environment: [:], home: home)
        #expect(root.path == "/Users/user/.claude/plugins/data/subspace-subspace")
    }

    @Test func claudeConfigDirMovesTheClaudeCodeRoot() {
        let root = claudeCode(environment: ["CLAUDE_CONFIG_DIR": "/cfg"]).spoolRoot(environment: ["CLAUDE_CONFIG_DIR": "/cfg"], home: home)
        #expect(root.path == "/cfg/plugins/data/subspace-subspace")
        let empty = claudeCode(environment: ["CLAUDE_CONFIG_DIR": ""]).spoolRoot(environment: ["CLAUDE_CONFIG_DIR": ""], home: home)
        #expect(empty.path == "/Users/user/.claude/plugins/data/subspace-subspace")
    }

    @Test func everySourceGetsItsOwnRootWithoutDuplicates() {
        let other = URL(fileURLWithPath: "/other/root", isDirectory: true)
        let adapters: [any PushAdapter] = [
            claudeCode(environment: [:]),
            StubAdapter(source: "a", root: other),
            StubAdapter(source: "b", root: URL(fileURLWithPath: "/other/./root/", isDirectory: true)),
        ]
        let roots = SpoolReader.roots(of: adapters, environment: [:], home: home)
        #expect(roots.map(\.path) == ["/Users/user/.claude/plugins/data/subspace-subspace", "/other/root"])
    }

    @Test func subspaceDirIsOneSharedRootForAllSources() {
        let adapters: [any PushAdapter] = [claudeCode(environment: ["SUBSPACE_DIR": "/spool", "CLAUDE_CONFIG_DIR": "/cfg"]), StubAdapter(source: "a", root: URL(fileURLWithPath: "/other"))]
        let roots = SpoolReader.roots(of: adapters, environment: ["SUBSPACE_DIR": "/spool", "CLAUDE_CONFIG_DIR": "/cfg"], home: home)
        #expect(roots.map(\.path) == ["/spool"])
    }

    @Test func aChosenFolderWinsOverSubspaceDirWhichWinsOverTheDefault() {
        let adapter = StubAdapter(source: "a", root: URL(fileURLWithPath: "/own", isDirectory: true))
        let chosen = URL(fileURLWithPath: "/chosen/./spool/", isDirectory: true)
        let shared = ["SUBSPACE_DIR": "/shared"]
        #expect(SubspaceRoot.resolve(adapter: adapter, chosen: chosen, environment: shared, home: home).path == "/chosen/spool")
        #expect(SubspaceRoot.resolve(adapter: adapter, chosen: nil, environment: shared, home: home).path == "/shared")
        #expect(SubspaceRoot.resolve(adapter: adapter, chosen: nil, environment: [:], home: home).path == "/own")
        #expect(SubspaceRoot.resolve(URL(fileURLWithPath: "/own"), chosen: chosen, environment: shared).path == "/chosen/spool")
        // A chosen folder without a path, e.g. a broken stored value, falls through.
        let empty = URL(string: "file:")
        #expect(SubspaceRoot.resolve(adapter: adapter, chosen: empty, environment: shared, home: home).path == "/shared")
    }

    @Test func aChosenFolderMovesOnlyItsOwnSource() {
        let adapters: [any PushAdapter] = [
            StubAdapter(source: "a", root: URL(fileURLWithPath: "/a", isDirectory: true)),
            StubAdapter(source: "b", root: URL(fileURLWithPath: "/b", isDirectory: true)),
        ]
        let chosen: [SourceID: URL] = ["b": URL(fileURLWithPath: "/chosen", isDirectory: true)]
        #expect(SpoolReader.roots(of: adapters, chosen: chosen, environment: [:], home: home).map(\.path) == ["/a", "/chosen"])
        // `SUBSPACE_DIR` still moves the sources without a chosen folder.
        #expect(SpoolReader.roots(of: adapters, chosen: chosen, environment: ["SUBSPACE_DIR": "/shared"], home: home).map(\.path)
            == ["/shared", "/chosen"])
    }

    @Test func aSourceWithTwoRootsReadsBothUnlessAFolderIsChosenOrShared() {
        let adapter = MultiRootAdapter(roots: [URL(fileURLWithPath: "/cli/./spool/", isDirectory: true),
                                               URL(fileURLWithPath: "/desktop/spool", isDirectory: true)])
        #expect(SubspaceRoot.resolveAll(adapter: adapter, environment: [:], home: home).map(\.path) == ["/cli/spool", "/desktop/spool"])
        // A chosen folder or `SUBSPACE_DIR` replaces all of them, with the same precedence as for one root.
        let chosen = URL(fileURLWithPath: "/chosen", isDirectory: true)
        #expect(SubspaceRoot.resolveAll(adapter: adapter, chosen: chosen, environment: ["SUBSPACE_DIR": "/shared"], home: home).map(\.path)
            == ["/chosen"])
        #expect(SubspaceRoot.resolveAll(adapter: adapter, environment: ["SUBSPACE_DIR": "/shared"], home: home).map(\.path) == ["/shared"])
        #expect(SubspaceRoot.resolveAll(adapter: adapter, chosen: URL(string: "file:"), environment: [:], home: home).map(\.path)
            == ["/cli/spool", "/desktop/spool"])
    }

    @Test func aSingleRootSourceResolvesToItsOneRoot() {
        let adapter = StubAdapter(source: "a", root: URL(fileURLWithPath: "/own/", isDirectory: true))
        #expect(SubspaceRoot.resolveAll(adapter: adapter, environment: [:], home: home).map(\.path) == ["/own"])
    }

    @Test func theReaderWatchesEveryRootOfASourceEachFolderOnce() {
        let adapters: [any PushAdapter] = [
            StubAdapter(source: "a", root: URL(fileURLWithPath: "/a", isDirectory: true)),
            MultiRootAdapter(roots: [URL(fileURLWithPath: "/cli", isDirectory: true), URL(fileURLWithPath: "/./a/", isDirectory: true),
                                     URL(fileURLWithPath: "/desktop", isDirectory: true), URL(fileURLWithPath: "/cli/", isDirectory: true)]),
        ]
        #expect(SpoolReader.roots(of: adapters, environment: [:], home: home).map(\.path) == ["/a", "/cli", "/desktop"])
        #expect(SpoolReader.roots(of: adapters, chosen: ["multi": URL(fileURLWithPath: "/chosen")], environment: [:], home: home).map(\.path)
            == ["/a", "/chosen"])
    }

    // MARK: choosing a folder

    let twoRoots: [SourceID: [URL]] = ["multi": [URL(fileURLWithPath: "/cli/spool", isDirectory: true),
                                                 URL(fileURLWithPath: "/desktop/spool", isDirectory: true)]]

    /// One of the source's own folders is no choice: the reader keeps reading all of them.
    @Test(arguments: ["/cli/spool", "/cli/spool/", "/desktop/spool/", "/desktop/./spool", "/cli/x/../spool"])
    func choosingOneOfTheDefaultFoldersResetsToAllOfThem(path: String) {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let chosen = SubspaceRoot.choice(folder, defaults: twoRoots["multi"]!)
        #expect(chosen == nil)
        // Nothing chosen before: nothing to read anew.
        #expect(!SubspaceRoot.rootsChange(defaults: twoRoots, from: [:], to: ["multi": chosen].compactMapValues { $0 }))
        // Another folder chosen before: back to both defaults.
        let other: [SourceID: URL] = ["multi": URL(fileURLWithPath: "/elsewhere", isDirectory: true)]
        #expect(SubspaceRoot.rootsChange(defaults: twoRoots, from: other, to: ["multi": chosen].compactMapValues { $0 }))
    }

    @Test func choosingAnotherFolderReplacesAllDefaults() {
        let folder = URL(fileURLWithPath: "/elsewhere/", isDirectory: true)
        #expect(SubspaceRoot.choice(folder, defaults: twoRoots["multi"]!) == folder)
        #expect(SubspaceRoot.choice(URL(fileURLWithPath: "/cli", isDirectory: true), defaults: twoRoots["multi"]!)?.path == "/cli")
        #expect(SubspaceRoot.rootsChange(defaults: twoRoots, from: [:], to: ["multi": folder]))
        #expect(SubspaceRoot.choice(nil, defaults: twoRoots["multi"]!) == nil)
    }

    @Test func choosingTheOneDefaultFolderOfASingleRootSourceIsAReset() {
        let defaults = [URL(fileURLWithPath: "/own", isDirectory: true)]
        #expect(SubspaceRoot.choice(URL(fileURLWithPath: "/own/", isDirectory: true), defaults: defaults) == nil)
        #expect(SubspaceRoot.choice(URL(fileURLWithPath: "/chosen", isDirectory: true), defaults: defaults)?.path == "/chosen")
        // An unregistered source has no defaults to fall back to.
        #expect(SubspaceRoot.choice(URL(fileURLWithPath: "/own", isDirectory: true), defaults: [])?.path == "/own")
    }
}

// MARK: - Reader

@Suite struct SpoolReaderTests {
    /// Writes a fixture run as subspace would spool it, one second apart.
    private func spool(_ run: Run, into root: URL) throws -> [Envelope] {
        let start = 1_790_000_000
        return try run.payloads.enumerated().map { index, data in
            let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let ts = start + index
            try writeEvent(envelopeJSON(ts: ts, payload: payload), in: root, name: "\(ts)-4242-\(index)",
                           mtime: Date(timeIntervalSince1970: TimeInterval(ts)))
            return Envelope(source: "claude-code", pid: 4242, payload: data, receivedAt: Date(timeIntervalSince1970: TimeInterval(ts)))
        }
    }

    @Test(arguments: Run.allCases)
    func theBacklogGivesWhatTheAdapterGivesForTheSamePayloads(run: Run) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let envelopes = try spool(run, into: root)
        let direct = run.adapter()
        let expected = try envelopes.flatMap { try direct.events(from: $0) }

        let reader = SpoolReader(adapters: [run.adapter()], environment: ["SUBSPACE_DIR": root.path], watcher: ManualWatcher())
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }

        let events = await recorder.waitFor(expected.count)
        #expect(events == expected)
    }

    @Test(arguments: Run.allCases)
    func theBacklogOfARootArrivesAsOneBatch(run: Run) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let envelopes = try spool(run, into: root)
        let direct = run.adapter()
        let expected = try envelopes.flatMap { try direct.events(from: $0) }

        let reader = SpoolReader(adapters: [run.adapter()], environment: ["SUBSPACE_DIR": root.path], watcher: ManualWatcher())
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }

        _ = await recorder.waitFor(expected.count)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.batches == [expected])
    }

    @Test func aFileWrittenAfterStartArrivesAsALaterBatch() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: root, name: "1", mtime: t)
        try writeEvent(envelopeJSON(payload: payload("Stop")), in: root, name: "2", mtime: t.addingTimeInterval(1))
        let watcher = ManualWatcher()
        let reader = SpoolReader(adapters: [claudeCode(environment: ["SUBSPACE_DIR": root.path])], environment: ["SUBSPACE_DIR": root.path], watcher: watcher)
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }
        #expect(await recorder.waitFor(2).count == 2)

        let day = try writeEvent(envelopeJSON(payload: payload("Stop")), in: root, name: "3").deletingLastPathComponent()
        watcher.send([day])
        _ = await recorder.waitFor(3)
        #expect(await recorder.batches.map(\.count) == [2, 1])
        #expect(await recorder.batches.last?.map(\.kind) == [.turnEnded()])
    }

    @Test func aScanWithoutEventsYieldsNoBatch() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        try writeEvent(Data("{\"v\":1,".utf8), in: root, name: "1", mtime: t)
        try writeEvent(envelopeJSON(source: "gemini", payload: payload("Stop")), in: root, name: "2", mtime: t.addingTimeInterval(1))
        let watcher = ManualWatcher()
        let reader = SpoolReader(adapters: [claudeCode(environment: ["SUBSPACE_DIR": root.path])], environment: ["SUBSPACE_DIR": root.path], watcher: watcher)
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }
        #expect(await eventually { watcher.directories.count == 1 })

        // A change scan with only unreadable files yields nothing either.
        let day = try writeEvent(Data("[1]".utf8), in: root, name: "3").deletingLastPathComponent()
        watcher.send([day])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.batches.isEmpty)

        // Proof the reader still runs: the next readable file arrives alone.
        try writeEvent(envelopeJSON(payload: payload("Stop")), in: root, name: "4")
        watcher.send([day])
        _ = await recorder.waitFor(1)
        #expect(await recorder.batches.map(\.count) == [1])
    }

    @Test func backlogFinishedFollowsTheBacklogOfEveryRootOnce() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let claudeConfig = base.appendingPathComponent("claude", isDirectory: true)
        let otherRoot = base.appendingPathComponent("other", isDirectory: true)
        let environment = ["CLAUDE_CONFIG_DIR": claudeConfig.path]
        let claudeRoot = claudeCode(environment: environment).spoolRoot(environment: environment, home: home)
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: claudeRoot, name: "1")
        try writeEvent(envelopeJSON(source: "other", payload: payload("Stop")), in: otherRoot, name: "2")
        let watcher = ManualWatcher()
        let reader = SpoolReader(adapters: [claudeCode(environment: environment), StubAdapter(source: "other", root: otherRoot)],
                                 environment: environment, watcher: watcher)
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }

        #expect(await eventually { await recorder.backlogFinished == [2] })
        // Later changes are no backlog.
        let day = try writeEvent(envelopeJSON(payload: payload("Stop")), in: claudeRoot, name: "3").deletingLastPathComponent()
        watcher.send([day])
        _ = await recorder.waitFor(3)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.backlogFinished == [2])
    }

    @Test func backlogFinishedFiresForARootWithoutEvents() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeEvent(Data("{\"v\":1,".utf8), in: root, name: "1")
        let watcher = ManualWatcher()
        let reader = SpoolReader(adapters: [claudeCode(environment: ["SUBSPACE_DIR": root.path])], environment: ["SUBSPACE_DIR": root.path], watcher: watcher)
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }

        #expect(await eventually { await recorder.backlogFinished == [0] })
        #expect(await recorder.batches.isEmpty)
    }

    @Test func backlogFinishedFiresForAMissingRootAndNotAgainWhenItAppears() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("missing", isDirectory: true)
        let reader = SpoolReader(adapters: [claudeCode(environment: ["SUBSPACE_DIR": root.path])], environment: ["SUBSPACE_DIR": root.path],
                                 watcher: ManualWatcher(), pollInterval: .milliseconds(20))
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }

        #expect(await eventually { await recorder.backlogFinished == [0] })
        // The root's first scan after it appears is no startup backlog.
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), creatingRoot: root, name: "1")
        #expect(await recorder.waitFor(1).count == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.backlogFinished == [0])
    }

    @Test func skipsWhatItCannotReadAndKeepsGoing() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: root, name: "1", mtime: t)
        try writeEvent(envelopeJSON(v: 2, payload: payload("Stop")), in: root, name: "2", mtime: t.addingTimeInterval(1))
        try writeEvent(Data("{\"v\":1,".utf8), in: root, name: "3", mtime: t.addingTimeInterval(2))
        try writeEvent(envelopeJSON(source: "gemini", payload: payload("Stop")), in: root, name: "4", mtime: t.addingTimeInterval(3))
        try writeEvent(envelopeJSON(payload: ["session_id": "s1"]), in: root, name: "5", mtime: t.addingTimeInterval(4))
        try writeEvent(envelopeJSON(payload: payload("Stop")), in: root, name: "6", mtime: t.addingTimeInterval(5))

        let reader = SpoolReader(adapters: [claudeCode(environment: ["SUBSPACE_DIR": root.path])], environment: ["SUBSPACE_DIR": root.path], watcher: ManualWatcher())
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }

        let events = await recorder.waitFor(2)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.events.map(\.kind) == [.sessionStarted(cwd: nil, pid: 4242), .turnEnded()])
        #expect(events.count == 2)
    }

    @Test func routesEnvelopesBySourceAcrossRoots() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let claudeConfig = base.appendingPathComponent("claude", isDirectory: true)
        let otherRoot = base.appendingPathComponent("other", isDirectory: true)
        let claudeRoot = claudeCode(environment: ["CLAUDE_CONFIG_DIR": claudeConfig.path]).spoolRoot(environment: ["CLAUDE_CONFIG_DIR": claudeConfig.path], home: home)
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: claudeRoot, name: "1")
        // A source's events are routed by `source`, wherever they lie.
        try writeEvent(envelopeJSON(source: "other", payload: payload("Stop")), in: otherRoot, name: "2")

        let reader = SpoolReader(adapters: [claudeCode(environment: ["CLAUDE_CONFIG_DIR": claudeConfig.path]), StubAdapter(source: "other", root: otherRoot)],
                                 environment: ["CLAUDE_CONFIG_DIR": claudeConfig.path], watcher: ManualWatcher())
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }

        let events = await recorder.waitFor(2)
        #expect(Set(events.map(\.session.source)) == ["claude-code", "other"])
    }

    @Test func aMissingRootIsOnlyPolledUntilItAppears() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("plugins/data/subspace-subspace", isDirectory: true)
        let watcher = ManualWatcher()
        let reader = SpoolReader(adapters: [claudeCode(environment: ["SUBSPACE_DIR": root.path])], environment: ["SUBSPACE_DIR": root.path],
                                 watcher: watcher, pollInterval: .milliseconds(20))
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }

        // Without the root nothing is watched, so an idle app costs nothing.
        try await Task.sleep(for: .milliseconds(100))
        #expect(watcher.directories.isEmpty)

        // Polling finds the root and reads its backlog without any watcher event.
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), creatingRoot: root, name: "1")
        #expect(await recorder.waitFor(1).count == 1)
        #expect(watcher.directories.map(\.path) == [root.standardizedFileURL.path])

        let day = try writeEvent(envelopeJSON(payload: payload("Stop")), in: root, name: "2").deletingLastPathComponent()
        watcher.send([day])
        #expect(await recorder.waitFor(2).map(\.kind) == [.sessionStarted(cwd: nil, pid: 4242), .turnEnded()])
    }

    @Test func aRootThatVanishesIsWaitedForAgain() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = ManualWatcher()
        let reader = SpoolReader(adapters: [claudeCode(environment: ["SUBSPACE_DIR": root.path])], environment: ["SUBSPACE_DIR": root.path],
                                 watcher: watcher, pollInterval: .milliseconds(20))
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }
        #expect(await eventually { watcher.directories.count == 1 })

        // Claude Code deletes the root on uninstall; a reinstall creates it anew.
        try FileManager.default.removeItem(at: root)
        watcher.send(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(watcher.directories.count == 1)

        try writeEvent(envelopeJSON(payload: payload("SessionStart")), creatingRoot: root, name: "1")
        #expect(await recorder.waitFor(1).count == 1)
        #expect(watcher.directories.count == 2)
    }

    @Test func readsFilesWrittenWhileRunningWithFSEvents() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = SpoolReader(adapters: [claudeCode(environment: ["SUBSPACE_DIR": root.path])], environment: ["SUBSPACE_DIR": root.path])
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }

        // Give FSEvents a moment to start, then write the way subspace does.
        try await Task.sleep(for: .milliseconds(300))
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: root, name: "1")
        #expect(await recorder.waitFor(1).count == 1)
        try writeEvent(envelopeJSON(payload: payload("Stop")), in: root, day: "2026-10-02", name: "2")
        #expect(await recorder.waitFor(2).map(\.kind) == [.sessionStarted(cwd: nil, pid: 4242), .turnEnded()])
    }
}

// MARK: - Store

/// What a directory holds: each entry's bytes and mtime in nanoseconds, by relative path.
/// Directories count with their path only.
private struct Entry: Equatable {
    let data: Data?
    let mtime: Int64?
}

private func snapshot(_ directory: URL) -> [String: Entry] {
    var entries: [String: Entry] = [:]
    for path in FileManager.default.subpaths(atPath: directory.path) ?? [] {
        let url = directory.appendingPathComponent(path)
        var info = stat()
        guard stat(url.path, &info) == 0 else { continue }
        if info.st_mode & S_IFMT == S_IFDIR {
            entries[path] = Entry(data: nil, mtime: nil)
        } else {
            let mtime = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
            entries[path] = Entry(data: FileManager.default.contents(atPath: url.path), mtime: mtime)
        }
    }
    return entries
}

/// The live session of `OrphanSpool` as subspace spooled it, each event's file in arrival
/// order. Made once: every test that spools the capture would read and encode
/// its 270 payloads again.
private let orphanFiles = Result {
    try OrphanSpool().events.enumerated().map { index, event in
        let ts = Int(event.at.timeIntervalSince1970)
        let payload = try JSONSerialization.jsonObject(with: event.payload) as! [String: Any]
        return (name: "\(ts)-\(OrphanSpool.pid)-\(index)", envelope: envelopeJSON(ts: ts, pid: Int(OrphanSpool.pid), payload: payload),
                mtime: event.at.addingTimeInterval(Double(index) / 1000))
    }
}

/// Spools that session as subspace did, each event in its own file of
/// `events/2026-10-05/`: all of it, or its first `count` events.
private func spoolOrphanFixture(into root: URL, first count: Int? = nil) throws {
    let files = try orphanFiles.get()
    for file in files.prefix(count ?? files.count) {
        try writeEvent(file.envelope, in: root, day: "2026-10-05", name: file.name, mtime: file.mtime)
    }
}

/// The session's start, up to its fifth subagent's end, for the tests that are
/// about what the reader does with a backlog and not about this session.
/// Parsing and mapping all of it would be most of their work; this quarter of
/// its bytes is still enough files to be read in several chunks at once.
private func spoolOrphanStart(into root: URL) throws {
    try spoolOrphanFixture(into: root, first: 65)
}

/// A reader with a fresh adapter on `root`, as after a start of the app.
private func storeReader(of root: URL, store: URL?, maxAge: TimeInterval? = nil,
                         watcher: any DirectoryWatching = ManualWatcher()) -> SpoolReader {
    let environment = ["SUBSPACE_DIR": root.path]
    return SpoolReader(adapters: [claudeCode(environment: environment)], environment: environment,
                       watcher: watcher, pollInterval: .milliseconds(20),
                       store: store.map { SpoolReader.Store(path: $0, maxAge: maxAge) })
}

/// Starts a reader on `root` and returns its backlog. The reader has stopped
/// then, so the next one has the store to itself.
private func backlog(of root: URL, store: URL?, maxAge: TimeInterval? = nil) async -> [AgentEvent] {
    await backlog(of: storeReader(of: root, store: store, maxAge: maxAge))
}

private func backlog(of reader: SpoolReader) async -> [AgentEvent] {
    let recorder = Recorder(await reader.events())
    let finished = await eventually { await !recorder.backlogFinished.isEmpty }
    #expect(finished, "timed out waiting for the backlog")
    await reader.stop()
    return await recorder.events
}

/// The spool files a store opened, through `EventStore`'s `readFile`.
private final class OpenedFiles: Sendable {
    private let files = Mutex<[URL]>([])

    var count: Int { files.withLock(\.count) }

    func read(_ file: URL) throws -> Data {
        files.withLock { $0.append(file) }
        return try Data(contentsOf: file)
    }
}

/// The times a reader opened its store, through `openStore`, and whether each
/// was on the main thread.
private final class StoreOpenings: Sendable {
    private let threads = Mutex<[Bool]>([])

    var onMainThread: [Bool] { threads.withLock { $0 } }

    func open(_ path: URL, maxAge: TimeInterval?) throws -> any SpoolStore {
        threads.withLock { $0.append(Thread.isMainThread) }
        return try EventStore(path: path, maxAge: maxAge)
    }
}

/// A flag a test raises from wherever it runs, e.g. inside a store's hook.
private final class Flag: Sendable {
    private let raised = Mutex(false)

    var isRaised: Bool { raised.withLock { $0 } }

    func raise() { raised.withLock { $0 = true } }
}

/// How many descriptors of this process are open on `file`. Asked by path, so
/// whatever other tests have open at the same time doesn't count.
private func descriptors(on file: URL) -> Int {
    // `F_GETPATH` gives the real path; a file that doesn't exist has none open.
    guard let real = realpath(file.path, nil) else { return 0 }
    defer { free(real) }
    // Every open descriptor, in a list grown until it holds them all.
    let stride = MemoryLayout<proc_fdinfo>.stride
    var open: [proc_fdinfo] = []
    var listed = 0
    repeat {
        open = Array(repeating: proc_fdinfo(), count: max(256, open.count * 2))
        listed = Int(proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &open, Int32(open.count * stride))) / stride
    } while listed == open.count
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    return open.prefix(listed).count { fcntl($0.proc_fd, F_GETPATH, &path) == 0 && strcmp(path, real) == 0 }
}

/// Seam `SpoolStore`: a real `EventStore` that throws on demand and lets the
/// test in before a step. A store of the test's own can't stand in, as
/// `IngestResult` has no public initializer.
private final class FlakyStore: SpoolStore {
    enum Step: Hashable, Sendable { case prune, ingest, replay }
    struct Failure: Error {}

    private let store: EventStore
    /// Runs before the given call of a step, counted from 1.
    private let before: @Sendable (Step, Int) -> Void
    /// Whether the given call of a step, counted from 1, fails.
    private let fails: @Sendable (Step, Int) -> Bool
    private let calls = Mutex<[Step: Int]>([:])
    private let remappedRows = Mutex<[Int]>([])

    /// `fails` comes first, so a trailing closure is the failures.
    init(_ store: EventStore, failing fails: @escaping @Sendable (Step, Int) -> Bool = { _, _ in false },
         before: @escaping @Sendable (Step, Int) -> Void = { _, _ in }) {
        self.store = store
        self.before = before
        self.fails = fails
    }

    /// How many rows each ingest that succeeded re-mapped.
    var remapped: [Int] { remappedRows.withLock { $0 } }

    var maxAge: TimeInterval? {
        get { store.maxAge }
        set { store.maxAge = newValue }
    }

    func count(_ step: Step) -> Int { calls.withLock { $0[step, default: 0] } }

    private func failing(_ step: Step) -> Bool {
        let call = calls.withLock { calls in
            calls[step, default: 0] += 1
            return calls[step, default: 0]
        }
        before(step, call)
        return fails(step, call)
    }

    func ingest(root: URL, changed: Set<URL>?, documents: [SourceID: MappingDocument?],
                excluding: [SourceID: Set<String>], now: Date) async throws -> IngestResult {
        let store = store
        guard failing(.ingest) else {
            let result = try await store.ingest(root: root, changed: changed, documents: documents, excluding: excluding, now: now)
            remappedRows.withLock { $0.append(result.remapped.count) }
            return result
        }
        // The real ingest in a cancelled task: it throws and has stored nothing,
        // and the store keeps the reported days pending as after any failure.
        return try await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.ingest(root: root, changed: changed, documents: documents, excluding: excluding, now: now)
        }.value
    }

    func prune(now: Date) async throws -> Int {
        if failing(.prune) { throw Failure() }
        return try await store.prune(now: now)
    }

    func replay() async throws -> [StoredEvent] {
        if failing(.replay) { throw Failure() }
        return try await store.replay()
    }
}

/// The target fields an `ExcludingAdapter` has the store drop; the test changes
/// them while the reader runs.
private final class Exclusions: Sendable {
    private let excluded: Mutex<Set<String>>

    init(_ fields: Set<String>) { excluded = Mutex(fields) }

    var fields: Set<String> {
        get { excluded.withLock { $0 } }
        set { excluded.withLock { $0 = newValue } }
    }
}

/// The Claude Code adapter, except for the fields it excludes: a mapping that
/// changes between two ingests of a running reader.
private final class ExcludingAdapter: PushAdapter {
    private let adapter: ClaudeCodeAdapter
    private let exclusions: Exclusions

    init(_ adapter: ClaudeCodeAdapter, excluding exclusions: Exclusions) {
        self.adapter = adapter
        self.exclusions = exclusions
    }

    var source: SourceID { adapter.source }
    var displayName: String { adapter.displayName }
    var excludedFields: Set<String> { exclusions.fields }
    func events(from envelope: Envelope) throws -> [AgentEvent] { try adapter.events(from: envelope) }
    func mappingDocument() -> MappingDocument? { adapter.mappingDocument() }
    func events(from envelope: Envelope, mapped: MappingResult) throws -> [AgentEvent] { try adapter.events(from: envelope, mapped: mapped) }
    func spoolRoot(environment: [String: String], home: URL) -> URL { adapter.spoolRoot(environment: environment, home: home) }
}

/// Seam `SpoolReader.events()`: a temporary spool root, a real `EventStore` in a
/// temporary folder and a watcher driven by hand.
@Suite struct SpoolStoreTests {
    /// Subspace deleted the day (retention, contract §5); the next launch rebuilds
    /// the same sessions from the store alone.
    @Test func aRestartAfterRetentionGivesTheSameEventsAndState() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        try spoolOrphanFixture(into: root)
        let first = await backlog(of: root, store: store)
        #expect(!first.isEmpty)
        #expect(first == (await backlog(of: root, store: nil)))

        try FileManager.default.removeItem(at: root.appendingPathComponent("events/2026-10-05"))
        let second = await backlog(of: root, store: store)
        #expect(second == first)

        var before = CollectiveState()
        first.forEach { before.apply($0) }
        var after = CollectiveState()
        second.forEach { after.apply($0) }
        #expect(after == before)
        let session = try #require(after.sessions[OrphanSpool.session])
        // The capture starts mid-session, without `SessionStart`: no cwd or session
        // model to compare, but the subagents and their models: the root and six
        // subagents, the internal agent stays invisible.
        #expect(session.agents.count == 7)
        #expect(session.agents.values.contains { $0.spec.modelID != nil })
    }

    /// The envelope's `terminal` is kept with the event: a session rebuilt
    /// from the store alone knows its terminal again. Run 22's real `SessionStart`
    /// and `terminal` (Claude Code 2.1.318).
    @Test func aRestartFromTheStoreAloneKeepsTheTerminal() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        let run = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/claude-code/2.1.318/22-background-terminal-env")
        let start = try JSONSerialization.jsonObject(with: Data(contentsOf: run.appendingPathComponent("events/004-SessionStart.json")))
        let terminal = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: run.appendingPathComponent("terminal.json")))
        let envelope = try JSONSerialization.data(withJSONObject: [
            "v": 1, "source": "claude-code", "ts": 1_793_778_258, "pid": 39661, "terminal": terminal, "payload": start,
        ])
        try writeEvent(envelope, in: root, day: "2026-11-04", name: "004-SessionStart")

        let first = await backlog(of: root, store: store)
        try FileManager.default.removeItem(at: root.appendingPathComponent("events/2026-11-04"))
        let second = await backlog(of: root, store: store)

        #expect(!second.isEmpty)
        #expect(second == first)
        #expect(second.allSatisfy { $0.terminal == TerminalIdentifiers([
            "WARP_FOCUS_URL": "warp://session/1b10f2936c54494a955cc11fd5ab3b22",
            "WARP_TERMINAL_SESSION_UUID": "1b10f2936c54494a955cc11fd5ab3b22",
        ]) })
    }

    /// A known file is not opened again: the store has what parsing and mapping made of it.
    @Test func aSecondStartOpensNoSpoolFile() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        try spoolOrphanStart(into: root)
        let spooled = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("events/2026-10-05").path).count
        #expect(spooled > 0)
        let opened = OpenedFiles()
        let start = {
            let environment = ["SUBSPACE_DIR": root.path]
            return await backlog(of: SpoolReader(
                adapters: [claudeCode(environment: environment)], environment: environment, watcher: ManualWatcher(),
                pollInterval: .milliseconds(20), store: SpoolReader.Store(path: store, maxAge: nil),
                openStore: { try EventStore(path: $0, maxAge: $1, readFile: opened.read) }))
        }

        let first = await start()
        #expect(!first.isEmpty)
        #expect(opened.count == spooled, "the first start opens every file once")
        #expect(await start() == first)
        #expect(opened.count == spooled, "the second start opens none")
    }

    @Test func aFileWrittenAfterStartArrivesOnceAndARestartReplaysItOnce() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: root, name: "1", mtime: t)
        try writeEvent(envelopeJSON(payload: payload("Stop")), in: root, name: "2", mtime: t.addingTimeInterval(1))
        let watcher = ManualWatcher()
        let reader = storeReader(of: root, store: store, watcher: watcher)
        let recorder = Recorder(await reader.events())
        #expect(await eventually { await recorder.backlogFinished == [1] })

        let day = try writeEvent(envelopeJSON(payload: payload("Stop")), in: root, name: "3", mtime: t.addingTimeInterval(2))
            .deletingLastPathComponent()
        watcher.send([day])
        _ = await recorder.waitFor(3)
        // Further reports of the same day, or of everything, bring nothing again.
        watcher.send([day])
        watcher.send(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.batches.map(\.count) == [2, 1])
        #expect(await recorder.batches.last?.map(\.kind) == [.turnEnded()])
        #expect(await recorder.backlogFinished == [1])
        await reader.stop()

        let restarted = Recorder(await storeReader(of: root, store: store).events())
        defer { Task { await restarted.stop() } }
        #expect(await eventually { await restarted.backlogFinished == [1] })
        #expect(await restarted.batches == [await recorder.events])
    }

    /// With file events a report names the written file, not its day folder: the
    /// store checks just that file, so a sibling nobody reported waits for its
    /// own file or the day.
    @Test func aReportedFileArrivesAndAnUnreportedSiblingWaitsForItsOwnReport() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: root, name: "1", mtime: t)
        let watcher = ManualWatcher()
        let reader = storeReader(of: root, store: store, watcher: watcher)
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }
        #expect(await eventually { await recorder.backlogFinished == [1] })

        let reported = try writeEvent(envelopeJSON(payload: payload("Stop")), in: root, name: "2", mtime: t.addingTimeInterval(1))
        let unreported = try writeEvent(envelopeJSON(payload: payload("SessionStart", session: "s2")), in: root, name: "3",
                                        mtime: t.addingTimeInterval(2))
        watcher.send([reported])
        _ = await recorder.waitFor(2)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await recorder.batches.map(\.count) == [1, 1])
        #expect(await recorder.batches.last?.map(\.kind) == [.turnEnded()])

        watcher.send([unreported])
        _ = await recorder.waitFor(3)
        #expect(await recorder.events.count == 3)
        await reader.stop()
    }

    /// Without a store the scanner scans the day of a reported file, so the
    /// reported file's event arrives (and its unreported sibling with it).
    @Test func aReportedFileArrivesWithoutAStore() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: root, name: "1", mtime: t)
        let watcher = ManualWatcher()
        let reader = storeReader(of: root, store: nil, watcher: watcher)
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }
        #expect(await eventually { await recorder.backlogFinished == [1] })

        let reported = try writeEvent(envelopeJSON(payload: payload("Stop")), in: root, name: "2", mtime: t.addingTimeInterval(1))
        watcher.send([reported])
        let events = await recorder.waitFor(2)
        #expect(events.last?.kind == .turnEnded())
        await reader.stop()
    }

    /// A source counts as connected by events only for what the app read from
    /// the spool: of a replay, the events whose file the root still holds, not
    /// those only the store kept, e.g. from before subspace's retention or a
    /// reinstall. The event that leaves the spool is the newer one, so counting it would show.
    @Test func aReplayTellsTheEventsTheSpoolStillHoldsFromThoseOnlyTheStoreKept() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        try writeEvent(envelopeJSON(ts: 1_790_000_010, payload: payload("Stop", session: "gone")), in: root, day: "2026-10-01",
                       name: "1", mtime: t)
        try writeEvent(envelopeJSON(ts: 1_790_000_001, payload: payload("Stop", session: "kept")), in: root, day: "2026-10-02",
                       name: "2", mtime: t.addingTimeInterval(1))

        let reader = storeReader(of: root, store: store)
        let first = Recorder(await reader.events())
        #expect(await eventually { await first.backlogFinished == [1] })
        await reader.stop()
        let events = await first.events
        #expect(events.map(\.session.sessionID) == ["gone", "kept"])
        #expect(await first.fresh.map(\.bySource) == [["claude-code": Date(timeIntervalSince1970: 1_790_000_010)]],
                "at the first start every file lies in the spool")

        try FileManager.default.removeItem(at: root.appendingPathComponent("events/2026-10-01"))
        let restarted = Recorder(await storeReader(of: root, store: store).events())
        defer { Task { await restarted.stop() } }
        #expect(await eventually { await restarted.backlogFinished == [1] })
        #expect(await restarted.batches == [events])
        #expect(await restarted.fresh.map(\.bySource) == [["claude-code": Date(timeIntervalSince1970: 1_790_000_001)]])
    }

    /// A former root's rows came from a folder the reader no longer reads,
    /// even while that folder is still there. Its event is the newer one, so
    /// counting it would show.
    @Test func aFormerRootsRowsAreNotSpooled() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("old", isDirectory: true)
        let root = base.appendingPathComponent("new", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        try writeEvent(envelopeJSON(ts: 1_790_000_010, payload: payload("Stop", session: "old")), in: old, name: "1", mtime: t)
        try writeEvent(envelopeJSON(ts: 1_790_000_001, payload: payload("Stop", session: "new")), in: root, name: "2",
                       mtime: t.addingTimeInterval(1))
        _ = await backlog(of: old, store: store)

        let recorder = Recorder(await storeReader(of: root, store: store).events())
        defer { Task { await recorder.stop() } }
        #expect(await eventually { await recorder.backlogFinished == [1] })
        #expect(await recorder.events.map(\.session.sessionID) == ["old", "new"])
        #expect(await recorder.fresh.map(\.bySource) == [["claude-code": Date(timeIntervalSince1970: 1_790_000_001)]])
    }

    /// E.g. Claude Code removed the root on uninstall: what the store has of it
    /// still shows. When the root comes back with the same files, they aren't
    /// news: only what the store doesn't have yet arrives.
    @Test func aRootMissingAtStartIsReplayedAndBringsOnlyUnknownFilesWhenItAppears() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        try spoolOrphanStart(into: root)
        let first = await backlog(of: root, store: store)
        #expect(!first.isEmpty)
        let away = base.appendingPathComponent("spool-away", isDirectory: true)
        try FileManager.default.moveItem(at: root, to: away)

        let watcher = ManualWatcher()
        let reader = storeReader(of: root, store: store, watcher: watcher)
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }
        #expect(await eventually { await recorder.backlogFinished == [1] })
        #expect(await recorder.events == first)
        #expect(watcher.directories.isEmpty)

        // Back with one more file already in it: polling finds it without a watcher report.
        try writeEvent(envelopeJSON(payload: payload("Stop", session: "new")), in: away, day: "2026-10-05", name: "z")
        try FileManager.default.moveItem(at: away, to: root)
        let events = await recorder.waitFor(first.count + 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.events == events)
        #expect(Array(events.prefix(first.count)) == first)
        #expect(events.dropFirst(first.count).map(\.session.sessionID) == ["new"])
        #expect(await recorder.batches.map(\.count) == [first.count, 1])
        #expect(await recorder.backlogFinished == [1])
        #expect(watcher.directories == [root.standardizedFileURL])
    }

    /// The user switched the source to another folder: sessions from the old one
    /// come from the store, in the one backlog batch, and the old folder is never watched.
    @Test func aFormerRootsRowsAreReplayedOnceInTheBacklog() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("old", isDirectory: true)
        let root = base.appendingPathComponent("new", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        try spoolOrphanStart(into: old)
        let first = await backlog(of: old, store: store)
        #expect(!first.isEmpty)
        // Newer than the capture, so the replay's order puts it last.
        try writeEvent(envelopeJSON(payload: payload("SessionStart", session: "new")), in: root, name: "new",
                       mtime: try #require(orphanFiles.get().last).mtime.addingTimeInterval(60))

        let environment = ["SUBSPACE_DIR": "/elsewhere"]
        let start = { (watcher: ManualWatcher) in
            SpoolReader(adapters: [claudeCode(environment: environment)], chosenRoots: ["claude-code": root],
                        environment: environment, watcher: watcher, pollInterval: .milliseconds(20),
                        store: SpoolReader.Store(path: store, maxAge: nil))
        }
        let watcher = ManualWatcher()
        let reader = start(watcher)
        let recorder = Recorder(await reader.events())
        #expect(await eventually { await recorder.backlogFinished == [1] })
        let events = await recorder.events
        #expect(Array(events.prefix(first.count)) == first)
        #expect(events.dropFirst(first.count).map(\.session.sessionID) == ["new"])

        watcher.send(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.events == events)
        #expect(watcher.directories == [root.standardizedFileURL])
        await reader.stop()

        // After a restart the same, again as one batch.
        let restarted = Recorder(await start(ManualWatcher()).events())
        defer { Task { await restarted.stop() } }
        #expect(await eventually { await restarted.backlogFinished == [1] })
        #expect(await restarted.batches == [events])
    }

    /// The spool moved to another folder and the mapping changed: the store holds
    /// each file under both paths, and the freshly mapped row of the current root
    /// counts, whichever path the replay's order puts first.
    @Test(arguments: [("a-old", "z-current"), ("z-old", "a-current")])
    func aFormerRootsRowDoesNotHideTheCurrentRootsReMappedRow(former: String, current: String) async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent(former, isDirectory: true)
        let root = base.appendingPathComponent(current, isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        var start = payload("SessionStart")
        start["cwd"] = "/expected-project"
        try writeEvent(envelopeJSON(payload: start), in: old, name: "1")
        let environment = ["SUBSPACE_DIR": old.path]
        let excluding = SpoolReader(
            adapters: [ExcludingAdapter(claudeCode(environment: environment), excluding: Exclusions(["cwd"]))],
            environment: environment, watcher: ManualWatcher(),
            store: SpoolReader.Store(path: store, maxAge: nil))
        #expect(await backlog(of: excluding).map(\.kind) == [.sessionStarted(cwd: nil, pid: 4242)])

        try FileManager.default.moveItem(at: old, to: root)
        let raw = await backlog(of: root, store: nil)
        #expect(raw.map(\.kind) == [.sessionStarted(cwd: "/expected-project", pid: 4242)])
        #expect(await backlog(of: root, store: store) == raw)
        #expect(Set(try await EventStore(path: store, maxAge: nil).replay().map(\.root.lastPathComponent)) == [former, current])
    }

    /// The same with the two paths being one folder, one of them a link to it.
    /// The store keys rows by path, so the start re-maps only the rows of the
    /// path it reads: the row stored under the other path is as stale as a
    /// former folder's, wherever the link's name sorts.
    @Test(arguments: [("a-link", true), ("z-link", true), ("a-link", false), ("z-link", false)])
    func aRowStoredUnderAnotherPathOfTheFolderDoesNotHideTheReMappedRow(link name: String, linkFirst: Bool) async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let spool = base.appendingPathComponent("m-spool", isDirectory: true)
        let link = base.appendingPathComponent(name, isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        var start = payload("SessionStart")
        start["cwd"] = "/expected-project"
        try writeEvent(envelopeJSON(payload: start), in: spool, name: "1")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: spool)
        let (former, current) = linkFirst ? (link, spool) : (spool, link)
        let environment = ["SUBSPACE_DIR": former.path]
        let excluding = SpoolReader(
            adapters: [ExcludingAdapter(claudeCode(environment: environment), excluding: Exclusions(["cwd"]))],
            environment: environment, watcher: ManualWatcher(),
            store: SpoolReader.Store(path: store, maxAge: nil))
        #expect(await backlog(of: excluding).map(\.kind) == [.sessionStarted(cwd: nil, pid: 4242)])

        let raw = await backlog(of: current, store: nil)
        #expect(raw.map(\.kind) == [.sessionStarted(cwd: "/expected-project", pid: 4242)])
        #expect(await backlog(of: current, store: store) == raw)
        #expect(Set(try await EventStore(path: store, maxAge: nil).replay().map(\.root.lastPathComponent)) == ["m-spool", name])
    }

    /// Across such a move, a file deleted before it is left with its former
    /// root's row only: it is replayed once, as it was mapped then, between the
    /// freshly mapped rows of the files that moved, all in the order of their mtimes.
    @Test(arguments: [("a-old", "z-current"), ("z-old", "a-current")])
    func rowsOfBothRootsAreReplayedOnceEachInTheOrderOfTheirFiles(former: String, current: String) async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent(former, isDirectory: true)
        let root = base.appendingPathComponent(current, isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        let time = Date(timeIntervalSince1970: 1_790_000_000)
        var files: [URL] = []
        for (index, session) in ["s1", "s2", "s3"].enumerated() {
            var start = payload("SessionStart", session: session)
            start["cwd"] = "/project-\(session)"
            files.append(try writeEvent(envelopeJSON(payload: start), in: old, name: "\(index + 1)",
                                        mtime: time.addingTimeInterval(Double(index))))
        }
        let environment = ["SUBSPACE_DIR": old.path]
        let excluding = SpoolReader(
            adapters: [ExcludingAdapter(claudeCode(environment: environment), excluding: Exclusions(["cwd"]))],
            environment: environment, watcher: ManualWatcher(),
            store: SpoolReader.Store(path: store, maxAge: nil))
        #expect(await backlog(of: excluding).map(\.kind) == Array(repeating: .sessionStarted(cwd: nil, pid: 4242), count: 3))

        try FileManager.default.removeItem(at: files[1])
        try FileManager.default.moveItem(at: old, to: root)
        let events = await backlog(of: root, store: store)
        #expect(events.map(\.session.sessionID) == ["s1", "s2", "s3"])
        #expect(events.map(\.kind) == [.sessionStarted(cwd: "/project-s1", pid: 4242), .sessionStarted(cwd: nil, pid: 4242),
                                       .sessionStarted(cwd: "/project-s3", pid: 4242)])
    }

    /// The folder was copied instead, so the copy's files have their own mtimes
    /// and a file's two rows need not be neighbours in the replay: file 1 is the
    /// newest in the copy, file 3 kept its mtime, file 2 was not copied. The
    /// freshly mapped row still takes the place of the file's first row.
    @Test(arguments: [("a-old", "z-current"), ("z-old", "a-current")])
    func aCopiedFoldersReMappedRowTakesThePlaceOfTheFilesFirstRow(former: String, current: String) async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent(former, isDirectory: true)
        let root = base.appendingPathComponent(current, isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        let time = Date(timeIntervalSince1970: 1_790_000_000)
        for (index, session) in ["s1", "s2", "s3"].enumerated() {
            var start = payload("SessionStart", session: session)
            start["cwd"] = "/project-\(session)"
            try writeEvent(envelopeJSON(payload: start), in: old, name: "\(index + 1)",
                           mtime: time.addingTimeInterval(Double(index)))
        }
        let environment = ["SUBSPACE_DIR": old.path]
        let excluding = SpoolReader(
            adapters: [ExcludingAdapter(claudeCode(environment: environment), excluding: Exclusions(["cwd"]))],
            environment: environment, watcher: ManualWatcher(),
            store: SpoolReader.Store(path: store, maxAge: nil))
        #expect(await backlog(of: excluding).map(\.kind) == Array(repeating: .sessionStarted(cwd: nil, pid: 4242), count: 3))

        try FileManager.default.copyItem(at: old, to: root)
        let copies = root.appendingPathComponent("events/2026-10-01", isDirectory: true)
        try FileManager.default.setAttributes([.modificationDate: time.addingTimeInterval(10)],
                                              ofItemAtPath: copies.appendingPathComponent("1.json").path)
        try FileManager.default.removeItem(at: copies.appendingPathComponent("2.json"))
        try FileManager.default.setAttributes([.modificationDate: time.addingTimeInterval(2)],
                                              ofItemAtPath: copies.appendingPathComponent("3.json").path)

        let watcher = ManualWatcher()
        let reader = storeReader(of: root, store: store, watcher: watcher)
        let recorder = Recorder(await reader.events())
        #expect(await eventually { await recorder.backlogFinished == [1] })
        let events = await recorder.events
        // By each file's first row: s1 and s2 by the old mtimes, s3 by the one both rows share.
        #expect(events.map(\.session.sessionID) == ["s1", "s2", "s3"])
        #expect(events.map(\.kind) == [.sessionStarted(cwd: "/project-s1", pid: 4242), .sessionStarted(cwd: nil, pid: 4242),
                                       .sessionStarted(cwd: "/project-s3", pid: 4242)])

        watcher.send(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.events == events)
        await reader.stop()

        // What the store replays: file 1's current row comes last, far from its former one.
        let rows = try await EventStore(path: store, maxAge: nil).replay().map { "\($0.root.lastPathComponent)/\($0.name)" }
        #expect(rows == ["\(former)/1.json", "\(former)/2.json"] + [former, current].sorted().map { "\($0)/3.json" }
            + ["\(current)/1.json"])
    }

    /// A former root can be the current one under another path, e.g. through a
    /// link: the store then holds every file once per path, and each counts once.
    @Test func theSameFolderUnderTwoPathsYieldsEachFileOnce() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        try spoolOrphanStart(into: root)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let first = await backlog(of: link, store: store)
        #expect(!first.isEmpty)

        #expect(await backlog(of: root, store: store) == first)
        // Now the store holds every file under both paths; back on the link, still once.
        #expect(await backlog(of: link, store: store) == first)
        #expect(Set(try await EventStore(path: store, maxAge: nil).replay().map(\.root.lastPathComponent)) == ["spool", "link"])
    }

    /// The link's rows came from the replay. When the folder appears under its
    /// other path, the ingest calls its files new, but they were yielded already.
    @Test func aFileFromTheReplayIsNotYieldedAgainByALaterIngest() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        try spoolOrphanStart(into: root)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let first = await backlog(of: link, store: store)
        #expect(!first.isEmpty)
        let away = base.appendingPathComponent("spool-away", isDirectory: true)
        try FileManager.default.moveItem(at: root, to: away)

        let reader = storeReader(of: root, store: store)
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }
        #expect(await eventually { await recorder.backlogFinished == [1] })
        try writeEvent(envelopeJSON(payload: payload("Stop", session: "new")), in: away, day: "2026-10-05", name: "z")
        try FileManager.default.moveItem(at: away, to: root)
        let events = await recorder.waitFor(first.count + 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.events == events)
        #expect(await recorder.batches.map(\.count) == [first.count, 1])
        #expect(events.last?.session.sessionID == "new")
    }

    /// Subspace writes while the reader starts. The start subscribes before it
    /// ingests, so a file that comes after the ingest, too late for the replay,
    /// arrives with the watcher's report of it.
    @Test func aFileWrittenBetweenTheStartsIngestAndItsReplayArrivesOnce() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: root, name: "1", mtime: t)
        try writeEvent(envelopeJSON(payload: payload("Stop")), in: root, name: "2", mtime: t.addingTimeInterval(1))
        let watcher = ManualWatcher()
        let flaky = FlakyStore(try EventStore(path: store, maxAge: nil), before: { step, _ in
            guard step == .replay else { return }
            let day = try! writeEvent(envelopeJSON(payload: payload("Stop", session: "late")), in: root, name: "3",
                                      mtime: t.addingTimeInterval(2)).deletingLastPathComponent()
            // What FSEvents reports to the subscription the start has made by then.
            watcher.send([day])
        })
        let reader = reader(of: root, store: store, flaky: flaky, watcher: watcher)
        let recorder = Recorder(await reader.events())

        _ = await recorder.waitFor(3)
        watcher.send(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(flaky.count(.ingest) >= 2 && flaky.count(.replay) == 1)
        #expect(await recorder.batches.map(\.count) == [2, 1])
        #expect(await recorder.events.map(\.session.sessionID) == ["s1", "s1", "late"])
        #expect(await recorder.backlogFinished == [1])
        await reader.stop()

        #expect(await backlog(of: root, store: store) == (await recorder.events))
    }

    /// The mapping changes while the reader runs, here the fields an adapter
    /// excludes: the next report's ingest re-maps the rows the store has and
    /// returns them next to the new file's. Their events were yielded already,
    /// by the start's replay or with an earlier report, so only the new file's
    /// are; the re-mapped rows take effect at the next start.
    @Test func rowsReMappedWhileRunningAreNotYieldedAgain() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: root, name: "1", mtime: t)
        try writeEvent(envelopeJSON(payload: payload("Stop")), in: root, name: "2", mtime: t.addingTimeInterval(1))
        let exclusions = Exclusions(["tool_response"])
        let flaky = FlakyStore(try EventStore(path: store, maxAge: nil))
        let watcher = ManualWatcher()
        let environment = ["SUBSPACE_DIR": root.path]
        let reader = SpoolReader(adapters: [ExcludingAdapter(claudeCode(environment: environment), excluding: exclusions)],
                                 environment: environment, watcher: watcher, pollInterval: .milliseconds(20),
                                 store: SpoolReader.Store(path: store, maxAge: nil), openStore: { _, _ in flaky })
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }
        #expect(await eventually { await recorder.backlogFinished == [1] })
        #expect(flaky.remapped == [0])

        // A row the start's replay didn't return: nothing but its being
        // re-mapped, not new, keeps it from being yielded a second time.
        let day = try writeEvent(envelopeJSON(payload: payload("Stop", session: "live")), in: root, name: "3", mtime: t.addingTimeInterval(2))
            .deletingLastPathComponent()
        watcher.send([day])
        _ = await recorder.waitFor(3)
        #expect(flaky.remapped == [0, 0])

        exclusions.fields = ["tool_response", "cwd"]
        try writeEvent(envelopeJSON(payload: payload("Stop", session: "new")), in: root, name: "4", mtime: t.addingTimeInterval(3))
        watcher.send([day])
        _ = await recorder.waitFor(4)
        try await Task.sleep(for: .milliseconds(100))
        #expect(flaky.remapped == [0, 0, 3], "the report's ingest must re-map the three rows the store has")
        #expect(await recorder.batches.map(\.count) == [2, 1, 1])
        #expect(await recorder.events.map(\.session.sessionID) == ["s1", "s1", "live", "new"])
    }

    /// One source's root is a link to another's: the folder is watched once, under
    /// the first one's path, so its backlog and a file written later arrive once.
    @Test(arguments: [true, false])
    func twoRootsThatAreOneFolderYieldEachFileOnce(stored: Bool) async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try spoolOrphanStart(into: root)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let plain = await backlog(of: root, store: nil)
        #expect(!plain.isEmpty)

        let environment = ["SUBSPACE_DIR": root.path]
        let watcher = ManualWatcher()
        let store = SpoolReader.Store(path: base.appendingPathComponent("store/events.sqlite"), maxAge: nil)
        let reader = SpoolReader(adapters: [claudeCode(environment: environment), StubAdapter(source: "other", root: link)],
                                 chosenRoots: ["other": link], environment: environment, watcher: watcher,
                                 pollInterval: .milliseconds(20), store: stored ? store : nil)
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }
        #expect(await eventually { await !recorder.backlogFinished.isEmpty })
        #expect(await recorder.batches == [plain])

        let day = try writeEvent(envelopeJSON(payload: payload("Stop", session: "new")), in: root, day: "2026-10-05", name: "z")
            .deletingLastPathComponent()
        watcher.send([day])
        _ = await recorder.waitFor(plain.count + 1)
        watcher.send(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.batches.map(\.count) == [plain.count, 1])
        #expect(await recorder.events.last?.session.sessionID == "new")
        #expect(await recorder.backlogFinished == [1])
        #expect(watcher.directories == [root.standardizedFileURL])
    }

    /// The app's layout, a root per source and one store for both: the start is
    /// one batch in the contract's order across the roots, and each root is
    /// watched from then on.
    @Test func twoRootsOnOneStoreGiveOneBacklogInOrderAndBothAreWatched() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let otherRoot = base.appendingPathComponent("other", isDirectory: true)
        let environment = ["CLAUDE_CONFIG_DIR": base.appendingPathComponent("claude", isDirectory: true).path]
        let claudeRoot = claudeCode(environment: environment).spoolRoot(environment: environment, home: home)
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        // By mtime the two roots' files alternate.
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: claudeRoot, name: "1", mtime: t)
        try writeEvent(envelopeJSON(source: "other", payload: payload("Stop")), in: otherRoot, name: "2", mtime: t.addingTimeInterval(1))
        try writeEvent(envelopeJSON(payload: payload("Stop")), in: claudeRoot, name: "3", mtime: t.addingTimeInterval(2))
        try writeEvent(envelopeJSON(source: "other", payload: payload("Stop")), in: otherRoot, name: "4", mtime: t.addingTimeInterval(3))
        let watcher = ManualWatcher()
        let reader = SpoolReader(adapters: [claudeCode(environment: environment), StubAdapter(source: "other", root: otherRoot)],
                                 environment: environment, watcher: watcher, pollInterval: .milliseconds(20),
                                 store: SpoolReader.Store(path: base.appendingPathComponent("store/events.sqlite"), maxAge: nil))
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }
        #expect(await eventually { await recorder.backlogFinished == [1] })
        #expect(await recorder.batches.map { $0.map(\.session.source) } == [["claude-code", "other", "claude-code", "other"]])
        #expect(watcher.directories.map(\.path) == [claudeRoot, otherRoot].map(\.standardizedFileURL.path))

        // A file in each root; the report reaches both roots' watches.
        let claudeDay = try writeEvent(envelopeJSON(payload: payload("Stop", session: "live")), in: claudeRoot, name: "5",
                                       mtime: t.addingTimeInterval(4)).deletingLastPathComponent()
        let otherDay = try writeEvent(envelopeJSON(source: "other", payload: payload("Stop")), in: otherRoot, name: "6",
                                      mtime: t.addingTimeInterval(5)).deletingLastPathComponent()
        watcher.send([claudeDay, otherDay])
        _ = await recorder.waitFor(6)
        watcher.send(nil)
        try await Task.sleep(for: .milliseconds(100))
        let live = await recorder.events.dropFirst(4)
        #expect(live.count == 2)
        #expect(Set(live.map(\.session.source)) == ["claude-code", "other"])
        #expect(await recorder.backlogFinished == [1])
    }

    /// One source, two roots (e.g. a tool's CLI and its desktop app) and a third
    /// path that is a link to the first: both folders are watched once each, and
    /// every file of either arrives once, at start, live and in the next start's replay.
    @Test(arguments: [true, false])
    func aSourceWithTwoRootsGetsEveryFileOfEitherOnce(stored: Bool) async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cli = base.appendingPathComponent("cli", isDirectory: true)
        let desktop = base.appendingPathComponent("desktop", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try writeEvent(envelopeJSON(source: "multi", ts: 1_790_000_001, payload: payload("Stop")), in: cli, name: "1")
        try writeEvent(envelopeJSON(source: "multi", ts: 1_790_000_002, payload: payload("Stop")), in: desktop, name: "2")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli)
        let store = SpoolReader.Store(path: base.appendingPathComponent("store/events.sqlite"), maxAge: nil)
        func reader(_ watcher: ManualWatcher) -> SpoolReader {
            SpoolReader(adapters: [MultiRootAdapter(roots: [cli, link, desktop])], environment: [:], watcher: watcher,
                        pollInterval: .milliseconds(20), store: stored ? store : nil)
        }
        let times = { (events: [AgentEvent]) in events.map { Int($0.timestamp.timeIntervalSince1970) }.sorted() }

        let watcher = ManualWatcher()
        let first = reader(watcher)
        let recorder = Recorder(await first.events())
        #expect(await eventually { await !recorder.backlogFinished.isEmpty })
        #expect(times(await recorder.events) == [1_790_000_001, 1_790_000_002])
        // Without a store each root's watch subscribes on its own, in no set order.
        #expect(watcher.directories.map(\.path).sorted() == [cli, desktop].map(\.standardizedFileURL.path))

        let cliDay = try writeEvent(envelopeJSON(source: "multi", ts: 1_790_000_003, payload: payload("Stop")), in: cli, name: "3")
            .deletingLastPathComponent()
        let desktopDay = try writeEvent(envelopeJSON(source: "multi", ts: 1_790_000_004, payload: payload("Stop")), in: desktop, name: "4")
            .deletingLastPathComponent()
        watcher.send([cliDay, desktopDay])
        _ = await recorder.waitFor(4)
        watcher.send(nil)
        try await Task.sleep(for: .milliseconds(100))
        let all = [1_790_000_001, 1_790_000_002, 1_790_000_003, 1_790_000_004]
        #expect(times(await recorder.events) == all)
        await first.stop()
        await recorder.stop()

        let second = reader(ManualWatcher())
        let restarted = Recorder(await second.events())
        defer { Task { await restarted.stop() } }
        #expect(await eventually { await !restarted.backlogFinished.isEmpty })
        #expect(times(await restarted.events) == all)
        await second.stop()
    }

    // MARK: Retention

    private static let threeDays: TimeInterval = 3 * 24 * 3600

    /// Two sessions: one whose file is ten days old, one from an hour ago.
    private func spoolOldAndRecent(into root: URL) throws {
        try writeEvent(envelopeJSON(payload: payload("SessionStart", session: "old")), in: root, day: "2026-10-01", name: "old",
                       mtime: Date().addingTimeInterval(-10 * 24 * 3600))
        try writeEvent(envelopeJSON(payload: payload("SessionStart", session: "recent")), in: root, day: "2026-10-10", name: "recent",
                       mtime: Date().addingTimeInterval(-3600))
    }

    @Test func aFileOlderThanTheMaximumAgeIsNotYieldedOnAFirstStart() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        try spoolOldAndRecent(into: root)

        let limited = await backlog(of: root, store: base.appendingPathComponent("limited/events.sqlite"), maxAge: Self.threeDays)
        #expect(limited.map(\.session.sessionID) == ["recent"])
        // Without a maximum age nothing is dropped.
        let unlimited = await backlog(of: root, store: base.appendingPathComponent("unlimited/events.sqlite"), maxAge: nil)
        #expect(unlimited.map(\.session.sessionID) == ["old", "recent"])
    }

    /// The user lowered the retention while the app runs: the next prune pass
    /// drops what is older, and it stays away although the spool still has it.
    @Test func pruningDropsRowsOlderThanTheNewMaximumAge() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        try spoolOldAndRecent(into: root)
        let watcher = ManualWatcher()
        let reader = storeReader(of: root, store: store, maxAge: nil, watcher: watcher)
        let recorder = Recorder(await reader.events())
        #expect(await eventually { await recorder.backlogFinished == [1] })
        #expect(await recorder.events.map(\.session.sessionID) == ["old", "recent"])

        await reader.pruneStore(now: Date())
        #expect(try await EventStore(path: store, maxAge: nil).replay().map(\.name) == ["old.json", "recent.json"])
        await reader.setMaxAge(Self.threeDays)
        await reader.pruneStore(now: Date())
        #expect(try await EventStore(path: store, maxAge: nil).replay().map(\.name) == ["recent.json"])

        // The old file is still spooled, but too old to come back.
        watcher.send(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.events.count == 2)
        await reader.stop()
        #expect(await backlog(of: root, store: store, maxAge: Self.threeDays).map(\.session.sessionID) == ["recent"])
    }

    /// The user raised the retention: what the spool still has within the new
    /// maximum age comes back with the next start, in the contract's order.
    @Test func aLongerMaximumAgeBringsOlderSpoolFilesBackAtTheNextStart() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        try spoolOldAndRecent(into: root)
        #expect(await backlog(of: root, store: store, maxAge: Self.threeDays).map(\.session.sessionID) == ["recent"])

        #expect(await backlog(of: root, store: store, maxAge: 10 * Self.threeDays).map(\.session.sessionID) == ["old", "recent"])
    }

    /// The app wasn't running when the rows aged: the start prunes before it replays.
    @Test func aStartDoesNotReplayRowsOlderThanTheMaximumAge() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        try spoolOldAndRecent(into: root)
        #expect(await backlog(of: root, store: store, maxAge: nil).count == 2)

        #expect(await backlog(of: root, store: store, maxAge: Self.threeDays).map(\.session.sessionID) == ["recent"])
        #expect(try await EventStore(path: store, maxAge: nil).replay().map(\.name) == ["recent.json"])
    }

    @Test func withoutAStoreRetentionAndPruningDoNothing() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try spoolOldAndRecent(into: root)
        let spooled = snapshot(root)
        let reader = storeReader(of: root, store: nil)
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }
        #expect(await eventually { await recorder.backlogFinished == [1] })

        await reader.setMaxAge(60)
        await reader.pruneStore(now: Date())
        #expect(await recorder.events.map(\.session.sessionID) == ["old", "recent"])
        #expect(snapshot(root) == spooled)
    }

    // MARK: Stopping

    /// A stopped reader neither reads nor stores anything more, so a new one can
    /// use the same store right after (e.g. when the user chose another folder).
    @Test func aStoppedReaderStoresAndYieldsNothingMore() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let watcher = ManualWatcher()
        let reader = storeReader(of: root, store: store, watcher: watcher)
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }
        #expect(await eventually { await recorder.backlogFinished == [0] })

        await reader.stop()
        let day = try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: root, name: "1").deletingLastPathComponent()
        watcher.send([day])
        try await Task.sleep(for: .milliseconds(100))

        #expect(await recorder.events.isEmpty)
        #expect(try await EventStore(path: store, maxAge: nil).replay().isEmpty)
    }

    /// Whether a reader started now on `root` has the store at `store`. Only
    /// then does it take a file written just before into the store: a reader
    /// that is kept out reads the spool alone and leaves the store as it is.
    private func aNewReaderGetsTheStore(_ store: URL, of root: URL) async throws -> Bool {
        let name = UUID().uuidString
        try writeEvent(envelopeJSON(payload: payload("Stop", session: name)), in: root, name: name)
        let events = await backlog(of: root, store: store)
        #expect(events.contains { $0.session.sessionID == name })
        return try await EventStore(path: store, maxAge: nil).replay().contains { $0.name == "\(name).json" }
    }

    /// E.g. the user chooses another folder while the app still starts: the
    /// reader stops wherever its start is, and the next one has the store.
    @Test(arguments: [FlakyStore.Step.prune, .ingest, .replay])
    fileprivate func aReaderStoppedDuringItsStartLetsGoOfTheStore(step: FlakyStore.Step) async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: root, name: "1")
        let held = Flag()
        let flaky = FlakyStore(try EventStore(path: store, maxAge: nil), before: { reached, call in
            guard reached == step, call == 1 else { return }
            held.raise()
            // The start stays in this step until `stop()` has cancelled it; the
            // bound only keeps a reader that is never stopped from holding a thread for good.
            let deadline = ContinuousClock.now + .seconds(30)
            while !Task.isCancelled, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.001) }
        })
        let reader = reader(of: root, store: store, flaky: flaky, watcher: ManualWatcher())
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }
        #expect(await eventually { held.isRaised })

        let stopped = Flag()
        let lock = URL(fileURLWithPath: store.path + ".lock")
        let open = Task {
            await reader.stop()
            // Asked right when `stop()` returns, not eventually: it returns with the lock released.
            let open = descriptors(on: lock)
            stopped.raise()
            return open
        }
        #expect(await eventually { stopped.isRaised }, "stop() must return")
        #expect(await open.value == 0)
        #expect(try await aNewReaderGetsTheStore(store, of: root))
    }

    /// The app stops a reader whose consumer may not have asked for its events
    /// yet. When it does, nothing starts, so the next reader has the store.
    @Test func aReaderStoppedBeforeItsEventsAreAskedForStartsNothing() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: root, name: "1")
        let openings = StoreOpenings()
        let environment = ["SUBSPACE_DIR": root.path]
        let reader = SpoolReader(adapters: [claudeCode(environment: environment)], environment: environment, watcher: ManualWatcher(),
                                 pollInterval: .milliseconds(20), store: SpoolReader.Store(path: store, maxAge: nil),
                                 openStore: openings.open)
        await reader.stop()

        let stream = await reader.events()
        let ended = Flag()
        let consumer = Task {
            var outputs = 0
            for await _ in stream { outputs += 1 }
            ended.raise()
            return outputs
        }
        #expect(await eventually { ended.isRaised }, "the stream must end at once")
        consumer.cancel()
        #expect(await consumer.value == 0)
        #expect(openings.onMainThread.isEmpty)
        #expect(descriptors(on: URL(fileURLWithPath: store.path + ".lock")) == 0)
        #expect(try await aNewReaderGetsTheStore(store, of: root))
    }

    // MARK: One reader per store

    /// Opening checks the whole file, and the app makes its reader and asks for
    /// its events on the main actor: neither may open the store there.
    @MainActor @Test func theStoreIsOpenedNeitherByInitNorOnTheMainThread() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: root, name: "1")
        let openings = StoreOpenings()
        let environment = ["SUBSPACE_DIR": root.path]
        let reader = SpoolReader(adapters: [claudeCode(environment: environment)], environment: environment, watcher: ManualWatcher(),
                                 pollInterval: .milliseconds(20),
                                 store: SpoolReader.Store(path: base.appendingPathComponent("store/events.sqlite"), maxAge: nil),
                                 openStore: openings.open)
        #expect(openings.onMainThread.isEmpty, "init must not open the store")

        var events: [AgentEvent] = []
        reading: for await output in await reader.events() {
            switch output {
            case .events(let batch), .replay(let batch, _): events += batch
            case .backlogFinished: break reading
            }
        }
        await reader.stop()
        #expect(events.count == 1)
        #expect(openings.onMainThread == [false])
    }

    /// However a reader ends, it closes the descriptor that held the lock: the
    /// app makes a new reader each time the user chooses another folder.
    @Test func noReaderLeavesADescriptorOfTheLockOpen() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        let lock = URL(fileURLWithPath: store.path + ".lock")
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: root, name: "1")
        let environment = ["SUBSPACE_DIR": root.path]
        let reader = { (openStore: @escaping @Sendable (URL, TimeInterval?) throws -> any SpoolStore) in
            SpoolReader(adapters: [claudeCode(environment: environment)], environment: environment, watcher: ManualWatcher(),
                        pollInterval: .milliseconds(20), store: SpoolReader.Store(path: store, maxAge: nil), openStore: openStore)
        }
        for _ in 1...3 {
            // Started and stopped.
            #expect(await backlog(of: root, store: store).count == 1)
            #expect(descriptors(on: lock) == 0)

            // Kept out by a reader that has the store; that one's descriptor is the only one.
            let holder = storeReader(of: root, store: store)
            let recorder = Recorder(await holder.events())
            #expect(await eventually { await recorder.backlogFinished == [1] })
            #expect(await holder.holdsStore)
            #expect(descriptors(on: lock) == 1)
            #expect(await backlog(of: root, store: store).count == 1)
            #expect(descriptors(on: lock) == 1)
            await holder.stop()
            #expect(descriptors(on: lock) == 0)

            // The store can't be opened.
            #expect(await backlog(of: reader { _, _ in throw FlakyStore.Failure() }).count == 1)
            #expect(descriptors(on: lock) == 0)

            // The store fails while the reader starts.
            #expect(await backlog(of: reader { FlakyStore(try EventStore(path: $0, maxAge: $1)) { step, _ in step == .replay } }).count == 1)
            #expect(descriptors(on: lock) == 0)
        }
    }

    /// E.g. a Debug build running next to the Release build, both on the app's
    /// one database: an ingest returns a file only to the reader that ran it,
    /// so the second reader leaves the store alone and reads the spool itself.
    @Test func twoReadersOnOneStoreBothGetEveryFileOnce() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: root, name: "1", mtime: t)
        try writeEvent(envelopeJSON(payload: payload("Stop")), in: root, name: "2", mtime: t.addingTimeInterval(1))
        let spooled = snapshot(root)
        var running: [(reader: SpoolReader, watcher: ManualWatcher, recorder: Recorder)] = []
        for _ in 1...2 {
            let watcher = ManualWatcher()
            let reader = storeReader(of: root, store: store, watcher: watcher)
            let recorder = Recorder(await reader.events())
            #expect(await eventually { await recorder.backlogFinished == [1] })
            running.append((reader, watcher, recorder))
        }

        let day = try writeEvent(envelopeJSON(payload: payload("Stop")), in: root, name: "3", mtime: t.addingTimeInterval(2))
            .deletingLastPathComponent()
        for (_, watcher, recorder) in running {
            watcher.send([day])
            _ = await recorder.waitFor(3)
            watcher.send(nil)
        }
        try await Task.sleep(for: .milliseconds(100))
        for (reader, _, recorder) in running {
            #expect(await recorder.batches.map(\.count) == [2, 1])
            #expect(await recorder.events.map(\.kind) == [.sessionStarted(cwd: nil, pid: 4242), .turnEnded(), .turnEnded()])
            #expect(await recorder.backlogFinished == [1])
            await reader.stop()
        }
        // The lock file lies next to the store, never in the root.
        #expect(FileManager.default.fileExists(atPath: store.path + ".lock"))
        #expect(snapshot(root)["events/2026-10-01/3.json"] != nil)
        #expect(snapshot(root).filter { $0.key != "events/2026-10-01/3.json" } == spooled)
    }

    /// What the app asks after the backlog: only the reader that has the store
    /// says so, neither one kept out by it nor one that has stopped.
    @Test func onlyTheRunningReaderThatHasTheStoreHoldsIt() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: root, name: "1")
        let first = storeReader(of: root, store: store)
        #expect(await !first.holdsStore, "nothing is opened before events()")
        let recorder = Recorder(await first.events())
        #expect(await eventually { await recorder.backlogFinished == [1] })
        #expect(await first.holdsStore)

        let second = storeReader(of: root, store: store)
        let keptOut = Recorder(await second.events())
        #expect(await eventually { await keptOut.backlogFinished == [1] })
        #expect(await !second.holdsStore)
        #expect(await first.holdsStore)
        await second.stop()

        await first.stop()
        #expect(await !first.holdsStore)
    }

    @Test func aReaderWithoutAStoreHoldsNone() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: root, name: "1")
        let reader = storeReader(of: root, store: nil)
        let recorder = Recorder(await reader.events())
        #expect(await eventually { await recorder.backlogFinished == [1] })
        #expect(await !reader.holdsStore)
        await reader.stop()
        #expect(await !reader.holdsStore)
    }

    /// The lock goes with the reading: once `stop()` has returned, the next
    /// reader on the path has the store, e.g. after the user chose another folder.
    @Test func aReaderStartedAfterAnotherStoppedUsesTheStoreAgain() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        try spoolOrphanStart(into: root)
        let first = storeReader(of: root, store: store)
        let recorder = Recorder(await first.events())
        #expect(await eventually { await recorder.backlogFinished == [1] })
        let events = await recorder.events
        #expect(!events.isEmpty)
        await first.stop()

        // Only the store still has the day.
        try FileManager.default.removeItem(at: root.appendingPathComponent("events/2026-10-05"))
        #expect(await backlog(of: root, store: store) == events)
    }

    /// A child process the app starts, e.g. a setup command, keeps a copy of
    /// every descriptor until its exec closes them, the lock of a reader that
    /// has just stopped too. The next reader waits for that instead of
    /// reading without the store until the app restarts.
    @Test func aLockLetGoOfShortlyAfterAReaderStartsStillGivesItTheStore() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        let lock = URL(fileURLWithPath: store.path + ".lock")
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: root, name: "1")
        let held = try SpoolReader.lock(store)
        let releasing = Flag()
        // A thread of its own, not a task: the reader may be blocking one of the pool's.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.05)
            // Raised before, so it is up once the reader can have the lock.
            releasing.raise()
            close(held)
        }

        let reader = storeReader(of: root, store: store)
        let recorder = Recorder(await reader.events())
        #expect(await eventually { await recorder.backlogFinished == [1] })
        #expect(releasing.isRaised, "the backlog came before the lock was let go of")
        #expect(await reader.holdsStore)
        #expect(descriptors(on: lock) == 1)
        await reader.stop()
        #expect(descriptors(on: lock) == 0)
    }

    /// A lock held for longer than a child's start, e.g. by a second copy of
    /// the app, still keeps a reader out: it reads the spool alone.
    @Test func aLockHeldPastTheGraceKeepsAReaderOut() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        let lock = URL(fileURLWithPath: store.path + ".lock")
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: root, name: "1")
        let held = try SpoolReader.lock(store)
        defer { close(held) }

        let reader = storeReader(of: root, store: store)
        let recorder = Recorder(await reader.events())
        #expect(await eventually { await recorder.backlogFinished == [1] })
        #expect(await recorder.events.count == 1)
        #expect(await !reader.holdsStore)
        #expect(descriptors(on: lock) == 1)
        await reader.stop()
        #expect(descriptors(on: lock) == 1)
    }

    /// The settings' button: what only the store still had is gone for good,
    /// what the spool has comes back with the next start, and the spool itself
    /// is not touched.
    @Test func clearingTheStoredEventsLeavesOnlyWhatTheSpoolStillHas() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        try writeEvent(envelopeJSON(payload: payload("SessionStart", session: "kept")), in: root, name: "1", mtime: t)
        let removed = try writeEvent(envelopeJSON(payload: payload("SessionStart", session: "gone")), in: root, name: "2",
                                     mtime: t.addingTimeInterval(1))
        #expect(await backlog(of: root, store: store).map(\.session.sessionID) == ["kept", "gone"])

        // Only the store still has the second event.
        try FileManager.default.removeItem(at: removed)
        #expect(await backlog(of: root, store: store).map(\.session.sessionID) == ["kept", "gone"])

        let spool = snapshot(root)
        try StoredEvents(store: store).clear()
        #expect(snapshot(root) == spool)
        #expect(!FileManager.default.fileExists(atPath: store.path))

        #expect(await backlog(of: root, store: store).map(\.session.sessionID) == ["kept"])
        #expect(try await EventStore(path: store, maxAge: nil).replay().map(\.name) == ["1.json"])
        #expect(snapshot(root) == spool)
    }

    // MARK: Without the store

    /// A reader on `root` whose store is `flaky`, the double of the one at `store`.
    private func reader(of root: URL, store: URL, flaky: FlakyStore, watcher: any DirectoryWatching) -> SpoolReader {
        let environment = ["SUBSPACE_DIR": root.path]
        return SpoolReader(adapters: [claudeCode(environment: environment)], environment: environment, watcher: watcher,
                           pollInterval: .milliseconds(20), store: SpoolReader.Store(path: store, maxAge: nil),
                           openStore: { _, _ in flaky })
    }

    /// Whatever the store fails at while the reader starts, the reader reads the
    /// spool itself instead, and goes on doing so.
    @Test(arguments: [FlakyStore.Step.prune, .ingest, .replay])
    fileprivate func aStoreFailingAtStartLeavesTheReaderOnTheSpool(step: FlakyStore.Step) async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        try spoolOrphanStart(into: root)
        let plain = await backlog(of: root, store: nil)
        #expect(!plain.isEmpty)

        let store = base.appendingPathComponent("store/events.sqlite")
        let flaky = FlakyStore(try EventStore(path: store, maxAge: nil)) { failed, _ in failed == step }
        let watcher = ManualWatcher()
        let reader = reader(of: root, store: store, flaky: flaky, watcher: watcher)
        let recorder = Recorder(await reader.events())
        defer { Task { await recorder.stop() } }
        #expect(await eventually { await recorder.backlogFinished == [1] })
        #expect(await recorder.events == plain)
        #expect(flaky.count(step) == 1)
        let ingests = flaky.count(.ingest)

        let day = try writeEvent(envelopeJSON(payload: payload("Stop", session: "new")), in: root, day: "2026-10-05", name: "z")
            .deletingLastPathComponent()
        watcher.send([day])
        let events = await recorder.waitFor(plain.count + 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.events == events)
        #expect(await recorder.batches.map(\.count) == [plain.count, 1])
        #expect(await recorder.backlogFinished == [1])
        #expect(flaky.count(.ingest) == ingests, "the store is left alone for the reader's whole lifetime")
    }

    @Test(arguments: ["file", "readOnly"])
    func aStoreThatCannotBeOpenedStillGivesEverySpoolEvent(blocker: String) async throws {
        let base = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.appendingPathComponent("store").path)
            try? FileManager.default.removeItem(at: base)
        }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let folder = base.appendingPathComponent("store", isDirectory: true)
        if blocker == "file" {
            try Data().write(to: folder)
        } else {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o555])
        }
        try spoolOrphanStart(into: root)
        let spooled = snapshot(root)

        let plain = await backlog(of: root, store: nil)
        #expect(!plain.isEmpty)
        #expect(await backlog(of: root, store: folder.appendingPathComponent("events.sqlite")) == plain)
        #expect(snapshot(root) == spooled)
        #expect(FileManager.default.subpaths(atPath: folder.path) ?? [] == [])
    }

    /// The spool is read-only (contract §4): a store inside a root, or in place of
    /// one, is not opened at all, so the reader works as without one.
    @Test(arguments: ["inside", "equal", "linkedInside"])
    func aStoreOverlappingTheRootIsNeverOpened(place: String) async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        try spoolOrphanStart(into: root)
        let store: URL
        switch place {
        case "inside":
            store = root.appendingPathComponent("store/events.sqlite")
        case "equal":
            store = root
        default:
            // Not created yet, reached through a link into the root.
            let link = base.appendingPathComponent("link", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
            store = link.appendingPathComponent("store/events.sqlite")
        }
        let spooled = snapshot(root)

        let plain = await backlog(of: root, store: nil)
        #expect(!plain.isEmpty)
        #expect(await backlog(of: root, store: store) == plain)
        #expect(snapshot(root) == spooled)
    }

    /// An ingest that fails while the reader runs costs no event: the store lists
    /// the day again with the next report of the root, whatever that one names.
    @Test func aFileMissedByAFailedIngestArrivesOnceWithTheNextReport() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("spool", isDirectory: true)
        let store = base.appendingPathComponent("store/events.sqlite")
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        try writeEvent(envelopeJSON(payload: payload("SessionStart")), in: root, name: "1", mtime: t)
        // The first ingest is the start's, the second the first report's.
        let flaky = FlakyStore(try EventStore(path: store, maxAge: nil)) { step, call in step == .ingest && call == 2 }
        let watcher = ManualWatcher()
        let reader = reader(of: root, store: store, flaky: flaky, watcher: watcher)
        let recorder = Recorder(await reader.events())
        #expect(await eventually { await recorder.backlogFinished == [1] })

        let missed = try writeEvent(envelopeJSON(payload: payload("Stop")), in: root, name: "2", mtime: t.addingTimeInterval(1))
            .deletingLastPathComponent()
        watcher.send([missed])
        #expect(await eventually { flaky.count(.ingest) == 2 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.events.count == 1)

        let next = try writeEvent(envelopeJSON(payload: payload("SessionStart", session: "s2")), in: root, day: "2026-10-02", name: "3",
                                  mtime: t.addingTimeInterval(2)).deletingLastPathComponent()
        watcher.send([next])
        _ = await recorder.waitFor(3)
        watcher.send(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.batches.map(\.count) == [1, 2])
        #expect(await recorder.events.map(\.kind) == [.sessionStarted(cwd: nil, pid: 4242), .turnEnded(), .sessionStarted(cwd: nil, pid: 4242)])
        await reader.stop()

        #expect(await backlog(of: root, store: store) == (await recorder.events))
    }
}
