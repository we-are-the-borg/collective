import Testing
@testable import CollectiveKit

/// Whether a newer subspace plugin is published, from release tags and the installed version.
@Suite struct SubspaceUpdateTests {
    /// Only a plain released `X.Y.Z` counts, so a pre-release or a typo never reads as an update.
    @Test func onlyPlainReleaseVersionsParse() {
        #expect(SubspaceVersion("1.0.1")?.description == "1.0.1")
        #expect(SubspaceVersion("10.20.30")?.description == "10.20.30")
        for invalid in ["v1.0.1", "1.0", "1.0.1.2", "1.0.1-rc.1", "1.0.1+b", "", " 1.0.1", "1..1", "a.b.c"] {
            #expect(SubspaceVersion(invalid) == nil, "\(invalid)")
        }
    }

    /// Versions compare per number, not as text.
    @Test func versionsCompareNumerically() throws {
        func v(_ text: String) throws -> SubspaceVersion { try #require(SubspaceVersion(text)) }
        #expect(try v("1.10.0") > v("1.9.0"))
        #expect(try v("2.0.0") > v("1.99.99"))
        #expect(try v("1.3.0") == v("1.3.0"))
        #expect(try !(v("1.3.0") < v("1.3.0")))
    }

    // Real tag lists of the subspace plugin repos, as the GitHub tags API returns them.
    let claudeCodeTags = ["claude-code-1.3.0", "claude-code-1.2.0", "claude-code-1.1.0", "claude-code-1.0.1", "claude-code-1.0.0"]
    let codexTags = ["codex-1.1.0", "codex-1.0.1", "codex-1.0.0"]

    /// The newest release of a prefix wins, whatever order the API lists the tags in.
    @Test func latestTagIsTheHighestOfItsPrefix() {
        #expect(SubspaceVersion.latest(in: claudeCodeTags, prefix: "claude-code-")?.description == "1.3.0")
        #expect(SubspaceVersion.latest(in: claudeCodeTags.reversed(), prefix: "claude-code-")?.description == "1.3.0")
        #expect(SubspaceVersion.latest(in: ["codex-1.0.1", "codex-1.1.0", "codex-1.0.0"], prefix: "codex-")?.description == "1.1.0")
    }

    /// Other prefixes, pre-releases and malformed tags never count as a release.
    @Test func latestTagSkipsForeignAndMalformedTags() {
        let mixed = claudeCodeTags + codexTags + [
            "claude-code-1.4.0-rc.1", "claude-code-v2.0.0", "claude-code-9.9", "foo", "claude-code-", "xclaude-code-5.0.0", "codex-9.0.0",
        ]
        #expect(SubspaceVersion.latest(in: mixed, prefix: "claude-code-")?.description == "1.3.0")
        #expect(SubspaceVersion.latest(in: mixed, prefix: "codex-")?.description == "9.0.0")
        #expect(SubspaceVersion.latest(in: codexTags + ["foo"], prefix: "claude-code-") == nil)
        #expect(SubspaceVersion.latest(in: [], prefix: "codex-") == nil)
    }

    let v1_2_0 = SubspaceVersion(major: 1, minor: 2, patch: 0)
    let v1_3_0 = SubspaceVersion(major: 1, minor: 3, patch: 0)

    /// An older installed plugin than the newest release is a hint; same or newer is not.
    @Test func aNewerReleaseIsAvailable() {
        #expect(UpdateAvailability(installed: "1.2.0", latest: v1_3_0, minimum: nil) == .available(installed: v1_2_0, latest: v1_3_0))
        #expect(UpdateAvailability(installed: "1.3.0", latest: v1_3_0, minimum: nil) == .upToDate)
        #expect(UpdateAvailability(installed: "1.4.0", latest: v1_3_0, minimum: nil) == .upToDate)
        #expect(UpdateAvailability(installed: "1.2.0", latest: nil, minimum: nil) == .upToDate)
    }

    /// Without a readable installed version there is nothing to compare, so never a hint.
    @Test func noHintWithoutAReadableInstalledVersion() {
        #expect(UpdateAvailability(installed: nil, latest: v1_3_0, minimum: v1_3_0) == .upToDate)
        #expect(UpdateAvailability(installed: "unknown", latest: v1_3_0, minimum: v1_3_0) == .upToDate)
        #expect(UpdateAvailability(installed: "1.2.0-rc.1", latest: v1_3_0, minimum: nil) == .upToDate)
    }

    /// Below the app's minimum an update is required, with or without a known release.
    @Test func belowTheMinimumAnUpdateIsRequired() {
        let v1_0_1 = SubspaceVersion(major: 1, minor: 0, patch: 1)
        #expect(UpdateAvailability(installed: "1.0.1", latest: nil, minimum: v1_2_0)
            == .required(installed: v1_0_1, minimum: v1_2_0, latest: nil))
        #expect(UpdateAvailability(installed: "1.0.1", latest: v1_3_0, minimum: v1_2_0)
            == .required(installed: v1_0_1, minimum: v1_2_0, latest: v1_3_0))
        // A release lookup older than the installed plugin is no news worth carrying.
        #expect(UpdateAvailability(installed: "1.0.1", latest: SubspaceVersion(major: 1, minor: 0, patch: 0), minimum: v1_2_0)
            == .required(installed: v1_0_1, minimum: v1_2_0, latest: nil))
    }

    /// At or above the minimum, a newer release is still only a hint.
    @Test func atOrAboveTheMinimumANewerReleaseIsAvailable() {
        #expect(UpdateAvailability(installed: "1.2.0", latest: v1_3_0, minimum: v1_2_0) == .available(installed: v1_2_0, latest: v1_3_0))
        #expect(UpdateAvailability(installed: "1.3.0", latest: v1_3_0, minimum: v1_2_0) == .upToDate)
        #expect(UpdateAvailability(installed: "1.3.0", latest: nil, minimum: v1_2_0) == .upToDate)
    }
}
