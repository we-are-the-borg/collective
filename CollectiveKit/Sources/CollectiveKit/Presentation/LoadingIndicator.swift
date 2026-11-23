import Foundation

/// When the popover shows its loading state while stored events are read after launch.
/// Only if reading takes longer than 300 ms, then for at least 500 ms, so a fast read never
/// flashes and a shown state never flickers.
public struct LoadingIndicator: Sendable, Equatable {
    public static let delay: TimeInterval = 0.3
    public static let minimumDuration: TimeInterval = 0.5

    public var launchedAt: Date
    /// nil while the stored events are still being read.
    public var backlogFinishedAt: Date?

    public init(launchedAt: Date, backlogFinishedAt: Date? = nil) {
        self.launchedAt = launchedAt
        self.backlogFinishedAt = backlogFinishedAt
    }

    private var showsAt: Date { launchedAt.addingTimeInterval(Self.delay) }

    /// False when reading finished within the delay: the state is never shown at all.
    private var isShownAtAll: Bool {
        guard let finished = backlogFinishedAt else { return true }
        return finished > showsAt
    }

    /// The moment the state goes away once it was shown; nil while reading continues.
    private var hidesAt: Date? {
        backlogFinishedAt.map { max($0, showsAt.addingTimeInterval(Self.minimumDuration)) }
    }

    public func isVisible(at now: Date) -> Bool {
        guard isShownAtAll, now >= showsAt else { return false }
        guard let hidesAt else { return true }
        return now < hidesAt
    }

    /// When `isVisible` next changes after `now`, so the app can schedule one wakeup. nil when
    /// it never changes again, or when the change depends on a finish time not known yet.
    public func nextChange(after now: Date) -> Date? {
        guard isShownAtAll else { return nil }
        if now < showsAt { return showsAt }
        guard let hidesAt, now < hidesAt else { return nil }
        return hidesAt
    }
}
