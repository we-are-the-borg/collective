import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

private let source: SourceID = "test-tool"
private let t0 = Date(timeIntervalSince1970: 1_000)

private func key(_ id: String) -> SessionKey { SessionKey(source: source, sessionID: id) }

/// Events of one session, one second apart.
private func session(_ id: String, _ kinds: [AgentEvent.Kind]) -> [AgentEvent] {
    kinds.enumerated().map { offset, kind in
        AgentEvent(session: key(id), timestamp: t0.addingTimeInterval(TimeInterval(offset)), kind: kind)
    }
}

private func state(_ events: [AgentEvent]) -> CollectiveState {
    var state = CollectiveState()
    for event in events { state.apply(event) }
    return state
}

/// Without an "Idle" group, so a resting card stays a card however long it rests.
private func model(_ state: CollectiveState, at seconds: TimeInterval = 30, idleAfter: IdleAfter = .never) -> PopoverModel {
    PopoverModel(state: state, now: t0.addingTimeInterval(seconds), settings: PopoverSettings(idleAfter: idleAfter))
}

private func card(_ kinds: [AgentEvent.Kind]) throws -> SessionItem {
    try #require(model(state(session("s1", kinds))).sessions.first)
}

private func spawn(_ id: String, background: Bool? = nil) -> AgentEvent.Kind {
    .agentSpawned(id: id, parent: .root, spec: AgentSpec(type: "explore", title: id.uppercased(), isBackground: background))
}

private let bash = ToolActivity(name: "Bash", detail: "touch captures/perm-one")

/// A kit text as an English user reads it, resolved from the kit's catalog.
private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

/// The state an active card shows.
@Suite struct PopoverModelCardStateTests {
    // MARK: Working and waiting

    @Test func aWorkingOrchestratorMakesAWorkingCard() throws {
        let item = try card([.promptSubmitted("Go"), .toolStarted(agent: .root, bash)])
        #expect(item.cardState == .working)
        #expect(item.rowStatus == .working)
        #expect(item.rowDetail == .tool(bash))
    }

    @Test func anOrchestratorWaitingForThePromptMakesAWaitingCard() throws {
        let item = try card([.promptSubmitted("Go"), .turnEnded()])
        #expect(item.cardState == .waiting)
        #expect(item.rowStatus == .waitingForYou)
        #expect(item.activity == nil)
    }

    /// The reply answers what the waiting row calls the user for.
    @Test func aWaitingCardWithAReplyShowsItAndReadsIt() throws {
        let item = try card([.promptSubmitted("Go"), .replied(agent: .root, "All done."), .turnEnded()])
        #expect(item.cardState == .waiting)
        #expect(item.rowDetail == .reply(try #require(item.reply), lineLimit: 2))
        #expect(item.lastReplyAccessibilityText.map(en) == "Last reply: All done.")
    }

    // MARK: Needs permission

    /// The tool asking stays the activity; the box says what to allow.
    @Test func anOrchestratorAskingToAllowAToolMakesAPermissionCard() throws {
        let item = try card([
            .promptSubmitted("Go"),
            .toolStarted(agent: .root, bash),
            .permissionRequested(agent: .root, bash),
        ])
        #expect(item.cardState == .needsPermission)
        #expect(item.state == .working)
        #expect(item.rowStatus == .needsPermission)
        #expect(item.activity == .tool(bash))
        #expect(item.rowDetail == .permission(PermissionCommand(toolName: "Bash", command: "touch captures/perm-one")))
        #expect(item.rowStatus?.mark.word.map(en) == "needs permission")
    }

    /// The call going on answers the request.
    @Test func anAnsweredRequestMakesTheCardWorkAgain() throws {
        let item = try card([
            .promptSubmitted("Go"),
            .toolStarted(agent: .root, bash),
            .permissionRequested(agent: .root, bash),
            .toolFinished(agent: .root),
            .toolStarted(agent: .root, ToolActivity(name: "Read", detail: "README.md")),
        ])
        #expect(item.cardState == .working)
        #expect(item.rowStatus == .working)
        #expect(item.rowDetail == .tool(ToolActivity(name: "Read", detail: "README.md")))
    }

    @Test func aSubagentAskingWhileTheOrchestratorWorksMakesAPermissionCard() throws {
        let item = try card([
            .promptSubmitted("Go"),
            spawn("x1"),
            .toolStarted(agent: .subagent("x1"), bash),
            .permissionRequested(agent: .subagent("x1"), bash),
        ])
        #expect(item.state == .working)
        #expect(item.cardState == .needsPermission)
        #expect(item.rowStatus == .needsPermission)
        #expect(item.activity == .thinking)
    }

    /// A request is a call to act; background work is none, so it wins.
    @Test func aRequestWinsOverBackgroundWork() throws {
        let item = try card([
            .promptSubmitted("Go"),
            spawn("bg", background: true),
            .turnEnded(),
            .toolStarted(agent: .subagent("bg"), bash),
            .permissionRequested(agent: .subagent("bg"), bash),
        ])
        #expect(item.state == .backgroundWorking)
        #expect(item.cardState == .needsPermission)
        #expect(item.rowStatus == .needsPermission)
        // The orchestrator rests, so there is no activity of its own.
        #expect(item.activity == nil)
    }

    // MARK: Background

    /// The card behaves as if the orchestrator worked;
    /// only the status word tells the background agent apart.
    @Test func aBackgroundAgentWorkingAfterTheTurnMakesAWorkingCard() throws {
        let item = try card([.promptSubmitted("Go"), spawn("bg", background: true), .turnEnded()])
        #expect(item.state == .backgroundWorking)
        #expect(item.cardState == .working)
        #expect(item.rowStatus == .backgroundAgents(count: 1))
        #expect(item.shellPill == nil)
    }

    /// The boundary between agent and shell: an agent still working keeps
    /// the working card; the shell runs on beside it.
    @Test func aBackgroundAgentPlusAShellStillMakesAWorkingCard() throws {
        let item = try card([
            .promptSubmitted("Go"), spawn("bg", background: true), .turnEnded(), .activityReported(.backgroundShell),
        ])
        #expect(item.state == .backgroundWorking)
        #expect(item.cardState == .working)
        #expect(item.rowStatus == .backgroundAgents(count: 1))
        #expect(item.shellPill == ShellPill())
    }

    @Test func aBackgroundShellAfterTheTurnMakesABackgroundCard() throws {
        let item = try card([.promptSubmitted("Go"), .turnEnded(), .activityReported(.backgroundShell)])
        #expect(item.cardState == .background)
        #expect(item.rowStatus == .shellRunning(several: false))
    }

    // MARK: From the orchestrator's state

    @Test(arguments: [
        (AgentDisplayState.working, CardState?.some(.working)),
        (.backgroundWorking, .working),
        (.waiting, .waiting),
        (.backgroundShell, .background),
        (.done, nil),
        (.stale, nil),
        (.unassigned, nil),
        (.archived, nil),
    ])
    func theOrchestratorsStateNamesTheCard(state: AgentDisplayState, expected: CardState?) {
        #expect(CardState(state, awaitsPermission: false) == expected)
    }

    /// Permission and question win over every state a card shows, a
    /// background agent's included; a row without a card stays without one.
    @Test(arguments: [AgentDisplayState.working, .backgroundWorking, .waiting, .backgroundShell])
    func aCallToActWinsOverTheCardsState(state: AgentDisplayState) {
        #expect(CardState(state, awaitsPermission: true) == .needsPermission)
        #expect(CardState(state, awaitsPermission: true, awaitsAnswer: true) == .needsPermission)
        #expect(CardState(state, awaitsPermission: false, awaitsAnswer: true) == .question)
    }

    @Test(arguments: [AgentDisplayState.done, .stale, .unassigned, .archived])
    func aStateWithoutACardStaysWithoutOneWhenAsked(state: AgentDisplayState) {
        #expect(CardState(state, awaitsPermission: true, awaitsAnswer: true) == nil)
    }

    // MARK: Rows without a surface

    @Test func anIdleRowHasNoCardState() throws {
        let m = model(state(session("s1", [.promptSubmitted("Go"), .turnEnded()])), at: 10 * 60, idleAfter: .fiveMinutes)
        #expect(m.sessions.isEmpty)
        let row = try #require(m.idle.first)
        #expect(row.cardState == nil)
    }

    @Test func aFinishedRowHasNoCardState() throws {
        let m = model(state(session("s1", [.promptSubmitted("Go"), .turnEnded(), .sessionEnded])))
        let row = try #require(m.finished.first)
        #expect(row.cardState == nil)
    }

    @Test func anUndoRowHasNoCardState() throws {
        var s = state(session("s1", [.promptSubmitted("Go"), .turnEnded()]))
        var undo = ArchiveUndo()
        undo.archive(.session(key("s1")), in: &s, at: t0.addingTimeInterval(20))
        let m = PopoverModel(state: s, now: t0.addingTimeInterval(22), settings: PopoverSettings(idleAfter: .never), undo: undo)
        let row = try #require(m.sessions.first)
        #expect(row.undo != nil)
        #expect(row.cardState == nil)
    }
}
