import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

private let claude: SourceID = "claude-code"
private let t0 = Date(timeIntervalSince1970: 1_000)
private let high = EffortLevel(step: 3, name: "high")!
private let max = EffortLevel(step: 5, name: "max")!

/// Events of one session, one second apart starting at `t0`.
private func session(_ id: String, _ kinds: [AgentEvent.Kind]) -> [AgentEvent] {
    kinds.enumerated().map { offset, kind in
        AgentEvent(session: SessionKey(source: claude, sessionID: id), timestamp: t0.addingTimeInterval(TimeInterval(offset)), kind: kind)
    }
}

private func state(_ events: [AgentEvent]) -> CollectiveState {
    var state = CollectiveState()
    for event in events { state.apply(event) }
    return state
}

private func model(_ state: CollectiveState, at seconds: TimeInterval = 60, settings: PopoverSettings = PopoverSettings()) -> PopoverModel {
    PopoverModel(
        state: state,
        now: t0.addingTimeInterval(seconds),
        settings: settings,
        modelNaming: [claude: ClaudeCodeModelNaming()]
    )
}

private func item(_ kinds: [AgentEvent.Kind], settings: PopoverSettings = PopoverSettings()) throws -> SessionItem {
    try #require(model(state(session("s1", kinds)), settings: settings).sessions.first)
}

private let opus: AgentEvent.Kind = .modelChanged(to: "claude-opus-5-5", from: nil)

private func en(_ resource: LocalizedStringResource?) -> String? {
    guard var resource else { return nil }
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

@Suite("Popover effort gauge")
struct PopoverModelEffortTests {
    @Test("the card header's model carries the orchestrator's effort and names it in the tooltip")
    func orchestratorEffort() throws {
        let label = try #require(try item([.promptSubmitted("Go"), opus, .effortReported(agent: .root, high)]).model)
        let effort = try #require(label.effort)
        #expect(effort.step == 3)
        #expect(effort.name == "high")
        #expect(label.helpLines.map { en($0) } == ["Effort: high"])
    }

    @Test("after a change the tooltip also says from which level and when, after the model's own switch")
    func changed() throws {
        let label = try #require(try item([
            .promptSubmitted("Go"), opus, .effortReported(agent: .root, high),
            .modelChanged(to: "claude-sonnet-5-5", from: "claude-opus-5-5"),
            .effortReported(agent: .root, max),
        ]).model)
        #expect(label.effort?.step == 5)
        // Formatted as the model switch is, after the system's 12/24-hour setting.
        let switched = t0.addingTimeInterval(3).formatted(date: .omitted, time: .shortened)
        let changed = t0.addingTimeInterval(4).formatted(date: .omitted, time: .shortened)
        #expect(label.helpLines.map { en($0) } == [
            "Switched from Opus 5.5 at \(switched)", "Effort: max", "Effort changed from high at \(changed)",
        ])
    }

    @Test("VoiceOver reads the model with its effort as one element")
    func voiceOverWithEffort() throws {
        let label = try #require(try item([.promptSubmitted("Go"), opus, .effortReported(agent: .root, high)]).model)
        #expect(en(label.accessibilityLabel) == "Opus 5.5, effort high")
    }

    @Test("an unknown effort leaves the label as it was: no gauge, tooltip and VoiceOver without it")
    func unknownEffort() throws {
        let label = try #require(try item([.promptSubmitted("Go"), opus]).model)
        #expect(label.effort == nil)
        #expect(label.helpLines.isEmpty)
        #expect(en(label.accessibilityLabel) == "Opus 5.5")
    }

    @Test("without a model there is no label, so no gauge either")
    func effortWithoutModel() throws {
        #expect(try item([.promptSubmitted("Go"), .effortReported(agent: .root, high)]).model == nil)
    }

    @Test("an idle row carries the orchestrator's last known effort")
    func idleRow() throws {
        let popover = model(
            state(session("s1", [.promptSubmitted("Go"), opus, .effortReported(agent: .root, high), .turnEnded()])),
            at: 400, settings: PopoverSettings(idleAfter: .fiveMinutes)
        )
        let idle = try #require(popover.idle.first)
        #expect(idle.model?.effort?.name == "high")
        #expect(idle.model?.helpLines.map { en($0) } == ["Effort: high"])
    }

    @Test("the gauge takes its level's color by default, gray once the setting is off, subagents too")
    func coloring() throws {
        let kinds: [AgentEvent.Kind] = [
            .promptSubmitted("Go"), opus, .effortReported(agent: .root, high),
            .agentSpawned(id: "a", parent: .root, spec: AgentSpec(type: "explore", title: "a", modelAlias: "haiku")),
            .effortReported(agent: .subagent("a"), max),
        ]
        var expansion = PopoverExpansion()
        expansion.toggleSubagents(SessionKey(source: claude, sessionID: "s1"), isOpen: false)
        func card(_ settings: PopoverSettings) throws -> SessionItem {
            try #require(PopoverModel(
                state: state(session("s1", kinds)), now: t0.addingTimeInterval(60), settings: settings,
                modelNaming: [claude: ClaudeCodeModelNaming()], expansion: expansion
            ).sessions.first)
        }
        func subagent(_ item: SessionItem) -> EffortLabel? {
            item.subagentToggle?.list.entries.compactMap(\.row).first?.model?.effort
        }

        #expect(PopoverSettings().colorsEffortLevels)
        let colored = try card(PopoverSettings())
        #expect(colored.model?.effort?.isColored == true)
        #expect(subagent(colored)?.isColored == true)

        let gray = try card(PopoverSettings(colorsEffortLevels: false))
        #expect(gray.model?.effort?.isColored == false)
        #expect(gray.model?.effort?.step == 3)
        #expect(subagent(gray)?.isColored == false)
        #expect(subagent(gray)?.step == 5)
    }
}
