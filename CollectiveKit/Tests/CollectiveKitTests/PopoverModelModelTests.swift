import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

private let claude: SourceID = "claude-code"
private let t0 = Date(timeIntervalSince1970: 1_000)

/// Events of one session, one second apart starting at `t0`.
private func session(_ id: String, source: SourceID = claude, _ kinds: [AgentEvent.Kind]) -> [AgentEvent] {
    kinds.enumerated().map { offset, kind in
        AgentEvent(session: SessionKey(source: source, sessionID: id), timestamp: t0.addingTimeInterval(TimeInterval(offset)), kind: kind)
    }
}

private func state(_ events: [AgentEvent]) -> CollectiveState {
    var state = CollectiveState()
    for event in events { state.apply(event) }
    return state
}

/// Claude Code registers its naming; any other source falls back to the plain one.
private func model(_ state: CollectiveState) -> PopoverModel {
    PopoverModel(
        state: state,
        now: t0.addingTimeInterval(60),
        settings: PopoverSettings(),
        modelNaming: [claude: ClaudeCodeModelNaming()]
    )
}

private func item(_ kinds: [AgentEvent.Kind], source: SourceID = claude) throws -> SessionItem {
    try #require(model(state(session("s1", source: source, kinds))).sessions.first)
}

private func spawn(_ id: String, alias: String? = nil, modelID: String? = nil) -> AgentEvent.Kind {
    .agentSpawned(id: id, parent: .root, spec: AgentSpec(type: "explore", title: id, modelAlias: alias, modelID: modelID))
}

private func en(_ resource: LocalizedStringResource?) -> String? {
    guard var resource else { return nil }
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

@Suite("Popover model names")
struct PopoverModelModelTests {
    // MARK: Session header

    @Test("a known session model shows its short name, the raw id in the tooltip")
    func sessionModelKnown() throws {
        let opus = try #require(try item([.promptSubmitted("Go"), .modelChanged(to: "claude-opus-5-5", from: nil)]).model)
        #expect(opus.name == "Opus 5.5")
        #expect(!opus.isRawName)
        #expect(opus.rawName == "claude-opus-5-5")
        #expect(opus.helpDetail == nil)

        let haiku = try #require(try item([.promptSubmitted("Go"), .modelChanged(to: "claude-haiku-4-5-20251001", from: nil)]).model)
        #expect(haiku.name == "Haiku 4.5")
    }

    @Test("a source without naming shows the name as delivered")
    func sessionModelPlain() throws {
        let codex = try #require(try item([.promptSubmitted("Go"), .modelChanged(to: "gpt-5-codex", from: nil)], source: "codex").model)
        #expect(codex.name == "gpt-5-codex")
        #expect(codex.isRawName)
        #expect(codex.rawName == "gpt-5-codex")
    }

    @Test("without a model nothing shows")
    func noModel() throws {
        let item = try item([.promptSubmitted("Go"), spawn("a"), spawn("b")])
        #expect(item.model == nil)
    }

    @Test("after a switch the header shows the new model and when it switched")
    func switched() throws {
        let item = try item([
            .promptSubmitted("Go"),
            .modelChanged(to: "claude-opus-5-5", from: nil),
            spawn("a", alias: "opus"),
            .modelChanged(to: "claude-sonnet-5-5", from: "claude-opus-5-5"),
        ])
        let label = try #require(item.model)
        #expect(label.name == "Sonnet 5.5")
        #expect(label.rawName == "claude-sonnet-5-5")
        let at = t0.addingTimeInterval(3).formatted(date: .omitted, time: .shortened)
        #expect(en(label.helpDetail) == "Switched from Opus 5.5 at \(at)")
    }

    @Test("finished sessions carry their model")
    func finishedSession() throws {
        let m = model(state(session("s1", [
            .promptSubmitted("Go"), .modelChanged(to: "claude-opus-5-5", from: nil), .sessionEnded,
        ])))
        #expect(m.finished.first?.model?.name == "Opus 5.5")
    }

    @Test("Claude Code registers its own naming")
    func adapterRegistersNaming() {
        #expect(ClaudeCodeAdapter().modelNaming.displayName(forModel: "claude-opus-5-5") == "Opus 5.5")
    }
}
