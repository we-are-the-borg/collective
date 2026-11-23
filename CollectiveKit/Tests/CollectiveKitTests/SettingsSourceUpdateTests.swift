import Foundation
import Testing
@testable import CollectiveKit

/// A source's settings with a subspace update to offer: the group, the
/// sidebar arrow and the status row.
@Suite struct SettingsSourceUpdateTests {
    private let v1_0_1 = SubspaceVersion(major: 1, minor: 0, patch: 1)
    private let v1_2_0 = SubspaceVersion(major: 1, minor: 2, patch: 0)
    private let v1_3_0 = SubspaceVersion(major: 1, minor: 3, patch: 0)
    private var available: UpdateAvailability { .available(installed: v1_0_1, latest: v1_3_0) }
    private var required: UpdateAvailability { .required(installed: v1_0_1, minimum: v1_2_0, latest: nil) }

    private func status(_ plugin: IntegrationStatus.Plugin = .enabled(version: "1.0.1"),
                        started: Date? = Date(timeIntervalSince1970: 1)) -> IntegrationStatus {
        var status = integration(plugin, lastSessionStartAt: started)
        status.commands.update = ["tt plugin marketplace update subspace", "tt plugin update subspace"]
        return status
    }

    private func row(
        _ status: IntegrationStatus?,
        _ availability: UpdateAvailability,
        run: SetupCommandRun.Snapshot? = nil,
        checksForUpdates: Bool = true,
        checkedAt: Date? = nil
    ) -> SettingsSourceModel {
        SettingsSourceModel(
            source: "test-tool", name: "Test Tool", status: status, checkedAt: checkedAt,
            defaultFolder: URL(filePath: "/Users/user/.tool/data/subspace"), chosenFolder: nil,
            availability: availability, updateRun: run, checksForUpdates: checksForUpdates, home: "/Users/user",
            now: Date(timeIntervalSince1970: 3)
        )
    }

    private func updateRun(_ phase: SetupCommandRun.Phase) -> SetupCommandRun.Snapshot {
        let state: SetupCommandRun.Line.State = switch phase {
        case .idle: .pending
        case .running: .running
        case .succeeded: .succeeded
        case .failed: .failed
        }
        return SetupCommandRun.Snapshot(kind: .update(from: v1_0_1, to: v1_3_0),
                                        lines: [SetupCommandRun.Line(command: "tt plugin update subspace", state: state)], phase: phase)
    }

    private func text(_ resource: LocalizedStringResource) -> String { String(localized: resource) }

    @Test func anAvailableUpdateShowsTheGroupAndTheArrow() {
        let model = row(status(), available)
        #expect(model.update?.state == .available)
        #expect(model.showsUpdateArrow)
        #expect(text(model.status.text) == "Connected · 1.0.1")
        // The offer is the arrow at the row's end; the form in front stays Connected's.
        #expect(model.statusMark == SourceStatusMark(shape: .dot, role: .success))
    }

    @Test(arguments: [SetupCommandRun.Phase.running(line: 0), .failed(line: 0)])
    func theArrowStaysWhileTheUpdateRunsOrAfterItFailed(phase: SetupCommandRun.Phase) {
        #expect(row(status(), available, run: updateRun(phase)).showsUpdateArrow)
    }

    /// Every command exited 0, but the probe after it still reports the old version.
    @Test func theArrowStaysWhenTheProbeDoesntConfirmTheUpdate() {
        let model = row(status(), available, run: updateRun(.succeeded(at: Date(timeIntervalSince1970: 2))),
                        checkedAt: Date(timeIntervalSince1970: 3))
        #expect(model.update?.state == .failed)
        #expect(model.showsUpdateArrow)
    }

    @Test func theArrowGoesOnceUpdated() {
        let model = row(status(.enabled(version: "1.3.0")), .upToDate, run: updateRun(.succeeded(at: Date(timeIntervalSince1970: 2))),
                        checkedAt: Date(timeIntervalSince1970: 3))
        #expect(model.update?.state == .updated)
        #expect(!model.showsUpdateArrow)
        #expect(text(model.status.text) == "Connected · 1.3.0")
    }

    @Test func switchedOffThereIsNeitherGroupNorArrow() {
        let model = row(status(), available, checksForUpdates: false)
        #expect(model.update == nil)
        #expect(!model.showsUpdateArrow)
    }

    @Test func upToDateThereIsNeitherGroupNorArrow() {
        let model = row(status(), .upToDate)
        #expect(model.update == nil)
        #expect(!model.showsUpdateArrow)
    }

    @Test func beforeTheFirstProbeThereIsNoGroup() {
        let model = row(nil, available)
        #expect(model.update == nil)
        #expect(!model.showsUpdateArrow)
        #expect(text(model.status.text) == "Checking…")
    }

    /// A warning, not an offer: the status mark becomes the `--warning` triangle, no arrow, also with the switch off.
    @Test(arguments: [true, false])
    func aRequiredUpdateTurnsAConnectedStatusIntoAWarning(checksForUpdates: Bool) {
        let model = row(status(), required, checksForUpdates: checksForUpdates)
        #expect(text(model.status.text) == "Update required · 1.0.1")
        #expect(text(model.statusWord) == "Update required")
        #expect(model.statusVersion == "1.0.1")
        #expect(model.statusMark == SourceStatusMark(shape: .triangle, role: .warning))
        #expect(model.update?.state == .required)
        #expect(!model.showsUpdateArrow)
        #expect(model.setUpButton == nil)
    }

    @Test func aRunningRequiredUpdateShowsNoArrow() {
        #expect(!row(status(), required, run: updateRun(.running(line: 0))).showsUpdateArrow)
    }

    /// The mark shows the worst state: a required update is worse than waiting,
    /// Disabled says more than it and keeps its text, the triangle either way. Both
    /// keep their Set Up button.
    @Test(arguments: [
        (IntegrationStatus.Plugin.enabled(version: "1.0.1"), Date?.none, "Update required · 1.0.1", SettingsSourceModel.ButtonStyle.normal),
        (.disabled(version: "1.0.1"), nil, "Disabled · 1.0.1", .primary),
    ])
    func aRequiredUpdateOutranksWaitingButNotDisabled(plugin: IntegrationStatus.Plugin, started: Date?, label: String,
                                                      button: SettingsSourceModel.ButtonStyle) {
        let model = row(status(plugin, started: started), required)
        #expect(text(model.status.text) == label)
        #expect(model.statusMark == SourceStatusMark(shape: .triangle, role: .warning))
        #expect(model.update?.state == .required)
        #expect(model.setUpButton == button)
    }

    /// The arrow is hidden from VoiceOver, so the row's label says it.
    @Test func withTheArrowTheRowSaysAnUpdateIsAvailable() {
        let model = row(status(), available)
        #expect(text(model.rowAccessibilityLabel) == "Test Tool, Connected · 1.0.1, update available")
    }

    /// Name and the status word of the pane, with the version where the pane shows it.
    @Test(arguments: [
        (IntegrationStatus.Plugin.enabled(version: "1.0.1"), Date?.some(Date(timeIntervalSince1970: 1)), "Test Tool, Connected · 1.0.1"),
        (.enabled(version: nil), nil, "Test Tool, Waiting for a session"),
        (.disabled(version: "1.0.1"), nil, "Test Tool, Disabled · 1.0.1"),
        (.notInstalled, nil, "Test Tool, Not set up"),
    ])
    func withoutTheArrowTheRowReadsNameAndStatus(plugin: IntegrationStatus.Plugin, started: Date?, label: String) {
        #expect(text(row(status(plugin, started: started), .upToDate).rowAccessibilityLabel) == label)
    }

    @Test func aRequiredUpdateIsInTheStatusNotTheSuffix() {
        #expect(text(row(status(), required).rowAccessibilityLabel) == "Test Tool, Update required · 1.0.1")
    }

    @Test func theGeneralUpdatesTextsAreTheDesigns() {
        #expect(text(SettingsText.updates) == "Updates")
        #expect(text(SettingsText.checkForSubspaceUpdates) == "Check for subspace updates")
        #expect(text(SettingsModel.updatesFootnote)
            == "Once a day, and when you open Setup or a source, The Collective asks GitHub which versions of subspace are published. Nothing about you or your sessions is sent. A required update is shown even when this is off.")
        #expect(text(SettingsText.updateAvailable) == "Update available")
    }
}
