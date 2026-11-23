import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

private let source: SourceID = "test-tool"
private let t0 = Date(timeIntervalSince1970: 1_000)

private func key(_ id: String) -> SessionKey { SessionKey(source: source, sessionID: id) }
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// Events of one session, one second apart starting at `start`.
private func session(_ id: String, start: TimeInterval = 0, _ kinds: [AgentEvent.Kind]) -> [AgentEvent] {
    kinds.enumerated().map { offset, kind in
        AgentEvent(session: key(id), timestamp: at(start + TimeInterval(offset)), kind: kind)
    }
}

/// Applies the events sorted by time, so sessions can interleave.
private func state(_ events: [AgentEvent]...) -> CollectiveState {
    var state = CollectiveState()
    for event in events.flatMap({ $0 }).sorted(by: { $0.timestamp < $1.timestamp }) {
        state.apply(event)
    }
    return state
}

private func spawn(_ id: String, background: Bool? = nil) -> AgentEvent.Kind {
    .agentSpawned(id: id, parent: .root, spec: AgentSpec(type: "explore", title: id.uppercased(), isBackground: background))
}

private let bash = ToolActivity(name: "Bash", detail: "swift test")

/// The orchestrator is at work.
private func working(_ id: String, start: TimeInterval = 0) -> [AgentEvent] {
    session(id, start: start, [.promptSubmitted("go"), .toolStarted(agent: .root, bash)])
}

/// The turn ended moments before the model is built: waiting for you, not idle yet.
private func waiting(_ id: String, start: TimeInterval = 900) -> [AgentEvent] {
    session(id, start: start, [.promptSubmitted("go"), .turnEnded()])
}

/// The turn ended long before the model is built: idle.
private func resting(_ id: String, start: TimeInterval = 0) -> [AgentEvent] {
    session(id, start: start, [.promptSubmitted("go"), .turnEnded()])
}

private func ended(_ id: String, start: TimeInterval = 900) -> [AgentEvent] {
    session(id, start: start, [.promptSubmitted("go"), .turnEnded(), .sessionEnded])
}

/// Built at 1000 s, so a turn that ended at 2 s has rested long enough for `IdleAfter.fiveMinutes`.
private func model(
    _ state: CollectiveState,
    at seconds: TimeInterval = 1000,
    tab: PopoverTab = .active,
    idleAfter: IdleAfter = .fiveMinutes,
    finishedRetention: FinishedRetention = .tenMinutes,
    expansion: PopoverExpansion = PopoverExpansion(),
    undo: ArchiveUndo = ArchiveUndo(),
    isLoading: Bool = false,
    indicatorVisible: Bool = false
) -> PopoverModel {
    var expansion = expansion
    expansion.select(tab)
    return PopoverModel(
        state: state, now: at(seconds), settings: PopoverSettings(finishedRetention: finishedRetention, idleAfter: idleAfter),
        expansion: expansion, undo: undo, isLoading: isLoading, loadingIndicatorVisible: indicatorVisible
    )
}

private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

private func count(_ model: PopoverModel, _ tab: PopoverTab) -> Int? {
    model.tabs.first { $0.tab == tab }?.count
}

/// The popover's tabs Active, Idle and Finished.
@Suite struct PopoverModelTabTests {
    // MARK: Selection

    @Test func thePopoverStartsOnActiveAndEveryOpeningReturnsThere() {
        var expansion = PopoverExpansion()
        #expect(expansion.selectedTab == .active)
        expansion.select(.finished)
        #expect(expansion.selectedTab == .finished)
        expansion.popoverOpened()
        #expect(expansion.selectedTab == .active)
    }

    @Test func theModelNamesTheSelectedTab() {
        let s = state(working("a"))
        for tab in PopoverTab.allCases {
            let m = model(s, tab: tab)
            #expect(m.selectedTab == tab)
            #expect(m.tabs.map(\.tab) == [.active, .idle, .finished])
            #expect(m.tabs.map(\.isSelected) == PopoverTab.allCases.map { $0 == tab })
        }
    }

    @Test func tabsAreNamed() {
        #expect(PopoverTab.allCases.map { en($0.title) } == ["Active", "Idle", "Finished"])
    }

    // MARK: Counts

    /// A tab counts the rows it shows, undo rows left out.
    @Test func eachTabCountsItsRowsWithoutUndoRows() {
        var s = state(working("a"), waiting("b"), waiting("gone"), resting("c"), ended("d"), ended("e", start: 901))
        var undo = ArchiveUndo()
        undo.archive(.session(key("gone")), in: &s, at: at(995))
        undo.archive(.finishedSession(key("e")), in: &s, at: at(995))
        let m = model(s, undo: undo)
        #expect(m.sessions.count == 3)
        #expect(count(m, .active) == 2)
        #expect(count(m, .idle) == 1)
        #expect(count(m, .finished) == 1)
    }

    @Test func emptyTabsCountZero() {
        let m = model(CollectiveState())
        #expect(m.tabs.map(\.count) == [0, 0, 0])
    }

    // MARK: Need you

    /// "◆ n" counts sessions in which anyone needs the user, at any depth, as
    /// the menu bar does, and "waiting for you" besides.
    @Test func needYouCountsSessionsInWhichAnyoneNeedsTheUser() {
        let subagentAsks = session("asks", start: 900, [
            .promptSubmitted("go"), spawn("x1"),
            .toolStarted(agent: .subagent("x1"), bash), .permissionRequested(agent: .subagent("x1"), bash),
        ])
        let question = session("question", start: 900, [
            .promptSubmitted("go"), .toolStarted(agent: .root, ToolActivity(name: "Ask"), callID: "c1"),
            .questionAsked(agent: .root, [Question(header: "Pick", text: "Which?")], callID: "c1"),
        ])
        let m = model(state(working("busy"), subagentAsks, question, waiting("waits"), resting("rests")))
        #expect(m.needYouCount == 3)
        #expect(m.tabs.map(\.needYouCount) == [3, 0, 0])
    }

    @Test func anArchivedSubagentAskingNeedsNobody() {
        var s = state(session("s1", start: 900, [
            .promptSubmitted("go"), spawn("x1"),
            .toolStarted(agent: .subagent("x1"), bash), .permissionRequested(agent: .subagent("x1"), bash),
            .toolStarted(agent: .root, bash),
        ]))
        s.archive(.agent(key("s1"), .subagent("x1")), at: at(990))
        #expect(model(s).needYouCount == 0)
    }

    /// The count shows whatever tab is selected; a new request switches no tab.
    @Test func needYouStaysOnActiveWhileAnotherTabIsSelected() {
        let m = model(state(waiting("waits"), resting("rests")), tab: .idle)
        #expect(m.selectedTab == .idle)
        #expect(m.needYouCount == 1)
        #expect(m.tabs.first?.needYouCount == 1)
    }

    @Test func needYouTooltipNamesTheCount() {
        let none = model(state(working("busy")))
        #expect(none.tabs[0].needYouText == nil)
        let one = model(state(waiting("a")))
        #expect(one.tabs[0].needYouText.map(en) == "1 needs you")
        let two = model(state(waiting("a"), waiting("b", start: 901)))
        #expect(two.tabs[0].needYouText.map(en) == "2 need you")
        #expect(two.tabs[1].needYouText == nil)
        #expect(two.tabs[0].needYouText?.key == "%lld need you", "shares the subagent footer's key")
    }

    // MARK: VoiceOver

    @Test func voiceOverReadsEachTabWithItsCounts() {
        var read = state(working("a"), waiting("b"), waiting("c", start: 901), resting("d"), resting("e", start: 1), ended("f"))
        // Unread adds to the label (PopoverModelUnreadTests).
        read.markAllRead()
        let m = model(read)
        #expect(m.tabs.map { en($0.accessibilityLabel) } == [
            "Active, 3 sessions, 2 need you", "Idle, 2 sessions, Waiting over 5 min", "Finished, 1 session, Cleared after 10 min",
        ])
        #expect(m.tabs[1].accessibilityLabel.key == "%@, %lld sessions, %@", "key equal to its defaultValue pattern")
        let quiet = model(state(working("a")))
        #expect(en(quiet.tabs[0].accessibilityLabel) == "Active, 1 session")
        #expect(en(quiet.tabs[1].accessibilityLabel) == "Idle, 0 sessions, Waiting over 5 min")
    }

    // MARK: Tab help

    /// Idle and Finished say their rule in the tooltip; Active has only "◆ n"'s.
    @Test func idleAndFinishedTellTheirRuleInTheTooltip() {
        let m = model(state(waiting("w"), resting("r"), ended("d")))
        #expect(m.tabs.map { $0.help.map(en) } == [nil, "Waiting over 5 min", "Cleared after 10 min"])
        // The rule shows whichever tab is selected.
        #expect(model(state(ended("d")), tab: .finished).tabs.map { $0.help.map(en) } == [nil, "Waiting over 5 min", "Cleared after 10 min"])
        // Shared with the settings' texts, keys equal to their defaultValue patterns.
        #expect(m.tabs.map { $0.help?.key } == [nil, "Waiting over %@", "Cleared after %@"])
    }

    @Test func theTabHelpFollowsTheSettings() {
        let m = model(state(resting("r")), idleAfter: .oneHour, finishedRetention: .thirtyMinutes)
        #expect(m.tabs.map { $0.help.map(en) } == [nil, "Waiting over 1 h", "Cleared after 30 min"])
    }

    /// Under "Never" no session goes idle, so there is no rule to tell.
    @Test func idleHasNoTooltipUnderNever() {
        let m = model(state(resting("r")), idleAfter: .never)
        #expect(m.tabs[1].help == nil)
        #expect(en(m.tabs[1].accessibilityLabel) == "Idle, 0 sessions")
    }

    /// A subagent asking under a working orchestrator makes the row "needs permission".
    @Test func aSubagentAskingMakesItsSessionNeedYou() {
        let m = model(state(session("s1", start: 900, [
            .promptSubmitted("go"), spawn("x1"),
            .toolStarted(agent: .subagent("x1"), bash), .permissionRequested(agent: .subagent("x1"), bash),
        ])))
        #expect(m.sessions.map(\.rowStatus) == [.needsPermission])
        #expect(m.needYouCount == 1)
    }

    // MARK: Content

    @Test func theSelectedTabListsItsRows() {
        let s = state(working("a"), resting("r"), ended("d"))
        let active = model(s, tab: .active)
        #expect(active.content == .list)
        #expect(active.rows.map(\.key) == [key("a")])
        #expect(model(s, tab: .idle).rows.map(\.key) == [key("r")])
        #expect(model(s, tab: .finished).rows.map(\.key) == [key("d")])
        #expect(model(s, tab: .idle).content == .list)
        #expect(model(s, tab: .finished).content == .list)
    }

    /// Resting sessions keep Active on Active, with a way to them.
    @Test func anEmptyActiveTabWithRestingSessionsIsAllQuiet() {
        let m = model(state(resting("r"), resting("q", start: 1)))
        #expect(m.content == .allQuiet(idleCount: 2))
        #expect(m.content.title.map(en) == "All quiet")
        #expect(m.content.message.map(en) == "No session is working or waiting for you.")
        #expect(m.content.showIdleText.map(en) == "Show 2 idle")
        #expect(model(state(resting("r"))).content.showIdleText.map(en) == "Show 1 idle")
    }

    /// "Show 0 idle" never shows: without resting sessions the Collective is dormant.
    @Test func anEmptyActiveTabWithoutRestingSessionsIsDormant() {
        #expect(model(CollectiveState()).content == .dormant)
        #expect(model(state(ended("d"))).content == .dormant)
        #expect(model(CollectiveState()).content.showIdleText == nil)
    }

    @Test func anEmptyTabWhileReadingShowsLoading() {
        #expect(model(CollectiveState(), isLoading: true).content == .loading(indicatorVisible: false))
        #expect(model(CollectiveState(), indicatorVisible: true).content == .loading(indicatorVisible: true))
        #expect(model(state(resting("r")), tab: .finished, isLoading: true).content == .loading(indicatorVisible: false))
        // Rows read so far show right away.
        #expect(model(state(working("a")), isLoading: true).content == .list)
    }

    @Test func emptyIdleAndFinishedTabsSayNothingIsThere() {
        let s = state(working("a"))
        let idle = model(s, tab: .idle)
        #expect(idle.content == .nothingIdle)
        #expect(idle.content.title.map(en) == "Nothing idle")
        #expect(idle.content.message == nil)
        let finished = model(s, tab: .finished)
        #expect(finished.content == .nothingFinished)
        #expect(finished.content.title.map(en) == "Nothing finished")
        // Under "Never" the Idle tab stays, empty.
        #expect(model(state(resting("r")), tab: .idle, idleAfter: .never).content == .nothingIdle)
    }

    /// The undo row of "Archive All Finished" is all the Finished tab lists then.
    @Test func theFinishedTabWithOnlyTheBulkUndoRowIsAList() {
        var s = state(ended("d"))
        var undo = ArchiveUndo()
        undo.archive(.allFinished([key("d")]), in: &s, at: at(995))
        let m = model(s, tab: .finished, undo: undo)
        #expect(m.finishedBulkUndo != nil)
        #expect(m.content == .list)
        #expect(count(m, .finished) == 0)
    }

    // MARK: Focus

    /// Only the selected tab's rows take focus, undo rows none.
    @Test func focusOrderFollowsTheSelectedTab() {
        var s = state(working("a"), waiting("gone"), resting("r"), resting("q", start: 1), ended("d"), ended("e", start: 901))
        var undo = ArchiveUndo()
        undo.archive(.session(key("gone")), in: &s, at: at(995))
        undo.archive(.finishedSession(key("d")), in: &s, at: at(995))
        #expect(model(s, undo: undo).focusOrder == [key("a")])
        #expect(model(s, tab: .idle, undo: undo).focusOrder == [key("q"), key("r")])
        #expect(model(s, tab: .finished, undo: undo).focusOrder == [key("e")])
    }
}
