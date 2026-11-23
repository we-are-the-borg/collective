import Foundation
import os

/// The user's read marks on disk, so a session read before a restart doesn't
/// come back unread. Kept apart from the event store like the
/// archive marks (`ArchiveFile`): the store holds what subspace wrote, this
/// holds what the user saw.
///
/// Marks go by age only, never because their session left the state: the spool
/// and the event store can replay a pruned session on the next launch, and its
/// mark must still keep it read then.
public struct ReadFile: Sendable {
    /// How long a mark is kept after the turn end it covers, as for archive
    /// marks: well past what the spool and the event store replay.
    public static let retention: TimeInterval = ArchiveFile.retention

    public let url: URL
    private let log = Logger(subsystem: "CollectiveKit", category: "read")

    public init(url: URL) { self.url = url }

    /// The marks younger than `retention`, or nil without a file: then the
    /// app never saved any, and what the first backlog brings counts as read
    /// (`CollectiveState.markAllRead`). A file that can't be read only costs
    /// the marks, never the launch: it is logged and counts as one without marks.
    public func load(now: Date) -> [SessionKey: Date]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: url))
            return Self.current(Dictionary(stored.marks.map { ($0.session, $0.readUpTo) },
                                           uniquingKeysWith: max), now: now)
        } catch {
            log.error("Not loading \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    /// Writes the marks younger than `retention`, replacing the file atomically so a
    /// crash never leaves half of it. Failures are logged: the marks stay in memory.
    public func save(_ marks: [SessionKey: Date], now: Date) {
        let stored = Stored(version: Stored.currentVersion, marks: Self.current(marks, now: now)
            .map { Mark(session: $0.key, readUpTo: $0.value) }
            .sorted { $0.readUpTo < $1.readUpTo })
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(stored).write(to: url, options: .atomic)
        } catch {
            log.error("Not saving \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private static func current(_ marks: [SessionKey: Date], now: Date) -> [SessionKey: Date] {
        marks.filter { now.timeIntervalSince($0.value) <= retention }
    }

    /// An array, not a dictionary: struct keys don't encode as JSON object keys.
    /// Dates stay `Date`'s own seconds since 2001, so they load back exactly.
    private struct Stored: Codable {
        static let currentVersion = 1
        var version: Int
        var marks: [Mark]
    }

    private struct Mark: Codable {
        var session: SessionKey
        var readUpTo: Date
    }
}
