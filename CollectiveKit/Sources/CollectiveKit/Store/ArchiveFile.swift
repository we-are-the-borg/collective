import Foundation
import os

/// The user's archive marks on disk, so an archived session stays hidden across
/// restarts. Kept apart from the event store: the store holds what subspace
/// wrote, this holds what the user decided.
///
/// Marks go by age only, never because their session left the state: the spool
/// and the event store can replay a pruned session on the next launch, and its
/// mark must still hide it then.
public struct ArchiveFile: Sendable {
    /// How long a mark is kept after archiving: well past the spool's and the
    /// event store's retention, so nothing they replay comes back unarchived.
    /// Only a store kept without limit can replay a session older than its mark.
    public static let retention: TimeInterval = 30 * 24 * 60 * 60

    public let url: URL
    private let log = Logger(subsystem: "CollectiveKit", category: "archive")

    public init(url: URL) { self.url = url }

    /// The marks younger than `retention`. A missing file is no marks; a file that
    /// can't be read only costs the marks, never the launch: it is logged.
    public func load(now: Date) -> [ArchiveTarget: Date] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: url))
            return Self.current(Dictionary(stored.marks.map { ($0.target, $0.archivedAt) },
                                           uniquingKeysWith: max), now: now)
        } catch {
            log.error("Not loading \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    /// Writes the marks younger than `retention`, replacing the file atomically so a
    /// crash never leaves half of it. Failures are logged: the marks stay in memory.
    public func save(_ marks: [ArchiveTarget: Date], now: Date) {
        let stored = Stored(version: Stored.currentVersion, marks: Self.current(marks, now: now)
            .map { Mark(target: $0.key, archivedAt: $0.value) }
            .sorted { $0.archivedAt < $1.archivedAt })
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(stored).write(to: url, options: .atomic)
        } catch {
            log.error("Not saving \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private static func current(_ marks: [ArchiveTarget: Date], now: Date) -> [ArchiveTarget: Date] {
        marks.filter { now.timeIntervalSince($0.value) <= retention }
    }

    /// An array, not a dictionary: enum keys don't encode as JSON object keys.
    /// Dates stay `Date`'s own seconds since 2001, so they load back exactly.
    private struct Stored: Codable {
        static let currentVersion = 1
        var version: Int
        var marks: [Mark]
    }

    private struct Mark: Codable {
        var target: ArchiveTarget
        var archivedAt: Date
    }
}
