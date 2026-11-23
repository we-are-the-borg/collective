import Foundation
import Testing
@testable import CollectiveKit

/// What the app asks and tells around an import of custom themes, in macOS's own wording:
/// "Replace?" per taken file name, and one alert per file that could not
/// be copied; invalid files are copied and show as error rows, so they get none.
@Suite struct CustomThemeImportAlertTests {
    private func file(_ name: String) -> URL {
        URL(fileURLWithPath: "/Users/user/Downloads/\(name)")
    }

    @Test func onlyAFileThatCouldNotBeCopiedGetsAnAlert() {
        let results = [
            CustomThemeImport(source: file("horizon-dark.yaml"), outcome: .imported),
            CustomThemeImport(source: file("ocean.yaml"), outcome: .replaced),
            CustomThemeImport(source: file("embers.yaml"), outcome: .declined),
            CustomThemeImport(source: file("espresso.yaml"), outcome: .alreadyInFolder),
            CustomThemeImport(source: file("notes.txt"), outcome: .notYAML),
            CustomThemeImport(source: file("locked.yaml"), outcome: .failed("You don’t have permission.")),
        ]
        #expect(CustomThemeImportAlert.alerts(after: results) == [
            CustomThemeImportAlert(
                message: "Couldn’t import “locked.yaml”.",
                informativeText: "You don’t have permission."
            ),
        ])
    }

    @Test func eachFailedFileGetsItsOwnAlertInOrder() {
        let results = [
            CustomThemeImport(source: file("b.yaml"), outcome: .failed("Disk full.")),
            CustomThemeImport(source: file("a.yml"), outcome: .failed("Not found.")),
        ]
        #expect(CustomThemeImportAlert.alerts(after: results).map(\.message) == [
            "Couldn’t import “b.yaml”.", "Couldn’t import “a.yml”.",
        ])
    }

    @Test func aTakenNameAsksToReplaceInMacOSWording() {
        let prompt = CustomThemeImportAlert.replace(fileName: "ocean.yaml")
        #expect(prompt.message == "“ocean.yaml” already exists. Do you want to replace it?")
        #expect(prompt.informativeText == "A file with the same name already exists in the Themes folder. Replacing it will overwrite its current contents.")
        #expect(String(localized: CustomThemeImportAlert.replaceButton) == "Replace")
        #expect(String(localized: CustomThemeImportAlert.cancelButton) == "Cancel")
    }
}
