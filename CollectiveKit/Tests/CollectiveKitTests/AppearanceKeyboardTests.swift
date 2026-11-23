import Foundation
import Testing
@testable import CollectiveKit

/// The Appearance pane's keys, one cell of the design's key table per expectation: on a slot, in
/// the search field and in the list. Tab and Shift-Tab are the system's focus order and pass.
@Suite struct AppearanceKeyboardTests {
    private let defaults = ThemeChoice(light: BundledThemes.defaultLight, dark: BundledThemes.defaultDark)

    private func model(
        _ choice: ThemeChoice? = nil, catalog: ThemeCatalog = .bundled, inUse: ThemeAppearance = .light,
        expanded: ThemeSlot? = .dark, query: String = ""
    ) -> AppearanceModel {
        AppearanceModel(catalog: catalog, choice: choice ?? defaults, inUse: inUse, expanded: expanded, query: query)
    }

    /// One dark custom theme and a broken file, from the real fixtures.
    private func folder() throws -> ThemeCatalog {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appearance-keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/custom-themes")
        for (name, fixture) in ["horizon-dark.yaml": "horizon-dark.yaml", "broken.yaml": "missing-base0D.yaml"] {
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(fixture), to: url.appendingPathComponent(name))
        }
        return ThemeCatalog(custom: CustomThemeFolder.entries(in: url))
    }

    // MARK: slot

    @Test(arguments: [AppearanceKey.space, .return])
    func spaceAndReturnToggleTheSlot(key: AppearanceKey) {
        #expect(model(expanded: nil).action(for: key, focus: .slot(.light), focusedRowID: nil) == .toggle(.light))
        #expect(model().action(for: key, focus: .slot(.dark), focusedRowID: nil) == .toggle(.dark))
    }

    @Test(arguments: [AppearanceKey.downArrow, .upArrow, .escape, .home, .text("a"), .deleteBackward, .leftArrow])
    func otherKeysOnASlotAreTheSystems(key: AppearanceKey) {
        #expect(model().action(for: key, focus: .slot(.light), focusedRowID: nil) == .pass)
    }

    /// ⌘F opens the slot in use, from a slot, Done's neighbors or nowhere in particular.
    @Test func findOpensTheSlotInUse() {
        #expect(model(inUse: .dark, expanded: nil).action(for: .find, focus: .slot(.light), focusedRowID: nil) == .find(.dark))
        #expect(model(inUse: .light, expanded: .dark).action(for: .find, focus: .slot(.dark), focusedRowID: nil) == .find(.light))
        #expect(model(inUse: .light, expanded: nil).action(for: .find, focus: nil, focusedRowID: nil) == .find(.light))
        let fixed = ThemeChoice(light: "github", dark: "nord", mode: .fixed, fixed: "nord")
        #expect(model(fixed, expanded: nil).action(for: .find, focus: nil, focusedRowID: nil) == .find(.fixed))
    }

    /// Inside an open browser ⌘F stays in it: into its search field, the text marked.
    @Test(arguments: [AppearanceFocus.search, .list, .done])
    func findInsideTheBrowserGoesToItsSearchField(focus: AppearanceFocus) {
        #expect(model(inUse: .light, expanded: .dark).action(for: .find, focus: focus, focusedRowID: nil) == .find(.dark))
    }

    // MARK: search field

    /// ↓ only focuses: the checked row if it matches, else the first.
    @Test func downFromTheSearchFieldFocusesTheEntryRow() {
        #expect(model().action(for: .downArrow, focus: .search, focusedRowID: nil) == .focusRow("catppuccin-macchiato"))
        #expect(model(query: "gruv").action(for: .downArrow, focus: .search, focusedRowID: nil) == .focusRow("gruvbox-dark"))
    }

    @Test func withoutMatchesDownDoesNothing() {
        #expect(model(query: "xyz").action(for: .downArrow, focus: .search, focusedRowID: nil) == .swallow)
    }

    /// No blind pick.
    @Test func returnInTheSearchFieldDoesNothing() {
        #expect(model(query: "gruv").action(for: .return, focus: .search, focusedRowID: nil) == .swallow)
    }

    /// First clear, then close; with no matches the same.
    @Test func escapeInTheSearchFieldClearsThenCollapses() {
        #expect(model(query: "gruv").action(for: .escape, focus: .search, focusedRowID: nil) == .clearSearch)
        #expect(model(query: "xyz").action(for: .escape, focus: .search, focusedRowID: nil) == .clearSearch)
        #expect(model(query: "").action(for: .escape, focus: .search, focusedRowID: nil) == .collapse)
    }

    /// The field editor only scrolls on Home and End; the table wants the caret moved.
    @Test func homeAndEndMoveTheCaret() {
        #expect(model(query: "gruv").action(for: .home, focus: .search, focusedRowID: nil) == .caretToStart)
        #expect(model(query: "gruv").action(for: .end, focus: .search, focusedRowID: nil) == .caretToEnd)
    }

    @Test(arguments: [AppearanceKey.text("g"), .space, .deleteBackward, .leftArrow, .rightArrow, .upArrow, .pageUp, .pageDown])
    func typingAndTheCaretAreTheSearchFieldsOwn(key: AppearanceKey) {
        #expect(model(query: "gruv").action(for: key, focus: .search, focusedRowID: nil) == .pass)
    }

    // MARK: list

    /// ↓ ↑ move and choose at once, held at the ends.
    @Test func arrowsMoveAndSelect() {
        let model = model()
        #expect(model.action(for: .downArrow, focus: .list, focusedRowID: "catppuccin-macchiato") == .selectRow("catppuccin-mocha"))
        #expect(model.action(for: .upArrow, focus: .list, focusedRowID: "catppuccin-macchiato") == .selectRow("catppuccin-frappe"))
        #expect(model.action(for: .downArrow, focus: .list, focusedRowID: "tomorrow-night-eighties") == .selectRow("tomorrow-night-eighties"))
    }

    /// At the end on the checked row nothing changes, so nothing is read again.
    @Test func atTheEndOnTheCheckedRowDownDoesNothing() {
        let choice = ThemeChoice(light: "github", dark: "tomorrow-night-eighties")
        #expect(model(choice).action(for: .downArrow, focus: .list, focusedRowID: "tomorrow-night-eighties") == .swallow)
        #expect(model(choice).action(for: .space, focus: .list, focusedRowID: "tomorrow-night-eighties") == .swallow)
    }

    /// ↑ on the first row goes back into the search field, the choice stays.
    @Test func upOnTheFirstRowReturnsToTheSearchField() {
        #expect(model(query: "gruv").action(for: .upArrow, focus: .list, focusedRowID: "gruvbox-dark") == .editSearch("gruv"))
        #expect(model().action(for: .upArrow, focus: .list, focusedRowID: "ayu-dark") == .editSearch(""))
    }

    /// Across the sections and past the error rows.
    @Test func arrowsCrossFromCustomToBuiltIn() throws {
        let model = model(catalog: try folder())
        #expect(model.action(for: .downArrow, focus: .list, focusedRowID: "custom:horizon-dark") == .selectRow("ayu-dark"))
        #expect(model.action(for: .upArrow, focus: .list, focusedRowID: "ayu-dark") == .selectRow("custom:horizon-dark"))
        #expect(model.action(for: .upArrow, focus: .list, focusedRowID: "custom:horizon-dark") == .editSearch(""))
    }

    @Test func homeAndEndSelectTheFirstAndLastRow() {
        let model = model()
        #expect(model.action(for: .home, focus: .list, focusedRowID: "nord") == .selectRow("ayu-dark"))
        #expect(model.action(for: .end, focus: .list, focusedRowID: "nord") == .selectRow("tomorrow-night-eighties"))
    }

    /// A box's height: 6 rows in Match (200 / 32), 8 in fixed mode (262 / 32).
    @Test func pageKeysMoveABoxAndSelect() {
        let model = model()
        #expect(model.action(for: .pageDown, focus: .list, focusedRowID: "ayu-dark") == .selectRow("everforest-dark-medium"))
        #expect(model.action(for: .pageUp, focus: .list, focusedRowID: "everforest-dark-medium") == .selectRow("ayu-dark"))
        let fixed = self.model(ThemeChoice(light: "github", dark: "nord", mode: .fixed, fixed: "nord"), expanded: .fixed)
        #expect(fixed.action(for: .pageDown, focus: .list, focusedRowID: "ayu-light") == .selectRow("rose-pine-dawn"))
    }

    @Test func spaceSelectsTheFocusedRow() {
        #expect(model().action(for: .space, focus: .list, focusedRowID: "nord") == .selectRow("nord"))
    }

    /// Choose, close, back to the slot.
    @Test func returnInTheListSelectsAndCollapses() {
        #expect(model().action(for: .return, focus: .list, focusedRowID: "nord") == .selectAndCollapse("nord"))
        #expect(model().action(for: .return, focus: .list, focusedRowID: "catppuccin-macchiato") == .selectAndCollapse("catppuccin-macchiato"))
    }

    @Test func escapeInTheListCollapses() {
        #expect(model(query: "gruv").action(for: .escape, focus: .list, focusedRowID: "gruvbox-dark") == .collapse)
    }

    /// No type-select: the keys go on in the search field.
    @Test func lettersAndBackspaceContinueInTheSearchField() {
        #expect(model(query: "gr").action(for: .text("u"), focus: .list, focusedRowID: "gruvbox-dark") == .editSearch("gru"))
        #expect(model(query: "gr").action(for: .deleteBackward, focus: .list, focusedRowID: "gruvbox-dark") == .editSearch("g"))
        #expect(model().action(for: .deleteBackward, focus: .list, focusedRowID: "nord") == .editSearch(""))
    }

    @Test(arguments: [AppearanceKey.leftArrow, .rightArrow])
    func sidewaysDoesNothingInTheList(key: AppearanceKey) {
        #expect(model().action(for: key, focus: .list, focusedRowID: "nord") == .swallow)
    }

    /// Tab lands on the entry row with no ring set yet, and a ring on a row the search filtered
    /// away moves there too.
    @Test func withoutAFocusedRowTheListActsFromTheEntryRow() {
        #expect(model().action(for: .downArrow, focus: .list, focusedRowID: nil) == .selectRow("catppuccin-mocha"))
        #expect(model(query: "gruv").action(for: .space, focus: .list, focusedRowID: "nord") == .selectRow("gruvbox-dark"))
        #expect(model().browser?.focusedRow(nil) == "catppuccin-macchiato")
        #expect(model().browser?.focusedRow("nord") == "nord")
    }

    @Test func nothingButFindActsOutsideTheSlotsSearchAndList() {
        #expect(model().action(for: .escape, focus: .done, focusedRowID: nil) == .pass)
        #expect(model().action(for: .downArrow, focus: nil, focusedRowID: nil) == .pass)
    }

    // MARK: reading keys

    /// Typed text continues the search; Tab, Return and the function keys do not (they have
    /// U+F700… characters).
    @Test func onlyPrintableTextCountsAsTyped() {
        #expect(AppearanceKey.typed("g") == .text("g"))
        #expect(AppearanceKey.typed("É") == .text("É"))
        #expect(AppearanceKey.typed("\t") == nil)
        #expect(AppearanceKey.typed("\r") == nil)
        #expect(AppearanceKey.typed("\u{1B}") == nil)
        #expect(AppearanceKey.typed("\u{7F}") == nil)
        #expect(AppearanceKey.typed(String(UnicodeScalar(0xF700)!)) == nil)
        #expect(AppearanceKey.typed("") == nil)
    }
}
