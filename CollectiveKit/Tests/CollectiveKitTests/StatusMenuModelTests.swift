import Foundation
import Testing
@testable import CollectiveKit

@Suite struct StatusMenuModelTests {
    func text(_ resource: LocalizedStringResource?) -> String? { resource.map { String(localized: $0) } }

    let missing = integration(.notInstalled)
    let disabled = integration(.disabled(version: nil))

    @Test func connectedMenuHasNoSetUp() {
        #expect(StatusMenuModel(connection: .ok).items == [.settings, .separator, .quit])
    }

    @Test func missingAndDisabledOfferSetUpBetweenSettingsAndTheSeparator() {
        let expected: [StatusMenuItem] = [.settings, .setUp, .separator, .quit]
        #expect(StatusMenuModel(connection: .missing(missing)).items == expected)
        #expect(StatusMenuModel(connection: .disabled(disabled)).items == expected)
    }

    @Test func titlesAreLocalizedAndTheSeparatorHasNone() {
        #expect(text(StatusMenuItem.settings.title) == "Settings…")
        #expect(text(StatusMenuItem.setUp.title) == "Set Up…")
        #expect(text(StatusMenuItem.quit.title) == "Quit The Collective")
        #expect(StatusMenuItem.separator.title == nil)
    }

    @Test func keyEquivalents() {
        #expect(StatusMenuItem.settings.keyEquivalent == .init(key: ",", command: true))
        #expect(StatusMenuItem.quit.keyEquivalent == .init(key: "q", command: true))
        #expect(StatusMenuItem.setUp.keyEquivalent == nil)
        #expect(StatusMenuItem.separator.keyEquivalent == nil)
    }

    @Test func onlySetUpCarriesTheWarningSymbol() {
        #expect(StatusMenuItem.setUp.symbolName == "exclamationmark.triangle.fill")
        #expect(StatusMenuItem.setUp.isWarning)
        for item in [StatusMenuItem.settings, .separator, .quit] {
            #expect(item.symbolName == nil)
            #expect(!item.isWarning)
        }
    }
}
