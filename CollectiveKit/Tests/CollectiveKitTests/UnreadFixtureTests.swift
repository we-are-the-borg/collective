import Foundation
import Testing
@testable import CollectiveKit

/// The live spool `OrphanSpool` through the adapter and the reducer:
/// six turns, each ended by a root `Stop`, the last at `270-Stop`.
@Suite(.heavy) struct UnreadFixtureTests {
    private let lastStop = Date(timeIntervalSince1970: 1_791_191_064)

    @Test func theRootsLastStopLeavesTheSessionUnread() throws {
        var state = CollectiveState()
        try OrphanSpool.replay(OrphanSpool().events, onto: &state)

        #expect(state.isUnread(OrphanSpool.session))
        #expect(state.sessions[OrphanSpool.session]?.turnEndedAt == lastStop)
    }

    /// Between `255-UserPromptSubmit` and the stop the last turn runs: the
    /// stop before it at `247-Stop` is no longer news, nor are the subagents' stops.
    @Test func whileTheLastTurnRunsNothingIsUnread() throws {
        var state = CollectiveState()
        try OrphanSpool.replay(OrphanSpool().events(through: 269), onto: &state)

        #expect(!state.isUnread(OrphanSpool.session))
    }

    /// The mark saved after the last stop keeps a replay of the whole
    /// backlog read.
    @Test func aRestoredMarkKeepsTheReplayedStopRead() throws {
        var state = CollectiveState()
        state.restoreReadMarks([OrphanSpool.session: lastStop])
        try OrphanSpool.replay(OrphanSpool().events, onto: &state)

        #expect(!state.isUnread(OrphanSpool.session))
    }
}
