import CoreGraphics

/// Where the popover panel goes under the status item. The panel is a plain
/// window, so unlike `MenuBarExtra` the app has to place it; this keeps the
/// math free of AppKit. All frames are in AppKit screen coordinates (origin
/// bottom-left, y up).
public enum PopoverPlacement {
    /// Space between the menu bar and the panel's top edge. Tuned at the visual check.
    public static let gap: CGFloat = 4
    /// Minimum distance from the visible frame's edges.
    public static let margin: CGFloat = 8

    /// - Parameters:
    ///   - iconFrame: the status item button's frame on screen.
    ///   - contentSize: the SwiftUI content's fitting size.
    ///   - visibleFrame: the visible frame of the screen that holds the icon. The
    ///     menu bar lies outside it, so the icon normally sits above its top edge.
    public static func frame(iconFrame: CGRect, contentSize: CGSize, visibleFrame: CGRect) -> CGRect {
        let top = min(iconFrame.minY, visibleFrame.maxY) - gap
        let height = max(0, min(contentSize.height, top - visibleFrame.minY - margin))
        let width = contentSize.width
        // Wider than the screen allows: the lower bound wins, so the panel starts at the left margin.
        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - margin - width
        let x = max(minX, min(iconFrame.midX - width / 2, maxX))
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}
