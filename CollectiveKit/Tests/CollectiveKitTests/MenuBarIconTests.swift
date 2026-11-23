import Foundation
import Testing
@testable import CollectiveKit

private let missing = ConnectionStatus.missing(integration(.notInstalled))
private let disabled = ConnectionStatus.disabled(integration(.disabled(version: "0.4.0")))

private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

@Suite struct MenuBarIconTests {
    @Test func activeAgentCountMapsToIdleOrWorking() {
        #expect(MenuBarIcon(activeAgentCount: 0) == .idle)
        #expect(MenuBarIcon(activeAgentCount: -1) == .idle)
        #expect(MenuBarIcon(activeAgentCount: 3) == .working(count: 3))
    }

    /// The warning drops the count even while agents are known: subspace
    /// first needs the user's attention.
    @Test(arguments: [0, 3])
    func missingOrDisabledSubspaceWarnsWithoutCount(count: Int) {
        #expect(MenuBarIcon(activeAgentCount: count, awaitsPermission: false, connection: missing) == .warning)
        #expect(MenuBarIcon(activeAgentCount: count, awaitsPermission: false, connection: disabled) == .warning)
    }

    /// Precedence: warning, then needs permission, then working, then idle.
    /// The badge says "?" instead of a count, so the count doesn't matter.
    @Test(arguments: [0, 3])
    func aPermissionRequestWinsOverWorkingButNotOverTheWarning(count: Int) {
        #expect(MenuBarIcon(activeAgentCount: count, awaitsPermission: true, connection: .ok) == .needsPermission)
        #expect(MenuBarIcon(activeAgentCount: count, awaitsPermission: true, connection: missing) == .warning)
        #expect(MenuBarIcon(activeAgentCount: count, awaitsPermission: true, connection: disabled) == .warning)
    }

    @Test func withoutARequestTheCountDecides() {
        #expect(MenuBarIcon(activeAgentCount: 0, awaitsPermission: false, connection: .ok) == .idle)
        #expect(MenuBarIcon(activeAgentCount: 3, awaitsPermission: false, connection: .ok) == .working(count: 3))
    }

    @Test func theStateGivesCountAndRequest() {
        let key = SessionKey(source: "test-tool", sessionID: "s1")
        let t0 = Date(timeIntervalSince1970: 1_000)
        var state = CollectiveState()
        state.apply(AgentEvent(session: key, timestamp: t0, kind: .promptSubmitted("go")))
        #expect(MenuBarIcon(state: state, connection: .ok) == .working(count: 1))
        state.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(1), kind: .permissionRequested(agent: .root, ToolActivity(name: "Bash"))))
        #expect(MenuBarIcon(state: state, connection: .ok) == .needsPermission)
    }

    /// A session started ahead of time that waits for work is none the
    /// user started, whatever it seems to do.
    @Test func aStandbySessionLeavesTheIconIdle() {
        let key = SessionKey(source: "test-tool", sessionID: "s1")
        let t0 = Date(timeIntervalSince1970: 1_000)
        var state = CollectiveState()
        state.apply(AgentEvent(session: key, timestamp: t0, kind: .sessionStarted(cwd: nil, pid: 1), pid: 1))
        state.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(0.5), kind: .activityReported(.standby), pid: 1))
        state.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(1), kind: .promptSubmitted("go")))
        state.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(2), kind: .permissionRequested(agent: .root, ToolActivity(name: "Bash"))))
        #expect(MenuBarIcon(state: state, connection: .ok) == .idle)
    }

    /// Idle and warning stay template assets; the colored states are drawn.
    @Test func onlyIdleAndWarningAreTemplateAssets() {
        #expect(MenuBarIcon.idle.templateImageName == "MenuBarIdle")
        #expect(MenuBarIcon.warning.templateImageName == "MenuBarWarning")
        #expect(MenuBarIcon.working(count: 3).templateImageName == nil)
        #expect(MenuBarIcon.needsPermission.templateImageName == nil)
        #expect(MenuBarIcon.backgroundShell.templateImageName == nil)
    }

    @Test(arguments: [0, -3])
    func directlyConstructedWorkingWithoutAgentsIsIdle(count: Int) {
        let icon = MenuBarIcon.working(count: count)
        #expect(icon.templateImageName == "MenuBarIdle")
        #expect(icon.scene(at: Date(timeIntervalSinceReferenceDate: 1), appearance: .light, animation: MenuBarAnimation(), reduceMotion: false) == nil)
        #expect(icon.nextSceneChange(after: Date(timeIntervalSinceReferenceDate: 1), animation: MenuBarAnimation(), reduceMotion: false) == nil)
    }

    @Test func canvasAndTimingConstants() {
        #expect(MenuBarAnimation().frameRate.framesPerSecond == 12)
        #expect(MenuBarIcon.canvasWidth == 22)
        #expect(MenuBarIcon.canvasHeight == 18)
    }
}

/// VoiceOver hears "The Collective", then the state in the popover's words.
@Suite struct MenuBarIconAccessibilityTests {
    private let key = SessionKey(source: "test-tool", sessionID: "s1")
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func working(_ agents: Int) -> CollectiveState {
        var state = CollectiveState()
        for index in 0..<agents {
            let session = SessionKey(source: "test-tool", sessionID: "s\(index)")
            state.apply(AgentEvent(session: session, timestamp: t0, kind: .promptSubmitted("go")))
        }
        return state
    }

    @Test func labelNamesTheApp() {
        #expect(en(MenuBarIcon.accessibilityLabel) == "The Collective")
    }

    @Test func valueCountsWorkingAgents() {
        #expect(en(MenuBarIcon.accessibilityValue(state: working(0), connection: .ok)) == "No agents working")
        #expect(en(MenuBarIcon.accessibilityValue(state: working(1), connection: .ok)) == "1 agent working")
        #expect(en(MenuBarIcon.accessibilityValue(state: working(3), connection: .ok)) == "3 agents working")
    }

    @Test func aPermissionRequestIsNamed() {
        var state = working(2)
        state.apply(AgentEvent(session: SessionKey(source: "test-tool", sessionID: "s0"), timestamp: t0.addingTimeInterval(1), kind: .permissionRequested(agent: .root, ToolActivity(name: "Bash"))))
        #expect(en(MenuBarIcon.accessibilityValue(state: state, connection: .ok)) == "An agent needs your permission")
    }

    /// Same precedence as the icon: the warning wins, with the warning block's title.
    @Test func theWarningSaysWhatIsWrong() {
        #expect(en(MenuBarIcon.accessibilityValue(state: working(2), connection: missing)) == "subspace isn’t installed")
        #expect(en(MenuBarIcon.accessibilityValue(state: working(0), connection: disabled)) == "subspace is disabled")
    }

    /// The icon-based overload names every state on its own.
    @Test func valueFromTheIconNamesTheState() {
        #expect(en(MenuBarIcon.accessibilityValue(icon: .idle, connection: .ok)) == "No agents working")
        #expect(en(MenuBarIcon.accessibilityValue(icon: .working(count: 1), connection: .ok)) == "1 agent working")
        #expect(en(MenuBarIcon.accessibilityValue(icon: .working(count: 3), connection: .ok)) == "3 agents working")
        #expect(en(MenuBarIcon.accessibilityValue(icon: .needsPermission, connection: .ok)) == "An agent needs your permission")
        #expect(en(MenuBarIcon.accessibilityValue(icon: .warning, connection: missing)) == "subspace isn’t installed")
        #expect(en(MenuBarIcon.accessibilityValue(icon: .warning, connection: disabled)) == "subspace is disabled")
    }
}

/// An open question turns the icon amber with "?" like a permission request;
/// VoiceOver tells the two apart.
@Suite struct MenuBarIconQuestionTests {
    private let key = SessionKey(source: "test-tool", sessionID: "s1")
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let question = Question(text: "Tea or coffee?", options: [QuestionOption(label: "tea"), QuestionOption(label: "coffee")])

    private func asking(_ agent: AgentRef = .root) -> CollectiveState {
        var state = CollectiveState()
        state.apply(AgentEvent(session: key, timestamp: t0, kind: .promptSubmitted("go")))
        if case let .subagent(id) = agent {
            state.apply(AgentEvent(session: key, timestamp: t0, kind: .agentSpawned(id: id, parent: .root, spec: AgentSpec(type: "explore"))))
        }
        state.apply(AgentEvent(session: key, timestamp: t0.addingTimeInterval(1), kind: .questionAsked(agent: agent, [question])))
        return state
    }

    @Test func anOpenQuestionTurnsTheIconAmber() {
        let icon = MenuBarIcon(state: asking(), connection: .ok)
        #expect(icon == .question)
        #expect(icon.templateImageName == nil)
        let at = Date(timeIntervalSinceReferenceDate: 1)
        #expect(icon.scene(at: at, appearance: .light, animation: MenuBarAnimation(), reduceMotion: false)
            == MenuBarIcon.needsPermission.scene(at: at, appearance: .light, animation: MenuBarAnimation(), reduceMotion: false))
        #expect(icon.nextSceneChange(after: at, animation: MenuBarAnimation(), reduceMotion: false) != nil)
    }

    @Test func theWarningStillWins() {
        #expect(MenuBarIcon(state: asking(), connection: missing) == .warning)
        #expect(MenuBarIcon(state: asking(), connection: disabled) == .warning)
    }

    @Test func aPermissionRequestWinsOverAQuestion() {
        var state = asking()
        state.apply(AgentEvent(session: SessionKey(source: "test-tool", sessionID: "s2"), timestamp: t0, kind: .promptSubmitted("go")))
        state.apply(AgentEvent(
            session: SessionKey(source: "test-tool", sessionID: "s2"), timestamp: t0.addingTimeInterval(1),
            kind: .permissionRequested(agent: .root, ToolActivity(name: "Bash"))
        ))
        #expect(MenuBarIcon(state: state, connection: .ok) == .needsPermission)
        #expect(en(MenuBarIcon.accessibilityValue(state: state, connection: .ok)) == "An agent needs your permission")
    }

    @Test func anArchivedAgentAsksNothing() {
        var state = asking(.subagent("a"))
        state.archive(.agent(key, .subagent("a")), at: t0.addingTimeInterval(2))
        #expect(MenuBarIcon(state: state, connection: .ok) == .working(count: 1))
    }

    @Test func voiceOverSaysAnAgentAsks() {
        #expect(en(MenuBarIcon.accessibilityValue(state: asking(), connection: .ok)) == "An agent asks you a question")
        #expect(en(MenuBarIcon.accessibilityValue(icon: .question, connection: .ok)) == "An agent asks you a question")
    }
}

/// A shell an agent left running in the background glimmers the idle cube:
/// its own state below working, so the number stays the working agents'.
@Suite struct MenuBarIconBackgroundShellTests {
    private let key = SessionKey(source: "test-tool", sessionID: "s1")
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func event(_ kind: AgentEvent.Kind, at seconds: TimeInterval, session: SessionKey? = nil) -> AgentEvent {
        AgentEvent(session: session ?? key, timestamp: t0.addingTimeInterval(seconds), kind: kind)
    }

    /// A turn over, its shell still running.
    private func shellRunning() -> CollectiveState {
        var state = CollectiveState()
        state.apply(event(.promptSubmitted("go"), at: 0))
        state.apply(event(.turnEnded(), at: 1))
        state.apply(event(.activityReported(.backgroundShell), at: 1.5))
        return state
    }

    private let other = SessionKey(source: "test-tool", sessionID: "s2")

    @Test func aShellAloneGlimmers() {
        #expect(MenuBarIcon(state: shellRunning(), connection: .ok) == .backgroundShell)
    }

    /// The shell is no agent: the number counts the working ones only.
    @Test func aWorkingAgentHidesTheShell() {
        var state = shellRunning()
        state.apply(event(.promptSubmitted("go"), at: 2, session: other))
        #expect(MenuBarIcon(state: state, connection: .ok) == .working(count: 1))

        var sameSession = shellRunning()
        sameSession.apply(event(.promptSubmitted("next"), at: 3))
        #expect(sameSession.sessions[key]?.runsBackgroundShell == true)
        #expect(MenuBarIcon(state: sameSession, connection: .ok) == .working(count: 1))
    }

    @Test func aPermissionRequestOrAQuestionWinsOverTheShell() {
        var permission = shellRunning()
        permission.apply(event(.promptSubmitted("go"), at: 2, session: other))
        permission.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 3, session: other))
        #expect(MenuBarIcon(state: permission, connection: .ok) == .needsPermission)

        var question = shellRunning()
        question.apply(event(.promptSubmitted("go"), at: 2, session: other))
        question.apply(event(.questionAsked(agent: .root, [Question(text: "Tea?", options: [])]), at: 3, session: other))
        #expect(MenuBarIcon(state: question, connection: .ok) == .question)
    }

    @Test func theWarningWinsOverTheShell() {
        #expect(MenuBarIcon(state: shellRunning(), connection: missing) == .warning)
        #expect(MenuBarIcon(state: shellRunning(), connection: disabled) == .warning)
    }

    @Test func anArchivedSessionsShellLeavesTheIconIdle() {
        var state = shellRunning()
        state.archive(.session(key), at: t0.addingTimeInterval(2))
        #expect(MenuBarIcon(state: state, connection: .ok) == .idle)
    }

    /// VoiceOver names the shell only while it is the icon's state.
    @Test func voiceOverSaysAShellRuns() {
        #expect(en(MenuBarIcon.accessibilityValue(state: shellRunning(), connection: .ok)) == "A background shell is running")
        #expect(en(MenuBarIcon.accessibilityValue(icon: .backgroundShell, connection: .ok)) == "A background shell is running")
    }

    @Test func workingAndPermissionKeepTheirWordsWhileAShellRuns() {
        var working = shellRunning()
        working.apply(event(.promptSubmitted("go"), at: 2, session: other))
        #expect(en(MenuBarIcon.accessibilityValue(state: working, connection: .ok)) == "1 agent working")

        working.apply(event(.permissionRequested(agent: .root, ToolActivity(name: "Bash")), at: 3, session: other))
        #expect(en(MenuBarIcon.accessibilityValue(state: working, connection: .ok)) == "An agent needs your permission")
        #expect(en(MenuBarIcon.accessibilityValue(state: shellRunning(), connection: missing)) == "subspace isn’t installed")
    }

    /// The last report said `shell`, but the session is over.
    @Test func anEndedSessionRunsNoShell() {
        var state = shellRunning()
        state.apply(event(.sessionEnded, at: 3))
        #expect(MenuBarIcon(state: state, connection: .ok) == .idle)
    }
}
