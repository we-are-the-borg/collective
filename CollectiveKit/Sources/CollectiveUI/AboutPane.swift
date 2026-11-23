import AppKit
import CollectiveKit
import SwiftUI

/// About: the centered head is the pane's heading, then what subspace is with one row per
/// registered source, then the acknowledgements with their sheet of full license texts. Under
/// the head's version the update status line, then the button row: `Check Now` or `Update…`,
/// and `Release Notes…`, which opens the release notes' sheet. The project link and the
/// copyright line are separate work and not drawn yet.
struct AboutPane: View {
    let appIcon: Image
    let appName: String
    /// The display label, e.g. "1.0.0 (42)".
    let version: String
    /// The plain `CFBundleShortVersionString`, which bounds the bundled release notes.
    let installedVersion: String?
    let sources: [SettingsSourceModel]
    var acknowledgements: Acknowledgements = .bundled
    /// The update status line; nil draws neither it nor `Check Now`.
    var update: AppUpdateStatusLine?
    /// `Check Now`: the app checks itself and every subspace plugin.
    var onCheckNow: () -> Void = {}
    /// `Update…`: the app opens its update window.
    var onUpdate: () -> Void = {}
    /// `nil` reads the bundled notes, bounded by `installedVersion`.
    var releaseNotes: ReleaseNotes?
    @State private var showsLicenseTexts = false
    @State private var showsReleaseNotes = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                head
                subspaceGroup.padding(.top, 22)
                acknowledgementsGroup.padding(.top, 22)
                footnote.padding(.top, 10)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.plexSans(13))
        .foregroundStyle(.role(.text))
        .sheet(isPresented: $showsLicenseTexts) {
            AcknowledgementsSheet(documents: acknowledgements.licenseDocuments)
        }
        .sheet(isPresented: $showsReleaseNotes) {
            ReleaseNotesSheet(releaseNotes: releaseNotes ?? .bundled(installedVersion: installedVersion))
        }
    }

    private var head: some View {
        VStack(spacing: 0) {
            // The app's own icon, which the theme does not tint.
            appIcon
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text(verbatim: appName)
                .font(.plexSans(15, weight: .semibold))
                .plexLineHeight(20, size: 15)
                .foregroundStyle(.role(.text))
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 10)
            Text(verbatim: version)
                .font(.plexSans(12).monospacedDigit())
                .plexLineHeight(17, size: 12)
                .foregroundStyle(.role(.textMuted))
                .padding(.top, 2)
            if let update { UpdateStatusLine(line: update).padding(.top, 14) }
            buttons.padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    /// Centered, 10 apart: `Check Now`, or the primary `Update…` in its place, before `Release Notes…`.
    private var buttons: some View {
        HStack(spacing: 10) {
            switch update?.button {
            case .checkNow(let enabled)?:
                Button(action: onCheckNow) { Text(SettingsText.checkNow) }
                    .buttonStyle(.settings)
                    .disabled(!enabled)
            case .update?:
                Button(action: onUpdate) { Text(SettingsText.updateApp) }
                    .buttonStyle(.settingsPrimary)
            case nil:
                EmptyView()
            }
            Button { showsReleaseNotes = true } label: { Text(SettingsText.releaseNotesButton) }
                .buttonStyle(.settings)
        }
    }

    // MARK: subspace

    private var subspaceGroup: some View {
        SettingsGroup(header: Text(SettingsText.subspace)) {
            subspaceSentence
                .settingsRowInsets()
                .frame(maxWidth: .infinity, alignment: .leading)
            // A source without a URL gets no row.
            ForEach(sources.compactMap { source in source.sourceURL.map { (source, $0) } }, id: \.0.source) { source, url in
                sourceRow(source, url: url)
            }
        }
    }

    /// The setup window's sentence, word for word, with `Learn more ↗` kept on one line.
    private var subspaceSentence: some View {
        let learnMore = nonBreakingLink(String(localized: SettingsText.learnMore), to: SettingsModel.subspaceURL)
        return (Text(SettingsText.subspaceSentence) + Text(verbatim: " ") + Text(learnMore))
            .font(.plexSans(12.5))
            .plexLineHeight(18, size: 12.5)
            .foregroundStyle(.role(.textMuted))
            .tint(RoleStyle(.accent))
            .fixedSize(horizontal: false, vertical: true)
            // A run of a Text cannot carry its own label, so the link is also an action of the paragraph.
            .accessibilityAction(named: Text(SettingsText.learnMoreAccessibilityLabel)) {
                NSWorkspace.shared.open(SettingsModel.subspaceURL)
            }
    }

    private func sourceRow(_ source: SettingsSourceModel, url: URL) -> some View {
        HStack(spacing: 12) {
            Link(destination: url) { Text(SettingsText.aboutSourceLink(name: source.name)) }
                .buttonStyle(.settingsLink)
            Spacer(minLength: 0)
            if let repository = source.repositoryName {
                Text(verbatim: repository)
                    .font(.plexMono(11.5))
                    .foregroundStyle(.role(.textSubtle))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 36)
    }

    // MARK: Acknowledgements

    private var acknowledgementsGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(SettingsText.acknowledgements)
                .font(.plexSans(13, weight: .semibold))
                .plexLineHeight(18, size: 13)
                .foregroundStyle(.role(.text))
                .accessibilityAddTraits(.isHeader)
            ForEach(acknowledgements.sections, id: \.id) { section in
                Text(section.title)
                    .font(.plexSans(11.5, weight: .semibold))
                    .plexLineHeight(16, size: 11.5)
                    .foregroundStyle(.role(.textMuted))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                AcknowledgementsList(entries: section.entries)
            }
        }
    }

    /// The design's inline link opens a sheet, not a page, so it is a link-styled button.
    private var footnote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(SettingsText.licenseTextsFootnote)
                .foregroundStyle(.role(.textSubtle))
            Button { showsLicenseTexts = true } label: { Text(SettingsText.showLicenseTexts) }
                .buttonStyle(SettingsLinkStyle(size: 12))
        }
        .font(.plexSans(12))
        .plexLineHeight(17, size: 12)
    }
}

/// One list's box: Name | Version | License 96 | ↗ 14, 12 apart, rows at least 32 high with
/// 1 px `--border` between them. A grid, so the versions line up within the list.
private struct AcknowledgementsList: View {
    let entries: [Acknowledgements.Entry]

    private static let inset: CGFloat = 14

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                if index > 0 {
                    // Across the whole box, under the rows' insets.
                    SettingsDivider().padding(.horizontal, -Self.inset)
                }
                GridRow {
                    Text(verbatim: entry.name)
                        .foregroundStyle(.role(.text))
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    Text(entry.versionText)
                        .font(.plexMono(11.5))
                        .foregroundStyle(.role(.textSubtle))
                        .lineLimit(1)
                    Text(verbatim: entry.spdx)
                        .font(.plexSans(12))
                        .foregroundStyle(.role(.textMuted))
                        .lineLimit(1)
                        .frame(width: 96, alignment: .leading)
                    Link(destination: entry.url) { Text(verbatim: "↗") }
                        .buttonStyle(SettingsLinkStyle(size: 13))
                        .frame(width: 14)
                        .accessibilityLabel(Text(SettingsText.website(name: entry.name)))
                }
            }
        }
        .padding(.horizontal, Self.inset)
        // Inside the frame, as the design's CSS border is outside the content.
        .padding(1)
        .overlay { Rectangle().strokeBorder(.role(.border), lineWidth: 1) }
    }
}

/// About's status line, 12/17 centered with 6 between the form and the text: the status word
/// in the form's role, the detail in `textSubtle`, after a failed `Check Now` a second line
/// 2 below in `textMuted`. VoiceOver reads it as one element and hears each change.
private struct UpdateStatusLine: View {
    let line: AppUpdateStatusLine

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                SourceStatusShapeView(line.mark)
                text.lineLimit(1)
            }
            if let explanation = line.explanation {
                Text(explanation)
                    .foregroundStyle(.role(.textMuted))
                    .multilineTextAlignment(.center)
            }
        }
        .font(.plexSans(12).monospacedDigit())
        .plexLineHeight(17, size: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
        .onChange(of: line) { AccessibilityNotification.Announcement(spoken).post() }
    }

    private var text: Text {
        let status = Text(line.status).foregroundStyle(.role(line.mark.role))
        guard let detail = line.detail else { return status }
        return status + Text(verbatim: " ") + Text(detail).foregroundStyle(.role(.textSubtle))
    }

    /// "Up to date · checked today at 14:02", the explanation after it.
    private var spoken: String {
        [line.status, line.detail, line.explanation].compactMap { $0.map { String(localized: $0) } }.joined(separator: " ")
    }
}
