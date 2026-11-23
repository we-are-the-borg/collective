import Testing
@testable import CollectiveKit

/// ↑ ↓ (and ← →) in the settings' sidebar and radio groups, like their macOS counterparts.
@Suite struct ArrowKeyStepTests {
    let options = ["a", "b", "c"]

    @Test func oneStepEitherWay() {
        #expect(options.arrowKeyStep(from: "a", by: 1) == "b")
        #expect(options.arrowKeyStep(from: "c", by: -1) == "b")
    }

    /// No wrapping around: the system's lists and radio groups stay on the last one.
    @Test func stopsAtEitherEnd() {
        #expect(options.arrowKeyStep(from: "a", by: -1) == "a")
        #expect(options.arrowKeyStep(from: "c", by: 1) == "c")
    }

    @Test func nothingForAnElementNotListed() {
        #expect(options.arrowKeyStep(from: "z", by: 1) == nil)
        #expect([String]().arrowKeyStep(from: "a", by: 1) == nil)
    }
}
