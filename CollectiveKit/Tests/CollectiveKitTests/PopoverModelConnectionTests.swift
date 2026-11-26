import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

private let source: SourceID = "test-tool"
private let t0 = Date(timeIntervalSince1970: 1_000)

/// One working session, so the list has something to keep showing.
private let working: CollectiveState = {
    var state = CollectiveState()
    state.apply(AgentEvent(session: SessionKey(source: source, sessionID: "s1"), timestamp: t0, kind: .sessionStarted(cwd: "/tmp/alpha", pid: nil)))
    return state
}()

private func model(
    _ state: CollectiveState = working,
    connection: ConnectionStatus,
    expansion: PopoverExpansion = PopoverExpansion(),
    undo: ArchiveUndo = ArchiveUndo()
) -> PopoverModel {
    PopoverModel(state: state, now: t0.addingTimeInterval(10), settings: PopoverSettings(), lastEventAt: t0, expansion: expansion, undo: undo, connection: connection)
}

/// One working, one waiting and two finished sessions.
private func mixed() -> CollectiveState {
    var state = CollectiveState()
    func started(_ id: String) -> SessionKey {
        let key = SessionKey(source: source, sessionID: id)
        state.apply(AgentEvent(session: key, timestamp: t0, kind: .sessionStarted(cwd: "/tmp/\(id)", pid: nil)))
        return key
    }
    state.apply(AgentEvent(session: started("working"), timestamp: t0, kind: .promptSubmitted("Go")))
    let waiting = started("waiting")
    state.apply(AgentEvent(session: waiting, timestamp: t0.addingTimeInterval(1), kind: .turnEnded()))
    for id in ["done1", "done2"] {
        state.apply(AgentEvent(session: started(id), timestamp: t0.addingTimeInterval(2), kind: .sessionEnded))
    }
    return state
}

private let warnings: [ConnectionStatus] = [.missing(integration(.notInstalled)), .disabled(integration(.disabled(version: nil)))]

private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

@Suite struct PopoverModelConnectionTests {
    @Test func okShowsNoWarningAndTheUsualFooter() {
        let popover = model(connection: .ok)
        #expect(popover.warning == nil)
        #expect(!popover.footerIsWarning)
        #expect(popover.footerParts(at: t0.addingTimeInterval(10)).map(en) == ["Linked to subspace", "last event 10 s ago"])
    }

    /// It names the tool whose install commands follow, not a fixed list of tools.
    @Test func missingWarnsWithInstallCommandsAndNamesTheTool() throws {
        let status = integration(.notInstalled)
        let popover = model(connection: .missing(status))
        let warning = try #require(popover.warning)
        #expect(en(warning.title) == "subspace isn’t installed")
        #expect(en(warning.text) == "The Collective sees your agents through subspace, a small plugin for Test Tool that records session events. Install it once; sessions you start afterwards appear here.")
        #expect(warning.commands == status.commands.install)
        #expect(en(warning.hint) == "Restart running sessions afterwards.")
        #expect(warning.showsSetUp)
        #expect(popover.footerIsWarning)
        #expect(popover.footerParts(at: t0.addingTimeInterval(10)).map(en) == ["subspace not installed"])
    }

    /// The warning box shows one Copy button per entry, so no entry may hold two commands.
    @Test func realWarningCommandsHoldOneCommandPerEntry() throws {
        var missing = integration(.notInstalled, source: "claude-code", toolName: "Claude Code")
        missing.commands = ClaudeCodeSubspace.commands
        var disabled = integration(.disabled(version: "0.4.0"), source: "claude-code", toolName: "Claude Code")
        disabled.commands = ClaudeCodeSubspace.commands
        var codex = integration(.notInstalled, source: "codex", toolName: "Codex")
        codex.commands = CodexSubspace.commands
        var antigravity = integration(.notInstalled, source: "antigravity", toolName: "Antigravity")
        antigravity.commands = AntigravitySubspace.commands
        var antigravityOff = integration(.disabled(version: "1.0.0"), source: "antigravity", toolName: "Antigravity")
        antigravityOff.commands = AntigravitySubspace.commands
        for connection in [ConnectionStatus.missing(missing), .disabled(disabled), .missing(codex), .missing(antigravity), .disabled(antigravityOff)] {
            let warning = try #require(model(connection: connection).warning)
            #expect(!warning.commands.isEmpty)
            for line in warning.commands {
                #expect(!line.contains("\n"))
                #expect(line.components(separatedBy: " plugin ").count == 2)
            }
        }
    }

    @Test func disabledWarnsWithEnableCommandsAndNamesTheTool() throws {
        let status = integration(.disabled(version: "0.4.0"))
        let popover = model(connection: .disabled(status))
        let warning = try #require(popover.warning)
        #expect(en(warning.title) == "subspace is disabled")
        #expect(en(warning.text) == "subspace is switched off in Test Tool. Sessions you start from now on won’t appear here; running ones keep reporting until they end.")
        #expect(warning.commands == status.commands.enable)
        #expect(en(warning.hint) == "Restart running sessions afterwards.")
        #expect(warning.showsSetUp)
        #expect(popover.footerIsWarning)
        #expect(popover.footerParts(at: t0.addingTimeInterval(10)).map(en) == ["subspace is disabled"])
    }

    /// While no new events arrive, the known sessions fold into
    /// one closed group under the warning block.
    @Test func warningFoldsAllKnownSessionsIntoAClosedGroup() throws {
        for connection in warnings {
            let popover = model(mixed(), connection: connection)
            #expect(popover.content == .list)
            #expect(popover.sessions.count == 2)
            #expect(popover.finished.count == 2)
            let header = try #require(popover.earlierSessions)
            #expect(header.count == 4)
            #expect(en(header.title) == "4 earlier sessions")
            #expect(!header.isExpanded)
        }
    }

    @Test func oneEarlierSessionIsSingular() throws {
        let header = try #require(model(connection: warnings[0]).earlierSessions)
        #expect(en(header.title) == "1 earlier session")
    }

    @Test func undoRowsDoNotCountAsEarlierSessions() throws {
        var state = mixed()
        var undo = ArchiveUndo()
        undo.archive(.finishedSession(SessionKey(source: source, sessionID: "done1")), in: &state, at: t0.addingTimeInterval(9))
        let header = try #require(model(state, connection: warnings[0], undo: undo).earlierSessions)
        #expect(header.count == 3)
    }

    @Test func withoutWarningThereIsNoEarlierSessionsGroup() {
        #expect(model(mixed(), connection: .ok).earlierSessions == nil)
    }

    @Test func openingTheGroupShowsTheUsualList() throws {
        var expansion = PopoverExpansion()
        expansion.toggleEarlierSessions()
        let popover = model(mixed(), connection: warnings[1], expansion: expansion)
        #expect(try #require(popover.earlierSessions).isExpanded)
        // Both start and prompt at t0, so the session ID breaks the tie.
        #expect(popover.focusOrder == ["waiting", "working"].map { SessionKey(source: source, sessionID: $0) })
        let usual = model(mixed(), connection: .ok, expansion: expansion)
        #expect(popover.sessions == usual.sessions)
        #expect(popover.finished == usual.finished)
        #expect(popover.tabs == usual.tabs)
    }

    /// Hidden rows take no focus, whatever tab is selected.
    @Test func aClosedGroupTakesNoFocus() {
        var expansion = PopoverExpansion()
        expansion.select(.finished)
        let popover = model(mixed(), connection: warnings[0], expansion: expansion)
        #expect(popover.focusOrder.isEmpty)
    }

    @Test func withoutSessionsTheWarningStandsAlone() {
        let popover = model(CollectiveState(), connection: .disabled(integration(.disabled(version: nil))))
        #expect(popover.content == .dormant)
        #expect(popover.warning != nil)
        #expect(popover.earlierSessions == nil)
    }
}
