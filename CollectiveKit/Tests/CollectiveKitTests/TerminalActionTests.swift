import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// "Show in <App>" on the popover's cards and rows, from the session's
// terminal target and the app the system resolves for it.

private let source: SourceID = "test-tool"
private let t0 = Date(timeIntervalSince1970: 1_000)
private let pid: Int32 = 767
private let warpTab = URL(string: "warp://session/16e5a860f58d4186bd579a30d87d0d18")!

private func key(_ id: String) -> SessionKey { SessionKey(source: source, sessionID: id) }

/// Run 21's `terminal`: an interactive session in a Warp tab.
private func warpTerminal() throws -> TerminalIdentifiers {
    let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/claude-code/2.1.317/21-terminal-env/terminal.json")
    return TerminalIdentifiers(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url)))
}

/// A terminal known only by its app (contract §4), as iTerm2 reports it.
private let iTerm = TerminalIdentifiers(["__CFBundleIdentifier": "com.googlecode.iterm2"])

/// A session started from `terminal` in its own process, its terminal
/// reported as its own unless `reported` is false, then `kinds` one second apart.
private func session(
    _ id: String, start: TimeInterval = 0, terminal: TerminalIdentifiers?, reported: Bool = true,
    _ kinds: [AgentEvent.Kind] = []
) -> [AgentEvent] {
    let all: [AgentEvent.Kind] = [.sessionStarted(cwd: "/Users/user/\(id)", pid: pid), .promptSubmitted("go")] + kinds
    var events = all.enumerated().map { offset, kind in
        AgentEvent(session: key(id), timestamp: t0.addingTimeInterval(start + TimeInterval(offset)), kind: kind,
                   pid: pid, terminal: terminal)
    }
    // The status file is read while the session runs.
    if reported {
        events.insert(AgentEvent(session: key(id), timestamp: t0.addingTimeInterval(start), kind: .terminalReported(.session), pid: pid), at: 1)
    }
    return events
}

private func state(_ events: [AgentEvent]...) -> CollectiveState {
    var state = CollectiveState()
    for event in events.flatMap({ $0 }) { state.apply(event) }
    return state
}

/// The system's installed apps, as a test sets them up.
private struct FakeTerminalApps: TerminalApps {
    var byBundleID: [String: TerminalApp] = [:]
    var byURL: [URL: TerminalApp] = [:]

    func app(bundleID: String) -> TerminalApp? { byBundleID[bundleID] }
    func app(opening url: URL) -> TerminalApp? { byURL[url] }
}

private let warp = TerminalApp(bundleID: "dev.warp.Warp-Stable", name: "Warp")
private let iTerm2 = TerminalApp(bundleID: "com.googlecode.iterm2", name: "iTerm2")
private let installed = FakeTerminalApps(byBundleID: [warp.bundleID: warp, iTerm2.bundleID: iTerm2])

/// A kit text as an English user reads it, resolved from the kit's catalog.
private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

private func action(_ events: [AgentEvent], apps: some TerminalApps = installed) throws -> TerminalAction? {
    TerminalAction(session: try #require(state(events).sessions[key("s1")]), apps: apps)
}

// MARK: - Seam: TerminalAction(session:apps:)

@Suite struct TerminalActionTests {
    @Test func warpSelectsTheSessionsTab() throws {
        let action = try #require(try action(session("s1", terminal: try warpTerminal())))
        #expect(action.target == .url(warpTab, bundleID: "dev.warp.Warp-Stable"))
        #expect(action.bundleID == "dev.warp.Warp-Stable")
        #expect(action.selectsTab)
        #expect(en(action.title) == "Show in Warp")
        #expect(en(action.help) == "Show in Warp ⌘↩")
    }

    @Test func anAppOnlyTargetBringsTheAppToTheFront() throws {
        let action = try #require(try action(session("s1", terminal: iTerm)))
        #expect(action.target == .app(bundleID: "com.googlecode.iterm2"))
        #expect(action.bundleID == "com.googlecode.iterm2")
        #expect(!action.selectsTab)
        #expect(en(action.title) == "Show in iTerm2")
        #expect(en(action.help) == "Brings iTerm2 to the front. It can’t select the session’s tab.")
    }

    /// The bundle is installed, but the system knows no name for it.
    @Test(arguments: [false, true])
    func anAppWithoutANameIsTheTerminal(appOnly: Bool) throws {
        let terminal = appOnly ? iTerm : try warpTerminal()
        let bundleID = appOnly ? "com.googlecode.iterm2" : "dev.warp.Warp-Stable"
        let nameless = FakeTerminalApps(byBundleID: [bundleID: TerminalApp(bundleID: bundleID, name: nil)])
        let action = try #require(try action(session("s1", terminal: terminal), apps: nameless))
        #expect(en(action.title) == "Show Terminal")
        #expect(en(action.help) == "Show Terminal ⌘↩")
    }

    /// A focus URL without a bundle: the app that opens it.
    @Test func aURLWithoutABundleIsOpenedByItsHandler() throws {
        let urlOnly = TerminalIdentifiers(["WARP_FOCUS_URL": warpTab.absoluteString])
        let shown = try #require(try action(session("s1", terminal: urlOnly), apps: FakeTerminalApps(byURL: [warpTab: warp])))
        #expect(shown.target == .url(warpTab, bundleID: nil))
        #expect(shown.bundleID == "dev.warp.Warp-Stable")
        #expect(shown.selectsTab)
        #expect(en(shown.title) == "Show in Warp")

        #expect(try action(session("s1", terminal: urlOnly)) == nil)
    }

    @Test func anAppThatIsNotInstalledOffersNothing() throws {
        #expect(try action(session("s1", terminal: try warpTerminal()), apps: FakeTerminalApps()) == nil)
        #expect(try action(session("s1", terminal: iTerm), apps: FakeTerminalApps()) == nil)
    }

    @Test func withoutATargetThereIsNoAction() throws {
        #expect(try action(session("s1", terminal: try warpTerminal(), reported: false)) == nil)
        #expect(try action(session("s1", terminal: nil)) == nil)
    }
}

// MARK: - Seam: PopoverModel(state:now:settings:…terminalApps:)

@Suite struct PopoverModelTerminalActionTests {
    private func model(_ state: CollectiveState, at seconds: TimeInterval, apps: (any TerminalApps)? = installed,
                       idleAfter: IdleAfter = .never, snapshot: IdleSnapshot? = nil) -> PopoverModel {
        let settings = PopoverSettings(idleAfter: idleAfter, idleSnapshot: snapshot)
        guard let apps else { return PopoverModel(state: state, now: t0.addingTimeInterval(seconds), settings: settings) }
        return PopoverModel(state: state, now: t0.addingTimeInterval(seconds), settings: settings, terminalApps: apps)
    }

    @Test func aCardOffersItsTerminal() throws {
        let state = state(
            session("s1", terminal: try warpTerminal(), [.turnEnded()]),
            session("s2", terminal: try warpTerminal(), reported: false, [.turnEnded()])
        )
        let cards = model(state, at: 10).sessions
        #expect(cards.first { $0.key == key("s1") }?.terminalAction?.bundleID == "dev.warp.Warp-Stable")
        #expect(cards.first { $0.key == key("s2") }?.terminalAction == nil)
        #expect(cards.count == 2)
    }

    @Test func anIdleRowOffersItsTerminal() throws {
        let state = state(session("s1", terminal: iTerm, [.turnEnded()]))
        let snapshot = IdleSnapshot(state, openedAt: t0.addingTimeInterval(600))
        let idle = model(state, at: 600, idleAfter: .fiveMinutes, snapshot: snapshot).idle
        #expect(idle.count == 1)
        #expect(idle.first?.terminalAction?.bundleID == "com.googlecode.iterm2")
    }

    /// Only while the target still holds: the session ended in its own process
    /// and its status file still exists, before it is deleted or after `/clear`.
    @Test func aFinishedRowOffersItsTerminal() throws {
        let state = state(session("s1", terminal: try warpTerminal(), [.turnEnded(), .sessionEnded]))
        let finished = model(state, at: 10).finished
        #expect(finished.count == 1)
        #expect(finished.first?.terminalAction?.selectsTab == true)
    }

    /// `/exit`: the status file is deleted after `SessionEnd` (subspace
    /// capture 2.1.287/1-idle-exit), so the row has nothing to bring forward.
    @Test func aFinishedRowWhoseStatusFileIsGoneOffersNothing() throws {
        let withdrawn = AgentEvent(session: key("s1"), timestamp: t0.addingTimeInterval(5), kind: .terminalReported(.unusable), pid: pid)
        let state = state(session("s1", terminal: try warpTerminal(), [.turnEnded(), .sessionEnded]), [withdrawn])
        let finished = model(state, at: 10).finished
        #expect(finished.count == 1)
        #expect(finished.first?.terminalAction == nil)
    }

    /// An undo row stands in for an archived card: nothing to show.
    @Test func anUndoRowOffersNothing() throws {
        var state = state(session("s1", terminal: try warpTerminal(), [.turnEnded()]))
        var undo = ArchiveUndo()
        _ = undo.archive(.session(key("s1")), in: &state, at: t0.addingTimeInterval(10))
        let item = try #require(PopoverModel(state: state, now: t0.addingTimeInterval(11), settings: PopoverSettings(idleAfter: .never),
                                             undo: undo, terminalApps: installed).sessions.first)
        #expect(item.undo != nil)
        #expect(item.terminalAction == nil)
    }

    @Test func withoutResolvedAppsNothingOffersATerminal() throws {
        let state = state(
            session("s1", terminal: try warpTerminal(), [.turnEnded()]),
            session("s2", terminal: iTerm, [.turnEnded(), .sessionEnded])
        )
        let byDefault = model(state, at: 10, apps: nil)
        #expect(byDefault.sessions.count == 1 && byDefault.finished.count == 1)
        #expect((byDefault.sessions + byDefault.finished).allSatisfy { $0.terminalAction == nil })

        let none = model(state, at: 10, apps: FakeTerminalApps())
        #expect((none.sessions + none.finished).allSatisfy { $0.terminalAction == nil })
    }

    // MARK: Placement

    /// Only permission and question show an action line; every other row keeps
    /// the action in its menu, ⌘↩ and VoiceOver.
    @Test func onlyPermissionAndQuestionShowAnActionLine() throws {
        let terminal = try warpTerminal()
        let working = state(session("s1", terminal: terminal, [.toolStarted(agent: .root, ToolActivity(name: "Edit"), callID: "c1")]))
        let workingRow = try #require(model(working, at: 3).sessions.first)
        #expect(workingRow.terminalAction != nil)
        #expect(workingRow.rowActions == nil)

        let waiting = state(session("s1", terminal: terminal, [.turnEnded()]))
        let waitingRow = try #require(model(waiting, at: 10).sessions.first)
        #expect(waitingRow.terminalAction != nil)
        #expect(waitingRow.rowActions == nil)

        let permission = state(session("s1", terminal: terminal, [.permissionRequested(agent: .root, ToolActivity(name: "Bash"))]))
        let permissionCard = try #require(model(permission, at: 3).sessions.first)
        #expect(permissionCard.cardState == .needsPermission)
        #expect(en(try #require(permissionCard.rowActions).hint) == "Allow or deny there.")

        let ask = ToolActivity(name: "Ask")
        let asking = state(session("s1", terminal: terminal, [
            .toolStarted(agent: .root, ask, callID: "c1"), .questionAsked(agent: .root, [Self.tea], callID: "c1"),
        ]))
        #expect(en(try #require(model(asking, at: 10).sessions.first?.rowActions).hint) == "Answer there.")

        let snapshot = IdleSnapshot(waiting, openedAt: t0.addingTimeInterval(600))
        let idleRow = try #require(model(waiting, at: 600, idleAfter: .fiveMinutes, snapshot: snapshot).idle.first)
        #expect(idleRow.terminalAction != nil)
        #expect(idleRow.rowActions == nil)

        let finished = state(session("s1", terminal: terminal, [.turnEnded(), .sessionEnded]))
        let finishedRow = try #require(model(finished, at: 10).finished.first)
        #expect(finishedRow.terminalAction != nil)
        #expect(finishedRow.rowActions == nil)
    }

    @Test func withoutAnActionTheLineSaysWhere() throws {
        let permission = state(session("s1", terminal: try warpTerminal(), [.permissionRequested(agent: .root, ToolActivity(name: "Bash"))]))
        let permissionRow = try #require(model(permission, at: 3, apps: nil).sessions.first)
        let actions = try #require(permissionRow.rowActions)
        #expect(en(actions.hint) == "Allow or deny in the terminal.")
    }

    // MARK: Question hints

    private static let tea = Question(
        header: nil, text: "Tea or coffee?",
        options: [QuestionOption(label: "tea"), QuestionOption(label: "coffee")], allowsOwnAnswer: false
    )

    private func question(_ questions: [Question], terminal: TerminalIdentifiers?, apps: (any TerminalApps)? = installed) throws -> QuestionPrompt {
        let ask = ToolActivity(name: "Ask")
        let events = session("s1", terminal: terminal, [
            .toolStarted(agent: .root, ask, callID: "c1"), .questionAsked(agent: .root, questions, callID: "c1"),
        ])
        return try #require(model(state(events), at: 10, apps: apps).sessions.first?.question)
    }

    @Test func theQuestionHintNamesTheApp() throws {
        let own = Question(header: nil, text: "Name?", options: [QuestionOption(label: "a")], allowsOwnAnswer: true)
        let bare = Question(header: nil, text: "Anything else?", options: [], allowsOwnAnswer: true)

        #expect(en(try question([own], terminal: try warpTerminal()).answerHint)
            == "Answer in Warp: type a number or your own answer.")
        #expect(en(try question([Self.tea], terminal: try warpTerminal()).answerHint) == "Answer in Warp: type a number.")
        #expect(en(try question([bare], terminal: iTerm).answerHint) == "Answer in iTerm2.")

        #expect(en(try question([bare], terminal: iTerm).accessibilityText) == "Choose one: Anything else? Answer in iTerm2.")
        #expect(en(try question([Self.tea, bare], terminal: try warpTerminal()).accessibilityText)
            == "Choose one: Tea or coffee? Options: 1 tea; 2 coffee. +1 more question. Answer in Warp.")
    }

    /// Without an action, the hints are today's.
    @Test(arguments: [false, true])
    func withoutAnActionTheHintSaysTerminal(hasTarget: Bool) throws {
        let prompt = try question([Self.tea, Self.tea], terminal: hasTarget ? try warpTerminal() : nil, apps: nil)
        #expect(en(prompt.answerHint) == "Answer in Terminal: type a number.")
        #expect(en(prompt.accessibilityText) == "Choose one: Tea or coffee? Options: 1 tea; 2 coffee. +1 more question. Answer in Terminal.")
    }

    /// A resolved app without a name keeps the "… in Terminal" texts.
    @Test func aNamelessAppKeepsTheTerminalHint() throws {
        let nameless = FakeTerminalApps(byBundleID: ["com.googlecode.iterm2": TerminalApp(bundleID: "com.googlecode.iterm2", name: nil)])
        #expect(en(try question([Self.tea], terminal: iTerm, apps: nameless).answerHint) == "Answer in Terminal: type a number.")
    }
}
