import Foundation
import SubspaceKit

/// Since when each source runs a newer subspace than before, as the probes
/// saw it, so the popover's footer can ask to restart the sessions that still
/// run the old plugin. Probes count, not the app's own
/// update runs, so an update in the terminal counts as well. In memory only:
/// the first probe after launch is a baseline, so after an app restart no hint
/// shows (accepted).
public struct SubspaceRestartHints: Sendable, Equatable {
    public struct Hint: Sendable, Equatable {
        /// The installed version the probe saw rise.
        public let version: SubspaceVersion
        /// When the probe that saw it started: a session started before it may run the old plugin.
        public let since: Date
    }

    /// The live hints, by source.
    public private(set) var hints: [SourceID: Hint] = [:]
    /// The last readable installed version, by source.
    private var installed: [SourceID: SubspaceVersion] = [:]

    public init() {}

    /// - Parameter probeStartedAt: When the probe that reported `statuses`
    ///   started; it may have read the plugin before the update finished.
    public mutating func observe(_ statuses: [IntegrationStatus], probeStartedAt: Date) {
        for status in statuses {
            // An unreadable version (a timed-out probe, say) says nothing either way.
            guard let version = SourceUpdateModel.installedVersion(status) else { continue }
            defer { installed[status.source] = version }
            guard let before = installed[status.source] else { continue }
            if version > before {
                hints[status.source] = Hint(version: version, since: probeStartedAt)
            } else if let hint = hints[status.source], hint.version > version {
                hints[status.source] = nil
            }
        }
    }
}
