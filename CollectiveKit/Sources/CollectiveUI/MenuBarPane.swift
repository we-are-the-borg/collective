import CollectiveKit
import SwiftUI

/// Menu Bar: when and how fast the cube moves. Nothing hides with the
/// choice, so the pane keeps its height; under Reduce Motion the choice stays visible, greyed
/// out, and applies again once it is off.
struct MenuBarPane: View {
    @Binding var menuBarAnimation: MenuBarAnimation
    let reduceMotion: Bool
    let onOpenDisplaySettings: () -> Void

    var body: some View {
        SettingsPaneScaffold(title: Text(SettingsText.menuBar), description: Text(SettingsText.menuBarDescription)) {
            if reduceMotion {
                SettingsGroup { reduceMotionNote }
            }
            SettingsGroup(header: Text(SettingsText.animateTheIcon)) {
                // A radio group rather than a popup: the sentences under the choices are there to compare.
                SettingsRadioGroup(
                    selection: $menuBarAnimation.level, options: MenuBarAnimation.Level.allCases,
                    title: Text(SettingsText.animateTheIcon), spacing: 10, alignment: .top
                ) { level in
                    SettingsLabel(Text(level.title), hint: Text(level.explanation))
                }
                .disabled(!MenuBarAnimation.canChooseLevel(reduceMotion: reduceMotion))
            }
            SettingsGroup(footnote: Text(SettingsText.menuBarFootnote)) {
                frameRateRow
                    .disabled(!menuBarAnimation.canChooseFrameRate(reduceMotion: reduceMotion))
            }
        }
    }

    private var frameRateRow: some View {
        let label = Text(SettingsText.frameRate)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                SettingsLabel(label)
                Text(menuBarAnimation.frameRateHint)
                    .font(.plexSans(12))
                    .plexLineHeight(17, size: 12)
                    .foregroundStyle(.role(.textMuted))
                    // The hints wrap differently; two fixed lines keep the row from jumping on a new choice.
                    .lineLimit(2, reservesSpace: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SettingsPopUp(
                selection: $menuBarAnimation.frameRate, label: label, value: Text(menuBarAnimation.frameRate.optionText)
            ) {
                ForEach(MenuBarAnimation.FrameRate.allCases, id: \.self) { rate in
                    Text(rate.optionText).tag(rate)
                }
            }
        }
        .settingsRowInsets()
        .frame(minHeight: 56)
    }

    private var reduceMotionNote: some View {
        HStack(alignment: .top, spacing: 10) {
            LucideImage(.accessibility, size: 16)
                .foregroundStyle(.role(.accent))
                // On the title's first line (18.2 high).
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(SettingsText.reduceMotionIsOn)
                    .font(.plexSans(13, weight: .semibold))
                    .plexLineHeight(18.2, size: 13)
                    .foregroundStyle(.role(.text))
                Text(SettingsText.reduceMotionNote)
                    .font(.plexSans(12))
                    .plexLineHeight(17, size: 12)
                    .foregroundStyle(.role(.textMuted))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onOpenDisplaySettings) { Text(SettingsText.openDisplaySettings) }
                .buttonStyle(.settings)
        }
        .settingsRowInsets()
    }
}

#if DEBUG
private struct MenuBarPanePreview: View {
    let reduceMotion: Bool
    @State var animation = MenuBarAnimation()

    var body: some View {
        MenuBarPane(menuBarAnimation: $animation, reduceMotion: reduceMotion, onOpenDisplaySettings: {})
            .frame(width: 460, height: 608)
            .background(.role(.surface))
            .tracksKeyboardUse()
    }
}

#Preview("Menu Bar – Catppuccin Latte") {
    MenuBarPanePreview(reduceMotion: false).themeSelection(light: "catppuccin-latte")
}
#Preview("Menu Bar – Catppuccin Macchiato") {
    MenuBarPanePreview(reduceMotion: false).themeSelection(dark: "catppuccin-macchiato").preferredColorScheme(.dark)
}
#Preview("Menu Bar – Reduce Motion, Latte") {
    MenuBarPanePreview(reduceMotion: true).themeSelection(light: "catppuccin-latte")
}
#Preview("Menu Bar – Reduce Motion, Macchiato") {
    MenuBarPanePreview(reduceMotion: true).themeSelection(dark: "catppuccin-macchiato").preferredColorScheme(.dark)
}
#Preview("Menu Bar – Never, Latte") {
    MenuBarPanePreview(reduceMotion: false, animation: MenuBarAnimation(level: .never)).themeSelection(light: "catppuccin-latte")
}
#endif
