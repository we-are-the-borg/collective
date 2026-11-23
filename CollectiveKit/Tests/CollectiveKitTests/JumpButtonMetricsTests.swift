import CoreGraphics
import Testing
@testable import CollectiveUI

/// The jump button, the row's last line.
@Suite("Jump button metrics")
struct JumpButtonMetricsTests {
    /// 22 high, 6 pt taller than the plain line the form without target keeps.
    @Test func theButtonIs22High() {
        #expect(JumpButtonMetrics.height == 22)
    }

    @Test func itsLabelSits6FromTheLeadingAnd8FromTheTrailingEdge() {
        #expect(JumpButtonMetrics.leadingInset == 6)
        #expect(JumpButtonMetrics.trailingInset == 8)
    }

    /// 7 between the target group, the pipe and the model group; 5 within a group.
    @Test func groupsSit7ApartTheirPartsFive() {
        #expect(JumpButtonMetrics.groupGap == 7)
        #expect(JumpButtonMetrics.partGap == 5)
    }

    /// Lucide symbol and tool logo at 12 pt, the texts at 11.5 pt.
    @Test func symbolAndLogoAre12PointsTheTexts11AndAHalf() {
        #expect(JumpButtonMetrics.symbolSize == 12)
        #expect(JumpButtonMetrics.logoSize == 12)
        #expect(JumpButtonMetrics.textSize == 11.5)
    }

    /// The popover's other buttons' radius.
    @Test func itsFrameHasThePopoverButtonsRadius() {
        #expect(PopoverButtonBody.radius == 5)
    }
}
