import CollectiveKit
import SwiftUI

// The controls of the settings and setup windows. Each keeps the native control's behavior
// (VoiceOver, keyboard, focus) and only draws its look from the roles; the open popup menu
// stays the system's. Radius 5, the keyboard focus a 2 px `--focus-ring` frame 1 px outside,
// for keyboard focus only. An enabled control's outline is `--border-control` (3:1 against the
// surfaces), a disabled one `--border`; what `--accent` fills turns `--accent-hover` when hovered
// and `--accent-active` when pressed.

enum SettingsControlMetrics {
    static let radius: CGFloat = 5
    static let buttonHeight: CGFloat = 24
    static let fontSize: CGFloat = 12.5
}

/// The 2 px `--focus-ring` frame 1 px outside a control of corner radius `radius`.
struct OutsideFocusRing: ViewModifier {
    let isShown: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if isShown {
                RoundedRectangle(cornerRadius: radius + 3, style: .circular)
                    .strokeBorder(.role(.focusRing), lineWidth: 2)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func outsideFocusRing(_ isShown: Bool, radius: CGFloat = SettingsControlMetrics.radius) -> some View {
        modifier(OutsideFocusRing(isShown: isShown, radius: radius))
    }
}

// MARK: Buttons

/// Button, primary button and destructive button: 24 high (Quit 28), 0/10 insets, 12.5 pt.
public struct SettingsButtonStyle: ButtonStyle {
    public enum Kind: Sendable {
        /// A 1 px `--border-control` frame without a fill, like "Show n idle" in the popover.
        case normal
        /// `--accent` with `--accent-on` text, weight 500.
        case primary
        /// A `--danger` outline. A building block nothing uses yet: "Clear…" is a normal button.
        case destructive
    }

    var kind: Kind
    var height: CGFloat
    var fillsWidth: Bool

    public init(_ kind: Kind = .normal, height: CGFloat = 24, fillsWidth: Bool = false) {
        self.kind = kind
        self.height = height
        self.fillsWidth = fillsWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        SettingsButtonBody(configuration: configuration, kind: kind, height: height, fillsWidth: fillsWidth)
    }
}

extension ButtonStyle where Self == SettingsButtonStyle {
    public static var settings: SettingsButtonStyle { SettingsButtonStyle() }
    public static var settingsPrimary: SettingsButtonStyle { SettingsButtonStyle(.primary) }
    public static var settingsDestructive: SettingsButtonStyle { SettingsButtonStyle(.destructive) }
}

/// A view rather than the style's body, so it can hold the hover and read the focus.
struct SettingsButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.showsButtonFocusRing) private var showsFocusRing
    @State private var isHovered = false
    let configuration: ButtonStyleConfiguration
    let kind: SettingsButtonStyle.Kind
    let height: CGFloat
    let fillsWidth: Bool

    struct Roles: Equatable {
        var text: ThemeRole
        var border: ThemeRole
        var fill: ThemeRole?
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsControlMetrics.radius, style: .circular)
        let roles = Self.roles(kind: kind, isEnabled: isEnabled, isPressed: configuration.isPressed, isHovered: isHovered)
        configuration.label
            .font(.plexSans(SettingsControlMetrics.fontSize, weight: kind == .primary ? .medium : .regular))
            .foregroundStyle(.role(roles.text))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: height)
            .background(roles.fill.map { AnyShapeStyle(.role($0)) } ?? AnyShapeStyle(.clear), in: shape)
            .overlay { shape.strokeBorder(.role(roles.border), lineWidth: 1) }
            .outsideFocusRing(showsFocusRing)
            .contentShape(shape)
            .focusEffectDisabled()
            .onHover { isHovered = $0 }
    }

    nonisolated static func roles(kind: SettingsButtonStyle.Kind, isEnabled: Bool, isPressed: Bool, isHovered: Bool) -> Roles {
        guard isEnabled else {
            return Roles(text: .textDisabled, border: .border, fill: kind == .primary ? .surfaceRaised : nil)
        }
        switch kind {
        case .primary:
            let accent = accentRole(isPressed: isPressed, isHovered: isHovered)
            return Roles(text: .accentOn, border: accent, fill: accent)
        case .normal, .destructive:
            let fill: ThemeRole? = isPressed ? .surfaceActive : isHovered ? .surfaceHover : nil
            return Roles(text: kind == .normal ? .text : .danger, border: kind == .normal ? .borderControl : .danger, fill: fill)
        }
    }
}

/// What `--accent` fills, by state: the primary button, the switch on, the selected radio.
nonisolated private func accentRole(isPressed: Bool, isHovered: Bool) -> ThemeRole {
    isPressed ? .accentActive : isHovered ? .accentHover : .accent
}

// MARK: Link

/// A link in `--accent`, underlined on hover, `--text-disabled` when disabled; its focus frame
/// has radius 3. For `Link` and for buttons that act like one.
public struct SettingsLinkStyle: ButtonStyle {
    var size: CGFloat

    public init(size: CGFloat = 12.5) {
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        SettingsLinkBody(configuration: configuration, size: size)
    }
}

extension ButtonStyle where Self == SettingsLinkStyle {
    public static var settingsLink: SettingsLinkStyle { SettingsLinkStyle() }
}

private struct SettingsLinkBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.showsButtonFocusRing) private var showsFocusRing
    @State private var isHovered = false
    let configuration: ButtonStyleConfiguration
    let size: CGFloat

    var body: some View {
        configuration.label
            .font(.plexSans(size))
            .foregroundStyle(.role(isEnabled ? .accent : .textDisabled))
            .underline(isEnabled && isHovered)
            .outsideFocusRing(showsFocusRing, radius: 3)
            .contentShape(Rectangle())
            .focusEffectDisabled()
            .onHover { isHovered = $0 }
    }
}

// MARK: Switch

/// The square switch: a 30 × 18 track, radius 5, with a 12 pt knob, radius 3. The label
/// takes the row's width, the switch sits at its end. The track is a button, so it takes the
/// keyboard focus where the system's switch does; VoiceOver gets the system's switch.
public struct SettingsSwitchStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { configuration.isOn.toggle() } label: { EmptyView() }
                .buttonStyle(SwitchTrackStyle(isOn: configuration.isOn))
        }
        .accessibilityRepresentation {
            // `.switch` here: the inherited style is this one, which would describe itself again.
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

extension ToggleStyle where Self == SettingsSwitchStyle {
    public static var settingsSwitch: SettingsSwitchStyle { SettingsSwitchStyle() }
}

private struct SwitchTrackStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        SwitchTrack(isOn: isOn, isPressed: configuration.isPressed)
    }
}

struct SwitchTrack: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.showsButtonFocusRing) private var showsFocusRing
    @State private var isHovered = false
    let isOn: Bool
    let isPressed: Bool

    static let size = CGSize(width: 30, height: 18)
    static let knob: CGFloat = 12
    /// The knob's distance from the track's outer edge: 1 px frame plus 2.
    static let knobInset: CGFloat = 3

    var body: some View {
        let track = RoundedRectangle(cornerRadius: SettingsControlMetrics.radius, style: .circular)
        let roles = Self.roles(isEnabled: isEnabled, isOn: isOn, isPressed: isPressed, isHovered: isHovered)
        ZStack(alignment: isOn ? .trailing : .leading) {
            track.fill(roles.fill.map { AnyShapeStyle(.role($0)) } ?? AnyShapeStyle(.clear))
            track.strokeBorder(.role(roles.border), lineWidth: 1)
            RoundedRectangle(cornerRadius: 3, style: .circular)
                .fill(.role(roles.knob))
                .frame(width: Self.knob, height: Self.knob)
                .padding(.horizontal, Self.knobInset)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .outsideFocusRing(showsFocusRing)
        .contentShape(track)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
    }

    struct Roles: Equatable {
        var border: ThemeRole
        var fill: ThemeRole?
        var knob: ThemeRole
    }

    /// The design's table of switch states.
    nonisolated static func roles(isEnabled: Bool, isOn: Bool, isPressed: Bool, isHovered: Bool) -> Roles {
        switch (isEnabled, isOn) {
        case (true, true):
            let accent = accentRole(isPressed: isPressed, isHovered: isHovered)
            return Roles(border: accent, fill: accent, knob: .accentOn)
        case (true, false):
            return Roles(
                border: .borderControl, fill: isPressed ? .surfaceActive : isHovered ? .surfaceHover : .surfaceRaised,
                knob: isPressed ? .text : .textMuted
            )
        case (false, true): return Roles(border: .borderStrong, fill: .borderStrong, knob: .surface)
        case (false, false): return Roles(border: .border, fill: nil, knob: .textDisabled)
        }
    }
}

// MARK: Radio

/// One radio button of a group: the round 16 pt mark, then the label. Selected is `--accent`
/// with a 6 pt `--accent-on` dot; the group reads as a radio group to VoiceOver and moves its
/// choice with the arrow keys (`SettingsRadioGroup`).
public struct SettingsRadioStyle: ButtonStyle {
    var isSelected: Bool
    var spacing: CGFloat
    var alignment: VerticalAlignment
    /// Set by a group, which takes the focus in the button's stead; nil: the button's own focus.
    var showsFocusRing: Bool?

    /// - Parameters:
    ///   - spacing: Between the mark and the label: 8, or 10 next to a title and a sentence.
    ///   - alignment: `.top` puts the mark on the label's first line.
    public init(isSelected: Bool, spacing: CGFloat = 8, alignment: VerticalAlignment = .center) {
        self.isSelected = isSelected
        self.spacing = spacing
        self.alignment = alignment
    }

    init(isSelected: Bool, spacing: CGFloat, alignment: VerticalAlignment, showsFocusRing: Bool) {
        self.init(isSelected: isSelected, spacing: spacing, alignment: alignment)
        self.showsFocusRing = showsFocusRing
    }

    public func makeBody(configuration: Configuration) -> some View {
        SettingsRadioBody(
            configuration: configuration, isSelected: isSelected, spacing: spacing, alignment: alignment,
            groupFocusRing: showsFocusRing
        )
    }
}

struct SettingsRadioBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.showsButtonFocusRing) private var showsButtonFocusRing
    @State private var isHovered = false
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    let spacing: CGFloat
    let alignment: VerticalAlignment
    let groupFocusRing: Bool?

    private var showsFocusRing: Bool { groupFocusRing ?? showsButtonFocusRing }

    static let size: CGFloat = 16
    static let dot: CGFloat = 6

    var body: some View {
        HStack(alignment: alignment, spacing: spacing) {
            mark
                .outsideFocusRing(showsFocusRing, radius: Self.size / 2)
                // On the first line of a 13 pt label (18.2 high) rather than its top.
                .padding(.top, alignment == .top ? 1 : 0)
            configuration.label
                .foregroundStyle(.role(isEnabled ? .text : .textDisabled))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
    }

    private var mark: some View {
        let roles = Self.markRoles(
            isSelected: isSelected, isEnabled: isEnabled, isPressed: configuration.isPressed, isHovered: isHovered
        )
        return ZStack {
            Circle().fill(roles.fill.map { AnyShapeStyle(.role($0)) } ?? AnyShapeStyle(.clear))
            if let border = roles.border {
                Circle().strokeBorder(.role(border), lineWidth: 1)
            }
            if let dot = roles.dot {
                Circle().fill(.role(dot)).frame(width: Self.dot, height: Self.dot)
            }
        }
        .frame(width: Self.size, height: Self.size)
    }

    /// The mark's circle fill, its outline (unselected only) and the dot (selected only).
    struct MarkRoles: Equatable {
        var fill: ThemeRole?
        var border: ThemeRole?
        var dot: ThemeRole?
    }

    nonisolated static func markRoles(isSelected: Bool, isEnabled: Bool, isPressed: Bool, isHovered: Bool) -> MarkRoles {
        switch (isSelected, isEnabled) {
        case (true, true): MarkRoles(fill: accentRole(isPressed: isPressed, isHovered: isHovered), dot: .accentOn)
        case (true, false): MarkRoles(fill: .borderStrong, dot: .surface)
        case (false, true):
            MarkRoles(fill: isPressed ? .surfaceActive : isHovered ? .surfaceHover : .surfaceRaised, border: .borderControl)
        case (false, false): MarkRoles(border: .border)
        }
    }
}

/// A radio group of `options`, one per row of a group box with 1 px `--border` between them.
/// Like a macOS radio group: one Tab stop for the whole group, where the
/// system's radio buttons take the focus (keyboard navigation on); ↑ ↓ and ← → move the choice
/// and apply it, stopping at the ends; the ring sits on the chosen option, for keyboard use
/// only. VoiceOver gets the system's radio group.
public struct SettingsRadioGroup<Value: Hashable, Label: View>: View {
    @Binding private var selection: Value
    private let options: [Value]
    private let title: Text
    private let spacing: CGFloat
    private let alignment: VerticalAlignment
    private let label: (Value) -> Label
    @FocusState private var isFocused: Bool
    @Environment(\.isKeyboardFocusVisible) private var isKeyboardFocusVisible

    /// - Parameters:
    ///   - title: What VoiceOver calls the group; the group header shows it.
    public init(
        selection: Binding<Value>, options: [Value], title: Text,
        spacing: CGFloat = 8, alignment: VerticalAlignment = .center,
        @ViewBuilder label: @escaping (Value) -> Label
    ) {
        _selection = selection
        self.options = options
        self.title = title
        self.spacing = spacing
        self.alignment = alignment
        self.label = label
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element) { index, option in
                if index > 0 { SettingsDivider() }
                Button { selection = option } label: { label(option) }
                    .buttonStyle(SettingsRadioStyle(
                        isSelected: option == selection, spacing: spacing, alignment: alignment,
                        showsFocusRing: option == selection && isFocused && isKeyboardFocusVisible
                    ))
                    // The group is the Tab stop, not each option.
                    .focusable(false)
                    .settingsRowInsets()
            }
        }
        // `.activate`: a Tab stop only with keyboard navigation on, like the system's.
        .focusable(interactions: .activate)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .leftArrow, .downArrow, .rightArrow]) { press in
            move(by: press.key == .upArrow || press.key == .leftArrow ? -1 : 1)
        }
        .accessibilityRepresentation {
            Picker(selection: $selection) {
                ForEach(options, id: \.self) { option in label(option).tag(option) }
            } label: { title }
                .pickerStyle(.radioGroup)
                // Shown, the label is a text of its own beside an unnamed group; hidden, it names the group.
                .labelsHidden()
        }
    }

    private func move(by offset: Int) -> KeyPress.Result {
        guard let next = options.arrowKeyStep(from: selection, by: offset) else { return .ignored }
        selection = next
        return .handled
    }
}

// MARK: Popup button

/// A popup button's closed state: the value with Lucide `chevron-down` on `--surface-raised`.
/// It opens the system's menu with the options, which marks the current one;
/// VoiceOver gets a pop-up button with the label and the value, and the keyboard opens it where
/// the system's popup takes the focus. SwiftUI does not tell a menu's label that its menu is
/// open (`isPressed` stays false, even while the mouse is down), so the open button looks like
/// the closed one rather than pressed.
public struct SettingsPopUp<Value: Hashable, Options: View>: View {
    @Binding private var selection: Value
    private let label: Text
    private let value: Text
    private let options: Options

    /// - Parameters:
    ///   - label: The row's label, for VoiceOver; the row shows it.
    ///   - value: The current option's text.
    ///   - options: The menu's items, each tagged with its value; a `Divider` separates.
    public init(selection: Binding<Value>, label: Text, value: Text, @ViewBuilder options: () -> Options) {
        _selection = selection
        self.label = label
        self.value = value
        self.options = options()
    }

    public var body: some View {
        Menu {
            Picker(selection: $selection) { options } label: { label }
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            value
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(SettingsPopUpStyle())
        .fixedSize()
        // A pop-up button with its label and value, not a menu button, like the system's.
        .accessibilityRepresentation {
            Picker(selection: $selection) { options } label: { label }
                .pickerStyle(.menu)
        }
    }
}

private struct SettingsPopUpStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsPopUpBody(configuration: configuration)
    }
}

struct SettingsPopUpBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.showsButtonFocusRing) private var showsFocusRing
    @State private var isHovered = false
    let configuration: ButtonStyleConfiguration

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsControlMetrics.radius, style: .circular)
        let roles = Self.roles(isEnabled: isEnabled, isPressed: configuration.isPressed, isHovered: isHovered)
        HStack(spacing: 8) {
            configuration.label
                .font(.plexSans(SettingsControlMetrics.fontSize))
                .foregroundStyle(.role(isEnabled ? .text : .textDisabled))
                .lineLimit(1)
            LucideImage(.chevronDown, size: 12)
                .foregroundStyle(.role(!isEnabled ? .textDisabled : configuration.isPressed ? .text : .textMuted))
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: SettingsControlMetrics.buttonHeight)
        .background(roles.fill.map { AnyShapeStyle(.role($0)) } ?? AnyShapeStyle(.clear), in: shape)
        .overlay { shape.strokeBorder(.role(roles.border), lineWidth: 1) }
        .outsideFocusRing(showsFocusRing)
        .contentShape(shape)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
    }

    struct Roles: Equatable {
        var border: ThemeRole
        var fill: ThemeRole?
    }

    /// Hover and pressed show in the fill only; the outline stays.
    nonisolated static func roles(isEnabled: Bool, isPressed: Bool, isHovered: Bool) -> Roles {
        guard isEnabled else { return Roles(border: .border, fill: nil) }
        return Roles(border: .borderControl, fill: isPressed ? .surfaceActive : isHovered ? .surfaceHover : .surfaceRaised)
    }
}

#if DEBUG
/// Every control in its states, like the design's overview of controls; hover, pressed and focus show
/// when used.
private struct SettingsControlsPreview: View {
    @State private var on = true
    @State private var off = false
    @State private var level = 0
    @State private var minutes = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: $on) { Text(verbatim: "Switch on") }.toggleStyle(.settingsSwitch)
            Toggle(isOn: $off) { Text(verbatim: "Switch off") }.toggleStyle(.settingsSwitch)
            Toggle(isOn: .constant(true)) { Text(verbatim: "Disabled, on") }.toggleStyle(.settingsSwitch).disabled(true)
            Toggle(isOn: .constant(false)) { Text(verbatim: "Disabled, off") }.toggleStyle(.settingsSwitch).disabled(true)
            SettingsGroup {
                SettingsRadioGroup(selection: $level, options: [0, 1, 2], title: Text(verbatim: "Radio")) { option in
                    Text(verbatim: ["Always", "Only when an agent needs me", "Never"][option])
                }
            }
            SettingsRadioGroup(selection: .constant(0), options: [0, 1], title: Text(verbatim: "Disabled radio")) { option in
                Text(verbatim: ["Always", "Never"][option])
            }
            .disabled(true)
            HStack(spacing: 12) {
                SettingsPopUp(selection: $minutes, label: Text(verbatim: "Keep"), value: Text(verbatim: "\(minutes) minutes")) {
                    ForEach([5, 10, 30], id: \.self) { Text(verbatim: "\($0) minutes").tag($0) }
                }
                SettingsPopUp(selection: .constant(12), label: Text(verbatim: "Frame rate"), value: Text(verbatim: "Smooth (12 fps)")) {
                    Text(verbatim: "Smooth (12 fps)").tag(12)
                }
                .disabled(true)
            }
            HStack(spacing: 12) {
                Button {} label: { Text(verbatim: "Choose…") }.buttonStyle(.settings)
                Button {} label: { Text(verbatim: "Reset") }.buttonStyle(.settings).disabled(true)
                Button {} label: { Text(verbatim: "Set Up…") }.buttonStyle(.settingsPrimary)
                Button {} label: { Text(verbatim: "Install") }.buttonStyle(.settingsPrimary).disabled(true)
                Button {} label: { Text(verbatim: "Clear…") }.buttonStyle(.settingsDestructive)
            }
            HStack(spacing: 18) {
                Button {} label: { Text(verbatim: "Open System Settings…") }.buttonStyle(.settingsLink)
                Button {} label: { Text(verbatim: "View changes on GitHub ↗") }.buttonStyle(.settingsLink).disabled(true)
            }
        }
        .font(.plexSans(13))
        .foregroundStyle(.role(.text))
        .padding(24)
        .frame(width: 460)
        .background(.role(.surface))
        .tracksKeyboardUse()
    }
}

#Preview("Controls") { SettingsControlsPreview() }
#Preview("Controls, dark") { SettingsControlsPreview().preferredColorScheme(.dark) }
#Preview("Controls, GitHub Light") { SettingsControlsPreview().themeSelection(light: "github") }
#endif
