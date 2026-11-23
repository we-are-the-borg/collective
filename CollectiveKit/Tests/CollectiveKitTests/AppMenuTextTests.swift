import Foundation
import Testing
@testable import CollectiveKit

@Suite struct AppMenuTextTests {
    @Test func aboutUsesTheStandardMacOSWording() {
        #expect(String(localized: AppMenuText.about) == "About The Collective")
    }
}
