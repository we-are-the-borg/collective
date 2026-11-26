import Foundation
import os
import SubspaceKit

/// Reads the subspace spool (contract v1) and turns its event files into `AgentEvent`s.
///
/// Each adapter names its source's roots (§2), usually one; a tool with a CLI
/// and a desktop app may have two. `SUBSPACE_DIR` replaces all of them with one
/// shared root. Roots that are one folder, e.g. one a link to another,
/// are read as one, so a file is applied once. A root may not exist yet (§3),
/// e.g. when the tool or subspace isn't installed: until it appears the reader
/// only checks for it every `pollInterval`, so an idle app costs nothing.
/// Envelopes go to the adapter of their `source`; other sources, unknown
/// versions and unreadable files are skipped (§4, §6). The reader never writes
/// to a root.
///
/// With a store (SubspaceKit's `EventStore`, an SQLite file of the app's), each
/// spool file is read, parsed and mapped once and kept as a row. A start replays
/// the rows instead of reading the spool again, so sessions outlive subspace's
/// retention (§5); the rows go by the app's own (`setMaxAge`, `pruneStore`).
/// The replay returns the rows of every root the store knows, former ones too,
/// e.g. from before the user chose another folder: their sessions run out like
/// any other, and those roots aren't watched.
///
/// Only one reader uses a store file at a time: an ingest returns a new file
/// only to the reader that ran it, so a second reader on the file, e.g. a Debug
/// build running next to the Release build, would miss what the first one took
/// in. A reader therefore holds a lock on `<store>.lock`, next to the database,
/// from before it opens the store until it has stopped.
///
/// Without a store the reader reads the spool itself at every start. It does so
/// too, for its whole lifetime, when the store is another reader's, can't be
/// opened, would lie in a root or fails while the reader starts: the store
/// saves work and keeps history, but never costs an event.
public actor SpoolReader {
    /// What the reader's stream yields.
    public enum Output: Sendable {
        /// The events of one scan, never empty.
        case events([AgentEvent])
        /// The store's backlog at start, never empty: `events` as for
        /// `.events`. `freshTimes` are the times of those of them whose file a
        /// root still holds, what reading the spool without a store would have
        /// returned too; the rest only the store kept, e.g. from before
        /// subspace's retention, a reinstall or a former root. Only the spool
        /// says a tool delivers now. The times, not those events: the backlog
        /// is every start's work, and a second list of it would add to each.
        case replay([AgentEvent], freshTimes: LastEventTimes)
        /// Every root's backlog at start has been read, including roots without
        /// events and roots that don't exist yet. Yielded once, after the
        /// backlog's batches; until then an empty state only means "not read yet".
        case backlogFinished
    }

    private let adapters: [SourceID: any PushAdapter]
    private let roots: [URL]
    private let watcher: any DirectoryWatching
    private let pollInterval: Duration
    /// Where the store's SQLite file lies, nil for none.
    private let storeURL: URL?
    /// How long the store keeps events (`setMaxAge`).
    private var maxAge: TimeInterval?
    /// The store the events are kept in, once `events()` has opened it; nil
    /// while the reader reads the spool only.
    private var store: (any SpoolStore)?
    /// The descriptor that holds the store's lock while this reader has the store.
    private var storeLock: Int32?
    /// Opens the store at a path with a maximum age; tests hand in their own.
    private let openStore: @Sendable (URL, TimeInterval?) throws -> any SpoolStore
    /// The files the start's replay returned, by day and name. The store keeps
    /// a file once per root path, so a folder reached under two paths, e.g.
    /// through a link, holds files the replay returned already: they are old,
    /// not news, and applying them again would put them on top of newer state.
    private var replayed: Set<String> = []
    private let log = Logger(subsystem: "CollectiveKit", category: "spool")
    /// Roots whose backlog at start hasn't been read yet.
    private var pendingBacklogs = 0
    /// What `events()` started; `stop()` waits for it.
    private var reading: Task<Void, Never>?
    /// Whether `stop()` was called: `events()` starts nothing after it.
    private var stopped = false

    /// The store a reader keeps its events in.
    public struct Store: Sendable {
        /// The path of the app's SQLite file for the events.
        public var path: URL
        /// How long the store keeps events, by their file's mtime; nil keeps
        /// them for good.
        public var maxAge: TimeInterval?

        /// `maxAge` has no default, as in `EventStore`: how long to keep events
        /// is the app's decision, not a silent "for good".
        public init(path: URL, maxAge: TimeInterval?) {
            self.path = path
            self.maxAge = maxAge
        }
    }

    /// `chosenRoots` are folders the user picked per source; they win over
    /// `SUBSPACE_DIR` and the adapter's own root (`SubspaceRoot`).
    ///
    /// `watcher` reports changes under each root. The default names the changed
    /// files themselves (`fileEvents`), so the store checks just those instead
    /// of listing the day folder, which may hold 10 000 files, on every report.
    ///
    /// `store` is where the events are kept and for how long, `nil` keeps none.
    /// The file is opened by what `events()` starts, not here: opening checks
    /// the whole file, and the caller may be on the main actor.
    public init(
        adapters: sending [any PushAdapter],
        chosenRoots: [SourceID: URL] = [:],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        watcher: any DirectoryWatching = FSEventsWatcher(fileEvents: true),
        pollInterval: Duration = .seconds(5),
        store: Store? = nil
    ) {
        self.init(adapters: adapters, chosenRoots: chosenRoots, environment: environment, home: home, watcher: watcher,
                  pollInterval: pollInterval, store: store,
                  openStore: { try EventStore(path: $0, maxAge: $1) })
    }

    /// For tests: `openStore` stands in for opening an `EventStore`.
    init(
        adapters: sending [any PushAdapter],
        chosenRoots: [SourceID: URL] = [:],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        watcher: any DirectoryWatching = FSEventsWatcher(fileEvents: true),
        pollInterval: Duration = .seconds(5),
        store: Store? = nil,
        openStore: @escaping @Sendable (URL, TimeInterval?) throws -> any SpoolStore
    ) {
        self.roots = Self.roots(of: adapters, chosen: chosenRoots, environment: environment, home: home)
        self.adapters = Dictionary(adapters.map { ($0.source, $0) }) { first, _ in first }
        self.watcher = watcher
        self.pollInterval = pollInterval
        self.storeURL = store?.path
        self.maxAge = store?.maxAge
        self.openStore = openStore
    }

    /// The roots to watch, each folder once. Two roots that are one folder
    /// under two paths, e.g. one source's root a link to another's, are one
    /// root, under the path of the first: watched twice, every file would be
    /// read and yielded once per path.
    static func roots(of adapters: [any PushAdapter], chosen: [SourceID: URL] = [:],
                      environment: [String: String], home: URL) -> [URL] {
        var roots: [URL] = []
        var folders: Set<String> = []
        for adapter in adapters {
            for root in SubspaceRoot.resolveAll(adapter: adapter, chosen: chosen[adapter.source], environment: environment, home: home) {
                if folders.insert(resolved(root).path).inserted { roots.append(root) }
            }
        }
        return roots
    }

    /// Starts reading: first the backlog, then new files as they arrive. With a
    /// store the backlog is one `replay`, all it holds once it has taken in the
    /// spool; without one it is a batch per root. Each later scan is one batch
    /// too, so a consumer applies what came together at once instead of
    /// redrawing per event; scans without events yield nothing. After the
    /// backlog comes `backlogFinished`. Ending the stream's iteration stops the
    /// reader, `stop()` too and waits until it has. Call once.
    ///
    /// After `stop()` the stream ends at once, and neither the store nor its
    /// lock is taken: a consumer that gets here late, e.g. a task that was
    /// still waiting for its turn, must not keep the store from the next reader.
    public func events() -> AsyncStream<Output> {
        let (stream, continuation) = AsyncStream.makeStream(of: Output.self)
        guard !stopped else {
            continuation.finish()
            return stream
        }
        let task = Task {
            await self.run(into: continuation)
            continuation.finish()
        }
        reading = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Stops reading and returns once every watch loop has ended, so nothing is
    /// read or stored afterwards, and the store and its lock are let go: a new
    /// reader may then use the same store, e.g. after the user chose another
    /// folder. Ends the stream too. Final: `events()` starts nothing afterwards.
    public func stop() async {
        stopped = true
        guard let reading else { return }
        reading.cancel()
        await reading.value
    }

    /// Whether the reader keeps its events in the store: from when `events()`
    /// has opened it until the reader stops, never for a reader that reads the
    /// spool only. The app asks after the backlog: a reader without the store
    /// then means the store is someone else's, e.g. a second copy of the app's,
    /// or unusable.
    public var holdsStore: Bool { store != nil }

    /// Changes how long the store keeps events, by their file's mtime (nil: for
    /// good), e.g. when the user changes the app's retention. The next
    /// `pruneStore` deletes by it. Does nothing without a store.
    public func setMaxAge(_ maxAge: TimeInterval?) {
        self.maxAge = maxAge
        store?.maxAge = maxAge
    }

    /// Deletes the stored events older than the maximum age before `now`; the
    /// spool is left alone. Does nothing without a store.
    public func pruneStore(now: Date) async {
        guard let store else { return }
        do {
            _ = try await store.prune(now: now)
        } catch {
            log.error("Not pruning the event store: \(String(describing: error), privacy: .public)")
        }
    }

    private func run(into continuation: AsyncStream<Output>.Continuation) async {
        var subscribed: [URL: AsyncStream<Set<URL>?>] = [:]
        store = openedStore()
        if let opened = store {
            do {
                subscribed = try await replay(opened, into: continuation)
            } catch {
                // Nothing was yielded yet, so reading the spool instead repeats nothing.
                releaseStore()
                if !Task.isCancelled {
                    log.error("Reading without the event store, it failed at start: \(String(describing: error), privacy: .public)")
                }
            }
        }
        if store == nil {
            pendingBacklogs = roots.count
            if roots.isEmpty { continuation.yield(.backlogFinished) }
        }
        let (store, subscriptions) = (store, subscribed)
        await withTaskGroup(of: Void.self) { group in
            for root in roots {
                group.addTask { await self.watch(root, store: store, subscribed: subscriptions[root], into: continuation) }
            }
        }
        releaseStore()
    }

    // MARK: Store

    /// The store to keep the events in, or nil: without a log when no store was
    /// asked for (a deliberate choice, e.g. tests, the benchmark's raw run), with
    /// a log line when the asked-for store can't be used (it overlaps a root,
    /// another reader holds its lock, opening fails). The reader then reads the
    /// spool only.
    private func openedStore() -> (any SpoolStore)? {
        guard let storeURL else { return nil }
        // The reader never writes into a root (§4); SQLite's side files lie next to the store's.
        if roots.contains(where: { Self.overlap($0, storeURL) }) {
            log.error("Keeping no event store at \(storeURL.path, privacy: .public): it overlaps a spool root")
            return nil
        }
        do {
            storeLock = try Self.lock(storeURL)
            return try openStore(storeURL, maxAge)
        } catch let error as POSIXError where error.code == .EWOULDBLOCK {
            log.error("Keeping no event store at \(storeURL.path, privacy: .public): another reader uses it, e.g. a second copy of the app")
        } catch {
            log.error("Keeping no event store at \(storeURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        releaseStore()
        return nil
    }

    /// How long `lock` keeps trying a lock someone holds, and how often.
    private static let lockGrace: Duration = .milliseconds(250)
    private static let lockRetryInterval: Duration = .milliseconds(5)

    /// Takes the lock of the store at `storeURL` and returns the descriptor
    /// that holds it: closing it releases the lock, and so does the kernel when
    /// the process ends. Throws `EWOULDBLOCK` while another reader holds it, in
    /// this process or another, and whatever keeps the lock file from being
    /// created. The file is never deleted: a reader that locked a deleted file
    /// would not keep out one that created it anew.
    ///
    /// A held lock is tried again for up to `lockGrace` before this throws, on
    /// the calling thread: a child process being started elsewhere in the
    /// process, e.g. a setup command, holds a copy of every descriptor until
    /// its exec closes them, so a lock its last holder has just closed stays
    /// taken for a few milliseconds. A second copy of the app holds it
    /// for good; a reader then reads the spool alone only after the grace.
    static func lock(_ storeURL: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(storeURL.path + ".lock", O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let deadline = ContinuousClock.now + lockGrace
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK, ContinuousClock.now < deadline else {
                close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            Thread.sleep(forTimeInterval: lockRetryInterval / .seconds(1))
        }
        return descriptor
    }

    /// Lets go of the store and its lock, for the next reader on the file.
    private func releaseStore() {
        store = nil
        if let storeLock { close(storeLock) }
        storeLock = nil
    }

    /// The start with a store: yields everything it holds as one `replay`, with
    /// the times of the events whose files the current roots still hold, then
    /// `backlogFinished`, and returns the roots' watcher subscriptions.
    ///
    /// The spool is ingested before the replay, not after: a changed mapping is
    /// then already applied to what the replay returns, and the one replay gives
    /// the contract's order across all roots. No ingest runs alongside the
    /// replay, so no event comes twice.
    private func replay(_ store: any SpoolStore, into continuation: AsyncStream<Output>.Continuation) async throws
        -> [URL: AsyncStream<Set<URL>?>] {
        var subscribed: [URL: AsyncStream<Set<URL>?>] = [:]
        // Subscribe before ingesting, so nothing written in between is missed.
        for root in roots where Self.directoryExists(root) { subscribed[root] = watcher.changes(under: root) }
        _ = try await store.prune(now: Date())
        // Their results are dropped: the replay returns the same rows.
        for root in roots { _ = try await ingest(root, changed: nil, into: store) }
        // Listed while the store reads its rows, not after: with many files the
        // listing would otherwise add to every start.
        async let listed = Self.files(in: roots)
        let (rows, keys) = once(try await store.replay())
        replayed = keys
        let inSpool = await listed
        // Standardized once per root, not per row, as in `once`.
        var rootPaths: [URL: String] = [:]
        var events: [AgentEvent] = []
        var freshTimes = LastEventTimes()
        for row in rows {
            let rowEvents = self.events(from: row)
            events += rowEvents
            let rootPath = rootPaths[row.root] ?? row.root.standardizedFileURL.path
            rootPaths[row.root] = rootPath
            if inSpool[rootPath]?[row.day]?.contains(row.name) == true { freshTimes.record(rowEvents) }
        }
        if !events.isEmpty { continuation.yield(.replay(events, freshTimes: freshTimes)) }
        continuation.yield(.backlogFinished)
        return subscribed
    }

    /// The replay's rows, each file once and in the given order, with the files'
    /// keys. Of a file the store holds under several roots, the row of a current
    /// root counts: only those were just ingested, so any other row may carry an
    /// older mapping. Current is exactly a path this reader ingests, in the form
    /// the store keys its rows by, not the folder behind it: a row stored under
    /// another path of the same folder, e.g. a link, was not re-mapped either.
    /// The row takes the place of the file's first row. For a moved folder that
    /// is its own place, as the rows of one file then share what the replay
    /// orders by first; a copied folder's rows need not.
    private func once(_ rows: [StoredEvent]) -> (rows: [StoredEvent], keys: Set<String>) {
        let current = Set(roots.map { $0.standardizedFileURL.path })
        // Only asked for a file's further rows; per root, not per row.
        var known: [URL: Bool] = [:]
        func isCurrent(_ root: URL) -> Bool {
            if let answer = known[root] { return answer }
            let answer = current.contains(root.standardizedFileURL.path)
            known[root] = answer
            return answer
        }
        var kept: [StoredEvent] = []
        var places: [String: Int] = [:]
        for row in rows {
            let key = Self.key(row)
            if let place = places[key] {
                if !isCurrent(kept[place].root), isCurrent(row.root) { kept[place] = row }
            } else {
                places[key] = kept.count
                kept.append(row)
            }
        }
        return (kept, Set(places.keys))
    }

    /// One ingest pass of `root`'s spool into `store`.
    private func ingest(_ root: URL, changed: Set<URL>?, into store: any SpoolStore) async throws -> IngestResult {
        // Once per pass, not per file: each fetch stats the mapping file.
        let documents = adapters.mapValues { $0.mappingDocument() }
        let excluding = adapters.mapValues(\.excludedFields)
        return try await store.ingest(root: root, changed: changed, documents: documents, excluding: excluding, now: Date())
    }

    /// Stored rows through the adapters, one by one in the given order.
    private func events(from rows: [StoredEvent]) -> [AgentEvent] {
        rows.flatMap { events(from: $0) }
    }

    private func events(from row: StoredEvent) -> [AgentEvent] {
        guard let adapter = adapters[row.source] else { return [] }
        do {
            switch row.content {
            case let .mapped(result): return try adapter.events(from: row.envelope, mapped: result)
            case .whole: return try adapter.events(from: row.envelope)
            case .foreign: return []
            }
        } catch {
            log.error("Skipping \(row.day, privacy: .public)/\(row.name, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// A file's place in a root, `<day>/<name>`, the same whichever path leads to the root.
    private static func key(_ row: StoredEvent) -> String {
        "\(row.day)/\(row.name)"
    }

    /// The files `roots` hold now, by the root's standardized path (as the
    /// store keys its rows), day and name. Listed from the spool, not the store,
    /// which also keeps files subspace has deleted since. Names only, from
    /// `events/<day>/` (contract §3, §4): a membership test needs neither the
    /// scanner's stats nor its order, and the stored rows it is asked about are
    /// event files only, so other names need no filter.
    private static func files(in roots: [URL]) -> [String: [String: Set<String>]] {
        let manager = FileManager.default
        var files: [String: [String: Set<String>]] = [:]
        for root in roots {
            let events = root.appendingPathComponent("events", isDirectory: true).path
            var days: [String: Set<String>] = [:]
            for day in (try? manager.contentsOfDirectory(atPath: events)) ?? [] {
                days[day] = Set((try? manager.contentsOfDirectory(atPath: "\(events)/\(day)")) ?? [])
            }
            files[root.standardizedFileURL.path] = days
        }
        return files
    }

    // MARK: Watching

    /// Watches `root` and yields what each report brings. Without a store the
    /// first scan is the root's backlog; with one the backlog came from the
    /// replay, and `subscribed` is the subscription made before it, nil for a
    /// root that was missing then.
    private func watch(_ root: URL, store: (any SpoolStore)?, subscribed: AsyncStream<Set<URL>?>?,
                       into continuation: AsyncStream<Output>.Continuation) async {
        var scanner = SpoolScanner(root: root)
        var subscribed = subscribed
        // A root that is missing at start has an empty backlog; when it appears
        // later, its first scan is news, not backlog. So is every scan with a store.
        var backlogRead = store != nil
        while !Task.isCancelled {
            let changes: AsyncStream<Set<URL>?>
            if let made = subscribed {
                changes = made
                subscribed = nil
            } else {
                guard Self.directoryExists(root) else {
                    if !backlogRead { backlogRead = true; finishBacklog(into: continuation) }
                    try? await Task.sleep(for: pollInterval)
                    continue
                }
                // Subscribe before scanning, so nothing written in between is missed.
                changes = watcher.changes(under: root)
                yield(await news(of: root, changed: nil, scanner: &scanner, store: store), into: continuation)
                if !backlogRead { backlogRead = true; finishBacklog(into: continuation) }
            }
            var vanished = false
            for await changed in changes {
                // E.g. Claude Code removes the root on uninstall: wait for it again.
                vanished = !Self.directoryExists(root)
                if vanished { break }
                yield(await news(of: root, changed: changed, scanner: &scanner, store: store), into: continuation)
            }
            // A watcher that ended on its own must not make this loop spin.
            if !vanished { try? await Task.sleep(for: .seconds(1)) }
        }
    }

    /// The events of the files a watcher report brings, `changed` as for
    /// `SpoolScanner.scan(changed:)`: with a store what an ingest returns as
    /// new, without one what the scanner hasn't returned before.
    ///
    /// A report may hold event files (the default watcher uses file events) as
    /// well as day folders. With a store, a reported file is checked alone and
    /// its day folder isn't listed; the scanner still scans the file's day.
    private func news(of root: URL, changed: Set<URL>?, scanner: inout SpoolScanner, store: (any SpoolStore)?) async -> [AgentEvent] {
        guard let store else { return await read(scanner.scan(changed: changed)) }
        do {
            // Re-mapped rows are left out: like every mapping change, they take
            // effect at the next start, whose replay returns them.
            let new = try await ingest(root, changed: changed, into: store).new
            return events(from: replayed.isEmpty ? new : new.filter { !replayed.contains(Self.key($0)) })
        } catch {
            // The store keeps the reported days and files pending, so the next ingest of
            // this root returns what this one missed.
            if !Task.isCancelled {
                log.error("Not storing events of \(root.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            return []
        }
    }

    /// Parsing and mapping are pure and run in parallel; the adapters correlate
    /// across events, so they get the results one by one in the contract's order.
    private func read(_ files: [URL]) async -> [AgentEvent] {
        guard !files.isEmpty else { return [] }
        // Once per pass, not per file: each fetch stats the mapping file.
        let documents = adapters.mapValues { $0.mappingDocument() }
        let parsed = await files.concurrentMap { SpoolFile.parsed(from: $0, documents: documents) }
        var events: [AgentEvent] = []
        for (file, parsed) in zip(files, parsed) {
            do {
                switch parsed {
                case let .mapped(envelope, result):
                    guard let adapter = adapters[envelope.source] else { continue }
                    events += try adapter.events(from: envelope, mapped: result)
                case let .whole(envelope):
                    guard let adapter = adapters[envelope.source] else { continue }
                    events += try adapter.events(from: envelope)
                case .foreign:
                    continue
                case let .failed(error):
                    throw error
                }
            } catch {
                log.error("Skipping \(file.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return events
    }

    private func yield(_ batch: [AgentEvent], into continuation: AsyncStream<Output>.Continuation) {
        if !batch.isEmpty { continuation.yield(.events(batch)) }
    }

    private func finishBacklog(into continuation: AsyncStream<Output>.Continuation) {
        pendingBacklogs -= 1
        if pendingBacklogs == 0 { continuation.yield(.backlogFinished) }
    }

    // MARK: File system

    /// Whether one path is the other or lies inside it, with symlinks resolved.
    static func overlap(_ a: URL, _ b: URL) -> Bool {
        let a = resolved(a).pathComponents
        let b = resolved(b).pathComponents
        return a.starts(with: b) || b.starts(with: a)
    }

    /// The real path of `url`, which may not exist yet: its deepest existing
    /// folder resolved, the rest appended. `resolvingSymlinksInPath` leaves a
    /// missing path as it is, so a store not created yet would slip through.
    private static func resolved(_ url: URL) -> URL {
        let url = url.standardizedFileURL
        if let real = realpath(url.path, nil) {
            defer { free(real) }
            return URL(fileURLWithPath: String(cString: real), isDirectory: true)
        }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { return url }
        return resolved(parent).appendingPathComponent(url.lastPathComponent, isDirectory: true)
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
