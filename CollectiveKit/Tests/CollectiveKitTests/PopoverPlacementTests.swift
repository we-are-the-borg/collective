import CoreGraphics
import Testing
@testable import CollectiveKit

@Suite struct PopoverPlacementTests {
    /// A 1440x900 screen whose menu bar (24 pt) lies above the visible frame.
    let main = CGRect(x: 0, y: 0, width: 1440, height: 876)
    let size = CGSize(width: 380, height: 500)

    /// A status item button as the menu bar places it: its top is the screen's top,
    /// which is above `visibleFrame.maxY`.
    func icon(midX: CGFloat, in visible: CGRect) -> CGRect {
        CGRect(x: midX - 11, y: visible.maxY, width: 22, height: 24)
    }

    @Test func iconInTheMiddleCentersThePanelUnderIt() {
        let frame = PopoverPlacement.frame(iconFrame: icon(midX: 700, in: main), contentSize: size, visibleFrame: main)
        #expect(frame.midX == 700)
        #expect(frame.width == 380)
        #expect(frame.height == 500)
        #expect(frame.maxY == main.maxY - PopoverPlacement.gap)
    }

    @Test func iconNearTheRightEdgeKeepsThePanelInsideTheMargin() {
        let frame = PopoverPlacement.frame(iconFrame: icon(midX: 1430, in: main), contentSize: size, visibleFrame: main)
        #expect(frame.maxX == main.maxX - PopoverPlacement.margin)
        #expect(frame.width == 380)
    }

    @Test func iconNearTheLeftEdgeKeepsThePanelInsideTheMargin() {
        let frame = PopoverPlacement.frame(iconFrame: icon(midX: 20, in: main), contentSize: size, visibleFrame: main)
        #expect(frame.minX == main.minX + PopoverPlacement.margin)
        #expect(frame.width == 380)
    }

    @Test func contentTallerThanTheRoomBelowTheIconIsCappedAndKeepsItsTop() {
        let tall = CGSize(width: 380, height: 2000)
        let frame = PopoverPlacement.frame(iconFrame: icon(midX: 700, in: main), contentSize: tall, visibleFrame: main)
        #expect(frame.maxY == main.maxY - PopoverPlacement.gap)
        #expect(frame.minY == main.minY + PopoverPlacement.margin)
    }

    /// The math must not assume the screen starts at the origin.
    @Test(arguments: [
        CGRect(x: -1920, y: 0, width: 1920, height: 1055),
        CGRect(x: 0, y: 900, width: 1440, height: 1055),
        CGRect(x: -1920, y: -300, width: 1920, height: 1055),
    ])
    func screensAwayFromTheOriginPlaceTheSameWay(visible: CGRect) {
        let middle = visible.midX
        let centered = PopoverPlacement.frame(iconFrame: icon(midX: middle, in: visible), contentSize: size, visibleFrame: visible)
        #expect(centered.midX == middle)
        #expect(centered.maxY == visible.maxY - PopoverPlacement.gap)
        #expect(centered.height == 500)

        let right = PopoverPlacement.frame(iconFrame: icon(midX: visible.maxX - 5, in: visible), contentSize: size, visibleFrame: visible)
        #expect(right.maxX == visible.maxX - PopoverPlacement.margin)
        let left = PopoverPlacement.frame(iconFrame: icon(midX: visible.minX + 5, in: visible), contentSize: size, visibleFrame: visible)
        #expect(left.minX == visible.minX + PopoverPlacement.margin)
    }

    @Test func iconAboveTheVisibleFrameHangsTheTopBelowTheVisibleFrame() {
        let high = CGRect(x: 689, y: 5000, width: 22, height: 24)
        let frame = PopoverPlacement.frame(iconFrame: high, contentSize: size, visibleFrame: main)
        #expect(frame.maxY == main.maxY - PopoverPlacement.gap)
    }

    /// A button inside the visible frame (a menu bar at the bottom or hidden) wins over its top edge.
    @Test func iconInsideTheVisibleFrameHangsTheTopBelowTheIcon() {
        let inside = CGRect(x: 689, y: 700, width: 22, height: 24)
        let frame = PopoverPlacement.frame(iconFrame: inside, contentSize: size, visibleFrame: main)
        #expect(frame.maxY == 700 - PopoverPlacement.gap)
    }

    @Test func contentWiderThanTheScreenAlignsToTheLeftMargin() {
        let wide = CGSize(width: 2000, height: 300)
        let frame = PopoverPlacement.frame(iconFrame: icon(midX: 700, in: main), contentSize: wide, visibleFrame: main)
        #expect(frame.minX == main.minX + PopoverPlacement.margin)
        #expect(frame.width == 2000)
    }

    @Test func noRoomLeftGivesAnEmptyHeightNeverANegativeOne() {
        let flat = CGRect(x: 0, y: 0, width: 1440, height: 10)
        let frame = PopoverPlacement.frame(iconFrame: icon(midX: 700, in: flat), contentSize: size, visibleFrame: flat)
        #expect(frame.height == 0)
    }
}
