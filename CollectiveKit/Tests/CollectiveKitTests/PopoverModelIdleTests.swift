import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

private let source: SourceID = "test-tool"
private let t0 = Date(timeIntervalSince1970: 1_000)

private func key(_ id: String) -> SessionKey { SessionKey(source: source, sessionID: id) }
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func event(_ id: String, at seconds: TimeInterval, _ kind: AgentEvent.Kind) -> AgentEvent {
    AgentEvent(session: key(id), timestamp: at(seconds), kind: kind)
}

/// Events of one session, one second apart starting at `start`.
private func session(_ id: String, start: TimeInterval = 0, _ kinds: [AgentEvent.Kind]) -> [AgentEvent] {
    kinds.enumerated().map { offset, kind in event(id, at: start + TimeInterval(offset), kind) }
}

/// A session whose turn ended at `start + 2`.
private func resting(_ id: String, start: TimeInterval = 0) -> [AgentEvent] {
    session(id, start: start, [.sessionStarted(cwd: "/Users/user/projects/\(id)", pid: nil), .promptSubmitted("go"), .turnEnded()])
}

/// Applies the events sorted by time, so sessions can interleave.
private func state(_ events: [AgentEvent]...) -> CollectiveState {
    var state = CollectiveState()
    for event in events.flatMap({ $0 }).sorted(by: { $0.timestamp < $1.timestamp }) {
        state.apply(event)
    }
    return state
}

private func model(
    _ state: CollectiveState,
    at seconds: TimeInterval,
    idleAfter: IdleAfter = .fiveMinutes,
    opened snapshot: IdleSnapshot? = nil,
    expansion: PopoverExpansion = PopoverExpansion(),
    undo: ArchiveUndo = ArchiveUndo()
) -> PopoverModel {
    PopoverModel(
        state: state, now: at(seconds),
        settings: PopoverSettings(idleAfter: idleAfter, idleSnapshot: snapshot),
        expansion: expansion, undo: undo
    )
}

/// What the app captures when the popover opens.
private func opening(_ state: CollectiveState, at seconds: TimeInterval) -> IdleSnapshot {
    IdleSnapshot(state, openedAt: at(seconds))
}

private func spawn(_ id: String, background: Bool? = nil) -> AgentEvent.Kind {
    .agentSpawned(id: id, parent: .root, spec: AgentSpec(type: "explore", title: id.uppercased(), isBackground: background))
}

/// A kit text as an English user reads it, resolved from the kit's catalog.
private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

@Suite struct PopoverModelIdleTests {
    // MARK: Threshold

    @Test func aWaitingSessionGoesIdleOnceItHasRestedLongEnough() {
        let s = state(resting("s1"))
        let before = model(s, at: 2 + 299)
        #expect(before.sessions.map(\.key) == [key("s1")])
        #expect(before.idle.isEmpty)

        let after = model(s, at: 2 + 300)
        #expect(after.sessions.isEmpty)
        #expect(after.idle.map(\.key) == [key("s1")])
    }

    @Test func neverKeepsEverySessionAtTheTop() {
        let m = model(state(resting("s1")), at: 10 * 3600, idleAfter: .never)
        #expect(m.sessions.map(\.key) == [key("s1")])
        #expect(m.idle.isEmpty)
    }

    // MARK: What keeps a session from resting

    @Test func aWorkingSubagentKeepsTheSessionActive() {
        let s = state(session("s1", [.sessionStarted(cwd: "/p/s1", pid: nil), .promptSubmitted("go"), spawn("a"), .turnEnded()]))
        let m = model(s, at: 3600)
        #expect(m.sessions.map(\.key) == [key("s1")])
        #expect(m.idle.isEmpty)
    }

    @Test func aWorkingBackgroundAgentKeepsTheSessionActive() {
        let s = state(session("s1", [.sessionStarted(cwd: "/p/s1", pid: nil), .promptSubmitted("go"), spawn("a", background: true), .turnEnded()]))
        let m = model(s, at: 3600)
        #expect(m.sessions.map(\.key) == [key("s1")])
        #expect(m.sessions.first?.state == .backgroundWorking)
        #expect(m.idle.isEmpty)
    }

    @Test func aBackgroundShellKeepsTheSessionActive() {
        let s = state(resting("s1"), [event("s1", at: 3, .activityReported(.backgroundShell))])
        let m = model(s, at: 3600)
        #expect(m.sessions.map(\.key) == [key("s1")])
        #expect(m.sessions.first?.state == .backgroundShell)
        #expect(m.idle.isEmpty)
    }

    @Test func anOpenPermissionRequestKeepsTheSessionActiveForHours() {
        let s = state(resting("s1"), [event("s1", at: 3, .permissionRequested(agent: .root, ToolActivity(name: "Bash")))])
        let m = model(s, at: 5 * 3600)
        #expect(m.sessions.map(\.key) == [key("s1")])
        #expect(m.idle.isEmpty)
    }

    @Test func aSessionReportedWaitingForTheUserStaysActiveForHours() {
        let s = state(resting("s1"), [event("s1", at: 3, .activityReported(.waiting))])
        let m = model(s, at: 5 * 3600)
        #expect(m.sessions.map(\.key) == [key("s1")])
        #expect(m.idle.isEmpty)
    }

    @Test func anEndedSessionIsFinishedNotIdle() {
        let s = state(resting("s1"), [event("s1", at: 3, .sessionEnded)])
        let m = model(s, at: 3 + 60, opened: opening(s, at: 3 + 60))
        #expect(m.finished.map(\.key) == [key("s1")])
        #expect(m.idle.isEmpty)
        #expect(m.sessions.isEmpty)
    }

    // MARK: The moment the popover opened

    @Test func aSessionWhoseTimeIsUpWhileThePopoverIsOpenKeepsItsCard() {
        let s = state(resting("s1"))
        let open = model(s, at: 2 + 400, opened: opening(s, at: 2 + 200))
        #expect(open.sessions.map(\.key) == [key("s1")])
        #expect(open.idle.isEmpty)

        let reopened = model(s, at: 2 + 401, opened: opening(s, at: 2 + 401))
        #expect(reopened.idle.map(\.key) == [key("s1")])
    }

    /// Events that leave the rest as it was, read while the popover is open,
    /// keep the row in the group.
    @Test func aSessionIdleAtTheOpeningStaysIdleWhileItRests() {
        var s = state(resting("s1"))
        let opened = opening(s, at: 400)
        s.apply(event("s1", at: 500, .activityReported(.idle)))
        s.apply(event("s1", at: 510, .sessionNamed("renamed")))
        s.apply(event("s1", at: 520, .modelChanged(to: "m", from: nil)))

        let open = model(s, at: 600, opened: opened)
        #expect(open.idle.map(\.key) == [key("s1")])
        #expect(open.idle.first?.idleSince == at(2))
        #expect(open.sessions.isEmpty)
    }

    /// The guess that the user stopped a silent turn dates the rest back to
    /// the last event, long before the opening; the card stays all the same.
    @Test func aRestGuessedWhileThePopoverIsOpenKeepsItsCard() {
        var s = state(session("s1", [.sessionStarted(cwd: "/p/s1", pid: nil), .promptSubmitted("go")]))
        let opened = opening(s, at: 1000)
        s.markInterrupted(now: at(1900), idleTimeout: 1800, toolTimeout: 1800)

        let open = model(s, at: 1901, opened: opened)
        #expect(open.sessions.map(\.key) == [key("s1")])
        #expect(open.idle.isEmpty)
        #expect(model(s, at: 1901, opened: opening(s, at: 1901)).idle.map(\.key) == [key("s1")])
    }

    /// Events read late carry their own, older times: a backlog replayed
    /// after the opening can make a session rest since long before it.
    @Test func aRestFromEventsReadAfterTheOpeningKeepsItsCard() {
        var s = state(session("s1", [.sessionStarted(cwd: "/p/s1", pid: nil), .promptSubmitted("go")]))
        let opened = opening(s, at: 1000)
        s.apply(event("s1", at: 10, .turnEnded()))

        let open = model(s, at: 1001, opened: opened)
        #expect(open.sessions.map(\.key) == [key("s1")])
        #expect(open.idle.isEmpty)
        #expect(model(s, at: 1001, opened: opening(s, at: 1001)).idle.map(\.key) == [key("s1")])
    }

    /// A session the opening did not know at all, e.g. first read from the
    /// backlog afterwards, stays a card too.
    @Test func aSessionFirstSeenAfterTheOpeningKeepsItsCard() {
        var s = CollectiveState()
        let opened = opening(s, at: 1000)
        for e in resting("s1") { s.apply(e) }

        let open = model(s, at: 1001, opened: opened)
        #expect(open.sessions.map(\.key) == [key("s1")])
        #expect(open.idle.isEmpty)
    }

    /// New work brings an idle session back at once, the popover open or not;
    /// resting again after the popover opened keeps it at the top until the
    /// next opening.
    @Test(arguments: [
        AgentEvent.Kind.promptSubmitted("more"),
        .turnStarted,
        .agentSpawned(id: "bg", parent: .root, spec: AgentSpec(type: "explore", title: "BG", isBackground: true)),
        .activityReported(.working),
        .activityReported(.backgroundShell),
    ])
    func newWorkBringsAnIdleSessionBack(work: AgentEvent.Kind) {
        var s = state(resting("s1"))
        let opened = opening(s, at: 400)
        #expect(model(s, at: 400, opened: opened).idle.map(\.key) == [key("s1")])

        s.apply(event("s1", at: 450, work))
        let back = model(s, at: 451, opened: opened)
        #expect(back.sessions.map(\.key) == [key("s1")])
        #expect(back.idle.isEmpty)

        s.apply(event("s1", at: 460, .turnEnded()))
        s.apply(event("s1", at: 461, .agentFinished(id: "bg")))
        s.apply(event("s1", at: 462, .activityReported(.idle)))
        let restingAgain = model(s, at: 2000, opened: opened)
        #expect(restingAgain.sessions.map(\.key) == [key("s1")])
        #expect(restingAgain.idle.isEmpty)
        #expect(model(s, at: 2000, opened: opening(s, at: 2000)).idle.map(\.key) == [key("s1")])
    }

    /// Backlog read late can interrupt the rest and end it again before its
    /// start: a subagent's whole life dated before the turn end. The new
    /// rest begins at the same moment as the one of the opening, yet it is
    /// another rest, so the card stays until the next opening.
    @Test func aRestResumedAtTheSameStartAfterTheOpeningKeepsItsCard() {
        var s = state(resting("s1"))
        let opened = opening(s, at: 400)
        #expect(model(s, at: 400, opened: opened).idle.map(\.key) == [key("s1")])

        s.apply(event("s1", at: 1.5, spawn("late")))
        #expect(model(s, at: 401, opened: opened).sessions.map(\.key) == [key("s1")])

        s.apply(event("s1", at: 1.8, .agentFinished(id: "late")))
        let open = model(s, at: 402, opened: opened)
        #expect(open.sessions.map(\.key) == [key("s1")])
        #expect(open.idle.isEmpty)
        #expect(model(s, at: 2000, opened: opened).idle.isEmpty)

        let reopened = model(s, at: 2000, opened: opening(s, at: 2000))
        #expect(reopened.idle.map(\.key) == [key("s1")])
        #expect(reopened.idle.first?.idleSince == at(2))
    }

    /// A later run under the same id counts its rests from the start again;
    /// its first rest is still not the one of the opening.
    @Test func aLaterRunRestingAfterTheOpeningKeepsItsCard() {
        var s = state(session("s1", [.sessionStarted(cwd: "/p/s1", pid: 1), .promptSubmitted("go"), .turnEnded()]))
        let opened = opening(s, at: 400)
        #expect(model(s, at: 400, opened: opened).idle.map(\.key) == [key("s1")])

        s.apply(event("s1", at: 450, .sessionStarted(cwd: "/p/s1", pid: 2)))
        let open = model(s, at: 2000, opened: opened)
        #expect(open.sessions.map(\.key) == [key("s1")])
        #expect(open.idle.isEmpty)
        #expect(model(s, at: 2000, opened: opening(s, at: 2000)).idle.first?.idleSince == at(450))
    }

    /// The sweep can end an idle session while the popover is open, and a
    /// later event shows it alive. It rests on from where it was, yet coming
    /// back from "Finished" is no reason to enter the group under the user's
    /// eyes: it stays a card until the next opening.
    @Test func aSessionRevivedAfterTheOpeningKeepsItsCard() {
        var s = state(resting("s1"))
        let opened = opening(s, at: 400)
        #expect(model(s, at: 400, opened: opened).idle.map(\.key) == [key("s1")])

        s.markStale(now: at(500), silenceTimeout: 60, waitingTimeout: 60) { _ in nil }
        let swept = model(s, at: 501, opened: opened)
        #expect(swept.finished.map(\.key) == [key("s1")])
        #expect(swept.idle.isEmpty)

        s.apply(event("s1", at: 510, .modelChanged(to: "m", from: nil)))
        let open = model(s, at: 511, opened: opened)
        #expect(open.sessions.map(\.key) == [key("s1")])
        #expect(open.idle.isEmpty)

        let reopened = model(s, at: 600, opened: opening(s, at: 600))
        #expect(reopened.idle.map(\.key) == [key("s1")])
        #expect(reopened.idle.first?.idleSince == at(2))
    }

    // MARK: Opening while the backlog is read

    /// Right after a launch the popover can open before the backlog is read;
    /// the sessions it brings, resting for hours, belong in Idle at once.
    @Test func anOpeningWhileTheBacklogIsReadClassifiesTheBacklogByNow() {
        var s = CollectiveState()
        var popover = IdleOpening()
        popover.popoverOpened(s, at: at(1000), isLoading: true)
        for e in resting("s1") { s.apply(e) }

        let open = model(s, at: 1001, opened: popover.snapshot)
        #expect(open.idle.map(\.key) == [key("s1")])
        #expect(open.sessions.isEmpty)
    }

    /// The backlog's end is the opening: from then on the idle rules
    /// hold, so a rest whose time is up later keeps its card.
    @Test func theBacklogsEndFixesTheClassificationOfAnOpenPopover() {
        var s = CollectiveState()
        var popover = IdleOpening()
        popover.popoverOpened(s, at: at(50), isLoading: true)
        for e in resting("s1") { s.apply(e) }
        popover.backlogFinished(s, at: at(100))

        let open = model(s, at: 400, opened: popover.snapshot)
        #expect(open.sessions.map(\.key) == [key("s1")])
        #expect(open.idle.isEmpty)
        #expect(popover.snapshot == opening(s, at: 100))
    }

    /// A closed popover classifies by `now`; the backlog's end leaves it so.
    @Test func closingWhileTheBacklogIsReadDropsTheWaitForItsEnd() {
        var s = CollectiveState()
        var popover = IdleOpening()
        popover.popoverOpened(s, at: at(50), isLoading: true)
        popover.popoverClosed()
        for e in resting("s1") { s.apply(e) }
        popover.backlogFinished(s, at: at(100))

        #expect(popover.snapshot == nil)
    }

    /// Once the backlog is read, the opening fixes the classification as before.
    @Test func anOpeningAfterTheBacklogFixesTheClassificationAtOnce() {
        let s = state(resting("s1"))
        var popover = IdleOpening()
        popover.popoverOpened(s, at: at(200), isLoading: false)
        #expect(popover.snapshot == opening(s, at: 200))

        popover.backlogFinished(s, at: at(400))
        #expect(popover.snapshot == opening(s, at: 200))
        #expect(model(s, at: 400, opened: popover.snapshot).idle.isEmpty)
    }

    /// Reading anew, e.g. after another folder was chosen, starts from an
    /// empty state, so an open popover waits for that backlog's end too.
    @Test func readingAnewWhileThePopoverIsOpenWaitsForTheNewBacklog() {
        var s = state(resting("s1"))
        var popover = IdleOpening()
        popover.popoverOpened(s, at: at(200), isLoading: false)

        popover.readingStarted()
        #expect(popover.snapshot == nil)
        s = state(resting("s1"))
        #expect(model(s, at: 400, opened: popover.snapshot).idle.map(\.key) == [key("s1")])

        popover.backlogFinished(s, at: at(400))
        #expect(popover.snapshot == opening(s, at: 400))
    }

    /// A closed popover has nothing to wait for.
    @Test func readingAnewWhileThePopoverIsClosedFixesNothingAtTheBacklogsEnd() {
        let s = state(resting("s1"))
        var popover = IdleOpening()
        popover.readingStarted()
        popover.backlogFinished(s, at: at(400))
        #expect(popover.snapshot == nil)
    }

    // MARK: When the rest began

    @Test func theRestBeginsAtTheTurnEnd() {
        let m = model(state(resting("s1")), at: 1000)
        #expect(m.idle.first?.idleSince == at(2))
    }

    @Test func theRestBeginsAtTheEndOfTheLastSubagentIfLater() {
        let s = state(
            session("s1", [.sessionStarted(cwd: "/p/s1", pid: nil), .promptSubmitted("go"), spawn("a", background: true), .turnEnded()]),
            [event("s1", at: 30, .agentFinished(id: "a"))]
        )
        #expect(model(s, at: 30 + 299).idle.isEmpty)
        #expect(model(s, at: 30 + 300).idle.first?.idleSince == at(30))
    }

    @Test func aSubagentEndedBeforeTheTurnEndLeavesTheTurnEnd() {
        let s = state(session("s1", [
            .sessionStarted(cwd: "/p/s1", pid: nil), .promptSubmitted("go"), spawn("a"), .agentFinished(id: "a"), .turnEnded(),
        ]))
        #expect(model(s, at: 1000).idle.first?.idleSince == at(4))
    }

    @Test func theRestBeginsAtTheEndOfTheBackgroundShellIfLater() {
        let s = state(resting("s1"), [
            event("s1", at: 3, .activityReported(.backgroundShell)),
            event("s1", at: 40, .activityReported(.idle)),
        ])
        #expect(model(s, at: 1000).idle.first?.idleSince == at(40))
    }

    @Test func aSessionWithoutATurnRestsFromItsStart() {
        let s = state(session("s1", [.sessionStarted(cwd: "/p/s1", pid: nil)]))
        #expect(model(s, at: 299).idle.isEmpty)
        #expect(model(s, at: 300).idle.first?.idleSince == t0)
    }

    @Test func aRepeatedStatusReportDoesNotRestartTheRest() {
        let s = state(resting("s1"), [
            event("s1", at: 3, .activityReported(.idle)),
            event("s1", at: 200, .activityReported(.idle)),
            event("s1", at: 250, .activityReported(.idle)),
        ])
        let m = model(s, at: 2 + 300)
        #expect(m.idle.map(\.key) == [key("s1")])
        #expect(m.idle.first?.idleSince == at(2))
    }

    // MARK: Order and counts

    @Test func idleSessionsListTheMostRecentRestFirst() {
        let s = state(resting("old"), resting("new", start: 20), resting("mid", start: 10))
        let m = model(s, at: 1000)
        #expect(m.idle.map(\.key) == [key("new"), key("mid"), key("old")])
    }

    @Test func idleSessionsRestingSinceTheSameMomentKeepAStableOrder() {
        let s = state(
            session("a", [.sessionStarted(cwd: "/p/a", pid: nil), .promptSubmitted("go")]) + [event("a", at: 10, .turnEnded())],
            session("b", start: 5, [.sessionStarted(cwd: "/p/b", pid: nil), .promptSubmitted("go")]) + [event("b", at: 10, .turnEnded())]
        )
        let m = model(s, at: 1000)
        // The later start first, as everywhere else in the list.
        #expect(m.idle.map(\.key) == [key("b"), key("a")])
    }

    @Test func theCardsKeepTheirOrderByPromptAroundTheIdleGroup() {
        let s = state(
            resting("idle"),
            session("first", start: 400, [.sessionStarted(cwd: "/p/first", pid: nil), .promptSubmitted("go")]),
            session("second", start: 500, [.sessionStarted(cwd: "/p/second", pid: nil), .promptSubmitted("go"), .turnEnded()])
        )
        let m = model(s, at: 600)
        #expect(m.sessions.map(\.key) == [key("second"), key("first")])
        #expect(m.idle.map(\.key) == [key("idle")])
    }

    @Test func idleSessionsCountOnTheirOwnTab() {
        let s = state(resting("idle"), session("busy", start: 900, [.sessionStarted(cwd: "/p/busy", pid: nil), .promptSubmitted("go")]))
        let m = model(s, at: 1000)
        #expect(m.idle.map(\.key) == [key("idle")])
        #expect(m.tabs.map(\.count) == [1, 1, 0])
        // Resting, the idle session no longer needs you.
        #expect(m.sessions.map(\.rowStatus) == [.working])
        #expect(m.needYouCount == 0)
    }

    @Test func onlyIdleSessionsLeaveActiveAllQuiet() {
        let m = model(state(resting("s1")), at: 1000)
        #expect(m.sessions.isEmpty)
        #expect(m.content == .allQuiet(idleCount: 1))
    }

    @Test func theEarlierSessionsUnderAWarningCountIdleSessions() {
        let s = state(resting("idle"), session("busy", start: 900, [.sessionStarted(cwd: "/p/busy", pid: nil), .promptSubmitted("go")]))
        let m = PopoverModel(
            state: s, now: at(1000), settings: PopoverSettings(),
            connection: .missing(integration(.notInstalled))
        )
        #expect(m.earlierSessions?.count == 2)
    }

    // MARK: Focus

    @Test func idleRowsTakeFocusOnlyWhileTheirTabIsSelected() {
        var s = state(
            resting("idle"),
            session("busy", start: 900, [.sessionStarted(cwd: "/p/busy", pid: nil), .promptSubmitted("go")]),
            session("done", start: 950, [.sessionStarted(cwd: "/p/done", pid: nil), .sessionEnded])
        )
        s.apply(event("idle", at: 960, .modelChanged(to: "m", from: nil)))
        var expansion = PopoverExpansion()
        #expect(model(s, at: 1000, expansion: expansion).focusOrder == [key("busy")])

        expansion.select(.idle)
        #expect(model(s, at: 1000, expansion: expansion).focusOrder == [key("idle")])
        expansion.select(.finished)
        #expect(model(s, at: 1000, expansion: expansion).focusOrder == [key("done")])
    }

    // MARK: Undo

    @Test func anArchivedIdleSessionKeepsItsPlaceAsUndoRow() throws {
        var s = state(resting("a"), resting("b", start: 10))
        var undo = ArchiveUndo()
        _ = undo.archive(.session(key("a")), in: &s, at: at(1000))
        var idleTab = PopoverExpansion()
        idleTab.select(.idle)
        let m = model(s, at: 1001, opened: opening(s, at: 900), expansion: idleTab, undo: undo)
        #expect(m.idle.map(\.key) == [key("b"), key("a")])
        let row = try #require(m.idle.last?.undo)
        #expect(en(row.text) == "a archived")
        #expect(m.tabs[1].count == 1)
        #expect(m.focusOrder == [key("b")])
    }

    // MARK: Texts

    @Test func theIdleRowWritesItsRestAndLastReplyAtTheViewsClock() throws {
        let s = state(session("s1", [
            .sessionStarted(cwd: "/p/s1", pid: nil), .promptSubmitted("go"), .replied(agent: .root, "All done."), .turnEnded(),
        ]))
        let item = try #require(model(s, at: 1000).idle.first)
        #expect(item.idleAccessibilityText(at: at(3 + 48 * 60)).map(en) == "idle for 48 min")
        // The status word says "idle" already.
        #expect(en(item.rowTimeText(at: at(3 + 12 * 60))) == "12 min")
        #expect(en(item.rowTimeText(at: at(3 + 2 * 3_600))) == "2 h")
        #expect(item.rowTimeCountsFrom == item.idleSince)
        #expect(item.lastReplyText(at: at(2 + 48 * 60)).map(en) == "Last reply, 48 min ago")
        #expect(item.reply?.text == "All done.")
        #expect(item.lastReplyAccessibilityText.map(en) == "Last reply: All done.")
    }

    /// The preview's clock counts from the reply, not from the rest, which
    /// began later once a background agent outlived the turn.
    @Test func theLastReplyCountsFromTheReplyNotTheRest() throws {
        let s = state(
            session("s1", [
                .sessionStarted(cwd: "/p/s1", pid: nil), .promptSubmitted("go"), spawn("a", background: true),
                .replied(agent: .root, "Started it."), .turnEnded(),
            ]),
            [event("s1", at: 30, .agentFinished(id: "a"))]
        )
        let item = try #require(model(s, at: 1000).idle.first)
        #expect(item.lastReplyAt == at(3))
        #expect(item.idleSince == at(30))
        #expect(item.lastReplyText(at: at(3 + 48 * 60)).map(en) == "Last reply, 48 min ago")
    }

    @Test func anIdleRowsReplyIsKeyedByItsSession() throws {
        let s = state(session("s1", [
            .sessionStarted(cwd: "/p/s1", pid: nil), .promptSubmitted("go"), .replied(agent: .root, "All done."), .turnEnded(),
        ]))
        #expect(model(s, at: 1000).idle.first?.reply?.id == .session(key("s1"), repliedAt: at(2)))
    }

    /// Back to work and resting again: the newer reply is another one.
    @Test func anIdleRowsNewerReplyHasANewID() throws {
        var s = state(session("s1", [
            .sessionStarted(cwd: "/p/s1", pid: nil), .promptSubmitted("go"), .replied(agent: .root, "First."), .turnEnded(),
        ]))
        for event in session("s1", start: 1000, [.promptSubmitted("again"), .replied(agent: .root, "Second."), .turnEnded()]) {
            s.apply(event)
        }
        let reply = try #require(model(s, at: 2000).idle.first?.reply)
        #expect(reply.text == "Second.")
        #expect(reply.id == .session(key("s1"), repliedAt: at(1001)))
    }

    @Test func anIdleRowWithoutAReplyHasNoPreview() throws {
        let item = try #require(model(state(resting("s1")), at: 1000).idle.first)
        #expect(item.reply == nil)
        #expect(item.lastReplyAt == nil)
        #expect(item.lastReplyText(at: at(1000)) == nil)
        #expect(item.lastReplyAccessibilityText == nil)
    }

    @Test func cardsHaveNoIdleText() throws {
        let s = state(session("s1", [.sessionStarted(cwd: "/p/s1", pid: nil), .promptSubmitted("go"), .turnEnded()]))
        let item = try #require(model(s, at: 100).sessions.first)
        #expect(item.idleSince == nil)
        #expect(item.idleAccessibilityText(at: at(100)) == nil)
    }

    @Test func idleAfterValues() {
        #expect(IdleAfter.allCases.map(\.rawValue) == ["fiveMinutes", "tenMinutes", "thirtyMinutes", "oneHour", "never"])
        #expect(IdleAfter.allCases.map(\.interval) == [300, 600, 1800, 3600, nil])
        #expect(IdleAfter.allCases.map { en($0.optionText) } == ["5 minutes", "10 minutes", "30 minutes", "1 hour", "Never"])
        #expect(IdleAfter.allCases.map { $0.waitingOverText.map(en) } == [
            "Waiting over 5 min", "Waiting over 10 min", "Waiting over 30 min", "Waiting over 1 h", nil,
        ])
        #expect(PopoverSettings().idleAfter == .fiveMinutes)
        #expect(PopoverSettings().idleSnapshot == nil)
    }

    @Test func theIdleTabReadsItsCountAndTime() {
        let one = model(state(resting("s1")), at: 1000)
        #expect(en(one.tabs[1].accessibilityLabel) == "Idle, 1 session, unread, Waiting over 5 min")
        #expect(one.tabs[1].help.map(en) == "Waiting over 5 min")

        let three = model(state(resting("a"), resting("b"), resting("c")), at: 5000, idleAfter: .oneHour)
        #expect(en(three.tabs[1].accessibilityLabel) == "Idle, 3 sessions, unread, Waiting over 1 h")
        #expect(three.tabs[1].help.map(en) == "Waiting over 1 h")
    }

    // MARK: Clock

    /// The rest running out is no change while the popover is open; only the
    /// next opening moves the session.
    @Test func theIdleThresholdSchedulesNoRebuild() {
        let s = state(resting("s1"))
        #expect(model(s, at: 100, opened: opening(s, at: 100)).nextChange == nil)
    }
}
