import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// The card's subagent list against captured Claude Code runs: what the
// rows show at points where the session still has its card.

private let claude: SourceID = "claude-code"

private struct NoMeta: SubagentMetaReading {
    func meta(transcriptPath: String, agentID: String) -> SubagentMeta? { nil }
}

private final class NoFiles: MappingFileSystem {
    func modificationDate(of url: URL) -> Date? { nil }
    func contents(of url: URL) throws -> Data { throw CocoaError(.fileNoSuchFile) }
}

/// Payloads one second apart from `start`, as the adapter tests replay them.
private func replay(_ payloads: [Data], with adapter: ClaudeCodeAdapter, start: Date = Date(timeIntervalSince1970: 1_000)) throws -> CollectiveState {
    var state = CollectiveState()
    for (index, payload) in payloads.enumerated() {
        let envelope = Envelope(source: claude, pid: 4242, payload: payload, receivedAt: start.addingTimeInterval(TimeInterval(index)))
        for event in try adapter.events(from: envelope) { state.apply(event) }
    }
    return state
}

/// The payloads of run 16 of 2.1.289 up to and including the file starting with `last`.
private func run16(through last: String? = nil) throws -> [Data] {
    let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/claude-code/2.1.289/16-agent-model/events")
    var files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    if let last, let end = files.firstIndex(where: { $0.hasPrefix(last) }) { files = Array(files[...end]) }
    return try files.map { try Data(contentsOf: directory.appendingPathComponent($0)) }
}

/// The only session's item at `now`, its subagent list opened by the user
/// and, with `foldOpen`, the orchestrator's fold row too.
private func item(_ state: CollectiveState, at now: Date, foldOpen: Bool = false, idleAfter: IdleAfter = .never) throws -> SessionItem {
    let session = try #require(state.sessions.values.first)
    var expansion = PopoverExpansion()
    expansion.toggleSubagents(session.key, isOpen: false)
    if foldOpen { expansion.toggleSubagentFold(SubagentFoldID(session: session.key, parent: .root)) }
    let popover = PopoverModel(
        state: state, now: now, settings: PopoverSettings(idleAfter: idleAfter),
        modelNaming: [claude: ClaudeCodeModelNaming()], expansion: expansion
    )
    return try #require((popover.sessions + popover.idle).first)
}

private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

private func rows(_ item: SessionItem) -> [SubagentRow] {
    item.subagentToggle?.list.entries.compactMap(\.row) ?? []
}

@Suite struct SubagentListFixtureTests {
    // MARK: 2.1.285 run 1: two parallel foreground subagents

    @Test func parallelSubagentsListTheNewestFirst() throws {
        let run = Run.headless
        let state = try replay(Array(run.payloads.prefix(12)), with: run.adapter())
        let item = try item(state, at: Date(timeIntervalSince1970: 1_020))
        let shown = rows(item)
        #expect(shown.map(\.title) == ["Read README.md and report content", "Run command and report output"])
        #expect(shown.map { en($0.titleText) } == ["general-purpose", "general-purpose"])
        #expect(shown.map(\.status) == [.working, .working])
        #expect(shown.map(\.depth) == [1, 1])
        #expect(shown.allSatisfy { !$0.isBackground && $0.runningSince != nil })
        // The model comes only with the call's end, after the subagent stopped.
        #expect(shown.allSatisfy { $0.model == nil })
        #expect(SubagentsHeader(summary: item.summary).statusParts.map(en) == ["2 working"])
    }

    /// Mid-run (012) the orchestrator waits on both: its detail shows its own
    /// last call, the toggle line under it the two at work.
    @Test func parallelSubagentsAtWorkShowOnTheToggleLineNotInTheDetail() throws {
        let run = Run.headless
        let item = try item(try replay(Array(run.payloads.prefix(12)), with: run.adapter()), at: Date(timeIntervalSince1970: 1_020))
        #expect(item.state == .working)
        #expect(item.activity == .tool(ToolActivity(name: "Agent", detail: "Read README.md and report content")))
        #expect(item.subagentToggle?.parts.map { en($0.text) } == ["2 working"])
        #expect(item.doneSubagentsAccessibilityText == nil)
        #expect(item.subagentsAccessibilityText.map(en) == "2 subagents working")
    }

    /// Mid-run (012) the orchestrator and both subagents work: the summary
    /// counts the session once, its row counts the subagents.
    @Test func parallelSubagentsAtWorkCountTheirSessionOnce() throws {
        let run = Run.headless
        let popover = PopoverModel(
            state: try replay(Array(run.payloads.prefix(12)), with: run.adapter()),
            now: Date(timeIntervalSince1970: 1_020), settings: PopoverSettings()
        )
        #expect(popover.sessions.count == 1)
        #expect(popover.sessions.first?.state == .working)
        #expect(popover.sessions.first?.summary.workingCount == 2)
    }

    /// Before the `Stop` (020) both are done: "2 done"; the session keeps
    /// it once it rests in "Idle" and once it has ended (021).
    @Test func doneParallelSubagentsLeaveOnlyTheirCount() throws {
        let run = Run.headless
        let card = try item(try replay(Array(run.payloads.prefix(19)), with: run.adapter()), at: Date(timeIntervalSince1970: 1_020))
        #expect(card.subagentToggle?.parts.map { en($0.text) } == ["2 done"])
        #expect(card.subagentsAccessibilityText.map(en) == "2 subagents done")

        let idle = try item(try replay(Array(run.payloads.prefix(20)), with: run.adapter()), at: Date(timeIntervalSince1970: 2_000), idleAfter: .fiveMinutes)
        #expect(idle.idleSince != nil)
        #expect(idle.subagentToggle?.parts.map { en($0.text) } == ["2 done"])
        #expect(idle.doneSubagentsAccessibilityText.map(en) == "2 subagents done")

        let ended = PopoverModel(
            state: try replay(run.payloads, with: run.adapter()), now: Date(timeIntervalSince1970: 1_030),
            settings: PopoverSettings(finishedRetention: .oneHour)
        )
        let finished = try #require(ended.finished.first)
        #expect(finished.subagentToggle?.parts.map { en($0.text) } == ["2 done"])
        #expect(finished.doneSubagentsAccessibilityText.map(en) == "2 subagents done")
    }

    /// Up to the orchestrator's `Stop` (020) the card stays, both subagents done.
    @Test func doneParallelSubagentsFoldIntoOneRow() throws {
        let run = Run.headless
        let state = try replay(Array(run.payloads.prefix(19)), with: run.adapter())
        let list = try #require(try item(state, at: Date(timeIntervalSince1970: 1_020)).subagentToggle?.list)
        guard case let .fold(fold)? = list.entries.first, list.entries.count == 1 else {
            Issue.record("expected one fold row, got \(list.entries)")
            return
        }
        #expect(fold.textParts.map(en) == ["2 done"])

        let open = try item(state, at: Date(timeIntervalSince1970: 1_020), foldOpen: true)
        let members = rows(open)
        #expect(members.map(\.title) == ["Read README.md and report content", "Run command and report output"])
        #expect(members.map(\.depth) == [2, 2])
        #expect(members.map { [$0.position, $0.total] } == [[2, 2], [1, 2]])
        #expect(members.map { $0.model?.name } == ["Haiku 4.5", "Haiku 4.5"])
        #expect(members.allSatisfy { $0.reply != nil && $0.prompt != nil })
    }

    // MARK: 2.1.287 run 6: background subagents

    /// 016 starts the second subagent with its type; the call gives its title
    /// only with its end (017). The type names it, so it works from the start.
    @Test func aBackgroundSubagentWorksUnderItsTypeBeforeItsTitleComes() throws {
        let run = Timeline("6-background-subagents")
        let starting = try item(try run.replay(through: 16), at: run.entry(n: 16).at.addingTimeInterval(1))
        let first = rows(starting)
        #expect(first.map(\.status) == [.working, .working])
        #expect(first.first?.title == nil)
        #expect(first.first.map { en($0.titleText) } == "general-purpose")
        #expect(SubagentsHeader(summary: starting.summary).statusParts.map(en) == ["2 working"])

        // After the orchestrator's `Stop` (019) both run on in the background.
        let waiting = try item(try run.replay(through: 19), at: run.entry(n: 19).at.addingTimeInterval(1))
        #expect(waiting.state == .backgroundWorking)
        let shown = rows(waiting)
        #expect(shown.map(\.title) == ["Run sleep command bg", "Run sleep command"])
        #expect(shown.allSatisfy { $0.isBackground && $0.status == .working })
        #expect(shown.map { $0.model?.name } == ["Sonnet 5.5", "Sonnet 5.5"])
        #expect(shown.map { $0.model?.helpDetail.map(en) } == ["Inherited", "Inherited"])
    }

    /// After the orchestrator's `Stop` (019) only the background subagents
    /// work: the header counts no session.
    @Test func backgroundSubagentsAloneCountTheirSessionAsWorking() throws {
        let run = Timeline("6-background-subagents")
        let popover = PopoverModel(
            state: try run.replay(through: 19), now: run.entry(n: 19).at.addingTimeInterval(1), settings: PopoverSettings()
        )
        #expect(popover.sessions.count == 1)
        #expect(popover.sessions.first?.state == .backgroundWorking)
        #expect(popover.sessions.first?.summary.workingCount == 2)
    }

    /// 027 ends the newer one; the older still runs.
    @Test func aDoneBackgroundSubagentFoldsAboveTheOneStillRunning() throws {
        let run = Timeline("6-background-subagents")
        let list = try #require(try item(try run.replay(through: 27), at: run.entry(n: 27).at.addingTimeInterval(1)).subagentToggle?.list)
        #expect(list.entries.count == 2)
        guard case let .fold(fold) = list.entries[0] else { Issue.record("no fold row first"); return }
        #expect(fold.textParts.map(en) == ["1 done"])
        #expect(list.entries[1].row?.title == "Run sleep command")
    }

    /// After the orchestrator's `Stop` (019) the toggle line counts both
    /// background subagents.
    @Test func backgroundSubagentsShowInTheStatusWord() throws {
        let run = Timeline("6-background-subagents")
        let waiting = try item(try run.replay(through: 19), at: run.entry(n: 19).at.addingTimeInterval(1))
        #expect(waiting.rowStatus == .backgroundAgents(count: 2))
        #expect(waiting.subagentToggle?.parts.map { en($0.text) } == ["2 working"])
        // The status word is only "working", so the row's label names them.
        #expect(waiting.subagentsAccessibilityText.map(en) == "2 subagents working")
    }

    /// 027 ends the newer one after 025 started a new turn: the status word
    /// says "working", so the row's label counts the working and the done one.
    @Test func aWorkingCardsLabelCountsTheBackgroundSubagentsLeft() throws {
        let run = Timeline("6-background-subagents")
        let card = try item(try run.replay(through: 27), at: run.entry(n: 27).at.addingTimeInterval(1))
        #expect(card.rowStatus == .working)
        #expect(card.subagentsAccessibilityText.map(en) == "1 subagent working, 1 done")
    }

    // MARK: 2.1.285 run 2: background subagents, one done before the other

    /// 020 ends the first background subagent while the orchestrator rests.
    @Test func theStatusWordOfOneBackgroundSubagentIsWorking() throws {
        let run = Run.background
        let item = try item(try replay(Array(run.payloads.prefix(20)), with: run.adapter()), at: Date(timeIntervalSince1970: 1_020))
        #expect(item.state == .backgroundWorking)
        #expect(item.rowStatus == .backgroundAgents(count: 1))
        #expect(item.rowStatus?.mark.word.map(en) == "working")
        #expect(item.subagentToggle?.parts.map { en($0.text) } == ["1 working", "1 done"])
        // The status word only says "working"; the label names the subagents.
        #expect(item.subagentsAccessibilityText.map(en) == "1 subagent working, 1 done")
    }

    // MARK: 2.1.289 run 16: subagent models

    @Test func eachRowNamesTheModelItsSubagentRunsWith() throws {
        let adapter = ClaudeCodeAdapter(metaReader: NoMeta(), mapping: MappingLoader(root: URL(filePath: "/spool/root", directoryHint: .isDirectory), fileSystem: NoFiles()))
        let state = try replay(try run16(through: "014"), with: adapter)
        let shown = rows(try item(state, at: Date(timeIntervalSince1970: 1_020)))
        #expect(shown.map(\.title) == ["Reply two", "Reply one"])
        #expect(shown.map { $0.model?.name } == ["Sonnet 5.5", "Haiku 4.5"])
        #expect(shown.map { $0.model?.helpDetail.map(en) } == ["Inherited", "Set at spawn"])
    }

    /// Before the `SessionEnd` (032) the session rests with both done.
    @Test func anIdleRowNamesItsSubagentsModelsInTheOrderOfSpawn() throws {
        let adapter = ClaudeCodeAdapter(metaReader: NoMeta(), mapping: MappingLoader(root: URL(filePath: "/spool/root", directoryHint: .isDirectory), fileSystem: NoFiles()))
        let state = try replay(try run16(through: "031"), with: adapter)
        let idle = try item(state, at: Date(timeIntervalSince1970: 2_000), idleAfter: .fiveMinutes)
        let line = try #require(idle.idleSubagents)
        #expect(en(line.title) == "2 subagents, all done")
        #expect(line.modelNames == ["Haiku 4.5", "Sonnet 5.5"])
    }
}
