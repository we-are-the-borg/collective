import AppKit
import CollectiveKit
import SubspaceKit
import SwiftUI

/// "Set Up The Collective": one section per tool, rendered from the model. A section
/// with commands to type also has one button that runs them for the user;
/// the commands stay copyable, and the session box stays copy-only.
/// The window's scene hides the system's title bar (`WindowTitleBar`).
public struct SetupWindowView: View {
    let model: SetupWindowModel
    let appIcon: Image
    let faqURL: URL?
    let onRun: (SourceID, SetupCardModel.CommandsBox.Footer.Button.Kind) -> Void
    let onRunUpdate: (SourceID, SetupCardModel.CommandsBox.Footer.Button.Kind) -> Void
    let onToggleOutput: (SourceID) -> Void
    let onCheckAgain: () -> Void
    let onClose: () -> Void

    /// The window's title; from this package so it shares the catalog with the window's texts.
    public static var title: Text { Text("Set Up The Collective", bundle: .module) }

    /// - Parameters:
    ///   - appIcon: The app's own icon; the package cannot reach it.
    ///   - faqURL: The FAQ "What if I don't see any sessions?"; nil hides the link.
    ///   - onRun: A card's Install, Enable or Try Again; the app starts or retries that tool's run.
    ///   - onRunUpdate: A card's Update, or Try Again after a failed update;
    ///     the app starts or retries the update run it shares with Settings.
    ///   - onToggleOutput: A card's Show/Hide Output.
    ///   - onCheckAgain: "Check Again"; the app probes the tools again.
    ///   - onClose: "Done" or "Later"; the app closes the window.
    public init(
        model: SetupWindowModel,
        appIcon: Image,
        faqURL: URL?,
        onRun: @escaping (SourceID, SetupCardModel.CommandsBox.Footer.Button.Kind) -> Void,
        onRunUpdate: @escaping (SourceID, SetupCardModel.CommandsBox.Footer.Button.Kind) -> Void,
        onToggleOutput: @escaping (SourceID) -> Void,
        onCheckAgain: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.appIcon = appIcon
        self.faqURL = faqURL
        self.onRun = onRun
        self.onRunUpdate = onRunUpdate
        self.onToggleOutput = onToggleOutput
        self.onCheckAgain = onCheckAgain
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowTitleBar(Self.title)
            header
            ForEach(model.cards, id: \.source) { card in
                SetupSectionView(
                    card: card,
                    onRun: { kind in
                        // "Try Again" is in both: the card says whose it is.
                        if card.buttonRunsUpdate { onRunUpdate(card.source, kind) } else { onRun(card.source, kind) }
                    },
                    onToggleOutput: { onToggleOutput(card.source) }
                )
            }
            footer
        }
        .font(.plexSans(13))
        .foregroundStyle(.role(.text))
        .frame(width: 600)
        .background(.role(.surface))
        // The window is as tall as the content (`.contentSize`); some of the texts could give
        // up a little height, so the window would settle anywhere in that range.
        .fixedSize(horizontal: false, vertical: true)
        // The title bar draws where the system's would.
        .ignoresSafeArea(.container, edges: .top)
        .tracksKeyboardUse()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            appIcon
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect your agents", bundle: .module)
                    .font(.plexSans(18, weight: .semibold))
                    .plexLineHeight(24, size: 18)
                    .accessibilityAddTraits(.isHeader)
                introduction
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 20, leading: 24, bottom: 18, trailing: 24))
    }

    /// What subspace is, then "Learn more ↗" on the same line where it fits; its words stay
    /// together.
    private var introduction: some View {
        let learnMore = nonBreakingLink(String(localized: SettingsText.learnMore), to: SettingsModel.subspaceURL)
        return (Text(SettingsText.subspaceSentence) + Text(verbatim: " ")
            + Text("Install it once for each tool you use.", bundle: .module) + Text(verbatim: " ")
            + Text(learnMore))
            .font(.plexSans(13))
            .plexLineHeight(19, size: 13)
            .foregroundStyle(.role(.textMuted))
            .tint(RoleStyle(.accent))
            .fixedSize(horizontal: false, vertical: true)
            // A run of a Text cannot carry its own label, so the link is also an action of the paragraph.
            .accessibilityAction(named: Text(SettingsText.learnMoreAccessibilityLabel)) {
                NSWorkspace.shared.open(SettingsModel.subspaceURL)
            }
    }

    // "You can reopen this window from Settings." is left out until Settings exist.
    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Events stay on this Mac and are deleted after 3 days.", bundle: .module)
                    .plexLineHeight(16, size: 11.5)
                    .foregroundStyle(.role(.textSubtle))
                    .fixedSize(horizontal: false, vertical: true)
                if let faqURL {
                    Link(destination: faqURL) {
                        Text("What if I don’t see any sessions?", bundle: .module)
                            .plexLineHeight(16, size: 11.5)
                    }
                    .buttonStyle(SettingsLinkStyle(size: 11.5))
                }
            }
            .font(.plexSans(11.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onCheckAgain) { Text("Check Again", bundle: .module) }
                .buttonStyle(.settings)
            switch model.primaryButton {
            case .done:
                Button(action: onClose) { Text("Done", bundle: .module) }
                    .buttonStyle(.settingsPrimary)
                    .keyboardShortcut(.defaultAction)
            case .later:
                Button(action: onClose) { Text("Later", bundle: .module) }
                    .buttonStyle(.settings)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 20, bottom: 14, trailing: 20))
        .overlay(alignment: .top) { Rectangle().fill(.role(.border)).frame(height: 1) }
    }
}

/// One tool over the full width, under a 1 px `--border` line: the status form, the name and
/// the status word in the form's role, then the steps and boxes indented to the name.
private struct SetupSectionView: View {
    let card: SetupCardModel
    let onRun: (SetupCardModel.CommandsBox.Footer.Button.Kind) -> Void
    let onToggleOutput: () -> Void

    /// The status column (14) and the gap after it (8).
    static let contentInset: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            if !card.steps.isEmpty || card.note != nil || card.commands != nil {
                VStack(alignment: .leading, spacing: 10) {
                    if let note = card.note {
                        Text(note)
                            .font(.plexSans(12))
                            .plexLineHeight(17, size: 12)
                            .foregroundStyle(.role(.textMuted))
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !card.steps.isEmpty {
                        steps
                    }
                    if let commands = card.commands { commandsSection(commands) }
                }
                .padding(.top, 12)
                .padding(.leading, Self.contentInset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 14, leading: 24, bottom: 16, trailing: 24))
        .overlay(alignment: .top) { Rectangle().fill(.role(.border)).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }

    private var head: some View {
        HStack(alignment: .top, spacing: 8) {
            SectionStatusForm(mark: card.statusMark)
                .frame(width: 14, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(card.title)
                        .font(.plexSans(13, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    if let pill = card.pill {
                        Text(pill.text)
                            .font(.plexSans(12.5))
                            .foregroundStyle(.role(card.statusMark.role))
                    }
                }
                .lineLimit(1)
                .frame(height: 18)
                Text(card.subtitle)
                    .font(.plexMono(11.5))
                    .plexLineHeight(16, size: 11.5, mono: true)
                    .foregroundStyle(.role(.textMuted))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 2)
                if let updateText = card.updateText {
                    Text(updateText)
                        .font(.plexSans(12))
                        .plexLineHeight(17, size: 12)
                        .foregroundStyle(.role(.textMuted))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(card.steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .top, spacing: 8) {
                    StepSymbol(symbol: step.symbol)
                        .frame(width: 14, height: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title)
                            .font(.plexSans(13))
                            .plexLineHeight(18, size: 13)
                            .foregroundStyle(.role(step.symbol == .open ? .textSubtle : .text))
                        if let detail = step.detail {
                            Text(detail)
                                .font(.plexSans(12))
                                .plexLineHeight(17, size: 12)
                                .foregroundStyle(.role(.textMuted))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commandsSection(_ commands: SetupCardModel.CommandsBox) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !commands.lines.isEmpty {
                CommandBox(box: commands, onFooterButton: onRun, onToggleOutput: onToggleOutput)
            }
            if !commands.inApp.isEmpty {
                Text("Or type this in a session:", bundle: .module)
                    .font(.plexSans(11.5))
                    .foregroundStyle(.role(.textMuted))
                CommandBox(lines: commands.inApp)
            }
        }
    }
}

/// The section's status form: the sources' forms at 12, the Lucide arrow and cross at 14.
private struct SectionStatusForm: View {
    let mark: SourceStatusMark

    var body: some View {
        switch mark.shape {
        case .circleArrowUp:
            icon(.circleArrowUp)
        case .circleX:
            icon(.circleX)
        case .dot, .ringWithDot, .triangle, .haloDot, .hollowRing:
            SourceStatusShapeView(mark)
        }
    }

    /// The status word says the same.
    private func icon(_ icon: LucideIcon) -> some View {
        LucideImage(icon, size: 14)
            .foregroundStyle(.role(mark.role))
            .accessibilityHidden(true)
    }
}

/// A check step's form; none moves: the waiting step stands (Bewegung).
private struct StepSymbol: View {
    let symbol: SetupCardModel.Step.Symbol

    var body: some View {
        switch symbol {
        // `--success`, not `--agent-done`: a passed step is no agent.
        case .done: StatusShapeView(.check, role: .success)
        case .waiting: SourceStatusShapeView(.ringWithDot, role: .info)
        case .open: SourceStatusShapeView(.hollowRing, role: .textSubtle)
        case .warning: SourceStatusShapeView(.triangle, role: .warning)
        }
    }
}

#if DEBUG
private struct SetupWindowPreview: View {
    let integrations: [IntegrationStatus]
    var runs: [SourceID: SetupCommandRun.Snapshot] = [:]
    var outputShown: Set<SourceID> = []
    var availability: [SourceID: UpdateAvailability] = [:]
    var updateRuns: [SourceID: SetupCommandRun.Snapshot] = [:]

    init(
        _ integrations: IntegrationStatus...,
        runs: [SourceID: SetupCommandRun.Snapshot] = [:],
        outputShown: Set<SourceID> = [],
        availability: UpdateAvailability = .upToDate,
        updateRun: SetupCommandRun.Snapshot? = nil
    ) {
        self.integrations = integrations
        self.runs = runs
        self.outputShown = outputShown
        self.availability = Dictionary(uniqueKeysWithValues: integrations.map { ($0.source, availability) })
        self.updateRuns = updateRun.map { run in Dictionary(uniqueKeysWithValues: integrations.map { ($0.source, run) }) } ?? [:]
    }

    var body: some View {
        SetupWindowView(
            model: SetupWindowModel(
                integrations: integrations,
                runs: runs,
                outputShown: outputShown,
                updateRuns: updateRuns,
                availability: availability,
                // A probe after the runs, so a succeeded one shows what that probe found.
                checkedAt: PreviewData.now.addingTimeInterval(1),
                now: PreviewData.now.addingTimeInterval(2),
                home: "/Users/user",
                timeZone: TimeZone(identifier: "Europe/Berlin") ?? .current
            ),
            appIcon: Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage()),
            faqURL: URL(string: "https://example.com/faq"),
            onRun: { _, _ in },
            onRunUpdate: { _, _ in },
            onToggleOutput: { _ in },
            onCheckAgain: {},
            onClose: {}
        )
    }
}

/// The design's four windows and its smaller states.
@MainActor
private enum SetupBoard {
    static var codexNotFound: IntegrationStatus {
        var status = PreviewData.codexMissingIntegration
        status.cli = .notFound
        status.searchedLocations = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return status
    }

    static var codexDisabled: IntegrationStatus {
        var status = PreviewData.codexMissingIntegration
        status.plugin = .disabled(version: "1.0.1")
        return status
    }

    static var codexWaiting: IntegrationStatus {
        var status = PreviewData.codexMissingIntegration
        status.plugin = .enabled(version: "1.0.1")
        status.commands.firstSessionHint = "Start a new Codex session, then approve subspace’s hooks with /hooks."
        return status
    }

    static var checking: IntegrationStatus {
        var status = PreviewData.missingIntegration
        status.plugin = .unknown
        return status
    }

    /// 1: Claude Code not installed, Codex not found.
    static var firstLaunch: SetupWindowPreview {
        SetupWindowPreview(PreviewData.missingIntegration, codexNotFound)
    }

    /// 2: Claude Code installing (line 2 runs), Codex disabled.
    static var installing: SetupWindowPreview {
        SetupWindowPreview(
            PreviewData.missingIntegration, codexDisabled,
            runs: PreviewData.run(PreviewData.missingIntegration, states: [.succeeded, .running], phase: .running(line: 1),
                                  outputs: [PreviewData.marketplaceOutput])
        )
    }

    /// 3: Claude Code failed, Codex installed just now: its run stays, as the plugin is enabled now.
    static var failed: SetupWindowPreview {
        let claude = PreviewData.run(
            PreviewData.missingIntegration, states: [.succeeded, .failed], phase: .failed(line: 1),
            outputs: [PreviewData.marketplaceOutput,
                      "$ claude plugin install example --scope user\nfatal: unable to access 'https://github.com/example/plugins.git/': Could not resolve host: github.com"]
        )
        let codex = PreviewData.run(
            PreviewData.codexMissingIntegration, states: [.succeeded, .succeeded], phase: .succeeded(at: PreviewData.now),
            outputs: ["$ codex plugin marketplace add example/plugins", "$ codex plugin install example"]
        )
        return SetupWindowPreview(PreviewData.missingIntegration, codexWaiting, runs: claude.merging(codex) { $1 })
    }

    /// 4: Claude Code connected, Codex waiting: Done.
    static var allDone: SetupWindowPreview {
        SetupWindowPreview(PreviewData.readyIntegration, codexWaiting)
    }

    static var updateAvailable: SetupWindowPreview {
        SetupWindowPreview(PreviewData.updatableIntegration, availability: PreviewData.updateAvailable)
    }

    static var updating: SetupWindowPreview {
        SetupWindowPreview(
            PreviewData.updatableIntegration, availability: PreviewData.updateAvailable,
            updateRun: PreviewData.updateRun(PreviewData.updatableIntegration, states: [.succeeded, .running], phase: .running(line: 1))
        )
    }

    static var updateFailed: SetupWindowPreview {
        SetupWindowPreview(
            PreviewData.updatableIntegration, availability: PreviewData.updateAvailable,
            updateRun: PreviewData.updateRun(
                PreviewData.updatableIntegration, states: [.succeeded, .failed], phase: .failed(line: 1),
                outputs: ["Updated marketplace example",
                          "$ claude plugin update example@example --scope user\nfatal: unable to access 'https://github.com/example/plugins.git/': Could not resolve host: github.com"])
        )
    }

    static var checkingWindow: SetupWindowPreview {
        SetupWindowPreview(checking, codexNotFound)
    }
}

// Latte is the light default, Macchiato the dark one.
#Preview("1 First launch – Latte") { SetupBoard.firstLaunch.preferredColorScheme(.light) }
#Preview("1 First launch – Macchiato") { SetupBoard.firstLaunch.preferredColorScheme(.dark) }
#Preview("2 Installing – Latte") { SetupBoard.installing.preferredColorScheme(.light) }
#Preview("2 Installing – Macchiato") { SetupBoard.installing.preferredColorScheme(.dark) }
#Preview("3 Failed, Codex installed – Latte") { SetupBoard.failed.preferredColorScheme(.light) }
#Preview("3 Failed, Codex installed – Macchiato") { SetupBoard.failed.preferredColorScheme(.dark) }
#Preview("4 All done – Latte") { SetupBoard.allDone.preferredColorScheme(.light) }
#Preview("4 All done – Macchiato") { SetupBoard.allDone.preferredColorScheme(.dark) }
#Preview("Update available – Latte") { SetupBoard.updateAvailable.preferredColorScheme(.light) }
#Preview("Update available – Macchiato") { SetupBoard.updateAvailable.preferredColorScheme(.dark) }
#Preview("Checking… – Latte") { SetupBoard.checkingWindow.preferredColorScheme(.light) }
#Preview("Checking… – Macchiato") { SetupBoard.checkingWindow.preferredColorScheme(.dark) }
#Preview("Updating") { SetupBoard.updating }
#Preview("Update failed") { SetupBoard.updateFailed }
#Preview("Update required") {
    SetupWindowPreview(PreviewData.updatableIntegration, availability: PreviewData.updateRequired)
}
#Preview("Marketplace already added") { SetupWindowPreview(PreviewData.marketplaceKnownIntegration) }
#Preview("Succeeded, output shown") {
    SetupWindowPreview(
        PreviewData.missingIntegration,
        runs: PreviewData.run(PreviewData.missingIntegration, states: [.succeeded, .succeeded], phase: .succeeded(at: PreviewData.now),
                              outputs: [PreviewData.marketplaceOutput, PreviewData.installOutput]),
        outputShown: [PreviewData.source]
    )
}
#Preview("Disabled with enable box") { SetupWindowPreview(PreviewData.disabledIntegration) }
#endif
