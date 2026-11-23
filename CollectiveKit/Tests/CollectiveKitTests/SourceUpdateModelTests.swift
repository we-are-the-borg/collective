import Foundation
import Testing
@testable import CollectiveKit

// The Update group of a source's settings pane, with the adapters' real lines.

private let gmt = TimeZone(identifier: "GMT")!
/// 03:46 GMT; "h:mm a" in English puts a narrow no-break space before "AM".
private let succeededAt = Date(timeIntervalSince1970: 13_560)

private let marketplaceUpdate = "claude plugin marketplace update subspace"
private let pluginUpdate = "claude plugin update subspace@subspace --scope user"
private let codexUpgrade = "codex plugin marketplace upgrade subspace"
private let codexAdd = "codex plugin add subspace@subspace"
private let codexHint = "Start a new Codex session, then approve subspace’s changed hooks with /hooks."

private func version(_ text: String) -> SubspaceVersion { SubspaceVersion(text)! }

private func claudeCode(
    _ plugin: IntegrationStatus.Plugin = .enabled(version: "1.0.1"),
    cli: IntegrationStatus.CLI = .found(path: "/Users/user/.local/bin/claude", version: "2.1.285"),
    lastSessionStartAt: Date? = Date(timeIntervalSince1970: 1),
    commands: SetupCommands = ClaudeCodeSubspace.commands
) -> IntegrationStatus {
    IntegrationStatus(
        source: "claude-code", toolName: "Claude Code", cliName: "claude", cli: cli, plugin: plugin,
        lastSessionStartAt: lastSessionStartAt, commands: commands
    )
}

private func codex(_ plugin: IntegrationStatus.Plugin = .enabled(version: "1.0.1")) -> IntegrationStatus {
    IntegrationStatus(
        source: "codex", toolName: "Codex", cliName: "codex", cli: .found(path: "/opt/homebrew/bin/codex", version: "0.160.0"),
        plugin: plugin, lastSessionStartAt: Date(timeIntervalSince1970: 1), commands: CodexSubspace.commands
    )
}

private let available = UpdateAvailability.available(installed: version("1.0.1"), latest: version("1.3.0"))

private func model(
    _ status: IntegrationStatus,
    _ availability: UpdateAvailability = available,
    run: SetupCommandRun.Snapshot? = nil,
    outputShown: Bool = false,
    checksForUpdates: Bool = true,
    checkedAt: Date? = nil,
    now: Date = succeededAt
) -> SourceUpdateModel? {
    SourceUpdateModel(status, checkedAt: checkedAt, availability: availability, run: run, outputShown: outputShown,
                      checksForUpdates: checksForUpdates, now: now, timeZone: gmt)
}

/// A probe that started after the run succeeded.
private let afterSuccess = succeededAt.addingTimeInterval(1)

private typealias RunLine = SetupCommandRun.Line

private func run(_ phase: SetupCommandRun.Phase, _ lines: [(String, RunLine.State, String?)],
                 from: String = "1.0.1", to: String = "1.3.0") -> SetupCommandRun.Snapshot {
    SetupCommandRun.Snapshot(kind: .update(from: version(from), to: version(to)),
                             lines: lines.map { RunLine(command: $0.0, state: $0.1, output: $0.2) }, phase: phase)
}

private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

/// Lines as "slot command", output on lines of its own under them.
private func lines(_ model: SourceUpdateModel?) -> [String] {
    (model?.commands?.lines ?? []).map { line in
        let slot = switch line.slot {
        case nil: ""
        case .number(let number)?: "\(number) "
        case .done?: "done "
        case .running?: "running "
        case .todo?: "todo "
        case .failed?: "failed "
        }
        return slot + line.command + (line.output.map { "\n" + $0 } ?? "")
    }
}

/// The footer's text, with "! " in front when it warns.
private func footer(_ model: SourceUpdateModel?) -> String? {
    model?.commands?.footer.map { footer in
        (footer.isWarning ? "! " : "") + en(footer.text)
    }
}

/// "Title (enabled) / accessibility label"
private func button(_ model: SourceUpdateModel?) -> String? {
    model?.commands?.footer?.button.map { button in
        "\(en(button.title)) (\(button.isEnabled ? "enabled" : "disabled")) / \(en(button.accessibilityLabel))"
    }
}

private func header(_ model: SourceUpdateModel?) -> String? {
    model.map { model in
        "\(model.statusMark.shape): \(en(model.title))" + (model.subtitle.map { " | " + en($0) } ?? "") + (model.text.map { " | " + en($0) } ?? "")
    }
}

@Suite struct SourceUpdateModelTests {
    @Test func anAvailableUpdateNumbersTheAdapterLinesAndOffersUpdate() throws {
        let model = try #require(model(claudeCode()))
        #expect(model.state == .available)
        #expect(header(model) == "circleArrowUp: subspace 1.3.0 is available | You have 1.0.1")
        #expect(lines(model) == ["1 \(marketplaceUpdate)", "2 \(pluginUpdate)"])
        #expect(footer(model) == "Runs both commands in your login shell. Restart running sessions afterwards.")
        #expect(button(model) == "Update (enabled) / Update subspace: runs \(marketplaceUpdate), then \(pluginUpdate)")
        #expect(model.commands?.footer?.button?.kind == .update)
        #expect(model.commands?.footer?.link?.kind == .changes)
        #expect(model.commands?.footer?.link.map { en($0.title) } == "View changes on GitHub ↗")
        #expect(model.commands?.footer?.link?.url
            == URL(string: "https://github.com/we-are-the-borg/subspace/compare/claude-code-1.0.1...claude-code-1.3.0"))
        #expect(model.commands?.footer?.outputToggle == nil)
        #expect(model.commands?.inApp == [])
    }

    @Test func theUpdatePlanRunsTheAdapterLinesWithTheFoundCLI() throws {
        let plan = try #require(model(claudeCode())?.runPlan)
        #expect(plan.kind == .update(from: version("1.0.1"), to: version("1.3.0")))
        #expect(plan.lines == [marketplaceUpdate, pluginUpdate])
        #expect(plan.skipping == [])
        #expect(plan.cliName == "claude")
        #expect(plan.cliPath == "/Users/user/.local/bin/claude")
    }

    @Test func codexAsksToApproveTheChangedHooksInsteadOfRestarting() {
        let model = model(codex())
        #expect(lines(model) == ["1 \(codexUpgrade)", "2 \(codexAdd)"])
        #expect(footer(model) == "Runs both commands in your login shell. \(codexHint)")
        #expect(model?.commands?.footer?.link?.url
            == URL(string: "https://github.com/we-are-the-borg/subspace/compare/codex-1.0.1...codex-1.3.0"))
    }

    @Test func aRunningUpdateMarksItsLinesAndDisablesTheButton() {
        let model = model(claudeCode(), run: run(.running(line: 1), [
            (marketplaceUpdate, .succeeded, "$ \(marketplaceUpdate)"), (pluginUpdate, .running, nil),
        ]))
        #expect(model?.state == .running)
        #expect(header(model) == "haloDot: Updating to 1.3.0… | You have 1.0.1")
        #expect(lines(model) == ["done \(marketplaceUpdate)", "running \(pluginUpdate)"])
        #expect(footer(model) == "Updating subspace…")
        #expect(button(model) == "Update (disabled) / Update, running")
        #expect(model?.commands?.footer?.link == nil)
        #expect(model?.runPlan == nil)
    }

    @Test func aFailedUpdateShowsTheFailedOutputAndOffersTryAgain() {
        let model = model(claudeCode(), run: run(.failed(line: 1), [
            (marketplaceUpdate, .succeeded, "$ \(marketplaceUpdate)"), (pluginUpdate, .failed, "$ \(pluginUpdate)\nNetwork down"),
        ]))
        #expect(model?.state == .failed)
        #expect(header(model) == "circleX: Update to 1.3.0 failed | You still have 1.0.1")
        #expect(lines(model) == ["done \(marketplaceUpdate)", "failed \(pluginUpdate)\n$ \(pluginUpdate)\nNetwork down"])
        #expect(footer(model) == "! Update failed. subspace is downloaded from GitHub; check your connection, then try again.")
        #expect(button(model) == "Try Again (enabled) / Try again: runs \(pluginUpdate)")
        #expect(model?.commands?.footer?.button?.kind == .tryAgain)
    }

    private let succeeded = run(.succeeded(at: succeededAt), [
        (marketplaceUpdate, .succeeded, "$ \(marketplaceUpdate)"), (pluginUpdate, .succeeded, "$ \(pluginUpdate)\nUpdated"),
    ])

    /// The recheck after the run reports the new version and nothing left to
    /// update; the group stays with the run until the windows close.
    @Test func aSucceededUpdateStaysAfterTheRecheckWithItsOutputFolded() {
        let model = model(claudeCode(.enabled(version: "1.3.0")), .upToDate, run: succeeded, checkedAt: afterSuccess)
        #expect(model?.state == .updated)
        #expect(header(model) == "dot: Updated to 1.3.0")
        #expect(lines(model) == ["done \(marketplaceUpdate)", "done \(pluginUpdate)"])
        #expect(footer(model) == "Updated at 3:46\u{202F}AM. Restart running sessions to use 1.3.0.")
        #expect(model?.commands?.footer?.outputToggle == .hidden)
        #expect(model?.commands?.footer?.button == nil)
    }

    /// The marketplace may have known a newer release than the lookup.
    @Test func aSucceededUpdateNamesTheVersionTheRecheckFound() {
        #expect(header(model(claudeCode(.enabled(version: "1.4.0")), .upToDate, run: succeeded, checkedAt: afterSuccess))
            == "dot: Updated to 1.4.0")
    }

    /// The commands' exit codes don't prove the update; until a probe taken
    /// after the success reports, the check is still part of the update.
    @Test func aSucceededUpdateKeepsRunningUntilAProbeAfterItReports() {
        let model = model(claudeCode(), run: succeeded)
        #expect(model?.state == .running)
        #expect(header(model) == "haloDot: Updating to 1.3.0… | You have 1.0.1")
        #expect(lines(model) == ["done \(marketplaceUpdate)", "done \(pluginUpdate)"])
        #expect(footer(model) == "Updating subspace…")
        #expect(button(model) == "Update (disabled) / Update, running")
    }

    private let codexSucceeded = run(.succeeded(at: succeededAt), [
        (codexUpgrade, .succeeded, "$ \(codexUpgrade)\nalready up to date"), (codexAdd, .succeeded, "$ \(codexAdd)"),
    ], to: "1.1.0")

    /// The visual check of 05.11.2026: every command exited 0, but the
    /// marketplace said "already up to date" and Codex kept 1.0.1.
    @Test func aProbeAfterTheSuccessStillReportingTheOldVersionFailsTheUpdate() throws {
        let model = try #require(model(codex(), run: codexSucceeded, checkedAt: afterSuccess))
        #expect(model.state == .failed)
        #expect(header(model) == "circleX: Update to 1.1.0 failed | You still have 1.0.1")
        #expect(lines(model) == ["done \(codexUpgrade)", "done \(codexAdd)"])
        #expect(footer(model) == "! The commands finished, but Codex still reports 1.0.1.")
        #expect(button(model) == "Try Again (enabled) / Try again: runs \(codexUpgrade), then \(codexAdd)")
        #expect(model.commands?.footer?.button?.kind == .tryAgain)
        #expect(model.commands?.footer?.outputToggle == .hidden)
    }

    /// Codex's plugin list can time out right after the update; that says nothing either way.
    @Test func anUnknownPluginStateAfterTheSuccessKeepsItRunning() {
        let model = model(codex(.unknown), run: codexSucceeded, checkedAt: afterSuccess, now: succeededAt.addingTimeInterval(29))
        #expect(model?.state == .running)
        #expect(footer(model) == "Updating subspace…")
    }

    /// The app keeps the last known state through a failed check; that
    /// state is the earlier check's, so it neither confirms nor refutes the run.
    @Test func aStateCarriedOverFromAnEarlierCheckKeepsItRunning() throws {
        let carried = codex(.unknown).keepingKnownPlugin(from: codex())
        #expect(carried.plugin == .enabled(version: "1.0.1"))
        let model = try #require(model(carried, run: codexSucceeded, checkedAt: afterSuccess, now: succeededAt.addingTimeInterval(29)))
        #expect(model.state == .running)
        #expect(footer(model) == "Updating subspace…")
    }

    @Test(arguments: [IntegrationStatus.Plugin.unknown, .enabled(version: "1.0.1")])
    func withoutAConfirmingProbeFor30SecondsTheUpdateFails(plugin: IntegrationStatus.Plugin) throws {
        // The 1.0.1 probe started before the success, so it doesn't count either.
        let checkedAt = plugin == .unknown ? afterSuccess : succeededAt.addingTimeInterval(-1)
        let model = try #require(model(codex(plugin), run: codexSucceeded, checkedAt: checkedAt, now: succeededAt.addingTimeInterval(30)))
        #expect(model.state == .failed)
        #expect(header(model) == "circleX: Update to 1.1.0 failed")
        #expect(footer(model) == "! The commands finished, but Codex doesn’t report the new version.")
        #expect(model.commands?.footer?.button?.kind == .tryAgain)
    }

    /// A probe running while the last command ran may have read the old plugin.
    @Test(arguments: [succeededAt.addingTimeInterval(-1), succeededAt])
    func aProbeFromBeforeTheSuccessNeverCounts(checkedAt: Date) {
        #expect(model(codex(), run: codexSucceeded, checkedAt: checkedAt)?.state == .running)
        #expect(model(codex(.enabled(version: "1.1.0")), .upToDate, run: codexSucceeded, checkedAt: checkedAt)?.state == .running)
    }

    @Test(arguments: [IntegrationStatus.Plugin.enabled(version: nil), .disabled(version: "unknown")])
    func anInstalledPluginWithoutAReadableVersionFailsTheUpdate(plugin: IntegrationStatus.Plugin) throws {
        let model = try #require(model(codex(plugin), run: codexSucceeded, checkedAt: afterSuccess))
        #expect(model.state == .failed)
        #expect(header(model) == "circleX: Update to 1.1.0 failed")
        #expect(footer(model) == "! The commands finished, but Codex doesn’t report the new version.")
    }

    // Pins the current behavior (green from the start): a plugin that vanished after the run is no confirmation either.
    @Test func aProbeAfterTheSuccessReportingNoPluginFailsTheUpdate() throws {
        let model = try #require(model(codex(.notInstalled), run: codexSucceeded, checkedAt: afterSuccess))
        #expect(model.state == .failed)
        #expect(header(model) == "circleX: Update to 1.1.0 failed")
        #expect(footer(model) == "! The commands finished, but Codex doesn’t report the new version.")
    }

    @Test func aProbeAfterTheSuccessReportingTheTargetConfirmsIt() {
        let model = model(codex(.enabled(version: "1.1.0")), .upToDate, run: codexSucceeded, checkedAt: afterSuccess)
        #expect(model?.state == .updated)
        #expect(header(model) == "dot: Updated to 1.1.0")
    }

    @Test func anUnconfirmedUpdateShowsItsOutputWhenAsked() {
        let model = model(codex(), run: codexSucceeded, outputShown: true, checkedAt: afterSuccess)
        #expect(lines(model) == ["done \(codexUpgrade)\n$ \(codexUpgrade)\nalready up to date", "done \(codexAdd)\n$ \(codexAdd)"])
        #expect(model?.commands?.footer?.outputToggle == .showing)
    }

    @Test func aSucceededUpdateShowsItsOutputWhenAsked() {
        let model = model(claudeCode(.enabled(version: "1.3.0")), .upToDate, run: succeeded, outputShown: true, checkedAt: afterSuccess)
        #expect(lines(model) == ["done \(marketplaceUpdate)\n$ \(marketplaceUpdate)", "done \(pluginUpdate)\n$ \(pluginUpdate)\nUpdated"])
        #expect(model?.commands?.footer?.outputToggle == .showing)
    }

    @Test func aSucceededCodexUpdateAsksToApproveTheChangedHooks() {
        let model = model(codex(.enabled(version: "1.3.0")), .upToDate, run: run(.succeeded(at: succeededAt), [
            (codexUpgrade, .succeeded, nil), (codexAdd, .succeeded, nil),
        ]), checkedAt: afterSuccess)
        #expect(footer(model) == "Updated at 3:46\u{202F}AM. \(codexHint)")
    }

    /// No adapter sets a minimum yet, so the test brings its own release.
    private func requiring(_ minimum: String) -> SetupCommands {
        var commands = ClaudeCodeSubspace.commands
        commands.release = SubspaceRelease(tagsRepository: "we-are-the-borg/subspace-claude-code", tagPrefix: "claude-code-",
                                           minimumVersion: minimum, changesRepository: "we-are-the-borg/subspace")
        return commands
    }

    @Test func aRequiredUpdateWarnsAndOffersUpdate() throws {
        let status = claudeCode(commands: requiring("1.2.0"))
        let required = UpdateAvailability(installed: "1.0.1", latest: version("1.3.0"), minimum: version("1.2.0"))
        let model = try #require(model(status, required))
        #expect(model.state == .required)
        #expect(header(model)
            == "triangle: The Collective needs subspace 1.2.0 or later | You have 1.0.1 | Until you update, some events from Claude Code sessions won’t show up here.")
        #expect(lines(model) == ["1 \(marketplaceUpdate)", "2 \(pluginUpdate)"])
        #expect(footer(model) == "Runs both commands in your login shell. Restart running sessions afterwards.")
        #expect(button(model) == "Update (enabled) / Update subspace: runs \(marketplaceUpdate), then \(pluginUpdate)")
        #expect(model.commands?.footer?.link?.url
            == URL(string: "https://github.com/we-are-the-borg/subspace/compare/claude-code-1.0.1...claude-code-1.3.0"))
        #expect(model.runPlan?.kind == .update(from: version("1.0.1"), to: version("1.3.0")))
    }

    /// Off, the app asks GitHub nothing, yet knows its own minimum.
    @Test func aRequiredUpdateShowsWithTheSwitchOffAndUpdatesToTheMinimum() {
        let status = claudeCode(commands: requiring("1.2.0"))
        let required = UpdateAvailability(installed: "1.0.1", latest: nil, minimum: version("1.2.0"))
        let model = model(status, required, checksForUpdates: false)
        #expect(model?.state == .required)
        #expect(model?.runPlan?.kind == .update(from: version("1.0.1"), to: version("1.2.0")))
        #expect(model?.commands?.footer?.link?.url
            == URL(string: "https://github.com/we-are-the-borg/subspace/compare/claude-code-1.0.1...claude-code-1.2.0"))
    }

    @Test func anAvailableUpdateHidesWithTheSwitchOff() {
        #expect(model(claudeCode(), checksForUpdates: false) == nil)
    }

    /// The user started the run, so its result stays until the windows close
    /// even after the switch goes off; only a group without a run follows it.
    @Test func aFailedUpdateStaysWithTheSwitchOff() {
        let failed = run(.failed(line: 1), [(marketplaceUpdate, .succeeded, nil), (pluginUpdate, .failed, "Network down")])
        #expect(model(claudeCode(), run: failed, checksForUpdates: false)?.state == .failed)
    }

    @Test func aSucceededUpdateStaysWithTheSwitchOff() {
        #expect(model(claudeCode(.enabled(version: "1.3.0")), .upToDate, run: succeeded, checksForUpdates: false, checkedAt: afterSuccess)?.state
            == .updated)
    }

    @Test func nothingWhileUpToDate() {
        #expect(model(claudeCode(), .upToDate) == nil)
    }

    @Test(arguments: [IntegrationStatus.Plugin.enabled(version: nil), .disabled(version: nil), .enabled(version: "unknown")])
    func nothingWithoutAReadableVersion(plugin: IntegrationStatus.Plugin) {
        #expect(model(claudeCode(plugin)) == nil)
    }

    @Test(arguments: [
        claudeCode(.enabled(version: "1.0.1")),
        claudeCode(.enabled(version: "1.0.1"), lastSessionStartAt: nil),
        claudeCode(.disabled(version: "1.0.1")),
    ])
    func connectedWaitingAndDisabledSourcesShowIt(status: IntegrationStatus) {
        #expect(model(status)?.state == .available)
    }

    @Test(arguments: [
        claudeCode(.notInstalled),
        claudeCode(.unknown),
        claudeCode(.notInstalled, cli: .notFound),
    ])
    func notSetUpOrNotFoundSourcesShowNothing(status: IntegrationStatus) {
        #expect(model(status) == nil)
    }

    /// The plugin read from the tool's settings without its CLI: nothing can
    /// run, so the lines are only there to copy, as on the setup card.
    @Test func withoutTheCLITheLinesAreOnlyCopied() {
        let model = model(claudeCode(cli: .notFound))
        #expect(model?.state == .available)
        #expect(lines(model) == [marketplaceUpdate, pluginUpdate])
        #expect(model?.commands?.footer == nil)
        #expect(model?.runPlan == nil)
    }

    /// An idle run was made but never started; the group is the one without it.
    @Test func anIdleRunChangesNothing() {
        let idle = run(.idle, [(marketplaceUpdate, .pending, nil), (pluginUpdate, .pending, nil)])
        #expect(model(claudeCode(), run: idle) == model(claudeCode()))
    }

    /// An install run belongs to the setup card, never to the update group.
    @Test func anInstallRunIsNotTheGroups() {
        let install = SetupCommandRun.Snapshot(kind: .install, lines: [RunLine(command: "claude x", state: .running)], phase: .running(line: 0))
        #expect(model(claudeCode(), run: install) == model(claudeCode()))
    }

    /// The sources' status forms in their roles: a running
    /// update is a halo, no spinner; updated is connected again.
    @Test func eachStateTakesTheSourceStatusFormInItsRole() {
        let required = UpdateAvailability(installed: "1.0.1", latest: version("1.3.0"), minimum: version("1.2.0"))
        let failed = run(.failed(line: 1), [(marketplaceUpdate, .succeeded, nil), (pluginUpdate, .failed, "Network down")])
        let running = run(.running(line: 0), [(marketplaceUpdate, .running, nil), (pluginUpdate, .pending, nil)])
        let marks = [
            model(claudeCode()),
            model(claudeCode(), run: running),
            model(claudeCode(), run: failed),
            model(claudeCode(.enabled(version: "1.3.0")), .upToDate, run: succeeded, checkedAt: afterSuccess),
            model(claudeCode(commands: requiring("1.2.0")), required),
        ].map { $0.map { "\($0.state) \($0.statusMark.shape) \($0.statusMark.role)" } }
        #expect(marks == [
            "available circleArrowUp info",
            "running haloDot info",
            "failed circleX danger",
            "updated dot success",
            "required triangle warning",
        ])
    }
}

@Suite struct SourceUpdateLineCountTests {
    private func tool(_ update: [String]) -> IntegrationStatus {
        IntegrationStatus(
            source: "test-tool", toolName: "Test Tool", cliName: "tt", cli: .found(path: "/usr/local/bin/tt", version: nil),
            plugin: .enabled(version: "1.0.1"), lastSessionStartAt: Date(timeIntervalSince1970: 1),
            commands: SetupCommands(install: [], installInApp: [], enable: [], enableInApp: [], update: update)
        )
    }

    @Test func oneLine() {
        let model = model(tool(["tt update"]))
        #expect(footer(model) == "Runs this command in your login shell. Restart running sessions afterwards.")
        #expect(button(model) == "Update (enabled) / Update subspace: runs tt update")
        // Without a release there is no comparison to link.
        #expect(model?.commands?.footer?.link == nil)
    }

    @Test func threeLines() {
        let model = model(tool(["tt a", "tt b", "tt c"]))
        #expect(lines(model) == ["1 tt a", "2 tt b", "3 tt c"])
        #expect(footer(model) == "Runs these 3 commands in your login shell. Restart running sessions afterwards.")
        #expect(button(model) == "Update (enabled) / Update subspace: runs tt a, tt b, then tt c")
    }

    /// An adapter without update lines has nothing to offer.
    @Test func noLinesNoGroup() {
        #expect(model(tool([])) == nil)
    }

    /// The status row still says an update is required; without lines there
    /// is no box and no button to put under a header.
    @Test func noLinesNoRequiredGroup() {
        var status = tool([])
        status.commands.release = SubspaceRelease(tagsRepository: "example/subspace-test-tool", tagPrefix: "test-tool-",
                                                  minimumVersion: "1.2.0", changesRepository: "example/subspace")
        let required = UpdateAvailability(installed: "1.0.1", latest: nil, minimum: version("1.2.0"))
        #expect(model(status, required, checksForUpdates: false) == nil)
        #expect(model(status, required) == nil)
    }
}
