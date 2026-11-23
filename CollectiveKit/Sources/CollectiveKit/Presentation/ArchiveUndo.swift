import Foundation

/// The archives the user can still take back. Archiving asks for no
/// confirmation; instead the archived item turns into an undo row for a few
/// seconds. The app keeps this while it runs, like `PopoverExpansion`, and
/// passes it into every `PopoverModel`, which shows the rows in place.
public struct ArchiveUndo: Sendable, Equatable {
    /// How long an undo row stays while the pointer is elsewhere.
    public static let lifetime: TimeInterval = 6

    public struct ID: Hashable, Sendable {
        let rawValue: Int
    }

    /// What the user archived in one action; it decides where the undo row
    /// shows and what Undo brings back.
    public enum Kind: Hashable, Sendable {
        case session(SessionKey)
        case finishedSession(SessionKey)
        /// "Archive All Finished": the finished sessions listed at that moment.
        case allFinished([SessionKey])
        /// "Archive Subagent" on a row of a card's subagent list: the agent
        /// and, through the store's rule, its subtree.
        case subagent(SessionKey, AgentRef)

        public var targets: [ArchiveTarget] {
            switch self {
            case let .session(key), let .finishedSession(key): [.session(key)]
            case let .allFinished(keys): keys.map { .session($0) }
            case let .subagent(key, agent): [.agent(key, agent)]
            }
        }
    }

    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: ID
        public let kind: Kind
        /// The date it gave its marks: a target that came back and was archived
        /// again carries a newer action's date and is no longer this entry's.
        fileprivate let archivedAt: Date
        /// Countdown left when it last stopped or started running.
        fileprivate var remaining: TimeInterval
        /// `nil` while paused.
        fileprivate var runningSince: Date?

        /// `nil` while paused: a row under the pointer never expires.
        var expiry: Date? { runningSince.map { $0.addingTimeInterval(remaining) } }

        /// Its own marks only: a target still hidden by a wider mark, or
        /// archived again by a newer entry, has nothing of this one's to undo.
        func ownTargets(in state: CollectiveState) -> [ArchiveTarget] {
            kind.targets.filter { state.archiveMarks[$0] == archivedAt }
        }

        func hasArchived(in state: CollectiveState) -> Bool {
            !ownTargets(in: state).isEmpty
        }
    }

    /// Oldest first.
    public private(set) var entries: [Entry] = []
    private var nextID = 0

    public init() {}

    /// The newest entry, which ⌘Z takes back.
    public var last: Entry? { entries.last }

    /// Archives `kind`'s targets in `state` and keeps an entry to undo them.
    @discardableResult
    public mutating func archive(_ kind: Kind, in state: inout CollectiveState, at date: Date) -> ID {
        for target in kind.targets { state.archive(target, at: date) }
        let id = ID(rawValue: nextID)
        nextID += 1
        entries.append(Entry(id: id, kind: kind, archivedAt: date, remaining: Self.lifetime, runningSince: date))
        return id
    }

    /// Brings back what the entry archived and drops it.
    public mutating func undo(_ id: ID, in state: inout CollectiveState) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        for target in entry.ownTargets(in: state) { state.unarchive(target) }
        remove(id)
    }

    /// ⌘Z: undoes the newest entry that still has something to undo, if any.
    public mutating func undoLast(in state: inout CollectiveState) {
        dropRevived(in: state)
        if let last { undo(last.id, in: &state) }
    }

    /// Drops the entries whose targets all came back with new work
    /// (`CollectiveState.apply`), even if archived again since. Their row is
    /// gone, so the pointer can never leave it, and a paused entry would
    /// otherwise stay forever.
    public mutating func dropRevived(in state: CollectiveState) {
        entries.removeAll { !$0.hasArchived(in: state) }
    }

    public func isVisible(_ id: ID, at date: Date) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        return entry.expiry.map { date < $0 } ?? true
    }

    public mutating func pause(_ id: ID, at date: Date) {
        update(id) { entry in
            guard let since = entry.runningSince else { return }
            entry.remaining -= date.timeIntervalSince(since)
            entry.runningSince = nil
        }
    }

    public mutating func resume(_ id: ID, at date: Date) {
        update(id) { entry in
            if entry.runningSince == nil { entry.runningSince = date }
        }
    }

    /// When the app's timer should next fire to let a row go; `nil` while no
    /// running row is left.
    public func nextExpiry(after date: Date) -> Date? {
        entries.compactMap(\.expiry).filter { $0 > date }.min()
    }

    /// Drops the entries whose time is up; their archive stays.
    @discardableResult
    public mutating func removeExpired(at date: Date) -> [Entry] {
        let isExpired = { (entry: Entry) in entry.expiry.map { $0 <= date } ?? false }
        let expired = entries.filter(isExpired)
        entries.removeAll(where: isExpired)
        return expired
    }

    /// Closing the popover commits: every archive stays, no row is left.
    public mutating func commitAll() {
        entries.removeAll()
    }

    public mutating func remove(_ id: ID) {
        entries.removeAll { $0.id == id }
    }

    private mutating func update(_ id: ID, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }
}
