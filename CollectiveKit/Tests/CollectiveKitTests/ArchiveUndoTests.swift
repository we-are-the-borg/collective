import Foundation
import Testing
@testable import CollectiveKit

private let s1 = SessionKey(source: "test-tool", sessionID: "s1")
private let s2 = SessionKey(source: "test-tool", sessionID: "s2")
private let t0 = Date(timeIntervalSince1970: 1_000)

private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// Two working sessions.
private func busy() -> CollectiveState {
    var state = CollectiveState()
    state.apply(AgentEvent(session: s1, timestamp: t0, kind: .promptSubmitted("go")))
    state.apply(AgentEvent(session: s2, timestamp: t0, kind: .promptSubmitted("go")))
    return state
}

@Suite struct ArchiveUndoTests {
    @Test func eachKindNamesWhatItArchives() {
        #expect(ArchiveUndo.Kind.session(s1).targets == [.session(s1)])
        #expect(ArchiveUndo.Kind.finishedSession(s1).targets == [.session(s1)])
        #expect(ArchiveUndo.Kind.allFinished([s1, s2]).targets == [.session(s1), .session(s2)])
    }

    @Test func archivingMarksTheTargetsAndKeepsAnUndoEntry() throws {
        var state = busy()
        var undo = ArchiveUndo()
        let id = undo.archive(.allFinished([s1, s2]), in: &state, at: at(10))

        #expect(state.archiveMarks == [.session(s1): at(10), .session(s2): at(10)])
        let entry = try #require(undo.last)
        #expect(entry.id == id)
        #expect(entry.kind == .allFinished([s1, s2]))
    }

    @Test func undoUnarchivesExactlyItsTargetsAndDropsTheEntry() {
        var state = busy()
        var undo = ArchiveUndo()
        let first = undo.archive(.session(s1), in: &state, at: at(10))
        undo.archive(.session(s2), in: &state, at: at(11))

        undo.undo(first, in: &state)
        #expect(state.archiveMarks == [.session(s2): at(11)])
        #expect(undo.entries.map(\.kind) == [.session(s2)])
    }

    @Test func undoLastTakesTheNewestEntry() {
        var state = busy()
        var undo = ArchiveUndo()
        undo.archive(.session(s1), in: &state, at: at(10))
        undo.archive(.session(s2), in: &state, at: at(11))

        undo.undoLast(in: &state)
        #expect(state.archiveMarks == [.session(s1): at(10)])
        undo.undoLast(in: &state)
        #expect(state.archiveMarks.isEmpty)
        #expect(undo.last == nil)
        undo.undoLast(in: &state)
    }

    @Test func anEntryWhoseTargetsCameBackIsDropped() {
        var state = busy()
        var undo = ArchiveUndo()
        let kept = undo.archive(.session(s2), in: &state, at: at(10))
        undo.archive(.session(s1), in: &state, at: at(11))
        undo.pause(undo.entries[1].id, at: at(12))

        state.apply(AgentEvent(session: s1, timestamp: at(13), kind: .promptSubmitted("again")))
        undo.dropRevived(in: state)
        #expect(undo.entries.map(\.id) == [kept])
    }

    @Test func anEntryKeepsItsPlaceWhileAnyTargetIsStillArchived() {
        var state = busy()
        var undo = ArchiveUndo()
        let id = undo.archive(.allFinished([s1, s2]), in: &state, at: at(10))

        state.apply(AgentEvent(session: s1, timestamp: at(11), kind: .promptSubmitted("again")))
        undo.dropRevived(in: state)
        #expect(undo.entries.map(\.id) == [id])
    }

    @Test func undoLastSkipsAnEntryWithNothingLeftToUndo() {
        var state = busy()
        var undo = ArchiveUndo()
        undo.archive(.session(s2), in: &state, at: at(10))
        undo.archive(.session(s1), in: &state, at: at(11))
        state.apply(AgentEvent(session: s1, timestamp: at(12), kind: .promptSubmitted("again")))
        #expect(state.archiveMarks == [.session(s2): at(10)])

        undo.undoLast(in: &state)
        #expect(state.archiveMarks.isEmpty)
        #expect(undo.entries.isEmpty)
    }

    @Test func undoingABulkEntryLeavesASessionArchivedAgainOnItsOwn() {
        var state = busy()
        var undo = ArchiveUndo()
        let bulk = undo.archive(.allFinished([s1, s2]), in: &state, at: at(10))
        state.apply(AgentEvent(session: s1, timestamp: at(11), kind: .promptSubmitted("again")))
        let single = undo.archive(.finishedSession(s1), in: &state, at: at(12))

        undo.undo(bulk, in: &state)
        #expect(state.archiveMarks == [.session(s1): at(12)])
        undo.undo(single, in: &state)
        #expect(state.archiveMarks.isEmpty)
    }

    @Test func undoLastTakesBackOnlyWhatEachEntryArchived() {
        var state = busy()
        var undo = ArchiveUndo()
        undo.archive(.allFinished([s1, s2]), in: &state, at: at(10))
        state.apply(AgentEvent(session: s1, timestamp: at(11), kind: .promptSubmitted("again")))
        undo.archive(.session(s1), in: &state, at: at(12))

        undo.undoLast(in: &state)
        #expect(state.archiveMarks == [.session(s2): at(10)])

        // Archived again and its row gone: ⌘Z reaches the bulk entry, which leaves s1 alone.
        let again = undo.archive(.session(s1), in: &state, at: at(13))
        undo.remove(again)
        undo.undoLast(in: &state)
        #expect(state.archiveMarks == [.session(s1): at(13)])
        #expect(undo.entries.isEmpty)
    }

    @Test func anEntryWhoseSessionWasArchivedAgainHasNothingToUndo() {
        var state = busy()
        var undo = ArchiveUndo()
        let old = undo.archive(.session(s1), in: &state, at: at(10))
        state.apply(AgentEvent(session: s1, timestamp: at(11), kind: .promptSubmitted("again")))
        let newer = undo.archive(.session(s1), in: &state, at: at(12))

        undo.undo(old, in: &state)
        #expect(state.archiveMarks == [.session(s1): at(12)])
        undo.dropRevived(in: state)
        #expect(undo.entries.map(\.id) == [newer])
    }

    @Test func dropRevivedKeepsAnEntryWithOneMarkOfItsOwn() {
        let s3 = SessionKey(source: "test-tool", sessionID: "s3")
        var state = busy()
        var undo = ArchiveUndo()
        let kept = undo.archive(.allFinished([s1, s3]), in: &state, at: at(10))
        undo.archive(.allFinished([s2]), in: &state, at: at(11))
        state.apply(AgentEvent(session: s1, timestamp: at(12), kind: .promptSubmitted("again")))
        state.apply(AgentEvent(session: s2, timestamp: at(12), kind: .promptSubmitted("again")))
        let newer = undo.archive(.allFinished([s1, s2]), in: &state, at: at(13))

        undo.dropRevived(in: state)
        #expect(undo.entries.map(\.id) == [kept, newer])
    }

    @Test func aPausedEntryThatCameBackDoesNotHoldBackTheNextExpiry() {
        var state = busy()
        var undo = ArchiveUndo()
        undo.archive(.session(s2), in: &state, at: at(10))
        let revived = undo.archive(.session(s1), in: &state, at: at(11))
        undo.pause(revived, at: at(12))

        state.apply(AgentEvent(session: s1, timestamp: at(13), kind: .promptSubmitted("again")))
        undo.dropRevived(in: state)
        #expect(undo.nextExpiry(after: at(13)) == at(16))
        undo.removeExpired(at: at(16))
        #expect(undo.entries.isEmpty)
    }

    @Test func anEntryIsVisibleForSixSeconds() {
        var state = busy()
        var undo = ArchiveUndo()
        let id = undo.archive(.session(s1), in: &state, at: at(10))

        #expect(undo.isVisible(id, at: at(10)))
        #expect(undo.isVisible(id, at: at(15.9)))
        #expect(!undo.isVisible(id, at: at(16)))
        #expect(undo.nextExpiry(after: at(10)) == at(16))
    }

    @Test func thePointerOnTheRowPausesTheCountdown() {
        var state = busy()
        var undo = ArchiveUndo()
        let id = undo.archive(.session(s1), in: &state, at: at(10))

        undo.pause(id, at: at(12))
        #expect(undo.isVisible(id, at: at(100)))
        #expect(undo.nextExpiry(after: at(12)) == nil)

        // 4 s were left when the pointer arrived.
        undo.resume(id, at: at(100))
        #expect(undo.nextExpiry(after: at(100)) == at(104))
        #expect(undo.isVisible(id, at: at(103.9)))
        #expect(!undo.isVisible(id, at: at(104)))
    }

    @Test func pausingTwiceOrResumingARunningEntryChangesNothing() {
        var state = busy()
        var undo = ArchiveUndo()
        let id = undo.archive(.session(s1), in: &state, at: at(10))

        undo.resume(id, at: at(12))
        #expect(undo.nextExpiry(after: at(12)) == at(16))
        undo.pause(id, at: at(12))
        undo.pause(id, at: at(14))
        undo.resume(id, at: at(20))
        #expect(undo.nextExpiry(after: at(20)) == at(24))
    }

    @Test func nextExpiryIsTheSoonestStillAhead() {
        var state = busy()
        var undo = ArchiveUndo()
        undo.archive(.session(s1), in: &state, at: at(10))
        undo.archive(.session(s2), in: &state, at: at(12))

        #expect(undo.nextExpiry(after: at(13)) == at(16))
        #expect(undo.nextExpiry(after: at(16)) == at(18))
        #expect(undo.nextExpiry(after: at(18)) == nil)
    }

    @Test func expiredEntriesAreRemovedAndTheirArchiveStays() {
        var state = busy()
        var undo = ArchiveUndo()
        let first = undo.archive(.session(s1), in: &state, at: at(10))
        let second = undo.archive(.session(s2), in: &state, at: at(12))

        let removed = undo.removeExpired(at: at(16))
        #expect(removed.map(\.id) == [first])
        #expect(undo.entries.map(\.id) == [second])
        #expect(state.isArchived(s1))
    }

    @Test func closingThePopoverCommitsEverything() {
        var state = busy()
        var undo = ArchiveUndo()
        undo.archive(.session(s1), in: &state, at: at(10))
        undo.archive(.session(s2), in: &state, at: at(11))

        undo.commitAll()
        #expect(undo.entries.isEmpty)
        #expect(state.isArchived(s1) && state.isArchived(s2))
    }

    @Test func removeDropsAnEntryWithoutTouchingTheState() {
        var state = busy()
        var undo = ArchiveUndo()
        let id = undo.archive(.session(s1), in: &state, at: at(10))

        undo.remove(id)
        #expect(undo.entries.isEmpty)
        #expect(!undo.isVisible(id, at: at(10)))
        #expect(state.isArchived(s1))
    }

    // MARK: Subagents

    /// `s1` working with a working subagent `a`, and `s2`.
    private func withSubagent() -> CollectiveState {
        var state = busy()
        state.apply(AgentEvent(session: s1, timestamp: t0, kind: .agentSpawned(id: "a", parent: .root, spec: AgentSpec(type: "Explore"))))
        return state
    }

    @Test func aSubagentEntryArchivesThatAgentOnly() throws {
        #expect(ArchiveUndo.Kind.subagent(s1, .subagent("a")).targets == [.agent(s1, .subagent("a"))])
        var state = withSubagent()
        var undo = ArchiveUndo()
        let id = undo.archive(.subagent(s1, .subagent("a")), in: &state, at: at(10))

        #expect(state.archiveMarks == [.agent(s1, .subagent("a")): at(10)])
        #expect(state.isArchived(.subagent("a"), in: s1))
        #expect(!state.isArchived(s1))
        #expect(try #require(undo.last).id == id)
    }

    @Test func undoingASubagentBringsItBack() {
        var state = withSubagent()
        var undo = ArchiveUndo()
        let id = undo.archive(.subagent(s1, .subagent("a")), in: &state, at: at(10))

        undo.undo(id, in: &state)
        #expect(state.archiveMarks.isEmpty)
        #expect(undo.entries.isEmpty)
    }

    @Test func undoLastTakesBackANewerSubagentEntryFirst() {
        var state = withSubagent()
        var undo = ArchiveUndo()
        undo.archive(.session(s2), in: &state, at: at(10))
        undo.archive(.subagent(s1, .subagent("a")), in: &state, at: at(11))

        undo.undoLast(in: &state)
        #expect(state.archiveMarks == [.session(s2): at(10)])
    }

    @Test func aSubagentBackAtWorkAndArchivedAgainBelongsToTheNewerEntry() {
        var state = withSubagent()
        var undo = ArchiveUndo()
        let old = undo.archive(.subagent(s1, .subagent("a")), in: &state, at: at(10))
        state.apply(AgentEvent(session: s1, timestamp: at(11), kind: .toolStarted(agent: .subagent("a"), ToolActivity(name: "Bash"))))
        #expect(state.archiveMarks.isEmpty)
        let newer = undo.archive(.subagent(s1, .subagent("a")), in: &state, at: at(12))

        undo.undo(old, in: &state)
        #expect(state.archiveMarks == [.agent(s1, .subagent("a")): at(12)])
        undo.dropRevived(in: state)
        #expect(undo.entries.map(\.id) == [newer])
    }

    /// The session's archive and undo leave the subagent's own mark and entry alone.
    @Test func aSessionArchivedWhileASubagentsUndoIsPendingLeavesItsEntryIntact() {
        var state = withSubagent()
        var undo = ArchiveUndo()
        let agent = undo.archive(.subagent(s1, .subagent("a")), in: &state, at: at(10))
        let session = undo.archive(.session(s1), in: &state, at: at(11))

        undo.undoLast(in: &state)
        #expect(state.archiveMarks == [.agent(s1, .subagent("a")): at(10)])
        #expect(undo.entries.map(\.id) == [agent])
        #expect(!undo.entries.contains { $0.id == session })

        undo.undoLast(in: &state)
        #expect(state.archiveMarks.isEmpty)
        #expect(undo.entries.isEmpty)
    }

    @Test func undoingASubagentLeavesItsSessionsNewerArchive() {
        var state = withSubagent()
        var undo = ArchiveUndo()
        let agent = undo.archive(.subagent(s1, .subagent("a")), in: &state, at: at(10))
        undo.archive(.session(s1), in: &state, at: at(11))

        undo.undo(agent, in: &state)
        #expect(state.archiveMarks == [.session(s1): at(11)])
        #expect(state.isArchived(.subagent("a"), in: s1))
    }
}
