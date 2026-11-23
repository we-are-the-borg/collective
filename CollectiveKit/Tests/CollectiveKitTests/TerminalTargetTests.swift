import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// The terminal a session runs in, from the envelope's `terminal` (subspace
// contract §4), its tab usable only while the session's own status file says its
// process is interactive (contract §6 "Terminal", §13 "Owner"); for a process of
// `claude --bg` and for Codex only the app.

// MARK: - Fixtures

private enum TerminalFixtures {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/claude-code")

    /// Run 22: `claude --bg`, a process of the daemon; `terminal` is the daemon's Warp tab.
    enum Background {
        static let folder = fixtures.appendingPathComponent("2.1.318/22-background-terminal-env")
        static let session = SessionKey(source: "claude-code", sessionID: "35ad01b4-0462-42d7-b0da-f38201cfa319")
        /// The status files' `pid`, the claimed spare that ran the job.
        static let pid: Int32 = 39661
        static let startedAt = Date(timeIntervalSince1970: 1_793_778_258.467)
    }

    /// Run 17: interactive, `/model sonnet`, then `/clear` in the same process.
    enum Interactive {
        static let folder = fixtures.appendingPathComponent("2.1.289/17-model-clear")
        static let first = SessionKey(source: "claude-code", sessionID: "31d88d15-f725-441b-8f42-88443f5fd7d1")
        static let second = SessionKey(source: "claude-code", sessionID: "53d29d64-7546-4aef-91e7-22dc7213f0bf")
        static let pid: Int32 = 767
        static let startedAt = Date(timeIntervalSince1970: 1_791_212_478.356)
    }

    /// Run 21's `terminal`: an interactive session in a Warp tab.
    static func warpTab() throws -> [String: String] {
        try terminal(fixtures.appendingPathComponent("2.1.317/21-terminal-env/terminal.json"))
    }

    static func terminal(_ url: URL) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }

    /// Raw payloads in arrival order (`NNN-<hook>.json`).
    static func payloads(in folder: URL) throws -> [Data] {
        let events = folder.appendingPathComponent("events")
        return try FileManager.default.contentsOfDirectory(atPath: events.path).sorted()
            .map { try Data(contentsOf: events.appendingPathComponent($0)) }
    }

    static func status(_ folder: URL, _ file: String) throws -> Data {
        try Data(contentsOf: folder.appendingPathComponent("status/\(file)"))
    }
}

private struct NoMeta: SubagentMetaReading {
    func meta(transcriptPath: String, agentID: String) -> SubagentMeta? { nil }
}

private struct NoRollouts: RolloutMetaReading {
    func meta(rolloutPath: String) -> RolloutMeta? { nil }
    func approvalsReviewer(rolloutPath: String, turnID: String) -> String? { nil }
    func effort(rolloutPath: String, turnID: String) -> String? { nil }
}

private final class NoFiles: MappingFileSystem {
    func modificationDate(of url: URL) -> Date? { nil }
    func contents(of url: URL) throws -> Data { throw CocoaError(.fileNoSuchFile) }
}

/// A root without `model/`, so the bundled documents are used.
private func bundledMapping() -> MappingLoader {
    MappingLoader(root: URL(filePath: "/spool/root", directoryHint: .isDirectory), fileSystem: NoFiles())
}

private let t0 = Date(timeIntervalSince1970: 1_793_778_258)

/// The hook events of `payloads`, wrapped as subspace wraps them, one second apart.
private func hookEvents(_ payloads: [Data], pid: Int32, terminal: [String: String]) throws -> [AgentEvent] {
    let adapter = ClaudeCodeAdapter(metaReader: NoMeta(), mapping: bundledMapping())
    return try payloads.enumerated().flatMap { index, payload in
        try adapter.events(from: Envelope(source: "claude-code", pid: pid, payload: payload,
                                          receivedAt: t0.addingTimeInterval(TimeInterval(index)), terminal: terminal))
    }
}

// MARK: - Seam: ClaudeCodeAdapter.events(from:)

@Suite struct ClaudeCodeTerminalTests {
    @Test func everyEventCarriesTheEnvelopesTerminal() throws {
        let terminal = try TerminalFixtures.terminal(TerminalFixtures.Background.folder.appendingPathComponent("terminal.json"))
        let events = try hookEvents(try TerminalFixtures.payloads(in: TerminalFixtures.Background.folder),
                                    pid: TerminalFixtures.Background.pid, terminal: terminal)

        #expect(events.count > 3)
        #expect(events.allSatisfy { $0.terminal == TerminalIdentifiers([
            "WARP_FOCUS_URL": "warp://session/1b10f2936c54494a955cc11fd5ab3b22",
            "WARP_TERMINAL_SESSION_UUID": "1b10f2936c54494a955cc11fd5ab3b22",
        ]) })
        #expect(events.contains { $0.kind == .sessionEnded })
    }

    @Test func anEnvelopeWithoutTerminalGivesNone() throws {
        let events = try hookEvents(try TerminalFixtures.payloads(in: TerminalFixtures.Background.folder),
                                    pid: TerminalFixtures.Background.pid, terminal: [:])
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.terminal == nil })
    }

}

// MARK: - Seam: CodexAdapter.events(from:)

/// No Codex capture has `terminal` yet: run 1's real Codex payloads in
/// envelopes with Claude Code's captured Warp terminal (run 21 or 22), as
/// subspace wraps them, one second apart.
private func codexEvents(terminal: [String: String]) throws -> [AgentEvent] {
    let adapter = CodexAdapter(rolloutReader: NoRollouts(), mapping: bundledMapping())
    return try CodexRun.headless.payloads.enumerated().flatMap { index, payload in
        try adapter.events(from: Envelope(source: "codex", pid: 4242, payload: payload,
                                          receivedAt: t0.addingTimeInterval(TimeInterval(index)), terminal: terminal))
    }
}

private let codexSession = SessionKey(source: "codex", sessionID: "01a0f6f3-e902-7f10-9fdd-9a6e4d38a220")

/// Run 1 with run 21's terminal, then its prompt again, without `terminal`,
/// after more than the adapter's 12 h, as when the thread goes on in the
/// ChatGPT app: the adapter has forgotten the session by then.
private func codexEventsResumedWithoutTerminal() throws -> [AgentEvent] {
    let adapter = CodexAdapter(rolloutReader: NoRollouts(), mapping: bundledMapping())
    let terminal = try TerminalFixtures.warpTab()
    let payloads = CodexRun.headless.payloads
    let first = try payloads.enumerated().flatMap { index, payload in
        try adapter.events(from: Envelope(source: "codex", pid: 4242, payload: payload,
                                          receivedAt: t0.addingTimeInterval(TimeInterval(index)), terminal: terminal))
    }
    let later = try adapter.events(from: Envelope(source: "codex", pid: 4242, payload: payloads[1],
                                                  receivedAt: t0.addingTimeInterval(13 * 60 * 60), terminal: [:]))
    return first + later
}

/// With the shared daemon, Codex's `terminal` is the daemon's (contract §6,
/// "Terminal"): it names the app, never the session's tab.
@Suite struct CodexTerminalTests {
    @Test func everyEventCarriesTheEnvelopesTerminal() throws {
        let events = try codexEvents(terminal: try TerminalFixtures.warpTab())
        #expect(events.count > 3)
        #expect(events.allSatisfy { $0.terminal == TerminalIdentifiers([
            "TERM_PROGRAM": "WarpTerminal",
            "TERM_PROGRAM_VERSION": "v0.2026.10.07.08.29.stable_00",
            "__CFBundleIdentifier": "dev.warp.Warp-Stable",
            "WARP_FOCUS_URL": "warp://session/16e5a860f58d4186bd579a30d87d0d18",
            "WARP_TERMINAL_SESSION_UUID": "16e5a860f58d4186bd579a30d87d0d18",
        ]) })
    }

    /// Sessions from the ChatGPT app carry no `terminal`: said once, so a
    /// report the store still keeps from before is taken back.
    @Test func anEnvelopeWithoutTerminalGivesNoneAndReportsItUnusableOnce() throws {
        let events = try codexEvents(terminal: [:])
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.terminal == nil })
        let reports = events.filter { if case .terminalReported = $0.kind { true } else { false } }
        #expect(reports.map(\.kind) == [.terminalReported(.unusable)])
        #expect(reports.first?.timestamp == t0)
    }

    /// The adapter forgets a session after 12 h; what it hears next is said
    /// again even when it has no terminal.
    @Test func aSessionForgottenAndBackWithoutTerminalWithdrawsTheReport() throws {
        let reports = try codexEventsResumedWithoutTerminal().filter {
            if case .terminalReported = $0.kind { true } else { false }
        }
        #expect(reports.map(\.kind) == [.terminalReported(.host), .terminalReported(.unusable)])
        #expect(reports.last?.timestamp == t0.addingTimeInterval(13 * 60 * 60))
    }

    /// Once per session, not with every hook; without a pid, as all Codex events.
    @Test func theSessionReportsItsTerminalAsAHostsOnce() throws {
        let reports = try codexEvents(terminal: try TerminalFixtures.warpTab()).filter {
            if case .terminalReported = $0.kind { true } else { false }
        }
        let report = try #require(reports.count == 1 ? reports.first : nil)
        #expect(report.session == codexSession)
        #expect(report.timestamp == t0)
        #expect(report.kind == .terminalReported(.host))
        #expect(report.pid == nil)
    }
}

// MARK: - Seam: ClaudeCodeSessionStatusSource.events(from:mapping:processStart:)

private let sessionMapping = MappingLoader.bundledDocument(named: "claude-code-session")!

/// Every process started long before its status file, so the pid check passes.
private let alive: @Sendable (Int32) -> Date? = { _ in Date(timeIntervalSince1970: 0) }

private func terminalReport(_ data: Data, processStart: (Int32) -> Date? = alive) -> AgentEvent? {
    ClaudeCodeSessionStatusSource.events(from: data, mapping: sessionMapping, processStart: processStart).terminal
}

@Suite struct SessionStatusTerminalTests {
    /// The interactive process's file, before its first status and later.
    @Test(arguments: ["001-status.json", "009-status.json"])
    func anInteractiveProcessReportsItsOwnTerminal(file: String) throws {
        let data = try TerminalFixtures.status(TerminalFixtures.Interactive.folder, file)
        #expect(terminalReport(data) == AgentEvent(
            session: TerminalFixtures.Interactive.first, timestamp: TerminalFixtures.Interactive.startedAt,
            kind: .terminalReported(.session), pid: TerminalFixtures.Interactive.pid))
    }

    /// After `/clear` the same process reports the session it runs now.
    @Test func afterClearTheNewSessionReportsItsOwnTerminal() throws {
        let data = try TerminalFixtures.status(TerminalFixtures.Interactive.folder, "013-status.json")
        #expect(terminalReport(data)?.session == TerminalFixtures.Interactive.second)
        #expect(terminalReport(data)?.kind == .terminalReported(.session))
    }

    /// `claude --bg`: the hooks see the daemon's terminal, which names the
    /// app but not the session's tab.
    @Test(arguments: ["001-status.json", "003-status.json", "010-status.json"])
    func aBackgroundProcessReportsItsHostsTerminal(file: String) throws {
        let data = try TerminalFixtures.status(TerminalFixtures.Background.folder, file)
        #expect(terminalReport(data) == AgentEvent(
            session: TerminalFixtures.Background.session, timestamp: TerminalFixtures.Background.startedAt,
            kind: .terminalReported(.host), pid: TerminalFixtures.Background.pid))
    }

    /// A spare is the daemon's, whatever its kind says (derived as in `SpareStatusTests`).
    @Test func aSpareReportsAnUnusableTerminal() throws {
        #expect(terminalReport(try SpareStatusTests.file())?.kind == .terminalReported(.unusable))
    }

    /// Without a known kind the file can't vouch for the terminal. No capture
    /// lacks one: run 17's interactive file with `kind` removed or changed.
    @Test(arguments: [nil, "daemon"] as [String?])
    func aMissingOrUnknownKindReportsAnUnusableTerminal(kind: String?) throws {
        let captured = try TerminalFixtures.status(TerminalFixtures.Interactive.folder, "009-status.json")
        var object = try #require(JSONSerialization.jsonObject(with: captured) as? [String: Any])
        object["kind"] = kind
        #expect(terminalReport(try JSONSerialization.data(withJSONObject: object))?.kind == .terminalReported(.unusable))
    }

    @Test func anUntrustedFileSaysNothing() throws {
        let data = try TerminalFixtures.status(TerminalFixtures.Interactive.folder, "009-status.json")
        let younger: (Int32) -> Date? = { _ in TerminalFixtures.Interactive.startedAt.addingTimeInterval(3) }
        #expect(terminalReport(data, processStart: { _ in nil }) == nil)
        #expect(terminalReport(data, processStart: younger) == nil)
    }
}

// MARK: - Seam: CollectiveState.apply(_:) and Session.terminalTarget

/// Run 17's first session up to before its `/clear` (002–011), all from its process.
private func interactiveHooks(terminal: [String: String]) throws -> [AgentEvent] {
    let payloads = try TerminalFixtures.payloads(in: TerminalFixtures.Interactive.folder).prefix(6)
    return try hookEvents(Array(payloads), pid: TerminalFixtures.Interactive.pid, terminal: terminal)
}

/// What run 17's status file says while the first session runs.
private func interactiveReport() throws -> AgentEvent {
    let data = try TerminalFixtures.status(TerminalFixtures.Interactive.folder, "009-status.json")
    return try #require(terminalReport(data))
}

private func reported(_ ownership: TerminalOwnership, pid: Int32, session: SessionKey = TerminalFixtures.Interactive.first,
                      at date: Date = TerminalFixtures.Interactive.startedAt) -> AgentEvent {
    AgentEvent(session: session, timestamp: date, kind: .terminalReported(ownership), pid: pid)
}

private let warpTab = URL(string: "warp://session/16e5a860f58d4186bd579a30d87d0d18")!

/// A kit text as an English user reads it, resolved from the kit's catalog.
private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

/// `key`'s item in the popover, with Warp installed.
private func card(_ key: SessionKey, in state: CollectiveState) throws -> SessionItem {
    let model = PopoverModel(state: state, now: t0.addingTimeInterval(60), settings: PopoverSettings(idleAfter: .never),
                             terminalApps: InstalledWarp())
    return try #require((model.sessions + model.idle + model.finished).first { $0.key == key })
}

@Suite struct SessionTerminalTargetTests {
    /// No interactive spool with `terminal` was captured: run 17's real payloads
    /// and status file (interactive, 2.1.289) with run 21's real Warp `terminal`
    /// (interactive, 2.1.317), as the envelope of run 17 would have carried it.
    /// The status file may be read before the spool or after it.
    @Test(arguments: [false, true])
    func anInteractiveSessionInWarpTargetsItsTab(statusFirst: Bool) throws {
        var state = CollectiveState()
        if statusFirst { state.apply(try interactiveReport()) }
        try interactiveHooks(terminal: try TerminalFixtures.warpTab()).forEach { state.apply($0) }
        if !statusFirst { state.apply(try interactiveReport()) }

        #expect(state.sessions[TerminalFixtures.Interactive.first]?.terminalTarget
            == .url(warpTab, bundleID: "dev.warp.Warp-Stable"))
        // Its own tab: the jump button selects it.
        #expect(try card(TerminalFixtures.Interactive.first, in: state).jumpAction?.selectsTab == true)
    }

    /// Run 21's terminal with only `__CFBundleIdentifier` kept, as in a
    /// terminal without a tab id (contract §4): only the app can come forward.
    @Test func withOnlyTheAppItTargetsTheApp() throws {
        var state = CollectiveState()
        let app = try TerminalFixtures.warpTab().filter { $0.key == "__CFBundleIdentifier" }
        try interactiveHooks(terminal: app).forEach { state.apply($0) }
        state.apply(try interactiveReport())

        #expect(state.sessions[TerminalFixtures.Interactive.first]?.terminalTarget == .app(bundleID: "dev.warp.Warp-Stable"))
    }

    @Test func withoutIdentifiersThereIsNoTarget() throws {
        var state = CollectiveState()
        try interactiveHooks(terminal: [:]).forEach { state.apply($0) }
        state.apply(try interactiveReport())

        #expect(state.sessions[TerminalFixtures.Interactive.first] != nil)
        #expect(state.sessions[TerminalFixtures.Interactive.first]?.terminalTarget == nil)
    }

    /// Run 21's terminal with its focus URL broken: the app is what is left;
    /// without it, nothing.
    @Test(arguments: [
        "warp://session/16e5a860", "warp://tab/16e5a860f58d4186bd579a30d87d0d18",
        "warp://session/16e5a860f58d4186bd579a30d87d0d18?x=1", "",
    ])
    func aMalformedFocusURLFallsBackToTheApp(focus: String) throws {
        var terminal = try TerminalFixtures.warpTab()
        terminal["WARP_FOCUS_URL"] = focus
        var state = CollectiveState()
        try interactiveHooks(terminal: terminal).forEach { state.apply($0) }
        state.apply(try interactiveReport())
        #expect(state.sessions[TerminalFixtures.Interactive.first]?.terminalTarget == .app(bundleID: "dev.warp.Warp-Stable"))

        terminal["__CFBundleIdentifier"] = nil
        var bare = CollectiveState()
        try interactiveHooks(terminal: terminal).forEach { bare.apply($0) }
        bare.apply(try interactiveReport())
        #expect(bare.sessions[TerminalFixtures.Interactive.first]?.terminalTarget == nil)
    }

    /// Without the status file nothing vouches for the terminal.
    @Test func withoutAStatusFileThereIsNoTarget() throws {
        var state = CollectiveState()
        try interactiveHooks(terminal: try TerminalFixtures.warpTab()).forEach { state.apply($0) }

        #expect(state.sessions[TerminalFixtures.Interactive.first]?.terminalTarget == nil)
    }

    /// Run 22 up to its `Stop`, with its status file read before the spool
    /// or after it, and its hooks carrying `terminal`.
    private func backgroundSession(terminal: [String: String], statusFirst: Bool = false) throws -> Session {
        let state = try backgroundState(terminal: terminal, statusFirst: statusFirst)
        let session = try #require(state.sessions[TerminalFixtures.Background.session])
        #expect(session.endedAt == nil)
        return session
    }

    private func backgroundState(terminal: [String: String], statusFirst: Bool = false) throws -> CollectiveState {
        let folder = TerminalFixtures.Background.folder
        let status = try #require(terminalReport(try TerminalFixtures.status(folder, "003-status.json")))
        var state = CollectiveState()
        if statusFirst { state.apply(status) }
        let hooks = try TerminalFixtures.payloads(in: folder).dropLast()
        try hookEvents(Array(hooks), pid: TerminalFixtures.Background.pid, terminal: terminal).forEach { state.apply($0) }
        if !statusFirst { state.apply(status) }
        return state
    }

    /// Run 22 as captured: the daemon's Warp tab, so only Warp may come
    /// forward, named by the URL it must never open.
    @Test(arguments: [false, true])
    func aBackgroundSessionNamesTheAppByItsHostsURL(statusFirst: Bool) throws {
        let terminal = try TerminalFixtures.terminal(TerminalFixtures.Background.folder.appendingPathComponent("terminal.json"))
        let session = try backgroundSession(terminal: terminal, statusFirst: statusFirst)
        #expect(session.terminalTarget == .appHandling(URL(string: "warp://session/1b10f2936c54494a955cc11fd5ab3b22")!))
    }

    /// No background capture has `__CFBundleIdentifier`: run 22's terminal
    /// with run 21's added, as a daemon started from Warp's shell would have
    /// it. The bundle names the app; the tab stays the daemon's.
    @Test func aBackgroundSessionWithTheAppsBundleTargetsTheApp() throws {
        var terminal = try TerminalFixtures.terminal(TerminalFixtures.Background.folder.appendingPathComponent("terminal.json"))
        terminal["__CFBundleIdentifier"] = try TerminalFixtures.warpTab()["__CFBundleIdentifier"]
        #expect(try backgroundSession(terminal: terminal).terminalTarget == .app(bundleID: "dev.warp.Warp-Stable"))
    }

    /// "Show in Warp" without its tab (design `terminal-focus.md`, "Benennung":
    /// "andere App, nur App").
    @Test func aBackgroundSessionOffersOnlyTheApp() throws {
        let terminal = try TerminalFixtures.terminal(TerminalFixtures.Background.folder.appendingPathComponent("terminal.json"))
        let action = try #require(TerminalAction(session: try backgroundSession(terminal: terminal), apps: InstalledWarp()))
        #expect(action.target == .appHandling(URL(string: "warp://session/1b10f2936c54494a955cc11fd5ab3b22")!))
        #expect(action.bundleID == "dev.warp.Warp-Stable")
        #expect(!action.selectsTab)
        #expect(en(action.title) == "Show in Warp")
        #expect(en(action.help) == "Brings Warp to the front. It can’t select the session’s tab.")
        // A host's tab: the jump button only brings Warp forward.
        let item = try card(TerminalFixtures.Background.session, in: try backgroundState(terminal: terminal))
        #expect(item.terminalAction == action)
        #expect(item.jumpAction == action)
    }

    @Test func aBackgroundSessionWithoutIdentifiersHasNoTarget() throws {
        #expect(try backgroundSession(terminal: [:]).terminalTarget == nil)
    }

    /// The job's file is gone: nothing vouches for the app anymore either.
    @Test func aWithdrawnHostReportRemovesTheTarget() throws {
        let terminal = try TerminalFixtures.terminal(TerminalFixtures.Background.folder.appendingPathComponent("terminal.json"))
        let folder = TerminalFixtures.Background.folder
        var state = CollectiveState()
        try hookEvents(Array(try TerminalFixtures.payloads(in: folder).dropLast()), pid: TerminalFixtures.Background.pid,
                       terminal: terminal).forEach { state.apply($0) }
        state.apply(try #require(terminalReport(try TerminalFixtures.status(folder, "003-status.json"))))
        #expect(state.sessions[TerminalFixtures.Background.session]?.terminalTarget != nil)

        state.apply(reported(.unusable, pid: TerminalFixtures.Background.pid, session: TerminalFixtures.Background.session,
                             at: TerminalFixtures.Background.startedAt))
        #expect(state.sessions[TerminalFixtures.Background.session]?.terminalTarget == nil)
    }

    /// Run 22's terminal with its focus URL broken: nothing names the app.
    @Test func aBackgroundSessionWithAMalformedFocusURLHasNoTarget() throws {
        var terminal = try TerminalFixtures.terminal(TerminalFixtures.Background.folder.appendingPathComponent("terminal.json"))
        terminal["WARP_FOCUS_URL"] = "warp://session/1b10f293"
        #expect(try backgroundSession(terminal: terminal).terminalTarget == nil)
    }

    /// The file is gone (`/exit`), the session not yet ended.
    @Test func aWithdrawnReportRemovesTheTarget() throws {
        var state = CollectiveState()
        try interactiveHooks(terminal: try TerminalFixtures.warpTab()).forEach { state.apply($0) }
        state.apply(try interactiveReport())
        state.apply(reported(.unusable, pid: TerminalFixtures.Interactive.pid))

        #expect(state.sessions[TerminalFixtures.Interactive.first]?.terminalTarget == nil)
    }

}

/// Codex sessions have no pid (contract §6, "Session liveness"), and their
/// terminal is a host's: only the app comes forward.
@Suite struct CodexTerminalTargetTests {
    private func codexState(terminal: [String: String]) throws -> CollectiveState {
        var state = CollectiveState()
        try codexEvents(terminal: terminal).forEach { state.apply($0) }
        #expect(state.sessions[codexSession]?.pid == nil)
        return state
    }

    /// Run 21's terminal: the bundle names the app, its tab is the daemon's.
    @Test func aCodexSessionTargetsTheApp() throws {
        let state = try codexState(terminal: try TerminalFixtures.warpTab())
        #expect(state.sessions[codexSession]?.terminalTarget == .app(bundleID: "dev.warp.Warp-Stable"))
    }

    /// Run 22's terminal, only Warp's variables: named by the URL it must never open.
    @Test func aCodexSessionWithOnlyWarpsURLNamesTheAppByIt() throws {
        let terminal = try TerminalFixtures.terminal(TerminalFixtures.Background.folder.appendingPathComponent("terminal.json"))
        let state = try codexState(terminal: terminal)
        #expect(state.sessions[codexSession]?.terminalTarget
            == .appHandling(URL(string: "warp://session/1b10f2936c54494a955cc11fd5ab3b22")!))
    }

    /// "Show in Warp" without its tab (design `terminal-focus.md`, "Benennung":
    /// "andere App, nur App").
    @Test func aCodexSessionOffersOnlyTheApp() throws {
        let state = try codexState(terminal: try TerminalFixtures.warpTab())
        let session = try #require(state.sessions[codexSession])
        let action = try #require(TerminalAction(session: session, apps: InstalledWarp()))
        #expect(action.target == .app(bundleID: "dev.warp.Warp-Stable"))
        #expect(!action.selectsTab)
        #expect(en(action.title) == "Show in Warp")
        #expect(en(action.help) == "Brings Warp to the front. It can’t select the session’s tab.")

        let model = PopoverModel(state: state, now: t0.addingTimeInterval(60), settings: PopoverSettings(idleAfter: .never),
                                 terminalApps: InstalledWarp())
        let card = try #require((model.sessions + model.idle + model.finished).first { $0.key == codexSession })
        #expect(card.terminalAction == action)
        // The shared daemon's tab: the jump button only brings Warp forward.
        #expect(card.jumpAction == action)
    }

    /// The ChatGPT app's sessions carry no `terminal`.
    @Test func aCodexSessionWithoutIdentifiersHasNoTarget() throws {
        #expect(try codexState(terminal: [:]).sessions[codexSession]?.terminalTarget == nil)
    }

    /// The session moves to where Codex sends no `terminal`: nothing names an app anymore.
    @Test func aCodexSessionWhoseTerminalGoesHasNoTarget() throws {
        let adapter = CodexAdapter(rolloutReader: NoRollouts(), mapping: bundledMapping())
        var state = CollectiveState()
        for (index, payload) in CodexRun.headless.payloads.enumerated() {
            let terminal = index < 3 ? try TerminalFixtures.warpTab() : [:]
            try adapter.events(from: Envelope(source: "codex", pid: 4242, payload: payload,
                                              receivedAt: t0.addingTimeInterval(TimeInterval(index)), terminal: terminal))
                .forEach { state.apply($0) }
            if index == 2 { #expect(state.sessions[codexSession]?.terminalTarget == .app(bundleID: "dev.warp.Warp-Stable")) }
        }
        #expect(state.sessions[codexSession]?.terminalTarget == nil)
    }

    /// More than 12 h later in the ChatGPT app: "Show in Warp" doesn't come back.
    @Test func aCodexSessionBackWithoutTerminalAfterExpiryHasNoTarget() throws {
        var state = CollectiveState()
        try codexEventsResumedWithoutTerminal().forEach { state.apply($0) }
        #expect(state.sessions[codexSession] != nil)
        #expect(state.sessions[codexSession]?.terminalTarget == nil)
    }

    /// Presumed dead, as after `waitingTimeout` without a process.
    @Test func aStaleCodexSessionHasNoTarget() throws {
        var state = try codexState(terminal: try TerminalFixtures.warpTab())
        #expect(state.sessions[codexSession]?.terminalTarget != nil)
        let at = try #require(state.sessions[codexSession]).lastActivity
        state.markStale(now: at.addingTimeInterval(10), silenceTimeout: 1, waitingTimeout: 1, processStart: { _ in nil })
        #expect(state.sessions[codexSession]?.root.status == .stale)
        #expect(state.sessions[codexSession]?.terminalTarget == nil)
    }

    /// A report without a pid is about a session without one: it neither
    /// applies to a session that has a pid nor waits for one.
    @Test func aReportWithoutAPidDoesNotApplyToASessionWithOne() throws {
        var state = CollectiveState()
        try interactiveHooks(terminal: try TerminalFixtures.warpTab()).forEach { state.apply($0) }
        state.apply(AgentEvent(session: TerminalFixtures.Interactive.first, timestamp: TerminalFixtures.Interactive.startedAt,
                               kind: .terminalReported(.session)))
        #expect(state.sessions[TerminalFixtures.Interactive.first]?.terminalTarget == nil)
    }

    /// And a report that names a pid never applies to a session without one.
    @Test func aReportWithAPidDoesNotApplyToACodexSession() throws {
        var state = CollectiveState()
        let adapter = CodexAdapter(rolloutReader: NoRollouts(), mapping: bundledMapping())
        let terminal = try TerminalFixtures.warpTab()
        for (index, payload) in CodexRun.headless.payloads.enumerated() {
            try adapter.events(from: Envelope(source: "codex", pid: 4242, payload: payload,
                                              receivedAt: t0.addingTimeInterval(TimeInterval(index)), terminal: terminal))
                .filter { if case .terminalReported = $0.kind { false } else { true } }
                .forEach { state.apply($0) }
        }
        state.apply(AgentEvent(session: codexSession, timestamp: t0, kind: .terminalReported(.session), pid: 4242))
        #expect(state.sessions[codexSession]?.terminalTarget == nil)
    }
}

/// The report follows the owner rule of reports and names (contract §13,
/// "Owner"): only from the session's own process, and it is no activity.
@Suite struct TerminalReportStoreTests {
    private let key = TerminalFixtures.Interactive.first
    private let pid = TerminalFixtures.Interactive.pid
    private let other: Int32 = 4321

    private func interactiveSession() throws -> CollectiveState {
        var state = CollectiveState()
        try interactiveHooks(terminal: try TerminalFixtures.warpTab()).forEach { state.apply($0) }
        return state
    }

    /// Another process's file names the session, e.g. a daemon's for a
    /// moment on `claude attach`: it waits for a resume in that process.
    @Test func aReportFromAnotherProcessWaitsForIt() throws {
        var state = try interactiveSession()
        state.apply(reported(.session, pid: other))
        #expect(state.sessions[key]?.terminalTarget == nil)

        // `--resume` in that process, from a terminal known only by its app.
        let resumed = AgentEvent(session: key, timestamp: t0.addingTimeInterval(60), kind: .sessionStarted(cwd: nil, pid: other),
                                 pid: other, terminal: TerminalIdentifiers(["__CFBundleIdentifier": "dev.warp.Warp-Stable"]))
        state.apply(resumed)
        #expect(state.sessions[key]?.pid == other)
        #expect(state.sessions[key]?.terminalTarget == .app(bundleID: "dev.warp.Warp-Stable"))
    }

    @Test func aReportBeforeAnyEventDoesNotMakeTheSessionAppear() {
        var state = CollectiveState()
        state.apply(reported(.session, pid: pid))
        #expect(state.sessions.isEmpty)
    }

    /// A resume in another process: what the old one reported and its
    /// terminal are the old tab's.
    @Test func aNewProcessStartsWithoutAReport() throws {
        var state = try interactiveSession()
        state.apply(reported(.session, pid: pid))
        #expect(state.sessions[key]?.terminalTarget != nil)

        state.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(60), kind: .sessionStarted(cwd: nil, pid: other),
                               pid: other, terminal: TerminalIdentifiers(try TerminalFixtures.warpTab())))
        #expect(state.sessions[key]?.pid == other)
        #expect(state.sessions[key]?.terminalTarget == nil)

        state.apply(reported(.session, pid: other))
        #expect(state.sessions[key]?.terminalTarget == .url(warpTab, bundleID: "dev.warp.Warp-Stable"))
    }

    /// Without a new run's start the old process's report must not
    /// carry over to the next one either.
    @Test func aProcessLearnedWithoutAReportHasNoTarget() throws {
        var state = CollectiveState()
        // The session is first seen from another process; its old process's file reports.
        state.apply(AgentEvent(session: key, timestamp: t0, kind: .promptSubmitted("hi"), pid: other,
                               terminal: TerminalIdentifiers(try TerminalFixtures.warpTab())))
        state.apply(reported(.session, pid: pid))
        #expect(state.sessions[key]?.pid == other)
        #expect(state.sessions[key]?.terminalTarget == nil)
    }

    /// Hooks of another process for the session keep the own process's terminal.
    @Test func anotherProcessesTerminalDoesNotReplaceTheSessions() throws {
        var state = try interactiveSession()
        state.apply(reported(.session, pid: pid))
        let daemonTab = try TerminalFixtures.terminal(TerminalFixtures.Background.folder.appendingPathComponent("terminal.json"))
        state.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(30), kind: .turnStarted, pid: other,
                               terminal: TerminalIdentifiers(daemonTab)))

        #expect(state.sessions[key]?.pid == pid)
        #expect(state.sessions[key]?.terminalTarget == .url(warpTab, bundleID: "dev.warp.Warp-Stable"))
    }

    /// Like a name, it changes nothing a card shows or sorts by.
    @Test func aReportIsNoActivity() throws {
        var state = try interactiveSession()
        let before = try #require(state.sessions[key])
        state.apply(reported(.session, pid: pid, at: before.lastActivity.addingTimeInterval(600)))
        let after = try #require(state.sessions[key])

        #expect(after.terminalTarget != nil)
        #expect(after.lastActivity == before.lastActivity)
        #expect(after.root == before.root)
        #expect(after.lastPromptAt == before.lastPromptAt)
        #expect(after.restingSince == before.restingSince)
        #expect(after.restsBegun == before.restsBegun)
    }

    /// Nor does it prove a session alive that the sweep took for dead.
    @Test func aReportDoesNotReviveAStaleSession() throws {
        var state = try interactiveSession()
        let at = try #require(state.sessions[key]).lastActivity
        state.markStale(now: at.addingTimeInterval(10), silenceTimeout: 1, waitingTimeout: 1, processStart: { _ in nil })
        #expect(state.sessions[key]?.root.status == .stale)

        state.apply(reported(.session, pid: pid))
        #expect(state.sessions[key]?.root.status == .stale)
    }

    /// A dead process leaves its status file behind (contract §13, "Lifetime"),
    /// so nothing vouches for the tab; an event from the process brings it back.
    @Test func aStaleSessionHasNoTargetUntilRevived() throws {
        var state = try interactiveSession()
        state.apply(reported(.session, pid: pid))
        let at = try #require(state.sessions[key]).lastActivity
        state.markStale(now: at.addingTimeInterval(10), silenceTimeout: 1, waitingTimeout: 1, processStart: { _ in nil })
        #expect(state.sessions[key]?.root.status == .stale)
        #expect(state.sessions[key]?.terminalTarget == nil)

        state.apply(AgentEvent(session: key, timestamp: at.addingTimeInterval(20), kind: .turnStarted, pid: pid,
                               terminal: TerminalIdentifiers(try TerminalFixtures.warpTab())))
        #expect(state.sessions[key]?.root.status != .stale)
        #expect(state.sessions[key]?.terminalTarget == .url(warpTab, bundleID: "dev.warp.Warp-Stable"))
    }

    /// An ended session takes none; it waits for a next run, like a report.
    @Test func anEndedSessionKeepsItForItsNextRun() throws {
        var state = try interactiveSession()
        state.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(20), kind: .sessionEnded, pid: pid))
        state.apply(reported(.session, pid: pid))
        #expect(state.sessions[key]?.terminalTarget == nil)

        state.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(40), kind: .sessionStarted(cwd: nil, pid: pid),
                               pid: pid, terminal: TerminalIdentifiers(try TerminalFixtures.warpTab())))
        #expect(state.sessions[key]?.terminalTarget == .url(warpTab, bundleID: "dev.warp.Warp-Stable"))
    }

    /// `/exit` (subspace capture 2.1.287/1-idle-exit): `SessionEnd` comes
    /// first, the status file is deleted after it. Without the file nothing
    /// vouches for the tab (contract §6, "Terminal").
    @Test func aWithdrawalAfterTheEndRemovesTheTarget() throws {
        var state = try interactiveSession()
        state.apply(reported(.session, pid: pid))
        state.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(20), kind: .sessionEnded, pid: pid))
        #expect(state.sessions[key]?.terminalTarget == .url(warpTab, bundleID: "dev.warp.Warp-Stable"))

        state.apply(reported(.unusable, pid: pid))
        #expect(state.sessions[key]?.terminalTarget == nil)
    }

    /// A report kept for a next run goes with the file, as before the end.
    @Test func aWithdrawalAfterTheEndDropsTheKeptReport() throws {
        var state = try interactiveSession()
        state.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(20), kind: .sessionEnded, pid: pid))
        state.apply(reported(.session, pid: pid))
        state.apply(reported(.unusable, pid: pid))

        state.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(40), kind: .sessionStarted(cwd: nil, pid: pid),
                               pid: pid, terminal: TerminalIdentifiers(try TerminalFixtures.warpTab())))
        #expect(state.sessions[key]?.terminalTarget == nil)
    }

    /// Another process's file going away says nothing about the session's tab.
    @Test func aWithdrawalFromAnotherProcessAfterTheEndChangesNothing() throws {
        var state = try interactiveSession()
        state.apply(reported(.session, pid: pid))
        state.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(20), kind: .sessionEnded, pid: pid))
        state.apply(reported(.unusable, pid: other))
        #expect(state.sessions[key]?.terminalTarget == .url(warpTab, bundleID: "dev.warp.Warp-Stable"))
    }

    @Test func aWaitingReportIsPrunedWithItsSession() throws {
        var state = CollectiveState()
        state.apply(reported(.session, pid: pid))
        state.prune(now: t0, retention: 60)
        state.prune(now: t0.addingTimeInterval(61), retention: 60)
        try interactiveHooks(terminal: try TerminalFixtures.warpTab()).forEach { state.apply($0) }

        #expect(state.sessions[key]?.terminalTarget == nil)
    }
}

// MARK: - Seam: CollectiveState.apply(_:) and PopoverModel, run 17 replayed

/// Run 17 in the order of its `timeline.jsonl` (subspace
/// `fixtures/claude-code/2.1.289/17-model-clear`): `/clear` switches the
/// process's status file from the first session to the second, `/exit`
/// deletes the file, then the second session ends. Hooks arrive in envelopes
/// at their captured time, with run 21's Warp `terminal`.
private enum Run17 {
    enum Step {
        case status(String)
        case hook(String, ms: Int64)
        /// The file is deleted: the status source withdraws what it last
        /// reported, the second session (`ClaudeCodeSessionStatusSource`).
        case fileDeleted
    }

    static let throughClear: [Step] = [
        .status("001-status.json"), .hook("002-SessionStart.json", ms: 1_791_212_478_426),
        .status("003-status.json"), .hook("004-InstructionsLoaded.json", ms: 1_791_212_478_659),
        .hook("005-InstructionsLoaded.json", ms: 1_791_212_478_659), .status("006-status.json"),
        .hook("007-UserPromptSubmit.json", ms: 1_791_212_482_232), .hook("008-Stop.json", ms: 1_791_212_483_463),
        .status("009-status.json"), .status("010-status.json"),
        .hook("011-PostModelSwitch.json", ms: 1_791_212_489_161), .status("012-status.json"),
        // `/clear`
        .status("013-status.json"), .hook("014-SessionEnd.json", ms: 1_791_212_492_893),
        .hook("015-SessionStart.json", ms: 1_791_212_492_914), .status("016-status.json"),
        .hook("017-UserPromptSubmit.json", ms: 1_791_212_496_615), .hook("018-InstructionsLoaded.json", ms: 1_791_212_496_683),
        .hook("019-InstructionsLoaded.json", ms: 1_791_212_496_683), .hook("020-Stop.json", ms: 1_791_212_497_938),
        .status("021-status.json"),
    ]
    // `/exit`
    static let exit: [Step] = [.fileDeleted, .hook("022-SessionEnd.json", ms: 1_791_212_503_799)]
    static let exitedAt = Date(timeIntervalSince1970: 1_791_212_505.467)

    static func apply(_ steps: [Step], to state: inout CollectiveState) throws {
        let folder = TerminalFixtures.Interactive.folder
        let pid = TerminalFixtures.Interactive.pid
        let adapter = ClaudeCodeAdapter(metaReader: NoMeta(), mapping: bundledMapping())
        for step in steps {
            switch step {
            case let .status(file):
                let events = ClaudeCodeSessionStatusSource.events(
                    from: try TerminalFixtures.status(folder, file), mapping: sessionMapping, processStart: alive)
                [events.activity, events.name, events.terminal].compactMap { $0 }.forEach { state.apply($0) }
            case let .hook(file, ms):
                let payload = try Data(contentsOf: folder.appendingPathComponent("events/\(file)"))
                let envelope = Envelope(source: "claude-code", pid: pid, payload: payload,
                                        receivedAt: Date(timeIntervalSince1970: TimeInterval(ms) / 1000),
                                        terminal: try TerminalFixtures.warpTab())
                try adapter.events(from: envelope).forEach { state.apply($0) }
            case .fileDeleted:
                let last = try #require(terminalReport(try TerminalFixtures.status(folder, "021-status.json")))
                state.apply(AgentEvent(session: last.session, timestamp: last.timestamp, kind: .terminalReported(.unusable), pid: pid))
            }
        }
    }
}

/// Resolves Warp, as installed: by its bundle and as the handler of `warp:` URLs.
private struct InstalledWarp: TerminalApps {
    func app(bundleID: String) -> TerminalApp? {
        bundleID == "dev.warp.Warp-Stable" ? TerminalApp(bundleID: bundleID, name: "Warp") : nil
    }
    func app(opening url: URL) -> TerminalApp? {
        url.scheme == "warp" ? app(bundleID: "dev.warp.Warp-Stable") : nil
    }
}

/// A withdrawal is about the process: when its status file goes, no session
/// it reported keeps a terminal, also one it ran before `/clear`
/// (contract §6, "Terminal").
@Suite struct ClearThenExitTerminalTests {
    private let first = TerminalFixtures.Interactive.first
    private let second = TerminalFixtures.Interactive.second

    /// While the process runs, the session ended by `/clear` keeps its tab.
    @Test func afterClearBothSessionsKeepTheirTab() throws {
        var state = CollectiveState()
        try Run17.apply(Run17.throughClear, to: &state)

        #expect(state.sessions[first]?.endedAt != nil)
        #expect(state.sessions[first]?.terminalTarget == .url(warpTab, bundleID: "dev.warp.Warp-Stable"))
        #expect(state.sessions[second]?.terminalTarget == .url(warpTab, bundleID: "dev.warp.Warp-Stable"))
    }

    @Test func afterExitNeitherSessionHasATarget() throws {
        var state = CollectiveState()
        try Run17.apply(Run17.throughClear + Run17.exit, to: &state)

        #expect(state.sessions[first]?.endedAt != nil)
        #expect(state.sessions[second]?.endedAt != nil)
        #expect(state.sessions[first]?.terminalTarget == nil)
        #expect(state.sessions[second]?.terminalTarget == nil)

        let finished = PopoverModel(state: state, now: Run17.exitedAt, settings: PopoverSettings(idleAfter: .never),
                                    terminalApps: InstalledWarp()).finished
        let firstRow = try #require(finished.first { $0.key == first })
        #expect(firstRow.terminalAction == nil)
        #expect(finished.allSatisfy { $0.terminalAction == nil })
    }

    /// Another process's file going away says nothing about this one's tabs.
    @Test func aWithdrawalFromAnotherProcessKeepsTheTab() throws {
        var state = CollectiveState()
        try Run17.apply(Run17.throughClear, to: &state)
        state.apply(reported(.unusable, pid: 4321, session: second))
        state.apply(reported(.unusable, pid: 4321, session: first))

        #expect(state.sessions[first]?.terminalTarget == .url(warpTab, bundleID: "dev.warp.Warp-Stable"))
        #expect(state.sessions[second]?.terminalTarget == .url(warpTab, bundleID: "dev.warp.Warp-Stable"))
    }
}
