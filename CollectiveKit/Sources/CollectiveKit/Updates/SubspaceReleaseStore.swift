import Foundation

/// What the release checker keeps across launches, so a restart within the
/// interval asks GitHub nothing and an offline launch still knows the last release.
public protocol SubspaceReleaseStore: AnyObject {
    /// The user's switch; true when never set.
    var checksForUpdates: Bool { get set }
    var record: SubspaceReleaseRecord { get set }
}

/// The last lookup per source, by `SourceID` raw value.
public struct SubspaceReleaseRecord: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        /// Also set by a failed lookup, so a failure waits for the next interval instead of retrying.
        public var lastAttempt: Date?
        /// The newest release of the last successful lookup.
        public var latest: String?

        public init(lastAttempt: Date? = nil, latest: String? = nil) {
            self.lastAttempt = lastAttempt
            self.latest = latest
        }
    }

    public var sources: [String: Entry]

    public init(sources: [String: Entry] = [:]) {
        self.sources = sources
    }
}

/// The app's defaults. The switch has its own key, so a record that no longer
/// decodes can't turn checking back on for someone who switched it off.
public final class UserDefaultsSubspaceReleaseStore: SubspaceReleaseStore {
    private let defaults: UserDefaults
    private static let checksForUpdatesKey = "checksForSubspaceUpdates"
    private static let recordKey = "subspaceReleases"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var checksForUpdates: Bool {
        get { defaults.object(forKey: Self.checksForUpdatesKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.checksForUpdatesKey) }
    }

    public var record: SubspaceReleaseRecord {
        get {
            defaults.data(forKey: Self.recordKey).flatMap { try? JSONDecoder().decode(SubspaceReleaseRecord.self, from: $0) }
                ?? SubspaceReleaseRecord()
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.recordKey) }
    }
}
