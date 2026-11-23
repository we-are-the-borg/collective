import Foundation
import Testing
@testable import CollectiveKit

@Suite struct ConnectionStatusTests {
    @Test func notInstalledIsMissing() {
        let status = integration(.notInstalled)
        #expect(ConnectionStatus(integrations: [status]) == .missing(status))
    }

    @Test func disabledIsDisabled() {
        let status = integration(.disabled(version: "0.4.0"))
        #expect(ConnectionStatus(integrations: [status]) == .disabled(status))
    }

    @Test func enabledAndUnknownAreOk() {
        #expect(ConnectionStatus(integrations: [integration(.enabled(version: "0.4.0"))]) == .ok)
        #expect(ConnectionStatus(integrations: [integration(.unknown)]) == .ok)
    }

    /// Before the first check has finished there is nothing to warn about.
    @Test func noStatusYetIsOk() {
        #expect(ConnectionStatus(integrations: []) == .ok)
    }

    @Test func missingWinsOverDisabledWhateverTheOrder() {
        let disabled = integration(.disabled(version: nil), source: "a")
        let missing = integration(.notInstalled, source: "b")
        #expect(ConnectionStatus(integrations: [disabled, missing]) == .missing(missing))
    }

    @Test func firstOfTheSameKindWins() {
        let first = integration(.notInstalled, source: "a")
        let second = integration(.notInstalled, source: "b")
        #expect(ConnectionStatus(integrations: [first, second]) == .missing(first))
        let disabledFirst = integration(.disabled(version: nil), source: "a")
        let disabledSecond = integration(.disabled(version: nil), source: "b")
        let enabled = integration(.enabled(version: nil), source: "c")
        #expect(ConnectionStatus(integrations: [enabled, disabledFirst, disabledSecond]) == .disabled(disabledFirst))
    }

    // MARK: Several sources

    @Test func oneEnabledSourceSilencesMissingOnes() {
        let enabled = integration(.enabled(version: nil), source: "a")
        let missing = integration(.notInstalled, source: "b")
        #expect(ConnectionStatus(integrations: [enabled, missing]) == .ok)
        #expect(ConnectionStatus(integrations: [missing, enabled]) == .ok)
    }

    @Test func noSourceEnabledNamesTheFirstMissing() {
        let first = integration(.notInstalled, source: "a")
        let second = integration(.notInstalled, source: "b")
        #expect(ConnectionStatus(integrations: [first, second]) == .missing(first))
    }

    @Test func aDisabledSourceWarnsEvenIfAnotherIsEnabled() {
        let enabled = integration(.enabled(version: nil), source: "a")
        let disabled = integration(.disabled(version: nil), source: "b")
        #expect(ConnectionStatus(integrations: [enabled, disabled]) == .disabled(disabled))
    }

    @Test func missingWinsOverDisabledWhenNoSourceIsEnabled() {
        let missing = integration(.notInstalled, source: "a")
        let disabled = integration(.disabled(version: nil), source: "b")
        #expect(ConnectionStatus(integrations: [missing, disabled]) == .missing(missing))
    }

    @Test func anUnknownSourceDoesNotSilenceAMissingOne() {
        let unknown = integration(.unknown, source: "a")
        let missing = integration(.notInstalled, source: "b")
        #expect(ConnectionStatus(integrations: [unknown, missing]) == .missing(missing))
    }
}
