import Foundation
import SubspaceKit

/// When the newest event the app read fresh from each source's spool happened.
/// The setup window and the settings count a source that delivered as
/// connected even without subspace's record of a session start.
/// Only what the spool holds belongs here: neither a status file the app polls
/// itself nor what only the app's store kept (`SpoolReader.Output.replay`
/// hands over the times of only the rest) says that subspace delivers now.
public struct LastEventTimes: Sendable, Equatable {
    public private(set) var bySource: [SourceID: Date] = [:]

    public init() {}

    public mutating func record(_ batch: [AgentEvent]) {
        for event in batch {
            bySource[event.session.source] = max(bySource[event.session.source] ?? event.timestamp, event.timestamp)
        }
    }

    public mutating func merge(_ other: LastEventTimes) {
        bySource.merge(other.bySource, uniquingKeysWith: max)
    }
}
