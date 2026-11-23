import CollectiveKit
import SwiftUI

// The popover's two buttons, radius 5 and without a fill like in Unimatrix: hover
// `--surface-hover`, pressed `--surface-active`. The keyboard focus is a 2 px
// `--focus-ring` frame 1 px outside, as everywhere in the family.

/// "Show n idle", the warning block's buttons, the row's "⋯" menu button and jump button: a 1 px `--border-control` frame
/// (`--border` when disabled), the label in `--text`. Height and insets stay with the caller,
/// as they differ per button.
public struct PopoverBorderedButtonStyle: ButtonStyle {
    static let frame: ThemeRole? = .borderControl

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PopoverButtonBody(configuration: configuration, frame: Self.frame)
    }
}

/// Icon buttons such as Settings in the title bar; the caller sizes the frame and colors the icon.
public struct PopoverIconButtonStyle: ButtonStyle {
    private var restingFill: ThemeRole?
    private var framed = false

    public init() {}

    /// A fill that stays while the pointer is away, such as the selected tab's
    /// `--surface-raised`; pressed still shows `--surface-active`. `framed` adds the
    /// 1 px `--border` frame, which the fill alone does not carry in light schemes; it marks
    /// the selection rather than outlining a control, so it is not `--border-control`.
    init(restingFill: ThemeRole?, framed: Bool = false) {
        self.restingFill = restingFill
        self.framed = framed
    }

    var frame: ThemeRole? { framed ? .border : nil }

    public func makeBody(configuration: Configuration) -> some View {
        PopoverButtonBody(configuration: configuration, frame: frame, restingFill: restingFill)
    }
}

extension ButtonStyle where Self == PopoverBorderedButtonStyle {
    public static var popoverBordered: PopoverBorderedButtonStyle { PopoverBorderedButtonStyle() }
}

extension ButtonStyle where Self == PopoverIconButtonStyle {
    public static var popoverIcon: PopoverIconButtonStyle { PopoverIconButtonStyle() }
}

/// A view rather than the style's body, so it can hold the hover and read the focus.
struct PopoverButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.showsButtonFocusRing) private var showsFocusRing
    @State private var isHovered = false
    let configuration: ButtonStyleConfiguration
    let frame: ThemeRole?
    var restingFill: ThemeRole?

    static let radius: CGFloat = 5

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .circular)
        configuration.label
            .foregroundStyle(.role(isEnabled ? .text : .textDisabled))
            .background(fill.map { AnyShapeStyle(.role($0)) } ?? AnyShapeStyle(.clear), in: shape)
            .overlay {
                if let frame = Self.frameRole(frame, isEnabled: isEnabled) {
                    shape.strokeBorder(.role(frame), lineWidth: 1)
                }
            }
            .overlay {
                if showsFocusRing {
                    RoundedRectangle(cornerRadius: Self.radius + 3, style: .circular)
                        .strokeBorder(.role(.focusRing), lineWidth: 2)
                        .padding(-3)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
            .focusEffectDisabled()
            .onHover { isHovered = $0 }
    }

    /// A disabled button's frame is `--border`, whatever its style draws when enabled.
    nonisolated static func frameRole(_ frame: ThemeRole?, isEnabled: Bool) -> ThemeRole? {
        frame.map { isEnabled ? $0 : .border }
    }

    private var fill: ThemeRole? {
        guard isEnabled else { return nil }
        if configuration.isPressed { return .surfaceActive }
        return restingFill ?? (isHovered ? .surfaceHover : nil)
    }
}
