import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

/// A check whose plugin list failed says nothing about the installation.
@Suite struct IntegrationStatusCarryOverTests {
    private let cli = IntegrationStatus.CLI.found(path: "/usr/local/bin/tt", version: "1.2.3")

    @Test func anUnknownPluginKeepsThePreviousStateWithItsVersion() {
        var previous = integration(.enabled(version: "1.0.1"), cli: .found(path: "/usr/local/bin/tt", version: "1.2.2"))
        previous.marketplaceAdded = true
        let new = integration(.unknown, cli: cli, lastSessionStartAt: Date(timeIntervalSince1970: 5))
        let kept = new.keepingKnownPlugin(from: previous)
        #expect(kept.plugin == .enabled(version: "1.0.1"))
        #expect(kept.pluginIsCarriedOver)
        // Everything else is the new check's.
        #expect(kept.cli == cli)
        #expect(kept.lastSessionStartAt == Date(timeIntervalSince1970: 5))
    }

    @Test(arguments: [IntegrationStatus.Plugin.disabled(version: "0.4.0"), .notInstalled])
    func everyKnownStateIsKept(previous: IntegrationStatus.Plugin) {
        #expect(integration(.unknown).keepingKnownPlugin(from: integration(previous)).plugin == previous)
    }

    @Test func withoutAPreviousStateItStaysUnknown() {
        let new = integration(.unknown)
        #expect(new.keepingKnownPlugin(from: nil) == new)
        #expect(new.keepingKnownPlugin(from: integration(.unknown)) == new)
        #expect(!new.keepingKnownPlugin(from: integration(.unknown)).pluginIsCarriedOver)
    }

    /// The tool is really gone, so nothing of the last check is claimed.
    @Test func aCLIThatIsNoLongerFoundCarriesNothingOver() {
        var previous = integration(.enabled(version: "1.0.1"))
        previous.marketplaceAdded = true
        let new = integration(.unknown, cli: .notFound)
        #expect(new.keepingKnownPlugin(from: previous) == new)
    }

    @Test(arguments: [IntegrationStatus.Plugin.notInstalled, .disabled(version: "1.0.1"), .enabled(version: "1.1.0")])
    func aKnownNewStateAlwaysWins(new: IntegrationStatus.Plugin) {
        let kept = integration(new).keepingKnownPlugin(from: integration(.enabled(version: "1.0.1")))
        #expect(kept.plugin == new)
        #expect(!kept.pluginIsCarriedOver)
    }

    @Test func anUnreadableMarketplaceListKeepsThePreviousAnswer() {
        var previous = integration(.enabled(version: "1.0.1"))
        previous.marketplaceAdded = true
        #expect(integration(.enabled(version: "1.0.1")).keepingKnownPlugin(from: previous).marketplaceAdded == true)
        var new = integration(.enabled(version: "1.0.1"))
        new.marketplaceAdded = false
        #expect(new.keepingKnownPlugin(from: previous).marketplaceAdded == false)
    }

    /// A second failed check in a row still knows the state from the last good one.
    @Test func aCarriedOverStateCarriesOnAndStaysMarked() {
        let once = integration(.unknown).keepingKnownPlugin(from: integration(.enabled(version: "1.0.1")))
        let twice = integration(.unknown).keepingKnownPlugin(from: once)
        #expect(twice.plugin == .enabled(version: "1.0.1"))
        #expect(twice.pluginIsCarriedOver)
    }

    @Test func theListMatchesBySourceAndKeepsTheNewOrder() {
        let previous = [integration(.enabled(version: "1.0.1"), source: "a"), integration(.disabled(version: nil), source: "b")]
        let results = [integration(.unknown, source: "b"), integration(.unknown, source: "a"), integration(.unknown, source: "c")]
        let kept = IntegrationStatus.keepingKnownPlugins(results, from: previous)
        #expect(kept.map(\.source) == ["b", "a", "c"])
        #expect(kept.map(\.plugin) == [.disabled(version: nil), .enabled(version: "1.0.1"), .unknown])
    }
}
