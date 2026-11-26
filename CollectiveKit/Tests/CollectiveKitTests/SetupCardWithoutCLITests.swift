import Foundation
import Testing
@testable import CollectiveKit

// The setup card of a tool that is present without its CLI and offers a
// path that runs another program (`SetupCommands.withoutCLI`).

private let now = Date(timeIntervalSince1970: 100_000)
private let home = "/Users/user"
private let gmt = TimeZone(identifier: "GMT")!

private let clone = "fetch clone https://example.com/subspace.git ~/.test-tool/plugins/subspace"
private let pull = "fetch -C ~/.test-tool/plugins/subspace pull"
private let fetchPath = "/usr/bin/fetch"
private let hooks = "subspace adds hooks that run in every Test Tool session."

/// The made-up tool of `integration(_:)`, its CLI missing, with a path through `fetch`.
private func withoutCLI(
    _ plugin: IntegrationStatus.Plugin,
    alternative: IntegrationStatus.CLI?,
    hint: LocalizedStringResource? = nil
) -> IntegrationStatus {
    var status = integration(plugin, cli: .notFound)
    status.commands.withoutCLI = SetupCommands.Alternative(program: "fetch", install: [clone], update: [pull], missingProgramHint: hint)
    status.alternative = alternative
    return status
}

private func card(_ status: IntegrationStatus, run: SetupCommandRun.Snapshot? = nil) -> SetupCardModel {
    SetupCardModel(status, run: run, now: now, home: home, timeZone: gmt)
}

private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

/// Terminal lines as "slot command".
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
        return slot + line.command
    }
}

/// "Title (enabled) / accessibility label"
private func button(_ card: SetupCardModel) -> String? {
    card.commands?.footer?.button.map { button in
        "\(en(button.title)) (\(button.isEnabled ? "enabled" : "disabled")) / \(en(button.accessibilityLabel))"
    }
}

@Suite struct SetupCardWithoutCLITests {
    @Test(arguments: [IntegrationStatus.Plugin.notInstalled, .unknown])
    func aFoundAlternativeOffersItsInstallLikeANotInstalledCard(plugin: IntegrationStatus.Plugin) throws {
        let card = card(withoutCLI(plugin, alternative: .found(path: fetchPath, version: nil)))
        #expect(card.state == .notInstalled)
        #expect(card.pill == nil)
        #expect(en(card.subtitle) == "tt · not on this Mac")
        #expect(card.note == nil)
        #expect(lines(card) == ["1 \(clone)"])
        #expect(card.commands?.footer.map { en($0.text) } == "Runs 1 command in your login shell. \(hooks)")
        #expect(button(card) == "Install (enabled) / Install subspace for Test Tool: runs \(clone)")
        #expect(card.commands?.inApp == ["/plugin install subspace"])
        let plan = try #require(card.runPlan)
        #expect(plan.kind == .install)
        #expect(plan.lines == [clone])
        #expect(plan.skipping == [])
        #expect(plan.programName == "fetch")
        #expect(plan.programPath == fetchPath)
    }

    /// The tool is there but the path's program is not: the lines are only
    /// there to copy, and the note names the program from the data.
    @Test func aMissingAlternativeShowsItsLinesToCopyAndNamesTheProgram() throws {
        let card = card(withoutCLI(.notInstalled, alternative: .notFound))
        #expect(card.state == .notInstalled)
        #expect(card.pill == nil)
        #expect(en(card.subtitle) == "tt · not on this Mac")
        #expect(card.runPlan == nil)
        #expect(lines(card) == [clone])
        #expect(card.commands?.footer == nil)
        #expect(card.note.map(en) == "fetch is not on this Mac, so The Collective can’t run these commands. Install it first.")
    }

    @Test func aMissingAlternativeTakesTheAdaptersHint() {
        let card = card(withoutCLI(.notInstalled, alternative: .notFound, hint: "Get fetch from example.com."))
        #expect(card.note.map(en) == "fetch is not on this Mac, so The Collective can’t run these commands. Get fetch from example.com.")
    }

    /// No path without the CLI applies: the probe set none, or the adapter offers none.
    @Test func withoutAnAlternativeTheCardIsNotFoundAsBefore() throws {
        var adapterWithout = withoutCLI(.notInstalled, alternative: .found(path: fetchPath, version: nil))
        adapterWithout.commands.withoutCLI = nil
        for status in [withoutCLI(.notInstalled, alternative: nil), adapterWithout] {
            let card = card(status)
            #expect(card.state == .notFound)
            #expect(card.pill.map { en($0.text) } == "Not found")
            #expect(card.note.map(en) == "The Collective looked in ~/.local/bin, /opt/homebrew/bin, and your login shell’s PATH. If you don’t use Test Tool, you can ignore this.")
            #expect(card.runPlan == nil)
            #expect(lines(card) == status.commands.install)
        }
    }

    /// The probe read the plugin from the tool's files: the card is the one
    /// without an alternative, whatever the program.
    @Test(arguments: [IntegrationStatus.CLI.found(path: fetchPath, version: nil), .notFound])
    func anEnabledPluginWithoutTheCLIIsConnectedAsBefore(alternative: IntegrationStatus.CLI) {
        var status = withoutCLI(.enabled(version: "1.0.0"), alternative: alternative)
        status.lastSessionStartAt = now.addingTimeInterval(-60)
        var plain = status
        plain.alternative = nil
        let connected = card(status)
        #expect(connected.state == .ready)
        #expect(connected.pill.map { en($0.text) } == "Connected")
        #expect(connected.note == nil)
        #expect(connected.runPlan == nil)
        #expect(connected == card(plain))
    }

    /// As with the CLI: the run's lines stay once the recheck finds the plugin enabled.
    @Test func aSucceededInstallThroughTheAlternativeStaysOnceThePluginIsEnabled() {
        let snapshot = SetupCommandRun.Snapshot(kind: .install, lines: [SetupCommandRun.Line(command: clone, state: .succeeded, output: "$ \(clone)")],
                                                phase: .succeeded(at: now))
        let card = card(withoutCLI(.enabled(version: "1.0.0"), alternative: .found(path: fetchPath, version: nil)), run: snapshot)
        #expect(card.state == .waiting)
        #expect(lines(card) == ["done \(clone)"])
        #expect(card.commands?.footer.map { en($0.text) } == "Installed at 3:46\u{202F}AM.")
    }
}

/// The settings pane words a tool that is there without its CLI as not set up, not as missing.
@Suite struct SettingsSourceWithoutCLITests {
    @Test(arguments: [IntegrationStatus.CLI.found(path: fetchPath, version: nil), .notFound])
    func aToolWithAnAlternativeIsNotSetUp(alternative: IntegrationStatus.CLI) {
        let model = SettingsSourceModel(source: "test-tool", name: "Test Tool", status: withoutCLI(.notInstalled, alternative: alternative),
                                        defaultFolders: [], chosenFolder: nil, home: home, now: now, timeZone: gmt)
        #expect(en(model.statusWord) == "Not set up")
        #expect(model.statusMark == .unknown)
        #expect(model.setUpButton == .primary)
    }
}
