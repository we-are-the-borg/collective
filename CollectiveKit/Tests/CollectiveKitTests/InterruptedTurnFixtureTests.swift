import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// MARK: - Timeline replay

/// A recorded Claude Code run of 2.1.287 unless `version` names another:
/// hook payloads and session status snapshots in the order `timeline.jsonl`
/// saw them arrive.
struct Timeline {
    struct Entry {
        let n: Int
        let file: String
        let at: Date
        var isHook: Bool { file.hasPrefix("events/") }
    }

    let run: String
    /// The run's folder in the fixtures of its Claude Code version.
    let directory: URL
    let entries: [Entry]
    /// The run's `claude` process, from its first status snapshot: the hooks'
    /// envelope pid (contract §13), which the captured payloads lack. The
    /// store takes status reports only from the session's own process.
    /// Nil if the run has none; `envelopePID()` fails the test then.
    let pid: Int32?

    init(_ run: String, version: String = "2.1.287") {
        self.run = run
        let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/claude-code/\(version)/\(run)")
        self.directory = directory
        let text = try! String(contentsOf: directory.appendingPathComponent("timeline.jsonl"), encoding: .utf8)
        entries = text.split(separator: "\n").compactMap { line in
            let object = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            guard let n = object["n"] as? Int, let file = object["file"] as? String,
                  let ms = object["ms"] as? Int64 else { return nil }
            // The envelope `ts` has whole seconds.
            return Entry(n: n, file: file, at: Date(timeIntervalSince1970: TimeInterval(ms / 1000)))
        }
        pid = entries.first { !$0.isHook }.flatMap { snapshot in
            let data = try? Data(contentsOf: directory.appendingPathComponent(snapshot.file))
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return (object?["pid"] as? Int).map(Int32.init)
        }
    }

    func data(_ entry: Entry) -> Data {
        try! Data(contentsOf: directory.appendingPathComponent(entry.file))
    }

    func entry(n: Int) -> Entry { entries.first { $0.n == n }! }

    /// `pid` for the hooks' envelopes, failing the calling test if the run
    /// has no status snapshot to take it from.
    func envelopePID() throws -> Int32 {
        try #require(pid, "\(run) has no status snapshot with a pid for the hooks' envelopes")
    }

    /// The status snapshot's `status` value (`busy`, `idle`, `waiting`).
    func snapshotStatus(_ entry: Entry) -> String {
        (try! JSONSerialization.jsonObject(with: data(entry)) as! [String: Any])["status"] as? String ?? "none"
    }

    /// Applies the entries up to and including `n` (all when nil) that pass `filter`,
    /// in the order given by `order`.
    func replay(
        through n: Int? = nil,
        hooks: Bool = true,
        statuses: Bool = true,
        statusesFirst: Bool = false
    ) throws -> CollectiveState {
        var selected = entries.filter { n == nil || $0.n <= n! }
        selected = selected.filter { $0.isHook ? hooks : statuses }
        if statusesFirst { selected = selected.filter { !$0.isHook } + selected.filter(\.isHook) }

        let adapter = ClaudeCodeAdapter(metaReader: NoMeta(), mapping: bundledMapping())
        let statusMapping = try #require(bundledMapping().document(named: ClaudeCodeSessionStatusSource.mappingName))
        // Alive, and started well before the run.
        let processStart: (Int32) -> Date? = { _ in Date(timeIntervalSince1970: 1_000) }

        let pid = try envelopePID()
        var state = CollectiveState()
        for entry in selected {
            let payload = data(entry)
            if entry.isHook {
                let envelope = Envelope(source: "claude-code", pid: pid, payload: payload, receivedAt: entry.at)
                for event in try adapter.events(from: envelope) { state.apply(event) }
            } else if let event = ClaudeCodeSessionStatusSource.event(from: payload, mapping: statusMapping, processStart: processStart) {
                state.apply(event)
            }
        }
        return state
    }
}

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

private extension CollectiveState {
    var root: Agent { sessions.values.first!.root }
}

/// A kit text as an English user reads it, resolved from the kit's catalog.
private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

// MARK: - Tests

@Suite struct InterruptedTurnFixtureTests {
    @Test func escAndCtrlCEndTheTurnAsSoonAsTheStatusFileSaysIdle() throws {
        let run = Timeline("2-interrupt-mid-turn")
        #expect(try run.replay(through: 7).root.status == .working)

        let escaped = try run.replay(through: 8)
        #expect(escaped.root.status == .waiting)
        #expect(escaped.activeAgentCount == 0)

        #expect(try run.replay(through: 9).root.status == .working)
        #expect(try run.replay(through: 11).root.status == .waiting)
    }

    @Test func hooksAloneStayWorkingAfterAnInterrupt() throws {
        // The bug the timeout fallback has to catch: no Stop hook follows an interrupt.
        let state = try Timeline("2-interrupt-mid-turn").replay(through: 11, statuses: false)
        #expect(state.root.status == .working)
    }

    @Test func interruptingAToolClearsTheToolAndWaits() throws {
        let run = Timeline("3-interrupt-mid-tool")
        #expect(try run.replay(through: 8).root.currentTool?.name == "Bash")
        #expect(try run.replay(through: 8).root.status == .working)

        let idle = try run.replay(through: 9)
        #expect(idle.root.status == .waiting)
        #expect(idle.root.currentTool == nil)
    }

    @Test func aPermissionPromptWaitsAndTheAnswerWorksAgain() throws {
        let run = Timeline("4-waiting-permission-question")
        let snapshots = run.entries.filter { !$0.isHook }
        let waiting = try #require(snapshots.first { run.snapshotStatus($0) == "waiting" })
        let busy = try #require(snapshots.first { $0.n > waiting.n && run.snapshotStatus($0) == "busy" })

        #expect(try run.replay(through: waiting.n).root.status == .waiting)
        #expect(try run.replay(through: busy.n).root.status == .working)
    }

    @Test func aStopHookNewerThanTheLastSnapshotWinsAndBackgroundSubagentsKeepRunning() throws {
        let run = Timeline("6-background-subagents")
        let stop = try #require(run.entries.first { $0.file.hasSuffix("-Stop.json") })
        let latestSnapshot = try #require(run.entries.last { !$0.isHook && $0.n < stop.n })
        #expect(run.snapshotStatus(latestSnapshot) == "busy")

        let state = try run.replay(through: stop.n)
        #expect(state.root.status == .waiting)
        #expect(state.activeAgentCount > 0)
    }

    @Test func theWholeBackgroundRunEndsConsistently() throws {
        let state = try Timeline("6-background-subagents").replay()
        #expect(state.sessions.values.first?.endedAt != nil)
        #expect(state.activeAgentCount == 0)
    }

    /// A background shell outlives the turn: `shell` in the status file must
    /// not set the orchestrator working again after its `Stop`.
    @Test func aBackgroundShellAfterTheTurnLeavesTheRootWaiting() throws {
        let run = Timeline("6a-background-shell-exit-dialog-killed")
        #expect(run.snapshotStatus(run.entry(n: 25)) == "shell")

        let state = try run.replay(through: 25)
        let session = try #require(state.sessions.values.first)
        #expect(session.root.status == .waiting)
        #expect(session.root.currentTool == nil)
        #expect(session.runsBackgroundShell)
        #expect(state.activeAgentCount == 0)
    }

    /// The hand-back turn (`busy`, 022) runs while the shell the turn
    /// before started still does: a turn says nothing about it.
    @Test func aBusySnapshotKeepsTheShellRunning() throws {
        let run = Timeline("6a-background-shell-exit-dialog-killed")
        #expect(run.snapshotStatus(run.entry(n: 22)) == "busy")
        let state = try run.replay(through: 22)
        #expect(state.root.status == .working)
        #expect(state.sessions.values.first?.runsBackgroundShell == true)
    }

    /// From the `Bash` post that started the shell (016) until the exit
    /// dialog (026): through the turn's `Stop` (020), the subagent's (021),
    /// the hand-back turn (022 `busy`, 023), its `Stop` (024) and `shell`
    /// (025). The dialog's `waiting` ends it, though the shell still ran
    /// then (it went only with the killed session): leaving `shell` while no
    /// turn runs is all a source says of a shell's end.
    @Test func theShellRunsFromItsStartUntilTheExitDialog() throws {
        let run = Timeline("6a-background-shell-exit-dialog-killed")
        #expect(run.snapshotStatus(run.entry(n: 26)) == "waiting")
        for entry in run.entries {
            let session = try run.replay(through: entry.n).sessions.values.first
            #expect((session?.runsBackgroundShell ?? false) == (16..<26).contains(entry.n), "after \(entry.file)")
        }
    }

    @Test func theExitDialogAfterTheShellWaitsWithoutIt() throws {
        let run = Timeline("6a-background-shell-exit-dialog-killed")
        #expect(run.snapshotStatus(run.entry(n: 26)) == "waiting")

        let state = try run.replay(through: 26)
        #expect(state.root.status == .waiting)
        #expect(state.sessions.values.first?.runsBackgroundShell == false)
    }

    /// The listing stays as of the last `Stop` (024), whatever the status
    /// file says since: no hook marks the shell's end.
    @Test func theSessionKeepsTheShellsItsLastStopListed() throws {
        let run = Timeline("6a-background-shell-exit-dialog-killed")
        let shell = BackgroundShell(
            id: "b1030i5uk", command: "sleep 30; echo bg", description: "Background command that sleeps 30 seconds then echoes"
        )

        let first = try #require(try run.replay(through: 13).sessions.values.first)
        #expect(first.backgroundShells.isEmpty)
        #expect(first.backgroundShellsListedAt == Date(timeIntervalSince1970: 1_790_969_162))

        let session = try #require(try run.replay().sessions.values.first)
        #expect(session.backgroundShells == [shell])
        #expect(session.backgroundShellsListedAt == Date(timeIntervalSince1970: 1_790_969_175))
    }

    @Test func theOrderOfHooksAgainstStatusSnapshotsDoesNotMatter() throws {
        let run = Timeline("2-interrupt-mid-turn")
        let timeline = try run.replay(through: 11)
        let reordered = try run.replay(through: 11, statusesFirst: true)
        #expect(timeline.root.status == .waiting)
        #expect(reordered.root.status == timeline.root.status)
    }
}

// MARK: - Background shell card

/// Run 6a as the popover shows it.
@Suite struct BackgroundShellFixtureTests {
    private let run = Timeline("6a-background-shell-exit-dialog-killed")

    /// The card `minutes` after entry `n` arrived.
    private func card(through n: Int, minutesLater minutes: TimeInterval = 0) throws -> (PopoverModel, SessionItem) {
        let state = try run.replay(through: n)
        let model = PopoverModel(state: state, now: run.entry(n: n).at.addingTimeInterval(minutes * 60), settings: PopoverSettings())
        return (model, try #require(model.sessions.first))
    }

    /// The bug: a spinner, "1 agent working" and "No activity for 19 min" for a turn long over.
    @Test func aShellAfterTheTurnShowsNoWorkingAgent() throws {
        let (model, item) = try card(through: 25, minutesLater: 19)
        #expect(model.sessions.count == 1)
        #expect(item.state == .backgroundShell)
        #expect(item.rowStatus == .shellRunning(several: false))
        #expect(item.activity == nil)
        #expect(item.shellPill != nil)
    }

    /// The pill names the one shell the `Stop` (024) listed, as of 024's time.
    @Test func theShellPillNamesTheShellTheTurnEndListed() throws {
        #expect(run.snapshotStatus(run.entry(n: 25)) == "shell")
        let (_, item) = try card(through: 25)
        #expect(item.cardState == .background)
        let shell = try #require(item.shellPill)
        #expect(item.statusAccessibilityText.map(en) == "shell running, sleep 30; echo bg")
        #expect(shell.shellText == "sleep 30; echo bg")
        let tooltip = try #require(shell.tooltip)
        let time = run.entry(n: 24).at.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "en")))
        #expect(en(tooltip.head) == "As of last turn end · \(time)")
        #expect(tooltip.shells == ["sleep 30; echo bg"])
        #expect(tooltip.foot == nil)
    }

    /// The restyled row: "shell running" and "Shell sleep 30; echo bg" with the listing's tooltip.
    @Test func theRowNamesTheShellTheTurnEndListed() throws {
        let (_, item) = try card(through: 25)
        #expect(item.rowStatus == .shellRunning(several: false))
        guard case let .shell(line)? = item.rowDetail else {
            Issue.record("no shell line: \(String(describing: item.rowDetail))")
            return
        }
        #expect(line.command == "sleep 30; echo bg")
        #expect(line.tooltip?.shells == ["sleep 30; echo bg"])
    }

    /// The turn that started the shell runs on, and the shell with it; the
    /// pill can't name the shell before a listing does (020).
    @Test func theTurnThatStartedTheShellCarriesABarePill() throws {
        for n in 16...19 {
            let (_, item) = try card(through: n)
            #expect(item.state == .working, "after \(n)")
            let shell = try #require(item.shellPill, "after \(n)")
            #expect(item.statusAccessibilityText.map(en) == "working, shell running", "after \(n)")
            #expect(shell.shellText == nil, "after \(n)")
            #expect(shell.tooltip == nil, "after \(n)")
        }
        let (_, before) = try card(through: 15)
        #expect(before.shellPill == nil)
    }

    /// From the turn's `Stop` (020) on, a listing names the shell.
    @Test func fromTheFirstListingOnThePillNamesTheShell() throws {
        for n in 20...25 {
            let (_, item) = try card(through: n)
            let shell = try #require(item.shellPill, "after \(n)")
            #expect(shell.shellText == "sleep 30; echo bg", "after \(n)")
            #expect(shell.tooltip?.shells == ["sleep 30; echo bg"], "after \(n)")
        }
    }

    /// A new turn works at once and keeps the shell pill.
    @Test func aNewTurnWorksAndKeepsTheShellPill() throws {
        for n in [22, 23] {
            let (_, item) = try card(through: n)
            #expect(item.state == .working, "after \(n)")
            let shell = try #require(item.shellPill, "after \(n)")
            #expect(shell.shellText == "sleep 30; echo bg", "after \(n)")
            #expect(shell.tooltip?.shells == ["sleep 30; echo bg"], "after \(n)")
        }
    }

    @Test func theExitDialogWaitsForYouWithoutTheShellPill() throws {
        let (_, item) = try card(through: 26)
        #expect(item.state == .waiting)
        #expect(item.rowStatus == .waitingForYou)
        #expect(item.shellPill == nil)
    }
}

// MARK: - Background shell icon

/// Run 6a as the menu bar shows it: the cube glimmers while a shell
/// runs and no agent works.
@Suite struct BackgroundShellIconFixtureTests {
    private let run = Timeline("6a-background-shell-exit-dialog-killed")

    private func icon(through n: Int? = nil) throws -> MenuBarIcon {
        MenuBarIcon(state: try run.replay(through: n), connection: .ok)
    }

    /// A turn running wins over the shell that runs with it.
    @Test func aBusyTurnWinsOverTheShell() throws {
        #expect(run.snapshotStatus(run.entry(n: 22)) == "busy")
        #expect(try icon(through: 16) == .working(count: 2)) // with the subagent that started at 009
        #expect(try icon(through: 22) == .working(count: 1))
    }

    /// The `Stop` (024) ends the turn and lists the shell: the cube
    /// glimmers before the status file says `shell`.
    @Test func theTurnsStopListingTheShellGlimmers() throws {
        #expect(try icon(through: 24) == .backgroundShell)
    }

    @Test func theShellAfterTheTurnGlimmers() throws {
        #expect(try icon(through: 25) == .backgroundShell)
    }

    /// The exit dialog (`waiting`) is the newest report: the shell no longer counts.
    @Test func theExitDialogFallsBackToIdle() throws {
        #expect(run.snapshotStatus(run.entry(n: 26)) == "waiting")
        #expect(try icon(through: 26) == .idle)
        #expect(try icon() == .idle)
    }
}
