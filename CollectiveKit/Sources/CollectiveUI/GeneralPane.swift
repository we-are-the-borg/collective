import CollectiveKit
import SwiftUI

/// General: launch at login, the effort gauge's colors with their live preview, the update
/// check.
struct GeneralPane: View {
    @Binding var launchAtLogin: Bool
    @Binding var colorsEffortLevels: Bool
    @Binding var checksForUpdates: Bool

    var body: some View {
        let preview = EffortGaugePreview(colorsEffortLevels: colorsEffortLevels)
        SettingsPaneScaffold(title: Text(SettingsText.general), description: Text(SettingsText.generalDescription)) {
            SettingsGroup {
                SettingsToggleRow(isOn: $launchAtLogin, title: Text(SettingsText.launchAtLogin))
            }
            SettingsGroup(header: Text(SettingsText.popover), footnote: Text(SettingsText.effortGaugeFootnote)) {
                SettingsToggleRow(isOn: $colorsEffortLevels, title: Text(SettingsText.colorEffortLevels), hint: Text(preview.hint))
                EffortPreviewRow(preview: preview)
            }
            SettingsGroup(header: Text(SettingsText.updates), footnote: Text(SettingsModel.updatesFootnote)) {
                SettingsToggleRow(isOn: $checksForUpdates, title: Text(SettingsText.checkForUpdatesAutomatically))
            }
        }
    }
}

/// The five gauges as in the popover, colored or gray as the switch is, so the user sees what
/// it does before opening the popover.
private struct EffortPreviewRow: View {
    let preview: EffortGaugePreview

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(preview.gauges, id: \.step) { gauge in
                VStack(spacing: 5) {
                    EffortGauge(step: gauge.step, role: gauge.role)
                    Text(gauge.label)
                        .font(.plexSans(11.5))
                        .foregroundStyle(.role(.textMuted))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14))
        .accessibilityElement(children: .combine)
    }
}
