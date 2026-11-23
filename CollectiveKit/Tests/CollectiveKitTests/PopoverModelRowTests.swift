import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// The restyled rows, each part with the theme role it is drawn in.

private let source: SourceID = "test-tool"
private let t0 = Date(timeIntervalSince1970: 1_000)
private let pid: Int32 = 767

private func key(_ id: String) -> SessionKey { SessionKey(source: source, sessionID: id) }
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// Events of one session, one second apart.
private func session(_ id: String, _ kinds: [AgentEvent.Kind]) -> [AgentEvent] {
    kinds.enumerated().map { offset, kind in
        AgentEvent(session: key(id), timestamp: at(TimeInterval(offset)), kind: kind)
    }
}

private func session(_ kinds: [AgentEvent.Kind]) -> [AgentEvent] { session("s1", kinds) }

private func state(_ events: [AgentEvent]) -> CollectiveState {
    var state = CollectiveState()
    for event in events { state.apply(event) }
    return state
}

private func model(
    _ state: CollectiveState, at seconds: TimeInterval = 30, idleAfter: IdleAfter = .never,
    colorsEffortLevels: Bool = true, sourceNames: [SourceID: String] = [source: "Test Tool"],
    sourceLogos: [SourceID: String] = [:],
    expansion: PopoverExpansion = PopoverExpansion(), terminalApps: any TerminalApps = NoTerminalApps()
) -> PopoverModel {
    PopoverModel(
        state: state, now: at(seconds),
        settings: PopoverSettings(idleAfter: idleAfter, colorsEffortLevels: colorsEffortLevels),
        sourceNames: sourceNames, sourceLogos: sourceLogos, expansion: expansion, terminalApps: terminalApps
    )
}

/// The one active row.
private func row(_ kinds: [AgentEvent.Kind], terminalApps: any TerminalApps = NoTerminalApps()) throws -> SessionItem {
    try #require(model(state(session(kinds)), terminalApps: terminalApps).sessions.first)
}

private func spawn(_ id: String, background: Bool? = nil, type: String? = "explore", title: String? = nil) -> AgentEvent.Kind {
    .agentSpawned(id: id, parent: .root, spec: AgentSpec(type: type, title: title, isBackground: background))
}

private let bash = ToolActivity(name: "Bash", detail: "swift test --filter ReplyViewTests")
private let edit = ToolActivity(name: "Edit", detail: "CollectiveKit/Sources/PopoverModel.swift")

private let tea = Question(text: "Tea or coffee?", options: [QuestionOption(label: "Tea", detail: "Green"), QuestionOption(label: "Coffee")], allowsOwnAnswer: true)
private let fruits = Question(text: "Which fruits?", options: [QuestionOption(label: "Apple"), QuestionOption(label: "Pear")], allowsMultiple: true)

private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

private func en(_ resource: LocalizedStringResource?) -> String? {
    resource.map { en($0) }
}

/// The system's installed apps, as a test sets them up.
private struct FakeTerminalApps: TerminalApps {
    var byBundleID: [String: TerminalApp] = [:]
    func app(bundleID: String) -> TerminalApp? { byBundleID[bundleID] }
    func app(opening url: URL) -> TerminalApp? { nil }
}

private let iTermBundle = "com.googlecode.iterm2"
private let warpBundle = "dev.warp.Warp-Stable"

/// Known only by its app (contract §4), as iTerm2 reports it.
private let iTerm = TerminalIdentifiers(["__CFBundleIdentifier": iTermBundle])
/// A Warp tab with its focus URL, shaped as captured in run 21.
private let warpTab = TerminalIdentifiers([
    "__CFBundleIdentifier": warpBundle,
    "WARP_FOCUS_URL": "warp://session/16e5a860f58d4186bd579a30d87d0d18",
])

/// A session in its own process in `terminal` (iTerm2 by default), its
/// terminal reported as `ownership` (its own by default), then `kinds`.
private func terminalSession(
    _ kinds: [AgentEvent.Kind], terminal: TerminalIdentifiers = iTerm, ownership: TerminalOwnership = .session
) -> [AgentEvent] {
    let all: [AgentEvent.Kind] = [.sessionStarted(cwd: "/Users/user/s1", pid: pid), .terminalReported(ownership)] + kinds
    return all.enumerated().map { offset, kind in
        AgentEvent(session: key("s1"), timestamp: at(TimeInterval(offset)), kind: kind, pid: pid, terminal: terminal)
    }
}

private func terminalApps(appName: String? = "iTerm2") -> FakeTerminalApps {
    FakeTerminalApps(byBundleID: [
        iTermBundle: TerminalApp(bundleID: iTermBundle, name: appName),
        warpBundle: TerminalApp(bundleID: warpBundle, name: "Warp"),
    ])
}

private func terminalRow(_ kinds: [AgentEvent.Kind], appName: String? = "iTerm2") throws -> SessionItem {
    try #require(model(state(terminalSession(kinds)), terminalApps: terminalApps(appName: appName)).sessions.first)
}

// MARK: - Status

@Suite struct RowStatusTests {
    @Test func aWorkingSessionShowsTheBrightHaloInTheWorkingRole() throws {
        let status = try #require(try row([.promptSubmitted("Go"), .toolStarted(agent: .root, bash)]).rowStatus)
        #expect(status == .working)
        #expect(status.mark.shape == .haloDot(bright: true))
        #expect(status.mark.shapeRole == .agentWorking)
        #expect(en(status.mark.word) == "working")
        #expect(status.mark.wordRole == .agentWorking)
        #expect(status.mark.help == nil)
    }

    /// The count lives on the subagent toggle line, so the word is plain "working".
    @Test(arguments: [1, 2])
    func backgroundAgentsWorkLikeTheSession(count: Int) throws {
        let spawns = (1...count).map { spawn("bg\($0)", background: true) }
        let status = try #require(try row([.promptSubmitted("Go")] + spawns + [.turnEnded()]).rowStatus)
        #expect(status == .backgroundAgents(count: count))
        #expect(status.mark.shape == .haloDot(bright: true))
        #expect(status.mark.shapeRole == .agentWorking)
        #expect(en(status.mark.word) == "working")
        #expect(status.mark.wordRole == .agentWorking)
    }

    @Test func aPermissionRequestIsADiamondInTheWaitingRole() throws {
        let status = try #require(try row([
            .promptSubmitted("Go"), .toolStarted(agent: .root, bash), .permissionRequested(agent: .root, bash),
        ]).rowStatus)
        #expect(status == .needsPermission)
        #expect(status.mark.shape == .diamond)
        #expect(status.mark.shapeRole == .agentWaiting)
        #expect(en(status.mark.word) == "needs permission")
        #expect(status.mark.wordRole == .agentWaiting)
    }

    @Test(arguments: [([tea], "has a question"), ([tea, fruits], "has 2 questions")])
    func aQuestionCountsInTheWord(questions: [Question], word: String) throws {
        let status = try #require(try row([.promptSubmitted("Go"), .questionAsked(agent: .root, questions)]).rowStatus)
        #expect(status == .question(count: questions.count))
        #expect(status.mark.shape == .diamond)
        #expect(status.mark.shapeRole == .agentWaiting)
        #expect(en(status.mark.word) == word)
        #expect(status.mark.wordRole == .agentWaiting)
    }

    @Test func waitingForTheNextPromptIsADiamondToo() throws {
        let status = try #require(try row([.promptSubmitted("Go"), .turnEnded()]).rowStatus)
        #expect(status == .waitingForYou)
        #expect(status.mark.shape == .diamond)
        #expect(status.mark.shapeRole == .agentWaiting)
        #expect(en(status.mark.word) == "waiting for you")
        #expect(status.mark.wordRole == .agentWaiting)
    }

    @Test(arguments: [
        ([BackgroundShell(id: "b1", command: "make build")], false, "shell running"),
        ([BackgroundShell(id: "b1", command: "make build"), BackgroundShell(id: "b2", command: "npm run watch")], true, "shells running"),
    ])
    func aLoneShellIsAStillHollowHalo(shells: [BackgroundShell], several: Bool, word: String) throws {
        let status = try #require(try row([
            .promptSubmitted("Go"), .turnEnded(), .backgroundShellsListed(shells), .activityReported(.backgroundShell),
        ]).rowStatus)
        #expect(status == .shellRunning(several: several))
        #expect(status.mark.shape == .hollowHalo)
        #expect(status.mark.shapeRole == .textMuted)
        #expect(en(status.mark.word) == word)
        #expect(status.mark.wordRole == .textMuted)
    }

    @Test func anIdleRowIsARingWithASubtleWord() throws {
        let s = state(session([.promptSubmitted("Go"), .turnEnded()]))
        let status = try #require(model(s, at: 1000, idleAfter: .fiveMinutes).idle.first?.rowStatus)
        #expect(status == .idle)
        #expect(status.mark.shape == .ring)
        #expect(status.mark.shapeRole == .agentIdle)
        #expect(en(status.mark.word) == "idle")
        #expect(status.mark.wordRole == .textSubtle)
    }

    @Test func aFinishedRowIsACheck() throws {
        let s = state(session([.promptSubmitted("Go"), .turnEnded(), .sessionEnded]))
        let status = try #require(model(s).finished.first?.rowStatus)
        #expect(status == .done)
        #expect(status.mark.shape == .check)
        #expect(status.mark.shapeRole == .agentDone)
        #expect(en(status.mark.word) == "done")
        #expect(status.mark.wordRole == .agentDone)
    }

    /// The tooltip and VoiceOver hint stay.
    @Test func aStaleRowIsADashedRingWithoutACleanExit() throws {
        var s = state(session([.sessionStarted(cwd: "/p", pid: 7), .promptSubmitted("Go")]))
        s.markStale(now: at(10), silenceTimeout: 60, waitingTimeout: 60, processStart: { _ in nil })
        let status = try #require(model(s, at: 20).finished.first?.rowStatus)
        #expect(status == .noCleanExit)
        #expect(status.mark.shape == .dashedRing)
        #expect(status.mark.shapeRole == .textSubtle)
        #expect(en(status.mark.word) == "no clean exit")
        #expect(status.mark.wordRole == .textSubtle)
        #expect(en(status.mark.help) == "The process ended without a clean exit.")
    }

    @Test func anUndoRowHasNoStatus() throws {
        var s = state(session([.promptSubmitted("Go"), .turnEnded()]))
        var undo = ArchiveUndo()
        undo.archive(.session(key("s1")), in: &s, at: at(5))
        let item = try #require(PopoverModel(state: s, now: at(6), settings: PopoverSettings(idleAfter: .never), undo: undo).sessions.first)
        #expect(item.undo != nil)
        #expect(item.rowStatus == nil)
    }

    // MARK: Precedence

    /// Whatever the orchestrator does, a call to act comes first.
    @Test func aSubagentsPermissionWinsOverTheWorkingOrchestrator() throws {
        let status = try row([
            .promptSubmitted("Go"), spawn("x1"),
            .toolStarted(agent: .subagent("x1"), bash), .permissionRequested(agent: .subagent("x1"), bash),
        ]).rowStatus
        #expect(status == .needsPermission)
    }

    @Test func aPermissionWinsOverAQuestion() throws {
        let status = try row([
            .promptSubmitted("Go"), spawn("x1"),
            .questionAsked(agent: .root, [tea]),
            .toolStarted(agent: .subagent("x1"), bash), .permissionRequested(agent: .subagent("x1"), bash),
        ]).rowStatus
        #expect(status == .needsPermission)
    }

    @Test func aQuestionWinsOverBackgroundWork() throws {
        let status = try row([
            .promptSubmitted("Go"), spawn("bg", background: true), .turnEnded(),
            .questionAsked(agent: .subagent("bg"), [tea]),
        ]).rowStatus
        #expect(status == .question(count: 1))
    }

    // MARK: Archived subagents

    /// The row, the summary and "◆ n" ask the same: an archived subagent's
    /// request calls no one.
    private func archivedAsking(rootWorks: Bool) -> CollectiveState {
        let root: [AgentEvent.Kind] = rootWorks ? [.toolStarted(agent: .root, edit)] : [.turnEnded()]
        var s = state(session([
            .promptSubmitted("Go"), spawn("x1", background: true),
            .toolStarted(agent: .subagent("x1"), bash), .permissionRequested(agent: .subagent("x1"), bash),
        ] + root))
        s.archive(.agent(key("s1"), .subagent("x1")), at: at(10))
        return s
    }

    @Test func anArchivedSubagentAskingUnderAWaitingOrchestratorLeavesItWaitingForYou() throws {
        let built = model(archivedAsking(rootWorks: false))
        let item = try #require(built.sessions.first)
        #expect(item.rowStatus == .waitingForYou)
        #expect(item.cardState == .waiting)
        #expect(built.needYouCount == 1)
    }

    @Test func anArchivedSubagentAskingUnderAWorkingOrchestratorLeavesItWorking() throws {
        let built = model(archivedAsking(rootWorks: true))
        let item = try #require(built.sessions.first)
        #expect(item.rowStatus == .working)
        #expect(item.cardState == .working)
        #expect(built.needYouCount == 0)
    }

    /// Permission, a question and the next prompt need the user; work,
    /// background agents and a shell don't.
    @Test func onlySessionsWaitingForTheUserNeedYou() throws {
        let s = state(
            session("a", [.promptSubmitted("Go"), .toolStarted(agent: .root, bash), .permissionRequested(agent: .root, bash)])
                + session("b", [.promptSubmitted("Go"), .questionAsked(agent: .root, [tea])])
                + session("c", [.promptSubmitted("Go"), .turnEnded()])
                + session("d", [.promptSubmitted("Go"), .toolStarted(agent: .root, edit)])
                + session("e", [.promptSubmitted("Go"), spawn("bg", background: true), .turnEnded()])
                + session("f", [.promptSubmitted("Go"), .turnEnded(), .activityReported(.backgroundShell)])
        )
        let built = model(s)
        #expect(built.sessions.count == 6)
        #expect(built.needYouCount == 3)
    }
}

// MARK: - Detail lines

@Suite struct RowDetailTests {
    @Test func aWorkingRowShowsItsTool() throws {
        let item = try row([.promptSubmitted("Go"), .toolStarted(agent: .root, edit)])
        #expect(item.rowDetail == .tool(edit))
        #expect(RowDetail.toolNameRole == .text)
        #expect(RowDetail.toolDetailRole == .textMuted)
    }

    @Test func aWorkingRowBetweenToolsThinks() throws {
        let item = try row([.promptSubmitted("Go"), .turnStarted])
        #expect(item.rowDetail == .thinking)
        #expect(en(RowDetail.thinkingText) == "Thinking…")
        #expect(RowDetail.quietRole == .textSubtle)
    }

    @Test func aSilentWorkingRowSaysSinceWhen() throws {
        let s = state(session([.promptSubmitted("Go"), .turnStarted]))
        let item = try #require(model(s, at: 120).sessions.first)
        #expect(item.rowDetail == .noActivity(since: at(1)))
    }

    @Test func backgroundAgentsThink() throws {
        let item = try row([.promptSubmitted("Go"), spawn("bg", background: true), .turnEnded()])
        #expect(item.rowDetail == .thinking)
    }

    @Test func aWaitingRowShowsTwoLinesOfItsReply() throws {
        let item = try row([.promptSubmitted("Go"), .replied(agent: .root, "All done."), .turnEnded()])
        guard case let .reply(reply, lineLimit) = item.rowDetail else {
            Issue.record("no reply: \(String(describing: item.rowDetail))")
            return
        }
        #expect(reply.text == "All done.")
        #expect(lineLimit == 2)
        #expect(RowDetail.textRole == .textMuted)
    }

    @Test func aWaitingRowWithoutAReplyShowsNothing() throws {
        #expect(try row([.promptSubmitted("Go"), .turnEnded()]).rowDetail == nil)
    }

    /// The tool's name leads the box, whichever tool asks.
    @Test(arguments: [bash, ToolActivity(name: "Write", detail: "captures/perm-one")])
    func aPermissionShowsTheCommandAsked(tool: ToolActivity) throws {
        let item = try row([.promptSubmitted("Go"), .toolStarted(agent: .root, tool), .permissionRequested(agent: .root, tool)])
        let command = PermissionCommand(toolName: tool.name, command: tool.detail)
        #expect(item.rowDetail == .permission(command))
        #expect(command.prefix == "\(tool.name) ")
        #expect(command.prefixRole == .textSubtle)
        #expect(command.commandRole == .text)
        #expect(PermissionCommand.lineLimit == 4)
        #expect(RowDetail.boxSurfaceRole == .surfaceSunken)
        #expect(RowDetail.boxBorderRole == .border)
    }

    /// Not the orchestrator's own activity: what the subagent asks to run.
    @Test func aSubagentsPermissionShowsItsCommand() throws {
        let item = try row([
            .promptSubmitted("Go"), .toolStarted(agent: .root, edit), spawn("x1"),
            .toolStarted(agent: .subagent("x1"), bash), .permissionRequested(agent: .subagent("x1"), bash),
        ])
        #expect(item.rowDetail == .permission(PermissionCommand(toolName: "Bash", command: bash.detail)))
    }

    /// A request the agent sends again before anything answers the first:
    /// the box shows the newer, not the one first kept. The captured second
    /// requests come only after an answer, which drops the first.
    @Test func aSecondUnansweredRequestShowsTheNewerCommand() throws {
        let write = ToolActivity(name: "Write", detail: "captures/perm-two")
        let item = try row([
            .promptSubmitted("Go"), .toolStarted(agent: .root, bash), .permissionRequested(agent: .root, bash),
            .permissionRequested(agent: .root, write),
        ])
        #expect(item.rowDetail == .permission(PermissionCommand(toolName: "Write", command: "captures/perm-two")))
    }

    @Test func anArchivedSubagentsRequestIsNotTheCommandShown() throws {
        var s = state(session([
            .promptSubmitted("Go"), spawn("x1"), spawn("x2"),
            .toolStarted(agent: .subagent("x1"), bash), .permissionRequested(agent: .subagent("x1"), bash),
            .toolStarted(agent: .subagent("x2"), edit), .permissionRequested(agent: .subagent("x2"), edit),
        ]))
        s.archive(.agent(key("s1"), .subagent("x2")), at: at(10))
        let item = try #require(model(s).sessions.first)
        #expect(item.rowDetail == .permission(PermissionCommand(toolName: "Bash", command: bash.detail)))
    }

    /// No descriptions and no "Other"; "+1 more" for the rest.
    @Test func aQuestionShowsItsOptionsNumbered() throws {
        let item = try row([.promptSubmitted("Go"), .questionAsked(agent: .root, [tea, fruits])])
        guard case let .question(question) = item.rowDetail else {
            Issue.record("no question: \(String(describing: item.rowDetail))")
            return
        }
        #expect(question.text == "Tea or coffee?")
        #expect(question.listedOptions.map(\.number) == [1, 2])
        #expect(question.listedOptions.map(\.label) == [.option("Tea"), .option("Coffee")])
        #expect(question.choices.count == 3, "the old card's choices still end with Other")
        #expect(en(question.moreLine) == "+1 more")
        #expect(question.multiSelectHint == nil)
        #expect(question.textRole == .text)
        #expect(question.numberRole == .textSubtle)
        #expect(question.labelRole == .text)
        #expect(question.moreRole == .textSubtle)
        #expect(question.hintRole == .textSubtle)
        #expect(QuestionPrompt.questionLineLimit == 4)
    }

    @Test func aSingleQuestionHasNoMoreLine() throws {
        let item = try row([.promptSubmitted("Go"), .questionAsked(agent: .root, [tea])])
        guard case let .question(question) = item.rowDetail else {
            Issue.record("no question")
            return
        }
        #expect(question.moreLine == nil)
    }

    /// "Choose one" is gone; "Choose any" only for a multi-select question.
    @Test func onlyAMultiSelectQuestionSaysChooseAny() throws {
        let item = try row([.promptSubmitted("Go"), .questionAsked(agent: .root, [fruits, fruits, tea])])
        guard case let .question(question) = item.rowDetail else {
            Issue.record("no question")
            return
        }
        #expect(en(question.multiSelectHint) == "Choose any")
        #expect(en(question.moreLine) == "+2 more")
    }

    @Test(arguments: [
        ([BackgroundShell(id: "b1", command: "npm run dev -- --port 5173", description: "Dev server")], "npm run dev -- --port 5173"),
        ([BackgroundShell(id: "b1", description: "Tail the server log")], "Tail the server log"),
        ([BackgroundShell(id: "b1")], nil),
        ([BackgroundShell(id: "b1", command: "make"), BackgroundShell(id: "b2", command: "npm run watch")], nil),
    ] as [([BackgroundShell], String?)])
    func aShellRowNamesItsShell(shells: [BackgroundShell], command: String?) throws {
        let item = try row([.promptSubmitted("Go"), .turnEnded(), .backgroundShellsListed(shells), .activityReported(.backgroundShell)])
        guard case let .shell(line) = item.rowDetail else {
            Issue.record("no shell: \(String(describing: item.rowDetail))")
            return
        }
        #expect(en(ShellLine.labelText) == "Shell")
        #expect(line.command == command)
        #expect(line.tooltip == item.shellPill?.tooltip)
        #expect(line.labelRole == .textMuted)
        #expect(line.commandRole == .textMuted)
    }

    @Test func anIdleRowShowsOneLineOfItsReply() throws {
        let s = state(session([.promptSubmitted("Go"), .replied(agent: .root, "Bumped the schema."), .turnEnded()]))
        let item = try #require(model(s, at: 1000, idleAfter: .fiveMinutes).idle.first)
        guard case let .reply(reply, lineLimit) = item.rowDetail else {
            Issue.record("no reply")
            return
        }
        #expect(reply.text == "Bumped the schema.")
        #expect(lineLimit == 1)
    }

    @Test func aFinishedRowShowsItsReply() throws {
        let s = state(session([.promptSubmitted("Fix the lock"), .replied(agent: .root, "Fixed."), .turnEnded(), .sessionEnded]))
        let item = try #require(model(s).finished.first)
        guard case let .reply(reply, lineLimit) = item.rowDetail else {
            Issue.record("no reply")
            return
        }
        #expect(reply.text == "Fixed.")
        #expect(lineLimit == 1)
    }

    @Test func aFinishedRowWithoutAReplyShowsItsPrompt() throws {
        let s = state(session([.promptSubmitted("  Fix the flaky lock test\n"), .turnEnded(), .sessionEnded]))
        #expect(try #require(model(s).finished.first).rowDetail == .prompt("Fix the flaky lock test"))
    }
}

// MARK: - Actions

@Suite struct RowActionsTests {
    /// The jump button below shows the terminal, so only the hint is left.
    @Test func aPermissionSendsTheUserToTheTerminal() throws {
        let item = try terminalRow([.promptSubmitted("Go"), .toolStarted(agent: .root, bash), .permissionRequested(agent: .root, bash)])
        let actions = try #require(item.rowActions)
        #expect(item.jumpAction != nil)
        #expect(en(actions.hint) == "Allow or deny there.")
        #expect(actions.hintRole == .textSubtle)
    }

    @Test func aQuestionSendsTheUserToTheTerminal() throws {
        let actions = try #require(try terminalRow([.promptSubmitted("Go"), .questionAsked(agent: .root, [tea])]).rowActions)
        #expect(en(actions.hint) == "Answer there.")
    }

    @Test func aPermissionWithoutATerminalOnlySaysWhere() throws {
        let actions = try #require(try row([.promptSubmitted("Go"), .toolStarted(agent: .root, bash), .permissionRequested(agent: .root, bash)]).rowActions)
        #expect(en(actions.hint) == "Allow or deny in the terminal.")
    }

    @Test func aQuestionWithoutATerminalKeepsTodaysSentence() throws {
        let actions = try #require(try row([.promptSubmitted("Go"), .questionAsked(agent: .root, [tea])]).rowActions)
        #expect(en(actions.hint) == "Answer in Terminal: type a number or your own answer.")
    }

    /// A host's terminal gets the jump button too, so "there" points at it.
    @Test func aPermissionInAHostsTerminalPointsAtTheButton() throws {
        let s = state(terminalSession([.promptSubmitted("Go"), .toolStarted(agent: .root, bash), .permissionRequested(agent: .root, bash)], ownership: .host))
        let actions = try #require(model(s, terminalApps: terminalApps()).sessions.first?.rowActions)
        #expect(en(actions.hint) == "Allow or deny there.")
    }

    @Test func aQuestionInAHostsTerminalPointsAtTheButton() throws {
        let s = state(terminalSession([.promptSubmitted("Go"), .questionAsked(agent: .root, [tea])], ownership: .host))
        let actions = try #require(model(s, terminalApps: terminalApps()).sessions.first?.rowActions)
        #expect(en(actions.hint) == "Answer there.")
    }

    /// Only permission and question show an action line;
    /// every other row reaches the terminal through its "⋯" menu, ⌘↩ and VoiceOver.
    @Test(arguments: [
        ([AgentEvent.Kind.promptSubmitted("Go"), .toolStarted(agent: .root, bash)], RowStatus.working),
        ([.promptSubmitted("Go"), spawn("bg1", background: true), .turnEnded()], .backgroundAgents(count: 1)),
        ([.promptSubmitted("Go"), .turnEnded(), .activityReported(.backgroundShell)], .shellRunning(several: false)),
        ([.promptSubmitted("Go"), .turnEnded()], .waitingForYou),
    ])
    func otherActiveRowsHaveNoActionsThoughTheyHaveATerminal(kinds: [AgentEvent.Kind], expected: RowStatus) throws {
        let item = try terminalRow(kinds)
        #expect(item.rowStatus == expected)
        #expect(item.terminalAction != nil)
        #expect(item.rowActions == nil)
    }

    @Test(arguments: [
        ([AgentEvent.Kind.promptSubmitted("Go"), .toolStarted(agent: .root, bash)], RowStatus.working),
        ([.promptSubmitted("Go"), spawn("bg1", background: true), .turnEnded()], .backgroundAgents(count: 1)),
        ([.promptSubmitted("Go"), .turnEnded(), .activityReported(.backgroundShell)], .shellRunning(several: false)),
        ([.promptSubmitted("Go"), .turnEnded()], .waitingForYou),
    ])
    func otherActiveRowsWithoutATerminalHaveNoActions(kinds: [AgentEvent.Kind], expected: RowStatus) throws {
        let item = try row(kinds)
        #expect(item.rowStatus == expected)
        #expect(item.rowActions == nil)
    }

    @Test func anIdleRowHasNoActionsThoughItHasATerminal() throws {
        let s = state(terminalSession([.promptSubmitted("Go"), .turnEnded()]))
        let item = try #require(model(s, at: 1000, idleAfter: .fiveMinutes, terminalApps: terminalApps()).idle.first)
        #expect(item.rowStatus == .idle)
        #expect(item.terminalAction != nil)
        #expect(item.rowActions == nil)
    }

    @Test func anIdleRowWithoutATerminalHasNoActions() throws {
        let s = state(session([.promptSubmitted("Go"), .turnEnded()]))
        let item = try #require(model(s, at: 1000, idleAfter: .fiveMinutes).idle.first)
        #expect(item.rowStatus == .idle)
        #expect(item.rowActions == nil)
    }

    /// Finished rows get no button, though their terminal may still be known.
    @Test func aFinishedRowHasNoActions() throws {
        let s = state(terminalSession([.promptSubmitted("Go"), .turnEnded(), .sessionEnded]))
        let item = try #require(model(s, terminalApps: terminalApps()).finished.first)
        #expect(item.rowStatus == .done)
        #expect(item.terminalAction != nil)
        #expect(item.rowActions == nil)
    }

    @Test func aRowWithoutACleanExitHasNoActions() throws {
        var s = state(terminalSession([.promptSubmitted("Go")]))
        s.markStale(now: at(10), silenceTimeout: 60, waitingTimeout: 60, processStart: { _ in nil })
        let item = try #require(model(s, at: 20, terminalApps: terminalApps()).finished.first)
        #expect(item.rowStatus == .noCleanExit)
        #expect(item.rowActions == nil)
    }
}

// MARK: - Jump action

/// The jump line is a button whenever the session has a target,
/// a host's included; Finished always shows the form without target.
@Suite struct JumpActionTests {
    @Test func aWarpTabJumpsToWarp() throws {
        let s = state(terminalSession([.promptSubmitted("Go"), .turnEnded()], terminal: warpTab))
        let item = try #require(model(s, terminalApps: terminalApps()).sessions.first)
        let action = try #require(item.jumpAction)
        #expect(en(action.title) == "Show in Warp")
    }

    /// `claude --bg` and Codex on the shared daemon: only the app comes
    /// forward, but the button is there.
    @Test(arguments: [iTerm, warpTab])
    func aHostsTerminalStillJumps(terminal: TerminalIdentifiers) throws {
        let s = state(terminalSession([.promptSubmitted("Go"), .turnEnded()], terminal: terminal, ownership: .host))
        let item = try #require(model(s, terminalApps: terminalApps()).sessions.first)
        #expect(item.jumpAction != nil)
        #expect(item.jumpAction == item.terminalAction)
    }

    /// The menu still offers a finished row's terminal while it is known.
    @Test func aFinishedRowNeverJumps() throws {
        let s = state(terminalSession([.promptSubmitted("Go"), .turnEnded(), .sessionEnded], terminal: warpTab))
        let item = try #require(model(s, terminalApps: terminalApps()).finished.first)
        #expect(item.terminalAction != nil)
        #expect(item.jumpAction == nil)
    }

    @Test func anIdleRowJumps() throws {
        let s = state(terminalSession([.promptSubmitted("Go"), .turnEnded()]))
        let item = try #require(model(s, at: 1000, idleAfter: .fiveMinutes, terminalApps: terminalApps()).idle.first)
        #expect(item.jumpAction != nil)
    }

    @Test func aStaleRowDoesNotJump() throws {
        var s = state(terminalSession([.promptSubmitted("Go")]))
        s.markStale(now: at(10), silenceTimeout: 60, waitingTimeout: 60, processStart: { _ in nil })
        let item = try #require(model(s, at: 20, terminalApps: terminalApps()).finished.first)
        #expect(item.jumpAction == nil)
    }

    /// An undo row stands in for an archived card, even with a terminal.
    @Test func anUndoRowDoesNotJump() throws {
        var s = state(terminalSession([.promptSubmitted("Go"), .turnEnded()]))
        #expect(model(s, terminalApps: terminalApps()).sessions.first?.jumpAction != nil)
        var undo = ArchiveUndo()
        _ = undo.archive(.session(key("s1")), in: &s, at: at(10))
        let item = try #require(PopoverModel(state: s, now: at(11), settings: PopoverSettings(idleAfter: .never),
                                             undo: undo, terminalApps: terminalApps()).sessions.first)
        #expect(item.undo != nil)
        #expect(item.jumpAction == nil)
    }

    @Test func aRowWithoutATargetDoesNotJump() throws {
        let item = try row([.promptSubmitted("Go"), .turnEnded()], terminalApps: terminalApps())
        #expect(item.jumpAction == nil)
    }
}

// MARK: - Subagent toggle

@Suite struct SubagentToggleTests {
    private func toggle(_ item: SessionItem) throws -> SubagentToggle {
        try #require(item.subagentToggle)
    }

    @Test func thePartsComeWorkingNeedsYouDone() throws {
        let item = try row([
            .promptSubmitted("Go"), .toolStarted(agent: .root, edit),
            spawn("w1"), spawn("w2"), spawn("asks"), spawn("d1"), spawn("d2"), spawn("d3"),
            .toolStarted(agent: .subagent("asks"), bash), .permissionRequested(agent: .subagent("asks"), bash),
            .agentFinished(id: "d1"), .agentFinished(id: "d2"), .agentFinished(id: "d3"),
        ])
        let toggle = try toggle(item)
        #expect(en(toggle.title) == "Subagents")
        #expect(toggle.titleRole == .textMuted)
        #expect(toggle.separatorRole == .textSubtle)
        #expect(toggle.parts.map { en($0.text) } == ["2 working", "1 needs you", "3 done"])
        #expect(toggle.parts.map(\.role) == [.agentWorking, .agentWaiting, .textSubtle])
        #expect(toggle.parts.map(\.isSeparatedBefore) == [false, true, true])
        // Open by itself while a subagent needs the user.
        #expect(toggle.isOpen)
        #expect(toggle.list.session == key("s1"))
    }

    /// "Subagents · 3 done", zero parts left out.
    @Test func onlyDoneOnesStillGetTheirSeparator() throws {
        let item = try row([
            .promptSubmitted("Go"), .toolStarted(agent: .root, edit), spawn("d1"), spawn("d2"),
            .agentFinished(id: "d1"), .agentFinished(id: "d2"),
        ])
        let toggle = try toggle(item)
        #expect(toggle.parts.map { en($0.text) } == ["2 done"])
        #expect(toggle.parts.map(\.isSeparatedBefore) == [true])
        #expect(!toggle.isOpen)
        #expect(toggle.list.entries.isEmpty)
    }

    /// Lost contact last, in `textSubtle` like done, set apart like done.
    @Test func lostContactComesAfterDone() throws {
        var s = state(session([
            .sessionStarted(cwd: "/p", pid: 7), .promptSubmitted("Go"), spawn("w1"), spawn("w2"), spawn("d1"), .agentFinished(id: "d1"),
        ]))
        s.markStale(now: at(10), silenceTimeout: 60, waitingTimeout: 60, processStart: { _ in nil })
        let toggle = try toggle(try #require(model(s, at: 20).finished.first))
        #expect(toggle.parts.map { en($0.text) } == ["1 done", "2 lost contact"])
        #expect(toggle.parts.map(\.role) == [.textSubtle, .textSubtle])
        #expect(toggle.parts.map(\.isSeparatedBefore) == [true, true])
    }

    /// "Subagents · 1 lost contact", as with done alone.
    @Test func onlyLostOnesStillGetTheirSeparator() throws {
        var s = state(session([.sessionStarted(cwd: "/p", pid: 7), .promptSubmitted("Go"), spawn("w1")]))
        s.markStale(now: at(10), silenceTimeout: 60, waitingTimeout: 60, processStart: { _ in nil })
        let toggle = try toggle(try #require(model(s, at: 20).finished.first))
        #expect(toggle.parts.map(\.isSeparatedBefore) == [true])
        #expect(toggle.parts.map(\.role) == [.textSubtle])
    }

    /// Those waiting for a type work too.
    @Test func unassignedOnesCountAsWorking() throws {
        let item = try row([.promptSubmitted("Go"), .toolStarted(agent: .root, edit), spawn("w1"), spawn("u1", type: nil)])
        #expect(try toggle(item).parts.map { en($0.text) } == ["2 working"])
    }

    /// Archived ones don't count, at any depth.
    @Test func archivedOnesDontCountAtAnyDepth() throws {
        var s = state(session([
            .promptSubmitted("Go"), .toolStarted(agent: .root, edit), spawn("w1"), spawn("a1"),
            .agentSpawned(id: "deep", parent: .subagent("w1"), spec: AgentSpec(type: "explore")),
        ]))
        s.archive(.agent(key("s1"), .subagent("a1")), at: at(10))
        let item = try #require(model(s).sessions.first)
        #expect(try toggle(item).parts.map { en($0.text) } == ["2 working"])
    }

    @Test func allArchivedLeavesNoToggle() throws {
        var s = state(session([.promptSubmitted("Go"), .toolStarted(agent: .root, edit), spawn("a1")]))
        s.archive(.agent(key("s1"), .subagent("a1")), at: at(10))
        #expect(try #require(model(s, at: 60).sessions.first).subagentToggle == nil)
    }

    @Test func withoutSubagentsThereIsNoToggle() throws {
        #expect(try row([.promptSubmitted("Go"), .toolStarted(agent: .root, edit)]).subagentToggle == nil)
    }

    /// The same toggle in place of "✓ n", and it opens a list there too.
    @Test func idleAndFinishedRowsHaveTheToggle() throws {
        let kinds: [AgentEvent.Kind] = [.promptSubmitted("Go"), spawn("d1"), .agentFinished(id: "d1"), .turnEnded()]
        let idleState = state(session(kinds))
        let idleItem = try #require(model(idleState, at: 1000, idleAfter: .fiveMinutes).idle.first)
        #expect(try toggle(idleItem).parts.map { en($0.text) } == ["1 done"])

        let finishedState = state(session(kinds + [.sessionEnded]))
        var expansion = PopoverExpansion()
        expansion.toggleSubagents(key("s1"), isOpen: false)
        let finishedItem = try #require(model(finishedState, expansion: expansion).finished.first)
        let finishedToggle = try toggle(finishedItem)
        #expect(finishedToggle.parts.map { en($0.text) } == ["1 done"])
        #expect(finishedToggle.isOpen)
        #expect(finishedToggle.list.entries.count == 1, "the fold row of the done one")
    }

    @Test func voiceOverReadsTheParts() throws {
        let item = try row([.promptSubmitted("Go"), .toolStarted(agent: .root, edit), spawn("w1"), spawn("d1"), .agentFinished(id: "d1")])
        #expect(en(try toggle(item).accessibilityLabel) == "Subagents, 1 working, 1 done")
    }
}

// MARK: - Subagent rows

@Suite struct SubagentRowMarkTests {
    /// The open list's rows of a working orchestrator.
    private func rows(_ kinds: [AgentEvent.Kind], archive: [String] = []) throws -> [SubagentRow] {
        var s = state(session([.promptSubmitted("Go"), .toolStarted(agent: .root, edit)] + kinds))
        for id in archive { s.archive(.agent(key("s1"), .subagent(id)), at: at(30)) }
        var expansion = PopoverExpansion()
        expansion.toggleSubagents(key("s1"), isOpen: false)
        let item = try #require(model(s, at: 40, expansion: expansion).sessions.first)
        return try #require(item.subagentToggle?.list).entries.compactMap(\.row)
    }

    private func row(_ id: String, in rows: [SubagentRow]) throws -> SubagentRow {
        try #require(rows.first { $0.ref == .subagent(id) })
    }

    @Test func aWorkingSubagentIsAStillHaloDot() throws {
        let mark = try row("w1", in: rows([spawn("w1")])).statusMark
        #expect(mark.shape == .haloDot(bright: false))
        #expect(mark.shapeRole == .agentWorking)
        #expect(en(mark.word) == "working")
        #expect(mark.wordRole == .agentWorking)
    }

    @Test func aSubagentAskingIsADiamond() throws {
        let all = try rows([
            spawn("p1"), spawn("q1"),
            .toolStarted(agent: .subagent("p1"), bash), .permissionRequested(agent: .subagent("p1"), bash),
            .questionAsked(agent: .subagent("q1"), [tea]),
        ])
        let permission = try row("p1", in: all).statusMark
        #expect(permission.shape == .diamond)
        #expect(permission.shapeRole == .agentWaiting)
        #expect(en(permission.word) == "needs permission")
        #expect(permission.wordRole == .agentWaiting)
        let question = try row("q1", in: all).statusMark
        #expect(question.shape == .diamond)
        #expect(en(question.word) == "has a question")
        #expect(question.wordRole == .agentWaiting)
    }

    @Test func aDoneSubagentIsACheck() throws {
        // A done one shows as a member of its open fold row.
        let s = state(session([.promptSubmitted("Go"), .toolStarted(agent: .root, edit), spawn("d1"), .agentFinished(id: "d1")]))
        var expansion = PopoverExpansion()
        expansion.toggleSubagents(key("s1"), isOpen: false)
        expansion.toggleSubagentFold(SubagentFoldID(session: key("s1"), parent: .root))
        let item = try #require(model(s, at: 40, expansion: expansion).sessions.first)
        let done = try #require(item.subagentToggle?.list.entries.compactMap(\.row).first)
        #expect(done.statusMark.shape == .check)
        #expect(done.statusMark.shapeRole == .agentDone)
        #expect(en(done.statusMark.word) == "done")
        #expect(done.statusMark.wordRole == .agentDone)
    }

    /// Alone it still gets the toggle: the list shows it.
    @Test func aSubagentOutOfReachHasLostContact() throws {
        var s = state(session([.sessionStarted(cwd: "/p", pid: 7), .promptSubmitted("Go"), spawn("w1")]))
        s.markStale(now: at(10), silenceTimeout: 60, waitingTimeout: 60, processStart: { _ in nil })
        var expansion = PopoverExpansion()
        expansion.toggleSubagents(key("s1"), isOpen: false)
        let item = try #require(model(s, at: 20, expansion: expansion).finished.first)
        let lost = try #require(item.subagentToggle?.list.entries.compactMap(\.row).first)
        #expect(lost.status == .lostContact)
        #expect(lost.statusMark.shape == .dashedRing)
        #expect(lost.statusMark.shapeRole == .textSubtle)
        #expect(en(lost.statusMark.word) == "lost contact")
        #expect(lost.statusMark.wordRole == .textSubtle)
        #expect(item.subagentToggle?.parts.map { en($0.text) } == ["1 lost contact"])
    }

    @Test func aSubagentAwaitingDesignationIsAStillRing() throws {
        let mark = try row("u1", in: rows([spawn("u1", type: nil)])).statusMark
        #expect(mark.shape == .ring)
        #expect(mark.shapeRole == .textSubtle)
        // The title slot says it; the word would only repeat it.
        #expect(mark.word == nil)
    }

    private func withModel(_ id: String, type: String?, title: String?) -> AgentEvent.Kind {
        .agentSpawned(id: id, parent: .root, spec: AgentSpec(type: type, title: title, modelAlias: "sonnet"))
    }

    @Test func aTypedSubagentIsTitledByItsType() throws {
        let subagent = try row("w1", in: rows([withModel("w1", type: "explore", title: "Find the reducer")]))
        #expect(en(subagent.titleText) == "explore")
        #expect(subagent.titleKind == .type)
        #expect(subagent.titleRole == .text)
        #expect(subagent.titleModel != nil)
        #expect(subagent.modelRole == .textSubtle)
    }

    @Test func aSubagentWithOnlyATitleIsTitledByIt() throws {
        let subagent = try row("t1", in: rows([spawn("t1", type: nil, title: "Find the reducer")]))
        #expect(en(subagent.titleText) == "Find the reducer")
        #expect(subagent.titleKind == .title)
        #expect(subagent.titleRole == .text)
        #expect(subagent.status == .working)
        #expect(en(subagent.statusMark.word) == "working")
    }

    @Test func aSubagentAwaitingDesignationSaysSoOnceInTheTitle() throws {
        let subagent = try row("u1", in: rows([withModel("u1", type: nil, title: nil)]))
        #expect(subagent.model != nil)
        #expect(en(subagent.titleText) == "Awaiting designation…")
        #expect(subagent.titleKind == .awaitingDesignation)
        #expect(subagent.titleRole == .textSubtle)
        #expect(subagent.titleModel == nil)
    }

    @Test func theFoldRowIsSubtle() throws {
        var s = state(session([.promptSubmitted("Go"), .toolStarted(agent: .root, edit), spawn("d1"), spawn("a1"), spawn("w1"), .agentFinished(id: "d1")]))
        s.archive(.agent(key("s1"), .subagent("a1")), at: at(10))
        var expansion = PopoverExpansion()
        expansion.toggleSubagents(key("s1"), isOpen: false)
        let item = try #require(model(s, at: 60, expansion: expansion).sessions.first)
        guard case let .fold(fold)? = item.subagentToggle?.list.entries.first(where: { if case .fold = $0 { true } else { false } }) else {
            Issue.record("no fold row")
            return
        }
        #expect(fold.textParts.map(en) == ["1 done", "1 archived"])
        #expect(fold.textRole == .textSubtle)
        #expect(fold.depth == 1)
    }
}

// MARK: - Jump line

/// The last line of every row, a button with a target, else
/// the same line receding.
@Suite struct JumpLineTests {
    private let opus: AgentEvent.Kind = .modelChanged(to: "claude-opus-5-5", from: nil)

    private func level(_ step: Int) -> AgentEvent.Kind {
        .effortReported(agent: .root, EffortLevel(step: step, name: "level\(step)")!)
    }

    // MARK: Target

    @Test func aWarpTabIsATerminalButtonToWarp() throws {
        let s = state(terminalSession([.promptSubmitted("Go"), opus, level(3)], terminal: warpTab))
        let line = try #require(model(s, terminalApps: terminalApps()).sessions.first).jumpLine
        let target = try #require(line.target)
        #expect(target.symbol == .terminal)
        #expect(target.appName == "Warp")
        #expect(en(target.title) == "Show in Warp")
        #expect(en(target.help) == "Show in Warp ⌘↩")
        #expect(target.symbolRole == .textMuted)
        #expect(target.destinationRole == .text)
        #expect(target.separatorRole == .borderStrong)
        #expect(target.hoverSymbolRole == .text)
        #expect(line.toolRole == .textMuted)
        #expect(line.modelRole == .textMuted)
        #expect(line.effort?.step == 3)
    }

    /// iTerm2 is known only by its app: it comes forward, its tab can't be chosen.
    @Test func anAppOnlyTerminalIsAnAppWindowButton() throws {
        let line = try terminalRow([.promptSubmitted("Go"), .turnEnded()]).jumpLine
        let target = try #require(line.target)
        #expect(target.symbol == .appWindow)
        #expect(target.appName == "iTerm2")
        #expect(en(target.help) == "Brings iTerm2 to the front. It can’t select the session’s tab.")
    }

    /// `claude --bg`: the daemon's Warp tab is not the session's, only Warp comes forward.
    @Test func aHostsWarpTabIsAnAppWindowButton() throws {
        let s = state(terminalSession([.promptSubmitted("Go"), .turnEnded()], terminal: warpTab, ownership: .host))
        let item = try #require(model(s, terminalApps: terminalApps()).sessions.first)
        let target = try #require(item.jumpLine.target)
        #expect(target.symbol == .appWindow)
        #expect(target.appName == "Warp")
    }

    /// The bundle is installed, the system knows no name for it.
    @Test func aNamelessAppIsTerminal() throws {
        let target = try #require(try terminalRow([.promptSubmitted("Go"), .turnEnded()], appName: nil).jumpLine.target)
        #expect(target.appName == nil)
        #expect(en(target.fallbackDestination) == "Terminal")
        #expect(en(target.title) == "Show Terminal")
    }

    @Test func anIdleRowKeepsItsTargetAndGauge() throws {
        let s = state(terminalSession([.promptSubmitted("Go"), opus, level(2), .turnEnded()]))
        let line = try #require(model(s, at: 1000, idleAfter: .fiveMinutes, terminalApps: terminalApps()).idle.first).jumpLine
        #expect(line.target?.symbol == .appWindow)
        #expect(line.effort?.step == 2)
    }

    // MARK: Without target

    /// Logo, model and gauge alone, all subtle.
    @Test func withoutATargetTheLineRecedes() throws {
        let line = try row([.promptSubmitted("Go"), opus, level(3)]).jumpLine
        #expect(line.target == nil)
        #expect(line.toolRole == .textSubtle)
        #expect(line.modelRole == .textSubtle)
        #expect(line.model?.name == "claude-opus-5-5")
        #expect(line.effort?.step == 3)
        #expect(EffortLabel.emptyRole == .border)
    }

    /// Finished always shows the form without target, the model without its gauge.
    @Test func aFinishedRowHasNoTargetAndNoGauge() throws {
        let s = state(terminalSession([.promptSubmitted("Go"), opus, level(3), .turnEnded(), .sessionEnded], terminal: warpTab))
        let item = try #require(model(s, terminalApps: terminalApps()).finished.first)
        #expect(item.terminalAction != nil)
        let line = item.jumpLine
        #expect(line.target == nil)
        #expect(line.model?.name == "claude-opus-5-5")
        #expect(line.effort == nil)
        #expect(line.model.map { en($0.accessibilityLabel) } == "claude-opus-5-5")
    }

    @Test func anUndoRowHasNoTarget() throws {
        var s = state(terminalSession([.promptSubmitted("Go"), .turnEnded()]))
        var undo = ArchiveUndo()
        _ = undo.archive(.session(key("s1")), in: &s, at: at(10))
        let item = try #require(PopoverModel(state: s, now: at(11), settings: PopoverSettings(idleAfter: .never),
                                             undo: undo, terminalApps: terminalApps()).sessions.first)
        #expect(item.undo != nil)
        #expect(item.jumpLine.target == nil)
    }

    // MARK: Tool and model

    /// The adapter's logo stands for the tool; tooltip and VoiceOver name it.
    @Test func aToolWithALogoShowsIt() throws {
        let s = state(session([.promptSubmitted("Go"), .turnEnded()]))
        let line = try #require(model(s, sourceLogos: [source: "test-logo"]).sessions.first).jumpLine
        #expect(line.tool == .logo(name: "test-logo"))
        #expect(line.toolName == "Test Tool")
    }

    /// Without a logo the raw id stands in its place, even beside a display name.
    @Test func aToolWithoutALogoShowsItsRawID() throws {
        let line = try row([.promptSubmitted("Go"), .turnEnded()]).jumpLine
        #expect(line.tool == .sourceID("test-tool"))
        #expect(line.toolName == "Test Tool")
    }

    @Test func anUnknownSourceIsNamedByItsRawID() throws {
        let s = state(session([.promptSubmitted("Go"), .turnEnded()]))
        let line = try #require(model(s, sourceNames: [:]).sessions.first).jumpLine
        #expect(line.tool == .sourceID("test-tool"))
        #expect(line.toolName == "test-tool")
    }

    /// Without a model only the logo, no gauge.
    @Test func withoutAModelOnlyTheTool() throws {
        let line = try row([.promptSubmitted("Go"), level(3)]).jumpLine
        #expect(line.model == nil)
        #expect(line.effort == nil)
    }

    @Test(arguments: [(1, ThemeRole.success), (2, .info), (3, .classCode), (4, .accent), (5, .accent)])
    func eachLevelHasItsRole(step: Int, role: ThemeRole) throws {
        #expect(try row([.promptSubmitted("Go"), opus, level(step)]).jumpLine.effort?.role == role)
    }

    @Test(arguments: 1...5)
    func uncoloredLevelsAreSubtle(step: Int) throws {
        let s = state(session([.promptSubmitted("Go"), opus, level(step)]))
        let line = try #require(model(s, colorsEffortLevels: false).sessions.first).jumpLine
        #expect(line.effort?.role == .textSubtle)
    }
}
