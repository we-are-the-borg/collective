import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

private let source: SourceID = "test-tool"
private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func key(_ id: String) -> SessionKey { SessionKey(source: source, sessionID: id) }

/// Events of one session at the given seconds after `t0`.
private func events(_ id: String, _ timed: [(TimeInterval, AgentEvent.Kind)]) -> [AgentEvent] {
    timed.map { AgentEvent(session: key(id), timestamp: t0.addingTimeInterval($0.0), kind: $0.1) }
}

private func state(_ events: [AgentEvent]...) -> CollectiveState {
    var state = CollectiveState()
    for event in events.flatMap({ $0 }).sorted(by: { $0.timestamp < $1.timestamp }) { state.apply(event) }
    return state
}

private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

private func spawn(_ id: String, background: Bool? = nil) -> AgentEvent.Kind {
    .agentSpawned(id: id, parent: .root, spec: AgentSpec(type: "explore", title: id.uppercased(), isBackground: background))
}

/// A working session with a working and a finished subagent, a waiting one
/// with a background agent, and a finished one.
private let scene = state(
    events("working", [
        (0, .sessionStarted(cwd: "/p/working", pid: nil)),
        (1, .promptSubmitted("Build it")),
        (2, spawn("a")),
        (3, .toolStarted(agent: .subagent("a"), ToolActivity(name: "Read", detail: "a.swift"))),
        (4, spawn("b")),
        (5, .agentFinished(id: "b")),
        (6, .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "swift test"))),
    ]),
    events("waiting", [
        (0, .sessionStarted(cwd: "/p/waiting", pid: nil)),
        (1, .promptSubmitted("Look around")),
        (2, spawn("bg", background: true)),
        (3, .replied(agent: .root, "Started a background agent.")),
        (4, .turnEnded()),
    ]),
    events("finished", [
        (0, .sessionStarted(cwd: "/p/finished", pid: nil)),
        (1, .promptSubmitted("Fix it")),
        (2, .replied(agent: .root, "Fixed.")),
        (3, .sessionEnded),
    ])
)

private func popover(_ state: CollectiveState, at seconds: TimeInterval, lastEventAt: Date? = nil, undo: ArchiveUndo = ArchiveUndo()) -> PopoverModel {
    PopoverModel(state: state, now: t0.addingTimeInterval(seconds), settings: PopoverSettings(), lastEventAt: lastEventAt, undo: undo)
}

/// The popover draws its model only when it changes: the times count at
/// the leaves (`timeText(at:)` and the like), so a model built a second later
/// without an event is the same model, and SwiftUI compares cheap values.
@Suite struct PresentationClockTests {
    @Test func aModelBuiltLaterWithoutEventsIsTheSame() {
        let early = popover(scene, at: 20, lastEventAt: t0.addingTimeInterval(6))
        let late = popover(scene, at: 41, lastEventAt: t0.addingTimeInterval(6))
        #expect(early.sessions.count == 2 && early.finished.count == 1)
        #expect(early == late)
    }

    @Test func theTimesAreWrittenAtTheLeafsClock() throws {
        let model = popover(scene, at: 20, lastEventAt: t0.addingTimeInterval(6))
        let working = try #require(model.sessions.first { $0.key == key("working") })
        let at = { (seconds: TimeInterval) in t0.addingTimeInterval(seconds) }
        #expect(en(working.timeText(at: at(20))) == "20 s")
        #expect(en(working.timeText(at: at(200))) == "3 min")
        #expect(working.timeCountsFrom == t0)
        #expect(en(working.lastEventText(at: at(66))) == "Last event 1 min ago")
        let finished = try #require(model.finished.first)
        #expect(en(finished.timeText(at: at(130))) == "Done 2 min ago")
        #expect(finished.timeCountsFrom == at(3))

        #expect(model.footerParts(at: at(30)).map(en) == ["Linked to subspace", "last event 24 s ago"])
        #expect(model.footerCountsFrom == at(6))
    }

    // MARK: When the clock alone changes a model

    /// The model says when it changes without an event, and is the same up
    /// to that moment.
    private func expectStable(_ build: (TimeInterval) -> PopoverModel, from start: TimeInterval, until change: TimeInterval) {
        let first = build(start)
        #expect(first.nextChange == t0.addingTimeInterval(change))
        #expect(build(change - 0.01) == first)
        #expect(build(change + 0.01) != first)
    }

    @Test func thinkingTurnsIntoNoActivityAtTheQuietThreshold() {
        let quiet = state(events("s", [(0, .promptSubmitted("go")), (5, .toolStarted(agent: .root, ToolActivity(name: "Read"))), (6, .toolFinished(agent: .root))]))
        let build = { (seconds: TimeInterval) in
            PopoverModel(state: quiet, now: t0.addingTimeInterval(seconds), settings: PopoverSettings())
        }
        // The finished call shows for a second from its start, then "Thinking…".
        #expect(build(5.5).sessions.first?.activity == .tool(ToolActivity(name: "Read")))
        expectStable(build, from: 5.5, until: 6)
        #expect(build(10).sessions.first?.activity == .thinking)
        expectStable(build, from: 10, until: 66)
        #expect(build(70).sessions.first?.activity == .noActivity(since: t0.addingTimeInterval(6)))
        // "No activity for …" counts at the leaf; nothing is left to wait for.
        #expect(build(70).nextChange == nil)
        #expect(build(70) == build(500))
    }

    @Test func aFinishedSessionLeavesTheListAfterItsRetention() {
        let ended = state(events("s", [(0, .promptSubmitted("go")), (2, .sessionEnded)]))
        let build = { (seconds: TimeInterval) in
            PopoverModel(state: ended, now: t0.addingTimeInterval(seconds), settings: PopoverSettings(finishedRetention: .fiveMinutes))
        }
        expectStable(build, from: 10, until: 302.001)
        #expect(build(10).finished.count == 1)
        #expect(build(302.01).finished.isEmpty)
    }

    /// A row is still listed at its retention's very end, so a model built
    /// then still waits for the row to go.
    @Test func aModelBuiltAtTheRetentionsEndStillWaitsForTheRowToGo() throws {
        let ended = state(events("s", [(0, .promptSubmitted("go")), (2, .sessionEnded)]))
        let build = { (seconds: TimeInterval) in
            PopoverModel(state: ended, now: t0.addingTimeInterval(seconds), settings: PopoverSettings(finishedRetention: .fiveMinutes))
        }
        #expect(build(302).finished.count == 1)
        #expect(build(302).nextChange == t0.addingTimeInterval(302.001))
        #expect(build(302.001).finished.isEmpty)
        #expect(build(302.001).nextChange == nil)
    }

    @Test func anUndoRowGoesWhenItsTimeIsUp() throws {
        var archived = state(events("s", [(0, .promptSubmitted("go")), (2, .turnEnded())]))
        var undo = ArchiveUndo()
        undo.archive(.session(key("s")), in: &archived, at: t0.addingTimeInterval(10))
        let build = { (seconds: TimeInterval) in
            PopoverModel(state: archived, now: t0.addingTimeInterval(seconds), settings: PopoverSettings(), undo: undo)
        }
        #expect(build(11).sessions.first?.undo != nil)
        expectStable(build, from: 11, until: 10 + ArchiveUndo.lifetime)
        #expect(build(10 + ArchiveUndo.lifetime + 0.01).sessions.isEmpty)
        // Held under the pointer, the row waits for nothing.
        undo.pause(try #require(undo.last).id, at: t0.addingTimeInterval(12))
        #expect(build(13).nextChange == nil)
    }

    @Test func anEmptyModelWaitsForNothing() {
        let empty = PopoverModel(state: CollectiveState(), now: t0, settings: PopoverSettings())
        #expect(empty.content == .dormant)
        #expect(empty.nextChange == nil)
        let loading = PopoverModel(state: CollectiveState(), now: t0, settings: PopoverSettings(), isLoading: true)
        #expect(loading.nextChange == nil)
    }
}
