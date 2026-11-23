import Testing
import Foundation
@testable import CollectiveKit

@Suite struct ProcessStartTimeTests {
    @Test func ownProcessStartedBetweenBootAndNow() throws {
        let now = Date()
        let started = try #require(ProcessStartTime.of(getpid()))
        let boot = now.addingTimeInterval(-ProcessInfo.processInfo.systemUptime - 1)
        #expect(started <= now)
        #expect(started >= boot)
    }

    @Test func missingOrInvalidPidIsNil() {
        #expect(ProcessStartTime.of(Int32.max) == nil)
        #expect(ProcessStartTime.of(0) == nil)
        #expect(ProcessStartTime.of(-1) == nil)
    }

    @Test func freshChildStartsAfterTestBegan() throws {
        let before = Date().addingTimeInterval(-1)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate() }

        let started = try #require(ProcessStartTime.of(child.processIdentifier))
        #expect(started >= before)
        #expect(abs(started.timeIntervalSinceNow) < 5)
    }
}
