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

private func state(_ events: [AgentEvent]...) -> CollectiveState {
    var state = CollectiveState()
    for event in events.flatMap({ $0 }).sorted(by: { $0.timestamp < $1.timestamp }) {
        state.apply(event)
    }
    return state
}

/// The turn ended at `start + 1`, moments before the model is built: waiting for you.
private func waiting(_ id: String, start: TimeInterval = 900) -> [AgentEvent] {
    session(id, start: start, [.promptSubmitted("go"), .turnEnded()])
}

/// The turn ended at `start + 1`, long before the model is built: idle.
private func resting(_ id: String, start: TimeInterval = 0) -> [AgentEvent] {
    session(id, start: start, [.promptSubmitted("go"), .turnEnded()])
}

private func ended(_ id: String, start: TimeInterval = 900) -> [AgentEvent] {
    session(id, start: start, [.promptSubmitted("go"), .turnEnded(), .sessionEnded])
}

private func working(_ id: String, start: TimeInterval = 900) -> [AgentEvent] {
    session(id, start: start, [.promptSubmitted("go"), .toolStarted(agent: .root, ToolActivity(name: "Bash", detail: "ls"))])
}

private func model(
    _ state: CollectiveState, at seconds: TimeInterval = 1000, undo: ArchiveUndo = ArchiveUndo()
) -> PopoverModel {
    PopoverModel(
        state: state, now: at(seconds), settings: PopoverSettings(finishedRetention: .tenMinutes, idleAfter: .fiveMinutes),
        undo: undo
    )
}

private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

private func tab(_ model: PopoverModel, _ tab: PopoverTab) -> TabItem? {
    model.tabs.first { $0.tab == tab }
}

/// Unread rows and tabs in the popover.
@Suite struct PopoverModelUnreadTests {
    // MARK: Rows

    @Test func aWaitingRowWhoseTurnEndedIsUnreadWithItsTurnEnd() throws {
        let row = try #require(model(state(waiting("a"))).sessions.first)

        #expect(row.isUnread)
        #expect(row.unreadTurnEndedAt == at(901))
    }

    @Test func aRowMarkedReadIsNoLongerUnread() throws {
        var state = state(waiting("a"))
        state.markRead(key("a"), upTo: at(901))
        let row = try #require(model(state).sessions.first)

        #expect(!row.isUnread)
        #expect(row.unreadTurnEndedAt == nil)
    }

    @Test func aWorkingRowIsNotUnread() throws {
        let row = try #require(model(state(working("a"))).sessions.first)

        #expect(!row.isUnread)
    }

    @Test func idleAndFinishedRowsCarryTheirUnreadTurnEnd() throws {
        let m = model(state(resting("r"), ended("d")))

        #expect(m.idle.map(\.unreadTurnEndedAt) == [at(1)])
        #expect(m.finished.map(\.unreadTurnEndedAt) == [at(901)])
    }

    // MARK: Tabs

    @Test func theIdleTabHasUnreadWhileAnIdleRowIsUnread() {
        #expect(tab(model(state(resting("r"))), .idle)?.hasUnread == true)

        var read = state(resting("r"))
        read.markRead(key("r"), upTo: at(1))
        #expect(tab(model(read), .idle)?.hasUnread == false)
    }

    @Test func theFinishedTabHasUnreadWhileAnEndedSessionIsUnread() {
        #expect(tab(model(state(ended("d"))), .finished)?.hasUnread == true)

        var read = state(ended("d"))
        read.markRead(key("d"), upTo: at(901))
        #expect(tab(model(read), .finished)?.hasUnread == false)
    }

    /// Active is shown on opening, so its rows need no sign on the tab.
    @Test func theActiveTabNeverHasUnread() throws {
        let m = model(state(waiting("a")))

        #expect(try #require(m.sessions.first).isUnread)
        #expect(tab(m, .active)?.hasUnread == false)
    }

    @Test func anArchivedSessionsUndoRowDoesNotCount() throws {
        var state = state(ended("d"))
        var undo = ArchiveUndo()
        _ = undo.archive(.finishedSession(key("d")), in: &state, at: at(998))
        let m = model(state, undo: undo)

        #expect(try #require(m.finished.first).undo != nil)
        #expect(tab(m, .finished)?.hasUnread == false)
    }

    // MARK: VoiceOver

    @Test func theRowsUnreadTextShowsOnlyWhileUnread() throws {
        var state = state(waiting("a"))
        let unread = try #require(model(state).sessions.first)
        #expect(unread.unreadAccessibilityText.map(en) == "unread")
        #expect(unread.unreadAccessibilityText?.key == "unread")

        state.markRead(key("a"), upTo: at(901))
        #expect(try #require(model(state).sessions.first).unreadAccessibilityText == nil)
    }

    @Test func voiceOverReadsUnreadAfterTheCountOnIdleAndFinished() {
        let m = model(state(waiting("a"), resting("r"), resting("s", start: 1), ended("d")))
        #expect(m.tabs.map { en($0.accessibilityLabel) } == [
            "Active, 1 session, 1 needs you", "Idle, 2 sessions, unread, Waiting over 5 min", "Finished, 1 session, unread, Cleared after 10 min",
        ])
        #expect(m.tabs[1].accessibilityLabel.key == "%@, %lld sessions, unread, %@", "key equal to its defaultValue pattern")

        var read = state(waiting("a"), resting("r"), ended("d"))
        read.markAllRead()
        #expect(model(read).tabs.map { en($0.accessibilityLabel) } == [
            "Active, 1 session, 1 needs you", "Idle, 1 session, Waiting over 5 min", "Finished, 1 session, Cleared after 10 min",
        ])
    }

    /// "need you" stays as it was: Active has no unread sign.
    @Test func voiceOverKeepsTheActiveTabsNeedYou() {
        let m = model(state(waiting("a")))
        #expect(en(m.tabs[0].accessibilityLabel) == "Active, 1 session, 1 needs you")
    }
}
