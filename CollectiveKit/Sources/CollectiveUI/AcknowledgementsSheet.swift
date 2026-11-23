import CollectiveKit
import SwiftUI

/// The full license texts behind About's "Show License Texts…": 520 × 440, the texts
/// scrolling in their box, `Done` on Return and Esc.
struct AcknowledgementsSheet: View {
    let documents: [Acknowledgements.LicenseDocument]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(SettingsText.acknowledgements)
                .font(.plexSans(15, weight: .semibold))
                .plexLineHeight(20, size: 15)
                .foregroundStyle(.role(.text))
                .accessibilityAddTraits(.isHeader)
            texts
            HStack {
                Spacer(minLength: 0)
                Button { dismiss() } label: { Text(SettingsText.done) }
                    .buttonStyle(.settingsPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.top, 18)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .frame(width: 520, height: 440)
        .background(.role(.surface))
        .overlay { Rectangle().strokeBorder(.role(.borderStrong), lineWidth: 1) }
        // A button takes one shortcut, Return above; Esc closes like the system's Cancel.
        .background {
            Button { dismiss() } label: { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var texts: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(documents.enumerated()), id: \.offset) { _, document in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: document.header)
                            .font(.plexMono(11.5, weight: .medium))
                            .plexLineHeight(16, size: 11.5, mono: true)
                            .foregroundStyle(.role(.text))
                            .accessibilityAddTraits(.isHeader)
                        Text(verbatim: document.text)
                            .font(.plexMono(11.5))
                            .plexLineHeight(16, size: 11.5, mono: true)
                            .foregroundStyle(.role(.textMuted))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .background(.role(.surfaceSunken))
        .overlay { Rectangle().strokeBorder(.role(.border), lineWidth: 1) }
    }
}

#if DEBUG
#Preview("Acknowledgements – Catppuccin Latte") {
    AcknowledgementsSheet(documents: Acknowledgements.bundled.licenseDocuments)
        .themeSelection(light: "catppuccin-latte")
}
#Preview("Acknowledgements – Catppuccin Macchiato") {
    AcknowledgementsSheet(documents: Acknowledgements.bundled.licenseDocuments)
        .themeSelection(dark: "catppuccin-macchiato")
        .preferredColorScheme(.dark)
}
#endif
