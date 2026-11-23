import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

private let source: SourceID = "test-tool"
private let t0 = Date(timeIntervalSince1970: 1_000)

private func key(_ id: String) -> SessionKey { SessionKey(source: source, sessionID: id) }
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func event(_ id: String, _ kind: AgentEvent.Kind, at seconds: TimeInterval) -> AgentEvent {
    AgentEvent(session: key(id), timestamp: at(seconds), kind: kind)
}

/// A session waiting for you, its turn ended at `start + 1`.
private func turn(_ id: String, start: TimeInterval, in state: inout CollectiveState) {
    state.apply(event(id, .promptSubmitted("go"), at: start))
    state.apply(event(id, .turnEnded(), at: start + 1))
}

private func rows(_ state: CollectiveState, at seconds: TimeInterval = 1000) -> [SessionKey: SessionItem] {
    let model = PopoverModel(
        state: state, now: at(seconds), settings: PopoverSettings(finishedRetention: .tenMinutes, idleAfter: .fiveMinutes)
    )
    return Dictionary(uniqueKeysWithValues: (model.sessions + model.idle + model.finished).map { ($0.key, $0) })
}

/// What the open popover showed is read once it closes.
@Suite struct UnreadReadingTests {
    @Test func aRowSeenWhileOpenIsReadAfterTheCommit() throws {
        var state = CollectiveState()
        turn("a", start: 900, in: &state)
        var reading = UnreadReading()

        reading.saw(try #require(rows(state)[key("a")]))
        // Nothing disappears under the user's eyes.
        #expect(try #require(rows(state)[key("a")]).isUnread)
        reading.commit(into: &state)

        #expect(!state.isUnread(key("a")))
    }

    @Test func aRowNeverSeenStaysUnread() throws {
        var state = CollectiveState()
        turn("a", start: 900, in: &state)
        turn("b", start: 902, in: &state)
        var reading = UnreadReading()

        reading.saw(try #require(rows(state)[key("a")]))
        reading.commit(into: &state)

        #expect(!state.isUnread(key("a")))
        #expect(state.isUnread(key("b")))
    }

    @Test func aTurnEndingAfterTheRowWasLastSeenStaysUnread() throws {
        var state = CollectiveState()
        turn("a", start: 900, in: &state)
        var reading = UnreadReading()

        reading.saw(try #require(rows(state)[key("a")]))
        turn("a", start: 950, in: &state)
        reading.commit(into: &state)

        #expect(state.isUnread(key("a")))
    }

    @Test func seeingTheNewerTurnEndReadsItToo() throws {
        var state = CollectiveState()
        turn("a", start: 900, in: &state)
        var reading = UnreadReading()

        reading.saw(try #require(rows(state, at: 940)[key("a")]))
        turn("a", start: 950, in: &state)
        reading.saw(try #require(rows(state)[key("a")]))
        reading.commit(into: &state)

        #expect(!state.isUnread(key("a")))
    }

    @Test func seeingARowThatIsNotUnreadRecordsNothing() throws {
        var state = CollectiveState()
        state.apply(event("a", .promptSubmitted("go"), at: 900))
        var reading = UnreadReading()

        reading.saw(try #require(rows(state)[key("a")]))

        #expect(reading.isEmpty)
    }

    @Test func theCommitStartsOver() throws {
        var state = CollectiveState()
        turn("a", start: 900, in: &state)
        var reading = UnreadReading()
        reading.saw(try #require(rows(state)[key("a")]))
        reading.commit(into: &state)

        #expect(reading.isEmpty)
        turn("a", start: 950, in: &state)
        reading.commit(into: &state)
        #expect(state.isUnread(key("a")))
    }
}
