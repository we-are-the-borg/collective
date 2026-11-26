import Foundation
import Observation
import SubspaceKit

/// The runs of a tool's commands, by tool: a setup card's install or
/// enable, and the update of the setup and settings windows. One run
/// per tool, so an update and an install of the same tool never run at once.
/// An install or enable run shows until the setup window closes, an update
/// run until the last of the two windows closes (the windows share it, so
/// closing one of two keeps it); either way the next open starts clean. A run
/// still going then is never cancelled and stays; the next open drops it once
/// it has ended, and a run still going then keeps showing its progress. While
/// its windows are closed only a running run is shown, so the next open's
/// first frame, drawn before `windowDidAppear(_:)`, never shows an ended one.
@MainActor @Observable
public final class SetupRuns {
    /// A window that shows runs.
    public enum Window: Sendable, Hashable { case setup, settings }

    private var runs: [SourceID: SetupCommandRun] = [:]
    private var openWindows: Set<Window> = []
    /// The tools whose finished run shows its output; cleared with the runs.
    public private(set) var outputShown: Set<SourceID> = []
    private let environment: [String: String]
    private let runner: any CommandRunner
    private let now: @MainActor () -> Date
    private let onSuccess: @MainActor () -> Void

    /// - Parameters:
    ///   - environment: The app's environment, handed to every run.
    ///   - onSuccess: Called once per run whose lines all succeeded, so the
    ///     app checks the tools again at once.
    public init(environment: [String: String], runner: any CommandRunner,
                now: @escaping @MainActor () -> Date = { Date() }, onSuccess: @escaping @MainActor () -> Void) {
        self.environment = environment
        self.runner = runner
        self.now = now
        self.onSuccess = onSuccess
    }

    /// The install and enable runs `SetupWindowModel` shows, by tool.
    public var snapshots: [SourceID: SetupCommandRun.Snapshot] {
        shown(updates: false, windowOpen: openWindows.contains(.setup))
    }

    /// The update runs `SourceUpdateModel` shows, by tool.
    public var updateSnapshots: [SourceID: SetupCommandRun.Snapshot] {
        shown(updates: true, windowOpen: !openWindows.isEmpty)
    }

    private func shown(updates: Bool, windowOpen: Bool) -> [SourceID: SetupCommandRun.Snapshot] {
        runs.filter { $0.value.kind.isUpdate == updates && (windowOpen || $0.value.isRunning) }.mapValues(\.snapshot)
    }

    /// The card's button: "Install" and "Enable" start a run from the card's
    /// plan, "Try Again" continues the failed one. Only ever on the user's tap,
    /// and only while the card shows that button enabled, so a stale tap (the
    /// recheck after a run changed the card) does nothing. The card is built
    /// here, with the tool's run as the window shows it, so no caller can hand
    /// in one that offers "Install" again over a failed run.
    /// - Returns: The started run, or `nil` if nothing was started: the card
    ///   offers no enabled button of this kind, the tool's run is still
    ///   running, or there is no plan or failed run to continue.
    @discardableResult
    public func run(_ kind: SetupCardModel.CommandsBox.Footer.Button.Kind, for status: IntegrationStatus) -> Task<Void, Never>? {
        // Without the tool's last event: it only tells waiting from ready, and
        // both have the same plan, commands and button.
        let card = SetupCardModel(status, run: snapshots[status.source], outputShown: outputShown.contains(status.source), now: now())
        guard let button = card.commands?.footer?.button, button.kind == kind, button.isEnabled else { return nil }
        switch kind {
        case .tryAgain:
            return runs[card.source]?.retry()
        case .install, .enable, .update:
            return start(card.runPlan, for: card.source)
        }
    }

    /// The update group's button: "Update" starts the source's update from the
    /// group's plan, "Try Again" continues the failed update, or runs every
    /// line again after a success no probe confirmed. As with the card,
    /// only while the group as the windows show it offers that button enabled.
    /// - Parameters:
    ///   - checkedAt: When the probe that reported `status` started.
    ///   - availability: What the release check says about the installed plugin now.
    ///   - checksForUpdates: The switch in General › Updates.
    /// - Returns: The started run, or `nil` if nothing was started: the group
    ///   offers no enabled button of this kind, or another run of the source
    ///   (an install, say) is still running.
    @discardableResult
    public func runUpdate(
        _ kind: SetupCardModel.CommandsBox.Footer.Button.Kind,
        for status: IntegrationStatus,
        checkedAt: Date?,
        availability: UpdateAvailability,
        checksForUpdates: Bool
    ) -> Task<Void, Never>? {
        guard let group = SourceUpdateModel(status, checkedAt: checkedAt, availability: availability, run: updateSnapshots[status.source],
                                            outputShown: outputShown.contains(status.source), checksForUpdates: checksForUpdates,
                                            now: now()),
              let button = group.commands?.footer?.button, button.kind == kind, button.isEnabled else { return nil }
        switch kind {
        case .tryAgain:
            guard let run = runs[group.source] else { return nil }
            // A rerun shows its output folded, like a new run.
            outputShown.remove(group.source)
            return run.retry() ?? run.runAgain()
        case .install, .enable, .update:
            return start(group.runPlan, for: group.source)
        }
    }

    /// Never over a run still running, whatever its kind.
    private func start(_ plan: SetupCardModel.RunPlan?, for source: SourceID) -> Task<Void, Never>? {
        if let run = runs[source], run.isRunning { return nil }
        guard let plan else { return nil }
        let run = SetupCommandRun(kind: plan.kind, lines: plan.lines, skipping: plan.skipping, programName: plan.programName, programPath: plan.programPath,
                                  environment: environment, runner: runner, now: now, onSuccess: onSuccess)
        runs[source] = run
        outputShown.remove(source)
        return run.start()
    }

    public func toggleOutput(for source: SourceID) {
        if !outputShown.insert(source).inserted { outputShown.remove(source) }
    }

    /// Opening the setup window drops ended installs and enables; opening a
    /// window while no other is open also drops ended updates, opening the
    /// second keeps the update the first shows.
    public func windowDidAppear(_ window: Window) {
        let othersOpen = !openWindows.subtracting([window]).isEmpty
        openWindows.insert(window)
        dropEndedRuns(installs: window == .setup, updates: !othersOpen)
    }

    public func windowDidDisappear(_ window: Window) {
        openWindows.remove(window)
        dropEndedRuns(installs: window == .setup, updates: openWindows.isEmpty)
    }

    /// Only an ended run that stays keeps its output shown.
    private func dropEndedRuns(installs: Bool, updates: Bool) {
        runs = runs.filter { $0.value.isRunning || !($0.value.kind.isUpdate ? updates : installs) }
        outputShown = outputShown.filter { runs[$0].map { !$0.isRunning } ?? false }
    }
}

private extension SetupCommandRun {
    var isRunning: Bool { if case .running = phase { true } else { false } }
}
