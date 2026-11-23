import Foundation
import Observation
import os
import SubspaceKit

/// Looks up the newest published subspace release per source from the public
/// git tags on GitHub. Everything tool-specific comes in as
/// `SubspaceRelease`, so the checker names no tool.
@MainActor @Observable
public final class SubspaceReleaseChecker {
    @ObservationIgnored private let client: any HTTPGetting
    @ObservationIgnored private let store: any SubspaceReleaseStore
    private var record: SubspaceReleaseRecord {
        didSet { store.record = record }
    }
    /// Observed, so `isChecking` updates `Check Now`.
    private var running: Task<Void, Never>?
    nonisolated private static let log = Logger(subsystem: "CollectiveKit", category: "subspace-updates")

    /// The settings switch "Check for updates automatically", one for the app
    /// and all sources. Off, the app asks GitHub nothing on its own and shows
    /// only what `Check Now` found; the releases found before stay stored, and
    /// switching on waits for the next due check.
    public var checksForUpdates: Bool {
        didSet { store.checksForUpdates = checksForUpdates }
    }

    public init(client: any HTTPGetting, store: any SubspaceReleaseStore) {
        self.client = client
        self.store = store
        record = store.record
        checksForUpdates = store.checksForUpdates
    }

    /// The newest release the last successful lookup found; with checking off
    /// only one that `Check Now` found.
    public func latest(for source: SourceID) -> SubspaceVersion? {
        guard let entry = record.sources[source.rawValue], checksForUpdates || entry.manual == true else { return nil }
        return entry.latest.flatMap(SubspaceVersion.init)
    }

    /// What the source's plugin should get, from the installed version the probe
    /// reported. The minimum ships with the adapter and needs no lookup, so it
    /// applies even with checking off.
    public func updateAvailability(for status: IntegrationStatus) -> UpdateAvailability {
        let installed: String? = switch status.plugin {
        case .enabled(let version), .disabled(let version): version
        case .notInstalled, .unknown: nil
        }
        let release = status.commands.release
        return UpdateAvailability(
            installed: installed,
            latest: release == nil ? nil : latest(for: status.source),
            minimum: release?.minimumVersion.flatMap(SubspaceVersion.init)
        )
    }

    /// How long the automatic check leaves a source alone after a lookup, also a failed one.
    public static let automaticInterval: TimeInterval = 24 * 60 * 60

    /// The automatic check, at launch and then as often as the caller likes:
    /// it only asks for sources whose last lookup is a day old. The time of the
    /// last lookup outlives a relaunch, so restarting never asks more often.
    /// - Returns: The lookup, or nil when nothing was due.
    @discardableResult
    public func checkIfDue(now: Date, sources: [SourceID: SubspaceRelease]) -> Task<Void, Never>? {
        lookUp(sources, olderThan: Self.automaticInterval, now: now)
    }

    /// How old the last lookup must be before opening Setup or a source pane asks again.
    public static let onOpenInterval: TimeInterval = 60 * 60

    /// When the user opens a place that shows updates: fresher than the
    /// automatic check, yet reopening a window never asks more than hourly.
    /// - Returns: The lookup, or nil when nothing was due.
    @discardableResult
    public func checkOnOpen(now: Date, sources: [SourceID: SubspaceRelease]) -> Task<Void, Never>? {
        lookUp(sources, olderThan: Self.onOpenInterval, now: now)
    }

    /// `Check Now`: every source at once, whatever the switch and the interval
    /// say. The click is the consent; only a lookup already running wins.
    /// - Returns: The lookup, or nil while one runs.
    @discardableResult
    public func checkNow(now: Date, sources: [SourceID: SubspaceRelease]) -> Task<Void, Never>? {
        lookUp(sources, olderThan: nil, now: now)
    }

    /// Whether a lookup is under way, for `Check Now`'s disabled state.
    public var isChecking: Bool { running != nil }

    /// - Parameter interval: How old a source's last lookup must be; nil is `Check Now`.
    private func lookUp(_ sources: [SourceID: SubspaceRelease], olderThan interval: TimeInterval?, now: Date) -> Task<Void, Never>? {
        // One lookup at a time: a window opened during the launch check must not ask again.
        guard checksForUpdates || interval == nil, running == nil else { return nil }
        let manual = interval == nil
        let sources = sources.filter { source, _ in
            guard let interval, let last = record.sources[source.rawValue]?.lastAttempt else { return true }
            // A lookup later than now means the clock was set back; waiting for it could take years.
            return last > now || now.timeIntervalSince(last) >= interval
        }
        guard !sources.isEmpty else { return nil }
        // Before asking, so a lookup that fails or never returns waits for the next interval.
        var attempted = record
        for source in sources.keys { attempted.sources[source.rawValue, default: .init()].lastAttempt = now }
        record = attempted
        let repositories = Set(sources.values.map(\.tagsRepository))
        let client = client
        let task = Task {
            let tags = await withTaskGroup(of: (String, [String]?).self) { group in
                for repository in repositories {
                    group.addTask { (repository, await Self.tags(of: repository, client: client)) }
                }
                var tags: [String: [String]] = [:]
                for await (repository, names) in group { tags[repository] = names }
                return tags
            }
            // A failure is never shown: the last release found stays, or nothing if there was none.
            // One assignment, so the store is written once per phase, not once per source.
            var found = record
            for (source, release) in sources {
                guard let names = tags[release.tagsRepository] else { continue }
                guard let latest = SubspaceVersion.latest(in: names, prefix: release.tagPrefix) else {
                    Self.log.error("No release tag \(release.tagPrefix, privacy: .public)X.Y.Z in \(release.tagsRepository, privacy: .public) for \(source.rawValue, privacy: .public)")
                    continue
                }
                Self.log.notice("Latest subspace release for \(source.rawValue, privacy: .public): \(latest.description, privacy: .public)")
                found.sources[source.rawValue, default: .init()].latest = latest.description
                found.sources[source.rawValue, default: .init()].manual = manual ? true : nil
            }
            record = found
            running = nil
        }
        running = task
        return task
    }

    private struct Tag: Decodable { var name: String }

    /// The tag names, or nil for anything but a readable tag list.
    nonisolated private static func tags(of repository: String, client: any HTTPGetting) async -> [String]? {
        // One page of 100 tags is the accepted limit: the distribution repos carry one tag per release of a single tool.
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/tags?per_page=100") else { return nil }
        // GitHub turns away requests without a User-Agent.
        let headers = ["Accept": "application/vnd.github+json", "User-Agent": "TheCollective"]
        let status: Int, data: Data
        do {
            (status, data) = try await client.get(url, headers: headers)
        } catch {
            log.error("Looking up the tags of \(repository, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard status == 200 else {
            log.error("Looking up the tags of \(repository, privacy: .public) failed: HTTP \(status, privacy: .public)")
            return nil
        }
        guard let tags = try? JSONDecoder().decode([Tag].self, from: data) else {
            log.error("Looking up the tags of \(repository, privacy: .public) failed: not a tag list")
            return nil
        }
        return tags.map(\.name)
    }
}
