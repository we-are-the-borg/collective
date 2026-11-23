import AppKit
import CollectiveKit
import SubspaceKit
import SwiftUI

/// A source's pane: its subspace state with Set Up…, what subspace is, the update group, the
/// event folder.
struct SourcePane: View {
    let source: SettingsSourceModel
    let onSetUp: (SourceID) -> Void
    let onUpdate: (SourceID, SetupCardModel.CommandsBox.Footer.Button.Kind) -> Void
    let onToggleUpdateOutput: (SourceID) -> Void
    let onChooseFolder: (SourceID) -> Void
    let onResetFolder: (SourceID) -> Void

    var body: some View {
        SettingsPaneScaffold(title: Text(verbatim: source.name), description: Text(SettingsText.sourceDescription(name: source.name))) {
            // The info row hangs 8 under the box, not the scaffold's 22.
            VStack(alignment: .leading, spacing: 8) {
                SettingsGroup { subspaceRow }
                SourceInfoRow(name: source.name, url: source.sourceURL)
            }
            if let update = source.update {
                UpdateGroup(
                    update: update,
                    onRun: { onUpdate(source.source, $0) },
                    onToggleOutput: { onToggleUpdateOutput(source.source) }
                )
            }
            SettingsGroup(header: Text(SettingsText.data)) { eventFolderRow }
        }
    }

    /// `subspace`, then the form and the status word in its role with the version in
    /// `--text-subtle`, then Set Up… in every state but ready.
    private var subspaceRow: some View {
        HStack(spacing: 12) {
            SettingsLabel(Text(SettingsText.subspace))
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                SourceStatusShapeView(source.statusMark)
                statusText
                    .font(.plexSans(13))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .fixedSize()
            // One element that reads like the sidebar row: "Connected · 1.0.1".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(source.status.text))
            if let style = source.setUpButton {
                Button { onSetUp(source.source) } label: { Text(SettingsText.setUp) }
                    .buttonStyle(SettingsButtonStyle(style == .primary ? .primary : .normal))
                    .fixedSize()
            }
        }
        .settingsRowInsets()
        .frame(minHeight: 44)
    }

    private var statusText: Text {
        let word = Text(source.statusWord).foregroundStyle(.role(source.statusMark.role))
        guard let version = source.statusVersion else { return word }
        return word + Text(verbatim: " · \(version)").foregroundStyle(.role(.textSubtle))
    }

    /// `Event folder` with Reset and Choose…, the path box under it. The marker stays outside the
    /// selectable path, so a copy is the path alone.
    private var eventFolderRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SettingsLabel(Text(SettingsText.eventFolder))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { onResetFolder(source.source) } label: { Text(SettingsText.reset) }
                    .buttonStyle(.settings)
                    .disabled(!source.canReset)
                Button { onChooseFolder(source.source) } label: { Text(SettingsText.choose) }
                    .buttonStyle(.settings)
            }
            .frame(minHeight: 24)
            VStack(alignment: .leading, spacing: 2) {
                PathText(text: source.eventFolderPath)
                if source.showsDefaultMarker {
                    Text(SettingsText.defaultMarker)
                        .font(.plexSans(11))
                        .plexLineHeight(15, size: 11)
                        .foregroundStyle(.role(.textMuted))
                }
            }
            .padding(EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowBox()
        }
        .settingsRowInsets()
    }
}

/// What subspace is for this tool, with the link to the adapter's plugin repository, in every
/// state; without a URL the sentence stands alone.
private struct SourceInfoRow: View {
    let name: String
    let url: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            LucideImage(.info, size: 14)
                .foregroundStyle(.role(.textMuted))
                .padding(.top, 1.5)
                .accessibilityHidden(true)
            paragraph
                .font(.plexSans(12))
                .plexLineHeight(17, size: 12)
                .foregroundStyle(.role(.textMuted))
                .tint(RoleStyle(.accent))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var paragraph: some View {
        let sentence = Text(SettingsText.sourceInfo(name: name))
        if let url {
            let link = nonBreakingLink(String(localized: SettingsText.sourceInfoLink(name: name)), to: url)
            (sentence + Text(verbatim: " ") + Text(link))
                // A run of a Text cannot carry its own label, so the link is also an action of the paragraph.
                .accessibilityAction(named: Text(SettingsText.sourceInfoLink(name: name))) {
                    NSWorkspace.shared.open(url)
                }
        } else {
            sentence
        }
    }
}

/// A path in Plex Mono 11/15, `--text-muted`, that wraps at any character: a SwiftUI `Text`
/// only breaks at word boundaries, so a long path without spaces would overflow. Selectable,
/// and a copy is the plain path, which zero-width spaces inserted for wrapping would not be.
private struct PathText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isSelectable = true
        field.lineBreakMode = .byCharWrapping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let paragraph = NSMutableParagraphStyle()
        // On the attributes too, so the field editor keeps the breaks while selecting.
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.minimumLineHeight = 15
        paragraph.maximumLineHeight = 15
        PlexFace.registerAll()
        var attributes: [NSAttributedString.Key: Any] = [
            // The role as of this update; a change of theme or appearance updates the view again.
            .foregroundColor: NSColor(Color(context.environment.theme.roles[.textMuted])),
            .paragraphStyle: paragraph,
        ]
        // The faces are bundled and registered above, so the name always resolves.
        if let font = NSFont(name: PlexFace.monoRegular.postScriptName, size: 11) { attributes[.font] = font }
        field.attributedStringValue = NSAttributedString(string: text, attributes: attributes)
    }

    /// The proposed width, and as tall as the wrapped text needs.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, let cell = field.cell else { return nil }
        let height = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(height))
    }
}

/// A source's update group under the info row: the update's form, title and
/// installed version, then the command box with its numbers, footer and output.
private struct UpdateGroup: View {
    let update: SourceUpdateModel
    let onRun: (SetupCardModel.CommandsBox.Footer.Button.Kind) -> Void
    let onToggleOutput: () -> Void

    /// The form's column (14) and the gap after it (8), so the required note lines up with the title.
    private static let textIndent: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    UpdateStatusForm(mark: update.statusMark)
                        .frame(width: 14, height: 14)
                    Text(update.title)
                        .font(.plexSans(13))
                        .foregroundStyle(.role(.text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let subtitle = update.subtitle {
                        Text(subtitle)
                            .font(.plexSans(12))
                            .foregroundStyle(.role(.textMuted))
                    }
                }
                .monospacedDigit()
                .frame(minHeight: 24)
                if let text = update.text {
                    Text(text)
                        .font(.plexSans(12))
                        .plexLineHeight(17, size: 12)
                        .foregroundStyle(.role(.textMuted))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Self.textIndent)
                }
            }
            if let commands = update.commands, !commands.lines.isEmpty {
                CommandBox(box: commands, numberSize: 11, onFooterButton: onRun, onToggleOutput: onToggleOutput)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(1)
        .overlay { Rectangle().strokeBorder(.role(.border), lineWidth: 1) }
    }
}

/// The update's form; a run carries the setup window's running line's halo.
private struct UpdateStatusForm: View {
    let mark: SourceStatusMark

    var body: some View {
        switch mark.shape {
        case .haloDot:
            StatusShapeView(.haloDot(bright: true), role: mark.role)
                .accessibilityHidden(true)
        case .dot, .ringWithDot, .triangle, .hollowRing, .circleArrowUp, .circleX:
            SourceStatusShapeView(mark)
        }
    }
}

#if DEBUG
/// One source's pane as the window shows it, at the detail's width.
private struct SourcePanePreview: View {
    let model: SettingsSourceModel

    init(
        _ status: IntegrationStatus?, chosen: Bool = false,
        availability: UpdateAvailability = .upToDate, updateRun: SetupCommandRun.Snapshot? = nil
    ) {
        let home = "/Users/user"
        let tool = status?.source == PreviewData.codexSource ? ".codex" : ".claude"
        model = SettingsSourceModel(
            source: status?.source ?? PreviewData.source,
            name: status?.toolName ?? "Claude Code",
            status: status,
            // A probe after the run, so a succeeded one shows what that probe found.
            checkedAt: PreviewData.now.addingTimeInterval(1),
            defaultFolder: URL(fileURLWithPath: "\(home)/\(tool)/plugins/data/subspace-subspace"),
            chosenFolder: chosen ? URL(fileURLWithPath: "\(home)/Library/Mobile Documents/com~apple~CloudDocs/Shared/subspace/claude-code/events") : nil,
            availability: availability,
            updateRun: updateRun,
            home: home,
            now: PreviewData.now.addingTimeInterval(2),
            timeZone: TimeZone(identifier: "Europe/Berlin") ?? .current
        )
    }

    var body: some View {
        SourcePane(source: model, onSetUp: { _ in }, onUpdate: { _, _ in }, onToggleUpdateOutput: { _ in },
                   onChooseFolder: { _ in }, onResetFolder: { _ in })
            .frame(width: 460, height: 640)
            .background(.role(.surface))
            .tracksKeyboardUse()
    }
}

@MainActor
private enum SourcePreviews {
    static var updateAvailable: SourcePanePreview {
        SourcePanePreview(PreviewData.updatableIntegration, availability: PreviewData.updateAvailable)
    }

    static var codexDisabled: SourcePanePreview {
        var status = PreviewData.codexMissingIntegration
        status.plugin = .disabled(version: "1.0.1")
        return SourcePanePreview(status)
    }

    static var codexNotSetUp: SourcePanePreview { SourcePanePreview(PreviewData.codexMissingIntegration) }
    static var waiting: SourcePanePreview { SourcePanePreview(PreviewData.waitingIntegration) }

    static var updating: SourcePanePreview {
        SourcePanePreview(PreviewData.updatableIntegration, availability: PreviewData.updateAvailable,
                          updateRun: PreviewData.updateRun(PreviewData.updatableIntegration, states: [.succeeded, .running], phase: .running(line: 1)))
    }

    static var updateFailed: SourcePanePreview {
        SourcePanePreview(PreviewData.updatableIntegration, availability: PreviewData.updateAvailable,
                          updateRun: PreviewData.updateRun(
                              PreviewData.updatableIntegration, states: [.succeeded, .failed], phase: .failed(line: 1),
                              outputs: ["Updated marketplace example", "$ claude plugin update example@example --scope user\nfatal: unable to access 'https://github.com/example/plugins.git/': Could not resolve host: github.com"]))
    }

    static var updateRequired: SourcePanePreview {
        SourcePanePreview(PreviewData.updatableIntegration, availability: PreviewData.updateRequired)
    }

    static var chosenFolder: SourcePanePreview { SourcePanePreview(PreviewData.readyIntegration, chosen: true) }
}

extension View {
    fileprivate func latte() -> some View { themeSelection(light: "catppuccin-latte") }
    fileprivate func macchiato() -> some View { themeSelection(dark: "catppuccin-macchiato").preferredColorScheme(.dark) }
}

// The design's two frames: Claude Code connected with an update, Codex disabled;
// then its second state (Codex not set up) and the update states the design leaves to the rules.
#Preview("Update available – Catppuccin Latte") { SourcePreviews.updateAvailable.latte() }
#Preview("Update available – Catppuccin Macchiato") { SourcePreviews.updateAvailable.macchiato() }
#Preview("Codex disabled – Catppuccin Latte") { SourcePreviews.codexDisabled.latte() }
#Preview("Codex disabled – Catppuccin Macchiato") { SourcePreviews.codexDisabled.macchiato() }
#Preview("Codex not set up – Catppuccin Latte") { SourcePreviews.codexNotSetUp.latte() }
#Preview("Codex not set up – Catppuccin Macchiato") { SourcePreviews.codexNotSetUp.macchiato() }
#Preview("Waiting – Catppuccin Latte") { SourcePreviews.waiting.latte() }
#Preview("Waiting – Catppuccin Macchiato") { SourcePreviews.waiting.macchiato() }
#Preview("Updating – Catppuccin Latte") { SourcePreviews.updating.latte() }
#Preview("Updating – Catppuccin Macchiato") { SourcePreviews.updating.macchiato() }
#Preview("Update failed – Catppuccin Latte") { SourcePreviews.updateFailed.latte() }
#Preview("Update failed – Catppuccin Macchiato") { SourcePreviews.updateFailed.macchiato() }
#Preview("Update required – Catppuccin Latte") { SourcePreviews.updateRequired.latte() }
#Preview("Update required – Catppuccin Macchiato") { SourcePreviews.updateRequired.macchiato() }
#Preview("Chosen folder – Catppuccin Latte") { SourcePreviews.chosenFolder.latte() }
#Preview("Chosen folder – Catppuccin Macchiato") { SourcePreviews.chosenFolder.macchiato() }
#endif
