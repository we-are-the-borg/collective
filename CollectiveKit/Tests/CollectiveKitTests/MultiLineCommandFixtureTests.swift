import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// MARK: - Fixtures

private let s20 = Timeline("20-multiline-command", version: "2.1.316")

private struct NoMeta: SubagentMetaReading {
    func meta(transcriptPath: String, agentID: String) -> SubagentMeta? { nil }
}

private final class MemoryFileSystem: MappingFileSystem {
    func modificationDate(of url: URL) -> Date? { nil }
    func contents(of url: URL) throws -> Data { throw CocoaError(.fileNoSuchFile) }
}

/// A root without `model/`, so the bundled documents are used.
private func bundledMapping() -> MappingLoader {
    MappingLoader(root: URL(filePath: "/spool/root", directoryHint: .isDirectory), fileSystem: MemoryFileSystem())
}

/// The S20 payloads also carry an effort level; these tests are about the call.
private func withoutEffort(_ kinds: [AgentEvent.Kind]) -> [AgentEvent.Kind] {
    kinds.filter { if case .effortReported = $0 { false } else { true } }
}

/// The events of hook `n`, after every earlier hook of the run went through
/// the same adapter.
private func kinds(of n: Int, in run: Timeline) throws -> [AgentEvent.Kind] {
    let adapter = ClaudeCodeAdapter(metaReader: NoMeta(), mapping: bundledMapping())
    let pid = try run.envelopePID()
    for entry in run.entries where entry.isHook && entry.n < n {
        _ = try adapter.events(from: Envelope(source: "claude-code", pid: pid, payload: run.data(entry), receivedAt: entry.at))
    }
    let entry = run.entry(n: n)
    return try withoutEffort(adapter.events(from: Envelope(source: "claude-code", pid: pid, payload: run.data(entry), receivedAt: entry.at)).map(\.kind))
}

private let heredocLine = "cat > captures/s20.txt <<'EOF'"
private let heredoc = "cat > captures/s20.txt <<'EOF'\nalpha\nbeta\nEOF"

// MARK: - Adapter

/// Adapter seam: a Claude Code `Bash` call with a four-line heredoc (S20,
/// 2.1.316) reads its command from the target field `command`.
@Suite struct ClaudeCodeMultiLineCommandTests {
    /// Only the request carries the whole command, for the popover's command
    /// box; its detail stays one line.
    @Test func theRequestCarriesTheWholeCommand() throws {
        #expect(try kinds(of: 10, in: s20) == [
            .permissionRequested(agent: .root, ToolActivity(name: "Bash", detail: heredocLine, fullDetail: heredoc)),
        ])
    }

    @Test func theCallsStartShowsTheFirstLineOnly() throws {
        #expect(try kinds(of: 9, in: s20) == [
            .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: heredocLine), callID: "toolu_014XmejEdghwd5u8ZxSU357E"),
        ])
    }
}

// MARK: - Popover row

/// Model seam: the command box of the replayed request gets the whole
/// command; the view cuts it to `PermissionCommand.lineLimit` lines.
@Suite struct MultiLineCommandRowFixtureTests {
    @Test func aClaudeCodeRequestShowsItsWholeMultiLineCommand() throws {
        let state = try s20.replay(through: 10)
        let last = try #require(state.sessions.values.first?.lastActivity)
        let model = PopoverModel(state: state, now: last.addingTimeInterval(1), settings: PopoverSettings(idleAfter: .never))
        let item = try #require(model.sessions.first)
        #expect(item.rowStatus == .needsPermission)
        #expect(item.rowDetail == .permission(PermissionCommand(toolName: "Bash", command: heredoc)))
    }
}
