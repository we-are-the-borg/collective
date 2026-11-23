import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

private let t0 = Date(timeIntervalSince1970: 1_000)

private func key(_ id: String, source: SourceID = "test-tool") -> SessionKey { SessionKey(source: source, sessionID: id) }
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// Events of one session, one second apart starting at `start`.
private func session(_ id: String, source: SourceID = "test-tool", start: TimeInterval = 0, _ kinds: [AgentEvent.Kind]) -> [AgentEvent] {
    kinds.enumerated().map { offset, kind in
        AgentEvent(session: key(id, source: source), timestamp: at(start + TimeInterval(offset)), kind: kind)
    }
}

private func state(_ events: [AgentEvent]...) -> CollectiveState {
    var state = CollectiveState()
    for event in events.flatMap({ $0 }).sorted(by: { $0.timestamp < $1.timestamp }) {
        state.apply(event)
    }
    return state
}

private func model(
    _ state: CollectiveState,
    at seconds: TimeInterval = 100,
    expansion: PopoverExpansion = PopoverExpansion(),
    undo: ArchiveUndo = ArchiveUndo()
) -> PopoverModel {
    PopoverModel(state: state, now: at(seconds), settings: PopoverSettings(), expansion: expansion, undo: undo)
}

private func spawn(_ id: String, parent: AgentRef = .root, title: String? = nil, background: Bool? = nil) -> AgentEvent.Kind {
    .agentSpawned(id: id, parent: parent, spec: AgentSpec(type: "explore", title: title ?? id.uppercased(), isBackground: background))
}

private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

/// Line parts the view joins, written with its separator for readability.
private func en(_ parts: [LocalizedStringResource]) -> String {
    parts.map(en).joined(separator: " | ")
}

/// A working session in project `alpha` with working subagents `a` and `b`.
private func alpha(start: TimeInterval = 0) -> [AgentEvent] {
    session("alpha", start: start, [.sessionStarted(cwd: "/p/alpha", pid: 1), .promptSubmitted("go"), spawn("a"), spawn("b")])
}

/// A working session in project `beta` without subagents.
private func beta(start: TimeInterval = 0) -> [AgentEvent] {
    session("beta", start: start, [.sessionStarted(cwd: "/p/beta", pid: 2), .promptSubmitted("go")])
}

/// A session in project `gamma` that ended.
private func gamma(start: TimeInterval = 0) -> [AgentEvent] {
    session("gamma", start: start, [.sessionStarted(cwd: "/p/gamma", pid: 3), .promptSubmitted("go"), .turnEnded(), .sessionEnded])
}

@Suite struct PopoverModelArchiveTests {
    // MARK: Archived sessions

    @Test func anArchivedSessionLeavesTheListAndEveryCount() {
        var s = state(alpha(), beta(), session("other", source: "other-tool", [.promptSubmitted("go")]))
        s.archive(.session(key("alpha")), at: at(50))
        s.archive(.session(key("other", source: "other-tool")), at: at(50))
        let m = model(s)

        #expect(m.sessions.map(\.key) == [key("beta")])
        #expect(m.tabs.map(\.count) == [1, 0, 0])
        #expect(m.sessions.map(\.rowStatus) == [.working])
        #expect(s.activeAgentCount == 1)
    }

    @Test func anArchivedFinishedSessionLeavesTheFinishedList() {
        var s = state(beta(), gamma())
        s.archive(.session(key("gamma")), at: at(50))
        #expect(model(s).finished.isEmpty)
    }

    @Test func withEverythingArchivedThePopoverIsEmpty() {
        var s = state(alpha(), gamma())
        s.archive(.session(key("alpha")), at: at(50))
        s.archive(.session(key("gamma")), at: at(50))
        let m = model(s)
        #expect(m.content == .dormant)
        #expect(en(m.footerParts(at: at(100))) == "Linked to subspace | listening")
    }

    // MARK: Archived subagents

    @Test func anArchivedSubagentNeverCountsAsWorking() throws {
        var s = state(alpha())
        s.archive(.agent(key("alpha"), .subagent("a")), at: at(50))
        let m = model(s)
        let item = try #require(m.sessions.first)

        #expect(s.activeAgentCount == 2)
        #expect(item.summary.workingCount == 1)
        #expect(item.summary.archivedCount == 1)
    }

    @Test func anArchivedSubagentTakesItsWorkingChildrenAlong() throws {
        var s = state(alpha(), session("alpha", start: 4, [spawn("c", parent: .subagent("a"))]))
        #expect(s.activeAgentCount == 4)

        s.archive(.agent(key("alpha"), .subagent("a")), at: at(50))
        var item = try #require(model(s).sessions.first)
        #expect(s.activeAgentCount == 2)
        #expect(item.summary.workingCount == 1)
        #expect(item.summary.archivedCount == 2)

        s.unarchive(.agent(key("alpha"), .subagent("a")))
        item = try #require(model(s).sessions.first)
        #expect(s.activeAgentCount == 4)
        #expect(item.summary.workingCount == 3)
        #expect(item.summary.archivedCount == 0)
    }

    @Test func anArchivedSubagentNoLongerCountsOnTheToggleLine() throws {
        var s = state(alpha())
        s.archive(.agent(key("alpha"), .subagent("a")), at: at(50))
        #expect(try #require(model(s).sessions.first).subagentToggle?.parts.map { en($0.text) } == ["1 working"])

        s.archive(.agent(key("alpha"), .subagent("b")), at: at(50))
        #expect(try #require(model(s).sessions.first).subagentToggle == nil)
        let activity = try #require(model(s).sessions.first?.activity)
        guard case let .noActivity(since) = activity else {
            Issue.record("expected no activity, got \(activity)")
            return
        }
        #expect(en(ActivityLine.noActivityText(since: since, at: at(100))) == "No activity for 1 min")
    }

    @Test func anArchivedBackgroundSubagentNoLongerCountsWhileTheSessionWaits() throws {
        var s = state(session("alpha", [.promptSubmitted("go"), spawn("bg1", background: true), spawn("bg2", background: true), .turnEnded()]))
        #expect(try #require(model(s).sessions.first).summary.workingCount == 2)

        s.archive(.agent(key("alpha"), .subagent("bg1")), at: at(50))
        let item = try #require(model(s).sessions.first)
        // bg2 still works, so the card shows background work rather than waiting.
        #expect(item.state == .backgroundWorking)
        #expect(item.backgroundWorkingCount == 1)
        #expect(item.summary.workingCount == 1)
    }

    @Test func aSingleArchivedSubagentCountsAsArchivedInTheHeading() throws {
        var s = state(alpha())
        s.archive(.agent(key("alpha"), .subagent("a")), at: at(50))
        let item = try #require(model(s).sessions.first)
        #expect(SubagentsHeader(summary: item.summary).statusParts.map(en) == ["1 working", "1 archived"])
    }

    // MARK: Last event and archivability

    @Test func anItemTellsHowLongAgoItsLastEventWas() throws {
        let s = state(alpha(), session("alpha", start: 30, [.toolStarted(agent: .subagent("b"), ToolActivity(name: "Bash"))]))
        let item = try #require(model(s, at: 100).sessions.first)
        #expect(en(item.lastEventText(at: at(100))) == "Last event 1 min ago")
        #expect(en(item.lastEventText(at: at(40))) == "Last event 10 s ago")
    }

    /// It would come back with its next tool start.
    @Test func aWorkingSessionCannotBeArchived() throws {
        let item = try #require(model(state(beta())).sessions.first)
        #expect(item.state == .working)
        #expect(!item.isArchivable)
    }

    @Test func aWaitingSessionCanBeArchived() throws {
        let item = try #require(model(state(session("alpha", [.promptSubmitted("go"), .turnEnded()]))).sessions.first)
        #expect(item.state == .waiting)
        #expect(item.isArchivable)
    }

    /// A subagent's tool start brings the session back as well.
    @Test func aSessionWhoseBackgroundSubagentWorksCannotBeArchived() throws {
        let s = state(session("alpha", [.promptSubmitted("go"), spawn("bg", background: true), .turnEnded()]))
        let item = try #require(model(s).sessions.first)
        #expect(item.state == .backgroundWorking)
        #expect(!item.isArchivable)
    }

    /// The turn ended without the foreground subagent's end: the card waits,
    /// yet the subagent's next tool start would bring the session back.
    @Test func aWaitingSessionWhoseForegroundSubagentWorksCannotBeArchived() throws {
        let s = state(session("alpha", [.promptSubmitted("go"), spawn("fg", background: false), .turnEnded()]))
        let item = try #require(model(s).sessions.first)
        #expect(item.state == .waiting)
        #expect(!item.isArchivable)
    }

    @Test func anArchivedWorkingSubagentDoesNotKeepItsSessionFromArchiving() throws {
        var s = state(session("alpha", [.promptSubmitted("go"), spawn("fg"), spawn("bg", background: true), .turnEnded()]))
        s.archive(.agent(key("alpha"), .subagent("fg")), at: at(50))
        s.archive(.agent(key("alpha"), .subagent("bg")), at: at(50))
        let item = try #require(model(s).sessions.first)
        #expect(item.state == .waiting)
        #expect(item.isArchivable)
    }

    @Test func staleAndFinishedSessionsCanBeArchived() throws {
        var s = state(alpha(), gamma())
        #expect(try #require(model(s).finished.first).isArchivable)

        s.markStale(now: at(70), silenceTimeout: 30, waitingTimeout: 30, processStart: { _ in nil })
        let stale = try #require(model(s).finished.first { $0.key == key("alpha") })
        #expect(stale.state == .stale)
        #expect(stale.isArchivable)
    }

    // MARK: Undo rows

    @Test func anArchivedSessionHoldsItsPlaceAsAnUndoRowWithoutCounting() throws {
        var s = state(alpha(start: 1), beta())
        var undo = ArchiveUndo()
        let id = undo.archive(.session(key("alpha")), in: &s, at: at(50))
        let m = model(s, at: 52, undo: undo)

        #expect(m.sessions.map(\.key) == [key("alpha"), key("beta")])
        let row = try #require(m.sessions.first?.undo)
        #expect(row.id == id)
        #expect(en(row.text) == "alpha archived")
        #expect(m.sessions.last?.undo == nil)
        #expect(m.tabs[0].count == 1)
        #expect(m.sessions.last?.rowStatus == .working)

        #expect(model(s, at: 56, undo: undo).sessions.map(\.key) == [key("beta")])
    }

    @Test func anUndoRowWithoutNameAndFolderUsesTheCardTitle() throws {
        var s = state(session("bare", [.promptSubmitted("go")]))
        var undo = ArchiveUndo()
        undo.archive(.session(key("bare")), in: &s, at: at(50))
        let m = PopoverModel(state: s, now: at(52), settings: PopoverSettings(), undo: undo)
        #expect(en(try #require(m.sessions.first?.undo).text) == "bare archived")
        #expect(m.content == .list)
    }

    @Test func aFinishedSessionHoldsItsPlaceInTheFinishedList() throws {
        var s = state(gamma(), session("delta", start: 1, [.promptSubmitted("go"), .sessionEnded]))
        var undo = ArchiveUndo()
        undo.archive(.finishedSession(key("gamma")), in: &s, at: at(50))
        let m = model(s, at: 52, undo: undo)

        #expect(m.finished.map(\.key) == [key("gamma"), key("delta")])
        #expect(en(try #require(m.finished.first?.undo).text) == "gamma archived")
        #expect(m.finished.last?.undo == nil)
    }

    @Test func archiveAllFinishedLeavesOneRowAndListsLaterFinishersBelowIt() throws {
        var s = state(gamma(), session("delta", start: 1, [.promptSubmitted("go"), .sessionEnded]),
                      session("late", start: 1, [.promptSubmitted("go")]))
        var undo = ArchiveUndo()
        let id = undo.archive(.allFinished([key("gamma"), key("delta")]), in: &s, at: at(50))
        s.apply(AgentEvent(session: key("late"), timestamp: at(51), kind: .sessionEnded))
        let m = model(s, at: 52, undo: undo)

        let row = try #require(m.finishedBulkUndo)
        #expect(row.id == id)
        #expect(en(row.text) == "2 finished sessions archived")
        #expect(m.finished.map(\.key) == [key("late")])

        let later = model(s, at: 57, undo: undo)
        #expect(later.finishedBulkUndo == nil)
        #expect(later.finished.map(\.key) == [key("late")])
    }

    @Test func theBulkRowAloneKeepsTheFinishedListUp() throws {
        var s = state(gamma())
        var undo = ArchiveUndo()
        undo.archive(.allFinished([key("gamma")]), in: &s, at: at(50))
        var finished = PopoverExpansion()
        finished.select(.finished)
        let m = model(s, at: 52, expansion: finished, undo: undo)
        #expect(en(try #require(m.finishedBulkUndo).text) == "1 finished session archived")
        #expect(m.content == .list)
        #expect(model(s, at: 56, expansion: finished, undo: undo).content == .nothingFinished)
    }

    @Test func aPausedUndoRowStays() {
        var s = state(alpha())
        var undo = ArchiveUndo()
        let id = undo.archive(.session(key("alpha")), in: &s, at: at(50))
        undo.pause(id, at: at(51))
        #expect(model(s, at: 500, undo: undo).sessions.first?.undo?.id == id)
    }

    @Test func aSessionBackAtWorkDropsItsUndoRow() throws {
        var s = state(alpha())
        var undo = ArchiveUndo()
        undo.archive(.session(key("alpha")), in: &s, at: at(50))
        s.apply(AgentEvent(session: key("alpha"), timestamp: at(51), kind: .promptSubmitted("again")))
        let m = model(s, at: 52, undo: undo)
        #expect(m.sessions.first?.undo == nil)
        #expect(m.tabs[0].count == 1)
    }

    @Test func theBulkRowCountsOnlyWhatItsUndoTakesBack() throws {
        var s = state(gamma(), session("delta", start: 1, [.promptSubmitted("go"), .sessionEnded]))
        var undo = ArchiveUndo()
        let bulk = undo.archive(.allFinished([key("gamma"), key("delta")]), in: &s, at: at(50))
        s.apply(AgentEvent(session: key("gamma"), timestamp: at(51), kind: .promptSubmitted("again")))
        s.apply(AgentEvent(session: key("gamma"), timestamp: at(52), kind: .sessionEnded))
        let single = undo.archive(.finishedSession(key("gamma")), in: &s, at: at(53))
        let m = model(s, at: 54, undo: undo)

        let row = try #require(m.finishedBulkUndo)
        #expect(row.id == bulk)
        #expect(en(row.text) == "1 finished session archived")
        #expect(m.finished.map(\.key) == [key("gamma")])
        #expect(m.finished.first?.undo?.id == single)
    }

    @Test func aSessionArchivedAgainByANewerEntryShowsOnlyThatEntrysRow() throws {
        var s = state(gamma())
        var undo = ArchiveUndo()
        undo.archive(.finishedSession(key("gamma")), in: &s, at: at(50))
        s.apply(AgentEvent(session: key("gamma"), timestamp: at(51), kind: .promptSubmitted("again")))
        s.apply(AgentEvent(session: key("gamma"), timestamp: at(52), kind: .sessionEnded))
        let bulk = undo.archive(.allFinished([key("gamma")]), in: &s, at: at(53))
        let m = model(s, at: 54, undo: undo)

        #expect(m.finishedBulkUndo?.id == bulk)
        #expect(m.finished.isEmpty)
    }
}

@Suite struct FinishedTabTests {
    private func ended(_ id: String, start: TimeInterval = 0) -> [AgentEvent] {
        session(id, start: start, [.promptSubmitted("x"), .sessionEnded])
    }

    private func working(_ id: String) -> [AgentEvent] {
        session(id, start: 5, [.promptSubmitted("y")])
    }

    @Test func theFinishedTabCountsFinishedSessions() {
        let m = model(state(ended("a"), ended("b", start: 1)))
        #expect(m.tabs[2].count == 2)
        #expect(!m.tabs[2].isSelected)
    }

    @Test func anUndoRowDoesNotCountOnTheFinishedTab() {
        var s = state(ended("a"), ended("b", start: 1))
        var undo = ArchiveUndo()
        undo.archive(.finishedSession(key("a")), in: &s, at: at(50))
        let m = model(s, at: 52, undo: undo)
        #expect(m.finished.count == 2)
        #expect(m.tabs[2].count == 1)
    }

    @Test func focusOrderTakesTheSelectedTabWithoutUndoRows() {
        var s = state(working("live"), ended("a"), ended("b", start: 1))
        var undo = ArchiveUndo()
        undo.archive(.finishedSession(key("a")), in: &s, at: at(50))

        #expect(model(s, at: 52, undo: undo).focusOrder == [key("live")])

        var expansion = PopoverExpansion()
        expansion.select(.finished)
        #expect(model(s, at: 52, expansion: expansion, undo: undo).focusOrder == [key("b")])
    }
}
