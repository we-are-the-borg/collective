import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

private let now = Date(timeIntervalSince1970: 100_000)
private let home = "/Users/user"

private func card(_ status: IntegrationStatus, lastEventAt: Date? = nil) -> SetupCardModel {
    SetupCardModel(status, lastEventAt: lastEventAt, now: now, home: home)
}

private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

/// Steps as "symbol title / detail", so a whole list reads as one literal.
private func steps(_ card: SetupCardModel) -> [String] {
    card.steps.map { step in
        let detail = step.detail.map { " / " + en($0) } ?? ""
        return "\(step.symbol) \(en(step.title))\(detail)"
    }
}

private func pill(_ card: SetupCardModel) -> String? {
    card.pill.map { "\(en($0.text)) (\(card.statusMark.shape))" }
}

@Suite struct SetupCardModelTests {
    /// The restyled section header: a form in front, the status word in its role.
    /// Not installed has no word but keeps the hollow ring in the status column.
    @Test(arguments: [
        (IntegrationStatus.Plugin.notInstalled, IntegrationStatus.CLI.found(path: "/usr/local/bin/tt", version: "1.2.3"), Date?.none,
         SourceStatusShape.hollowRing, ThemeRole.textSubtle),
        (.disabled(version: "0.4.0"), .found(path: "/usr/local/bin/tt", version: "1.2.3"), nil, .triangle, .warning),
        (.enabled(version: "0.4.0"), .found(path: "/usr/local/bin/tt", version: "1.2.3"), nil, .ringWithDot, .info),
        (.enabled(version: "0.4.0"), .found(path: "/usr/local/bin/tt", version: "1.2.3"), Date(timeIntervalSince1970: 1), .dot, .success),
        (.notInstalled, .notFound, nil, .hollowRing, .textSubtle),
        (.unknown, .found(path: "/usr/local/bin/tt", version: "1.2.3"), nil, .hollowRing, .textSubtle),
    ])
    func statusMarkPerState(plugin: IntegrationStatus.Plugin, cli: IntegrationStatus.CLI, started: Date?,
                            shape: SourceStatusShape, role: ThemeRole) {
        let card = card(integration(plugin, cli: cli, lastSessionStartAt: started))
        #expect(card.statusMark == SourceStatusMark(shape: shape, role: role))
    }

    @Test func notInstalledOffersTheInstallCommandsOpen() throws {
        let status = integration(.notInstalled)
        let card = card(status)
        #expect(card.state == .notInstalled)
        #expect(card.title == "Test Tool")
        #expect(card.source == "test-tool")
        #expect(card.pill == nil)
        #expect(en(card.subtitle) == "/usr/local/bin/tt · 1.2.3")
        #expect(steps(card) == [
            "done Test Tool found",
            "open subspace installed",
            "open Plugin enabled",
            "open First session seen",
        ])
        #expect(card.note == nil)
        let commands = try #require(card.commands)
        #expect(commands.terminal == status.commands.install)
        #expect(commands.inApp == status.commands.installInApp)
    }

    /// The probe could not tell (a timed-out list) and no earlier check
    /// knew: like Settings before the first check, no claim and nothing to run.
    @Test func unknownPluginWithTheCLIFoundIsStillChecking() {
        let card = card(integration(.unknown))
        #expect(card.state == .checking)
        #expect(pill(card) == "Checking… (hollowRing)")
        #expect(en(card.subtitle) == "/usr/local/bin/tt · 1.2.3")
        #expect(card.steps.isEmpty)
        #expect(card.note == nil)
        #expect(card.commands == nil)
        #expect(card.runPlan == nil)
        #expect(card.update == nil)
    }

    @Test func disabledWithoutEnableCommandsShowsNoCommandBox() {
        var status = integration(.disabled(version: "0.4.0"))
        status.commands = SetupCommands(install: ["tt install"], installInApp: [], enable: [], enableInApp: [])
        #expect(card(status).commands == nil)
    }

    @Test func disabledWithOnlyInAppCommandsKeepsTheBox() {
        var status = integration(.disabled(version: "0.4.0"))
        status.commands = SetupCommands(install: [], installInApp: [], enable: [], enableInApp: ["/plugin enable x"])
        #expect(card(status).commands?.inApp == ["/plugin enable x"])
    }

    /// Every line gets its own Copy button, and a session takes pasted text as one input,
    /// so each entry must hold exactly one command.
    @Test func realClaudeCodeCommandsHoldOneCommandPerEntry() throws {
        for state in [IntegrationStatus.Plugin.notInstalled, .disabled(version: "0.4.0")] {
            var status = integration(state, source: "claude-code", toolName: "Claude Code")
            status.commands = ClaudeCodeSubspace.commands
            let commands = try #require(card(status).commands)
            #expect(!commands.terminal.isEmpty)
            #expect(!commands.inApp.isEmpty)
            for line in commands.terminal {
                #expect(!line.contains("\n"))
                #expect(line.components(separatedBy: "claude plugin").count == 2)
            }
            for line in commands.inApp {
                #expect(!line.contains("\n"))
                #expect(line.components(separatedBy: "/plugin").count == 2)
            }
        }
    }

    @Test func realCodexCommandsHoldOneCommandPerEntry() throws {
        var status = integration(.notInstalled, source: "codex", toolName: "Codex")
        status.commands = CodexSubspace.commands
        let commands = try #require(card(status).commands)
        #expect(commands.terminal.count == 2)
        for line in commands.terminal {
            #expect(!line.contains("\n"))
            #expect(line.components(separatedBy: "codex plugin").count == 2)
        }
    }

    @Test func disabledOffersTheEnableCommandsOpen() throws {
        let status = integration(.disabled(version: "0.4.0"))
        let card = card(status)
        #expect(card.state == .disabled)
        #expect(pill(card) == "Disabled (triangle)")
        #expect(steps(card) == [
            "done Test Tool found",
            "done subspace installed / 0.4.0 · user scope",
            "warning Plugin is disabled / subspace is switched off in Test Tool, so sessions you start from now on won’t report here.",
            "open First session seen",
        ])
        let commands = try #require(card.commands)
        #expect(commands.terminal == status.commands.enable)
        #expect(commands.inApp == status.commands.enableInApp)
    }

    @Test func disabledWithoutVersionNamesOnlyTheScope() {
        let card = card(integration(.disabled(version: nil)))
        #expect(steps(card)[1] == "done subspace installed / user scope")
    }

    @Test func enabledWithoutSessionWaits() {
        let card = card(integration(.enabled(version: "0.4.0")))
        #expect(card.state == .waiting)
        #expect(pill(card) == "Waiting for a session (ringWithDot)")
        #expect(steps(card) == [
            "done Test Tool found",
            "done subspace installed",
            "done Plugin enabled",
            "waiting Waiting for the first session / Start a new Test Tool session. Sessions that were already running pick up subspace after a restart.",
        ])
        #expect(card.commands == nil)
    }

    /// Enabled per the fallback read while the CLI is not on this Mac: nothing
    /// claims the CLI was found.
    @Test func waitingWithoutCLILeavesOutTheFoundStep() {
        let card = card(integration(.enabled(version: nil), cli: .notFound))
        #expect(card.state == .waiting)
        #expect(steps(card).first == "done subspace installed")
        #expect(steps(card).count == 3)
        #expect(en(card.subtitle) == "tt · not on this Mac")
    }

    @Test func enabledWithASessionIsReady() {
        let card = card(integration(.enabled(version: "0.4.0"), lastSessionStartAt: now.addingTimeInterval(-150)))
        #expect(card.state == .ready)
        #expect(pill(card) == "Connected (dot)")
        #expect(en(card.subtitle) == "subspace 0.4.0 · last session started 2 min ago")
        #expect(card.steps.isEmpty)
        #expect(card.note == nil)
        #expect(card.commands == nil)
    }

    @Test func readyWithoutVersionLeavesItOut() {
        let card = card(integration(.enabled(version: nil), lastSessionStartAt: now.addingTimeInterval(-5)))
        #expect(en(card.subtitle) == "subspace · last session started 5 s ago")
    }

    /// A reinstall makes the tool recreate its data folder, so subspace's record
    /// of a session start is gone until the next one; running sessions still
    /// deliver events.
    @Test func enabledWithEventsButNoSessionStartIsReady() {
        let card = card(integration(.enabled(version: "1.0.1")), lastEventAt: now.addingTimeInterval(-2))
        #expect(card.state == .ready)
        #expect(pill(card) == "Connected (dot)")
        #expect(en(card.subtitle) == "subspace 1.0.1 · last event 2 s ago")
        #expect(card.steps.isEmpty)
        #expect(card.commands == nil)
    }

    @Test func readyByEventsWithoutVersionLeavesItOut() {
        let card = card(integration(.enabled(version: nil)), lastEventAt: now.addingTimeInterval(-180))
        #expect(en(card.subtitle) == "subspace · last event 3 min ago")
    }

    @Test func aNewerEventOutranksTheSessionStart() {
        let status = integration(.enabled(version: "1.0.1"), lastSessionStartAt: now.addingTimeInterval(-600))
        #expect(en(card(status, lastEventAt: now.addingTimeInterval(-5)).subtitle) == "subspace 1.0.1 · last event 5 s ago")
    }

    @Test func aNewerSessionStartOutranksTheEvent() {
        let status = integration(.enabled(version: "1.0.1"), lastSessionStartAt: now.addingTimeInterval(-5))
        #expect(en(card(status, lastEventAt: now.addingTimeInterval(-600)).subtitle) == "subspace 1.0.1 · last session started 5 s ago")
    }

    /// Events only stand in for the session start; they never say the plugin is installed or enabled.
    @Test(arguments: [
        (IntegrationStatus.Plugin.notInstalled, IntegrationStatus.CLI.found(path: "/usr/local/bin/tt", version: "1.2.3"), SetupCardModel.State.notInstalled),
        (.unknown, .found(path: "/usr/local/bin/tt", version: "1.2.3"), .checking),
        (.disabled(version: "1.0.1"), .found(path: "/usr/local/bin/tt", version: "1.2.3"), .disabled),
        (.notInstalled, .notFound, .notFound),
    ])
    func eventsLeaveAPluginThatIsNotEnabledAlone(plugin: IntegrationStatus.Plugin, cli: IntegrationStatus.CLI, expected: SetupCardModel.State) {
        let status = integration(plugin, cli: cli)
        let withEvents = card(status, lastEventAt: now.addingTimeInterval(-2))
        #expect(withEvents.state == expected)
        #expect(withEvents == card(status))
    }

    @Test func notFoundExplainsWhereItLookedAndOffersTheCommands() throws {
        let status = integration(.notInstalled, cli: .notFound)
        let card = card(status)
        #expect(card.state == .notFound)
        #expect(pill(card) == "Not found (hollowRing)")
        #expect(en(card.subtitle) == "tt · not on this Mac")
        #expect(card.steps.isEmpty)
        #expect(card.note.map(en) == "The Collective looked in ~/.local/bin, /opt/homebrew/bin, and your login shell’s PATH. If you don’t use Test Tool, you can ignore this.")
        let commands = try #require(card.commands)
        #expect(commands.terminal == status.commands.install)
    }

    /// Disabled per the fallback read while the CLI is not on this Mac: the
    /// known plugin state wins, like the popover's warning, and nothing claims
    /// the CLI was found.
    @Test func disabledWithoutCLIStaysDisabled() throws {
        let status = integration(.disabled(version: "0.4.0"), cli: .notFound)
        let card = card(status)
        #expect(card.state == .disabled)
        #expect(pill(card) == "Disabled (triangle)")
        #expect(en(card.subtitle) == "tt · not on this Mac")
        #expect(steps(card) == [
            "done subspace installed / 0.4.0 · user scope",
            "warning Plugin is disabled / subspace is switched off in Test Tool, so sessions you start from now on won’t report here.",
            "open First session seen",
        ])
        #expect(card.note == nil)
        let commands = try #require(card.commands)
        #expect(commands.terminal == status.commands.enable)
        #expect(commands.inApp == status.commands.enableInApp)
    }

    @Test func unknownWithoutCLIIsNotFound() {
        #expect(card(integration(.unknown, cli: .notFound)).state == .notFound)
    }

    /// The popover's warning and the card never point at different commands.
    @Test(arguments: [
        IntegrationStatus.CLI.found(path: "/usr/local/bin/tt", version: "1.2.3"),
        .notFound,
    ], [
        IntegrationStatus.Plugin.notInstalled,
        .disabled(version: "0.4.0"),
        .enabled(version: "0.4.0"),
        .unknown,
    ])
    func cardCommandsAgreeWithTheConnectionStatus(cli: IntegrationStatus.CLI, plugin: IntegrationStatus.Plugin) {
        let status = integration(plugin, cli: cli)
        let commands = card(status).commands?.terminal
        switch ConnectionStatus(integrations: [status]) {
        case .disabled:
            #expect(commands == status.commands.enable)
        case .missing:
            #expect(commands == status.commands.install)
        case .ok:
            #expect(commands != status.commands.enable)
        }
    }

    /// The same with a path without the CLI: the warning names the card's
    /// lines, whether its program was found or not.
    @Test(arguments: [IntegrationStatus.CLI.found(path: "/usr/bin/fetch", version: nil), .notFound])
    func popoverWarningAgreesWithTheCardWithoutTheCLI(alternative: IntegrationStatus.CLI) throws {
        var status = integration(.notInstalled, cli: .notFound)
        status.commands.withoutCLI = SetupCommands.Alternative(program: "fetch", install: ["fetch clone https://example.com/subspace.git"])
        status.alternative = alternative
        let warning = try #require(WarningBlock(ConnectionStatus(integrations: [status])))
        #expect(warning.commands == ["fetch clone https://example.com/subspace.git"])
        #expect(warning.commands == card(status).commands?.terminal)
    }

    @Test(arguments: [IntegrationStatus.CLI.found(path: "/usr/local/bin/tt", version: "1.2.3"), .notFound])
    func popoverWarningAgreesWithTheCardWithoutAnAlternative(cli: IntegrationStatus.CLI) throws {
        let status = integration(.notInstalled, cli: cli)
        let warning = try #require(WarningBlock(ConnectionStatus(integrations: [status])))
        #expect(warning.commands == status.commands.install)
        #expect(warning.commands == card(status).commands?.terminal)
    }

    @Test func notFoundWithoutListedLocationsNamesOnlyThePath() {
        let card = card(integration(.notInstalled, cli: .notFound, searchedLocations: []))
        #expect(card.note.map(en) == "The Collective looked in your login shell’s PATH. If you don’t use Test Tool, you can ignore this.")
    }

    @Test func notFoundWithOneLocationHasNoCommaBeforeAnd() {
        let card = card(integration(.notInstalled, cli: .notFound, searchedLocations: ["~/.local/bin"]))
        #expect(card.note.map(en) == "The Collective looked in ~/.local/bin and your login shell’s PATH. If you don’t use Test Tool, you can ignore this.")
    }

    @Test func notFoundWithThreeLocationsListsThemWithSerialComma() {
        let card = card(integration(.notInstalled, cli: .notFound, searchedLocations: ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]))
        #expect(card.note.map(en) == "The Collective looked in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, and your login shell’s PATH. If you don’t use Test Tool, you can ignore this.")
    }

    @Test func subtitleAbbreviatesTheHomeFolder() {
        let found = card(integration(.notInstalled, cli: .found(path: "\(home)/.local/bin/tt", version: "1.2.3")))
        #expect(en(found.subtitle) == "~/.local/bin/tt · 1.2.3")
        // Only a whole path component counts as home.
        let sibling = card(integration(.notInstalled, cli: .found(path: "\(home)2/bin/tt", version: "1.2.3")))
        #expect(en(sibling.subtitle) == "\(home)2/bin/tt · 1.2.3")
    }

    @Test func subtitleWithoutVersionIsThePathAlone() {
        let card = card(integration(.notInstalled, cli: .found(path: "\(home)/bin/tt", version: nil)))
        #expect(en(card.subtitle) == "~/bin/tt")
    }
}

@Suite struct SetupWindowModelTests {
    @Test func oneCardPerIntegrationInOrder() {
        let window = SetupWindowModel(
            integrations: [integration(.notInstalled, source: "a"), integration(.disabled(version: nil), source: "b")],
            now: now
        )
        #expect(window.cards.map(\.source) == ["a", "b"])
    }

    private func button(
        _ integrations: [IntegrationStatus],
        runs: [SourceID: SetupCommandRun.Snapshot] = [:],
        lastEvents: [SourceID: Date] = [:]
    ) -> SetupWindowModel.PrimaryButton {
        SetupWindowModel(integrations: integrations, runs: runs, lastEvents: lastEvents, now: now).primaryButton
    }

    private func snapshot(_ phase: SetupCommandRun.Phase) -> SetupCommandRun.Snapshot {
        SetupCommandRun.Snapshot(kind: .install, lines: [SetupCommandRun.Line(command: "tt install", state: .pending, output: nil)], phase: phase)
    }

    private let waiting = integration(.enabled(version: nil), source: "w")
    private let ready = integration(.enabled(version: nil), source: "r", lastSessionStartAt: now)
    private let missingCLI = integration(.notInstalled, source: "nf", cli: .notFound)

    @Test func doneOnceNothingIsLeftToDo() {
        #expect(button([waiting]) == .done)
        #expect(button([ready]) == .done)
        #expect(button([waiting, ready]) == .done)
        // A tool that is not on this Mac does not count.
        #expect(button([ready, missingCLI]) == .done)
        #expect(button([waiting, missingCLI]) == .done)
    }

    @Test func eachCardGetsItsOwnSourcesLastEvent() {
        let window = SetupWindowModel(
            integrations: [integration(.enabled(version: nil), source: "a"), integration(.enabled(version: nil), source: "b")],
            lastEvents: ["b": now.addingTimeInterval(-2), "other": now],
            now: now
        )
        #expect(window.cards.map(\.state) == [.waiting, .ready])
    }

    @Test func doneOnceReadyByEvents() {
        #expect(button([waiting], lastEvents: ["w": now]) == .done)
        #expect(button([waiting, missingCLI], lastEvents: ["w": now]) == .done)
        #expect(button([waiting, integration(.notInstalled, source: "n")], lastEvents: ["w": now, "n": now]) == .later)
    }

    @Test func laterWhileAToolStillNeedsSetup() {
        #expect(button([waiting, integration(.notInstalled, source: "n")]) == .later)
        #expect(button([waiting, integration(.disabled(version: nil), source: "d")]) == .later)
        #expect(button([ready, integration(.unknown, source: "u")]) == .later)
    }

    @Test func laterWithoutAnyInstalledTool() {
        #expect(button([missingCLI]) == .later)
        #expect(button([]) == .later)
    }

    @Test func laterWhileARunIsRunning() {
        #expect(button([waiting, ready], runs: ["r": snapshot(.running(line: 0))]) == .later)
    }

    @Test func aFinishedRunDoesNotHoldDoneBack() {
        #expect(button([waiting], runs: ["w": snapshot(.succeeded(at: now))]) == .done)
        #expect(button([waiting, ready], runs: ["r": snapshot(.failed(line: 0))]) == .done)
    }
}
