import Foundation

/// The unread rows the user saw while the popover was open, read only once it
/// closes: nothing disappears under the user's eyes. A row counts
/// up to the turn end it showed when last reported, so a turn ending after
/// that stays unread unless the popover reports the row again.
public struct UnreadReading: Sendable, Equatable {
    /// The newest turn end seen per session.
    private var seen: [SessionKey: Date] = [:]

    public init() {}

    /// Nothing seen since the last commit.
    public var isEmpty: Bool { seen.isEmpty }

    /// The popover showed `item`: when it became visible, and again when a
    /// visible row's `unreadTurnEndedAt` changes. A read row records nothing.
    public mutating func saw(_ item: SessionItem) {
        guard let ended = item.unreadTurnEndedAt else { return }
        seen[item.key] = max(seen[item.key] ?? ended, ended)
    }

    /// Marks what was seen read, on closing, and starts over.
    public mutating func commit(into state: inout CollectiveState) {
        for (key, ended) in seen { state.markRead(key, upTo: ended) }
        seen = [:]
    }
}
