import AppKit
import CollectiveKit
import os

/// Brings a session's terminal to the front; whether there is one to bring
/// is the kit's to say (`TerminalAction`).
enum TerminalFocuser {
    nonisolated private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Collective", category: "Terminal")

    static func show(_ action: TerminalAction) {
        switch action.target {
        case let .url(url, _):
            open(url, bundleID: action.bundleID)
        case .app, .appHandling:
            // `.appHandling`'s URL leads to another tab than the session's:
            // it only told which app, so it is never opened.
            activate(bundleID: action.bundleID)
        }
    }

    /// The app that handles the URL selects the session's tab (Warp's focus URL).
    private static func open(_ url: URL, bundleID: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            log.error("No app \(bundleID, privacy: .public) to open the session's tab with")
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
            if let error {
                log.error("Could not open the session's tab: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// A running instance comes forward; otherwise the app launches.
    private static func activate(bundleID: String) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            // Since macOS 14 activation is cooperative: the active app hands it over.
            NSApp.yieldActivation(to: running)
            if running.activate() { return }
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            log.error("No app \(bundleID, privacy: .public) to bring to the front")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                log.error("Could not bring \(bundleID, privacy: .public) to the front: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
