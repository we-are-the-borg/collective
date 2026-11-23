import Foundation
import Testing
@testable import CollectiveUI

/// 30 Oct 2026 at the given hour and minute, UTC.
private func october30(_ hour: Int, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: hour, minute: minute))!
}

/// When the popover's clock turns (`ModelClock`): the moment it waits for.
@Suite struct ModelClockTests {
    @Test func itWaitsForAChangeAfterTheBuild() {
        #expect(ClockTurn.wait(for: october30(8, 1), builtAt: october30(8)) == october30(8, 1))
        #expect(ClockTurn.wait(for: nil, builtAt: october30(8)) == nil)
    }

    /// A change at or before the build is in the model already. Waiting for
    /// it would turn the clock over and over, for a model that names its own
    /// moment on every build too.
    @Test func aChangeNotAfterTheBuildIsNotWaitedFor() {
        #expect(ClockTurn.wait(for: october30(8), builtAt: october30(8)) == nil)
        #expect(ClockTurn.wait(for: october30(7), builtAt: october30(8)) == nil)
    }
}
