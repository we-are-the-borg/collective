import AppKit
import CollectiveKit
import Synchronization

/// The installed terminal apps as LaunchServices knows them. The popover is
/// rebuilt every clock tick and asks once per session, so each bundle ID and
/// URL scheme is looked up once per run; an app installed or removed meanwhile
/// shows after a relaunch.
nonisolated final class WorkspaceTerminalApps: TerminalApps {
    private struct Cache {
        var byBundleID: [String: TerminalApp?] = [:]
        var byScheme: [String: TerminalApp?] = [:]
    }

    private let cache = Mutex(Cache())

    func app(bundleID: String) -> TerminalApp? {
        if let cached = cache.withLock({ $0.byBundleID[bundleID] }) { return cached }
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { Self.app(at: $0, bundleID: bundleID) }
        cache.withLock { $0.byBundleID[bundleID] = app }
        return app
    }

    /// Cached by scheme: the app that opens a URL follows from its scheme alone.
    func app(opening url: URL) -> TerminalApp? {
        let scheme = url.scheme?.lowercased() ?? url.absoluteString
        if let cached = cache.withLock({ $0.byScheme[scheme] }) { return cached }
        let app = NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { appURL in
            Bundle(url: appURL)?.bundleIdentifier.map { Self.app(at: appURL, bundleID: $0) }
        }
        cache.withLock { $0.byScheme[scheme] = app }
        return app
    }

    /// The name the bundle gives itself ("Warp", "iTerm2", "Terminal"), not the
    /// file's: "iTerm.app" is iTerm2, and a file name depends on Finder's
    /// extension setting.
    private static func app(at url: URL, bundleID: String) -> TerminalApp {
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String).flatMap { $0.isEmpty ? nil : $0 }
        return TerminalApp(bundleID: bundleID, name: name)
    }
}
