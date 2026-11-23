import Foundation
import GRDB
import os
import Synchronization

/// Keeps each spool file's parsed and mapped event in an SQLite database the
/// app owns, so every file is read, parsed and mapped once and a start replays
/// the stored rows instead.
///
/// The app chooses the location, in its own data directory: the package never
/// writes into a spool root (contract §3). Rows are keyed by root, day folder
/// and file name, which the plugin never reuses (contract §4). They stay until
/// `prune()` removes them by the app's retention (`maxAge`).
///
/// At start the app calls `replay()` first, then `ingest(changed: nil)` for
/// each root, then the ingests its watcher triggers. An ingest that commits
/// while `replay` is still about to read returns events the replay holds as
/// well, so an app that must not see an event twice doesn't run one alongside
/// its start replay.
///
/// Each `ingest` and each `prune` is one SQLite write transaction. SQLite lets
/// one writer in at a time, so they run one after the other, whether they
/// come from one instance, from several instances on the same file or from
/// several processes (e.g. a Debug and a Release build sharing their data
/// directory); each waits for the one before it, up to 30 seconds, and then
/// throws. `replay` reads alongside any of them and sees what the last one
/// committed. All instances and processes on one file must ingest with the
/// same documents, `excluding` sets and package version: otherwise each one
/// takes the rows the other stored for a mapping change and re-maps them, on
/// every ingest.
public final class EventStore: Sendable {
    /// WAL mode: the app's replay doesn't wait for an ingest's write
    /// transaction, which holds the write lock while it reads files.
    let database: DatabasePool
    /// Injected by tests to count which files are opened.
    private let readFile: @Sendable (URL) throws -> Data
    /// The envelope version the store reads, `SpoolFile.version`; tests
    /// inject another to stand in for a package that reads a newer one.
    private let envelopeVersion: Int
    /// Backs `maxAge`, which the app may set while an ingest or prune reads it.
    private let retention: Mutex<TimeInterval?>
    /// What ingests have yet to list beyond what they are told: days reported
    /// to an ingest that hasn't succeeded yet, or holding a file that could
    /// not be read, and roots to list in full. Such a file may never change
    /// again, so its day may never be reported again. Only in memory: a new
    /// store starts with a full listing anyway.
    private let pending = Mutex(PendingListings())
    /// Paths of spool files whose read failed and was logged as an error;
    /// later failures of the same file, which every ingest of its day retries,
    /// are logged at debug level. A file leaves the set once it is read.
    let loggedUnreadable = Mutex<Set<String>>([])
    /// On while `truncateLog` checkpoints, on the writer's queue: the busy
    /// handler then gives up at once. Only the writer has that handler, see
    /// `open`. Not a `Mutex`: the handler, an escaping closure, keeps a copy.
    let checkpointing: OSAllocatedUnfairLock<Bool>

    /// How long an ingest or prune waits for another writer's transaction,
    /// of another instance or process, before it throws `SQLITE_BUSY`.
    /// A first ingest of a full spool holds the lock for a second or two on
    /// a fast machine, so this leaves room for slower machines and larger
    /// spools; a lock held longer belongs to a stuck writer, and the ingest
    /// fails and leaves its days to the next one.
    static let busyTimeout: TimeInterval = 30
    /// How long the busy handler sleeps before each retry: short against a
    /// lock held for a few milliseconds, the usual ingest of a few files.
    static let busyRetryInterval: TimeInterval = 0.01

    static let log = Logger(subsystem: "SubspaceKit", category: "store")

    /// How long the store keeps events, by their file's mtime; nil keeps
    /// them for good. Both `ingest` and `prune` go by it, so a file `prune`
    /// removed is not stored again by the next ingest while it is still in
    /// the spool. Set it when the user changes the app's retention: a lower
    /// value lets the next `prune` delete more; a higher one lets files still
    /// in the spool that are within the new limit come back as new events on
    /// the next ingest that lists their day (at the latest
    /// `ingest(changed: nil)`), which is right, since they are within the
    /// retention again.
    public var maxAge: TimeInterval? {
        get { retention.withLock { $0 } }
        set { retention.withLock { $0 = newValue } }
    }

    /// Opens or creates the database at `path`, creating missing parent
    /// folders, and brings its schema up to date. A file that is not a
    /// database or is corrupt, including a damaged page anywhere in it (checked
    /// with `PRAGMA quick_check`), is moved aside as `<path>.corrupt` (replacing
    /// an older one) and replaced by an empty store, which the app's next
    /// ingest fills again from the spool. Other failures, e.g. a folder the app
    /// may not write to, are thrown.
    ///
    /// Only an open checks: damage that arises while the store is open makes
    /// `ingest`, `replay` and `prune` throw, and the next open recovers it.
    ///
    /// `maxAge` is the app's retention, see the property. It has no default:
    /// how long to keep events is the app's decision, and a silent "forever"
    /// would grow the store without anyone having chosen it.
    public convenience init(path: URL, maxAge: TimeInterval?) throws {
        try self.init(path: path, maxAge: maxAge, readFile: { try Data(contentsOf: $0) })
    }

    /// `onBusyWait` is injected by tests to see, or hold, the writer waiting
    /// for a lock: the busy handler calls it with its retry count, on the
    /// waiting thread, before it decides whether to wait on.
    init(path: URL, maxAge: TimeInterval?, envelopeVersion: Int = SpoolFile.version,
         readFile: @escaping @Sendable (URL) throws -> Data, onBusyWait: (@Sendable (Int) -> Void)? = nil) throws {
        retention = Mutex(maxAge)
        self.envelopeVersion = envelopeVersion
        let checkpointing = OSAllocatedUnfairLock(initialState: false)
        self.checkpointing = checkpointing
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            database = try Self.open(path, checkpointing: checkpointing, onBusyWait: onBusyWait)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB || error.resultCode == .SQLITE_CORRUPT {
            Self.log.error("Replacing damaged event store \(path.path, privacy: .public): \(String(describing: error), privacy: .public)")
            try Self.moveAside(path)
            database = try Self.open(path, checkpointing: checkpointing, onBusyWait: onBusyWait)
        }
        self.readFile = readFile
    }

    private static func open(_ path: URL, checkpointing: OSAllocatedUnfairLock<Bool>,
                             onBusyWait: (@Sendable (Int) -> Void)?) throws -> DatabasePool {
        // GRDB's default fails at once while another connection writes; the
        // migration below is a write too. A handler rather than `.timeout`,
        // so `truncateLog` turns the wait off through GRDB, not through a
        // SQLite library GRDB may not be built with. Only the writer calls
        // it: a pool gives its readers a timeout of its own. Like SQLite's
        // own timeout, it sleeps on the thread of the waiting statement (the
        // writer's queue for ingests and prunes) and counts its sleeps
        // rather than reading the clock; false gives up with SQLITE_BUSY.
        var configuration = Configuration()
        configuration.busyMode = .callback { tries in
            onBusyWait?(tries)
            guard !checkpointing.withLock({ $0 }), Double(tries) * busyRetryInterval < busyTimeout else { return false }
            Thread.sleep(forTimeInterval: busyRetryInterval)
            return true
        }
        let database = try DatabasePool(path: path.path, configuration: configuration)
        do {
            try migrator.migrate(database)
            // A damaged page past the schema passes the migration and would
            // only fail later reads; quick_check reads every page. It reports
            // what it finds as rows, the first one "ok" for an intact file.
            let check = try database.read { try String.fetchOne($0, sql: "PRAGMA quick_check") }
            guard check == "ok" else {
                throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "quick_check: \(check ?? "no result")")
            }
        } catch {
            try? database.close()
            throw error
        }
        return database
    }

    /// Keeps the damaged file, with its WAL, for a look later; the shared
    /// memory file only indexes the WAL and is dropped.
    private static func moveAside(_ path: URL) throws {
        let files = FileManager.default
        for (suffix, asideSuffix) in [("", ".corrupt"), ("-wal", ".corrupt-wal"), ("-shm", nil)] {
            let source = path.path + suffix
            if let asideSuffix { try? files.removeItem(atPath: path.path + asideSuffix) }
            guard files.fileExists(atPath: source) else { continue }
            if let asideSuffix {
                try files.moveItem(atPath: source, toPath: path.path + asideSuffix)
            } else {
                try files.removeItem(atPath: source)
            }
        }
    }

    // MARK: Schema

    /// What a row holds. `failed` rows hold no content; they only mark a file
    /// as known so it is not reopened (contract §6: skip and log).
    enum Kind: String {
        case mapped, whole, foreign, failed
    }

    /// Internal so tests can build a store of an earlier schema version.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            // Each root path once; rows refer to it by id, which keeps the
            // path out of every row and out of the primary key. `version` is
            // the envelope version (`SpoolFile.version`) the root's files were
            // last read with, so failed rows are read again when it changes.
            // It is set with the root's `source_state` rows, and null until
            // then: a root without any, never ingested or with no sources at
            // all, can't tell the two apart otherwise.
            //
            // One row per spool file. `revision` is the mapping document's,
            // `exclusions` the fingerprint of the fields removed from `result`
            // and `format` the interpreter's `supportedFormat` (mapped rows
            // only), so a row can be re-mapped when one of them changes. Per row
            // rather than once for the store: ingest re-maps one root at a time
            // and mapped rows only while their file is still in the spool, so
            // rows of different mappings live side by side. `payload` keeps
            // the bytes of whole and foreign rows, which a later mapping maps
            // without the file. Envelope columns are null for failed
            // rows. The blobs come last, so reading the other columns does not
            // walk their overflow pages.
            try db.execute(sql: """
                CREATE TABLE root (
                    id INTEGER PRIMARY KEY,
                    path TEXT NOT NULL UNIQUE,
                    version INTEGER
                );
                CREATE TABLE event (
                    rootID INTEGER NOT NULL REFERENCES root(id),
                    day TEXT NOT NULL,
                    name TEXT NOT NULL,
                    mtime INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    source TEXT,
                    pid INTEGER,
                    ts REAL,
                    blockName TEXT,
                    revision INTEGER,
                    exclusions TEXT,
                    format INTEGER,
                    result BLOB,
                    payload BLOB,
                    PRIMARY KEY (rootID, day, name)
                );
                CREATE INDEX event_order ON event (mtime, name);
                """)
            // Per root and source, the mapping (`SourceState`) the rows of
            // files still in the spool were last brought up to; the set of a
            // root is the documents its last complete re-map was given. An
            // ingest whose mapping differs, a source more or less included,
            // looks for the rows it would change.
            try db.execute(sql: """
                CREATE TABLE source_state (
                    rootID INTEGER NOT NULL REFERENCES root(id) ON DELETE CASCADE,
                    source TEXT NOT NULL,
                    revision INTEGER,
                    exclusions TEXT NOT NULL,
                    format INTEGER NOT NULL,
                    PRIMARY KEY (rootID, source)
                );
                """)
        }
        migrator.registerMigration("v2") { db in
            // The envelope's `terminal` (`Envelope.terminal`): a JSON object of
            // its entries with sorted keys, null when it has none and for
            // failed rows. `ADD COLUMN` puts it after the blobs, which costs
            // nothing: the readers that need it, `replay` and `staleRows`,
            // read `result` or `payload` anyway. Rows stored before have
            // none, like an envelope without `terminal`.
            try db.execute(sql: "ALTER TABLE event ADD COLUMN terminal TEXT")
        }
        return migrator
    }

    // MARK: Ingest

    /// Above this many rows written by one ingest, the ingest truncates the
    /// WAL afterwards. SQLite's automatic checkpoints keep the WAL from
    /// growing past about 4 MB between transactions but never shrink the
    /// file, so a first ingest of a full spool (one transaction, tens of MB)
    /// would leave a WAL as large as the database. A thousand rows are a few
    /// MB, about what the automatic checkpoints keep anyway, so smaller
    /// ingests, the steady state of a few files per watcher event, skip the
    /// extra checkpoint.
    static let checkpointThreshold = 1000

    /// Stores the spool files of `root` the store doesn't know yet and returns
    /// their events, and apart from them the events of known files a mapping
    /// change re-mapped (`IngestResult`). The app calls it with what its
    /// `DirectoryWatching` reports for `root` and its current documents; the
    /// store lists the spool itself and remembers in its database what it has.
    ///
    /// `changed` is what the watcher reported, directories and files, as for
    /// `SpoolScanner.scan(changed:)`. An event file is looked up by its key
    /// and read only if unknown, without listing its day: a busy day holds
    /// thousands of files, and a watcher that reports files
    /// (`FSEventsWatcher(fileEvents: true)`) makes an ingest cost what is new,
    /// not what the day holds. A reported file that is gone is no error. A
    /// day folder lists only that day; in it only `*.json` names not starting
    /// with a dot count, other names and a directory of such a name are
    /// ignored. Files being written (dot-names),
    /// `schema/` or `model/`, and any other file outside a day folder (such
    /// as `plugin.json`), which hold no events, are ignored. Any other
    /// directory, or nil (at start, or when the watcher lost track), lists
    /// every day, and so does the first ingest of `root`, whatever `changed`
    /// holds. Known files are not opened; neither are files older than
    /// `maxAge` before `now`, which are not stored either. The rest are read,
    /// parsed and mapped in parallel and stored in one transaction.
    ///
    /// When the mapping changed since the last ingest of `root` (a source's
    /// document has a higher revision, its `excluding` set differs, the
    /// interpreter's format changed, a source gained or lost its document, a
    /// source was added to or left out of `documents`, or the package reads
    /// another envelope version), the ingest looks up the rows the new mapping
    /// would change in its database, in every day, and replaces them; it lists
    /// no more days for that. Mapped rows of a lower revision, other exclusions
    /// or another format are read again from their spool file: only their
    /// result is stored, so one whose file left the spool keeps what it has.
    /// Whole and foreign rows whose source now has a document, and foreign
    /// rows whose source is now among `documents` at all, are mapped from the
    /// payload they keep, whether their file is still in the spool or not.
    /// Failed rows are read again from their spool file, if it is still there,
    /// when the envelope version changed. Re-mapped rows come back under
    /// `remapped`; a formerly failed file that is now a valid envelope comes
    /// under `new`, since the app was never given it. A source whose document
    /// is now nil or that is no longer among `documents` leaves its rows as
    /// they are, and so do rows older than `maxAge`: `prune` removes them.
    ///
    /// `documents` is as for `SpoolFile.parsed(from:documents:)`. `excluding`
    /// names fields per source that are dropped from the core and block of
    /// mapped results before they are stored, e.g. large ones the app never
    /// reads. Files that were read but are not a valid envelope are logged and
    /// remembered as known, but not returned. Files that could not be read
    /// are logged and left unknown, and the next ingest retries them, reported
    /// or not: it lists their day again, or, for a reported file, looks at the
    /// file again. A known file to re-map that could not be read keeps its
    /// row, and the next ingest reads it again.
    ///
    /// Everything from reading what the store has of `root` to storing the
    /// new rows is one write transaction, so the ingest decides on the state
    /// it changes. It holds SQLite's write lock while it reads files, a second
    /// or two for a first ingest of a full spool: other ingests and prunes on
    /// the file wait for it, `replay` doesn't. An ingest that throws, whatever
    /// failed (the database, waiting for the lock, a cancellation before or
    /// during its transaction), has stored nothing, and the next ingest of
    /// `root` looks at what this one was told to, reported again or not.
    public func ingest(
        root: URL,
        changed: Set<URL>?,
        documents: [SourceID: MappingDocument?],
        excluding: [SourceID: Set<String>] = [:],
        now: Date = Date()
    ) async throws -> IngestResult {
        let rootPath = root.standardizedFileURL.path
        // The reported days and files are pending before the write is
        // queued, not once it failed: an ingest that decides after this call
        // looks at them too, whether this one fails, is cancelled or
        // succeeds, so a failure doesn't leave them to the ingest after that one.
        pending.withLock { $0.add(SpoolListing.report(changed: changed), root: rootPath) }
        let outcome = try await database.writeWithoutTransaction { db in
            var outcome: IngestOutcome?
            // IMMEDIATE takes the write lock at BEGIN, before the ingest
            // reads anything, so no other writer changes what it decides
            // on. GRDB's `write` would pick IMMEDIATE for a writable
            // connection as well, but only implicitly.
            try db.inTransaction(.immediate) {
                outcome = try self.ingest(db, rootPath: rootPath, changed: changed, documents: documents,
                                          excluding: excluding, now: now)
                return .commit
            }
            // Committed, and still on the writer's queue: the next ingest of
            // this instance decides after this.
            self.pending.withLock { $0.settle(outcome!.listed, unreadable: outcome!.unreadable, root: rootPath) }
            return outcome!
        }
        if outcome.written > Self.checkpointThreshold { await truncateLog() }
        return outcome.result
    }

    /// The transaction of `ingest`: decides which days to list, finds the
    /// rows to re-map, reads the unknown and stale files and stores them and
    /// the mapping state.
    private func ingest(
        _ db: Database, rootPath: String, changed: Set<URL>?, documents: [SourceID: MappingDocument?],
        excluding: [SourceID: Set<String>], now: Date
    ) throws -> IngestOutcome {
        // Built from the stored path as `replay` builds it, so the events of
        // both have equal roots whichever form of the URL the app passed.
        let rootURL = Self.rootURL(path: rootPath)
        let fingerprints = excluding.mapValues(Self.fingerprint)
        let mapping = MappingState(
            sources: documents.reduce(into: [:]) { states, entry in
                states[entry.key] = SourceState(document: entry.value, exclusions: fingerprints[entry.key] ?? Self.fingerprint([]))
            },
            version: Int64(envelopeVersion))
        let cutoff = maxAge.map { Self.cutoff(maxAge: $0, now: now) }
        let rootID = try Self.rootID(db, path: rootPath)
        let previous = try rootID.flatMap { try Self.mappingState(db, rootID: $0) }
        let remap = previous != mapping
        // A re-map finds its rows in the database, so only a root without a
        // recorded mapping, never ingested, needs every day listed.
        //
        // The pending days and files are taken before listing, and each is
        // looked at below, so a file reported before this, or in a day
        // reported before this, was there to be seen. A report made after it
        // stays pending for the next ingest.
        let listed = pending.withLock { $0.snapshot(root: rootPath) }
        let days: Set<String>
        var files: [FileKey] = []
        if previous != nil, listed.everyDay == nil, let reported = SpoolListing.report(changed: changed) {
            days = reported.days.union(listed.days.keys)
            for (day, names) in reported.files.merging(listed.files.mapValues { Set($0.keys) }, uniquingKeysWith: { $0.union($1) })
            where !days.contains(day) {
                files += names.map { FileKey(day: day, name: $0) }
            }
        } else {
            days = Set(SpoolListing.days(in: rootURL))
        }

        var known: [String: Set<String>] = [:]
        var stale = StaleRows()
        if let rootID {
            let names = try db.cachedStatement(sql: "SELECT name FROM event WHERE rootID = ? AND day = ?")
            for day in days {
                let rows = try String.fetchCursor(names, arguments: [rootID, day])
                while let name = try rows.next() { known[day, default: []].insert(name) }
            }
            // A primary-key lookup per reported file instead of the names of
            // its day, which grow with every event of a busy day.
            let row = try db.cachedStatement(sql: "SELECT 1 FROM event WHERE rootID = ? AND day = ? AND name = ?")
            files = try files.filter { try Int.fetchOne(row, arguments: [rootID, $0.day, $0.name]) == nil }
            if remap {
                stale = try Self.staleRows(db, rootID: rootID, documents: documents, fingerprints: fingerprints,
                                           versionChanged: previous?.version != mapping.version, cutoff: cutoff ?? .min)
            }
        }
        var reads: [SpoolRead] = []
        for day in days {
            for name in SpoolListing.entries(in: rootURL, day: day) where known[day]?.contains(name) != true {
                let file = SpoolListing.file(in: rootURL, day: day, name: name)
                if !SpoolListing.isDirectory(file) { reads.append(SpoolRead(file: file, existing: nil)) }
            }
        }
        for key in files {
            let file = SpoolListing.file(in: rootURL, day: key.day, name: key.name)
            // A reported file may be gone already, e.g. with its day folder
            // (contract §5), or never have been one: nothing to retry.
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                reads.append(SpoolRead(file: file, existing: nil))
            }
        }
        // Straight at their place in the spool: the query gave their day and
        // name, so no day is listed for them.
        for (key, kind) in stale.files {
            reads.append(SpoolRead(file: SpoolListing.file(in: rootURL, day: key.day, name: key.name), existing: kind))
        }

        // On the writer's queue, not a cooperative thread: blocking it while
        // the files are read is fine.
        let outcomes: [ReadOutcome] = reads.blockingConcurrentMap { read -> ReadOutcome in
            let file = read.file
            // A known file that left the spool keeps its row. Its age was
            // checked by the query, against the same cutoff.
            if read.existing != nil, !FileManager.default.fileExists(atPath: file.path) { return .skipped }
            let mtime = SpoolScanner.mtimeNanoseconds(file)
            if let cutoff, mtime < cutoff { return .skipped }
            let key = FileKey(file)
            // A read error may pass (too many open files, an interrupted
            // read), so the file stays unknown and the next ingest retries it.
            // One that vanished is not listed again.
            let data: Data
            do {
                data = try self.readFile(file)
            } catch {
                if self.loggedUnreadable.withLock({ $0.insert(file.path).inserted }) {
                    Self.log.error("Could not read spool file \(file.path, privacy: .public): \(String(describing: error), privacy: .public)")
                } else {
                    Self.log.debug("Still cannot read spool file \(file.path, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                return .unreadable(key, existing: read.existing)
            }
            self.loggedUnreadable.withLock { _ = $0.remove(file.path) }
            let parsed = SpoolFile.parsed(from: data, documents: documents, version: self.envelopeVersion)
            if case let .failed(error) = parsed {
                Self.log.error("Skipping unreadable spool file \(file.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            return .record(Record(root: rootURL, day: key.day, name: key.name, mtime: mtime, parsed: parsed,
                                  existing: read.existing, documents: documents, excluding: excluding,
                                  fingerprints: fingerprints))
        }
        var records = stale.payloads.blockingConcurrentMap { stored in
            stored.record(root: rootURL, documents: documents, excluding: excluding, fingerprints: fingerprints)
        }.compactMap { $0 }
        var unreadable = SpoolListing.Report()
        // Whether every stale row was brought up to `mapping`. A known file
        // that could not be read is not: the mapping state stays as it was, so
        // the next ingest's query finds the file again, without listing its day.
        var complete = true
        for outcome in outcomes {
            switch outcome {
            case let .record(record): records.append(record)
            case let .unreadable(key, existing):
                // Retried as it was found: a listed day is listed again, a
                // reported file looked at again, without listing its day.
                if existing != nil {
                    complete = false
                } else if days.contains(key.day) {
                    unreadable.days.insert(key.day)
                } else {
                    unreadable.files[key.day, default: []].insert(key.name)
                }
            case .skipped: break
            }
        }
        var outcome = IngestOutcome(listed: listed, unreadable: unreadable)
        guard !records.isEmpty || remap else { return outcome }

        let id: Int64
        if let rootID {
            id = rootID
        } else {
            try db.execute(sql: "INSERT INTO root (path) VALUES (?)", arguments: [rootPath])
            id = db.lastInsertedRowID
        }
        let insert = try db.cachedStatement(sql: """
            INSERT INTO event
                (rootID, day, name, mtime, kind, source, pid, ts, blockName, revision, exclusions, format, result, payload,
                 terminal)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        // A re-read file's mtime comes from the current stat, not the row; the
        // two agree, since the plugin writes a spool file once, by renaming it
        // into place, and never touches it again (contract §4).
        let replace = try db.cachedStatement(sql: """
            UPDATE event SET mtime = ?, kind = ?, source = ?, pid = ?, ts = ?, blockName = ?, revision = ?,
                exclusions = ?, format = ?, result = ?, payload = ?, terminal = ?
            WHERE rootID = ? AND day = ? AND name = ?
            """)
        var new: [StoredEvent] = []
        var remapped: [StoredEvent] = []
        for record in records {
            if let existing = record.existing {
                // A file that no longer parses, or still doesn't, keeps the
                // row it has.
                guard let event = record.event else { continue }
                try replace.execute(arguments: record.columns + [id, record.day, record.name])
                // A failed file was never returned: the app gets it as new.
                if existing == .failed { new.append(event) } else { remapped.append(event) }
            } else {
                try insert.execute(arguments: [id, record.day, record.name] + record.columns)
                if let event = record.event { new.append(event) }
            }
            outcome.written += 1
        }
        try Self.recordMapping(db, rootID: id, mapping: mapping, previous: previous, complete: complete)
        Self.log.debug("Stored \(outcome.written, privacy: .public) spool files of \(rootPath, privacy: .public)")
        let order = { (a: StoredEvent, b: StoredEvent) in (a.mtime, a.name) < (b.mtime, b.name) }
        outcome.result = IngestResult(new: new.sorted(by: order), remapped: remapped.sorted(by: order))
        return outcome
    }

    /// The URL of a stored root path, the same for `ingest` and `replay`.
    private static func rootURL(path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func rootID(_ db: Database, path: String) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT id FROM root WHERE path = ?", arguments: [path])
    }

    /// The recorded mapping state of a root, or nil if none is recorded, so
    /// that any mapping differs from it.
    private static func mappingState(_ db: Database, rootID: Int64) throws -> MappingState? {
        // Null until the first state is recorded.
        guard let version = try Int64.fetchOne(db, sql: "SELECT version FROM root WHERE id = ?", arguments: [rootID]) else {
            return nil
        }
        var sources: [SourceID: SourceState] = [:]
        let rows = try Row.fetchCursor(db, sql: """
            SELECT source, revision, exclusions, format FROM source_state WHERE rootID = ?
            """, arguments: [rootID])
        while let row = try rows.next() {
            sources[SourceID(rawValue: row[0])] = SourceState(revision: row[1], exclusions: row[2], format: row[3])
        }
        return MappingState(sources: sources, version: version)
    }

    /// Notes that the root's rows are up to date with `mapping`, inside the
    /// ingest's transaction, if they changed from `previous` and the re-map
    /// is `complete`. A stale file that could not be read keeps its old row,
    /// so the state stays as it was and the next ingest looks for stale rows
    /// again. The root's whole set is replaced: a source left out of
    /// `mapping` loses its state, so the ingest that gives it again re-maps
    /// its rows.
    private static func recordMapping(_ db: Database, rootID: Int64, mapping: MappingState,
                                      previous: MappingState?, complete: Bool) throws {
        guard complete, previous != mapping else { return }
        try db.execute(sql: "DELETE FROM source_state WHERE rootID = ?", arguments: [rootID])
        try db.execute(sql: "UPDATE root SET version = ? WHERE id = ?", arguments: [mapping.version, rootID])
        for (source, state) in mapping.sources {
            try db.execute(sql: """
                INSERT INTO source_state (rootID, source, revision, exclusions, format) VALUES (?, ?, ?, ?, ?)
                """, arguments: [rootID, source.rawValue, state.revision, state.exclusions, state.format])
        }
    }

    /// The rows of a root that the mapping of `ingest` would change: per
    /// source in `documents`, mapped rows to read again and whole and foreign
    /// rows to map from their payload, and, if `versionChanged`, failed rows
    /// to read again. Rows whose file is older than `cutoff` are left to
    /// `prune`. A whole row may come back here after its re-map when its
    /// stored payload can't be parsed; a valid store has none.
    private static func staleRows(_ db: Database, rootID: Int64, documents: [SourceID: MappingDocument?],
                                  fingerprints: [SourceID: String], versionChanged: Bool, cutoff: Int64) throws -> StaleRows {
        var stale = StaleRows()
        let columns = "day, name, kind, mtime, pid, ts, payload, terminal"
        for (source, document) in documents {
            let rows: RowCursor
            if let document {
                // A missing revision counts as 0, as in `MappingLoader`.
                rows = try Row.fetchCursor(db, sql: """
                    SELECT \(columns) FROM event WHERE rootID = ? AND source = ? AND mtime >= ? AND (
                        kind IN ('whole', 'foreign')
                        OR (kind = 'mapped' AND (IFNULL(revision, 0) < ? OR exclusions IS NOT ? OR format IS NOT ?)))
                    """, arguments: [rootID, source.rawValue, cutoff, document.revision ?? 0,
                                     fingerprints[source] ?? fingerprint([]), MappingInterpreter.supportedFormat])
            } else {
                rows = try Row.fetchCursor(db, sql: """
                    SELECT \(columns) FROM event WHERE rootID = ? AND source = ? AND mtime >= ? AND kind = 'foreign'
                    """, arguments: [rootID, source.rawValue, cutoff])
            }
            while let row = try rows.next() {
                let key = FileKey(day: row["day"], name: row["name"])
                switch Kind(rawValue: row["kind"]) {
                case .mapped:
                    stale.files[key] = .mapped
                case let kind?:
                    stale.payloads.append(StoredPayload(
                        key: key, kind: kind, mtime: row["mtime"], source: source, pid: row["pid"], ts: row["ts"],
                        payload: row["payload"], terminal: row["terminal"]))
                case nil:
                    break
                }
            }
        }
        if versionChanged {
            let rows = try Row.fetchCursor(db, sql: """
                SELECT day, name FROM event WHERE rootID = ? AND mtime >= ? AND kind = 'failed'
                """, arguments: [rootID, cutoff])
            while let row = try rows.next() { stale.files[FileKey(day: row["day"], name: row["name"])] = .failed }
        }
        return stale
    }

    /// Shrinks the WAL back to nothing. Best effort: if a reader holds an old
    /// snapshot, the checkpoint gives up at once, and the next large ingest
    /// tries again.
    private func truncateLog() async {
        do {
            try await database.writeWithoutTransaction { db in
                // The checkpoint waits for readers through the busy handler,
                // which would hold the writer queue, and so this instance's
                // next ingests, for up to the busy timeout. Set on the
                // writer's queue, so no other statement of this instance's
                // writer runs while it is on; `defer` resets it whether the
                // checkpoint throws or the task was cancelled.
                self.checkpointing.withLock { $0 = true }
                defer { self.checkpointing.withLock { $0 = false } }
                _ = try db.checkpoint(.truncate)
            }
        } catch {
            Self.log.debug("Could not truncate the event store's WAL: \(String(describing: error), privacy: .public)")
        }
    }

    /// The oldest mtime, in nanoseconds, that `maxAge` before `now` keeps;
    /// ingest and prune draw the same line.
    private static func cutoff(maxAge: TimeInterval, now: Date) -> Int64 {
        Int64(((now.timeIntervalSince1970 - maxAge) * 1e9).rounded(.down))
    }

    /// A deterministic text for a set of excluded field names: equal sets give
    /// equal texts, so a changed set shows in the stored rows.
    static func fingerprint(_ fields: Set<String>) -> String {
        let sorted = fields.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        return String(decoding: JSONValue.array(sorted.map(JSONValue.string)).serialized(), as: UTF8.self)
    }

    /// The `terminal` column of an envelope's entries, see the `v2` migration.
    static func terminalColumn(_ terminal: [String: String]) -> String? {
        guard !terminal.isEmpty else { return nil }
        let members = terminal.reduce(into: [JSONKey: JSONValue]()) { $0[JSONKey($1.key)] = .string($1.value) }
        return String(decoding: JSONValue.object(members).serialized(), as: UTF8.self)
    }

    /// The entries of a row's `terminal` column, none for null. A column that
    /// is not a JSON object of strings, which the store never writes, is
    /// logged and gives none as well: the identifiers are a hint, so the
    /// event is kept without them.
    static func terminal(column: String?, day: String, name: String) -> [String: String] {
        guard let column else { return [:] }
        guard case let .object(members)? = try? JSONValue(data: Data(column.utf8)),
              members.values.allSatisfy({ if case .string = $0 { true } else { false } }) else {
            log.error("Ignoring the undecodable terminal of stored event \(day, privacy: .public)/\(name, privacy: .public)")
            return [:]
        }
        var terminal: [String: String] = [:]
        for case let (key, .string(string)) in members { terminal[key.string] = string }
        return terminal
    }

    // MARK: Prune

    /// Deletes every row, of any kind, whose file's mtime lies more than
    /// `maxAge` before `now`, and roots left without rows, in one transaction;
    /// returns how many rows went. The app's own retention: nothing else
    /// deletes rows, and with `maxAge` nil nothing is deleted. `ingest` skips
    /// files older than the same `maxAge`, so a pruned file still in the spool
    /// does not come back.
    public func prune(now: Date = Date()) async throws -> Int {
        guard let maxAge else { return 0 }
        let cutoff = Self.cutoff(maxAge: maxAge, now: now)
        let deleted = try await database.write { db in
            try db.execute(sql: "DELETE FROM event WHERE mtime < ?", arguments: [cutoff])
            let deleted = db.changesCount
            try db.execute(sql: "DELETE FROM root WHERE NOT EXISTS (SELECT 1 FROM event WHERE rootID = root.id)")
            return deleted
        }
        Self.log.debug("Pruned \(deleted, privacy: .public) stored events")
        return deleted
    }

    // MARK: Replay

    /// Every stored event of all roots, in the contract's order (mtime, then
    /// name), without failed files. The warm-start path: no file is read and
    /// nothing is mapped; results are decoded in parallel.
    ///
    /// It returns what the ingests committed before it began reading. At
    /// start, call it before any `ingest`, then `ingest(changed: nil)` per
    /// root, then the ingests the watcher triggers: an ingest that commits
    /// before this replay begins reading returns events the replay returns
    /// too, so an app that must not get an event twice doesn't run one
    /// alongside its start replay.
    public func replay() async throws -> [StoredEvent] {
        let rows = try await database.read { db in
            var roots: [String: URL] = [:]
            var rows: [StoredRow] = []
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT root.path, day, name, mtime, kind, source, pid, ts, blockName, result, payload, terminal
                FROM event JOIN root ON root.id = event.rootID
                WHERE kind != 'failed'
                ORDER BY mtime, name, root.path, day
                """)
            while let row = try cursor.next() {
                let rootPath: String = row[0]
                let root = roots[rootPath] ?? Self.rootURL(path: rootPath)
                roots[rootPath] = root
                rows.append(StoredRow(
                    root: root, day: row[1], name: row[2], mtime: row[3], kind: row[4], source: row[5],
                    pid: row[6], ts: row[7], blockName: row[8], result: row[9], payload: row[10], terminal: row[11]))
            }
            return rows
        }
        return await rows.concurrentMap { $0.event }.compactMap { $0 }
    }
}

// MARK: - Rows

/// A file's key within one root.
private struct FileKey: Hashable, Sendable {
    let day: String
    let name: String

    init(day: String, name: String) {
        self.day = day
        self.name = name
    }

    init(_ file: URL) {
        self.init(day: file.deletingLastPathComponent().lastPathComponent, name: file.lastPathComponent)
    }
}

/// What a root's rows were last brought up to: every source's mapping and the
/// envelope version its files were read with.
private struct MappingState: Equatable {
    let sources: [SourceID: SourceState]
    /// `SpoolFile.version` of the reading package; a file failed under one
    /// version may be valid under the next.
    let version: Int64
}

/// A source's mapping as far as stored rows depend on it.
private struct SourceState: Equatable {
    /// The document's revision, a missing one as 0, as in `MappingLoader`;
    /// nil for a source without a document.
    let revision: Int64?
    /// `EventStore.fingerprint` of the source's excluded fields.
    let exclusions: String
    let format: Int64

    init(revision: Int64?, exclusions: String, format: Int64) {
        self.revision = revision
        self.exclusions = exclusions
        self.format = format
    }

    init(document: MappingDocument?, exclusions: String) {
        self.init(revision: document.map { $0.revision ?? 0 }, exclusions: exclusions,
                  format: MappingInterpreter.supportedFormat)
    }
}

/// What one ingest listed and stored, for the bookkeeping after its commit.
private struct IngestOutcome: Sendable {
    /// What was pending when the ingest decided, all of which it looked at.
    let listed: PendingListings.Snapshot
    /// Listed days holding a file that could not be read, and reported
    /// files outside them that could not be read.
    let unreadable: SpoolListing.Report
    var result = IngestResult(new: [], remapped: [])
    /// Rows inserted or replaced.
    var written = 0

    init(listed: PendingListings.Snapshot, unreadable: SpoolListing.Report) {
        self.listed = listed
        self.unreadable = unreadable
    }
}

/// Per root path, the days ingests have yet to list, the reported files they
/// have yet to look at, and whether to list every day. Each addition is
/// numbered, so an ingest's success clears only the additions it saw when it
/// decided: one made while its transaction ran, even for a day it was
/// listing anyway, may name a file it listed too early to see, and stays for
/// the next ingest. A pending file is looked at alone, never by listing its
/// day, which is what reporting files saves.
private struct PendingListings {
    struct Snapshot: Sendable {
        /// Day folder names, each with the number of its latest addition.
        var days: [String: UInt64] = [:]
        /// Event file names per day folder, each with the number of its
        /// latest addition.
        var files: [String: [String: UInt64]] = [:]
        /// The number of the latest every-day addition, if any.
        var everyDay: UInt64?

        var isEmpty: Bool { days.isEmpty && files.isEmpty && everyDay == nil }
    }

    private var counter: UInt64 = 0
    private var roots: [String: Snapshot] = [:]

    /// `report` nil adds every day.
    mutating func add(_ report: SpoolListing.Report?, root: String) {
        counter += 1
        if let report {
            for day in report.days { roots[root, default: Snapshot()].days[day] = counter }
            for (day, names) in report.files {
                for name in names { roots[root, default: Snapshot()].files[day, default: [:]][name] = counter }
            }
        } else {
            roots[root, default: Snapshot()].everyDay = counter
        }
    }

    func snapshot(root: String) -> Snapshot { roots[root] ?? Snapshot() }

    /// After a committed ingest that decided on `listed`: what it saw is
    /// done, unless added again since; its days and files with a file that
    /// could not be read are looked at again by the next ingest.
    mutating func settle(_ listed: Snapshot, unreadable: SpoolListing.Report, root: String) {
        if var current = roots[root] {
            for (day, number) in listed.days where current.days[day] == number { current.days[day] = nil }
            for (day, names) in listed.files {
                for (name, number) in names where current.files[day]?[name] == number { current.files[day]?[name] = nil }
                if current.files[day]?.isEmpty == true { current.files[day] = nil }
            }
            if let number = listed.everyDay, current.everyDay == number { current.everyDay = nil }
            roots[root] = current.isEmpty ? nil : current
        }
        if unreadable != SpoolListing.Report() { add(unreadable, root: root) }
    }
}

/// The rows `ingest` re-maps, see `EventStore.staleRows`.
private struct StaleRows {
    /// Mapped and failed rows, read again from their file.
    var files: [FileKey: EventStore.Kind] = [:]
    /// Whole and foreign rows, mapped from the payload they keep.
    var payloads: [StoredPayload] = []
}

/// A spool file to read: an unknown one, or a known one to re-map.
private struct SpoolRead: Sendable {
    let file: URL
    /// The kind of the row the file replaces; nil for an unknown file.
    let existing: EventStore.Kind?
}

/// What reading one file came to.
private enum ReadOutcome: Sendable {
    case record(Record)
    /// The file could not be read; `existing` as for its `SpoolRead`.
    case unreadable(FileKey, existing: EventStore.Kind?)
    /// Older than the ingest's max age, or a known file that left the spool.
    case skipped
}

/// A whole or foreign row with what its event needs, to map from its payload.
private struct StoredPayload: Sendable {
    let key: FileKey
    let kind: EventStore.Kind
    let mtime: Int64
    let source: SourceID
    let pid: Int32?
    let ts: Double
    let payload: Data?
    /// The raw `terminal` column, decoded with the row.
    let terminal: String?

    /// The row mapped with `documents`, or nil, logged, for a payload that
    /// doesn't parse, which keeps its row. The stored payload is the parse's
    /// own serialization (`SpoolFile.envelope(from:)`), so it parses to the
    /// value the file's parse gave, and the mapping, which reads the payload
    /// only, gives what it would give for the file.
    func record(root: URL, documents: [SourceID: MappingDocument?], excluding: [SourceID: Set<String>],
                fingerprints: [SourceID: String]) -> Record? {
        guard let payload, let value = try? JSONValue(data: payload) else {
            EventStore.log.error("Cannot map the stored payload of \(key.day, privacy: .public)/\(key.name, privacy: .public)")
            return nil
        }
        let envelope = Envelope(source: source, pid: pid, payload: payload, receivedAt: Date(timeIntervalSince1970: ts),
                                terminal: EventStore.terminal(column: terminal, day: key.day, name: key.name))
        return Record(root: root, day: key.day, name: key.name, mtime: mtime,
                      parsed: SpoolFile.parsed(envelope, payload: value, documents: documents), existing: kind,
                      documents: documents, excluding: excluding, fingerprints: fingerprints)
    }
}

/// One file ready to insert, or to replace a known row, with the event an
/// ingest returns for it.
private struct Record: Sendable {
    let day: String
    let name: String
    let mtime: Int64
    let kind: EventStore.Kind
    let revision: Int64?
    let result: Data?
    let exclusions: String?
    /// Nil for a failed file.
    let event: StoredEvent?
    /// The kind of the known row this replaces; nil for an unknown file,
    /// whose row is inserted.
    let existing: EventStore.Kind?

    init(root: URL, day: String, name: String, mtime: Int64, parsed: ParsedSpoolFile, existing: EventStore.Kind?,
         documents: [SourceID: MappingDocument?], excluding: [SourceID: Set<String>], fingerprints: [SourceID: String]) {
        self.existing = existing
        self.day = day
        self.name = name
        self.mtime = mtime
        let envelope: Envelope
        let content: StoredEvent.Content
        switch parsed {
        case .mapped(let parsedEnvelope, var mapped):
            for field in excluding[parsedEnvelope.source] ?? [] {
                mapped.core[JSONKey(field)] = nil
                mapped.block[JSONKey(field)] = nil
            }
            kind = .mapped
            revision = (documents[parsedEnvelope.source] ?? nil)?.revision
            result = mapped.jsonValue.serialized()
            exclusions = fingerprints[parsedEnvelope.source] ?? EventStore.fingerprint([])
            envelope = parsedEnvelope
            content = .mapped(mapped)
        case let .whole(parsedEnvelope):
            (kind, revision, result, exclusions) = (.whole, nil, nil, nil)
            envelope = parsedEnvelope
            content = .whole(parsedEnvelope.payload)
        case let .foreign(parsedEnvelope):
            (kind, revision, result, exclusions) = (.foreign, nil, nil, nil)
            envelope = parsedEnvelope
            content = .foreign(parsedEnvelope.payload)
        case .failed:
            (kind, revision, result, exclusions, event) = (.failed, nil, nil, nil, nil)
            return
        }
        event = StoredEvent(root: root, day: day, name: name, mtime: mtime, source: envelope.source, pid: envelope.pid,
                            receivedAt: envelope.receivedAt, terminal: envelope.terminal, content: content)
    }

    /// The row's columns after its key, in the order of the insert and update.
    var columns: StatementArguments {
        var payload: Data?
        if case let .whole(bytes)? = event?.content { payload = bytes }
        if case let .foreign(bytes)? = event?.content { payload = bytes }
        let blockName: String?
        if case let .mapped(result)? = event?.content { blockName = result.blockName } else { blockName = nil }
        let format = kind == .mapped ? MappingInterpreter.supportedFormat : nil
        return [mtime, kind.rawValue, event?.source.rawValue, event?.pid, event?.receivedAt.timeIntervalSince1970,
                blockName, revision, exclusions, format, result, payload,
                event.flatMap { EventStore.terminalColumn($0.terminal) }]
    }
}

/// A row's raw columns, fetched in one pass and decoded outside the database.
private struct StoredRow: Sendable {
    let root: URL
    let day: String
    let name: String
    let mtime: Int64
    let kind: String
    let source: String
    let pid: Int32?
    let ts: Double
    let blockName: String?
    let result: Data?
    let payload: Data?
    let terminal: String?

    /// Nil, logged, for a row that doesn't decode; a valid store has none.
    var event: StoredEvent? {
        let content: StoredEvent.Content
        switch EventStore.Kind(rawValue: kind) {
        case .mapped:
            // With the results' own limit: a result can be deeper than the
            // spool file it was mapped from.
            guard let result, let blockName, let value = try? JSONReader.read(result, maxDepth: MappingResult.maxDepth),
                  let mapped = MappingResult(jsonValue: value, blockName: blockName) else { return undecodable() }
            content = .mapped(mapped)
        case .whole:
            guard let payload else { return undecodable() }
            content = .whole(payload)
        case .foreign:
            guard let payload else { return undecodable() }
            content = .foreign(payload)
        case .failed, nil:
            return undecodable()
        }
        return StoredEvent(root: root, day: day, name: name, mtime: mtime, source: SourceID(rawValue: source), pid: pid,
                           receivedAt: Date(timeIntervalSince1970: ts),
                           terminal: EventStore.terminal(column: terminal, day: day, name: name), content: content)
    }

    private func undecodable() -> StoredEvent? {
        EventStore.log.error("Skipping undecodable stored event \(day, privacy: .public)/\(name, privacy: .public)")
        return nil
    }
}
