import Foundation
import Observation

/// What the app knows about its own updates. The updater (Sparkle, in the
/// app) reports into it; the kit names no updater. Sparkle keeps the cadence
/// and the skipped versions, so nothing here outlives a relaunch except the
/// time of the last check, which the updater hands over.
@MainActor @Observable
public final class AppUpdateState {
    /// The running app's version; nil when it isn't X.Y.Z.
    public let installed: SubspaceVersion?
    /// A newer version the last successful check found; it stays through a
    /// later check, a failed one included, until a check finds none or the
    /// user skips it.
    public private(set) var available: SubspaceVersion?
    /// When the updater last checked, automatic or not.
    public private(set) var lastCheck: Date?
    /// A check under way, and whether `Check Now` started it.
    public private(set) var checking: Check?
    /// Set when a `Check Now` failed, until the next check starts; an
    /// automatic check that fails shows nothing.
    public private(set) var failed = false

    public enum Check: Sendable, Equatable { case automatic, manual }

    public init(installed: String?, lastCheck: Date? = nil) {
        self.installed = installed.flatMap(SubspaceVersion.init)
        self.lastCheck = lastCheck
    }

    /// The updater's own record of its last check, at launch; a check
    /// reported since then wins.
    public func restoreLastCheck(_ date: Date?) {
        if lastCheck == nil { lastCheck = date }
    }

    /// The updater started a check.
    public func checkStarted(_ check: Check) {
        checking = check
        failed = false
    }

    /// The check found `version`. A version that isn't newer than the
    /// installed one, or isn't X.Y.Z, offers nothing.
    public func found(_ version: String, at date: Date) {
        let version = SubspaceVersion(version)
        available = if let version, let installed, version > installed { version } else { nil }
        lastCheck = date
        checking = nil
    }

    /// The check found no newer version.
    public func foundNothing(at date: Date) {
        available = nil
        lastCheck = date
        checking = nil
    }

    /// The check failed: shown only after `Check Now`, and the last result stays.
    public func checkFailed() {
        failed = checking == .manual
        checking = nil
    }

    /// The user chose `Skip This Version` in the update window.
    public func skipped() {
        available = nil
    }
}
