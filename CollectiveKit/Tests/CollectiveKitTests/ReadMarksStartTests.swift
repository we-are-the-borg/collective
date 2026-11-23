import Foundation
import Testing
@testable import CollectiveKit

private let key = SessionKey(source: "test-tool", sessionID: "s1")
private let other = SessionKey(source: "test-tool", sessionID: "s2")
private let t0 = Date(timeIntervalSince1970: 1_000)

private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func replay(_ session: SessionKey, endingAt seconds: TimeInterval, into state: inout CollectiveState) {
    state.apply(AgentEvent(session: session, timestamp: at(seconds - 5), kind: .promptSubmitted("go")))
    state.apply(AgentEvent(session: session, timestamp: at(seconds), kind: .turnEnded()))
}

/// How a reading starts from the read file.
@Suite struct ReadMarksStartTests {
    @Test func savedMarksAreRestoredAndTheBacklogChangesNothing() {
        var state = CollectiveState()
        var start = ReadMarksStart(restoring: [key: at(10)], into: &state)
        replay(key, endingAt: 10, into: &state)
        replay(other, endingAt: 20, into: &state)

        let saves = start.backlogFinished(in: &state)
        #expect(!saves)
        #expect(!state.isUnread(key))
        #expect(state.isUnread(other))
    }

    /// A file without marks is not a first launch: the user read nothing yet.
    @Test func anEmptyFileIsNotAFirstLaunch() {
        var state = CollectiveState()
        var start = ReadMarksStart(restoring: [:], into: &state)
        replay(key, endingAt: 10, into: &state)

        let saves = start.backlogFinished(in: &state)
        #expect(!saves)
        #expect(state.isUnread(key))
    }

    /// First launch with the feature: old sessions must not all show a dot.
    @Test func withoutAFileTheFirstBacklogCountsAsReadAndIsSavedOnce() {
        var state = CollectiveState()
        var start = ReadMarksStart(restoring: nil, into: &state)
        replay(key, endingAt: 10, into: &state)

        let saves = start.backlogFinished(in: &state)
        #expect(saves)
        #expect(!state.isUnread(key))

        replay(key, endingAt: 30, into: &state)
        let savesAgain = start.backlogFinished(in: &state)
        #expect(!savesAgain)
        #expect(state.isUnread(key))
    }

    /// Saved even without sessions, so the next launch finds a file.
    @Test func withoutAFileAnEmptyBacklogIsSavedToo() {
        var state = CollectiveState()
        var start = ReadMarksStart(restoring: nil, into: &state)

        let saves = start.backlogFinished(in: &state)
        #expect(saves)
        #expect(state.readMarks.isEmpty)
    }

    @Test func restoringReplacesMarksTheStateHeld() {
        var state = CollectiveState()
        state.markRead(other, upTo: at(5))

        _ = ReadMarksStart(restoring: [key: at(10)], into: &state)

        #expect(state.readMarks == [key: at(10)])
    }
}
