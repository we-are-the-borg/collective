import Foundation
import GRDB
import Synchronization
import Testing
@testable import SubspaceKit

// MARK: - Helpers

/// A temporary database location and spool roots for one test; `remove()` in
/// the test's `defer` deletes all of it.
private struct Scratch {
    let directory: URL
    /// Inside a folder that does not exist yet: the store creates it.
    var database: URL { directory.appendingPathComponent("store/events.sqlite") }

    init() throws { directory = try temporaryDirectory() }

    func root(_ name: String = "root") -> URL { directory.appendingPathComponent(name, isDirectory: true) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private let claudeCode = MappingLoader.bundledDocument(named: "claude-code")
private let codex = MappingLoader.bundledDocument(named: "codex")
private let documents: [SourceID: MappingDocument?] = ["claude-code": claudeCode, "codex": codex]

private let stop = "claude-code/008-Stop.json"
private let postToolUse = "claude-code/009-PostToolUse.json"
private let codexStop = "codex/005-Stop.json"

/// `terminal` as for `envelopeJSON`: left out when nil.
private func event(_ fixture: String, source: String? = nil, terminal: [String: Any]? = nil) throws -> Data {
    envelopeJSON(source: source ?? String(fixture.prefix { $0 != "/" }), terminal: terminal, payload: try capturedPayload(fixture))
}

private let base = Date(timeIntervalSince1970: 1_790_000_000)

/// What a stored event must equal: the file read and mapped directly.
private func expectedEvent(_ file: URL, documents: [SourceID: MappingDocument?] = documents) -> (Envelope, StoredEvent.Content)? {
    switch SpoolFile.parsed(from: file, documents: documents) {
    case let .mapped(envelope, result):
        (Envelope(source: envelope.source, pid: envelope.pid, payload: Data(), receivedAt: envelope.receivedAt,
                  terminal: envelope.terminal), .mapped(result))
    case let .whole(envelope): (envelope, .whole(envelope.payload))
    case let .foreign(envelope): (envelope, .foreign(envelope.payload))
    case .failed: nil
    }
}

/// Reads files like the store does and records which ones it opened.
private final class FileReads: Sendable {
    private let opened = Mutex<[String]>([])
    var names: [String] { opened.withLock { $0 } }

    func read(_ url: URL) throws -> Data {
        opened.withLock { $0.append(url.lastPathComponent) }
        return try Data(contentsOf: url)
    }
}

private func openStore(at path: URL, maxAge: TimeInterval? = nil, counting reads: FileReads) throws -> EventStore {
    try EventStore(path: path, maxAge: maxAge, readFile: { try reads.read($0) })
}

private extension IngestResult {
    /// Nothing new and nothing re-mapped.
    var isEmpty: Bool { new.isEmpty && remapped.isEmpty }
}

/// The bundled Claude Code document's revision, and the one a newer plugin
/// would write. Derived, so updating the bundled copy needs no test change.
private let bundledRevision = claudeCode?.revision ?? 0
private let raisedRevision = bundledRevision + 1

/// The bundled Claude Code document with its revision raised textually, as a
/// newer plugin would write it: the same mapping, a higher revision.
private func claudeCodeWithRaisedRevision(to revision: Int64 = raisedRevision) throws -> MappingDocument {
    let url = try #require(MappingLoader.bundledURL(named: "claude-code"))
    let text = try String(contentsOf: url, encoding: .utf8)
    let raised = text.replacingOccurrences(of: #""revision": \#(bundledRevision)"#, with: #""revision": \#(revision)"#)
    #expect(raised != text)
    return try MappingDocument(data: Data(raised.utf8))
}

/// The bundled Codex document with `spawn_task` keeping the whole parsed
/// `tool_response` instead of its `task_name` string: a `parse: json` field
/// whose value lands in the result as parsed.
private func codexKeepingTheParsedSpawnResponse() throws -> MappingDocument {
    let url = try #require(MappingLoader.bundledURL(named: "codex"))
    let text = try String(contentsOf: url, encoding: .utf8)
    let kept = text.replacingOccurrences(of: #""pick": "/task_name",\#n      "type": "string","#, with: #""type": "any","#)
    #expect(kept != text)
    return try MappingDocument(data: Data(kept.utf8))
}

/// The bundled Claude Code document with a block field `payload` that copies
/// the whole payload (`path: ""`).
private func claudeCodeCopyingThePayload() throws -> MappingDocument {
    let url = try #require(MappingLoader.bundledURL(named: "claude-code"))
    let text = try String(contentsOf: url, encoding: .utf8)
    let copying = text.replacingOccurrences(of: #""fields": {"#, with: #""fields": { "payload": { "path": "", "type": "any" },"#)
    #expect(copying != text)
    return try MappingDocument(data: Data(copying.utf8))
}

/// The contents a store gives for the spool at `root`: the ingest's new
/// events, a replay, and a replay of the store opened again.
private func ingestedReplayedAndReopened(root: URL, database: URL,
                                         documents: [SourceID: MappingDocument?]) async throws -> [[StoredEvent.Content]] {
    let (ingested, replayed) = try await {
        let store = try EventStore(path: database, maxAge: nil)
        let ingested = try await store.ingest(root: root, changed: nil, documents: documents).new
        return (ingested, try await store.replay())
    }()
    let reopened = try await EventStore(path: database, maxAge: nil).replay()
    return [ingested, replayed, reopened].map { $0.map(\.content) }
}

/// A day folder as a watcher reports it.
private func dayFolder(_ root: URL, _ day: String = "2026-10-01") -> URL {
    root.appendingPathComponent("events/\(day)", isDirectory: true)
}

/// A spool path as FSEvents reports it: resolved, so it needn't start with
/// the root the app passes (`/private/var/…` for a temporary `/var/…`).
private func reported(_ root: URL, _ path: String, isDirectory: Bool = false) -> URL {
    URL(fileURLWithPath: root.resolvingSymlinksInPath().path, isDirectory: true)
        .appendingPathComponent(path, isDirectory: isDirectory)
}

/// An event file as FSEvents reports it, see `reported(_:_:isDirectory:)`.
private func reportedFile(_ root: URL, day: String = "2026-10-01", _ name: String) -> URL {
    reported(root, "events/\(day)/\(name)")
}

/// Reads files like the store does, except that it fails the named ones
/// with a read error until told otherwise.
private final class FailingReads: Sendable {
    let failing: Mutex<Set<String>>
    /// The names of the files it was asked to read, failed or not.
    let attempts = Mutex<[String]>([])

    init(failing: Set<String>) { self.failing = Mutex(failing) }

    func read(_ url: URL) throws -> Data {
        attempts.withLock { $0.append(url.lastPathComponent) }
        if failing.withLock({ $0.contains(url.lastPathComponent) }) { throw POSIXError(.EMFILE) }
        return try Data(contentsOf: url)
    }
}

/// Blocks whatever closure calls `hold()` until the test calls `release()`:
/// a hook of the store (`readFile` inside an ingest's transaction,
/// `onBusyWait` inside a checkpoint's busy handler) or a closure the test
/// passes to GRDB (`database.read`, `writeWithoutTransaction`). Those run on
/// a database queue or a dispatch worker, never on a cooperative thread, so
/// they may block; the test waits with `waitUntilEntered()`, which doesn't.
/// A hold never released fails the test instead of hanging, which the time
/// limit alone can't prevent while a thread is blocked.
private final class Hold: Sendable {
    private let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let released = DispatchSemaphore(value: 0)

    init() { (entered, enteredContinuation) = AsyncStream<Void>.makeStream() }

    func hold() {
        enteredContinuation.yield()
        if released.wait(timeout: .now() + .seconds(30)) == .timedOut { Issue.record("the held operation was never released") }
    }

    func waitUntilEntered() async { for await _ in entered { break } }
    func release() { released.signal() }
}

/// For a `readFile` hook: holds the first read of each named file with its
/// `Hold`; later reads of it, e.g. by the next ingest, pass.
private final class FirstReadHolds: Sendable {
    private let holds: Mutex<[String: Hold]>

    init(_ holds: [String: Hold]) { self.holds = Mutex(holds) }

    func pass(_ url: URL) { holds.withLock { $0.removeValue(forKey: url.lastPathComponent) }?.hold() }
}

/// Watches a store's busy handler through its `onBusyWait` hook, which runs on
/// the waiting writer's thread. `expect(holding:)` arms it for the handler's
/// next call, which `untilWaiting(orEndOf:)` waits for and which, given a
/// `Hold`, is held there: the writer stays inside the statement that waits.
/// Calls while it is not armed, e.g. of an earlier checkpoint, pass. Each
/// `expect` starts a wait of its own, so one instance serves several.
private final class BusyWaits: Sendable {
    private struct Expectation {
        let hold: Hold?
        let calls: AsyncStream<Void>
        let callsContinuation: AsyncStream<Void>.Continuation
        /// Cleared by the call it waits for; later calls pass.
        var armed = true
    }

    private let expectation = Mutex<Expectation?>(nil)

    func expect(holding hold: Hold? = nil) {
        let (calls, continuation) = AsyncStream<Void>.makeStream()
        expectation.withLock { $0 = Expectation(hold: hold, calls: calls, callsContinuation: continuation) }
    }

    /// The store's `onBusyWait`.
    func waited(_ tries: Int) {
        let armed: Expectation? = expectation.withLock {
            guard let current = $0, current.armed else { return nil }
            $0?.armed = false
            return current
        }
        guard let armed else { return }
        armed.callsContinuation.yield()
        armed.hold?.hold()
    }

    /// Whether the armed call came; false once `task`, the one expected to
    /// wait, ended without it.
    func untilWaiting<Success: Sendable>(orEndOf task: Task<Success, any Error>) async -> Bool {
        guard let current = expectation.withLock({ $0 }) else { return false }
        Task { [continuation = current.callsContinuation] in
            _ = await task.result
            continuation.finish()
        }
        for await _ in current.calls { return true }
        return false
    }
}

/// A store whose writer waits for locks under the eyes of `busy`.
private func openStore(at path: URL, maxAge: TimeInterval? = nil, watching busy: BusyWaits) throws -> EventStore {
    try EventStore(path: path, maxAge: maxAge, readFile: { try Data(contentsOf: $0) }, onBusyWait: busy.waited)
}

/// Runs the task code of an ingest (not its database work, which runs on the
/// store's writer) on a serial queue the test controls: `drained()` returns
/// once everything enqueued so far has run, and `pause()` keeps the task from
/// resuming until `resume()`. Pausing suspends the queue, blocking no thread.
private final class PausableExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "PausableExecutor")

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }

    func pause() { queue.suspend() }
    func resume() { queue.resume() }
    func drained() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
}

/// How many rows the store holds, of any kind.
private func rowCount(in store: EventStore) async throws -> Int {
    try await store.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM event") ?? 0 }
}

/// Overwrites `count` bytes of `file` from `offset` on, as a failing disk would.
private func damage(_ file: URL, at offset: Int, count: Int) throws {
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))
    try handle.write(contentsOf: Data(repeating: 0xA5, count: count))
}

/// A closed store holding `count` mapped events, checked to be intact, and
/// its page size and count.
private func intactStore(at path: URL, root: URL, count: Int) async throws -> (pageSize: Int, pageCount: Int) {
    let data = try event(postToolUse)
    for index in 0..<count { try writeEvent(data, in: root, name: "\(index)", mtime: base + Double(index)) }
    do {
        let store = try EventStore(path: path, maxAge: nil)
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.count == count)
    }
    // Closing the store checkpointed its WAL into the file (macOS keeps the
    // emptied WAL file), so damage to the file is damage to the store.
    let wal = try? FileManager.default.attributesOfItem(atPath: path.path + "-wal")[.size] as? Int
    #expect((wal ?? 0) == 0)
    return try await DatabaseQueue(path: path.path).read { db in
        #expect(try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok")
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM event") == count)
        return (try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0, try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0)
    }
}

/// An integer column of one file's row, for state the events don't show.
private func column(_ name: String, of file: URL, in store: EventStore) async throws -> Int64? {
    try await store.database.read { db in
        try Int64.fetchOne(db, sql: "SELECT \(name) FROM event WHERE name = ?", arguments: [file.lastPathComponent])
    }
}

/// A text column of one file's row, like `column(_:of:in:)`.
private func textColumn(_ name: String, of file: URL, in store: EventStore) async throws -> String? {
    try await store.database.read { db in
        try String.fetchOne(db, sql: "SELECT \(name) FROM event WHERE name = ?", arguments: [file.lastPathComponent])
    }
}

// MARK: - Tests

@Suite struct EventStoreTests {
    @Test func replayGivesWhatReadingTheFilesGivesInContractOrder() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let first = scratch.root("first"), second = scratch.root("second")
        // Across days and roots; `b` and `a` share an mtime, so the name decides.
        let late = try writeEvent(event(stop), in: first, day: "2026-10-02", name: "3-late", mtime: base + 30)
        let b = try writeEvent(event(postToolUse), in: first, day: "2026-10-01", name: "2-b", mtime: base + 20)
        let a = try writeEvent(event(codexStop), in: second, day: "2026-10-01", name: "2-a", mtime: base + 20)
        let early = try writeEvent(event(stop), in: second, day: "2026-10-02", name: "1-early", mtime: base + 10)

        let store = try EventStore(path: scratch.database, maxAge: nil)
        let fromFirst = try await store.ingest(root: first, changed: nil, documents: documents).new
        let fromSecond = try await store.ingest(root: second, changed: nil, documents: documents).new
        #expect(fromFirst.map(\.name) == ["2-b.json", "3-late.json"])
        #expect(fromSecond.map(\.name) == ["1-early.json", "2-a.json"])

        let replayed = try await store.replay()
        let order = [early, a, b, late]
        #expect(replayed.map(\.name) == order.map(\.lastPathComponent))
        #expect(replayed.map(\.day) == ["2026-10-02", "2026-10-01", "2026-10-01", "2026-10-02"])
        #expect(replayed.map(\.root.path) == [second, second, first, first].map(\.standardizedFileURL.path))
        for (stored, file) in zip(replayed, order) {
            let (envelope, content) = try #require(expectedEvent(file))
            #expect(stored.envelope == envelope)
            #expect(stored.content == content)
            guard case .mapped = stored.content else { Issue.record("expected .mapped"); continue }
        }
    }

    /// A payload nested as deep as the reader accepts, in `tool_input`, which
    /// the claude-code mapping copies whole: the stored result is as deep. The
    /// store serializes and reads it on its 512 KB worker threads, this test
    /// compares it on the cooperative pool's.
    @Test func theDeepestPayloadIsStoredAndReplayed() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let raw = try postToolUse(adding: #""deep":"# + nestedJSON(.mixed, depth: 509))
        let file = try writeEvent(envelopeJSON(rawPayload: raw), in: root, name: "1-deep")
        let (_, content) = try #require(expectedEvent(file))
        guard case let .mapped(result) = content, case let .object(toolInput)? = result.block["tool_input"] else {
            Issue.record("expected tool_input in the mapped result"); return
        }
        #expect(toolInput["deep"] != nil)

        let store = try EventStore(path: scratch.database, maxAge: nil)
        let ingested = try await store.ingest(root: root, changed: nil, documents: documents).new
        #expect(ingested.map(\.content) == [content])
        #expect(try await store.replay().map(\.content) == [content])
    }

    /// A `parse: json` field holding a value as deep as the reader accepts:
    /// the result is two levels deeper, beyond what a spool file may be, and
    /// still comes back from the store, also once it is opened again.
    @Test func aResultHoldingTheDeepestParsedValueIsReplayed() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let documents: [SourceID: MappingDocument?] = ["codex": try codexKeepingTheParsedSpawnResponse()]
        // The captured response, `{"task_name":"/root/alpha"}`, inside 511 levels.
        let captured = #""tool_response":"{\"task_name\":\"/root/alpha\"}""#
        let deep = nestedJSON(.mixed, depth: 511, around: #"{"task_name":"/root/alpha"}"#)
        let text = String(decoding: try capturedPayloadData("codex/008-PostToolUse.json"), as: UTF8.self)
        let raw = text.replacingOccurrences(of: captured, with: #""tool_response":""# + deep.replacingOccurrences(of: "\"", with: #"\""#) + "\"")
        #expect(raw != text)
        let file = try writeEvent(envelopeJSON(source: "codex", rawPayload: Data(raw.utf8)), in: root, name: "1-deep")
        let (_, content) = try #require(expectedEvent(file, documents: documents))
        guard case let .mapped(result) = content, case .array? = result.block["spawn_task"] else {
            Issue.record("expected the parsed response in the mapped result"); return
        }
        #expect(throws: JSONParseError.self) { try JSONValue(data: result.jsonValue.serialized()) }

        let contents = try await ingestedReplayedAndReopened(root: root, database: scratch.database, documents: documents)
        // Compared outside `#expect`, whose failure message would describe the
        // values recursively, too deep for the test's stack.
        #expect(contents.map(\.count) == [1, 1, 1])
        let same = contents.map { $0 == [content] }
        #expect(same == [true, true, true])
    }

    /// A block field copying the deepest payload a spool file may hold
    /// (`path: ""`): the result is one level deeper than the file, and still
    /// comes back from the store, also once it is opened again.
    @Test func aResultHoldingTheDeepestPayloadWholeIsReplayed() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let documents: [SourceID: MappingDocument?] = ["claude-code": try claudeCodeCopyingThePayload()]
        let raw = try postToolUse(adding: #""deep":"# + nestedJSON(.mixed, depth: 509))
        let file = try writeEvent(envelopeJSON(rawPayload: raw), in: root, name: "1-deep")
        let (_, content) = try #require(expectedEvent(file, documents: documents))
        guard case let .mapped(result) = content, result.block["payload"] == (try JSONValue(data: raw)) else {
            Issue.record("expected the whole payload in the mapped result"); return
        }
        #expect(throws: JSONParseError.self) { try JSONValue(data: result.jsonValue.serialized()) }

        let contents = try await ingestedReplayedAndReopened(root: root, database: scratch.database, documents: documents)
        // Compared outside `#expect`, whose failure message would describe the
        // values recursively, too deep for the test's stack.
        #expect(contents.map(\.count) == [1, 1, 1])
        let same = contents.map { $0 == [content] }
        #expect(same == [true, true, true])
    }

    @Test func aReopenedStoreReplaysTheSameEvents() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, name: "1-a", mtime: base + 1)
        try writeEvent(event(codexStop), in: root, name: "2-b", mtime: base + 2)
        try writeEvent(event(codexStop), in: root, name: "3-c", mtime: base + 3)
        let before = try await {
            let store = try EventStore(path: scratch.database, maxAge: nil)
            _ = try await store.ingest(root: root, changed: nil, documents: ["claude-code": claudeCode, "codex": nil])
            return try await store.replay()
        }()
        #expect(before.count == 3)

        let after = try await EventStore(path: scratch.database, maxAge: nil).replay()
        #expect(after == before)
    }

    /// A root given without a trailing slash: the events `ingest` returns
    /// carry the same root URL as the replayed ones, so they compare equal.
    @Test func ingestAndReplayGiveEqualRoots() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = URL(filePath: scratch.root().path, directoryHint: .notDirectory)
        try writeEvent(envelopeJSON(rawPayload: capturedPayloadData(stop)), in: root, name: "1-a")
        let store = try EventStore(path: scratch.database, maxAge: nil)
        let ingested = try await store.ingest(root: root, changed: nil, documents: documents).new
        #expect(ingested.count == 1)
        #expect(ingested == (try await store.replay()))
    }

    @Test func aRootWithAndWithoutATrailingSlashIsOneRoot() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let path = scratch.root().path
        try writeEvent(event(stop), in: scratch.root(), name: "1-a", mtime: base + 1)
        let store = try EventStore(path: scratch.database, maxAge: nil)

        let first = try await store.ingest(root: URL(filePath: path, directoryHint: .notDirectory), changed: nil,
                                           documents: documents).new
        #expect(first.map(\.name) == ["1-a.json"])
        #expect(try await store.ingest(root: URL(filePath: path + "/", directoryHint: .isDirectory), changed: nil,
                                       documents: documents).isEmpty)
        #expect(try await store.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM root") } == 1)
        #expect(try await store.replay() == first)
    }

    @Test func aSecondIngestOpensNoKnownFile() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, name: "1-a", mtime: base + 1)
        let reads = FileReads()
        let store = try openStore(at: scratch.database, counting: reads)
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.count == 1)
        #expect(reads.names == ["1-a.json"])

        // The same file again, e.g. after a restart, plus a new one.
        try writeEvent(event(codexStop), in: root, name: "2-b", mtime: base + 2)
        let stored = try await store.ingest(root: root, changed: nil, documents: documents).new
        #expect(stored.map(\.name) == ["2-b.json"])
        #expect(reads.names == ["1-a.json", "2-b.json"])

        // A reopened store knows them too.
        let reopened = try openStore(at: scratch.database, counting: reads)
        #expect(try await reopened.ingest(root: root, changed: nil, documents: documents).isEmpty)
        #expect(reads.names == ["1-a.json", "2-b.json"])
        #expect(try await reopened.replay().count == 2)
    }

    @Test func filesOlderThanTheMaxAgeAreNeitherOpenedNorStored() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let now = base + 3600
        try writeEvent(event(stop), in: root, name: "1-old", mtime: now - 120)
        try writeEvent(event(stop), in: root, name: "2-recent", mtime: now - 30)
        let reads = FileReads()
        let store = try openStore(at: scratch.database, maxAge: 60, counting: reads)

        let stored = try await store.ingest(root: root, changed: nil, documents: documents, now: now)
        #expect(stored.new.map(\.name) == ["2-recent.json"])
        #expect(reads.names == ["2-recent.json"])
        #expect(try await store.replay().map(\.name) == ["2-recent.json"])

        // Not remembered either: with the retention raised, the old file is
        // within it again and comes as new.
        store.maxAge = 180
        let all = try await store.ingest(root: root, changed: nil, documents: documents, now: now)
        #expect(all == IngestResult(new: all.new, remapped: []))
        #expect(all.new.map(\.name) == ["1-old.json"])
        #expect(try await store.replay().map(\.name) == ["1-old.json", "2-recent.json"])
    }

    @Test func excludedFieldsAreDroppedForTheirSourceOnly() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let claude = try writeEvent(event(postToolUse), in: root, name: "1-claude", mtime: base + 1)
        try writeEvent(event(postToolUse, source: "other"), in: root, name: "2-other", mtime: base + 2)
        // The same document mapping a second source, which excludes nothing.
        let documents: [SourceID: MappingDocument?] = ["claude-code": claudeCode, "other": claudeCode]
        let store = try EventStore(path: scratch.database, maxAge: nil)

        let stored = try await store.ingest(root: root, changed: nil, documents: documents,
                                            excluding: ["claude-code": ["tool_response"], "codex": ["tool_input"]]).new
        #expect(try await store.replay() == stored)
        guard case let .mapped(excluded) = stored.first?.content, case let .mapped(kept) = stored.last?.content else {
            Issue.record("expected two mapped events"); return
        }
        guard case let .mapped(full)? = expectedEvent(claude, documents: documents)?.1 else {
            Issue.record("expected .mapped"); return
        }
        // Both sit in the Claude Code block.
        #expect(full.block["tool_response"] != nil)
        #expect(excluded.block["tool_response"] == nil)
        #expect(excluded.block["tool_input"] != nil)
        var expected = full
        expected.core["tool_response"] = nil
        expected.block["tool_response"] = nil
        #expect(excluded == expected)
        #expect(kept == full)
    }

    @Test func wholeAndForeignEventsKeepTheirPayloadBytes() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(codexStop), in: root, name: "1-whole", mtime: base + 1)
        try writeEvent(event(stop, source: "elsewhere"), in: root, name: "2-foreign", mtime: base + 2)
        let documents: [SourceID: MappingDocument?] = ["codex": nil]
        let store = try EventStore(path: scratch.database, maxAge: nil)

        let stored = try await store.ingest(root: root, changed: nil, documents: documents).new
        // The ingest returns the payload bytes the parse produced; the replay
        // gives back exactly those bytes.
        let replayed = try await store.replay()
        #expect(replayed == stored)
        #expect(replayed.map(\.source) == ["codex", "elsewhere"])
        #expect(replayed.map(\.pid) == [4242, 4242])
        #expect(replayed.map(\.receivedAt) == [base, base])
        guard case let .whole(wholeBytes) = replayed.first?.content,
              case let .foreign(foreignBytes) = replayed.last?.content else {
            Issue.record("expected a whole and a foreign event"); return
        }
        #expect(replayed.map(\.envelope.payload) == [wholeBytes, foreignBytes])
        // `SpoolFile.envelope` re-serializes the payload, so the bytes may
        // differ from the file's in key order; the JSON is the captured one.
        #expect(try JSONValue(data: wholeBytes) == JSONValue(data: JSONSerialization.data(withJSONObject: capturedPayload(codexStop))))
        #expect(try JSONValue(data: foreignBytes) == JSONValue(data: JSONSerialization.data(withJSONObject: capturedPayload(stop))))
    }

    @Test func unreadableFilesAreKnownButNeitherReplayedNorReopened() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(Data("{\"v\":1,".utf8), in: root, name: "1-broken", mtime: base + 1)
        try writeEvent(envelopeJSON(v: 2, payload: capturedPayload(stop)), in: root, name: "2-v2", mtime: base + 2)
        try writeEvent(event(stop), in: root, name: "3-good", mtime: base + 3)
        let reads = FileReads()
        let store = try openStore(at: scratch.database, counting: reads)

        let stored = try await store.ingest(root: root, changed: nil, documents: documents).new
        #expect(stored.map(\.name) == ["3-good.json"])
        #expect(try await store.replay().map(\.name) == ["3-good.json"])
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).isEmpty)
        #expect(reads.names.sorted() == ["1-broken.json", "2-v2.json", "3-good.json"])
    }

    @Test func aFileThatCannotBeReadIsRetriedByTheNextIngest() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, name: "1-a", mtime: base + 1)
        try writeEvent(event(codexStop), in: root, name: "2-b", mtime: base + 2)
        let reads = FailingReads(failing: ["2-b.json"])
        let store = try EventStore(path: scratch.database, maxAge: nil, readFile: { try reads.read($0) })

        // E.g. too many open files: neither stored nor returned.
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.map(\.name) == ["1-a.json"])
        #expect(try await rowCount(in: store) == 1)

        // Nobody passes the file again: the store lists its day and finds it unknown.
        reads.failing.withLock { $0 = [] }
        #expect(try await store.ingest(root: root, changed: [dayFolder(root)], documents: documents).new.map(\.name) == ["2-b.json"])
        #expect(try await store.replay().map(\.name) == ["1-a.json", "2-b.json"])
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).isEmpty)
    }

    @Test func aFileThatCannotBeReadIsRetriedEvenIfItsDayIsNotReportedAgain() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let a = try writeEvent(event(stop), in: root, day: "2026-10-01", name: "1-a", mtime: base + 1)
        let b = try writeEvent(event(codexStop), in: root, day: "2026-10-02", name: "2-b", mtime: base + 2)
        let reads = FailingReads(failing: [b.lastPathComponent])
        let store = try EventStore(path: scratch.database, maxAge: nil, readFile: { try reads.read($0) })
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.map(\.name) == [a.lastPathComponent])

        // E.g. the session's last event: nothing changes in its day afterwards.
        reads.failing.withLock { $0 = [] }
        let c = try writeEvent(event(stop), in: root, day: "2026-10-01", name: "3-c", mtime: base + 3)
        let stored = try await store.ingest(root: root, changed: [dayFolder(root, "2026-10-01")], documents: documents).new
        #expect(stored.map(\.name) == [b.lastPathComponent, c.lastPathComponent])
        #expect(try await store.ingest(root: root, changed: [], documents: documents).isEmpty)
    }

    @Test func aFileThatStaysUnreadableIsLoggedAsAnErrorOnlyOnce() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let file = try writeEvent(event(stop), in: root, name: "1-a", mtime: base + 1)
        let reads = FailingReads(failing: [file.lastPathComponent])
        let store = try EventStore(path: scratch.database, maxAge: nil, readFile: { try reads.read($0) })
        // By name: the store logs the listed path, in which the temporary folder's symlink is resolved.
        func logged() -> [String] { store.loggedUnreadable.withLock { $0 }.map { URL(fileURLWithPath: $0).lastPathComponent } }

        // Each ingest retries the file; only the first failure is an error.
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).isEmpty)
        #expect(logged() == [file.lastPathComponent])
        #expect(try await store.ingest(root: root, changed: [], documents: documents).isEmpty)
        #expect(logged() == [file.lastPathComponent])

        // Once read, a later failure would be an error again.
        reads.failing.withLock { $0 = [] }
        #expect(try await store.ingest(root: root, changed: [], documents: documents).new.map(\.name) == ["1-a.json"])
        #expect(logged().isEmpty)
    }

    // MARK: Terminal

    /// The envelope's `terminal` is stored with the event: the ingest returns
    /// it, and so does a replay after the store was reopened.
    @Test func theCapturedTerminalIsStoredAndReplayed() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop, terminal: capturedTerminal()), in: root, name: "1-a", mtime: base + 1)
        try writeEvent(event(codexStop, terminal: capturedTerminal()), in: root, name: "2-b", mtime: base + 2)
        try writeEvent(event(stop, source: "elsewhere", terminal: capturedTerminal()), in: root, name: "3-c", mtime: base + 3)
        let ingested = try await {
            let store = try EventStore(path: scratch.database, maxAge: nil)
            return try await store.ingest(root: root, changed: nil, documents: ["claude-code": claudeCode, "codex": nil]).new
        }()
        #expect(ingested.map(\.terminal) == Array(repeating: capturedTerminalEntries, count: 3))
        #expect(ingested.map(\.envelope.terminal) == Array(repeating: capturedTerminalEntries, count: 3))

        let replayed = try await EventStore(path: scratch.database, maxAge: nil).replay()
        #expect(replayed == ingested)
        #expect(replayed.map(\.terminal) == Array(repeating: capturedTerminalEntries, count: 3))
    }

    /// Stored as a JSON object with keys in code point order; a file without
    /// `terminal`, or one that is no envelope, stores null.
    @Test func theTerminalColumnIsAnObjectWithSortedKeysOrNull() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let with = try writeEvent(event(stop, terminal: capturedTerminal()), in: root, name: "1-with", mtime: base + 1)
        let without = try writeEvent(event(stop), in: root, name: "2-without", mtime: base + 2)
        let broken = try writeEvent(Data("{\"v\":1,".utf8), in: root, name: "3-broken", mtime: base + 3)
        let store = try EventStore(path: scratch.database, maxAge: nil)
        _ = try await store.ingest(root: root, changed: nil, documents: documents)

        #expect(try await textColumn("terminal", of: with, in: store) == """
            {"TERM_PROGRAM":"WarpTerminal","TERM_PROGRAM_VERSION":"v0.2026.10.07.08.29.stable_00",\
            "WARP_FOCUS_URL":"warp://session/16e5a860f58d4186bd579a30d87d0d18",\
            "WARP_TERMINAL_SESSION_UUID":"16e5a860f58d4186bd579a30d87d0d18","__CFBundleIdentifier":"dev.warp.Warp-Stable"}
            """)
        #expect(try await textColumn("terminal", of: without, in: store) == nil)
        #expect(try await textColumn("kind", of: broken, in: store) == "failed")
        #expect(try await textColumn("terminal", of: broken, in: store) == nil)
        #expect(try await store.replay().map(\.terminal) == [capturedTerminalEntries, [:]])
    }

    /// A column the store wouldn't write costs the identifiers, not the event.
    @Test(arguments: ["WarpTerminal", #"["WarpTerminal"]"#, #"{"TERM_PROGRAM":"WarpTerminal","TERM_PROGRAM_VERSION":1}"#,
                      "null"])
    func anUndecodableTerminalColumnIsReplayedAsNone(column: String) async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let file = try writeEvent(event(stop, terminal: capturedTerminal()), in: root, name: "1-a", mtime: base + 1)
        let store = try EventStore(path: scratch.database, maxAge: nil)
        let stored = try #require(try await store.ingest(root: root, changed: nil, documents: documents).new.first)
        try await store.database.write { db in
            try db.execute(sql: "UPDATE event SET terminal = ?", arguments: [column])
        }

        let replayed = try await store.replay()
        #expect(replayed.map(\.terminal) == [[:]])
        #expect(replayed.first?.content == stored.content)
        #expect(replayed.first?.name == file.lastPathComponent)
    }

    /// Whole and foreign rows are mapped from their stored payload; the
    /// terminal comes from the row as well, not from the file, which is gone.
    @Test func wholeAndForeignRowsRemappedFromTheirPayloadKeepTheTerminal() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let whole = try writeEvent(event(codexStop, terminal: capturedTerminal()), in: root, name: "1-whole", mtime: base + 1)
        let foreign = try writeEvent(event(stop, source: "elsewhere", terminal: capturedTerminal()), in: root,
                                     name: "2-foreign", mtime: base + 2)
        let store = try EventStore(path: scratch.database, maxAge: nil)
        let first = try await store.ingest(root: root, changed: nil, documents: ["codex": nil])
        guard case .whole = first.new.first?.content, case .foreign = first.new.last?.content else {
            Issue.record("expected a whole and a foreign row"); return
        }
        try FileManager.default.removeItem(at: whole)
        try FileManager.default.removeItem(at: foreign)

        let result = try await store.ingest(root: root, changed: [], documents: ["codex": codex, "elsewhere": nil])
        #expect(result.remapped.map(\.name) == ["1-whole.json", "2-foreign.json"])
        guard case .mapped = result.remapped.first?.content, case .whole = result.remapped.last?.content else {
            Issue.record("expected a mapped and a whole row"); return
        }
        #expect(result.remapped.map(\.terminal) == [capturedTerminalEntries, capturedTerminalEntries])
        #expect(result.remapped.map(\.envelope.terminal) == [capturedTerminalEntries, capturedTerminalEntries])
        #expect(try await store.replay() == result.remapped)
    }

    /// A mapped row read again for a raised revision keeps its terminal.
    @Test func aRowRemappedByARaisedRevisionKeepsTheTerminal() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let file = try writeEvent(event(stop, terminal: capturedTerminal()), in: root, name: "1-a", mtime: base + 1)
        let store = try EventStore(path: scratch.database, maxAge: nil)
        _ = try await store.ingest(root: root, changed: nil, documents: documents)

        let raised: [SourceID: MappingDocument?] = ["claude-code": try claudeCodeWithRaisedRevision(), "codex": codex]
        let result = try await store.ingest(root: root, changed: [], documents: raised)
        #expect(result.remapped.map(\.name) == [file.lastPathComponent])
        let (envelope, content) = try #require(expectedEvent(file, documents: raised))
        #expect(result.remapped.first?.envelope == envelope)
        #expect(result.remapped.first?.content == content)
        #expect(result.remapped.first?.terminal == capturedTerminalEntries)
        #expect(try await column("revision", of: file, in: store) == raisedRevision)
        #expect(try await store.replay() == result.remapped)
    }

    /// A store written before the `terminal` column: opening it adds the
    /// column, the old row stays as it was, without identifiers (it is not
    /// read again), and new files are stored with theirs. A re-map that reads
    /// the old row's file again stores the file's identifiers.
    @Test func aStoreFromBeforeTheTerminalColumnKeepsItsRows() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let old = try writeEvent(event(stop, terminal: capturedTerminal()), in: root, name: "1-old", mtime: base + 1)
        guard case let .mapped(envelope, result) = SpoolFile.parsed(from: old, documents: documents) else {
            Issue.record("expected .mapped"); return
        }
        // The row as the v1 schema stored it.
        try FileManager.default.createDirectory(at: scratch.database.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let v1 = try DatabaseQueue(path: scratch.database.path)
        try EventStore.migrator.migrate(v1, upTo: "v1")
        try await v1.write { db in
            try db.execute(sql: "INSERT INTO root (id, path) VALUES (1, ?)", arguments: [root.standardizedFileURL.path])
            try db.execute(sql: """
                INSERT INTO event
                    (rootID, day, name, mtime, kind, source, pid, ts, blockName, revision, exclusions, format, result, payload)
                VALUES (1, '2026-10-01', ?, ?, 'mapped', ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                """, arguments: [old.lastPathComponent, SpoolScanner.mtimeNanoseconds(old), envelope.source.rawValue,
                                 envelope.pid, envelope.receivedAt.timeIntervalSince1970, result.blockName,
                                 claudeCode?.revision, EventStore.fingerprint([]), MappingInterpreter.supportedFormat,
                                 result.jsonValue.serialized()])
        }
        try v1.close()

        let reads = FileReads()
        let store = try openStore(at: scratch.database, counting: reads)
        let replayed = try await store.replay()
        #expect(replayed.map(\.name) == [old.lastPathComponent])
        #expect(replayed.first?.content == .mapped(result))
        #expect(replayed.first?.terminal == [:])

        let new = try writeEvent(event(codexStop, terminal: capturedTerminal()), in: root, name: "2-new", mtime: base + 2)
        let ingested = try await store.ingest(root: root, changed: nil, documents: documents)
        #expect(ingested.remapped.isEmpty)
        #expect(ingested.new.map(\.name) == [new.lastPathComponent])
        #expect(ingested.new.first?.terminal == capturedTerminalEntries)
        #expect(reads.names == [new.lastPathComponent])
        #expect(try await store.replay().map(\.terminal) == [[:], capturedTerminalEntries])

        // Read again from its file, the old row gets the file's identifiers.
        let raised: [SourceID: MappingDocument?] = ["claude-code": try claudeCodeWithRaisedRevision(), "codex": codex]
        let remapped = try await store.ingest(root: root, changed: [], documents: raised).remapped
        #expect(remapped.map(\.name) == [old.lastPathComponent])
        #expect(remapped.first?.terminal == capturedTerminalEntries)
        #expect(try await store.replay().map(\.terminal) == [capturedTerminalEntries, capturedTerminalEntries])
    }

    // MARK: Several instances

    /// Two instances on one file, as two processes would have: SQLite's write
    /// lock serializes their ingests, so each file is stored once and
    /// returned by exactly one of them, and neither fails with SQLITE_BUSY.
    @Test(.timeLimit(.minutes(1))) func twoInstancesIngestingOneRootConcurrentlyStoreEveryFileOnce() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let fixtures = [stop, postToolUse, codexStop]
        var keys: Set<String> = []
        for day in ["2026-10-01", "2026-10-02", "2026-10-03"] {
            for index in 0..<100 {
                let file = try writeEvent(event(fixtures[index % 3]), in: root, day: day, name: "\(index)",
                                          mtime: base + Double(index))
                keys.insert("\(day)/\(file.lastPathComponent)")
            }
        }
        let first = try EventStore(path: scratch.database, maxAge: nil)
        let second = try EventStore(path: scratch.database, maxAge: nil)

        async let fromFirst = first.ingest(root: root, changed: nil, documents: documents)
        async let fromSecond = second.ingest(root: root, changed: nil, documents: documents)
        let returned = try await (fromFirst.new + fromSecond.new).map { "\($0.day)/\($0.name)" }
        #expect(returned.count == keys.count)
        #expect(Set(returned) == keys)
        #expect(try await rowCount(in: first) == keys.count)
        #expect(try await first.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM root") } == 1)
        #expect(Set(try await second.replay().map { "\($0.day)/\($0.name)" }) == keys)
    }

    /// A prune of another instance waits for an ingest holding the write
    /// lock while it reads files, then runs on what the ingest stored.
    @Test(.timeLimit(.minutes(1))) func aPruneOfAnotherInstanceWaitsForAnIngestInItsTransaction() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let a = try writeEvent(event(stop), in: root, name: "1-a", mtime: base + 1)
        let hold = Hold()
        let ingesting = try EventStore(path: scratch.database, maxAge: nil, readFile: { url in
            hold.hold()
            return try Data(contentsOf: url)
        })
        // Opened before the ingest takes the lock: opening migrates, which writes.
        let busy = BusyWaits()
        let pruning = try openStore(at: scratch.database, maxAge: 60, watching: busy)

        let ingest = Task { try await ingesting.ingest(root: root, changed: nil, documents: documents) }
        await hold.waitUntilEntered()
        busy.expect()
        let prune = Task { try await pruning.prune(now: base + 3600) }
        // Released once the prune waits for the lock.
        #expect(await busy.untilWaiting(orEndOf: prune))
        hold.release()

        #expect(try await ingest.value.new.map(\.name) == [a.lastPathComponent])
        // It came second: it found the ingested row.
        #expect(try await prune.value == 1)
        #expect(try await ingesting.replay().isEmpty)
    }

    @Test func onlyTheReportedDaysAreListedUnlessTheChangeIsElsewhere() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let reads = FileReads()
        let store = try openStore(at: scratch.database, counting: reads)
        // An empty spool: the store now knows its mapping state, so the next
        // ingests list only what they are told.
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).isEmpty)

        try writeEvent(event(stop), in: root, day: "2026-10-01", name: "1-a", mtime: base + 1)
        try writeEvent(event(codexStop), in: root, day: "2026-10-02", name: "2-b", mtime: base + 2)
        let first = try await store.ingest(root: root, changed: [dayFolder(root, "2026-10-01")], documents: documents).new
        #expect(first.map(\.name) == ["1-a.json"])
        #expect(reads.names == ["1-a.json"])
        #expect(try await store.ingest(root: root, changed: [], documents: documents).isEmpty)

        // `events/` itself (a new day folder) is not a day: everything is listed.
        let second = try await store.ingest(root: root, changed: [root.appendingPathComponent("events", isDirectory: true)],
                                            documents: documents).new
        #expect(second.map(\.name) == ["2-b.json"])

        // A watcher that lost track reports nil.
        try writeEvent(event(stop), in: root, day: "2026-10-01", name: "3-c", mtime: base + 3)
        try writeEvent(event(stop), in: root, day: "2026-10-03", name: "4-d", mtime: base + 4)
        let third = try await store.ingest(root: root, changed: nil, documents: documents).new
        #expect(third.map(\.name) == ["3-c.json", "4-d.json"])
        #expect(reads.names.sorted() == ["1-a.json", "2-b.json", "3-c.json", "4-d.json"])
    }

    @Test func theFirstIngestOfARootListsEveryDayEvenWithoutDocuments() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, day: "2026-10-01", name: "1-a", mtime: base + 1)
        try writeEvent(event(codexStop), in: root, day: "2026-10-02", name: "2-b", mtime: base + 2)
        let store = try EventStore(path: scratch.database, maxAge: nil)

        let first = try await store.ingest(root: root, changed: [dayFolder(root, "2026-10-01")], documents: [:]).new
        #expect(first.map(\.name) == ["1-a.json", "2-b.json"])

        // Ingested once, even with no sources: from now on only reported days.
        try writeEvent(event(stop), in: root, day: "2026-10-02", name: "3-c", mtime: base + 3)
        #expect(try await store.ingest(root: root, changed: [dayFolder(root, "2026-10-01")], documents: [:]).isEmpty)
    }

    /// A trigger stands in for a failing write (e.g. a full disk): it aborts
    /// the insert of the second file, after the first one went in.
    @Test func aFailedTransactionStoresNothingAndTheNextIngestRetries() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, name: "1-a", mtime: base + 1)
        try writeEvent(event(codexStop), in: root, name: "2-b", mtime: base + 2)
        let store = try EventStore(path: scratch.database, maxAge: nil)
        try await store.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail BEFORE INSERT ON event WHEN NEW.name = '2-b.json'
                BEGIN SELECT RAISE(ABORT, 'disk full'); END
                """)
        }

        await #expect(throws: DatabaseError.self) {
            try await store.ingest(root: root, changed: nil, documents: documents)
        }
        #expect(try await store.replay().isEmpty)

        try await store.database.write { db in try db.execute(sql: "DROP TRIGGER fail") }
        let stored = try await store.ingest(root: root, changed: nil, documents: documents).new
        #expect(stored.map(\.name) == ["1-a.json", "2-b.json"])
        #expect(try await store.replay() == stored)
    }

    /// The failed ingest listed a day nobody reports again: the next ingest
    /// retries it all the same, as for a file that could not be read.
    @Test func aFailedTransactionIsRetriedEvenIfItsDayIsNotReportedAgain() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, name: "1-a", mtime: base + 1)
        let store = try EventStore(path: scratch.database, maxAge: nil)
        // Records the root's mapping state, so the ingests below list reported days only.
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.map(\.name) == ["1-a.json"])

        try writeEvent(event(codexStop), in: root, name: "2-b", mtime: base + 2)
        try await store.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail BEFORE INSERT ON event WHEN NEW.name = '2-b.json'
                BEGIN SELECT RAISE(ABORT, 'disk full'); END
                """)
        }
        await #expect(throws: DatabaseError.self) {
            try await store.ingest(root: root, changed: [dayFolder(root)], documents: documents)
        }

        try await store.database.write { db in try db.execute(sql: "DROP TRIGGER fail") }
        #expect(try await store.ingest(root: root, changed: [], documents: documents).new.map(\.name) == ["2-b.json"])
        #expect(try await store.replay().map(\.name) == ["1-a.json", "2-b.json"])
    }

    /// The ingest fails while it reads the root's mapping state, before it
    /// decides what to list (a hidden table stands in for a failing read): the
    /// reported day is listed by the next ingest all the same.
    @Test func aFailedDecisionLeavesTheReportedDaysToTheNextIngest() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, day: "2026-10-01", name: "1-a", mtime: base + 1)
        let store = try EventStore(path: scratch.database, maxAge: nil)
        // Records the root's mapping state, so the ingests below list reported days only.
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.map(\.name) == ["1-a.json"])

        try writeEvent(event(codexStop), in: root, day: "2026-10-02", name: "2-b", mtime: base + 2)
        try await store.database.write { try $0.execute(sql: "ALTER TABLE source_state RENAME TO hidden") }
        await #expect(throws: DatabaseError.self) {
            try await store.ingest(root: root, changed: [dayFolder(root, "2026-10-02")], documents: documents)
        }

        try await store.database.write { try $0.execute(sql: "ALTER TABLE hidden RENAME TO source_state") }
        #expect(try await store.ingest(root: root, changed: [], documents: documents).new.map(\.name) == ["2-b.json"])
        #expect(try await store.ingest(root: root, changed: [], documents: documents).isEmpty)
    }

    /// An ingest cancelled before it touched the database: what it was told
    /// to list, a day or everything, is listed by the next ingest.
    @Test func aCancelledIngestLeavesItsDaysToTheNextIngest() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, day: "2026-10-01", name: "1-a", mtime: base + 1)
        let store = try EventStore(path: scratch.database, maxAge: nil)
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.map(\.name) == ["1-a.json"])

        func cancelledIngest(changed: Set<URL>?) async {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await store.ingest(root: root, changed: changed, documents: documents)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
        }

        try writeEvent(event(codexStop), in: root, day: "2026-10-02", name: "2-b", mtime: base + 2)
        await cancelledIngest(changed: [dayFolder(root, "2026-10-02")])
        #expect(try await store.ingest(root: root, changed: [], documents: documents).new.map(\.name) == ["2-b.json"])

        // `events/` itself: every day, the new one included.
        try writeEvent(event(stop), in: root, day: "2026-10-01", name: "3-c", mtime: base + 3)
        try writeEvent(event(stop), in: root, day: "2026-10-03", name: "4-d", mtime: base + 4)
        await cancelledIngest(changed: [root.appendingPathComponent("events", isDirectory: true)])
        #expect(try await store.ingest(root: root, changed: [], documents: documents).new.map(\.name) == ["3-c.json", "4-d.json"])
        #expect(try await store.ingest(root: root, changed: [], documents: documents).isEmpty)
    }

    /// An ingest's reported day is pending from its call on, not from its
    /// failure: an ingest queued behind a failed one lists the day too, rather
    /// than leaving it to the one after, even when it decides before the
    /// failed one's task resumes (held back on a paused executor here).
    @Test(.timeLimit(.minutes(1))) func anIngestQueuedBehindAFailedOneListsItsReportedDay() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, day: "2026-10-01", name: "1-a", mtime: base + 1)
        let failing = Hold(), queued = Hold()
        let holds = FirstReadHolds(["2-b.json": failing, "3-c.json": queued])
        let store = try EventStore(path: scratch.database, maxAge: nil, readFile: { url in
            holds.pass(url)
            return try Data(contentsOf: url)
        })
        // Records the root's mapping state, so the ingests below list reported days only.
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.map(\.name) == ["1-a.json"])

        try writeEvent(event(codexStop), in: root, day: "2026-10-01", name: "2-b", mtime: base + 2)
        try writeEvent(event(stop), in: root, day: "2026-10-02", name: "3-c", mtime: base + 3)
        let executor = PausableExecutor()
        let failed = Task(executorPreference: executor) {
            try await store.ingest(root: root, changed: [dayFolder(root, "2026-10-01")], documents: documents)
        }
        await failing.waitUntilEntered()
        executor.pause()
        // Cancelled in its transaction, its insert throws and it rolls back,
        // as on a full disk.
        failed.cancel()
        failing.release()
        let next = Task { try await store.ingest(root: root, changed: [dayFolder(root, "2026-10-02")], documents: documents) }
        await queued.waitUntilEntered()
        queued.release()
        #expect(try await next.value.new.map(\.name) == ["2-b.json", "3-c.json"])
        executor.resume()
        await #expect(throws: CancellationError.self) { try await failed.value }
        #expect(try await store.ingest(root: root, changed: [], documents: documents).isEmpty)
    }

    /// A day reported while another ingest is in its transaction may hold a
    /// file that ingest listed too early to see. Its success leaves the day
    /// pending, even one it was listing for an earlier report, so the next
    /// ingest lists it when the reporting one doesn't get to. It guards that
    /// `settle` goes by the numbers of the additions (it fails if it ignores
    /// them), not a regression: the code before the numbering passes too,
    /// since GRDB fails a cancelled write only at its turn on the writer,
    /// after the other ingest's success.
    @Test(.timeLimit(.minutes(1))) func aDayReportedDuringAnotherIngestStaysPendingAfterItsSuccess() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, day: "2026-10-01", name: "1-a", mtime: base + 1)
        let reads = FailingReads(failing: ["1-a.json"])
        let hold = Hold()
        let holds = FirstReadHolds(["2-b.json": hold])
        let store = try EventStore(path: scratch.database, maxAge: nil, readFile: { url in
            holds.pass(url)
            return try reads.read(url)
        })
        // Leaves the day pending, for its unreadable file.
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).isEmpty)
        reads.failing.withLock { $0 = [] }

        try writeEvent(event(codexStop), in: root, day: "2026-10-02", name: "2-b", mtime: base + 2)
        let listing = Task { try await store.ingest(root: root, changed: nil, documents: documents) }
        await hold.waitUntilEntered()
        // Listed already: the ingest in its transaction doesn't see it.
        try writeEvent(event(stop), in: root, day: "2026-10-01", name: "3-c", mtime: base + 3)
        let executor = PausableExecutor()
        let reporting = Task(executorPreference: executor) {
            try await store.ingest(root: root, changed: [dayFolder(root, "2026-10-01")], documents: documents)
        }
        // Its task ran up to its turn on the writer: the day is reported.
        await executor.drained()
        // Fails at its turn, after the listing ingest.
        reporting.cancel()
        hold.release()
        #expect(try await listing.value.new.map(\.name) == ["1-a.json", "2-b.json"])
        await #expect(throws: CancellationError.self) { try await reporting.value }

        #expect(try await store.ingest(root: root, changed: [], documents: documents).new.map(\.name) == ["3-c.json"])
        #expect(try await store.ingest(root: root, changed: [], documents: documents).isEmpty)
    }

    // MARK: Reported files

    /// A watcher that reports files: each is looked up alone, and its day is
    /// not listed, so a file nobody reported waits for its day's listing.
    @Test func reportedFilesAreLookedAtAloneWithoutListingTheirDay() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, name: "1-a", mtime: base + 1)
        let reads = FileReads()
        let store = try openStore(at: scratch.database, counting: reads)
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.map(\.name) == ["1-a.json"])

        try writeEvent(event(codexStop), in: root, name: "2-b", mtime: base + 2)
        try writeEvent(event(stop), in: root, name: "3-c", mtime: base + 3)
        let day = dayFolder(root)
        try Data().write(to: day.appendingPathComponent(".4-d.tmp"))
        try Data().write(to: day.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: day.appendingPathComponent("5-nested.json"), withIntermediateDirectories: true)
        // Known, unknown, being written, not an event, a directory, and gone
        // (e.g. a day folder the plugin deleted).
        let names = ["1-a.json", "2-b.json", ".4-d.tmp", "notes.txt", "5-nested.json", "6-gone.json"]
        let changed = Set(names.map { reportedFile(root, $0) })
        #expect(try await store.ingest(root: root, changed: changed, documents: documents).new.map(\.name) == ["2-b.json"])
        #expect(reads.names == ["1-a.json", "2-b.json"])
        // Neither the gone file nor the directory is an error, or left to retry.
        #expect(store.loggedUnreadable.withLock { $0 }.isEmpty)
        #expect(try await store.ingest(root: root, changed: [], documents: documents).isEmpty)
        #expect(reads.names == ["1-a.json", "2-b.json"])

        #expect(try await store.ingest(root: root, changed: [day], documents: documents).new.map(\.name) == ["3-c.json"])
    }

    /// The plugin rewrites `schema/` and `model/` on every SessionStart; they
    /// hold no events, so a change there lists nothing. The root itself is
    /// anything else: every day.
    @Test func changesToSchemaAndModelListNothing() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, day: "2026-10-01", name: "1-a", mtime: base + 1)
        let reads = FileReads()
        let store = try openStore(at: scratch.database, counting: reads)
        let model = reported(root, "model/claude-code.json")
        // The first ingest of a root lists every day all the same.
        #expect(try await store.ingest(root: root, changed: [model], documents: documents).new.map(\.name) == ["1-a.json"])

        try writeEvent(event(codexStop), in: root, day: "2026-10-02", name: "2-b", mtime: base + 2)
        let changed: Set<URL> = [reported(root, "schema", isDirectory: true), reported(root, "schema/envelope.v1.json"),
                                 reported(root, "model", isDirectory: true), model]
        #expect(try await store.ingest(root: root, changed: changed, documents: documents).isEmpty)
        #expect(try await store.ingest(root: root, changed: [], documents: documents).isEmpty)
        #expect(reads.names == ["1-a.json"])

        let rootItself = URL(fileURLWithPath: root.resolvingSymlinksInPath().path, isDirectory: true)
        #expect(try await store.ingest(root: root, changed: [rootItself], documents: documents).new.map(\.name) == ["2-b.json"])
    }

    /// The plugin rewrites `plugin.json` in the root on every SessionStart; a
    /// file-level watcher reports it and its temporary file, which hold no
    /// events. The root and `events/` as directories still list every day.
    @Test func filesOutsideADayFolderListNothingButDirectoriesListEveryDay() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, day: "2026-10-01", name: "1-a", mtime: base + 1)
        let reads = FileReads()
        let store = try openStore(at: scratch.database, counting: reads)
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.map(\.name) == ["1-a.json"])

        try writeEvent(event(codexStop), in: root, day: "2026-10-02", name: "2-b", mtime: base + 2)
        let changed: Set<URL> = [reported(root, "plugin.json"), reported(root, ".plugin.json.tmp")]
        #expect(try await store.ingest(root: root, changed: changed, documents: documents).isEmpty)
        #expect(try await store.ingest(root: root, changed: [], documents: documents).isEmpty)
        #expect(reads.names == ["1-a.json"])

        let rootItself = URL(fileURLWithPath: root.resolvingSymlinksInPath().path, isDirectory: true)
        #expect(try await store.ingest(root: root, changed: [rootItself], documents: documents).new.map(\.name) == ["2-b.json"])
        try writeEvent(event(stop), in: root, day: "2026-10-01", name: "3-c", mtime: base + 3)
        let events = reported(root, "events", isDirectory: true)
        #expect(try await store.ingest(root: root, changed: [events], documents: documents).new.map(\.name) == ["3-c.json"])
    }

    /// As for a day: the file a failed ingest was told about is looked at by
    /// the next ingest, and alone, without listing its day.
    @Test func aFailedTransactionIsRetriedEvenIfItsFileIsNotReportedAgain() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, name: "1-a", mtime: base + 1)
        let reads = FileReads()
        let store = try openStore(at: scratch.database, counting: reads)
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.map(\.name) == ["1-a.json"])

        try writeEvent(event(codexStop), in: root, name: "2-b", mtime: base + 2)
        try writeEvent(event(stop), in: root, name: "3-c", mtime: base + 3)
        try await store.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail BEFORE INSERT ON event WHEN NEW.name = '2-b.json'
                BEGIN SELECT RAISE(ABORT, 'disk full'); END
                """)
        }
        await #expect(throws: DatabaseError.self) {
            try await store.ingest(root: root, changed: [reportedFile(root, "2-b.json")], documents: documents)
        }

        try await store.database.write { db in try db.execute(sql: "DROP TRIGGER fail") }
        #expect(try await store.ingest(root: root, changed: [], documents: documents).new.map(\.name) == ["2-b.json"])
        #expect(try await store.ingest(root: root, changed: [], documents: documents).isEmpty)
        #expect(reads.names == ["1-a.json", "2-b.json", "2-b.json"])
    }

    @Test func aCancelledIngestLeavesItsFilesToTheNextIngest() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, name: "1-a", mtime: base + 1)
        let reads = FileReads()
        let store = try openStore(at: scratch.database, counting: reads)
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.map(\.name) == ["1-a.json"])

        try writeEvent(event(codexStop), in: root, name: "2-b", mtime: base + 2)
        try writeEvent(event(stop), in: root, name: "3-c", mtime: base + 3)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.ingest(root: root, changed: [reportedFile(root, "2-b.json")], documents: documents)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.ingest(root: root, changed: [], documents: documents).new.map(\.name) == ["2-b.json"])
        #expect(try await store.ingest(root: root, changed: [], documents: documents).isEmpty)
        #expect(reads.names == ["1-a.json", "2-b.json"])
    }

    /// As `anIngestQueuedBehindAFailedOneListsItsReportedDay`, with files.
    @Test(.timeLimit(.minutes(1))) func anIngestQueuedBehindAFailedOneLooksAtItsReportedFile() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, day: "2026-10-01", name: "1-a", mtime: base + 1)
        let failing = Hold(), queued = Hold()
        let holds = FirstReadHolds(["2-b.json": failing, "3-c.json": queued])
        let reads = FileReads()
        let store = try EventStore(path: scratch.database, maxAge: nil, readFile: { url in
            holds.pass(url)
            return try reads.read(url)
        })
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.map(\.name) == ["1-a.json"])

        try writeEvent(event(codexStop), in: root, day: "2026-10-01", name: "2-b", mtime: base + 2)
        try writeEvent(event(stop), in: root, day: "2026-10-02", name: "3-c", mtime: base + 3)
        try writeEvent(event(stop), in: root, day: "2026-10-01", name: "4-d", mtime: base + 4)
        let executor = PausableExecutor()
        let failed = Task(executorPreference: executor) {
            try await store.ingest(root: root, changed: [reportedFile(root, "2-b.json")], documents: documents)
        }
        await failing.waitUntilEntered()
        executor.pause()
        failed.cancel()
        failing.release()
        let next = Task {
            try await store.ingest(root: root, changed: [reportedFile(root, day: "2026-10-02", "3-c.json")], documents: documents)
        }
        await queued.waitUntilEntered()
        queued.release()
        #expect(try await next.value.new.map(\.name) == ["2-b.json", "3-c.json"])
        executor.resume()
        await #expect(throws: CancellationError.self) { try await failed.value }
        #expect(try await store.ingest(root: root, changed: [], documents: documents).isEmpty)
        #expect(!reads.names.contains("4-d.json"))
    }

    /// A file reported while another ingest is in its transaction is left
    /// pending by that ingest's success, as a day is, even one that ingest
    /// was told about itself but found missing (a name reported early). It
    /// guards that `settle` goes by the numbers of the file additions too; like
    /// `aDayReportedDuringAnotherIngestStaysPendingAfterItsSuccess`, the code
    /// before file reports passes as well, since it listed every day for them.
    @Test(.timeLimit(.minutes(1))) func aFileReportedDuringAnotherIngestStaysPendingAfterItsSuccess() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, name: "1-a", mtime: base + 1)
        let hold = Hold()
        let holds = FirstReadHolds(["2-b.json": hold])
        let store = try EventStore(path: scratch.database, maxAge: nil, readFile: { url in
            holds.pass(url)
            return try Data(contentsOf: url)
        })
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.map(\.name) == ["1-a.json"])

        try writeEvent(event(codexStop), in: root, name: "2-b", mtime: base + 2)
        let looking = Task {
            try await store.ingest(root: root, changed: [reportedFile(root, "2-b.json"), reportedFile(root, "3-c.json")],
                                   documents: documents)
        }
        await hold.waitUntilEntered()
        // Looked at already: the ingest in its transaction found it missing.
        try writeEvent(event(stop), in: root, name: "3-c", mtime: base + 3)
        let executor = PausableExecutor()
        let reporting = Task(executorPreference: executor) {
            try await store.ingest(root: root, changed: [reportedFile(root, "3-c.json")], documents: documents)
        }
        // Its task ran up to its turn on the writer: the file is reported.
        await executor.drained()
        // Fails at its turn, after the other ingest.
        reporting.cancel()
        hold.release()
        #expect(try await looking.value.new.map(\.name) == ["2-b.json"])
        await #expect(throws: CancellationError.self) { try await reporting.value }

        #expect(try await store.ingest(root: root, changed: [], documents: documents).new.map(\.name) == ["3-c.json"])
        #expect(try await store.ingest(root: root, changed: [], documents: documents).isEmpty)
    }

    /// The file stays pending, not its day: retrying it costs no listing.
    @Test func aReportedFileThatCannotBeReadIsRetriedWithoutListingItsDay() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, name: "1-a", mtime: base + 1)
        let reads = FailingReads(failing: ["2-b.json"])
        let store = try EventStore(path: scratch.database, maxAge: nil, readFile: { try reads.read($0) })
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.map(\.name) == ["1-a.json"])

        try writeEvent(event(codexStop), in: root, name: "2-b", mtime: base + 2)
        #expect(try await store.ingest(root: root, changed: [reportedFile(root, "2-b.json")], documents: documents).isEmpty)
        reads.failing.withLock { $0 = [] }
        try writeEvent(event(stop), in: root, name: "3-c", mtime: base + 3)
        #expect(try await store.ingest(root: root, changed: [], documents: documents).new.map(\.name) == ["2-b.json"])
        #expect(try await store.ingest(root: root, changed: [], documents: documents).isEmpty)
        #expect(reads.attempts.withLock { $0 } == ["1-a.json", "2-b.json", "2-b.json"])
    }

    /// A busy day holds thousands of files, and a watcher batch names the
    /// new ones: an ingest of a reported file must not cost the day's size
    /// (listing the day and loading its names took ~78 ms here).
    @Test(.timeLimit(.minutes(1))) func anIngestOfReportedFilesDoesNotGrowWithTheirDay() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let data = try event(stop)
        // In parallel: one by one, writing them took about three seconds.
        let failed = Mutex(false)
        DispatchQueue.concurrentPerform(iterations: 10_000) { index in
            do { try writeEvent(data, in: root, name: "0-\(index)") } catch { failed.withLock { $0 = true } }
        }
        #expect(!failed.withLock { $0 })
        let store = try EventStore(path: scratch.database, maxAge: nil)
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.count == 10_000)

        let clock = ContinuousClock()
        var elapsed = Duration.zero
        let ingests = 20
        for index in 0..<ingests {
            let file = try writeEvent(data, in: root, name: "1-\(index)")
            let start = clock.now
            let new = try await store.ingest(root: root, changed: [file], documents: documents).new
            elapsed += clock.now - start
            #expect(new.map(\.name) == [file.lastPathComponent])
        }
        let average = elapsed / ingests
        #expect(average < .milliseconds(10), "\(average) per ingest")
    }

    // MARK: Prune

    @Test func pruneDeletesRowsOlderThanTheMaxAgeAndTheirEmptyRoots() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let first = scratch.root("first"), second = scratch.root("second")
        let now = base + 3600
        try writeEvent(event(stop), in: first, name: "1-old", mtime: now - 120)
        try writeEvent(Data("{\"v\":1,".utf8), in: first, name: "2-broken", mtime: now - 90)
        try writeEvent(event(stop), in: first, name: "3-recent", mtime: now - 30)
        try writeEvent(event(codexStop), in: second, name: "1-other", mtime: now - 100)
        let reads = FileReads()
        let store = try openStore(at: scratch.database, counting: reads)
        _ = try await store.ingest(root: first, changed: nil, documents: documents, now: now)
        _ = try await store.ingest(root: second, changed: nil, documents: documents, now: now)

        // Without a retention nothing goes.
        #expect(try await store.prune(now: now) == 0)
        #expect(try await rowCount(in: store) == 4)

        // Lowered: every kind goes, the failed row included.
        store.maxAge = 60
        #expect(try await store.prune(now: now) == 3)
        #expect(try await store.replay().map(\.name) == ["3-recent.json"])
        let roots = try await store.database.read { try String.fetchAll($0, sql: "SELECT path FROM root") }
        #expect(roots == [first.standardizedFileURL.path])
        #expect(try await store.prune(now: now) == 0)
    }

    /// The store's one retention: files stored while they were recent, pruned
    /// once they are older, do not come back from the spool they are still in.
    @Test func aPrunedFileStillInTheSpoolIsNotStoredAgain() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, day: "2026-10-01", name: "1-a", mtime: base + 1)
        try writeEvent(Data("{\"v\":1,".utf8), in: root, day: "2026-10-01", name: "2-broken", mtime: base + 2)
        try writeEvent(event(codexStop), in: root, day: "2026-10-02", name: "3-c", mtime: base + 3)
        let reads = FileReads()
        let store = try openStore(at: scratch.database, maxAge: 60, counting: reads)
        #expect(try await store.ingest(root: root, changed: nil, documents: documents, now: base + 10).new
            .map(\.name) == ["1-a.json", "3-c.json"])

        // An hour later: all of them are past the retention.
        let later = base + 3600
        #expect(try await store.prune(now: later) == 3)
        let readsBefore = reads.names
        // Every day listed, as at a start or when the watcher lost track.
        #expect(try await store.ingest(root: root, changed: nil, documents: documents, now: later).isEmpty)
        #expect(try await store.ingest(root: root, changed: [dayFolder(root, "2026-10-02")], documents: documents,
                                       now: later).isEmpty)
        #expect(reads.names == readsBefore)
        #expect(try await store.replay().isEmpty)
    }

    // MARK: Re-mapping

    @Test func aRaisedRevisionRemapsKnownFilesStillInTheSpool() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let present = try writeEvent(event(stop), in: root, name: "1-present", mtime: base + 1)
        let gone = try writeEvent(event(postToolUse), in: root, name: "2-gone", mtime: base + 2)
        let reads = FileReads()
        let store = try openStore(at: scratch.database, counting: reads)
        _ = try await store.ingest(root: root, changed: nil, documents: documents)
        let before = try await store.replay()

        // `gone` left the spool, and the watcher reports nothing.
        try FileManager.default.removeItem(at: gone)
        let raised: [SourceID: MappingDocument?] = ["claude-code": try claudeCodeWithRaisedRevision(), "codex": codex]
        let result = try await store.ingest(root: root, changed: [], documents: raised)
        #expect(result.new.isEmpty)
        #expect(result.remapped.map(\.name) == ["1-present.json"])
        // The file that left the spool is not opened.
        #expect(reads.names == ["1-present.json", "2-gone.json", "1-present.json"])
        let (_, content) = try #require(expectedEvent(present, documents: raised))
        #expect(result.remapped.first?.content == content)
        #expect(try await column("revision", of: present, in: store) == raisedRevision)
        #expect(try await column("revision", of: gone, in: store) == bundledRevision)
        let replayed = try await store.replay()
        #expect(replayed.map(\.name) == before.map(\.name))
        #expect(replayed.first == result.remapped.first)
        #expect(replayed.last == before.last)

        // Re-mapped once: the next ingest opens nothing.
        #expect(try await store.ingest(root: root, changed: nil, documents: raised).isEmpty)
        #expect(reads.names.count == 3)
    }

    /// An app that reloads its documents on every pass gets the events of a
    /// mapping update apart from the files it has not seen.
    @Test func remappedEventsAreReturnedApartFromNewOnes() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, name: "1-a", mtime: base + 1)
        try writeEvent(event(codexStop), in: root, name: "2-codex", mtime: base + 2)
        try writeEvent(event(postToolUse), in: root, name: "3-b", mtime: base + 3)
        let store = try EventStore(path: scratch.database, maxAge: nil)
        let first = try await store.ingest(root: root, changed: nil, documents: documents)
        #expect(first.new.map(\.name) == ["1-a.json", "2-codex.json", "3-b.json"])
        #expect(first.remapped.isEmpty)

        let raised: [SourceID: MappingDocument?] = ["claude-code": try claudeCodeWithRaisedRevision(), "codex": codex]
        // Older than the known files: the order is per list.
        try writeEvent(event(stop), in: root, name: "0-new", mtime: base)
        let result = try await store.ingest(root: root, changed: [dayFolder(root)], documents: raised)
        #expect(result.new.map(\.name) == ["0-new.json"])
        // Codex's document did not change.
        #expect(result.remapped.map(\.name) == ["1-a.json", "3-b.json"])
        #expect(try await store.replay() == (result.new + [first.new[1]] + result.remapped).sorted { $0.mtime < $1.mtime })
        #expect(try await store.ingest(root: root, changed: [dayFolder(root)], documents: raised).isEmpty)
    }

    /// A re-map looks up its rows instead of listing every day: days nobody
    /// reports are not listed for it, so a new file there waits for its day's
    /// report.
    @Test func aMappingUpdateRemapsKnownFilesInEveryDayButListsOnlyTheReportedDays() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let first = try writeEvent(event(stop), in: root, day: "2026-10-01", name: "1-first", mtime: base + 1)
        let second = try writeEvent(event(postToolUse), in: root, day: "2026-10-02", name: "2-second", mtime: base + 2)
        let reads = FileReads()
        let store = try openStore(at: scratch.database, counting: reads)
        _ = try await store.ingest(root: root, changed: nil, documents: documents)

        // The watcher reports a third day only; the new document reaches every day.
        let raised: [SourceID: MappingDocument?] = ["claude-code": try claudeCodeWithRaisedRevision(), "codex": codex]
        let third = try writeEvent(event(stop), in: root, day: "2026-10-03", name: "3-third", mtime: base + 3)
        let fourth = try writeEvent(event(stop), in: root, day: "2026-10-01", name: "4-fourth", mtime: base + 4)
        let result = try await store.ingest(root: root, changed: [dayFolder(root, "2026-10-03")], documents: raised)
        #expect(result.remapped.map(\.name) == [first, second].map(\.lastPathComponent))
        #expect(result.new.map(\.name) == [third.lastPathComponent])
        for file in [first, second, third] { #expect(try await column("revision", of: file, in: store) == raisedRevision) }
        #expect(reads.names.count == 5)

        #expect(try await store.ingest(root: root, changed: [dayFolder(root, "2026-10-01")], documents: raised)
            == IngestResult(new: try await store.replay().filter { $0.name == fourth.lastPathComponent }, remapped: []))
        #expect(reads.names.count == 6)
    }

    /// A stale file that stays unreadable costs one read per ingest: it is
    /// found again by its row, and its failure lists no day.
    @Test func aRemapWhoseFileCannotBeReadIsRetriedByTheNextIngest() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let file = try writeEvent(event(stop), in: root, day: "2026-10-01", name: "1-a", mtime: base + 1)
        let reads = FailingReads(failing: [])
        let store = try EventStore(path: scratch.database, maxAge: nil, readFile: { try reads.read($0) })
        _ = try await store.ingest(root: root, changed: nil, documents: documents)

        let raised: [SourceID: MappingDocument?] = ["claude-code": try claudeCodeWithRaisedRevision(), "codex": codex]
        reads.failing.withLock { $0 = [file.lastPathComponent] }
        #expect(try await store.ingest(root: root, changed: [], documents: raised).isEmpty)
        #expect(try await column("revision", of: file, in: store) == bundledRevision)

        // Still failing: tried again, while another day stays unlisted.
        let b = try writeEvent(event(codexStop), in: root, day: "2026-10-02", name: "2-b", mtime: base + 2)
        #expect(try await store.ingest(root: root, changed: [], documents: raised).isEmpty)
        #expect(reads.attempts.withLock { $0 } == ["1-a.json", "1-a.json", "1-a.json"])

        reads.failing.withLock { $0 = [] }
        let result = try await store.ingest(root: root, changed: [], documents: raised)
        #expect(result.remapped.map(\.name) == ["1-a.json"])
        #expect(result.new.isEmpty)
        #expect(try await column("revision", of: file, in: store) == raisedRevision)
        #expect(try await store.ingest(root: root, changed: [], documents: raised).isEmpty)
        #expect(reads.attempts.withLock { $0 }.count == 4)
        #expect(try await store.ingest(root: root, changed: [dayFolder(root, "2026-10-02")], documents: raised).new
            .map(\.name) == [b.lastPathComponent])
    }

    @Test func aChangedExclusionSetRemapsKnownFilesStillInTheSpool() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(postToolUse), in: root, name: "1-present", mtime: base + 1)
        let gone = try writeEvent(event(postToolUse), in: root, name: "2-gone", mtime: base + 2)
        let reads = FileReads()
        let store = try openStore(at: scratch.database, counting: reads)
        _ = try await store.ingest(root: root, changed: nil, documents: documents,
                                   excluding: ["claude-code": ["tool_response"]])

        try FileManager.default.removeItem(at: gone)
        let result = try await store.ingest(root: root, changed: [], documents: documents, excluding: [:])
        #expect(result.new.isEmpty)
        #expect(result.remapped.map(\.name) == ["1-present.json"])
        #expect(reads.names == ["1-present.json", "2-gone.json", "1-present.json"])
        let replayed = try await store.replay()
        guard case let .mapped(full) = replayed.first?.content, case let .mapped(stale) = replayed.last?.content else {
            Issue.record("expected two mapped events"); return
        }
        #expect(full.block["tool_response"] != nil)
        #expect(stale.block["tool_response"] == nil)
        #expect(replayed.first == result.remapped.first)

        #expect(try await store.ingest(root: root, changed: nil, documents: documents, excluding: [:]).isEmpty)
        #expect(reads.names.count == 3)
    }

    /// Whole and foreign rows keep their payload, so a source given a document
    /// (or given at all) maps them without opening a file, also one that left
    /// the spool; exclusions apply as to new files.
    @Test func wholeAndForeignRowsAreRemappedFromTheirPayloadOnceTheirSourceIsGiven() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let whole = try writeEvent(event(codexStop), in: root, name: "1-whole", mtime: base + 1)
        let gone = try writeEvent(event(postToolUse), in: root, name: "2-gone", mtime: base + 2)
        try writeEvent(event(stop, source: "elsewhere"), in: root, name: "3-foreign", mtime: base + 3)
        let reads = FileReads()
        let store = try openStore(at: scratch.database, counting: reads)
        let first = try await store.ingest(root: root, changed: nil, documents: ["codex": nil, "claude-code": nil])
        #expect(reads.names.count == 3)

        // Codex and Claude Code get a document; the other source becomes known, still without one.
        let given: [SourceID: MappingDocument?] = ["codex": codex, "claude-code": claudeCode, "elsewhere": nil]
        let excluding: [SourceID: Set<String>] = ["claude-code": ["tool_response"]]
        let (wholeEnvelope, wholeContent) = try #require(expectedEvent(whole, documents: given))
        guard case var .mapped(goneResult)? = expectedEvent(gone, documents: given)?.1 else {
            Issue.record("expected .mapped"); return
        }
        goneResult.core["tool_response"] = nil
        goneResult.block["tool_response"] = nil
        try FileManager.default.removeItem(at: gone)

        let result = try await store.ingest(root: root, changed: [], documents: given, excluding: excluding)
        #expect(result.new.isEmpty)
        #expect(result.remapped.map(\.name) == ["1-whole.json", "2-gone.json", "3-foreign.json"])
        #expect(reads.names.count == 3)
        #expect(result.remapped.first?.envelope == wholeEnvelope)
        #expect(result.remapped.first?.content == wholeContent)
        #expect(result.remapped[1].content == .mapped(goneResult))
        #expect(result.remapped[1].envelope.receivedAt == first.new[1].receivedAt)
        #expect(result.remapped.last?.content == first.new.last.map { .whole($0.envelope.payload) })
        #expect(try await store.replay() == result.remapped)
        #expect(try await store.ingest(root: root, changed: nil, documents: given, excluding: excluding).isEmpty)

        // A mapping that goes away leaves the mapped rows as they are.
        #expect(try await store.ingest(root: root, changed: nil, documents: ["codex": nil, "claude-code": nil]).isEmpty)
        #expect(reads.names.count == 3)
        #expect(try await store.replay() == result.remapped)
    }

    @Test func anotherInterpreterFormatRemapsKnownFilesStillInTheSpool() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let file = try writeEvent(event(stop), in: root, name: "1-a", mtime: base + 1)
        let reads = FileReads()
        let store = try openStore(at: scratch.database, counting: reads)
        let stored = try await store.ingest(root: root, changed: nil, documents: documents)
        #expect(try await column("format", of: file, in: store) == MappingInterpreter.supportedFormat)

        // As if an older interpreter had mapped the row.
        try await store.database.write { db in
            try db.execute(sql: "UPDATE event SET format = 0")
            try db.execute(sql: "UPDATE source_state SET format = 0")
        }
        #expect(try await store.ingest(root: root, changed: nil, documents: documents)
            == IngestResult(new: [], remapped: stored.new))
        #expect(reads.names == ["1-a.json", "1-a.json"])
        #expect(try await column("format", of: file, in: store) == MappingInterpreter.supportedFormat)
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).isEmpty)
        #expect(reads.names.count == 2)
    }

    @Test func aSourceDroppedAndGivenAgainRemapsItsForeignRows() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, name: "1-a", mtime: base + 1)
        let store = try EventStore(path: scratch.database, maxAge: nil)
        _ = try await store.ingest(root: root, changed: nil, documents: documents)

        // Claude Code is dropped from the documents; its next file is stored as foreign.
        let b = try writeEvent(event(stop), in: root, name: "2-b", mtime: base + 2)
        let foreign = try await store.ingest(root: root, changed: [dayFolder(root)], documents: ["codex": codex]).new
        guard case .foreign? = foreign.first?.content else { Issue.record("expected .foreign"); return }

        // Back with the same document as at first: the foreign row is mapped.
        let back = try await store.ingest(root: root, changed: [], documents: documents)
        #expect(back.new.isEmpty)
        #expect(back.remapped.map(\.name) == [b.lastPathComponent])
        let (_, content) = try #require(expectedEvent(b))
        #expect(back.remapped.first?.content == content)
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).isEmpty)
    }

    /// A `v: 2` envelope is failed for a package that reads version 1, and
    /// read again once the package reads version 2 while it is still in the
    /// spool. The app never got it, so it comes as new.
    @Test func aFailedFileIsReadAgainOnceTheEnvelopeVersionChanges() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        // The same captured payload; only the envelope's `v` differs.
        let good = try writeEvent(event(stop), in: root, name: "1-good", mtime: base + 1)
        let v2 = try writeEvent(envelopeJSON(v: 2, payload: capturedPayload(stop)), in: root, name: "2-v2", mtime: base + 2)
        let reads = FileReads()
        let first = try await {
            let store = try openStore(at: scratch.database, counting: reads)
            return try await store.ingest(root: root, changed: nil, documents: documents)
        }()
        #expect(first.new.map(\.name) == [good.lastPathComponent])

        // The same version after a restart: nothing is read again.
        let same = try openStore(at: scratch.database, counting: reads)
        #expect(try await same.ingest(root: root, changed: nil, documents: documents).isEmpty)
        #expect(reads.names.count == 2)

        let newer = try EventStore(path: scratch.database, maxAge: nil, envelopeVersion: 2, readFile: { try reads.read($0) })
        let result = try await newer.ingest(root: root, changed: [], documents: documents)
        #expect(result.remapped.isEmpty)
        #expect(result.new.map(\.name) == [v2.lastPathComponent])
        #expect(reads.names == [good, v2, v2].map(\.lastPathComponent))
        // What the version-1 envelope with the same payload gives.
        #expect(result.new.first?.content == first.new.first?.content)
        #expect(result.new.first?.envelope == first.new.first?.envelope)
        #expect(try await newer.replay().map(\.name) == [good, v2].map(\.lastPathComponent))
        #expect(try await newer.ingest(root: root, changed: nil, documents: documents).isEmpty)
        #expect(reads.names.count == 3)
    }

    // MARK: Damaged database

    @Test func aCorruptDatabaseIsMovedAsideAndRecreated() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        try writeEvent(event(stop), in: root, name: "1-a", mtime: base + 1)
        let aside = scratch.database.appendingPathExtension("corrupt")
        try FileManager.default.createDirectory(at: scratch.database.deletingLastPathComponent(), withIntermediateDirectories: true)

        for garbage in ["first garbage", "second garbage"] {
            let bytes = Data(String(repeating: "\(garbage) ", count: 400).utf8)
            try? FileManager.default.removeItem(at: scratch.database)
            try bytes.write(to: scratch.database)
            do {
                let store = try EventStore(path: scratch.database, maxAge: nil)
                #expect(try await store.replay().isEmpty)
                #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.map(\.name) == ["1-a.json"])
            }
            // Only the latest damaged copy is kept.
            #expect(try Data(contentsOf: aside) == bytes)
        }
    }

    @Test func aDamagedDataPageIsFoundAtOpenAndTheStoreRecreated() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let aside = scratch.database.appendingPathExtension("corrupt")
        let (pageSize, pageCount) = try await intactStore(at: scratch.database, root: root, count: 300)
        #expect(pageCount > 20)

        // One page well inside the file; the schema on page 1 stays readable.
        try damage(scratch.database, at: pageSize * (pageCount / 2), count: pageSize)
        let damaged = try Data(contentsOf: scratch.database)

        let store = try EventStore(path: scratch.database, maxAge: nil)
        #expect(try await store.replay().isEmpty)
        let other = scratch.root("other")
        try writeEvent(event(stop), in: other, name: "1-a", mtime: base + 1)
        #expect(try await store.ingest(root: other, changed: nil, documents: documents).new.map(\.name) == ["1-a.json"])
        #expect(try Data(contentsOf: aside) == damaged)
    }

    @Test func aDamagedSchemaPageIsMovedAsideAndRecreated() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let aside = scratch.database.appendingPathExtension("corrupt")
        let (pageSize, _) = try await intactStore(at: scratch.database, root: root, count: 10)

        // Page 1 after the file header: a database, but a corrupt one.
        try damage(scratch.database, at: 100, count: pageSize - 100)
        let damaged = try Data(contentsOf: scratch.database)
        #expect {
            try DatabaseQueue(path: scratch.database.path).read { try Int.fetchOne($0, sql: "SELECT count(*) FROM event") }
        } throws: { ($0 as? DatabaseError)?.resultCode == .SQLITE_CORRUPT }

        let store = try EventStore(path: scratch.database, maxAge: nil)
        #expect(try await store.replay().isEmpty)
        let other = scratch.root("other")
        try writeEvent(event(stop), in: other, name: "1-a", mtime: base + 1)
        #expect(try await store.ingest(root: other, changed: nil, documents: documents).new.map(\.name) == ["1-a.json"])
        #expect(try Data(contentsOf: aside) == damaged)
    }

    @Test func theWriteAheadLogOfACorruptDatabaseIsMovedAsideWithIt() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let path = scratch.database.path
        try FileManager.default.createDirectory(at: scratch.database.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wal = Data(String(repeating: "log ", count: 400).utf8)
        try Data(String(repeating: "garbage ", count: 400).utf8).write(to: scratch.database)
        try wal.write(to: URL(fileURLWithPath: path + "-wal"))
        try Data(String(repeating: "index ", count: 400).utf8).write(to: URL(fileURLWithPath: path + "-shm"))

        let store = try EventStore(path: scratch.database, maxAge: nil)
        #expect(try await store.replay().isEmpty)
        // SQLite resets a WAL it cannot use while it opens the database, so
        // only the move is visible, not the bytes.
        #expect(FileManager.default.fileExists(atPath: path + ".corrupt-wal"))
        #expect((try? Data(contentsOf: URL(fileURLWithPath: path + "-wal"))) != wal)
        #expect(!FileManager.default.fileExists(atPath: path + ".corrupt-shm"))
    }

    @Test func anUnwritableLocationIsAnError() throws {
        let scratch = try Scratch()
        let locked = scratch.directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            scratch.remove()
        }

        #expect(throws: (any Error).self) { try EventStore(path: locked.appendingPathComponent("events.sqlite"), maxAge: nil) }
        #expect(!FileManager.default.fileExists(atPath: locked.appendingPathComponent("events.sqlite.corrupt").path))
    }

    // MARK: WAL

    @Test func aLargeIngestTruncatesTheWriteAheadLog() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let data = try event(stop)
        let wal = URL(fileURLWithPath: scratch.database.path + "-wal")
        func walSize() throws -> Int { try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int ?? 0 }
        let store = try EventStore(path: scratch.database, maxAge: nil)

        try writeEvent(data, in: root, name: "0", mtime: base)
        _ = try await store.ingest(root: root, changed: nil, documents: documents)
        #expect(try walSize() > 0)
        for index in 1...EventStore.checkpointThreshold { try writeEvent(data, in: root, name: "\(index)", mtime: base + Double(index)) }
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.count == EventStore.checkpointThreshold)
        #expect(try walSize() > 0)
        for index in 1...EventStore.checkpointThreshold + 1 {
            try writeEvent(data, in: root, day: "2026-10-02", name: "\(index)", mtime: base + Double(index))
        }
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.count == EventStore.checkpointThreshold + 1)
        #expect(try walSize() == 0)
    }

    /// A reader on an old snapshot, here another instance's, keeps the WAL
    /// from being truncated. The ingest gives up on it at once instead of
    /// holding its writer for the busy timeout (the held reader would time
    /// out first and fail the test), and the next large ingest, which still
    /// waits for another writer, truncates.
    @Test(.timeLimit(.minutes(2))) func aReaderOnAnOldSnapshotDoesNotHoldUpALargeIngest() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let data = try event(stop)
        let wal = URL(fileURLWithPath: scratch.database.path + "-wal")
        func walSize() throws -> Int { try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int ?? 0 }
        let busy = BusyWaits()
        let store = try openStore(at: scratch.database, watching: busy)
        let reader = try EventStore(path: scratch.database, maxAge: nil)
        // Leaves frames in the WAL, so the reader's snapshot reads from it.
        try writeEvent(data, in: root, name: "0", mtime: base)
        _ = try await store.ingest(root: root, changed: nil, documents: documents)

        let hold = Hold()
        let reading = Task {
            try await reader.database.read { db in
                _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM event")
                hold.hold()
            }
        }
        await hold.waitUntilEntered()
        for index in 1...EventStore.checkpointThreshold + 1 {
            try writeEvent(data, in: root, day: "2026-10-02", name: "\(index)", mtime: base + Double(index))
        }
        #expect(try await store.ingest(root: root, changed: nil, documents: documents).new.count == EventStore.checkpointThreshold + 1)
        #expect(try walSize() > 0)
        hold.release()
        try await reading.value

        for index in 1...EventStore.checkpointThreshold + 1 {
            try writeEvent(data, in: root, day: "2026-10-03", name: "\(index)", mtime: base + Double(index))
        }
        // Ingests still wait for another writer: the next one waits for the
        // other instance's write lock and then succeeds.
        let locking = Hold()
        let locked = Task {
            try await reader.database.writeWithoutTransaction { db in
                try db.inTransaction(.immediate) {
                    locking.hold()
                    return .rollback
                }
            }
        }
        await locking.waitUntilEntered()
        busy.expect()
        let ingest = Task { try await store.ingest(root: root, changed: nil, documents: documents) }
        // Released once the ingest waits for the lock.
        #expect(await busy.untilWaiting(orEndOf: ingest))
        locking.release()
        try await locked.value
        #expect(try await ingest.value.new.count == EventStore.checkpointThreshold + 1)
        #expect(try walSize() == 0)
    }

    /// While a checkpoint makes the store's busy handler give up at once, its
    /// reads don't: pool readers wait for a lock with a timeout of their own
    /// (GRDB's `readonlyBusyMode`), not with the writer's handler. A WAL
    /// reader meets a lock only while another connection recovers the WAL
    /// index, holds the file in exclusive locking mode or, as the last one to
    /// close, checkpoints and deletes the WAL, and its wait in SQLite's own
    /// handler can't be observed, so no test can tell it waited before the
    /// lock went. The test reads the readers' busy timeout instead:
    /// SQLite's handler has one; a connection GRDB gives a handler of the
    /// app's (`.callback`, as the writer has) or none has 0.
    @Test(.timeLimit(.minutes(2))) func readsDoNotGiveUpWhileTheStoreCheckpoints() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root()
        let busy = BusyWaits()
        let store = try openStore(at: scratch.database, watching: busy)
        let held = try await CheckpointHold(store, busy: busy, root: root,
                                            reader: EventStore(path: scratch.database, maxAge: nil))

        #expect(store.checkpointing.withLock { $0 })
        #expect(try await store.replay().count == EventStore.checkpointThreshold + 2)
        let timeout = try await store.database.read { try Int.fetchOne($0, sql: "PRAGMA busy_timeout") }
        #expect((timeout ?? 0) > 0)
        try await held.release()
    }

    /// The flag is the store's own: another instance's ingest waiting for the
    /// write lock the checkpoint holds keeps waiting, and succeeds.
    @Test(.timeLimit(.minutes(2))) func anotherInstanceWaitsForAStoreThatCheckpoints() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let root = scratch.root(), other = scratch.root("other")
        let busy = BusyWaits(), otherBusy = BusyWaits()
        let store = try openStore(at: scratch.database, watching: busy)
        // Opened before the checkpoint takes the lock: opening migrates.
        let waiting = try openStore(at: scratch.database, watching: otherBusy)
        let file = try writeEvent(event(codexStop), in: other, name: "1-a", mtime: base + 1)
        let held = try await CheckpointHold(store, busy: busy, root: root,
                                            reader: EventStore(path: scratch.database, maxAge: nil))

        otherBusy.expect()
        let ingest = Task { try await waiting.ingest(root: other, changed: nil, documents: documents) }
        #expect(await otherBusy.untilWaiting(orEndOf: ingest))
        #expect(store.checkpointing.withLock { $0 })
        try await held.release()
        #expect(try await ingest.value.new.map(\.name) == [file.lastPathComponent])
    }
}

/// Holds `store` inside the WAL checkpoint after a large ingest of `root`,
/// with its busy handler set to give up at once: `reader`, another
/// instance, holds an old snapshot, so the checkpoint waits for it, and
/// `busy` holds that wait. The checkpoint holds the write lock meanwhile.
private struct CheckpointHold {
    private let ingest: Task<IngestResult, any Error>
    private let checkpoint: Hold
    private let snapshot: Hold
    private let reading: Task<Void, any Error>

    init(_ store: EventStore, busy: BusyWaits, root: URL, reader: EventStore) async throws {
        let data = try event(stop)
        // Leaves frames in the WAL, so the reader's snapshot reads from it.
        try writeEvent(data, in: root, name: "0", mtime: base)
        _ = try await store.ingest(root: root, changed: nil, documents: documents)
        let snapshot = Hold()
        reading = Task {
            try await reader.database.read { db in
                _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM event")
                snapshot.hold()
            }
        }
        await snapshot.waitUntilEntered()
        for index in 1...EventStore.checkpointThreshold + 1 {
            try writeEvent(data, in: root, day: "2026-10-02", name: "\(index)", mtime: base + Double(index))
        }
        let checkpoint = Hold()
        busy.expect(holding: checkpoint)
        let ingest = Task { try await store.ingest(root: root, changed: nil, documents: documents) }
        #expect(await busy.untilWaiting(orEndOf: ingest))
        (self.ingest, self.checkpoint, self.snapshot) = (ingest, checkpoint, snapshot)
    }

    /// Lets the checkpoint give up and the ingest return, then the reader.
    func release() async throws {
        checkpoint.release()
        #expect(try await ingest.value.new.count == EventStore.checkpointThreshold + 1)
        snapshot.release()
        try await reading.value
    }
}
