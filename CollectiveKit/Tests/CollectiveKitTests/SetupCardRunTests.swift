import Foundation
import Testing
@testable import CollectiveKit

// The card around its command run, with the adapters' real lines.

private let now = Date(timeIntervalSince1970: 100_000)
private let home = "/Users/user"
private let gmt = TimeZone(identifier: "GMT")!

private let marketplace = "claude plugin marketplace add we-are-the-borg/subspace-claude-code"
private let install = "claude plugin install subspace@subspace --scope user"
private let enable = "claude plugin enable subspace@subspace"
private let hooks = "subspace adds hooks that run in every Claude Code session."

private func claudeCode(
    _ plugin: IntegrationStatus.Plugin,
    marketplaceAdded: Bool? = nil,
    cli: IntegrationStatus.CLI = .found(path: "\(home)/.local/bin/claude", version: "2.1.285"),
    lastSessionStartAt: Date? = nil
) -> IntegrationStatus {
    IntegrationStatus(
        source: "claude-code", toolName: "Claude Code", cliName: "claude", cli: cli, plugin: plugin,
        marketplaceAdded: marketplaceAdded, lastSessionStartAt: lastSessionStartAt,
        commands: ClaudeCodeSubspace.commands
    )
}

private func codex(
    _ plugin: IntegrationStatus.Plugin,
    marketplaceAdded: Bool? = nil,
    cli: IntegrationStatus.CLI = .found(path: "/opt/homebrew/bin/codex", version: "0.160.0")
) -> IntegrationStatus {
    IntegrationStatus(
        source: "codex", toolName: "Codex", cliName: "codex", cli: cli, plugin: plugin,
        marketplaceAdded: marketplaceAdded, commands: CodexSubspace.commands
    )
}

private func card(_ status: IntegrationStatus, run: SetupCommandRun.Snapshot? = nil, outputShown: Bool = false) -> SetupCardModel {
    SetupCardModel(status, run: run, outputShown: outputShown, now: now, home: home, timeZone: gmt)
}

private typealias RunLine = SetupCommandRun.Line

private func run(_ phase: SetupCommandRun.Phase, _ lines: [(String, RunLine.State, String?)],
                 kind: SetupCardModel.RunPlan.Kind = .install) -> SetupCommandRun.Snapshot {
    SetupCommandRun.Snapshot(kind: kind, lines: lines.map { RunLine(command: $0.0, state: $0.1, output: $0.2) }, phase: phase)
}

/// 03:46 GMT; "h:mm a" in English puts a narrow no-break space before "AM".
private let succeededAt = Date(timeIntervalSince1970: 13_560)

private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

/// Terminal lines as "slot command [tag]", output on lines of its own under them.
private func lines(_ card: SetupCardModel) -> [String] {
    (card.commands?.lines ?? []).map { line in
        let slot = switch line.slot {
        case nil: ""
        case .number(let number)?: "\(number) "
        case .done?: "done "
        case .running?: "running "
        case .todo?: "todo "
        case .failed?: "failed "
        }
        let tag = line.tag.map { " [\(en($0))]" } ?? ""
        let output = line.output.map { "\n" + $0 } ?? ""
        return slot + line.command + tag + output
    }
}

/// The footer's text, with "! " in front when it warns.
private func footer(_ card: SetupCardModel) -> String? {
    card.commands?.footer.map { footer in
        (footer.isWarning ? "! " : "") + en(footer.text)
    }
}

/// "Title (enabled) / accessibility label"
private func button(_ card: SetupCardModel) -> String? {
    card.commands?.footer?.button.map { button in
        "\(en(button.title)) (\(button.isEnabled ? "enabled" : "disabled")) / \(en(button.accessibilityLabel))"
    }
}

private func pill(_ card: SetupCardModel) -> String? {
    card.pill.map { "\(en($0.text)) (\(card.statusMark.shape))" }
}

@Suite struct SetupCardRunTests {
    @Test func notInstalledNumbersBothLinesAndOffersInstall() throws {
        let card = card(claudeCode(.notInstalled))
        #expect(lines(card) == ["1 \(marketplace)", "2 \(install)"])
        #expect(footer(card) == "Runs both commands in your login shell. \(hooks)")
        #expect(button(card) == "Install (enabled) / Install subspace for Claude Code: runs \(marketplace), then \(install)")
        #expect(card.commands?.footer?.button?.kind == .install)
        #expect(card.commands?.footer?.link?.kind == .source)
        #expect(card.commands?.footer?.link?.url == URL(string: "https://github.com/we-are-the-borg/subspace-claude-code"))
        #expect(card.commands?.footer?.outputToggle == nil)
        #expect(card.commands?.inApp == ClaudeCodeSubspace.commands.installInApp)
        #expect(pill(card) == nil)
    }

    @Test func anAddedMarketplaceIsMarkedDoneAndOnlyTheInstallIsNumbered() {
        let card = card(claudeCode(.notInstalled, marketplaceAdded: true))
        #expect(lines(card) == ["done \(marketplace) [Already added]", "1 \(install)"])
        #expect(footer(card) == "The marketplace is already there. Runs 1 command in your login shell. \(hooks)")
        #expect(button(card) == "Install (enabled) / Install subspace for Claude Code: runs \(install)")
        #expect(pill(card) == nil)
    }

    @Test func anUnknownMarketplaceRunsBothLines() {
        #expect(lines(card(claudeCode(.notInstalled, marketplaceAdded: false))) == ["1 \(marketplace)", "2 \(install)"])
        #expect(card(claudeCode(.notInstalled, marketplaceAdded: false)).runPlan?.skipping == [])
    }

    @Test func theInstallPlanRunsTheAdapterLinesWithTheFoundCLI() throws {
        let plan = try #require(card(claudeCode(.notInstalled)).runPlan)
        #expect(plan.kind == .install)
        #expect(plan.lines == [marketplace, install])
        #expect(plan.skipping == [])
        #expect(plan.programName == "claude")
        #expect(plan.programPath == "\(home)/.local/bin/claude")
    }

    @Test func theInstallPlanSkipsAnAddedMarketplace() {
        #expect(card(claudeCode(.notInstalled, marketplaceAdded: true)).runPlan?.skipping == [0])
    }

    @Test func theEnablePlanRunsTheEnableLine() throws {
        let plan = try #require(card(claudeCode(.disabled(version: "0.4.0"))).runPlan)
        #expect(plan.kind == .enable)
        #expect(plan.lines == [enable])
        #expect(plan.skipping == [])
    }

    @Test(arguments: [
        IntegrationStatus.Plugin.notInstalled,
        .disabled(version: "0.4.0"),
        .enabled(version: "0.4.0"),
    ])
    func noPlanWithoutTheCLI(plugin: IntegrationStatus.Plugin) {
        #expect(card(claudeCode(plugin, cli: .notFound)).runPlan == nil)
    }

    @Test func noPlanOnceEnabled() {
        #expect(card(claudeCode(.enabled(version: "0.4.0"))).runPlan == nil)
        #expect(card(claudeCode(.enabled(version: "0.4.0"), lastSessionStartAt: now)).runPlan == nil)
    }

    @Test func disabledNumbersTheEnableLineAndOffersEnable() {
        let card = card(claudeCode(.disabled(version: "0.4.0")))
        #expect(lines(card) == ["1 \(enable)"])
        #expect(footer(card) == "Runs this command in your login shell.")
        #expect(button(card) == "Enable (enabled) / Enable subspace: runs \(enable)")
        #expect(card.commands?.footer?.button?.kind == .enable)
        #expect(card.commands?.inApp == ClaudeCodeSubspace.commands.enableInApp)
        #expect(pill(card) == "Disabled (triangle)")
    }

    /// Without a CLI the lines stay copy-only: no slots, footer or button.
    @Test(arguments: [IntegrationStatus.Plugin.notInstalled, .disabled(version: "0.4.0")])
    func withoutTheCLITheLinesAreOnlyCopied(plugin: IntegrationStatus.Plugin) throws {
        let card = card(claudeCode(plugin, cli: .notFound))
        let commands = try #require(card.commands)
        #expect(!commands.lines.isEmpty)
        #expect(commands.lines.allSatisfy { $0.slot == nil && $0.tag == nil && $0.output == nil })
        #expect(commands.footer == nil)
    }

    // MARK: - Running

    @Test func runningOnTheMarketplaceLeavesTheInstallToDo() {
        let card = card(claudeCode(.notInstalled), run: run(.running(line: 0), [
            (marketplace, .running, nil), (install, .pending, nil),
        ]))
        #expect(lines(card) == ["running \(marketplace)", "todo \(install)"])
        #expect(footer(card) == "Adding the marketplace…")
        #expect(button(card) == "Install (disabled) / Install, running")
        #expect(card.commands?.footer?.button?.kind == .install)
        #expect(card.commands?.footer?.link?.kind == .source)
        #expect(card.commands?.footer?.link?.url == ClaudeCodeSubspace.sourceURL)
        #expect(card.commands?.inApp == ClaudeCodeSubspace.commands.installInApp)
        #expect(pill(card) == nil)
    }

    @Test func runningOnTheInstallAfterTheMarketplace() {
        let card = card(claudeCode(.notInstalled), run: run(.running(line: 1), [
            (marketplace, .succeeded, "$ \(marketplace)"), (install, .running, nil),
        ]))
        #expect(lines(card) == ["done \(marketplace)", "running \(install)"])
        #expect(footer(card) == "Installing subspace…")
        #expect(button(card) == "Install (disabled) / Install, running")
    }

    @Test func runningOnTheInstallWithTheMarketplaceAlreadyAdded() {
        let card = card(claudeCode(.notInstalled, marketplaceAdded: true), run: run(.running(line: 1), [
            (marketplace, .skipped, nil), (install, .running, nil),
        ]))
        #expect(lines(card) == ["done \(marketplace) [Already added]", "running \(install)"])
        #expect(footer(card) == "Installing subspace…")
    }

    @Test func runningOnTheEnableLine() {
        let card = card(claudeCode(.disabled(version: "0.4.0")), run: run(.running(line: 0), [(enable, .running, nil)], kind: .enable))
        #expect(lines(card) == ["running \(enable)"])
        #expect(footer(card) == "Enabling subspace…")
        #expect(button(card) == "Enable (disabled) / Enable, running")
        #expect(card.commands?.footer?.button?.kind == .enable)
        #expect(pill(card) == "Disabled (triangle)")
    }

    /// A run made but not started shows the card as before it.
    @Test func anIdleRunChangesNothing() {
        let status = claudeCode(.notInstalled)
        #expect(card(status, run: run(.idle, [(marketplace, .pending, nil), (install, .pending, nil)])) == card(status))
    }

    // MARK: - Succeeded

    @Test func aSucceededInstallHidesItsOutputUntilAsked() {
        let snapshot = run(.succeeded(at: succeededAt), [
            (marketplace, .succeeded, "$ \(marketplace)\nAdded."), (install, .succeeded, "$ \(install)\nInstalled."),
        ])
        let hidden = card(claudeCode(.notInstalled), run: snapshot)
        #expect(lines(hidden) == ["done \(marketplace)", "done \(install)"])
        #expect(footer(hidden) == "Installed at 3:46\u{202F}AM.")
        #expect(hidden.commands?.footer?.outputToggle == .hidden)
        #expect(hidden.commands?.footer?.button == nil)
        #expect(hidden.commands?.footer?.link?.kind == .source)
        #expect(hidden.commands?.footer?.link?.url == ClaudeCodeSubspace.sourceURL)
        #expect(pill(hidden) == nil)

        let shown = card(claudeCode(.notInstalled), run: snapshot, outputShown: true)
        #expect(lines(shown) == [
            "done \(marketplace)\n$ \(marketplace)\nAdded.",
            "done \(install)\n$ \(install)\nInstalled.",
        ])
        #expect(shown.commands?.footer?.outputToggle == .showing)
    }

    /// A skipped line never ran, so it has no output to show.
    @Test func aSkippedLineShowsNoOutput() {
        let card = card(claudeCode(.notInstalled, marketplaceAdded: true), run: run(.succeeded(at: succeededAt), [
            (marketplace, .skipped, nil), (install, .succeeded, "$ \(install)"),
        ]), outputShown: true)
        #expect(lines(card) == ["done \(marketplace) [Already added]", "done \(install)\n$ \(install)"])
    }

    /// The recheck after the run already reports the next state: the steps
    /// and pill follow it, the run's lines stay until the window closes.
    @Test func aSucceededInstallStaysOnceThePluginIsEnabled() throws {
        let card = card(claudeCode(.enabled(version: "0.4.0")), run: run(.succeeded(at: succeededAt), [
            (marketplace, .succeeded, "$ \(marketplace)"), (install, .succeeded, "$ \(install)"),
        ]))
        #expect(card.state == .waiting)
        #expect(pill(card) == "Waiting for a session (ringWithDot)")
        #expect(card.steps.map(\.symbol) == [.done, .done, .done, .waiting])
        #expect(lines(card) == ["done \(marketplace)", "done \(install)"])
        #expect(footer(card) == "Installed at 3:46\u{202F}AM.")
        #expect(card.commands?.inApp == [])
        #expect(card.runPlan == nil)
    }

    @Test func aSucceededEnable() {
        let card = card(claudeCode(.enabled(version: "0.4.0")), run: run(.succeeded(at: succeededAt), [
            (enable, .succeeded, "$ \(enable)"),
        ], kind: .enable))
        #expect(lines(card) == ["done \(enable)"])
        #expect(footer(card) == "Enabled at 3:46\u{202F}AM.")
        #expect(card.commands?.footer?.outputToggle == .hidden)
        #expect(card.commands?.footer?.button == nil)
    }

    /// The recheck finds the plugin installed but disabled: the next step's
    /// box replaces the run, so the card offers Enable at once.
    @Test func aSucceededInstallGivesWayToTheEnableStep() {
        let card = card(claudeCode(.disabled(version: "0.4.0")), run: run(.succeeded(at: succeededAt), [
            (marketplace, .succeeded, "$ \(marketplace)"), (install, .succeeded, "$ \(install)"),
        ]))
        #expect(lines(card) == ["1 \(enable)"])
        #expect(footer(card) == "Runs this command in your login shell.")
        #expect(button(card) == "Enable (enabled) / Enable subspace: runs \(enable)")
        #expect(card.commands?.footer?.button?.kind == .enable)
        #expect(card.commands?.footer?.outputToggle == nil)
        #expect(card.commands?.inApp == ClaudeCodeSubspace.commands.enableInApp)
        #expect(card.runPlan?.kind == .enable)
        #expect(pill(card) == "Disabled (triangle)")
    }

    /// Until the recheck the success triggered comes back, the status still
    /// shows the state before the run; the run stays rather than offering
    /// the same step again for a moment.
    @Test func aSucceededInstallStaysWhileTheStatusStillShowsItsStep() {
        let card = card(claudeCode(.notInstalled), run: run(.succeeded(at: succeededAt), [
            (marketplace, .succeeded, "$ \(marketplace)"), (install, .succeeded, "$ \(install)"),
        ]))
        #expect(lines(card) == ["done \(marketplace)", "done \(install)"])
        #expect(footer(card) == "Installed at 3:46\u{202F}AM.")
        #expect(card.commands?.footer?.button == nil)
        #expect(card.commands?.inApp == [])
    }

    @Test func aSucceededEnableGivesWayToTheInstallStep() {
        let card = card(claudeCode(.notInstalled), run: run(.succeeded(at: succeededAt), [
            (enable, .succeeded, "$ \(enable)"),
        ], kind: .enable))
        #expect(lines(card) == ["1 \(marketplace)", "2 \(install)"])
        #expect(card.commands?.footer?.button?.kind == .install)
        #expect(card.commands?.inApp == ClaudeCodeSubspace.commands.installInApp)
    }

    // MARK: - Failed

    @Test func aFailedInstallShowsTheFailedOutputAndOffersTryAgain() {
        let card = card(claudeCode(.notInstalled), run: run(.failed(line: 1), [
            (marketplace, .succeeded, "$ \(marketplace)\nAdded."), (install, .failed, "$ \(install)\nfatal: unable to access"),
        ]), outputShown: true)
        #expect(lines(card) == ["done \(marketplace)", "failed \(install)\n$ \(install)\nfatal: unable to access"])
        #expect(footer(card) == "! Installation failed. subspace is downloaded from GitHub; check your connection, then try again.")
        #expect(button(card) == "Try Again (enabled) / Try again: runs \(install)")
        #expect(card.commands?.footer?.button?.kind == .tryAgain)
        #expect(card.commands?.footer?.outputToggle == nil)
        #expect(card.commands?.inApp == ClaudeCodeSubspace.commands.installInApp)
        #expect(pill(card) == "Failed (circleX)")
        #expect(card.statusMark == SourceStatusMark(shape: .circleX, role: .danger))
    }

    @Test func aFailedFirstLineLeavesTheRestToDo() {
        let card = card(claudeCode(.notInstalled), run: run(.failed(line: 0), [
            (marketplace, .failed, "$ \(marketplace)\nno network"), (install, .pending, nil),
        ]))
        #expect(lines(card) == ["failed \(marketplace)\n$ \(marketplace)\nno network", "todo \(install)"])
        #expect(button(card) == "Try Again (enabled) / Try again: runs \(marketplace)")
    }

    @Test func aFailedEnable() {
        let card = card(claudeCode(.disabled(version: "0.4.0")), run: run(.failed(line: 0), [
            (enable, .failed, "$ \(enable)\nError"),
        ], kind: .enable))
        #expect(lines(card) == ["failed \(enable)\n$ \(enable)\nError"])
        #expect(footer(card) == "! Enabling failed. Check the output, then try again.")
        #expect(button(card) == "Try Again (enabled) / Try again: runs \(enable)")
        #expect(card.commands?.inApp == ClaudeCodeSubspace.commands.enableInApp)
        #expect(pill(card) == "Failed (circleX)")
    }

    /// Fixed by hand while the window was open: the recheck wins over the
    /// failure, the run's lines and the failed output stay until the window closes.
    @Test(arguments: [nil, now.addingTimeInterval(-60)] as [Date?])
    func aFailedRunGivesWayOnceTheRecheckFindsThePluginEnabled(lastSessionStartAt: Date?) {
        let card = card(claudeCode(.enabled(version: "0.4.0"), lastSessionStartAt: lastSessionStartAt), run: run(.failed(line: 1), [
            (marketplace, .succeeded, "$ \(marketplace)\nAdded."), (install, .failed, "$ \(install)\nfatal: unable to access"),
        ]))
        #expect(pill(card) == (lastSessionStartAt == nil ? "Waiting for a session (ringWithDot)" : "Connected (dot)"))
        #expect(lines(card) == ["done \(marketplace)", "failed \(install)\n$ \(install)\nfatal: unable to access"])
        #expect(card.commands?.footer == nil)
        #expect(card.commands?.inApp == [])
        #expect(card.runPlan == nil)
    }

    @Test func aFailedInstallStaysWhileTheRecheckStillFindsItNotInstalled() {
        let card = card(claudeCode(.notInstalled), run: run(.failed(line: 1), [
            (marketplace, .succeeded, "$ \(marketplace)\nAdded."), (install, .failed, "$ \(install)\nfatal: unable to access"),
        ]))
        #expect(pill(card) == "Failed (circleX)")
        #expect(lines(card) == ["done \(marketplace)", "failed \(install)\n$ \(install)\nfatal: unable to access"])
        #expect(footer(card) == "! Installation failed. subspace is downloaded from GitHub; check your connection, then try again.")
        #expect(button(card) == "Try Again (enabled) / Try again: runs \(install)")
        #expect(card.commands?.inApp == ClaudeCodeSubspace.commands.installInApp)
    }

    /// The install got through after all (its failing line reported an error
    /// once the plugin was in): the next step replaces the failure.
    @Test func aFailedInstallGivesWayToTheEnableStep() {
        let card = card(claudeCode(.disabled(version: "0.4.0")), run: run(.failed(line: 1), [
            (marketplace, .succeeded, "$ \(marketplace)\nAdded."), (install, .failed, "$ \(install)\nfatal: unable to access"),
        ]))
        #expect(pill(card) == "Disabled (triangle)")
        #expect(lines(card) == ["1 \(enable)"])
        #expect(footer(card) == "Runs this command in your login shell.")
        #expect(button(card) == "Enable (enabled) / Enable subspace: runs \(enable)")
        #expect(card.commands?.footer?.button?.kind == .enable)
        #expect(card.commands?.inApp == ClaudeCodeSubspace.commands.enableInApp)
        #expect(card.runPlan?.kind == .enable)
    }

    // MARK: - CLI gone

    /// No run without a found CLI: once the recheck no longer
    /// finds it, a finished run gives way to the commands to copy.
    @Test(arguments: [
        SetupCommandRun.Phase.failed(line: 1),
        .succeeded(at: succeededAt),
    ])
    func aFinishedInstallGivesWayOnceTheRecheckFindsNoCLI(phase: SetupCommandRun.Phase) throws {
        let failed = if case .failed = phase { true } else { false }
        let card = card(claudeCode(.notInstalled, cli: .notFound), run: run(phase, [
            (marketplace, .succeeded, "$ \(marketplace)\nAdded."),
            (install, failed ? .failed : .succeeded, "$ \(install)\nfatal: unable to access"),
        ]))
        #expect(card.state == .notFound)
        #expect(pill(card) == "Not found (hollowRing)")
        let commands = try #require(card.commands)
        #expect(lines(card) == [marketplace, install])
        #expect(commands.footer == nil)
        #expect(commands.inApp == ClaudeCodeSubspace.commands.installInApp)
    }

    /// The plugin state is known from the tool's settings, the CLI is not.
    @Test func aFailedEnableGivesWayOnceTheRecheckFindsNoCLI() {
        let card = card(claudeCode(.disabled(version: "0.4.0"), cli: .notFound), run: run(.failed(line: 0), [
            (enable, .failed, "$ \(enable)\nError"),
        ], kind: .enable))
        #expect(pill(card) == "Disabled (triangle)")
        #expect(lines(card) == [enable])
        #expect(card.commands?.footer == nil)
    }

    /// A running run can't be stopped, so its progress still shows; its
    /// button is off while it runs anyway. Once it ends it gives way.
    @Test func aRunningInstallStillShowsWhenTheRecheckFindsNoCLI() {
        let card = card(claudeCode(.notInstalled, cli: .notFound), run: run(.running(line: 1), [
            (marketplace, .succeeded, "$ \(marketplace)"), (install, .running, nil),
        ]))
        #expect(lines(card) == ["done \(marketplace)", "running \(install)"])
        #expect(footer(card) == "Installing subspace…")
        #expect(button(card) == "Install (disabled) / Install, running")
        #expect(pill(card) == "Not found (hollowRing)")
    }

    // MARK: - Codex

    private static let codexMarketplace = "codex plugin marketplace add we-are-the-borg/subspace-codex"
    private static let codexInstall = "codex plugin add subspace@subspace"
    private static let codexHooks = "subspace adds hooks that run in every Codex session."

    @Test func codexNotInstalledOffersInstall() throws {
        let card = card(codex(.notInstalled))
        #expect(lines(card) == ["1 \(Self.codexMarketplace)", "2 \(Self.codexInstall)"])
        #expect(footer(card) == "Runs both commands in your login shell. \(Self.codexHooks)")
        #expect(button(card) == "Install (enabled) / Install subspace for Codex: runs \(Self.codexMarketplace), then \(Self.codexInstall)")
        #expect(card.commands?.footer?.link?.kind == .source)
        #expect(card.commands?.footer?.link?.url == URL(string: "https://github.com/we-are-the-borg/subspace-codex"))
        let plan = try #require(card.runPlan)
        #expect(plan.lines == [Self.codexMarketplace, Self.codexInstall])
        #expect(plan.programName == "codex")
        #expect(plan.programPath == "/opt/homebrew/bin/codex")
    }

    @Test func codexRunningOnTheMarketplace() {
        let card = card(codex(.notInstalled), run: run(.running(line: 0), [
            (Self.codexMarketplace, .running, nil), (Self.codexInstall, .pending, nil),
        ]))
        #expect(lines(card) == ["running \(Self.codexMarketplace)", "todo \(Self.codexInstall)"])
        #expect(footer(card) == "Adding the marketplace…")
        #expect(button(card) == "Install (disabled) / Install, running")
    }

    @Test func codexSucceededInstall() {
        let card = card(codex(.enabled(version: "0.4.0")), run: run(.succeeded(at: succeededAt), [
            (Self.codexMarketplace, .succeeded, "$ \(Self.codexMarketplace)"), (Self.codexInstall, .succeeded, "$ \(Self.codexInstall)"),
        ]))
        #expect(lines(card) == ["done \(Self.codexMarketplace)", "done \(Self.codexInstall)"])
        #expect(footer(card) == "Installed at 3:46\u{202F}AM.")
        #expect(card.commands?.footer?.outputToggle == .hidden)
        #expect(pill(card) == "Waiting for a session (ringWithDot)")
    }

    /// Codex has no enable lines, so a disabled plugin has no plan: nothing
    /// keeps a finished install, and the card is the one without a run.
    @Test(arguments: [
        SetupCommandRun.Phase.failed(line: 1),
        .succeeded(at: succeededAt),
    ])
    func aFinishedCodexInstallGivesWayOnceTheRecheckFindsThePluginDisabled(phase: SetupCommandRun.Phase) {
        let failed = if case .failed = phase { true } else { false }
        let status = codex(.disabled(version: "0.4.0"))
        let withoutRun = card(status)
        let card = card(status, run: run(phase, [
            (Self.codexMarketplace, .succeeded, "$ \(Self.codexMarketplace)"),
            (Self.codexInstall, failed ? .failed : .succeeded, "$ \(Self.codexInstall)\nError"),
        ]))
        #expect(card == withoutRun)
        #expect(pill(card) == "Disabled (triangle)")
        #expect(card.commands == nil)
        #expect(card.runPlan == nil)
    }

    @Test func codexNotFoundIsOnlyCopied() throws {
        let card = card(codex(.notInstalled, cli: .notFound))
        #expect(card.state == .notFound)
        #expect(card.runPlan == nil)
        let commands = try #require(card.commands)
        #expect(commands.terminal == [Self.codexMarketplace, Self.codexInstall])
        #expect(commands.lines.allSatisfy { $0.slot == nil })
        #expect(commands.footer == nil)
        #expect(pill(card) == "Not found (hollowRing)")
    }

    /// Codex has no command to enable a plugin, so there is nothing to run.
    @Test func codexDisabledHasNoButton() {
        let card = card(codex(.disabled(version: "0.4.0")))
        #expect(card.runPlan == nil)
        #expect(card.commands == nil)
    }

    /// Codex holds plugin hooks back until they are approved (subspace contract §11).
    @Test func codexWaitingAsksToApproveTheHooks() {
        let card = card(codex(.enabled(version: "0.4.0")))
        #expect(card.steps.last?.detail.map(en) == "Start a new Codex session, then approve subspace’s hooks with /hooks.")
    }

    @Test func claudeCodeWaitingKeepsTheGenericDetail() {
        let card = card(claudeCode(.enabled(version: "0.4.0")))
        #expect(card.steps.last?.detail.map(en) == "Start a new Claude Code session. Sessions that were already running pick up subspace after a restart.")
    }
}

@Suite struct SetupWindowRunTests {
    @Test func eachCardGetsItsOwnRunAndOutputToggle() {
        let snapshot = run(.succeeded(at: succeededAt), [(enable, .succeeded, "$ \(enable)")], kind: .enable)
        let window = SetupWindowModel(
            integrations: [claudeCode(.disabled(version: "0.4.0")), codex(.notInstalled)],
            runs: ["claude-code": snapshot],
            outputShown: ["claude-code"],
            now: now, home: home, timeZone: gmt
        )
        #expect(window.cards[0] == card(claudeCode(.disabled(version: "0.4.0")), run: snapshot, outputShown: true))
        #expect(window.cards[1] == card(codex(.notInstalled)))
    }
}

/// Line counts no adapter has today, through the catalog's plural variants.
@Suite struct SetupCardLineCountTests {
    private func tool(_ plugin: IntegrationStatus.Plugin, install: [String] = [], enable: [String] = [], marketplaceAdded: Bool? = nil) -> IntegrationStatus {
        var status = integration(plugin)
        status.marketplaceAdded = marketplaceAdded
        status.commands = SetupCommands(
            install: install, installInApp: [], enable: enable, enableInApp: [],
            marketplaceLine: install.first
        )
        return status
    }

    private let toolHooks = "subspace adds hooks that run in every Test Tool session."

    @Test func aSingleInstallLine() {
        let card = card(tool(.notInstalled, install: ["tt add"]))
        #expect(footer(card) == "Runs 1 command in your login shell. \(toolHooks)")
        #expect(button(card) == "Install (enabled) / Install subspace for Test Tool: runs tt add")
    }

    @Test func threeInstallLines() {
        let card = card(tool(.notInstalled, install: ["tt a", "tt b", "tt c"]))
        #expect(lines(card) == ["1 tt a", "2 tt b", "3 tt c"])
        #expect(footer(card) == "Runs 3 commands in your login shell. \(toolHooks)")
        #expect(button(card) == "Install (enabled) / Install subspace for Test Tool: runs tt a, tt b, then tt c")
    }

    @Test func twoLinesLeftAfterTheMarketplace() {
        let card = card(tool(.notInstalled, install: ["tt a", "tt b", "tt c"], marketplaceAdded: true))
        #expect(lines(card) == ["done tt a [Already added]", "1 tt b", "2 tt c"])
        #expect(footer(card) == "The marketplace is already there. Runs 2 commands in your login shell. \(toolHooks)")
    }

    @Test func twoEnableLines() {
        let card = card(tool(.disabled(version: nil), enable: ["tt on", "tt reload"]))
        #expect(footer(card) == "Runs 2 commands in your login shell.")
        #expect(button(card) == "Enable (enabled) / Enable subspace: runs tt on, then tt reload")
    }

    /// The made-up tool keeps the general advice for its first session.
    @Test func withoutAHintTheWaitingDetailIsGeneral() {
        let card = card(integration(.enabled(version: nil)))
        #expect(card.steps.last?.detail.map(en) == "Start a new Test Tool session. Sessions that were already running pick up subspace after a restart.")
    }
}
