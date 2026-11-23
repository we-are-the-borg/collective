import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// The setup card while subspace has an update, with the adapters' real lines.

private let gmt = TimeZone(identifier: "GMT")!
private let now = Date(timeIntervalSince1970: 100_000)
private let home = "/Users/user"

private let marketplaceUpdate = "claude plugin marketplace update subspace"
private let pluginUpdate = "claude plugin update subspace@subspace --scope user"

private func version(_ text: String) -> SubspaceVersion { SubspaceVersion(text)! }

private func claudeCode(
    _ plugin: IntegrationStatus.Plugin = .enabled(version: "1.0.1"),
    lastSessionStartAt: Date? = Date(timeIntervalSince1970: 1)
) -> IntegrationStatus {
    IntegrationStatus(
        source: "claude-code", toolName: "Claude Code", cliName: "claude",
        cli: .found(path: "/Users/user/.local/bin/claude", version: "2.1.285"), plugin: plugin,
        lastSessionStartAt: lastSessionStartAt, commands: ClaudeCodeSubspace.commands
    )
}

private let available = UpdateAvailability.available(installed: version("1.0.1"), latest: version("1.3.0"))
private let required = UpdateAvailability.required(installed: version("1.0.1"), minimum: version("1.1.0"), latest: version("1.3.0"))

private func card(
    _ status: IntegrationStatus,
    _ availability: UpdateAvailability = available,
    updateRun: SetupCommandRun.Snapshot? = nil,
    checksForUpdates: Bool = true,
    checkedAt: Date? = nil,
    now: Date = now
) -> SetupCardModel {
    SetupCardModel(status, availability: availability, updateRun: updateRun, checksForUpdates: checksForUpdates,
                   checkedAt: checkedAt, now: now, home: home, timeZone: gmt)
}

private typealias RunLine = SetupCommandRun.Line

private func updateRun(_ phase: SetupCommandRun.Phase, _ states: [RunLine.State]) -> SetupCommandRun.Snapshot {
    SetupCommandRun.Snapshot(
        kind: .update(from: version("1.0.1"), to: version("1.3.0")),
        lines: zip([marketplaceUpdate, pluginUpdate], states).map { RunLine(command: $0, state: $1, output: "out") },
        phase: phase
    )
}

private func en(_ resource: LocalizedStringResource?) -> String? {
    guard var resource else { return nil }
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

private func pill(_ card: SetupCardModel) -> String? {
    card.pill.map { "\(en($0.text)!) (\(card.statusMark.shape))" }
}

@Suite struct SetupCardUpdateTests {
    @Test func availableUpdateShowsItsPillTextAndBox() throws {
        let card = card(claudeCode())
        #expect(card.state == .ready)
        #expect(pill(card) == "Update available (circleArrowUp)")
        #expect(card.statusMark == SourceStatusMark(shape: .circleArrowUp, role: .info))
        #expect(en(card.updateText) == "subspace 1.3.0 is available. You have 1.0.1.")
        let update = try #require(card.update)
        #expect(update.state == .available)
        #expect(card.commands == update.commands)
        #expect(card.commands?.terminal == [marketplaceUpdate, pluginUpdate])
        #expect(card.commands?.footer?.button?.kind == .update)
        #expect(card.buttonRunsUpdate)
    }

    @Test func runningUpdateShowsUpdatingWithoutText() {
        let card = card(claudeCode(), updateRun: updateRun(.running(line: 1), [.succeeded, .running]))
        #expect(pill(card) == "Updating… (haloDot)")
        // A halo instead of a spinner.
        #expect(card.statusMark == SourceStatusMark(shape: .haloDot, role: .info))
        #expect(card.updateText == nil)
        #expect(en(card.commands?.footer?.text) == "Updating subspace…")
        #expect(card.commands?.footer?.button?.isEnabled == false)
        #expect(card.buttonRunsUpdate)
    }

    @Test func failedUpdateShowsRedPillAndTryAgain() {
        let card = card(claudeCode(), updateRun: updateRun(.failed(line: 1), [.succeeded, .failed]))
        #expect(pill(card) == "Update failed (circleX)")
        #expect(card.statusMark == SourceStatusMark(shape: .circleX, role: .danger))
        #expect(card.updateText == nil)
        #expect(card.commands?.footer?.isWarning == true)
        #expect(card.commands?.footer?.button?.kind == .tryAgain)
        #expect(card.commands?.lines.last?.output == "out")
        #expect(card.buttonRunsUpdate)
    }

    /// The pill is the card's own again; the probe's new version is in the subtitle.
    @Test func confirmedUpdateShowsConnected() {
        let succeededAt = now.addingTimeInterval(-10)
        let card = card(claudeCode(.enabled(version: "1.3.0"), lastSessionStartAt: now.addingTimeInterval(-120)), .upToDate,
                        updateRun: updateRun(.succeeded(at: succeededAt), [.succeeded, .succeeded]),
                        checkedAt: succeededAt.addingTimeInterval(1))
        #expect(card.update?.state == .updated)
        #expect(pill(card) == "Connected (dot)")
        #expect(card.statusMark == SourceStatusMark(shape: .dot, role: .success))
        #expect(en(card.subtitle) == "subspace 1.3.0 · last session started 2 min ago")
        #expect(card.updateText == nil)
        #expect(en(card.commands?.footer?.text) == "Updated at 3:46\u{202F}AM. Restart running sessions to use 1.3.0.")
        #expect(card.commands?.footer?.button == nil)
    }

    /// The commands exited 0, but the newest probe started before that: it may have read the old plugin.
    @Test func succeededRunWithAProbeFromBeforeItStaysUpdating() {
        let succeededAt = now.addingTimeInterval(-10)
        let card = card(claudeCode(.enabled(version: "1.3.0")), .upToDate,
                        updateRun: updateRun(.succeeded(at: succeededAt), [.succeeded, .succeeded]),
                        checkedAt: succeededAt.addingTimeInterval(-1))
        #expect(card.update?.state == .running)
        #expect(pill(card) == "Updating… (haloDot)")
    }

    /// Every command succeeded, yet the probe after them still reports the old version.
    @Test func succeededRunWithAProbeStillReportingTheOldVersionFails() {
        let succeededAt = now.addingTimeInterval(-10)
        let card = card(claudeCode(.enabled(version: "1.0.1")), .upToDate,
                        updateRun: updateRun(.succeeded(at: succeededAt), [.succeeded, .succeeded]),
                        checkedAt: succeededAt.addingTimeInterval(1))
        #expect(card.update?.state == .failed)
        #expect(pill(card) == "Update failed (circleX)")
        #expect(card.commands?.lines.allSatisfy { $0.slot != .failed } == true)
        #expect(card.commands?.footer?.button?.kind == .tryAgain)
        #expect(card.buttonRunsUpdate)
    }

    @Test func requiredUpdateShowsWarningPillAndText() {
        let card = card(claudeCode(), required)
        #expect(pill(card) == "Update required (triangle)")
        #expect(card.statusMark == SourceStatusMark(shape: .triangle, role: .warning))
        #expect(en(card.updateText) == "This version of The Collective needs subspace 1.1.0 or later. You have 1.0.1, so some events from Claude Code sessions won’t show up.")
        #expect(card.commands?.footer?.button?.kind == .update)
    }

    @Test func switchOffHidesAnAvailableUpdateButNotARequiredOne() {
        let off = card(claudeCode(), checksForUpdates: false)
        #expect(off.update == nil)
        #expect(pill(off) == "Connected (dot)")
        #expect(off.updateText == nil)
        #expect(off.commands == nil)
        #expect(!off.buttonRunsUpdate)
        #expect(pill(card(claudeCode(), required, checksForUpdates: false)) == "Update required (triangle)")
    }

    @Test func waitingCardOffersTheUpdate() {
        let card = card(claudeCode(lastSessionStartAt: nil))
        #expect(card.state == .waiting)
        #expect(pill(card) == "Update available (circleArrowUp)")
        #expect(card.commands?.terminal == [marketplaceUpdate, pluginUpdate])
        #expect(card.steps.count == 4)
    }

    /// One box per card: Enable matters more than the update.
    @Test func disabledCardKeepsItsEnableBox() {
        let status = claudeCode(.disabled(version: "1.0.1"))
        let card = card(status, required)
        #expect(card.update == nil)
        #expect(card.updateText == nil)
        #expect(pill(card) == "Disabled (triangle)")
        #expect(card.commands?.terminal == status.commands.enable)
        #expect(card.commands?.footer?.button?.kind == .enable)
        #expect(!card.buttonRunsUpdate)
    }

    /// A started run outlasts a probe that briefly can't tell the plugin is there.
    @Test func runningUpdateShowsOnACardWhoseProbeReportsNotInstalled() {
        let card = card(claudeCode(.notInstalled), .upToDate, updateRun: updateRun(.running(line: 1), [.succeeded, .running]))
        #expect(card.state == .notInstalled)
        #expect(card.update?.state == .running)
        #expect(pill(card) == "Updating… (haloDot)")
        #expect(en(card.commands?.footer?.text) == "Updating subspace…")
        #expect(card.buttonRunsUpdate)
    }

    /// An update started in Settings for a disabled source shows its run here too.
    @Test func runningUpdateShowsOnADisabledCard() {
        let card = card(claudeCode(.disabled(version: "1.0.1")), updateRun: updateRun(.failed(line: 1), [.succeeded, .failed]))
        #expect(card.state == .disabled)
        #expect(pill(card) == "Update failed (circleX)")
        #expect(card.commands?.footer?.button?.kind == .tryAgain)
        #expect(card.buttonRunsUpdate)
    }

    @Test func idleUpdateRunOnADisabledCardKeepsTheEnableBox() {
        let status = claudeCode(.disabled(version: "1.0.1"))
        let idle = SetupCommandRun.Snapshot(kind: .update(from: version("1.0.1"), to: version("1.3.0")),
                                            lines: [], phase: .idle)
        let card = card(status, updateRun: idle)
        #expect(card.update == nil)
        #expect(card.commands?.footer?.button?.kind == .enable)
        #expect(!card.buttonRunsUpdate)
    }

    @Test func notInstalledCardShowsNoUpdate() {
        let card = card(claudeCode(.notInstalled), required)
        #expect(card.update == nil)
        #expect(card.pill == nil)
        #expect(card.commands?.footer?.button?.kind == .install)
    }

    /// The card's own run is an install's or enable's; an update handed in there shows nothing of its own.
    @Test func updateRunAsTheCardsRunShowsNothing() {
        let status = claudeCode()
        let run = updateRun(.failed(line: 1), [.succeeded, .failed])
        #expect(SetupCardModel(status, run: run, now: now, home: home, timeZone: gmt) == SetupCardModel(status, now: now, home: home, timeZone: gmt))
    }

    @Test func upToDateCardIsAsBefore() {
        let status = claudeCode()
        #expect(card(status, .upToDate) == SetupCardModel(status, now: now, home: home, timeZone: gmt))
    }
}

@Suite struct SetupWindowUpdateTests {
    private func window(
        updateRuns: [SourceID: SetupCommandRun.Snapshot] = [:],
        availability: [SourceID: UpdateAvailability] = ["claude-code": available]
    ) -> SetupWindowModel {
        SetupWindowModel(integrations: [claudeCode()], updateRuns: updateRuns, availability: availability, checksForUpdates: true,
                         checkedAt: nil, now: now, home: home, timeZone: gmt)
    }

    /// An update never holds back Done.
    @Test func availableUpdateKeepsDone() {
        let window = window()
        #expect(window.cards.first?.update?.state == .available)
        #expect(window.primaryButton == .done)
    }

    @Test func runningUpdateKeepsDoneAndShowsOnItsCard() {
        let window = window(updateRuns: ["claude-code": updateRun(.running(line: 0), [.running, .pending])])
        #expect(window.cards.first?.update?.state == .running)
        #expect(window.primaryButton == .done)
    }

    @Test func sourceWithoutAvailabilityIsUpToDate() {
        #expect(window(availability: [:]).cards.first?.update == nil)
    }

    /// The window model hands `checkedAt` on to its cards: only a probe after the success confirms the update.
    @Test func windowPassesTheProbeTimeToItsCards() {
        let succeededAt = now.addingTimeInterval(-10)
        func cards(checkedAt: Date) -> SetupCardModel? {
            SetupWindowModel(
                integrations: [claudeCode(.enabled(version: "1.3.0"), lastSessionStartAt: now.addingTimeInterval(-120))],
                updateRuns: ["claude-code": updateRun(.succeeded(at: succeededAt), [.succeeded, .succeeded])],
                availability: ["claude-code": .upToDate], checksForUpdates: true,
                checkedAt: checkedAt, now: now, home: home, timeZone: gmt
            ).cards.first
        }
        #expect(cards(checkedAt: succeededAt.addingTimeInterval(1)).flatMap(pill) == "Connected (dot)")
        #expect(cards(checkedAt: succeededAt.addingTimeInterval(-1)).flatMap(pill) == "Updating… (haloDot)")
    }
}
