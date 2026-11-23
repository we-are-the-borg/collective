import Foundation

/// How a reading of the spool starts from the read file. Saved
/// marks go into the state before the backlog replays, as archive marks do.
/// Without a file the app never saved any: the first launch with this
/// feature. Then whatever the first backlog brings counts as read, so old
/// sessions don't all show a dot; a file that
/// exists, empty or not, is restored as it is.
public struct ReadMarksStart: Sendable, Equatable {
    private var marksBacklogRead: Bool

    /// - Parameter loaded: What `ReadFile.load` returned, nil without a file.
    public init(restoring loaded: [SessionKey: Date]?, into state: inout CollectiveState) {
        state.restoreReadMarks(loaded ?? [:])
        marksBacklogRead = loaded == nil
    }

    /// When the reader's backlog is read. True once, without a file: the
    /// caller saves then, even without marks, so the next launch finds one.
    public mutating func backlogFinished(in state: inout CollectiveState) -> Bool {
        guard marksBacklogRead else { return false }
        marksBacklogRead = false
        state.markAllRead()
        return true
    }
}
