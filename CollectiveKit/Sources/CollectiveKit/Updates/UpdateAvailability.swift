/// Whether the installed subspace plugin of a source should be updated.
public enum UpdateAvailability: Sendable, Equatable {
    /// Nothing to offer: no newer release is known, or there is no installed version to compare.
    case upToDate
    /// A newer release is published; the installed plugin still works.
    case available(installed: SubspaceVersion, latest: SubspaceVersion)
    /// The installed plugin is older than this app needs. `latest` is only set
    /// when a lookup found a release newer than the installed one.
    case required(installed: SubspaceVersion, minimum: SubspaceVersion, latest: SubspaceVersion?)

    /// - Parameters:
    ///   - installed: the version as the probe reports it, possibly missing or unreadable.
    ///   - latest: the newest published release; `nil` when no lookup succeeded or lookups are off.
    ///   - minimum: the oldest plugin version the adapter can work with; `nil` when it has none.
    public init(installed: String?, latest: SubspaceVersion?, minimum: SubspaceVersion?) {
        // Without a readable installed version any hint would be a guess.
        guard let installed = installed.flatMap(SubspaceVersion.init) else {
            self = .upToDate
            return
        }
        let newer = latest.flatMap { $0 > installed ? $0 : nil }
        // The minimum ships with the app and needs no network, so it is checked
        // first and shows even with lookups switched off or failing.
        if let minimum, installed < minimum {
            self = .required(installed: installed, minimum: minimum, latest: newer)
        } else if let newer {
            self = .available(installed: installed, latest: newer)
        } else {
            self = .upToDate
        }
    }
}
