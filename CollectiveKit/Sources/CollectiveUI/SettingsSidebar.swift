import CollectiveKit
import SwiftUI

/// The settings window's sidebar on `--surface-panel`: the panes in `SettingsModel.panes` order,
/// the sources under their header, About pinned to the bottom, then Quit. One stop for the
/// keyboard like the list it replaces: ↑ ↓ move the selection; the ring shows on the selected
/// row once a key was pressed.
struct SettingsSidebar: View {
    let model: SettingsModel
    @Binding var selection: SettingsPane
    let onQuit: () -> Void
    @FocusState private var isFocused: Bool
    @Environment(\.isKeyboardFocusVisible) private var isKeyboardFocusVisible

    static let width: CGFloat = 200

    var body: some View {
        // 0, so the divider keeps its own 6 above and 8 below.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                // From `panes`, so the rows stand in the order ↑ ↓ walk.
                ForEach(model.panes, id: \.self) { pane in
                    if pane == firstSourcePane { sourcesHeader }
                    if pane == .about { Spacer(minLength: 0) }
                    row(pane)
                }
            }
            .focusable(interactions: .edit)
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(by: -1) }
            .onKeyPress(.downArrow) { move(by: 1) }
            .accessibilityElement(children: .contain)
            // Across the full width, through the sidebar's insets.
            Rectangle()
                .fill(.role(.border))
                .frame(height: 1)
                .padding(.horizontal, -8)
                .padding(.top, 6)
                .padding(.bottom, 8)
            // Not a pane: a plain push button under the rows, so it is not selectable.
            Button(action: onQuit) {
                Text("Quit The Collective", bundle: .module)
            }
            .buttonStyle(SettingsButtonStyle(height: 28, fillsWidth: true))
            .keyboardShortcut("q", modifiers: .command)
            .help(Text(SettingsText.quitTooltip))
        }
        .padding(8)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(.role(.surfacePanel))
        .overlay(alignment: .trailing) {
            Rectangle().fill(.role(.border)).frame(width: 1)
        }
    }

    private var firstSourcePane: SettingsPane? {
        model.panes.first { if case .source = $0 { true } else { false } }
    }

    private var sourcesHeader: some View {
        Text(SettingsText.sources)
            .font(.plexSans(11.5, weight: .semibold))
            // The design sets the `Sources` header in `--text-muted`, not `--text-subtle`.
            .foregroundStyle(.role(.textMuted))
            .padding(EdgeInsets(top: 14, leading: 8, bottom: 4, trailing: 8))
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func row(_ pane: SettingsPane) -> some View {
        if case .source(let id) = pane {
            if let source = model.sources.first(where: { $0.source == id }) { sourceRow(source) }
        } else if let item = pane.sidebarItem {
            paneRow(pane, icon: item.icon, name: item.name)
        }
    }

    /// About shows the arrow while an app update is known, like a source row.
    private func paneRow(_ pane: SettingsPane, icon: LucideIcon, name: LocalizedStringResource) -> some View {
        let isSelected = selection == pane
        return SidebarRow(
            name: Text(name),
            isSelected: isSelected,
            showsFocusRing: isSelected && isFocused && isKeyboardFocusVisible,
            select: { select(pane) }
        ) {
            LucideImage(icon, size: 16)
                .foregroundStyle(.role(isSelected ? .text : .textMuted))
        } trailing: {
            if pane == .about, model.showsAboutUpdateArrow {
                LucideImage(.circleArrowUp, size: 13)
                    .foregroundStyle(.role(.info))
                    .help(Text(SettingsText.updateAvailable))
            }
        }
        .accessibilityLabel(Text(pane == .about ? model.aboutRowAccessibilityLabel : name))
    }

    /// The status form in front instead of the tool's logo, so the names line up; an
    /// update on offer adds the arrow at the end.
    private func sourceRow(_ source: SettingsSourceModel) -> some View {
        let pane = SettingsPane.source(source.source)
        let isSelected = selection == pane
        return SidebarRow(
            name: Text(source.name),
            isSelected: isSelected,
            showsFocusRing: isSelected && isFocused && isKeyboardFocusVisible,
            select: { select(pane) }
        ) {
            SourceStatusShapeView(source.statusMark)
        } trailing: {
            if source.showsUpdateArrow {
                LucideImage(.circleArrowUp, size: 13)
                    .foregroundStyle(.role(.info))
                    .help(Text(SettingsText.updateAvailable))
            }
        }
        .accessibilityLabel(Text(source.rowAccessibilityLabel))
    }

    /// A click selects and focuses the sidebar like a click into the list did, so ↑ ↓ follow.
    private func select(_ pane: SettingsPane) {
        selection = pane
        isFocused = true
    }

    private func move(by offset: Int) -> KeyPress.Result {
        selection = model.pane(from: selection, moving: offset)
        return .handled
    }
}

/// One sidebar row: 28 high, radius 5, 0/8 insets, the 16 pt icon field 8 before the name.
/// Selected `--surface-raised`, hovered `--surface-hover`; the keyboard ring is 2 px
/// `--focus-ring` inside, like the popover's rows.
private struct SidebarRow<Leading: View, Trailing: View>: View {
    let name: Text
    let isSelected: Bool
    let showsFocusRing: Bool
    let select: () -> Void
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .circular)
        HStack(spacing: 8) {
            leading
                .frame(width: 16, height: 16)
            name
                .font(.plexSans(13))
                .foregroundStyle(.role(.text))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(fill.map { AnyShapeStyle(.role($0)) } ?? AnyShapeStyle(.clear), in: shape)
        .overlay {
            if showsFocusRing {
                shape.strokeBorder(.role(.focusRing), lineWidth: 2).allowsHitTesting(false)
            }
        }
        .contentShape(shape)
        .onTapGesture(perform: select)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }

    private var fill: ThemeRole? {
        if isSelected { return .surfaceRaised }
        return isHovered ? .surfaceHover : nil
    }
}

private extension SettingsPane {
    /// The icon and name of a pane's row; a source's row shows its status and name instead.
    var sidebarItem: (icon: LucideIcon, name: LocalizedStringResource)? {
        switch self {
        case .general: (.settings, SettingsText.general)
        case .appearance: (.palette, SettingsText.appearance)
        case .sessions: (.history, SettingsText.sessions)
        case .notifications: (.bell, SettingsText.notifications)
        case .menuBar: (.panelTop, SettingsText.menuBar)
        case .about: (.info, SettingsText.about)
        case .source: nil
        }
    }
}
