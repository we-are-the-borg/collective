import Foundation
import SubspaceKit
import Synchronization
import Testing
@testable import CollectiveKit

// When each tool's probe runs and when its result shows, per source.

// MARK: - Helpers

/// Hands out probes that report only what the test releases for their
/// source, one release per check, so a test can act while a check runs. A
/// release before the check starts waits for it.
private final class ProbeGate: Sendable {
    private struct State {
        var waiting: [SourceID: [CheckedContinuation<IntegrationStatus, Never>]] = [:]
        var released: [SourceID: [IntegrationStatus]] = [:]
        var starts: [SourceID: Int] = [:]
    }

    private let state = Mutex(State())

    func probe(_ source: SourceID) -> GatedProbe { GatedProbe(source: source, gate: self) }

    /// How many checks of `source` have started so far.
    func starts(_ source: SourceID) -> Int { state.withLock { $0.starts[source, default: 0] } }

    /// The oldest waiting check of `status.source` returns `status`, or the next one to start.
    func release(_ status: IntegrationStatus) {
        let waiting = state.withLock { state -> CheckedContinuation<IntegrationStatus, Never>? in
            if let first = state.waiting[status.source]?.first {
                state.waiting[status.source]?.removeFirst()
                return first
            }
            state.released[status.source, default: []].append(status)
            return nil
        }
        waiting?.resume(returning: status)
    }

    fileprivate func check(_ source: SourceID) async -> IntegrationStatus {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> IntegrationStatus? in
                state.starts[source, default: 0] += 1
                if let first = state.released[source]?.first {
                    state.released[source]?.removeFirst()
                    return first
                }
                state.waiting[source, default: []].append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

private struct GatedProbe: IntegrationProbe {
    let source: SourceID
    let gate: ProbeGate
    var commands: SetupCommands { integration(.unknown, source: source).commands }
    func check() async -> IntegrationStatus { await gate.check(source) }
}

@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_000)
}

/// The checks under test, with every result they report in arrival order.
@MainActor
private struct Harness {
    let gate = ProbeGate()
    let clock = Clock()
    let checks: IntegrationChecks
    let results: AsyncStream<(status: IntegrationStatus, startedAt: Date)>

    init(_ sources: [SourceID]) {
        let gate = gate
        let clock = clock
        let (results, continuation) = AsyncStream.makeStream(of: (status: IntegrationStatus, startedAt: Date).self)
        self.results = results
        checks = IntegrationChecks(probes: sources.map(gate.probe), now: { clock.now }) { status, startedAt in
            continuation.yield((status, startedAt))
        }
    }
}

private let a: SourceID = "tool-a"
private let b: SourceID = "tool-b"
private let c: SourceID = "tool-c"
private let start = Date(timeIntervalSince1970: 1_000)

// MARK: - Tests

@MainActor
@Suite(.timeLimit(.minutes(1))) struct IntegrationChecksTests {
    @Test func aProbeThatNeverReturnsDoesNotHoldBackAnother() async {
        let harness = Harness([a, b])
        var results = harness.results.makeAsyncIterator()
        let reported = integration(.enabled(version: "1.0.0"), source: a)
        harness.checks.check()
        harness.gate.release(reported)
        let first = await results.next()
        #expect(first?.status == reported)
        #expect(harness.checks.statuses == [reported])
        #expect(harness.checks.checkedAt == [a: start])
        #expect(!harness.checks.allReported)
        harness.gate.release(integration(.enabled(version: nil), source: b))
        _ = await results.next()
    }

    @Test func checkedAtIsWhenEachSourcesProbeStarted() async {
        let harness = Harness([a, b])
        var results = harness.results.makeAsyncIterator()
        harness.checks.check()
        harness.gate.release(integration(.enabled(version: nil), source: a))
        _ = await results.next()
        harness.clock.now = later(1)
        // a starts again, b still runs its first check.
        harness.checks.check()
        harness.gate.release(integration(.enabled(version: nil), source: a))
        let second = await results.next()
        #expect(second?.startedAt == later(1))
        #expect(harness.checks.checkedAt == [a: later(1)])
        harness.gate.release(integration(.enabled(version: nil), source: b))
        let third = await results.next()
        #expect(third?.startedAt == start)
        #expect(harness.checks.checkedAt == [a: later(1), b: start])
        // b's follow-up of the second check.
        harness.gate.release(integration(.enabled(version: nil), source: b))
        _ = await results.next()
    }

    @Test func checksOfOneSourceNeverOverlapAndOneFollowUpComesAfter() async {
        let harness = Harness([a])
        var results = harness.results.makeAsyncIterator()
        let firstStatus = integration(.notInstalled, source: a)
        let followUpStatus = integration(.enabled(version: "1.0.0"), source: a)
        harness.checks.check()
        harness.clock.now = later(1)
        harness.checks.check()
        harness.clock.now = later(2)
        harness.checks.check()
        harness.gate.release(firstStatus)
        let first = await results.next()
        #expect(first?.status == firstStatus)
        #expect(first?.startedAt == start)
        // The follow-up starts when the first is done, not when it was asked for.
        harness.gate.release(followUpStatus)
        let followUp = await results.next()
        #expect(followUp?.status == followUpStatus)
        #expect(followUp?.startedAt == later(2))
        #expect(harness.checks.statuses == [followUpStatus])
        // Only one follow-up: the next result is the next check's.
        harness.clock.now = later(3)
        harness.gate.release(followUpStatus)
        harness.checks.check()
        let next = await results.next()
        #expect(next?.startedAt == later(3))
        #expect(harness.gate.starts(a) == 3)
    }

    @Test func aFailedListKeepsThePreviousPlugin() async {
        let harness = Harness([a])
        var results = harness.results.makeAsyncIterator()
        harness.checks.check()
        harness.gate.release(integration(.enabled(version: "1.0.0"), source: a))
        _ = await results.next()
        harness.checks.check()
        harness.gate.release(integration(.unknown, source: a))
        var expected = integration(.enabled(version: "1.0.0"), source: a)
        expected.pluginIsCarriedOver = true
        let second = await results.next()
        #expect(second?.status == expected)
        #expect(harness.checks.statuses == [expected])
    }

    @Test func statusesKeepTheProbesOrderWhateverArrivesFirst() async {
        let harness = Harness([a, b, c])
        var results = harness.results.makeAsyncIterator()
        let statusA = integration(.enabled(version: nil), source: a)
        let statusB = integration(.notInstalled, source: b)
        let statusC = integration(.disabled(version: nil), source: c)
        harness.checks.check()
        #expect(harness.checks.statuses.isEmpty)
        #expect(!harness.checks.allReported)
        harness.gate.release(statusC)
        _ = await results.next()
        harness.gate.release(statusA)
        _ = await results.next()
        #expect(harness.checks.statuses == [statusA, statusC])
        #expect(!harness.checks.allReported)
        harness.gate.release(statusB)
        _ = await results.next()
        #expect(harness.checks.statuses == [statusA, statusB, statusC])
        #expect(harness.checks.allReported)
    }

    @Test func theCallbackGetsEachResultWithItsStart() async {
        let harness = Harness([a, b])
        var results = harness.results.makeAsyncIterator()
        let statusA = integration(.enabled(version: nil), source: a)
        let statusB = integration(.notInstalled, source: b)
        harness.checks.check()
        harness.clock.now = later(5)
        harness.gate.release(statusB)
        let first = await results.next()
        harness.gate.release(statusA)
        let second = await results.next()
        #expect(first?.status == statusB)
        #expect(first?.startedAt == start)
        #expect(second?.status == statusA)
        #expect(second?.startedAt == start)
    }

    // MARK: Staleness

    @Test func checkIfStaleChecksOnlySourcesWhoseLastResultIsOlderThanTheFreshness() async {
        let harness = Harness([a, b])
        var results = harness.results.makeAsyncIterator()
        harness.checks.check()
        harness.gate.release(integration(.enabled(version: nil), source: a))
        _ = await results.next()
        harness.clock.now = later(8)
        harness.gate.release(integration(.enabled(version: nil), source: b))
        _ = await results.next()
        // a finished 12 s ago, b 4 s ago.
        harness.clock.now = later(12)
        harness.checks.checkIfStale(freshness: 10)
        harness.gate.release(integration(.enabled(version: nil), source: a))
        harness.gate.release(integration(.enabled(version: nil), source: b))
        let stale = await results.next()
        #expect(stale?.status.source == a)
        #expect(stale?.startedAt == later(12))
        // b's release waits for the next check: b was not started.
        harness.clock.now = later(13)
        harness.checks.check()
        harness.gate.release(integration(.enabled(version: nil), source: a))
        let next = [await results.next(), await results.next()]
        #expect(next.first { $0?.status.source == b }??.startedAt == later(13))
    }

    @Test func aSourceThatNeverReportedIsStale() async {
        let harness = Harness([a])
        var results = harness.results.makeAsyncIterator()
        harness.checks.checkIfStale(freshness: 10)
        harness.gate.release(integration(.enabled(version: nil), source: a))
        let first = await results.next()
        #expect(first?.startedAt == start)
    }

    @Test func aSourceInFlightIsNotCheckedAgainWhenStale() async {
        let harness = Harness([a])
        var results = harness.results.makeAsyncIterator()
        harness.checks.check()
        harness.clock.now = later(30)
        harness.checks.checkIfStale(freshness: 10)
        harness.gate.release(integration(.enabled(version: nil), source: a))
        _ = await results.next()
        // No follow-up was queued: the next release waits for the next check.
        harness.clock.now = later(31)
        harness.gate.release(integration(.enabled(version: nil), source: a))
        harness.checks.check()
        let next = await results.next()
        #expect(next?.startedAt == later(31))
    }

    // MARK: Replacing the probes

    @Test func replacedProbesDropRemovedSourcesAndCheckWithTheNewOnes() async {
        let harness = Harness([a, b])
        var results = harness.results.makeAsyncIterator()
        let statusA = integration(.enabled(version: "1.0.0"), source: a)
        harness.checks.check()
        harness.gate.release(statusA)
        harness.gate.release(integration(.enabled(version: nil), source: b))
        _ = await results.next()
        _ = await results.next()
        let newGate = ProbeGate()
        harness.checks.replaceProbes([newGate.probe(a), newGate.probe(c)])
        #expect(harness.checks.statuses == [statusA])
        #expect(harness.checks.checkedAt == [a: start])
        #expect(!harness.checks.allReported)
        harness.clock.now = later(1)
        harness.checks.check()
        let newA = integration(.disabled(version: "1.0.0"), source: a)
        let newC = integration(.notInstalled, source: c)
        newGate.release(newA)
        newGate.release(newC)
        _ = await results.next()
        _ = await results.next()
        #expect(harness.checks.statuses == [newA, newC])
        #expect(harness.checks.checkedAt == [a: later(1), c: later(1)])
        #expect(harness.checks.allReported)
        #expect(harness.gate.starts(a) == 1)
    }

    @Test func aCheckInFlightWhenTheProbesAreReplacedIsFollowedByTheNewProbe() async {
        let harness = Harness([a, b])
        var results = harness.results.makeAsyncIterator()
        harness.checks.check()
        let newGate = ProbeGate()
        harness.checks.replaceProbes([newGate.probe(a)])
        harness.clock.now = later(1)
        harness.checks.check()
        // b's result comes from a source no longer registered and is dropped.
        harness.gate.release(integration(.enabled(version: nil), source: b))
        let oldA = integration(.notInstalled, source: a)
        harness.gate.release(oldA)
        let first = await results.next()
        #expect(first?.status == oldA)
        #expect(first?.startedAt == start)
        let newA = integration(.enabled(version: "1.0.0"), source: a)
        newGate.release(newA)
        let followUp = await results.next()
        #expect(followUp?.status == newA)
        #expect(followUp?.startedAt == later(1))
        #expect(harness.checks.statuses == [newA])
        #expect(harness.checks.checkedAt == [a: later(1)])
    }

    // MARK: Connection

    @Test func aMissingPluginWarnsOnlyOnceEverySourceReported() async {
        let harness = Harness([a, b])
        var results = harness.results.makeAsyncIterator()
        let missingA = integration(.notInstalled, source: a)
        harness.checks.check()
        harness.gate.release(missingA)
        _ = await results.next()
        #expect(ConnectionStatus(integrations: harness.checks.statuses, allReported: harness.checks.allReported) == .ok)
        harness.gate.release(integration(.notInstalled, source: b))
        _ = await results.next()
        #expect(ConnectionStatus(integrations: harness.checks.statuses, allReported: harness.checks.allReported) == .missing(missingA))
    }
}

private func later(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
