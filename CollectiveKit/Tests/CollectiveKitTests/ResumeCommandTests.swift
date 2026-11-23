import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// MARK: - Seam 1: the adapter's resume command

@Suite struct AdapterResumeCommandTests {
    /// `claude --resume <id>`, checked against Claude Code 2.1.316.
    @Test func claudeCodeResumesBySessionID() {
        let command = ClaudeCodeAdapter().resumeCommand
        #expect(command?.arguments(sessionID: "a1b2") == ["claude", "--resume", "a1b2"])
    }

    /// `codex resume <SESSION_ID>`, checked against Codex 0.166.0.
    @Test func codexResumesBySessionID() {
        let command = CodexAdapter().resumeCommand
        #expect(command?.arguments(sessionID: "a1b2") == ["codex", "resume", "a1b2"])
    }

    @Test func anAdapterWithoutOneHasNone() {
        #expect(PlainAdapter().resumeCommand == nil)
    }
}

// MARK: - Seam 2: the command line from the adapter's command and the cwd

@Suite struct ResumeCommandLineTests {
    private let command = ResumeCommand { ["tt", "resume", $0] }

    @Test func withoutACwdItIsTheCommandAlone() {
        #expect(command.commandLine(sessionID: "a1b2", cwd: nil) == "tt resume a1b2")
    }

    @Test func aPlainCwdGoesInUnquoted() {
        #expect(command.commandLine(sessionID: "a1b2", cwd: "/Users/user/my-app") == "cd /Users/user/my-app && tt resume a1b2")
    }

    @Test func aCwdWithSpacesGetsSingleQuotes() {
        #expect(command.commandLine(sessionID: "a1b2", cwd: "/Users/user/My Projects/app") == "cd '/Users/user/My Projects/app' && tt resume a1b2")
    }

    @Test func aSingleQuoteInTheCwdIsEscaped() {
        #expect(command.commandLine(sessionID: "a1b2", cwd: "/tmp/it's here") == #"cd '/tmp/it'\''s here' && tt resume a1b2"#)
    }

    /// Session IDs are UUIDs, but go through the same quoting.
    @Test func argumentsAreQuotedWhenNeeded() {
        #expect(command.commandLine(sessionID: "my session", cwd: nil) == "tt resume 'my session'")
    }
}

// MARK: - Seam 3: what a card and a finished row copy

@Suite struct SessionItemResumeTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func replay(_ payloads: [Data], source: SourceID, with adapter: some PushAdapter) throws -> CollectiveState {
        var state = CollectiveState()
        for (index, payload) in payloads.enumerated() {
            let envelope = Envelope(source: source, pid: 4242, payload: payload, receivedAt: t0.addingTimeInterval(TimeInterval(index)))
            for event in try adapter.events(from: envelope) { state.apply(event) }
        }
        return state
    }

    /// The resume commands as the app collects them from its adapters.
    private func model(_ state: CollectiveState, adapters: [any PushAdapter]) -> PopoverModel {
        PopoverModel(
            state: state, now: t0.addingTimeInterval(60), settings: PopoverSettings(),
            resumeCommands: Dictionary(uniqueKeysWithValues: adapters.compactMap { adapter in adapter.resumeCommand.map { (adapter.source, $0) } })
        )
    }

    /// The headless run ends with `SessionEnd`, so it is a finished row.
    @Test func aFinishedClaudeCodeRowResumesInItsProjectFolder() throws {
        let adapter = Run.headless.adapter()
        let state = try replay(Run.headless.payloads, source: "claude-code", with: adapter)
        let item = try #require(model(state, adapters: [adapter]).finished.first)
        #expect(item.sessionID == "0505288b-ea45-4223-8992-a11388993320")
        #expect(item.resumeCommand == "cd /Users/user/dev/subspace/tools/hook-capture && claude --resume 0505288b-ea45-4223-8992-a11388993320")
    }

    /// The session ID is the thread UUID of the rollout's file name, which `codex resume` takes.
    @Test func aCodexCardResumesInItsFolderWithSpaces() throws {
        let adapter = CodexRun.cwdWithSpaces.adapter()
        let state = try replay(CodexRun.cwdWithSpaces.payloads, source: "codex", with: adapter)
        let item = try #require(model(state, adapters: [adapter]).sessions.first)
        #expect(item.sessionID == "01a0f73c-f632-7622-a755-51d3ace56468")
        #expect(item.resumeCommand == "cd '/Users/user/dev/subspace/tools/hook-capture/codex/captures/project with spaces' && codex resume 01a0f73c-f632-7622-a755-51d3ace56468")
    }

    @Test func aSourceWithoutOneOffersOnlyTheSessionID() {
        let key = SessionKey(source: "test-tool", sessionID: "s1")
        var state = CollectiveState()
        state.apply(AgentEvent(session: key, timestamp: t0, kind: .sessionStarted(cwd: "/tmp/app", pid: nil)))
        state.apply(AgentEvent(session: key, timestamp: t0, kind: .promptSubmitted("x")))
        let item = model(state, adapters: [PlainAdapter()]).sessions.first
        #expect(item?.sessionID == "s1")
        #expect(item != nil && item?.resumeCommand == nil)
    }

    // "Copy Path" copies the folder alone, quoted for a terminal only when needed.

    @Test func aFinishedClaudeCodeRowCopiesItsPlainPathUnquoted() throws {
        let adapter = Run.headless.adapter()
        let state = try replay(Run.headless.payloads, source: "claude-code", with: adapter)
        let item = try #require(model(state, adapters: [adapter]).finished.first)
        #expect(item.quotedPath == "/Users/user/dev/subspace/tools/hook-capture")
    }

    @Test func aCodexCardCopiesItsPathWithSpacesInSingleQuotes() throws {
        let adapter = CodexRun.cwdWithSpaces.adapter()
        let state = try replay(CodexRun.cwdWithSpaces.payloads, source: "codex", with: adapter)
        let item = try #require(model(state, adapters: [adapter]).sessions.first)
        #expect(item.quotedPath == "'/Users/user/dev/subspace/tools/hook-capture/codex/captures/project with spaces'")
    }

    /// An empty folder would quote to `''`, which is no path to go to.
    @Test(arguments: [nil, ""] as [String?])
    func aSessionWithoutAKnownFolderOffersNoPath(cwd: String?) throws {
        let key = SessionKey(source: "test-tool", sessionID: "s1")
        var state = CollectiveState()
        state.apply(AgentEvent(session: key, timestamp: t0, kind: .sessionStarted(cwd: cwd, pid: nil)))
        state.apply(AgentEvent(session: key, timestamp: t0, kind: .promptSubmitted("x")))
        let item = try #require(model(state, adapters: [PlainAdapter()]).sessions.first)
        #expect(item.quotedPath == nil)
    }
}

/// A tool that names no resume command.
private final class PlainAdapter: PushAdapter {
    let source: SourceID = "test-tool"
    let displayName = "Test Tool"
    func events(from envelope: Envelope) throws -> [AgentEvent] { [] }
    func spoolRoot(environment: [String: String], home: URL) -> URL { home }
}
