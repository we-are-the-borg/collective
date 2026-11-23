import CollectiveKit
import SwiftUI

/// Sessions: how long finished sessions stay, when they go idle, the stored events.
struct SessionsPane: View {
    let storedEvents: StoredEventsModel
    @Binding var finishedRetention: FinishedRetention
    @Binding var idleAfter: IdleAfter
    @Binding var eventRetention: EventRetention
    let onClearStoredEvents: () -> Void
    @State private var confirmsClear = false
    /// The message as of the click on "Clear…", so the open dialog does not change with the live size.
    @State private var clearMessage: LocalizedStringResource?

    var body: some View {
        SettingsPaneScaffold(title: Text(SettingsText.sessions), description: Text(SettingsText.sessionsDescription)) {
            SettingsGroup(footnote: Text(SettingsModel.retentionFootnote)) {
                popUpRow(Text(SettingsText.keepFinishedVisible), selection: $finishedRetention, value: finishedRetention.optionText) {
                    ForEach(SettingsModel.retentionOptions, id: \.self) { option in
                        Text(option.optionText).tag(option)
                    }
                }
            }
            SettingsGroup(footnote: Text(SettingsModel.idleFootnote)) {
                popUpRow(Text(SettingsText.moveToIdleAfter), selection: $idleAfter, value: idleAfter.optionText) {
                    ForEach(SettingsModel.idleOptions.filter { $0 != .never }, id: \.self) { option in
                        Text(option.optionText).tag(option)
                    }
                    Divider()
                    Text(IdleAfter.never.optionText).tag(IdleAfter.never)
                }
            }
            SettingsGroup(footnote: Text(SettingsModel.eventRetentionFootnote)) {
                popUpRow(Text(SettingsText.keepEvents), selection: $eventRetention, value: eventRetention.optionText) {
                    ForEach(SettingsModel.eventRetentionOptions, id: \.self) { option in
                        Text(option.optionText).tag(option)
                    }
                }
                storedEventsRow
            }
        }
        .confirmationDialog(
            Text(SettingsText.clearTitle), isPresented: $confirmsClear, titleVisibility: .visible
        ) {
            Button(role: .destructive, action: onClearStoredEvents) { Text(SettingsText.clearConfirm) }
            // Return must not delete anything.
            Button(role: .cancel) {} label: { Text(SettingsText.cancel) }
                .keyboardShortcut(.defaultAction)
        } message: {
            if let clearMessage { Text(clearMessage) }
        }
    }

    /// The size and "Clear…", a normal button: the system dialog carries the danger. Without
    /// a size the row shows none and the button is disabled.
    private var storedEventsRow: some View {
        HStack(spacing: 12) {
            SettingsLabel(Text(SettingsText.storedEvents))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let size = storedEvents.sizeText {
                Text(size)
                    .font(.plexSans(SettingsControlMetrics.fontSize))
                    .monospacedDigit()
                    .foregroundStyle(.role(.textMuted))
                    .lineLimit(1)
            }
            Button {
                // No size, no message: nothing to confirm.
                guard let message = storedEvents.confirmationMessage else { return }
                clearMessage = message
                confirmsClear = true
            } label: { Text(SettingsText.clear) }
                .buttonStyle(.settings)
                .disabled(!storedEvents.canClear)
        }
        .settingsRowInsets()
        .frame(minHeight: 44)
    }

    private func popUpRow<Value: Hashable, Options: View>(
        _ label: Text, selection: Binding<Value>, value: LocalizedStringResource,
        @ViewBuilder options: () -> Options
    ) -> some View {
        HStack(spacing: 12) {
            SettingsLabel(label)
                .frame(maxWidth: .infinity, alignment: .leading)
            SettingsPopUp(selection: selection, label: label, value: Text(value), options: options)
        }
        .settingsRowInsets()
        .frame(minHeight: 44)
    }
}

#if DEBUG
private struct SessionsPanePreview: View {
    let storedEvents: StoredEventsModel
    @State private var finishedRetention = FinishedRetention.tenMinutes
    @State private var idleAfter = IdleAfter.fiveMinutes
    @State private var eventRetention = EventRetention.threeDays

    var body: some View {
        SessionsPane(
            storedEvents: storedEvents, finishedRetention: $finishedRetention, idleAfter: $idleAfter,
            eventRetention: $eventRetention, onClearStoredEvents: {}
        )
        .frame(width: 460, height: 608)
        .background(.role(.surface))
        .tracksKeyboardUse()
    }
}

#Preview("Sessions – Catppuccin Latte") {
    SessionsPanePreview(storedEvents: StoredEventsModel(size: 14_600_000)).themeSelection(light: "catppuccin-latte")
}
#Preview("Sessions – Catppuccin Macchiato") {
    SessionsPanePreview(storedEvents: StoredEventsModel(size: 14_600_000))
        .themeSelection(dark: "catppuccin-macchiato").preferredColorScheme(.dark)
}
// No size known yet, so no size text and "Clear…" disabled.
#Preview("Sessions – Clear disabled, Latte") {
    SessionsPanePreview(storedEvents: StoredEventsModel(size: nil)).themeSelection(light: "catppuccin-latte")
}
#Preview("Sessions – Clear disabled, Macchiato") {
    SessionsPanePreview(storedEvents: StoredEventsModel(size: 14_600_000, isClearing: true))
        .themeSelection(dark: "catppuccin-macchiato").preferredColorScheme(.dark)
}
#endif
