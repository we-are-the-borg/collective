import Foundation
import Synchronization
import Testing
import SubspaceKit
@testable import CollectiveKit

// MARK: - Helpers

/// Real GitHub tags API responses (see the folder's README).
private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/github/\(name)"))
}

private let claudeCodeTagsURL = "https://api.github.com/repos/we-are-the-borg/subspace-claude-code/tags?per_page=100"
private let codexTagsURL = "https://api.github.com/repos/we-are-the-borg/subspace-codex/tags?per_page=100"

/// The releases as the adapters deliver them.
private let claudeCode = SubspaceRelease(tagsRepository: "we-are-the-borg/subspace-claude-code", tagPrefix: "claude-code-",
                                         changesRepository: "we-are-the-borg/subspace")
private let codex = SubspaceRelease(tagsRepository: "we-are-the-borg/subspace-codex", tagPrefix: "codex-",
                                    changesRepository: "we-are-the-borg/subspace")
private let both: [SourceID: SubspaceRelease] = ["claude-code": claudeCode, "codex": codex]

private let v1_1_0 = SubspaceVersion(major: 1, minor: 1, patch: 0)
private let v1_3_0 = SubspaceVersion(major: 1, minor: 3, patch: 0)
private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let hour: TimeInterval = 3600

/// The network, the one system boundary of the checker: answers by URL and records every request.
private final class FakeGitHub: HTTPGetting {
    enum Answer: Sendable { case response(status: Int, body: Data), failure }
    struct Request: Sendable { var url: URL; var headers: [String: String] }
    struct Failure: Error {}

    private let state = Mutex<(answers: [String: Answer], requests: [Request])>(([:], []))

    init(_ answers: [String: Answer] = [:]) { state.withLock { $0.answers = answers } }

    /// Both repos answer with their real tags.
    static func real() throws -> FakeGitHub {
        FakeGitHub([
            claudeCodeTagsURL: .response(status: 200, body: try fixture("tags-subspace-claude-code.json")),
            codexTagsURL: .response(status: 200, body: try fixture("tags-subspace-codex.json")),
        ])
    }

    var requests: [Request] { state.withLock { $0.requests } }
    var requestedURLs: [String] { requests.map(\.url.absoluteString).sorted() }

    func answer(_ url: String, with answer: Answer) { state.withLock { $0.answers[url] = answer } }

    func get(_ url: URL, headers: [String: String]) async throws -> (status: Int, data: Data) {
        let answer = state.withLock { state in
            state.requests.append(Request(url: url, headers: headers))
            return state.answers[url.absoluteString]
        }
        switch answer {
        case .response(let status, let body): return (status, body)
        case .failure, nil: throw Failure()
        }
    }
}

/// The persistent store, the other faked boundary; shared between checkers like the app's defaults across launches.
private final class MemoryStore: SubspaceReleaseStore {
    var checksForUpdates = true
    var record = SubspaceReleaseRecord() { didSet { recordWrites += 1 } }
    private(set) var recordWrites = 0
}

@MainActor
private func check(_ checker: SubspaceReleaseChecker, now: Date, _ sources: [SourceID: SubspaceRelease] = both) async {
    await checker.checkIfDue(now: now, sources: sources)?.value
}

// MARK: - Tests

@MainActor @Suite struct SubspaceReleaseCheckerTests {
    /// The real tag lists name Claude Code 1.3.0 and Codex 1.1.0 as the newest releases.
    @Test func realTagListsGiveTheNewestReleasePerSource() async throws {
        let checker = SubspaceReleaseChecker(client: try FakeGitHub.real(), store: MemoryStore())
        await check(checker, now: start)
        #expect(checker.latest(for: "claude-code") == v1_3_0)
        #expect(checker.latest(for: "codex") == v1_1_0)
    }

    /// GitHub's tags endpoint, its JSON media type and a User-Agent, which GitHub requires.
    @Test func asksGitHubsTagsAPIWithTheRequiredHeaders() async throws {
        let github = try FakeGitHub.real()
        await check(SubspaceReleaseChecker(client: github, store: MemoryStore()), now: start, ["claude-code": claudeCode])
        let request = try #require(github.requests.first)
        #expect(github.requests.count == 1)
        #expect(request.url.absoluteString == claudeCodeTagsURL)
        #expect(request.headers["Accept"] == "application/vnd.github+json")
        #expect(request.headers["User-Agent"] == "TheCollective")
    }

    /// At most once a day: the first launch asks once per repo, the rest of the day asks nothing.
    @Test func automaticCheckAsksOncePerDay() async throws {
        let github = try FakeGitHub.real()
        let checker = SubspaceReleaseChecker(client: github, store: MemoryStore())
        await check(checker, now: start)
        #expect(github.requestedURLs == [claudeCodeTagsURL, codexTagsURL])
        await check(checker, now: start + 23 * hour)
        #expect(github.requests.count == 2)
        await check(checker, now: start + 24 * hour)
        #expect(github.requestedURLs == [claudeCodeTagsURL, claudeCodeTagsURL, codexTagsURL, codexTagsURL])
    }

    /// A relaunch within the day asks nothing and still knows the releases.
    @Test func aRelaunchWithinADayAsksNothing() async throws {
        let github = try FakeGitHub.real()
        let store = MemoryStore()
        await check(SubspaceReleaseChecker(client: github, store: store), now: start)
        let relaunched = SubspaceReleaseChecker(client: github, store: store)
        await check(relaunched, now: start + 23 * hour)
        #expect(github.requests.count == 2)
        #expect(relaunched.latest(for: "claude-code") == v1_3_0)
        #expect(relaunched.latest(for: "codex") == v1_1_0)
    }

    /// The record is written once before the requests and once after, however many sources.
    @Test func aLookupWritesTheRecordOncePerPhase() async throws {
        let store = MemoryStore()
        await check(SubspaceReleaseChecker(client: try FakeGitHub.real(), store: store), now: start)
        #expect(store.recordWrites == 2)
    }

    /// Sources tagged in the same repo share one request and each reads its own prefix.
    @Test func sourcesOfOneRepoShareARequest() async throws {
        let shared = try fixture("tags-subspace-claude-code.json")
        let mixed = """
        [{"name": "codex-2.0.0"}, {"name": "claude-code-1.1.0"}]
        """
        let github = FakeGitHub([codexTagsURL: .response(status: 200, body: Data(mixed.utf8)), claudeCodeTagsURL: .response(status: 200, body: shared)])
        let checker = SubspaceReleaseChecker(client: github, store: MemoryStore())
        let sameRepo = SubspaceRelease(tagsRepository: codex.tagsRepository, tagPrefix: "claude-code-", changesRepository: codex.changesRepository)
        await check(checker, now: start, ["codex": codex, "claude-code": sameRepo])
        #expect(github.requestedURLs == [codexTagsURL])
        #expect(checker.latest(for: "codex") == SubspaceVersion(major: 2, minor: 0, patch: 0))
        #expect(checker.latest(for: "claude-code") == v1_1_0)
    }

    /// Opening Setup or a source pane asks again once the last lookup is an hour old.
    @Test func openingAsksAgainAfterAnHour() async throws {
        let github = try FakeGitHub.real()
        let checker = SubspaceReleaseChecker(client: github, store: MemoryStore())
        await check(checker, now: start)
        await checker.checkOnOpen(now: start + 59 * 60, sources: both)?.value
        #expect(github.requests.count == 2)
        await checker.checkOnOpen(now: start + hour, sources: both)?.value
        #expect(github.requests.count == 4)
        // The automatic check counts that lookup too.
        await check(checker, now: start + 24 * hour)
        #expect(github.requests.count == 4)
    }

    /// A last lookup later than now (the clock was set back) never blocks:
    /// both checks ask right away, and the intervals count from that lookup.
    @Test func aLookupInTheFutureIsDue() async throws {
        let earlier = start - 48 * hour
        let github = try FakeGitHub.real()
        let checker = SubspaceReleaseChecker(client: github, store: MemoryStore())
        await check(checker, now: start)
        await check(checker, now: earlier)
        #expect(github.requests.count == 4)
        await check(checker, now: earlier + 23 * hour)
        #expect(github.requests.count == 4)
        await check(checker, now: earlier + 24 * hour)
        #expect(github.requests.count == 6)

        let opening = try FakeGitHub.real()
        let opened = SubspaceReleaseChecker(client: opening, store: MemoryStore())
        await check(opened, now: start)
        await opened.checkOnOpen(now: earlier, sources: both)?.value
        #expect(opening.requests.count == 4)
        await opened.checkOnOpen(now: earlier + 59 * 60, sources: both)?.value
        #expect(opening.requests.count == 4)
        await opened.checkOnOpen(now: earlier + hour, sources: both)?.value
        #expect(opening.requests.count == 6)
    }

    /// No response, an error status, a body that isn't a tag list, or no tag of
    /// the prefix: nothing reaches the caller, the last release stays, and the
    /// failed lookup still waits for the next interval.
    @Test(arguments: [
        FakeGitHub.Answer.failure,
        .response(status: 403, body: Data(#"{"message": "API rate limit exceeded"}"#.utf8)),
        .response(status: 500, body: Data()),
        .response(status: 200, body: Data("<html>".utf8)),
        .response(status: 200, body: Data(#"{"name": "claude-code-9.0.0"}"#.utf8)),
        .response(status: 200, body: Data(#"[{"name": "codex-9.0.0"}, {"name": "claude-code-9.0.0-rc.1"}]"#.utf8)),
    ])
    fileprivate func aFailedLookupKeepsTheLastRelease(_ failure: FakeGitHub.Answer) async throws {
        let github = try FakeGitHub.real()
        let checker = SubspaceReleaseChecker(client: github, store: MemoryStore())
        await check(checker, now: start)
        github.answer(claudeCodeTagsURL, with: failure)
        await check(checker, now: start + 24 * hour)
        #expect(github.requests.count == 4)
        #expect(checker.latest(for: "claude-code") == v1_3_0)
        #expect(checker.latest(for: "codex") == v1_1_0)
        await check(checker, now: start + 25 * hour)
        await checker.checkOnOpen(now: start + 24.5 * hour, sources: both)?.value
        #expect(github.requests.count == 4)
    }

    /// Without any successful lookup a failure leaves nothing to show.
    @Test func aFailedFirstLookupShowsNothing() async throws {
        let github = FakeGitHub()
        let checker = SubspaceReleaseChecker(client: github, store: MemoryStore())
        await check(checker, now: start)
        #expect(github.requests.count == 2)
        #expect(checker.latest(for: "claude-code") == nil)
        #expect(checker.latest(for: "codex") == nil)
    }

    /// Checking is on until the user switches it off, and the choice outlives a relaunch.
    @Test func checkingIsOnByDefaultAndTheSwitchPersists() throws {
        let store = MemoryStore()
        let checker = SubspaceReleaseChecker(client: try FakeGitHub.real(), store: store)
        #expect(checker.checksForUpdates)
        checker.checksForUpdates = false
        #expect(!SubspaceReleaseChecker(client: try FakeGitHub.real(), store: store).checksForUpdates)
    }

    /// Switched off, the app asks GitHub nothing and shows no release it found
    /// before; switching on again shows it and waits for the next due check.
    @Test func switchedOffNothingIsAskedOrShown() async throws {
        let github = try FakeGitHub.real()
        let checker = SubspaceReleaseChecker(client: github, store: MemoryStore())
        await check(checker, now: start)
        checker.checksForUpdates = false
        #expect(checker.checkIfDue(now: start + 48 * hour, sources: both) == nil)
        #expect(checker.checkOnOpen(now: start + 48 * hour, sources: both) == nil)
        #expect(github.requests.count == 2)
        #expect(checker.latest(for: "claude-code") == nil)
        #expect(checker.latest(for: "codex") == nil)

        checker.checksForUpdates = true
        #expect(github.requests.count == 2)
        #expect(checker.latest(for: "claude-code") == v1_3_0)
        await check(checker, now: start + 48 * hour)
        #expect(github.requests.count == 4)
    }

    /// Switched off from the first launch, not even the first lookup happens.
    @Test func switchedOffFromTheStartNothingIsAsked() async throws {
        let github = try FakeGitHub.real()
        let store = MemoryStore()
        store.checksForUpdates = false
        let checker = SubspaceReleaseChecker(client: github, store: store)
        #expect(checker.checkIfDue(now: start, sources: both) == nil)
        #expect(checker.checkOnOpen(now: start, sources: both) == nil)
        #expect(github.requests.isEmpty)
    }

    private func status(_ plugin: IntegrationStatus.Plugin, minimum: String? = nil, release: SubspaceRelease? = claudeCode) -> IntegrationStatus {
        var release = release
        release?.minimumVersion = minimum
        return IntegrationStatus(source: "claude-code", toolName: "Claude Code", cliName: "claude",
                                 cli: .found(path: "/usr/local/bin/claude", version: "2.1.316"), plugin: plugin,
                                 commands: SetupCommands(install: [], installInApp: [], enable: [], enableInApp: [], release: release))
    }

    /// The installed version of an enabled or disabled plugin against the newest release.
    @Test func availabilityComparesTheInstalledPlugin() async throws {
        let checker = SubspaceReleaseChecker(client: try FakeGitHub.real(), store: MemoryStore())
        await check(checker, now: start)
        let v1_2_0 = SubspaceVersion(major: 1, minor: 2, patch: 0)
        #expect(checker.updateAvailability(for: status(.enabled(version: "1.2.0"))) == .available(installed: v1_2_0, latest: v1_3_0))
        #expect(checker.updateAvailability(for: status(.disabled(version: "1.2.0"))) == .available(installed: v1_2_0, latest: v1_3_0))
        #expect(checker.updateAvailability(for: status(.enabled(version: "1.3.0"))) == .upToDate)
        #expect(checker.updateAvailability(for: status(.enabled(version: nil))) == .upToDate)
        #expect(checker.updateAvailability(for: status(.notInstalled)) == .upToDate)
        #expect(checker.updateAvailability(for: status(.unknown)) == .upToDate)
        // Without release data the source can't be looked up, so nothing found earlier counts.
        #expect(checker.updateAvailability(for: status(.enabled(version: "1.2.0"), release: nil)) == .upToDate)
    }

    /// The app knows its minimum itself, so it applies with checking off and without any lookup.
    @Test func theMinimumAppliesWithCheckingOff() throws {
        let checker = SubspaceReleaseChecker(client: try FakeGitHub.real(), store: MemoryStore())
        checker.checksForUpdates = false
        let v1_0_1 = SubspaceVersion(major: 1, minor: 0, patch: 1)
        #expect(checker.updateAvailability(for: status(.enabled(version: "1.0.1"), minimum: "1.1.0"))
            == .required(installed: v1_0_1, minimum: v1_1_0, latest: nil))
        #expect(checker.updateAvailability(for: status(.enabled(version: "1.1.0"), minimum: "1.1.0")) == .upToDate)
    }

    /// A check while a lookup runs asks nothing more, even when it would be due by then.
    @Test func lookupsNeverOverlap() async throws {
        let github = try FakeGitHub.real()
        let checker = SubspaceReleaseChecker(client: github, store: MemoryStore())
        let running = try #require(checker.checkIfDue(now: start, sources: both))
        #expect(checker.checkOnOpen(now: start + 2 * hour, sources: both) == nil)
        #expect(checker.checkIfDue(now: start + 25 * hour, sources: both) == nil)
        await running.value
        #expect(github.requestedURLs == [claudeCodeTagsURL, codexTagsURL])
        // Once it is over, the next due check asks again.
        await checker.checkOnOpen(now: start + 2 * hour, sources: both)?.value
        #expect(github.requests.count == 4)
    }
}

/// The app's store: real defaults in a suite of their own, removed afterwards.
@MainActor @Suite struct UserDefaultsSubspaceReleaseStoreTests {
    /// What one launch found and chose is what the next launch starts from.
    @Test func aRelaunchFindsTheSwitchAndTheLastLookup() async throws {
        let suite = "SubspaceReleaseStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let github = try FakeGitHub.real()

        let first = SubspaceReleaseChecker(client: github, store: UserDefaultsSubspaceReleaseStore(defaults: defaults))
        #expect(first.checksForUpdates)
        await check(first, now: start)

        let second = SubspaceReleaseChecker(client: github, store: UserDefaultsSubspaceReleaseStore(defaults: defaults))
        #expect(second.checkIfDue(now: start + 23 * hour, sources: both) == nil)
        #expect(second.latest(for: "claude-code") == v1_3_0)
        second.checksForUpdates = false

        let third = SubspaceReleaseChecker(client: github, store: UserDefaultsSubspaceReleaseStore(defaults: defaults))
        #expect(!third.checksForUpdates)
        #expect(github.requests.count == 2)
    }

    /// A record that no longer reads never turns checking back on.
    @Test func anUnreadableRecordKeepsTheSwitch() throws {
        let suite = "SubspaceReleaseStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSubspaceReleaseStore(defaults: defaults)
        store.checksForUpdates = false
        defaults.set(Data("garbage".utf8), forKey: "subspaceReleases")
        let checker = SubspaceReleaseChecker(client: try FakeGitHub.real(), store: store)
        #expect(!checker.checksForUpdates)
    }
}

