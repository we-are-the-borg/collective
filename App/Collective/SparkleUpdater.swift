import AppKit
import CollectiveKit
import os
import Sparkle

/// The app's own updates: Sparkle with its standard update window, reporting
/// into the kit's `AppUpdateState`.
///
/// Sparkle keeps the schedule (`SUScheduledCheckInterval`, once a day) and the
/// skipped versions; `automaticallyChecksForUpdates` follows the switch in
/// General › Updates. A version found on schedule opens no window (gentle
/// reminders): it only shows in the popover footer, the sidebar and About.
/// `Check Now` probes without a window, `Update…` opens it.
final class SparkleUpdater: NSObject {
    let state: AppUpdateState
    private var updater: SPUUpdater?
    private var userDriver: SPUStandardUserDriver?
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Collective", category: "AppUpdates")

    init(bundle: Bundle = .main) {
        state = AppUpdateState(installed: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        super.init()
        let userDriver = SPUStandardUserDriver(hostBundle: bundle, delegate: self)
        self.userDriver = userDriver
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: userDriver, delegate: self)
    }

    /// Starts Sparkle with the switch's value. An updater that can't start
    /// (no public key, a broken feed URL) is logged and makes `Check Now` fail.
    func start(checksAutomatically: Bool) {
        guard let updater else { return }
        do {
            try updater.start()
            setChecksAutomatically(checksAutomatically)
            state.restoreLastCheck(updater.lastUpdateCheckDate)
        } catch {
            Self.log.error("Sparkle did not start: \(String(describing: error), privacy: .public)")
            self.updater = nil
        }
    }

    /// The switch in General › Updates. Only written when it differs, since
    /// Sparkle stores the value and reschedules on every write.
    func setChecksAutomatically(_ on: Bool) {
        guard let updater, updater.automaticallyChecksForUpdates != on else { return }
        updater.automaticallyChecksForUpdates = on
    }

    /// `Check Now`: looks for a newer version without a window; the result
    /// shows in About. A session already under way (an update waiting to be
    /// shown) is left alone.
    func checkNow() {
        guard let updater else {
            state.checkStarted(.manual)
            state.checkFailed()
            return
        }
        guard !updater.sessionInProgress else { return }
        state.checkStarted(.manual)
        updater.checkForUpdateInformation()
    }

    /// `Update…` and the footer's link: Sparkle's window for the version found.
    /// The app has no Dock icon, so it comes forward first.
    func showUpdateWindow() {
        guard let updater else { return }
        NSApp.activate()
        updater.checkForUpdates()
    }
}

extension SparkleUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        state.found(item.displayVersionString, at: updater.lastUpdateCheckDate ?? Date())
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        state.foundNothing(at: updater.lastUpdateCheckDate ?? Date())
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        guard let error = error as NSError? else { return }
        // "No update" and a cancelled install are no failures; the callbacks above already reported.
        let ignored = [Int(SUError.noUpdateError.rawValue), Int(SUError.installationCanceledError.rawValue)]
        guard error.domain != SUSparkleErrorDomain || !ignored.contains(error.code) else { return }
        Self.log.error("Update check failed: \(String(describing: error), privacy: .public)")
        state.checkFailed()
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
                 state: SPUUserUpdateState) {
        if choice == .skip { self.state.skipped() }
    }
}

extension SparkleUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A version found on schedule never opens the window on its own; the
    /// app's own places show it until the user clicks.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }
}
