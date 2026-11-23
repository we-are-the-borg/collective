import SwiftUI

/// The Lucide icons bundled in `Resources/Lucide.xcassets` (lucide-static 1.72.0), named as in
/// Lucide.
public enum LucideIcon: String, CaseIterable, Sendable {
    case chevronRight = "chevron-right"
    case chevronDown = "chevron-down"
    case chevronUp = "chevron-up"
    case terminal
    case appWindow = "app-window"
    case ellipsis
    case messageSquareText = "message-square-text"
    case settings
    case panelTop = "panel-top"
    case circleAlert = "circle-alert"
    case circleCheck = "circle-check"
    case circleArrowUp = "circle-arrow-up"
    case circleX = "circle-x"
    case info
    case history
    case bell
    case accessibility
    case palette
    case check
    case search
    case x
    case triangleAlert = "triangle-alert"
}

/// A Lucide icon `size` points square, drawn as a template in the current foreground style,
/// so `.foregroundStyle(.role(.textMuted))` colors it. The stroke scales with the size, as
/// Lucide draws stroke 2 on its 24 pt grid. Hidden from VoiceOver like the other glyphs: the
/// surrounding control carries the label.
public struct LucideImage: View {
    let icon: LucideIcon
    let size: CGFloat

    public init(_ icon: LucideIcon, size: CGFloat) {
        self.icon = icon
        self.size = size
    }

    public var body: some View {
        Image(icon.rawValue, bundle: .module)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
