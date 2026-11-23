import CollectiveKit
import SwiftUI

/// Notifications: when, for which tools, with sound. Sources come from the registered
/// adapters, so a tool added later gets its switch, on.
/// Turned off in System Settings only the sentence changes, the switches stay usable.
struct NotificationsPane: View {
    let sources: [SettingsSourceModel]
    @Binding var notificationPreferences: NotificationPreferences
    let notificationsTurnedOff: Bool
    let onOpenNotificationSettings: () -> Void

    var body: some View {
        SettingsPaneScaffold(title: Text(SettingsText.notifications), description: Text(SettingsText.notificationsDescription)) {
            SettingsGroup(header: Text(SettingsText.notifyWhen)) {
                SettingsToggleRow(isOn: $notificationPreferences.permission, title: Text(SettingsText.notifyPermission))
                SettingsToggleRow(isOn: $notificationPreferences.question, title: Text(SettingsText.notifyQuestion))
                turnFinishedRow
            }
            if !sources.isEmpty {
                SettingsGroup(header: Text(SettingsText.notifyFor)) {
                    ForEach(sources, id: \.source) { source in
                        SettingsToggleRow(
                            isOn: Binding(
                                get: { notificationPreferences.notifies(for: source.source) },
                                set: { notificationPreferences.setNotifies($0, for: source.source) }
                            ),
                            title: Text(source.name)
                        )
                    }
                }
            }
            SettingsGroup {
                SettingsToggleRow(isOn: $notificationPreferences.sound, title: Text(SettingsText.playSound))
            }
            SettingsGroup {
                HStack(spacing: 12) {
                    Text(SettingsModel.notificationsFootnote(turnedOff: notificationsTurnedOff))
                        .font(.plexSans(13))
                        .foregroundStyle(.role(.textMuted))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // An action, not a link.
                    Button(action: onOpenNotificationSettings) { Text(SettingsText.openSystemSettings) }
                        .buttonStyle(.settings)
                }
                .settingsRowInsets()
                .frame(minHeight: 44)
            }
        }
    }

    private var turnFinishedRow: some View {
        let label = Text(SettingsText.notifyTurnFinished)
        return HStack(spacing: 12) {
            SettingsLabel(label)
                .frame(maxWidth: .infinity, alignment: .leading)
            SettingsPopUp(
                selection: $notificationPreferences.turnFinishedAfter, label: label,
                value: Text(notificationPreferences.turnFinishedAfter.optionText)
            ) {
                ForEach(SettingsModel.turnFinishedOptions.filter { $0 != .never }, id: \.self) { option in
                    Text(option.optionText).tag(option)
                }
                Divider()
                Text(TurnFinishedAfter.never.optionText).tag(TurnFinishedAfter.never)
            }
        }
        .settingsRowInsets()
        .frame(minHeight: 44)
    }
}

#if DEBUG
private struct NotificationsPanePreview: View {
    let turnedOff: Bool
    @State private var preferences = NotificationPreferences()

    private var sources: [SettingsSourceModel] {
        PreviewData.sourceIDs.map { id in
            SettingsSourceModel(
                source: id, name: PreviewData.sourceNames[id] ?? id.rawValue, status: PreviewData.readyIntegration,
                defaultFolder: URL(fileURLWithPath: "/Users/user/.claude/plugins/data/subspace-subspace"), chosenFolder: nil,
                home: "/Users/user", now: PreviewData.now
            )
        }
    }

    var body: some View {
        NotificationsPane(
            sources: sources, notificationPreferences: $preferences, notificationsTurnedOff: turnedOff,
            onOpenNotificationSettings: {}
        )
        .frame(width: 460, height: 608)
        .background(.role(.surface))
        .tracksKeyboardUse()
    }
}

#Preview("Notifications – Catppuccin Latte") {
    NotificationsPanePreview(turnedOff: false).themeSelection(light: "catppuccin-latte")
}
#Preview("Notifications – Catppuccin Macchiato") {
    NotificationsPanePreview(turnedOff: false).themeSelection(dark: "catppuccin-macchiato").preferredColorScheme(.dark)
}
#Preview("Notifications – off in System Settings, Latte") {
    NotificationsPanePreview(turnedOff: true).themeSelection(light: "catppuccin-latte")
}
#Preview("Notifications – off in System Settings, Macchiato") {
    NotificationsPanePreview(turnedOff: true).themeSelection(dark: "catppuccin-macchiato").preferredColorScheme(.dark)
}
#endif
