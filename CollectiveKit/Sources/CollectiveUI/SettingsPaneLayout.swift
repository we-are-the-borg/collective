import CollectiveKit
import SwiftUI

// The panes' building blocks: heading with its description, square group boxes with rows,
// group headers and footnotes.

extension View {
    /// A group row's 10/14 insets.
    func settingsRowInsets() -> some View {
        padding(.vertical, 10).padding(.horizontal, 14)
    }
}

/// A pane: its name 18/24 semibold, the description 12.5/18 in `--text-muted`, then the groups
/// 22 apart, all 24 from the edges; scrolls when the window is shorter.
struct SettingsPaneScaffold<Content: View>: View {
    private let title: Text
    private let description: Text
    private let descriptionSpacing: CGFloat
    private let content: Content

    /// - Parameter descriptionSpacing: Below the description: 20, Appearance 18.
    init(title: Text, description: Text, descriptionSpacing: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.title = title
        self.description = description
        self.descriptionSpacing = descriptionSpacing
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                title
                    .font(.plexSans(18, weight: .semibold))
                    .plexLineHeight(24, size: 18)
                    .foregroundStyle(.role(.text))
                    .accessibilityAddTraits(.isHeader)
                description
                    .font(.plexSans(12.5))
                    .plexLineHeight(18, size: 12.5)
                    .foregroundStyle(.role(.textMuted))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    .padding(.bottom, descriptionSpacing)
                VStack(alignment: .leading, spacing: 22) { content }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.plexSans(13))
        .foregroundStyle(.role(.text))
    }
}

/// A square box with a 1 px `--border`, its rows split by 1 px lines; an optional header
/// 13/18 semibold 8 above and footnote 12/17 `--text-subtle` 8 below.
struct SettingsGroup<Content: View>: View {
    private let header: Text?
    private let footnote: Text?
    private let content: Content

    init(header: Text? = nil, footnote: Text? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                header
                    .font(.plexSans(13, weight: .semibold))
                    .plexLineHeight(18, size: 13)
                    .foregroundStyle(.role(.text))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 8)
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { SettingsDivider() }
                        row
                    }
                }
            }
            // Inside the frame, as the design's CSS border is outside the content.
            .padding(1)
            .overlay { Rectangle().strokeBorder(.role(.border), lineWidth: 1) }
            if let footnote {
                footnote
                    .font(.plexSans(12))
                    .plexLineHeight(17, size: 12)
                    .foregroundStyle(.role(.textSubtle))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
    }
}

/// The 1 px `--border` line between a group's rows.
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(.role(.border)).frame(height: 1)
    }
}

/// A row's label, 13 `--text` (`--text-disabled` when disabled), with an optional hint
/// 12/17 `--text-muted` 2 below.
struct SettingsLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    private let title: Text
    private let hint: Text?

    init(_ title: Text, hint: Text? = nil) {
        self.title = title
        self.hint = hint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
                .font(.plexSans(13))
                .plexLineHeight(18.2, size: 13)
                .foregroundStyle(.role(isEnabled ? .text : .textDisabled))
            if let hint {
                hint
                    .font(.plexSans(12))
                    .plexLineHeight(17, size: 12)
                    .foregroundStyle(.role(.textMuted))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A group row with a switch: 44 high, 56 with a hint.
struct SettingsToggleRow: View {
    @Binding var isOn: Bool
    let title: Text
    var hint: Text?

    var body: some View {
        Toggle(isOn: $isOn) { SettingsLabel(title, hint: hint) }
            .toggleStyle(.settingsSwitch)
            .settingsRowInsets()
            .frame(minHeight: hint == nil ? 44 : 56)
    }
}
