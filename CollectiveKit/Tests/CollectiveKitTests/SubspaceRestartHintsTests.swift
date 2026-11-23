import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

// When a probe saw a source's installed subspace rise, for the restart hint.

private let t0 = Date(timeIntervalSince1970: 1_000)

private func tool(_ plugin: IntegrationStatus.Plugin, source: SourceID = "a") -> IntegrationStatus {
    IntegrationStatus(
        source: source, toolName: "Tool", cliName: "tt", cli: .found(path: "/usr/local/bin/tt", version: nil), plugin: plugin,
        lastSessionStartAt: nil, commands: SetupCommands(install: [], installInApp: [], enable: [], enableInApp: [])
    )
}

private func hints(_ observations: [(IntegrationStatus.Plugin, Date)]) -> SubspaceRestartHints {
    var hints = SubspaceRestartHints()
    for (plugin, at) in observations { hints.observe([tool(plugin)], probeStartedAt: at) }
    return hints
}

private func hint(_ version: String, since: Date) -> SubspaceRestartHints.Hint {
    SubspaceRestartHints.Hint(version: SubspaceVersion(version)!, since: since)
}

@Suite struct SubspaceRestartHintsTests {
    /// After an app restart nothing shows: nothing rose since the app looked first.
    @Test func firstObservationIsOnlyABaseline() {
        #expect(hints([(.enabled(version: "1.0.1"), t0)]).hints.isEmpty)
    }

    @Test func riseRecordsTheVersionAndTheProbesStart() {
        let hints = hints([(.enabled(version: "1.0.1"), t0), (.enabled(version: "1.1.0"), t0.addingTimeInterval(5))])
        #expect(hints.hints == ["a": hint("1.1.0", since: t0.addingTimeInterval(5))])
    }

    /// A disabled plugin is installed as well.
    @Test func riseCountsForADisabledPlugin() {
        let hints = hints([(.disabled(version: "1.0.1"), t0), (.disabled(version: "1.1.0"), t0.addingTimeInterval(5))])
        #expect(hints.hints == ["a": hint("1.1.0", since: t0.addingTimeInterval(5))])
    }

    @Test func sameVersionKeepsTheHint() {
        let hints = hints([
            (.enabled(version: "1.0.1"), t0), (.enabled(version: "1.1.0"), t0.addingTimeInterval(5)),
            (.enabled(version: "1.1.0"), t0.addingTimeInterval(10)),
        ])
        #expect(hints.hints == ["a": hint("1.1.0", since: t0.addingTimeInterval(5))])
    }

    /// A timed-out probe says nothing about the version, so the hint stays and no new baseline forms.
    @Test func unreadableVersionChangesNothing() {
        let unreadable: [IntegrationStatus.Plugin] = [.unknown, .enabled(version: nil), .enabled(version: "next"), .notInstalled]
        for plugin in unreadable {
            let hints = hints([
                (.enabled(version: "1.0.1"), t0), (.enabled(version: "1.1.0"), t0.addingTimeInterval(5)),
                (plugin, t0.addingTimeInterval(10)), (.enabled(version: "1.1.0"), t0.addingTimeInterval(15)),
            ])
            #expect(hints.hints == ["a": hint("1.1.0", since: t0.addingTimeInterval(5))], "\(plugin)")
        }
        #expect(hints([(.unknown, t0), (.enabled(version: "1.1.0"), t0.addingTimeInterval(5))]).hints.isEmpty)
    }

    @Test func furtherRiseReplacesTheHint() {
        let hints = hints([
            (.enabled(version: "1.0.1"), t0), (.enabled(version: "1.1.0"), t0.addingTimeInterval(5)),
            (.enabled(version: "1.2.0"), t0.addingTimeInterval(10)),
        ])
        #expect(hints.hints == ["a": hint("1.2.0", since: t0.addingTimeInterval(10))])
    }

    @Test func downgradeDropsTheHintAndSetsANewBaseline() {
        let downgraded = hints([
            (.enabled(version: "1.0.1"), t0), (.enabled(version: "1.1.0"), t0.addingTimeInterval(5)),
            (.enabled(version: "1.0.1"), t0.addingTimeInterval(10)),
        ])
        #expect(downgraded.hints.isEmpty)
        // Rising again from the lower baseline is a new hint.
        var again = downgraded
        again.observe([tool(.enabled(version: "1.1.0"))], probeStartedAt: t0.addingTimeInterval(15))
        #expect(again.hints == ["a": hint("1.1.0", since: t0.addingTimeInterval(15))])
    }

    @Test func sourcesAreKeptApart() {
        var hints = SubspaceRestartHints()
        hints.observe([tool(.enabled(version: "1.0.1"), source: "a"), tool(.enabled(version: "1.0.1"), source: "b")], probeStartedAt: t0)
        hints.observe([tool(.enabled(version: "1.1.0"), source: "a"), tool(.enabled(version: "1.0.1"), source: "b")],
                      probeStartedAt: t0.addingTimeInterval(5))
        #expect(hints.hints == ["a": hint("1.1.0", since: t0.addingTimeInterval(5))])
    }
}
