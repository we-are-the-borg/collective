import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

private let t0 = Date(timeIntervalSince1970: 100_000)

private func event(_ source: SourceID, at offset: TimeInterval) -> AgentEvent {
    AgentEvent(session: SessionKey(source: source, sessionID: "s"), timestamp: t0.addingTimeInterval(offset), kind: .turnStarted)
}

@Suite struct LastEventTimesTests {
    @Test func nothingRecordedKnowsNoTime() {
        let times = LastEventTimes()
        #expect(times.bySource.isEmpty)
    }

    @Test func keepsTheNewestEventPerSource() {
        var times = LastEventTimes()
        times.record([event("a", at: 5), event("b", at: 2), event("a", at: 1)])
        #expect(times.bySource == ["a": t0.addingTimeInterval(5), "b": t0.addingTimeInterval(2)])
    }

    /// The backlog replays out of order across batches; an older batch never moves a time back.
    @Test func anOlderBatchKeepsTheNewerTime() {
        var times = LastEventTimes()
        times.record([event("a", at: 5)])
        times.record([event("a", at: 3), event("b", at: 7)])
        #expect(times.bySource == ["a": t0.addingTimeInterval(5), "b": t0.addingTimeInterval(7)])
    }

    /// The reader hands the replay's times over already reduced; merging them
    /// keeps the newer time per source, as recording their events would.
    @Test func mergingKeepsTheNewerTimePerSource() {
        var times = LastEventTimes()
        times.record([event("a", at: 5), event("b", at: 2)])
        var other = LastEventTimes()
        other.record([event("a", at: 3), event("b", at: 4), event("c", at: 1)])
        times.merge(other)
        #expect(times.bySource == ["a": t0.addingTimeInterval(5), "b": t0.addingTimeInterval(4), "c": t0.addingTimeInterval(1)])
    }

    @Test func anEmptyBatchChangesNothing() {
        var times = LastEventTimes()
        times.record([])
        #expect(times == LastEventTimes())
    }
}
