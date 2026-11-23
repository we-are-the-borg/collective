import Foundation
import os
import SubspaceKit

/// Reports whether Claude Code sessions are working, waiting or idle, from the
/// session status files Claude Code keeps in `<config dir>/sessions/<pid>.json`
/// (subspace contract §13). Hooks miss an interrupt (Esc, Ctrl-C); these files
/// flip to `idle` right away. The files also carry the session's name, which
/// the user can change with `/rename`, and the process's kind: only an
/// interactive process's hooks see the session's own terminal (contract §6,
/// "Terminal"); a `claude --bg` process's see the daemon's, which still names
/// the app. The file says which, and its end takes that back.
/// All events carry the file's `pid`, the `claude` process, which is also the
/// hooks' envelope pid: other processes write such files too, e.g. a daemon's
/// for a moment on `claude attach`, so the store takes a report only from the
/// session's own process.
/// A file marked `spare` belongs to a process Claude Code's daemon started
/// ahead of time for a job not yet given: it reports standby, whatever its
/// state, so its session stays hidden until a job claims the process.
///
/// The files are read only through the target fields of the
/// `claude-code-session` mapping document (`docs/model.md` §12), from the same
/// `$ROOT` as the hook mapping. A file is trusted only while its `pid` is alive
/// and not reused; otherwise nothing is reported but taking back a terminal it
/// reported, and without a known `state` no activity either: the store falls
/// back to its timeout. Like the spool reader, a missing folder is only checked
/// every `pollInterval`. The source never writes to the folder.
public actor ClaudeCodeSessionStatusSource: PullSource {
    public nonisolated let source: SourceID = sourceID
    public nonisolated let displayName = "Claude Code"
    public nonisolated let logoName: String? = "claude-code"
    nonisolated static let sourceID: SourceID = "claude-code"
    static let mappingName = "claude-code-session"
    /// Claude Code mostly writes in place, so a read can catch a half-written file.
    static let readAttempts = 3

    private let directory: URL
    private let mapping: MappingLoader
    private let watcher: any DirectoryWatching
    private let processStart: @Sendable (Int32) -> Date?
    private let pollInterval: Duration
    private let retryDelay: Duration
    private let log = Logger(subsystem: "CollectiveKit", category: "session-status")
    /// What was last reported per file name, so a rescan reports only changes.
    private var reported: [String: FileEvents] = [:]
    private var loggedNoMapping = false

    /// `chosenRoot` is the folder the user picked for the hook events; only the
    /// mapping comes from there.
    public init(
        chosenRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        watcher: any DirectoryWatching = FSEventsWatcher(),
        pollInterval: Duration = .seconds(5)
    ) {
        self.init(
            directory: Self.sessionsDirectory(environment: environment, home: home),
            mapping: ClaudeCodeAdapter.defaultMapping(chosen: chosenRoot, environment: environment, home: home),
            watcher: watcher,
            processStart: { ProcessStartTime.of($0) },
            pollInterval: pollInterval,
            retryDelay: .milliseconds(100)
        )
    }

    init(
        directory: URL,
        mapping: sending MappingLoader,
        watcher: any DirectoryWatching,
        processStart: @escaping @Sendable (Int32) -> Date?,
        pollInterval: Duration,
        retryDelay: Duration
    ) {
        self.directory = directory
        self.mapping = mapping
        self.watcher = watcher
        self.processStart = processStart
        self.pollInterval = pollInterval
        self.retryDelay = retryDelay
    }

    /// `sessions` in Claude Code's config folder (contract §13). Claude Code's
    /// own folder, so `SUBSPACE_DIR` doesn't move it.
    static func sessionsDirectory(environment: [String: String], home: URL) -> URL {
        ClaudeCodeAdapter.configDirectory(environment: environment, home: home)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Starts watching: first every file as one batch, then per change of the
    /// folder one batch with the files whose reported state changed. Scans
    /// without changes yield nothing. Ending the stream's iteration stops the
    /// source. Call once.
    public nonisolated func events() -> AsyncStream<[AgentEvent]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [AgentEvent].self)
        let task = Task { await self.watch(into: continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: Watching

    private func watch(into continuation: AsyncStream<[AgentEvent]>.Continuation) async {
        while !Task.isCancelled {
            guard Self.directoryExists(directory) else {
                try? await Task.sleep(for: pollInterval)
                continue
            }
            // Subscribe before scanning, so nothing written in between is missed.
            let changes = watcher.changes(under: directory)
            yield(await scan(), into: continuation)

            var vanished = false
            // The folder is small (one file per running `claude`), so any
            // change, and a lost track (`nil`) alike, rescans all of it.
            for await _ in changes {
                vanished = !Self.directoryExists(directory)
                if vanished { break }
                yield(await scan(), into: continuation)
            }
            // A watcher that ended on its own must not make this loop spin.
            if !vanished { try? await Task.sleep(for: .seconds(1)) }
        }
    }

    private func scan() async -> [AgentEvent] {
        guard let document = mapping.document(named: Self.mappingName) else {
            if !loggedNoMapping {
                loggedNoMapping = true
                log.error("No \(Self.mappingName, privacy: .public) mapping; session status not read")
            }
            return []
        }
        loggedNoMapping = false

        // `<pid>.json` only: the `<pid>.<hash>.key` files next to them are secrets.
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .sorted()
        var batch: [AgentEvent] = []
        // A process's file goes when it ends (contract §13, "Lifetime"); its
        // session may still show, e.g. until a late `SessionEnd`, but nothing
        // vouches for its terminal anymore.
        for (name, last) in reported where !names.contains(name) {
            if let withdrawal = Self.withdrawal(of: last) { batch.append(withdrawal) }
        }
        reported = reported.filter { names.contains($0.key) }

        for name in names {
            guard let json = await read(name) else { continue }
            let events = Self.events(from: json, mapping: document, processStart: processStart)
            let last = reported[name]
            if let activity = events.activity, last?.activity != activity { batch.append(activity) }
            // `updated_at` moves with any change of the file: only another name,
            // or the same one for another session, is news.
            if let named = events.name, last?.name?.session != named.session || last?.name?.kind != named.kind {
                batch.append(named)
            }
            // The kind is the process's for its lifetime: only another session is news.
            if let terminal = events.terminal, last?.terminal?.session != terminal.session || last?.terminal?.kind != terminal.kind {
                batch.append(terminal)
            }
            // After a crash the file stays (contract §13, "Lifetime") while its
            // pid is dead or reused: no more a voucher than a deleted file.
            if events.terminal == nil, let last, let withdrawal = Self.withdrawal(of: last) { batch.append(withdrawal) }
            reported[name] = events
        }
        return batch
    }

    /// The file's content, retried a few times while it doesn't parse; nil when
    /// it never did or is gone. Either way that is no change to report.
    private func read(_ name: String) async -> JSONValue? {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        for attempt in 1...Self.readAttempts {
            guard let data = try? Data(contentsOf: url) else { return nil }
            if let json = try? JSONValue(data: data), case .object = json { return json }
            if attempt < Self.readAttempts { try? await Task.sleep(for: retryDelay) }
        }
        log.error("Skipping unreadable \(url.path, privacy: .public)")
        return nil
    }

    /// Takes back what `last` reported about the terminal, as of the report;
    /// nil when it reported nothing usable.
    private static func withdrawal(of last: FileEvents) -> AgentEvent? {
        guard let reported = last.terminal, reported.kind != .terminalReported(.unusable) else { return nil }
        return AgentEvent(session: reported.session, timestamp: reported.timestamp,
                          kind: .terminalReported(.unusable), pid: reported.pid)
    }

    private func yield(_ batch: [AgentEvent], into continuation: AsyncStream<[AgentEvent]>.Continuation) {
        if !batch.isEmpty { continuation.yield(batch) }
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: One file

    /// What one status file stands for. Nothing when it can't be trusted: a
    /// field missing, or a `pid` that is dead or now belongs to a younger
    /// process (contract §13, `docs/model.md` §12.3).
    struct FileEvents: Equatable {
        /// Nil also while the file has no `state` yet, or an unknown one.
        var activity: AgentEvent?
        var name: AgentEvent?
        /// Whose the hooks' `terminal` is: the session's own only for an
        /// interactive process (contract §6, "Terminal"), the daemon's for
        /// a process of `claude --bg`.
        var terminal: AgentEvent?
    }

    /// The activity one status file reports; see `events(from:mapping:processStart:)`.
    static func event(from data: Data, mapping: MappingDocument, processStart: (Int32) -> Date?) -> AgentEvent? {
        events(from: data, mapping: mapping, processStart: processStart).activity
    }

    static func events(from data: Data, mapping: MappingDocument, processStart: (Int32) -> Date?) -> FileEvents {
        guard let json = try? JSONValue(data: data), case .object = json else { return FileEvents() }
        return events(from: json, mapping: mapping, processStart: processStart)
    }

    static func events(from json: JSONValue, mapping: MappingDocument, processStart: (Int32) -> Date?) -> FileEvents {
        let result = MappingInterpreter.apply(mapping, to: json)
        guard case let .string(session)? = result.core["session"], !session.isEmpty,
              case let .integer(pid)? = result.block["pid"], let pid = Int32(exactly: pid),
              case let .integer(startedAt)? = result.block["started_at"],
              let processStarted = processStart(pid),
              // The process starts just before it writes `startedAt`; one that
              // started later reuses the pid of a process that crashed.
              processStarted <= date(ms: startedAt).addingTimeInterval(2)
        else { return FileEvents() }
        let key = SessionKey(source: sourceID, sessionID: session)

        var events = FileEvents()
        let spare = result.block["spare"] == .bool(true)
        // A process of `claude --bg` or a spare runs under the daemon, whose
        // terminal its hooks see: of a job it still names the app the user
        // started it from, a spare is shown nowhere. The kind is the
        // process's from its start.
        let ownership: TerminalOwnership = switch (spare, result.block["process_kind"]) {
        case (false, .string("interactive")?): .session
        case (false, .string("bg")?): .host
        default: .unusable
        }
        events.terminal = AgentEvent(session: key, timestamp: date(ms: startedAt), kind: .terminalReported(ownership), pid: pid)
        if spare {
            // A spare is one from its process's start, so a file without a
            // status time yet still hides its session.
            let since: Int64 = if case let .integer(statusAt)? = result.block["status_at"] { statusAt } else { startedAt }
            events.activity = AgentEvent(session: key, timestamp: date(ms: since), kind: .activityReported(.standby), pid: pid)
        } else if case let .string(state)? = result.core["state"], let activity = activity(state, status: result.block["status"]),
           case let .integer(statusAt)? = result.block["status_at"] {
            events.activity = AgentEvent(session: key, timestamp: date(ms: statusAt), kind: .activityReported(activity), pid: pid)
        }
        // The name is there from the file's first version, before any state.
        // That version has no `updated_at` yet; it was written as the process started.
        if case let .string(name)? = result.block["name"], !name.isEmpty {
            let namedAt: Int64 = if case let .integer(updatedAt)? = result.block["updated_at"] { updatedAt } else { startedAt }
            events.name = AgentEvent(session: key, timestamp: date(ms: namedAt), kind: .sessionNamed(name), pid: pid)
        }
        return events
    }

    /// The mapping counts `shell` as `working`; only the raw `status` tells
    /// that the turn is over while a background shell runs.
    private static func activity(_ state: String, status: JSONValue?) -> SessionActivity? {
        if status == .string("shell") { return .backgroundShell }
        return switch state {
        case "working": .working
        case "waiting": .waiting
        case "idle": .idle
        default: nil
        }
    }

    private static func date(ms: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }
}
