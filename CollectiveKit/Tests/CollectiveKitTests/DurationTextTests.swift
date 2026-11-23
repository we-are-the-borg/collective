import Foundation
import Testing
@testable import CollectiveKit

/// When a leaf's clock wakes: only when its duration text would read differently.
@Suite struct DurationTextTests {
    /// A leaf's clock wakes only when its text would read differently: each
    /// second in the first minute, then each minute, just past the turn.
    @Test func theTextChangesEachSecondThenEachMinute() {
        let since = Date(timeIntervalSinceReferenceDate: 815_000_000.37)
        func next(_ elapsed: TimeInterval) -> TimeInterval {
            DurationText.nextChange(after: since.addingTimeInterval(elapsed), countingFrom: since).timeIntervalSince(since)
        }
        #expect(abs(next(0) - 1) < 0.01)
        #expect(abs(next(58.5) - 59) < 0.01)
        #expect(abs(next(59.2) - 60) < 0.01)
        #expect(abs(next(60) - 120) < 0.01)
        #expect(abs(next(4_330) - 4_380) < 0.01)
        // Before its start a duration reads "0 s" until it reaches 1 s.
        #expect(abs(next(-30) - 1) < 0.01)
    }

    /// Written at the moment the clock wakes, the text is already the new one,
    /// whatever the rounding of the dates.
    @Test func atTheWakeTheTextIsTheNextOne() {
        for fraction in stride(from: 0.0, to: 1.0, by: 0.037) {
            let since = Date(timeIntervalSinceReferenceDate: 815_000_000 + fraction)
            var now = since
            for _ in 0..<70 {
                let wake = DurationText.nextChange(after: now, countingFrom: since)
                #expect(wake > now)
                #expect(DurationText.format(wake.timeIntervalSince(since)) != DurationText.format(now.timeIntervalSince(since)))
                #expect(DurationText.format(wake.addingTimeInterval(-0.01).timeIntervalSince(since)) == DurationText.format(now.timeIntervalSince(since)))
                now = wake
            }
        }
    }
}
