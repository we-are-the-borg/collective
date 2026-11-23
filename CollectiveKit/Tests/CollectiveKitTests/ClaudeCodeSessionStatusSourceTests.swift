import Foundation
import SubspaceKit
import Synchronization
import Testing
@testable import CollectiveKit

// MARK: - Helpers

private let mapping = MappingLoader.bundledDocument(named: "claude-code-session")!

/// A process that started long before any status file, so the pid check passes.
private let alive: @Sendable (Int32) -> Date? = { _ in Date(timeIntervalSince1970: 0) }

private func date(ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

/// Status files carry their process. 3668 is the pid of the capture
/// `2-interrupt-mid-turn`, which the hand-built files share.
private let capturedPid: Int32 = 3668

private func named(_ session: String, _ name: String, at ms: Int64, pid: Int32 = capturedPid) -> AgentEvent {
    AgentEvent(session: SessionKey(source: "claude-code", sessionID: session), timestamp: date(ms: ms),
               kind: .sessionNamed(name), pid: pid)
}

/// A captured status file of Claude Code 2.1.287 (subspace `fixtures/`).
private func capturedStatus(_ run: String, _ file: String) throws -> Data {
    try Data(contentsOf: SubspaceDevRepo.root.appendingPathComponent("fixtures/claude-code/2.1.287/\(run)/status/\(file)"))
}

/// A status file of run 17 (2.1.289, interactive) or 22 (2.1.318, `claude --bg`),
/// copied into the test bundle.
private func capturedRun17(_ file: String) throws -> Data {
    try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/claude-code/2.1.289/17-model-clear/status/\(file)"))
}

private func capturedRun22(_ file: String) throws -> Data {
    try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/claude-code/2.1.318/22-background-terminal-env/status/\(file)"))
}

/// `data` with its top-level keys changed, for cases no capture shows.
private func edited(_ data: Data, _ changes: [String: Any]) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.merge(changes) { $1 }
    return try JSONSerialization.data(withJSONObject: object)
}

private let interrupted = "53d7703c-613e-4c00-b9ab-a400db09b847"

// MARK: - Seam 1: one status file → one event

/// The captured status files of Claude Code 2.1.287 (subspace `fixtures/`), checked
/// against the committed expectations of the same snapshot.
@Suite(.enabled(if: SubspaceDevRepo.isAvailable,
                "subspace dev repo not found (expected at ../../we-are-the-borg/subspace or $SUBSPACE_DEV_DIR); captured status files NOT checked"))
struct SessionStatusCaptureTests {
    private static let runs = [
        "2-interrupt-mid-turn", "3-interrupt-mid-tool", "4-waiting-permission-question", "6-background-subagents",
    ]

    private static func folder(_ run: String, _ name: String) -> URL {
        SubspaceDevRepo.root.appendingPathComponent("fixtures/claude-code/2.1.287/\(run)/\(name)", isDirectory: true)
    }

    @Test(arguments: runs)
    func eachCapturedSnapshotGivesItsExpectedState(run: String) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.folder(run, "status").path)
            .filter { $0.hasSuffix(".json") }.sorted()
        #expect(names.count > 1)
        for name in names {
            let data = try Data(contentsOf: Self.folder(run, "status").appendingPathComponent(name))
            let expected = try JSONValue(data: Data(contentsOf: Self.folder(run, "status-expected").appendingPathComponent(name)))
            guard case let .object(object) = expected else { Issue.record("\(name): not an object"); continue }

            let event = ClaudeCodeSessionStatusSource.event(from: data, mapping: mapping, processStart: alive)

            guard case let .string(state)? = object["state"],
                  case let .object(block)? = object["claude_code_session"],
                  case let .integer(statusAt)? = block["status_at"],
                  case let .integer(pid)? = block["pid"],
                  case let .string(session)? = object["session"] else {
                #expect(event == nil, "\(run)/\(name)")
                continue
            }
            let activity: SessionActivity = switch state {
            case "working": .working
            case "waiting": .waiting
            default: .idle
            }
            #expect(event == AgentEvent(session: SessionKey(source: "claude-code", sessionID: session),
                                        timestamp: date(ms: statusAt), kind: .activityReported(activity), pid: Int32(pid)),
                    "\(run)/\(name)")
        }
    }

    @Test(arguments: runs)
    func theFirstSnapshotHasNoStateYet(run: String) throws {
        let data = try Data(contentsOf: Self.folder(run, "status").appendingPathComponent("001-status.json"))
        #expect(ClaudeCodeSessionStatusSource.event(from: data, mapping: mapping, processStart: alive) == nil)
    }

    /// Claude Code names every session from the start, here after its folder.
    @Test func theFirstSnapshotNamesTheSessionAsTheProcessStarted() throws {
        let events = ClaudeCodeSessionStatusSource.events(
            from: try capturedStatus("2-interrupt-mid-turn", "001-status.json"), mapping: mapping, processStart: alive
        )
        #expect(events.activity == nil)
        // No `updatedAt` yet: the file was written as the process started.
        #expect(events.name == named(interrupted, "claude-code-0a", at: 1_790_968_981_781))
    }

    @Test func aLaterSnapshotNamesTheSessionAsOfItsLastChange() throws {
        let events = ClaudeCodeSessionStatusSource.events(
            from: try capturedStatus("2-interrupt-mid-turn", "011-status.json"), mapping: mapping, processStart: alive
        )
        #expect(events.activity == activity(interrupted, .idle, at: 1_790_968_999_513))
        #expect(events.name == named(interrupted, "claude-code-0a", at: 1_790_968_999_513))
    }

    /// The store takes a report only from the session's own process:
    /// the file's `pid` is the `claude` process, the hooks' envelope pid.
    @Test(arguments: [("2-interrupt-mid-turn", "011-status.json", 3668), ("7-continue", "010-status.json", 7033)]
          as [(String, String, Int32)])
    func bothEventsCarryTheFilesPid(run: String, file: String, pid: Int32) throws {
        let events = ClaudeCodeSessionStatusSource.events(
            from: try capturedStatus(run, file), mapping: mapping, processStart: alive
        )
        #expect(events.activity != nil)
        #expect(events.name != nil)
        #expect(events.activity?.pid == pid)
        #expect(events.name?.pid == pid)
    }

    /// `--continue`: the process takes on the continued session's id.
    @Test func theNameGoesToTheSessionTheFileNamesNow() throws {
        let before = ClaudeCodeSessionStatusSource.events(
            from: try capturedStatus("7-continue", "001-status.json"), mapping: mapping, processStart: alive
        )
        let after = ClaudeCodeSessionStatusSource.events(
            from: try capturedStatus("7-continue", "002-status.json"), mapping: mapping, processStart: alive
        )
        #expect(before.name == named("c5988a13-afa8-40a2-ba1f-e2e4306f694b", "claude-code-32", at: 1_790_969_214_945, pid: 7033))
        #expect(after.name == named("356cc977-00dd-4889-9e26-0aa587d3d220", "claude-code-32", at: 1_790_969_214_997, pid: 7033))
    }

    @Test func anInterruptMidTurnReportsIdleWithoutAnyHook() throws {
        let data = try Data(contentsOf: Self.folder("2-interrupt-mid-turn", "status").appendingPathComponent("011-status.json"))
        #expect(ClaudeCodeSessionStatusSource.event(from: data, mapping: mapping, processStart: alive)
            == AgentEvent(session: SessionKey(source: "claude-code", sessionID: "53d7703c-613e-4c00-b9ab-a400db09b847"),
                          timestamp: date(ms: 1_790_968_999_513), kind: .activityReported(.idle), pid: capturedPid))
    }
}

/// Run 6a, copied into the test bundle: a background shell outlives the turn.
@Suite struct BackgroundShellStatusTests {
    private static let session = "356cc977-00dd-4889-9e26-0aa587d3d220"

    private static func status(_ file: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent(
            "Fixtures/claude-code/2.1.287/6a-background-shell-exit-dialog-killed/status/\(file)"
        ))
    }

    private static func reported(_ file: String) throws -> AgentEvent? {
        ClaudeCodeSessionStatusSource.events(from: try status(file), mapping: mapping, processStart: alive).activity
    }

    /// Claude Code writes `shell` once the turn is over and only the shell runs.
    @Test func aShellStatusReportsABackgroundShell() throws {
        #expect(try Self.reported("025-status.json") == activity(Self.session, .backgroundShell, at: 1_790_969_175_815, pid: 5783))
    }

    /// With a background subagent running, the file says `busy`.
    @Test func busyStillReportsWorking() throws {
        #expect(try Self.reported("022-status.json") == activity(Self.session, .working, at: 1_790_969_173_006, pid: 5783))
    }

    /// The exit dialog that asks whether to stop the background work.
    @Test func theExitDialogReportsWaiting() throws {
        #expect(try Self.reported("026-status.json") == activity(Self.session, .waiting, at: 1_790_969_181_045, pid: 5783))
    }
}

/// A `claude bg-spare` process no job has claimed yet. No such status
/// file was captured: it is derived from a captured idle one (run 6a, 2.1.287)
/// with the fields subspace contract §13 ("Spare processes") gives it (`spare`,
/// `kind: bg`, `jobId` and `name` equal to the short session id, `status: idle`);
/// pid, session and times are those of the spare in `spool-2026-11-01-bg-spare`.
@Suite struct SpareStatusTests {
    static let session = "92f09628-0235-4c9c-b054-9e7a01a56f32"
    static let pid: Int32 = 31141
    /// Start of the spare's process, in the second of its hooks (ts 1793535434).
    static let startedAt: Int64 = 1_793_535_434_000
    static let statusAt: Int64 = 1_793_535_434_400

    static func file(spare: Bool? = true) throws -> Data {
        let captured = try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent(
            "Fixtures/claude-code/2.1.287/6a-background-shell-exit-dialog-killed/status/003-status.json"
        ))
        let short = String(session.prefix(8))
        var changes: [String: Any] = [
            "kind": "bg", "sessionId": session, "pid": Int(pid), "status": "idle", "jobId": short, "name": short,
            "startedAt": startedAt, "statusUpdatedAt": statusAt, "updatedAt": statusAt,
        ]
        if let spare { changes["spare"] = spare }
        return try edited(captured, changes)
    }

    private static func reported(_ data: Data) -> AgentEvent? {
        ClaudeCodeSessionStatusSource.events(from: data, mapping: mapping, processStart: alive).activity
    }

    @Test func aSpareReportsStandby() throws {
        #expect(Self.reported(try Self.file()) == activity(Self.session, .standby, at: Self.statusAt, pid: Self.pid))
    }

    @Test(arguments: [nil, false] as [Bool?])
    func withoutSpareTheMappedStateIsReported(spare: Bool?) throws {
        #expect(Self.reported(try Self.file(spare: spare)) == activity(Self.session, .idle, at: Self.statusAt, pid: Self.pid))
    }

    /// Standby is trusted like any report: only from a live process that wrote the file.
    @Test func aSpareOfADeadOrReusedPidReportsNothing() throws {
        let younger: (Int32) -> Date? = { _ in date(ms: Self.startedAt).addingTimeInterval(3) }
        for processStart in [younger, { _ in nil }] {
            #expect(ClaudeCodeSessionStatusSource.events(from: try Self.file(), mapping: mapping, processStart: processStart).activity == nil)
        }
    }

    /// The first version of a file has no `statusUpdatedAt` yet; a spare is one
    /// from its process's start.
    @Test func aSpareWithoutStatusTimeReportsStandbySinceItsStart() throws {
        var object = try #require(JSONSerialization.jsonObject(with: try Self.file()) as? [String: Any])
        object["statusUpdatedAt"] = nil
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(Self.reported(data) == activity(Self.session, .standby, at: Self.startedAt, pid: Self.pid))
    }
}

/// Status files built by hand, shaped like the captured ones, for the cases the
/// captures don't show.
@Suite struct SessionStatusFileTests {
    static let startedAt: Int64 = 1_790_968_981_781

    static func file(status: String? = "busy", pid: Int? = 3668, startedAt: Int64? = startedAt,
                     session: String = "s1", statusAt: Int64 = 1_790_968_999_513, name: String? = nil) -> Data {
        var object: [String: Any] = ["sessionId": session, "cwd": "/tmp", "kind": "interactive",
                                     "updatedAt": statusAt, "statusUpdatedAt": statusAt]
        if let status { object["status"] = status }
        if let name { object["name"] = name }
        if let pid { object["pid"] = pid }
        if let startedAt { object["startedAt"] = startedAt }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func aLiveProcessGivesTheStateSinceItsStatusTime() {
        let event = ClaudeCodeSessionStatusSource.event(from: Self.file(status: "waiting"), mapping: mapping, processStart: alive)
        #expect(event == AgentEvent(session: SessionKey(source: "claude-code", sessionID: "s1"),
                                    timestamp: date(ms: 1_790_968_999_513), kind: .activityReported(.waiting), pid: capturedPid))
    }

    @Test func aDeadProcessGivesNothing() {
        #expect(ClaudeCodeSessionStatusSource.event(from: Self.file(), mapping: mapping, processStart: { _ in nil }) == nil)
    }

    @Test func aReusedPidGivesNothing() {
        let younger: (Int32) -> Date? = { _ in date(ms: Self.startedAt).addingTimeInterval(3) }
        #expect(ClaudeCodeSessionStatusSource.event(from: Self.file(), mapping: mapping, processStart: younger) == nil)
    }

    @Test func aProcessStartedShortlyBeforeItsFileIsTrusted() {
        let slightlyLater: (Int32) -> Date? = { _ in date(ms: Self.startedAt).addingTimeInterval(1.5) }
        #expect(ClaudeCodeSessionStatusSource.event(from: Self.file(), mapping: mapping, processStart: slightlyLater) != nil)
    }

    @Test func theProcessIsLookedUpByThePidInTheFile() {
        var asked: [Int32] = []
        _ = ClaudeCodeSessionStatusSource.event(from: Self.file(pid: 4711), mapping: mapping) { asked.append($0); return nil }
        #expect(asked == [4711])
    }

    @Test func anUnknownStatusGivesNothing() {
        #expect(ClaudeCodeSessionStatusSource.event(from: Self.file(status: "frobnicating"), mapping: mapping, processStart: alive) == nil)
    }

    @Test func aMissingPidGivesNothing() {
        #expect(ClaudeCodeSessionStatusSource.event(from: Self.file(pid: nil), mapping: mapping, processStart: alive) == nil)
    }

    /// Without `startedAt` a reused pid can't be told apart.
    @Test func aMissingStartTimeGivesNothing() {
        #expect(ClaudeCodeSessionStatusSource.event(from: Self.file(startedAt: nil), mapping: mapping, processStart: alive) == nil)
    }

    @Test func aNameIsReportedWithoutAState() {
        let events = ClaudeCodeSessionStatusSource.events(from: Self.file(status: nil, name: "n"), mapping: mapping, processStart: alive)
        #expect(events.activity == nil)
        #expect(events.name == named("s1", "n", at: 1_790_968_999_513))
    }

    @Test func anUntrustedFileGivesNoName() {
        let younger: (Int32) -> Date? = { _ in date(ms: Self.startedAt).addingTimeInterval(3) }
        for processStart in [younger, { _ in nil }] {
            let events = ClaudeCodeSessionStatusSource.events(from: Self.file(name: "n"), mapping: mapping, processStart: processStart)
            #expect(events.activity == nil)
            #expect(events.name == nil)
        }
    }

    @Test func anEmptyNameGivesNone() {
        let events = ClaudeCodeSessionStatusSource.events(from: Self.file(name: ""), mapping: mapping, processStart: alive)
        #expect(events.activity != nil)
        #expect(events.name == nil)
    }

    @Test func somethingElseThanAJSONObjectGivesNothing() {
        for data in [Data("{\"pid\":".utf8), Data("[]".utf8), Data()] {
            #expect(ClaudeCodeSessionStatusSource.event(from: data, mapping: mapping, processStart: alive) == nil)
        }
    }
}

// MARK: - Where the status files are

@Suite struct SessionStatusDirectoryTests {
    private let home = URL(fileURLWithPath: "/Users/user", isDirectory: true)

    @Test func defaultsToTheClaudeFolderInHome() {
        #expect(ClaudeCodeSessionStatusSource.sessionsDirectory(environment: [:], home: home).path
            == "/Users/user/.claude/sessions")
    }

    @Test func claudeConfigDirMovesIt() {
        #expect(ClaudeCodeSessionStatusSource.sessionsDirectory(environment: ["CLAUDE_CONFIG_DIR": "/tmp/cc"], home: home).path
            == "/tmp/cc/sessions")
    }

    @Test func anEmptyClaudeConfigDirCountsAsUnset() {
        #expect(ClaudeCodeSessionStatusSource.sessionsDirectory(environment: ["CLAUDE_CONFIG_DIR": ""], home: home).path
            == "/Users/user/.claude/sessions")
    }

    /// The status files are Claude Code's own, not subspace's.
    @Test func subspaceDirDoesNotMoveIt() {
        #expect(ClaudeCodeSessionStatusSource.sessionsDirectory(environment: ["SUBSPACE_DIR": "/tmp/spool"], home: home).path
            == "/Users/user/.claude/sessions")
    }
}

// MARK: - Seam 2: watching the folder

/// A fresh, empty directory; removed when the test's `defer` runs.
private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CollectiveKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
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

/// Collects a stream's batches in the background. Most tests are about
/// activity and names; they leave out the terminal reports, which
/// have tests of their own, and so a batch of nothing else.
private actor Recorder {
    private(set) var batches: [[AgentEvent]] = []
    private var task: Task<Void, Never>?
    private let keepsTerminal: Bool

    init(_ stream: AsyncStream<[AgentEvent]>, keepsTerminal: Bool = false) {
        self.keepsTerminal = keepsTerminal
        Task { await self.start(stream) }
    }

    private func start(_ stream: AsyncStream<[AgentEvent]>) {
        task = Task { for await batch in stream { self.append(batch) } }
    }

    private func append(_ batch: [AgentEvent]) {
        let kept = keepsTerminal ? batch : batch.filter {
            if case .terminalReported = $0.kind { false } else { true }
        }
        if !kept.isEmpty { batches.append(kept) }
    }

    func stop() { task?.cancel() }

    /// Waits until at least `count` batches arrived, at most `timeout`.
    func waitFor(batches count: Int, timeout: Duration = .seconds(30)) async -> [[AgentEvent]] {
        let deadline = ContinuousClock.now + timeout
        while batches.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return batches
    }
}

/// Polls until `condition` holds, at most `timeout`.
private func eventually(timeout: Duration = .seconds(30), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func activity(_ session: String, _ activity: SessionActivity, at ms: Int64, pid: Int32 = capturedPid) -> AgentEvent {
    AgentEvent(session: SessionKey(source: "claude-code", sessionID: session), timestamp: date(ms: ms),
               kind: .activityReported(activity), pid: pid)
}

/// A batch's order follows the directory listing, which the tests don't pin.
private func bySession(_ batch: [AgentEvent]) -> [AgentEvent] {
    batch.sorted { $0.session.sessionID < $1.session.sessionID }
}

@Suite struct SessionStatusSourceTests {
    private let watcher = ManualWatcher()

    /// A source on `directory` that never touches the real environment: the
    /// mapping comes from the bundled copy, every pid is alive.
    private func source(
        _ directory: URL,
        processStart: @escaping @Sendable (Int32) -> Date? = alive,
        bundled: @escaping @Sendable (String) -> MappingDocument? = MappingLoader.bundledDocument,
        retryDelay: Duration = .milliseconds(10)
    ) -> ClaudeCodeSessionStatusSource {
        ClaudeCodeSessionStatusSource(
            directory: directory,
            mapping: MappingLoader(root: directory.appendingPathComponent("no-subspace-root", isDirectory: true), bundled: bundled),
            watcher: watcher, processStart: processStart,
            pollInterval: .milliseconds(20), retryDelay: retryDelay
        )
    }

    private func write(_ data: Data, _ name: String, in directory: URL) throws {
        try data.write(to: directory.appendingPathComponent(name))
    }

    @Test func theInitialScanIsOneBatch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(SessionStatusFileTests.file(status: "busy", session: "a", statusAt: 1), "1.json", in: directory)
        try write(SessionStatusFileTests.file(status: "idle", session: "b", statusAt: 2), "2.json", in: directory)

        let recorder = Recorder(source(directory).events())
        defer { Task { await recorder.stop() } }

        let batches = await recorder.waitFor(batches: 1)
        #expect(batches.count == 1)
        #expect(bySession(batches.first ?? []) == [activity("a", .working, at: 1), activity("b", .idle, at: 2)])
    }

    @Test func aChangeYieldsOnlyTheFilesThatChanged() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(SessionStatusFileTests.file(status: "busy", session: "a", statusAt: 1), "1.json", in: directory)
        try write(SessionStatusFileTests.file(status: "busy", session: "b", statusAt: 2), "2.json", in: directory)
        let recorder = Recorder(source(directory).events())
        defer { Task { await recorder.stop() } }
        #expect(await recorder.waitFor(batches: 1).count == 1)

        // Ctrl-C: the file flips to idle, and no hook says so.
        try write(SessionStatusFileTests.file(status: "idle", session: "a", statusAt: 3), "1.json", in: directory)
        watcher.send([directory])

        let batches = await recorder.waitFor(batches: 2)
        #expect(batches.count == 2)
        #expect(batches.last == [activity("a", .idle, at: 3)])
    }

    @Test func anUnchangedFileIsNotReportedAgain() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(SessionStatusFileTests.file(session: "a", statusAt: 1), "1.json", in: directory)
        let recorder = Recorder(source(directory).events())
        defer { Task { await recorder.stop() } }
        #expect(await recorder.waitFor(batches: 1).count == 1)

        // Rewritten with the same state, e.g. only `updatedAt` moved; and a lost track.
        var object = try #require(JSONSerialization.jsonObject(with: SessionStatusFileTests.file(session: "a", statusAt: 1)) as? [String: Any])
        object["updatedAt"] = 99
        try write(JSONSerialization.data(withJSONObject: object), "1.json", in: directory)
        watcher.send([directory])
        watcher.send(nil)
        try await Task.sleep(for: .milliseconds(100))

        #expect(await recorder.batches.count == 1)
    }

    @Test func aRescanAfterALostTrackReportsChanges() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = Recorder(source(directory).events())
        defer { Task { await recorder.stop() } }
        #expect(await eventually { watcher.directories.count == 1 })

        try write(SessionStatusFileTests.file(status: "waiting", session: "a", statusAt: 5), "1.json", in: directory)
        watcher.send(nil)

        #expect(await recorder.waitFor(batches: 1) == [[activity("a", .waiting, at: 5)]])
    }

    @Test func onlyStatusFilesAreRead() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let status = SessionStatusFileTests.file(session: "status", statusAt: 1)
        try write(status, "3668.json", in: directory)
        try write(SessionStatusFileTests.file(session: "key"), "3668.0123abcd.key", in: directory)
        try write(SessionStatusFileTests.file(session: "dot"), ".3669.json", in: directory)
        try write(SessionStatusFileTests.file(session: "tmp"), "3670.json.tmp", in: directory)
        let recorder = Recorder(source(directory).events())
        defer { Task { await recorder.stop() } }

        #expect(await recorder.waitFor(batches: 1) == [[activity("status", .working, at: 1)]])
        try await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.batches.count == 1)
    }

    @Test func untrustedFilesAreNotReported() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Left behind by a crashed process whose pid is gone.
        try write(SessionStatusFileTests.file(session: "a", statusAt: 1), "1.json", in: directory)
        let recorder = Recorder(source(directory, processStart: { _ in nil }).events())
        defer { Task { await recorder.stop() } }
        #expect(await eventually { watcher.directories.count == 1 })
        try await Task.sleep(for: .milliseconds(50))

        #expect(await recorder.batches.isEmpty)
    }

    @Test func aDeletedFileReportsNothing() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(SessionStatusFileTests.file(session: "a", statusAt: 1), "1.json", in: directory)
        let recorder = Recorder(source(directory).events())
        defer { Task { await recorder.stop() } }
        #expect(await recorder.waitFor(batches: 1).count == 1)

        // `/exit`: the hooks' `session.end` ends the session.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("1.json"))
        watcher.send([directory])
        try await Task.sleep(for: .milliseconds(100))

        #expect(await recorder.batches.count == 1)
    }

    /// `/exit` of an interactive session: once its file is gone, nothing vouches
    /// for the terminal anymore (contract §6, "Terminal").
    @Test func anInteractiveFileThatVanishesReportsItUnusable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionKey(source: "claude-code", sessionID: "31d88d15-f725-441b-8f42-88443f5fd7d1")
        let startedAt = date(ms: 1_791_212_478_356)
        try write(capturedRun17("009-status.json"), "767.json", in: directory)
        let recorder = Recorder(source(directory).events(), keepsTerminal: true)
        defer { Task { await recorder.stop() } }
        let first = await recorder.waitFor(batches: 1).first ?? []
        #expect(first.contains(AgentEvent(session: session, timestamp: startedAt, kind: .terminalReported(.session), pid: 767)))

        try FileManager.default.removeItem(at: directory.appendingPathComponent("767.json"))
        watcher.send([directory])

        let batches = await recorder.waitFor(batches: 2)
        #expect(batches.count == 2)
        #expect(batches.last == [AgentEvent(session: session, timestamp: startedAt, kind: .terminalReported(.unusable), pid: 767)])
    }

    /// A background session's file vouched for the app of the daemon's
    /// terminal: once it is gone, that goes too.
    @Test func aHostFileThatVanishesReportsItUnusable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionKey(source: "claude-code", sessionID: "35ad01b4-0462-42d7-b0da-f38201cfa319")
        let startedAt = date(ms: 1_793_778_258_467)
        try write(capturedRun22("010-status.json"), "39661.json", in: directory)
        let recorder = Recorder(source(directory).events(), keepsTerminal: true)
        defer { Task { await recorder.stop() } }
        let first = await recorder.waitFor(batches: 1).first ?? []
        #expect(first.contains(AgentEvent(session: session, timestamp: startedAt, kind: .terminalReported(.host), pid: 39661)))

        try FileManager.default.removeItem(at: directory.appendingPathComponent("39661.json"))
        watcher.send([directory])

        let batches = await recorder.waitFor(batches: 2)
        #expect(batches.count == 2)
        #expect(batches.last == [AgentEvent(session: session, timestamp: startedAt, kind: .terminalReported(.unusable), pid: 39661)])
    }

    /// A spare's file never vouched for anything to take back.
    @Test func anUnusableFileThatVanishesReportsNothing() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(SpareStatusTests.file(), "\(SpareStatusTests.pid).json", in: directory)
        let recorder = Recorder(source(directory).events(), keepsTerminal: true)
        defer { Task { await recorder.stop() } }
        #expect(await recorder.waitFor(batches: 1).first?.contains { $0.kind == .terminalReported(.unusable) } == true)

        try FileManager.default.removeItem(at: directory.appendingPathComponent("\(SpareStatusTests.pid).json"))
        watcher.send([directory])
        try await Task.sleep(for: .milliseconds(100))

        #expect(await recorder.batches.count == 1)
    }

    /// After a crash the file stays (contract §13, "Lifetime"), but its pid is
    /// dead or reused: it vouches for the terminal no more than a deleted one.
    @Test func anInteractiveFileThatBecomesUntrustedReportsItUnusable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionKey(source: "claude-code", sessionID: "31d88d15-f725-441b-8f42-88443f5fd7d1")
        let startedAt = date(ms: 1_791_212_478_356)
        let processAlive = Mutex(true)
        try write(capturedRun17("009-status.json"), "767.json", in: directory)
        let recorder = Recorder(source(directory, processStart: { pid in
            processAlive.withLock { $0 } ? alive(pid) : nil
        }).events(), keepsTerminal: true)
        defer { Task { await recorder.stop() } }
        let first = await recorder.waitFor(batches: 1).first ?? []
        #expect(first.contains(AgentEvent(session: session, timestamp: startedAt, kind: .terminalReported(.session), pid: 767)))

        processAlive.withLock { $0 = false }
        watcher.send(nil)

        let batches = await recorder.waitFor(batches: 2)
        #expect(batches.count == 2)
        #expect(batches.last == [AgentEvent(session: session, timestamp: startedAt, kind: .terminalReported(.unusable), pid: 767)])

        // Withdrawn once: the file going later takes nothing back again.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("767.json"))
        watcher.send([directory])
        try await Task.sleep(for: .milliseconds(100))

        #expect(await recorder.batches.count == 2)
    }

    /// The same for a background session after a crash: the app of the
    /// daemon's terminal is no longer vouched for, and a later deletion adds nothing.
    @Test func aHostFileThatBecomesUntrustedReportsItUnusable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = SessionKey(source: "claude-code", sessionID: "35ad01b4-0462-42d7-b0da-f38201cfa319")
        let startedAt = date(ms: 1_793_778_258_467)
        let processAlive = Mutex(true)
        try write(capturedRun22("010-status.json"), "39661.json", in: directory)
        let recorder = Recorder(source(directory, processStart: { pid in
            processAlive.withLock { $0 } ? alive(pid) : nil
        }).events(), keepsTerminal: true)
        defer { Task { await recorder.stop() } }
        let first = await recorder.waitFor(batches: 1).first ?? []
        #expect(first.contains(AgentEvent(session: session, timestamp: startedAt, kind: .terminalReported(.host), pid: 39661)))

        processAlive.withLock { $0 = false }
        watcher.send(nil)

        let batches = await recorder.waitFor(batches: 2)
        #expect(batches.count == 2)
        #expect(batches.last == [AgentEvent(session: session, timestamp: startedAt, kind: .terminalReported(.unusable), pid: 39661)])

        try FileManager.default.removeItem(at: directory.appendingPathComponent("39661.json"))
        watcher.send([directory])
        try await Task.sleep(for: .milliseconds(100))

        #expect(await recorder.batches.count == 2)
    }

    /// The process's kind doesn't change with its state: a new status alone
    /// reports nothing again; `/clear` reports the session it runs now.
    @Test func theTerminalIsReportedOncePerSession() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(capturedRun17("009-status.json"), "767.json", in: directory)
        let recorder = Recorder(source(directory).events(), keepsTerminal: true)
        defer { Task { await recorder.stop() } }
        #expect(await recorder.waitFor(batches: 1).count == 1)

        let busy = try #require(try await change(to: capturedRun17("010-status.json"), "767.json", in: directory, recorder: recorder, batch: 2))
        #expect(!busy.contains { if case .terminalReported = $0.kind { true } else { false } })

        let cleared = try #require(try await change(to: capturedRun17("013-status.json"), "767.json", in: directory, recorder: recorder, batch: 3))
        #expect(cleared.contains(AgentEvent(
            session: SessionKey(source: "claude-code", sessionID: "53d29d64-7546-4aef-91e7-22dc7213f0bf"),
            timestamp: date(ms: 1_791_212_478_356), kind: .terminalReported(.session), pid: 767)))
    }

    @Test func anUnparseableFileIsReportedOnceItParses() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(Data("{\"pid\":36".utf8), "1.json", in: directory)
        try write(SessionStatusFileTests.file(session: "b", statusAt: 2), "2.json", in: directory)
        let recorder = Recorder(source(directory).events())
        defer { Task { await recorder.stop() } }
        #expect(await recorder.waitFor(batches: 1) == [[activity("b", .working, at: 2)]])

        try write(SessionStatusFileTests.file(session: "a", statusAt: 1), "1.json", in: directory)
        watcher.send([directory])

        let batches = await recorder.waitFor(batches: 2)
        #expect(batches.count == 2)
        #expect(batches.last == [activity("a", .working, at: 1)])
    }

    /// A file that is unreadable for a moment keeps its last state, so reading it
    /// fine again with that state is no change either.
    @Test func aFileUnparseableForAMomentIsNoChange() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let status = SessionStatusFileTests.file(session: "a", statusAt: 1)
        try write(status, "1.json", in: directory)
        let recorder = Recorder(source(directory).events())
        defer { Task { await recorder.stop() } }
        #expect(await recorder.waitFor(batches: 1).count == 1)

        try write(Data("{\"pid\":36".utf8), "1.json", in: directory)
        watcher.send([directory])
        try await Task.sleep(for: .milliseconds(100))
        try write(status, "1.json", in: directory)
        watcher.send([directory])
        try await Task.sleep(for: .milliseconds(100))

        #expect(await recorder.batches.count == 1)
    }

    /// Caught mid-write: read again shortly, without waiting for another change.
    @Test func aHalfWrittenFileIsReadAgainShortly() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(Data("{\"pid\":36".utf8), "1.json", in: directory)
        let recorder = Recorder(source(directory, retryDelay: .milliseconds(200)).events())
        defer { Task { await recorder.stop() } }
        try await Task.sleep(for: .milliseconds(50))

        try write(SessionStatusFileTests.file(session: "a", statusAt: 1), "1.json", in: directory)

        #expect(await recorder.waitFor(batches: 1) == [[activity("a", .working, at: 1)]])
    }

    /// The public initializer reads the session mapping from the folder the user
    /// chose for the hook events. That folder's document renames the session id's
    /// path, so only a source using it reports the file.
    @Test func theMappingComesFromAChosenFolder() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let chosen = base.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen.appendingPathComponent("model"), withIntermediateDirectories: true)
        let bundled = try String(contentsOf: try #require(MappingLoader.bundledURL(named: "claude-code-session")), encoding: .utf8)
        // Derived, so the replacement keeps applying when the bundled document moves on.
        let revision = try #require(MappingLoader.bundledDocument(named: "claude-code-session")?.revision)
        let drifted = bundled
            .replacingOccurrences(of: #""revision": \#(revision)"#, with: #""revision": 99"#)
            .replacingOccurrences(of: #""path": "/sessionId""#, with: #""path": "/chosenSessionId""#)
        #expect(drifted.contains(#""revision": 99"#), "the revision replacement must apply")
        #expect(drifted.contains("/chosenSessionId"))
        try Data(drifted.utf8).write(to: chosen.appendingPathComponent("model/claude-code-session.json"))

        let config = base.appendingPathComponent("config", isDirectory: true)
        let sessions = config.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        // The real pid check runs: this test process, started before its file.
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let file: [String: Any] = ["chosenSessionId": "chosen", "status": "busy", "pid": Int(getpid()),
                                   "startedAt": now, "statusUpdatedAt": now]
        try write(JSONSerialization.data(withJSONObject: file), "\(getpid()).json", in: sessions)

        let source = ClaudeCodeSessionStatusSource(
            chosenRoot: chosen, environment: ["CLAUDE_CONFIG_DIR": config.path],
            home: URL(filePath: "/nowhere"), watcher: watcher, pollInterval: .milliseconds(20)
        )
        let recorder = Recorder(source.events())
        defer { Task { await recorder.stop() } }

        #expect(await recorder.waitFor(batches: 1) == [[activity("chosen", .working, at: now, pid: getpid())]])
    }

    @Test func withoutAMappingNothingIsReported() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(SessionStatusFileTests.file(session: "a", statusAt: 1), "1.json", in: directory)
        let recorder = Recorder(source(directory, bundled: { _ in nil }).events())
        defer { Task { await recorder.stop() } }
        #expect(await eventually { watcher.directories.count == 1 })
        try await Task.sleep(for: .milliseconds(50))

        #expect(await recorder.batches.isEmpty)
    }

    @Test func aMissingFolderIsOnlyPolledUntilItAppears() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("sessions", isDirectory: true)
        let recorder = Recorder(source(directory).events())
        defer { Task { await recorder.stop() } }

        try await Task.sleep(for: .milliseconds(100))
        #expect(watcher.directories.isEmpty)

        // Appears with its file already in it, as a polling source could otherwise
        // find it still empty and, with a watcher that reports nothing, miss the file.
        let staging = base.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try write(SessionStatusFileTests.file(session: "a", statusAt: 1), "1.json", in: staging)
        try FileManager.default.moveItem(at: staging, to: directory)

        #expect(await recorder.waitFor(batches: 1) == [[activity("a", .working, at: 1)]])
        #expect(watcher.directories.map(\.path) == [directory.path])
    }

    @Test func aFolderThatVanishesIsWaitedForAgain() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recorder = Recorder(source(directory).events())
        defer { Task { await recorder.stop() } }
        #expect(await eventually { watcher.directories.count == 1 })

        try FileManager.default.removeItem(at: directory)
        watcher.send(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(watcher.directories.count == 1)

        let staging = base.appendingPathComponent(".staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try write(SessionStatusFileTests.file(session: "a", statusAt: 1), "1.json", in: staging)
        try FileManager.default.moveItem(at: staging, to: directory)

        #expect(await recorder.waitFor(batches: 1) == [[activity("a", .working, at: 1)]])
        #expect(watcher.directories.count == 2)
    }

    /// Contract §13: nothing in `sessions/` is created, changed or deleted, also
    /// not files the source can't use.
    @Test func neverWritesToTheFolder() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(SessionStatusFileTests.file(session: "a", statusAt: 1), "1.json", in: directory)
        try write(Data("{".utf8), "2.json", in: directory)
        try write(Data("secret".utf8), "1.abc.key", in: directory)
        func snapshot() throws -> [String: Data] {
            var files: [String: Data] = [:]
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                files[name] = try Data(contentsOf: directory.appendingPathComponent(name))
            }
            return files
        }
        let before = try snapshot()
        let recorder = Recorder(source(directory).events())
        defer { Task { await recorder.stop() } }
        #expect(await recorder.waitFor(batches: 1).count == 1)
        watcher.send(nil)
        try await Task.sleep(for: .milliseconds(100))

        #expect(try snapshot() == before)
    }

    // MARK: Names

    /// Writes `data` as the file and waits for the batch it gives.
    private func change(
        to data: Data, _ name: String, in directory: URL, recorder: Recorder, batch number: Int
    ) async throws -> [AgentEvent]? {
        try write(data, name, in: directory)
        watcher.send([directory])
        let batches = await recorder.waitFor(batches: number)
        return batches.count == number ? batches.last : nil
    }

    @Test(.enabled(if: SubspaceDevRepo.isAvailable, "subspace dev repo not found; captured status files NOT checked"))
    func theFirstScanNamesEverySessionInItsBatch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(capturedStatus("2-interrupt-mid-turn", "011-status.json"), "3668.json", in: directory)
        try write(capturedStatus("7-continue", "010-status.json"), "7033.json", in: directory)
        let recorder = Recorder(source(directory).events())
        defer { Task { await recorder.stop() } }

        let batches = await recorder.waitFor(batches: 1)
        let continued = "356cc977-00dd-4889-9e26-0aa587d3d220"
        #expect(batches.count == 1)
        #expect(bySession(batches.first ?? []).map(\.session.sessionID) == [continued, continued, interrupted, interrupted])
        for event in [
            activity(interrupted, .idle, at: 1_790_968_999_513), named(interrupted, "claude-code-0a", at: 1_790_968_999_513),
            activity(continued, .idle, at: 1_790_969_220_966, pid: 7033), named(continued, "claude-code-32", at: 1_790_969_220_966, pid: 7033),
        ] {
            #expect(batches.first?.contains(event) == true, "\(event.kind)")
        }
    }

    @Test(.enabled(if: SubspaceDevRepo.isAvailable, "subspace dev repo not found; captured status files NOT checked"))
    func anUnchangedNameIsReportedOncePerFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(capturedStatus("2-interrupt-mid-turn", "001-status.json"), "3668.json", in: directory)
        let recorder = Recorder(source(directory).events())
        defer { Task { await recorder.stop() } }
        #expect(await recorder.waitFor(batches: 1) == [[named(interrupted, "claude-code-0a", at: 1_790_968_981_781)]])

        for (number, file, event) in [
            (2, "003-status.json", activity(interrupted, .idle, at: 1_790_968_981_861)),
            (3, "006-status.json", activity(interrupted, .working, at: 1_790_968_985_602)),
            (4, "011-status.json", activity(interrupted, .idle, at: 1_790_968_999_513)),
        ] {
            let batch = try await change(to: capturedStatus("2-interrupt-mid-turn", file), "3668.json",
                                         in: directory, recorder: recorder, batch: number)
            #expect(batch == [event], "\(file)")
        }
    }

    /// No capture has a `/rename`: the captured files are edited to show one
    /// between 003 and 006, with `updatedAt` moving to the rename.
    @Test(.enabled(if: SubspaceDevRepo.isAvailable, "subspace dev repo not found; captured status files NOT checked"))
    func aRenameIsReportedOnce() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(capturedStatus("2-interrupt-mid-turn", "003-status.json"), "3668.json", in: directory)
        let recorder = Recorder(source(directory).events())
        defer { Task { await recorder.stop() } }
        #expect(await recorder.waitFor(batches: 1).first?.count == 2)

        let renamed = try edited(capturedStatus("2-interrupt-mid-turn", "003-status.json"),
                                 ["name": "renamed", "updatedAt": 1_790_968_983_000])
        let rename = try await change(to: renamed, "3668.json", in: directory, recorder: recorder, batch: 2)
        #expect(rename == [named(interrupted, "renamed", at: 1_790_968_983_000)])

        let working = try edited(capturedStatus("2-interrupt-mid-turn", "006-status.json"), ["name": "renamed"])
        let next = try await change(to: working, "3668.json", in: directory, recorder: recorder, batch: 3)
        #expect(next == [activity(interrupted, .working, at: 1_790_968_985_602)])
    }

    /// `--continue`: the same name, now for the continued session.
    @Test(.enabled(if: SubspaceDevRepo.isAvailable, "subspace dev repo not found; captured status files NOT checked"))
    func aNewSessionInTheSameFileIsNamedAgain() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(capturedStatus("7-continue", "001-status.json"), "7033.json", in: directory)
        let recorder = Recorder(source(directory).events())
        defer { Task { await recorder.stop() } }
        #expect(await recorder.waitFor(batches: 1)
            == [[named("c5988a13-afa8-40a2-ba1f-e2e4306f694b", "claude-code-32", at: 1_790_969_214_945, pid: 7033)]])

        let continued = "356cc977-00dd-4889-9e26-0aa587d3d220"
        for (number, file, event) in [
            (2, "002-status.json", named(continued, "claude-code-32", at: 1_790_969_214_997, pid: 7033)),
            (3, "004-status.json", activity(continued, .idle, at: 1_790_969_215_076, pid: 7033)),
            (4, "007-status.json", activity(continued, .working, at: 1_790_969_218_779, pid: 7033)),
        ] {
            let batch = try await change(to: capturedStatus("7-continue", file), "7033.json",
                                         in: directory, recorder: recorder, batch: number)
            #expect(batch == [event], "\(file)")
        }
    }

    /// A job claims the spare: the process's file names the job's
    /// session now, without `spare`. No claim was captured; the claim file is
    /// derived from the spare's as contract §13 ("Spare processes") describes it:
    /// the job's `sessionId`, `jobId` and `name`, a new `startedAt`, no `spare`.
    @Test func aClaimedSpareReportsOnlyTheJobsSession() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spare = SpareStatusTests.session, pid = SpareStatusTests.pid, at = SpareStatusTests.statusAt
        try write(SpareStatusTests.file(), "\(pid).json", in: directory)
        let recorder = Recorder(source(directory).events())
        defer { Task { await recorder.stop() } }
        #expect(await recorder.waitFor(batches: 1).first?.first == activity(spare, .standby, at: at, pid: pid))

        let job = "job"
        let claimedAt = at + 60_000
        let claimed = try edited(SpareStatusTests.file(spare: nil), [
            "sessionId": job, "jobId": "job-id", "name": "job-name",
            "startedAt": claimedAt, "updatedAt": claimedAt, "statusUpdatedAt": claimedAt,
        ])
        let batch = try await change(to: claimed, "\(pid).json", in: directory, recorder: recorder, batch: 2)
        #expect(batch == [activity(job, .idle, at: claimedAt, pid: pid), named(job, "job-name", at: claimedAt, pid: pid)])
    }

    /// The real watcher, end to end: Claude Code writing a file in place.
    @Test func picksUpChangesWithFSEvents() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = ClaudeCodeSessionStatusSource(
            directory: directory,
            mapping: MappingLoader(root: directory.appendingPathComponent("no-subspace-root", isDirectory: true)),
            watcher: FSEventsWatcher(), processStart: alive,
            pollInterval: .milliseconds(20), retryDelay: .milliseconds(10)
        )
        let recorder = Recorder(source.events())
        defer { Task { await recorder.stop() } }
        try await Task.sleep(for: .milliseconds(300))

        try write(SessionStatusFileTests.file(status: "idle", session: "a", statusAt: 7), "1.json", in: directory)

        #expect(await recorder.waitFor(batches: 1) == [[activity("a", .idle, at: 7)]])
    }
}
