import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

private let source: SourceID = "test-tool"
private let t0 = Date(timeIntervalSince1970: 1_000)

private func key(_ id: String) -> SessionKey { SessionKey(source: source, sessionID: id) }

/// Events of one session, one second apart from `t0` on.
private func state(_ kinds: [AgentEvent.Kind]) -> CollectiveState {
    var state = CollectiveState()
    for (offset, kind) in kinds.enumerated() {
        state.apply(AgentEvent(session: key("s1"), timestamp: t0.addingTimeInterval(TimeInterval(offset)), kind: kind))
    }
    return state
}

/// The session's item `seconds` after `t0`, wherever it is listed.
private func item(_ kinds: [AgentEvent.Kind], at seconds: TimeInterval = 30) throws -> SessionItem {
    let popover = PopoverModel(
        state: state(kinds), now: t0.addingTimeInterval(seconds), settings: PopoverSettings(finishedRetention: .oneHour)
    )
    return try #require((popover.sessions + popover.finished).first)
}

private func spawn(_ id: String, background: Bool? = nil) -> AgentEvent.Kind {
    .agentSpawned(id: id, parent: .root, spec: AgentSpec(type: "explore", title: id.uppercased(), isBackground: background))
}

private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

private let started: AgentEvent.Kind = .sessionStarted(cwd: "/tmp/alpha", pid: nil)
private let test = ToolActivity(name: "Bash", detail: "swift test")

/// A row's own activity beside its subagents, and what its VoiceOver label
/// says of them.
@Suite struct SessionItemSubagentTests {
    // MARK: Activity

    /// The detail counts no subagents: the toggle line does.
    @Test func aSessionWaitingOnItsSubagentsShowsItsOwnActivity() throws {
        let item = try item([started, .promptSubmitted("Go"), spawn("a"), spawn("b")])
        #expect(item.state == .working)
        #expect(item.activity == .thinking)
        #expect(item.rowDetail == .thinking)
    }

    /// Waiting on a subagent busy with a tool, the orchestrator's own
    /// "Thinking…" still turns into "No activity" by the clock alone.
    @Test func aSessionWaitingOnItsSubagentsChangesByItsOwnClock() throws {
        let kinds: [AgentEvent.Kind] = [started, .promptSubmitted("Go"), spawn("a"), .toolStarted(agent: .subagent("a"), test)]
        let before = try item(kinds, at: 10)
        #expect(before.activity == .thinking)
        let change = try #require(before.nextChange)
        // The prompt (at 1) is the orchestrator's last event.
        #expect(change == t0.addingTimeInterval(1 + ActivityLine.quietThreshold))
        let after = try item(kinds, at: change.timeIntervalSince(t0))
        #expect(after.activity == .noActivity(since: t0.addingTimeInterval(1)))
    }

    // MARK: VoiceOver

    /// The active row's label names the working and the done ones.
    @Test func theRowsLabelNamesWorkingAndDoneSubagents() throws {
        let both = try item([started, .promptSubmitted("Go"), spawn("a"), spawn("b"), spawn("c"), .agentFinished(id: "c")])
        #expect(both.subagentsAccessibilityText.map(en) == "2 subagents working, 1 done")
        let done = try item([started, .promptSubmitted("Go"), spawn("a"), spawn("b"), .agentFinished(id: "a"), .agentFinished(id: "b"), .turnEnded()])
        #expect(done.subagentsAccessibilityText.map(en) == "2 subagents done")
        let working = try item([started, .promptSubmitted("Go"), spawn("a")])
        #expect(working.subagentsAccessibilityText.map(en) == "1 subagent working")
    }

    @Test func withoutSubagentsTheLabelSaysNothingOfThem() throws {
        let item = try item([started, .promptSubmitted("Go")])
        #expect(item.subagentsAccessibilityText == nil)
        #expect(item.doneSubagentsAccessibilityText == nil)
    }

    /// A finished row's label counts its done ones.
    @Test func aFinishedRowsLabelCountsItsDoneSubagents() throws {
        let item = try item([started, .promptSubmitted("Go"), spawn("a"), .agentFinished(id: "a"), .turnEnded(), .sessionEnded])
        #expect(item.endedAt != nil)
        #expect(item.doneSubagentsAccessibilityText.map(en) == "1 subagent done")
    }
}
