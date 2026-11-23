import Testing
@testable import CollectiveUI

/// The working halo stands still (its pulse redrew the whole popover every frame, 40–50 %
/// CPU): radius 6.25, opacity 0.38, the dot at 3.5, the values Reduce Motion drew before.
@Suite("Status shape metrics")
struct StatusShapeMetricsTests {
    /// A working dot stands brighter than a subagent row's, so it still reads as working; the
    /// halo fits the 14 pt status column (7.0 on the 12 grid).
    @Test func theWorkingHaloStandsAboveTheSubagentHalo() {
        #expect(StatusShapeMetrics.brightHaloRadius == 6.25)
        #expect(StatusShapeMetrics.brightHaloOpacity == 0.38)
        #expect(StatusShapeMetrics.dotRadius == 3.5)
        #expect(StatusShapeMetrics.haloRadius == 5.75)
        #expect(StatusShapeMetrics.haloOpacity == 0.28)
        #expect(StatusShapeMetrics.brightHaloRadius * 2 <= 14)
    }
}
