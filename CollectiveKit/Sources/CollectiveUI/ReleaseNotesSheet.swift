import CollectiveKit
import SwiftUI

/// The user release notes behind About's "Release Notes…": built like the license
/// texts' sheet, 520 × 440, every release up to the installed one scrolling in its box, newest
/// first, `Done` on Return and Esc.
struct ReleaseNotesSheet: View {
    let releaseNotes: ReleaseNotes
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(SettingsText.releaseNotes)
                .font(.plexSans(15, weight: .semibold))
                .plexLineHeight(20, size: 15)
                .foregroundStyle(.role(.text))
                .accessibilityAddTraits(.isHeader)
            notes
            HStack {
                Link(destination: ReleaseNotes.allReleasesURL) { Text(SettingsText.allReleasesOnGitHub) }
                    .buttonStyle(SettingsLinkStyle(size: 12.5))
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

    private var notes: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(releaseNotes.releases.enumerated()), id: \.element.id) { index, release in
                    if index > 0 {
                        SettingsDivider()
                            .padding(.top, 12)
                            .padding(.bottom, 14)
                    }
                    ReleaseSection(release: release)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .background(.role(.surface))
        .overlay { Rectangle().strokeBorder(.role(.border), lineWidth: 1) }
    }
}

/// One version: its heading, the `Installed` pill on the installed one, then its notes.
private struct ReleaseSection: View {
    let release: ReleaseNotes.Release

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: release.version)
                    .font(.plexSans(13, weight: .semibold).monospacedDigit())
                    .plexLineHeight(18, size: 13)
                    .foregroundStyle(.role(.text))
                if release.isInstalled {
                    Text(SettingsText.installed)
                        .font(.plexSans(11))
                        .plexLineHeight(16, size: 11)
                        .foregroundStyle(.role(.textMuted))
                        .padding(.horizontal, 6)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5).strokeBorder(.role(.borderStrong), lineWidth: 1)
                        }
                }
            }
            // Read as one header, "1.2.0, Installed".
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ReplyMarkdownView(blocks: release.blocks, style: .releaseNotes)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#if DEBUG
private let previewNotes = ReleaseNotes(
    markdown: """
    ## 1.3.0

    - Not shown: newer than the installed version.

    ## 1.2.0

    - A new look in the style of **Unimatrix Zero**, with IBM Plex type.
    - Pick your colors in *Settings › Appearance*, or import `base16` schemes.

    ## 1.1.0

    - Choose whether the menu bar cube animates [always or never](https://example.com).

    ## 1.0.0

    - The first release.
    """,
    installedVersion: "1.2.0"
)

#Preview("Release Notes – Catppuccin Latte") {
    ReleaseNotesSheet(releaseNotes: previewNotes)
        .themeSelection(light: "catppuccin-latte")
}
#Preview("Release Notes – Catppuccin Macchiato") {
    ReleaseNotesSheet(releaseNotes: previewNotes)
        .themeSelection(dark: "catppuccin-macchiato")
        .preferredColorScheme(.dark)
}
#endif
