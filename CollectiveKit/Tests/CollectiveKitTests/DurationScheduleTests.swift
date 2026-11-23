import Foundation
import Testing
@testable import CollectiveUI

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// The first `count` moments a leaf's clock draws at, starting at `seconds`.
private func moments(from seconds: TimeInterval, since: [TimeInterval], count: Int = 3) -> [TimeInterval] {
    let entries = DurationSchedule(since: since.map(at)).entries(from: at(seconds), mode: .normal)
    return entries.prefix(count).map { $0.timeIntervalSince(t0) }
}

private func expectMoments(_ actual: [TimeInterval], _ expected: [TimeInterval], sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual.count == expected.count, sourceLocation: sourceLocation)
    for (actual, expected) in zip(actual, expected) {
        #expect(abs(actual - expected) < 0.000_1, "\(actual) is not \(expected)", sourceLocation: sourceLocation)
    }
}

/// A leaf's clock wakes only when one of its times reads differently, just
/// past the turn (`DurationText.nextChange`).
@Suite struct DurationScheduleTests {
    @Test func withNothingToCountItDrawsOnce() {
        expectMoments(moments(from: 10, since: []), [10])
    }

    @Test func inTheFirstMinuteEachSecond() {
        expectMoments(moments(from: 10, since: [0]), [10, 11.001, 12.001])
        expectMoments(moments(from: 10.5, since: [0]), [10.5, 11.001, 12.001])
    }

    @Test func thenEachMinute() {
        expectMoments(moments(from: 58.5, since: [0]), [58.5, 59.001, 60.001])
        expectMoments(moments(from: 90, since: [0]), [90, 120.001, 180.001])
    }

    @Test func forHoursStillEachMinute() {
        expectMoments(moments(from: 7_230, since: [0]), [7_230, 7_260.001, 7_320.001])
    }

    @Test func severalCountsWakeAtTheEarliestTurn() {
        // 0 turns at 180, 100 counts its first minute: each second wins.
        expectMoments(moments(from: 130, since: [0, 100]), [130, 131.001, 132.001])
        // Both past their first minute, on different seconds of the minute.
        expectMoments(moments(from: 200, since: [0, 130], count: 4), [200, 240.001, 250.001, 300.001])
    }
}
