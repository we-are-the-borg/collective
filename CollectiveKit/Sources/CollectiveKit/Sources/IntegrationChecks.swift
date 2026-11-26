import Foundation
import Observation
import SubspaceKit

/// The checks of the tools' subspace integrations, per source: each probe's
/// result shows as soon as it arrives, so a CLI that hangs until its timeout
/// holds back only its own source. Checks of one source never overlap: one
/// asked for meanwhile follows the running one, so a "Check Again" after
/// fixing something is never answered by a check that started before the fix.
///
/// Probes must be unique per source (one per tool, as the app registers them
/// today): checks and statuses are kept by source, and two probes of one
/// source are not merged.
@MainActor @Observable
public final class IntegrationChecks {
    /// What each probe last reported, in the probes' order (so the first tool
    /// listed wins ties, `ConnectionStatus`); a source that never reported is absent.
    public var statuses: [IntegrationStatus] { probes.compactMap { results[$0.source] } }
    /// When the probe behind each source's status started, by source.
    public private(set) var checkedAt: [SourceID: Date] = [:]

    private var probes: [any IntegrationProbe]
    private var results: [SourceID: IntegrationStatus] = [:]
    /// When each source's last result arrived, for `checkIfStale(freshness:)`.
    private var finishedAt: [SourceID: Date] = [:]
    private var inFlight: Set<SourceID> = []
    /// Sources whose next check follows the one in flight.
    private var pending: Set<SourceID> = []
    private let now: @MainActor () -> Date
    private let onResult: @MainActor (IntegrationStatus, Date) -> Void

    /// - Parameters:
    ///   - probes: One per source; their order is the order of `statuses`.
    ///   - onResult: Called once per result, after it is stored, with the
    ///     status as `statuses` holds it and when its probe started.
    public init(probes: [any IntegrationProbe], now: @escaping @MainActor () -> Date = { Date() },
                onResult: @escaping @MainActor (IntegrationStatus, _ startedAt: Date) -> Void) {
        self.probes = probes
        self.now = now
        self.onResult = onResult
    }

    /// Whether every source has reported at least once: the first round has finished.
    /// Also true while there are no probes (before `replaceProbes`): nothing left to wait for.
    public var allReported: Bool { probes.allSatisfy { results[$0.source] != nil } }

    /// Checks every source; one whose check is still running checks once more after it.
    public func check() {
        for probe in probes { check(probe.source) }
    }

    /// Checks the sources whose last result arrived more than `freshness`
    /// ago, and those that never reported; the probes run CLIs, so the popover
    /// opening calls this rather than `check()`. One in flight counts as fresh.
    public func checkIfStale(freshness: TimeInterval) {
        let now = now()
        for probe in probes where !inFlight.contains(probe.source) {
            if let finished = finishedAt[probe.source], now.timeIntervalSince(finished) <= freshness { continue }
            check(probe.source)
        }
    }

    /// The app registers new probes when the event folders change and checks
    /// afterwards; this starts nothing itself. Later checks use the new probes,
    /// statuses of sources no longer present are dropped. A check still in
    /// flight keeps running: its result counts if its source is still present
    /// (else it is dropped), and a check asked for meanwhile follows it with the new probe.
    public func replaceProbes(_ probes: [any IntegrationProbe]) {
        self.probes = probes
        let present = Set(probes.map(\.source))
        results = results.filter { present.contains($0.key) }
        checkedAt = checkedAt.filter { present.contains($0.key) }
        finishedAt = finishedAt.filter { present.contains($0.key) }
        pending.formIntersection(present)
    }

    private func check(_ source: SourceID) {
        guard !inFlight.contains(source) else {
            pending.insert(source)
            return
        }
        guard let probe = probes.first(where: { $0.source == source }) else { return }
        inFlight.insert(source)
        let startedAt = now()
        Task { [weak self] in
            let status = await Self.run(probe)
            self?.finished(status, of: source, startedAt: startedAt)
        }
    }

    @concurrent nonisolated private static func run(_ probe: any IntegrationProbe) async -> IntegrationStatus {
        await probe.check()
    }

    private func finished(_ status: IntegrationStatus, of source: SourceID, startedAt: Date) {
        inFlight.remove(source)
        guard probes.contains(where: { $0.source == source }) else { return }
        // A list that failed keeps the last known plugin state.
        let status = status.keepingKnownPlugin(from: results[source])
        results[source] = status
        checkedAt[source] = startedAt
        finishedAt[source] = now()
        onResult(status, startedAt)
        if pending.remove(source) != nil { check(source) }
    }
}
