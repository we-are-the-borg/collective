import Foundation
import Testing
@testable import CollectiveKit

/// The Appearance pane, variant C: a slot per macOS appearance (one in fixed mode), and under the
/// expanded slot a browser with a search field and the sections Custom and Built-in. Custom
/// folders are built in a temporary directory from the real schemes in `Fixtures/custom-themes`
/// (see its README) and read with `CustomThemeFolder`.
@Suite struct AppearanceModelTests {
    private let defaults = ThemeChoice(light: BundledThemes.defaultLight, dark: BundledThemes.defaultDark)

    private func model(
        _ choice: ThemeChoice? = nil, catalog: ThemeCatalog = .bundled, inUse: ThemeAppearance = .light,
        expanded: ThemeSlot? = nil, query: String = ""
    ) -> AppearanceModel {
        AppearanceModel(catalog: catalog, choice: choice ?? defaults, inUse: inUse, expanded: expanded, query: query)
    }

    private func text(_ resource: LocalizedStringResource) -> String { String(localized: resource) }

    // MARK: custom folders

    private static let fixtures = Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures/custom-themes")

    /// A catalog over a fresh folder holding each fixture under the file name it maps to.
    private func catalog(_ files: [String: String]) throws -> ThemeCatalog {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appearance-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, fixture) in files {
            try FileManager.default.copyItem(
                at: Self.fixtures.appendingPathComponent(fixture),
                to: url.appendingPathComponent(name)
            )
        }
        return ThemeCatalog(custom: CustomThemeFolder.entries(in: url))
    }

    // MARK: slots

    @Test func matchingTheSystemShowsALightAndADarkSlot() {
        let slots = model().slots
        #expect(slots.map(\.id) == [.light, .dark])
        #expect(slots.map(\.title) == ["Light Mode", "Dark Mode"])
        #expect(slots.map(\.themeName) == ["Catppuccin Latte", "Catppuccin Macchiato"])
        #expect(slots.map(\.theme.id) == ["catppuccin-latte", "catppuccin-macchiato"])
        #expect(slots.allSatisfy { $0.notice == nil && !$0.isExpanded })
    }

    @Test(arguments: [ThemeAppearance.light, .dark])
    func theSlotMacOSShowsIsInUse(inUse: ThemeAppearance) {
        let slots = model(inUse: inUse).slots
        #expect(slots.filter(\.isInUse).map(\.id) == [inUse == .light ? .light : .dark])
        #expect(text(AppearanceModel.inUseMarker) == " · in use")
    }

    @Test(arguments: [ThemeAppearance.light, .dark])
    func oneSchemeShowsOneSlotNeverInUse(inUse: ThemeAppearance) {
        let choice = ThemeChoice(light: "github", dark: "github-dark", mode: .fixed, fixed: "catppuccin-macchiato")
        let slots = model(choice, inUse: inUse).slots
        #expect(slots.map(\.id) == [.fixed])
        #expect(slots.map(\.title) == ["Scheme"])
        #expect(slots.map(\.themeName) == ["Catppuccin Macchiato"])
        #expect(slots.allSatisfy { !$0.isInUse })
    }

    @Test func theSlotShowsTheChosenSchemesFullName() {
        let slots = model(ThemeChoice(light: "github", dark: "tokyo-night-moon")).slots
        #expect(slots.map(\.themeName) == ["GitHub Light", "Tokyo Night Moon"])
    }

    /// The VoiceOver table: label the slot's name, value the full name with "Default" (Match
    /// only), "in use" and whether its browser is open, as a button with no expanded state of its
    /// own reads it.
    @Test func voiceOverReadsTheSlotWithItsSchemeDefaultInUseAndState() {
        let slots = model(inUse: .light).slots
        #expect(slots.map(\.accessibilityLabel) == ["Light Mode", "Dark Mode"])
        #expect(slots.map(\.accessibilityValue) == ["Catppuccin Latte, Default, in use, collapsed", "Catppuccin Macchiato, Default, collapsed"])
        let chosen = model(ThemeChoice(light: "github", dark: "gruvbox-dark"), inUse: .dark, expanded: .dark).slots
        #expect(chosen.map(\.accessibilityValue) == ["GitHub Light, collapsed", "Gruvbox Dark, in use, expanded"])
        let fixed = model(ThemeChoice(light: "github", dark: "github-dark", mode: .fixed, fixed: "catppuccin-macchiato"), expanded: .fixed).slots
        #expect(fixed.map(\.accessibilityLabel) == ["Scheme"])
        #expect(fixed.map(\.accessibilityValue) == ["Catppuccin Macchiato, expanded"])
    }

    @Test func onlyTheExpandedSlotOfTheModeIsExpanded() {
        #expect(model(expanded: .dark).slots.map(\.isExpanded) == [false, true])
        #expect(model(expanded: .fixed).slots.map(\.isExpanded) == [false, false])
        #expect(model(expanded: .fixed).browser == nil)
        #expect(model().browser == nil)
    }

    // MARK: browser

    private static let lightIDs = [
        "ayu-light", "catppuccin-latte", "everforest-light-medium", "github", "github-light-high-contrast",
        "gruvbox-light", "material-lighter", "one-light", "rose-pine-dawn", "solarized-light",
        "tokyo-night-light", "tomorrow",
    ]

    private static let darkIDs = [
        "ayu-dark", "ayu-mirage", "catppuccin-frappe", "catppuccin-macchiato", "catppuccin-mocha", "dracula",
        "everforest-dark-medium", "github-dark", "github-dark-dimmed", "github-dark-high-contrast",
        "gruvbox-dark", "kanagawa", "kanagawa-dragon", "material", "material-darker", "material-palenight",
        "nord", "one-dark", "rose-pine", "rose-pine-moon", "solarized-dark",
        "tokyo-night-dark", "tokyo-night-moon", "tokyo-night-storm", "tomorrow-night", "tomorrow-night-eighties",
    ]

    private func rows(_ section: AppearanceModel.Section?) -> [AppearanceModel.Row] {
        (section?.items ?? []).compactMap { if case .row(let row) = $0 { row } else { nil } }
    }

    private func section(_ kind: AppearanceModel.Section.Kind, _ browser: AppearanceModel.Browser?) -> AppearanceModel.Section? {
        browser?.sections.first { $0.id == kind }
    }

    /// A section's items as the list shows them: headers by title, rows by id, error rows by file.
    private func layout(_ section: AppearanceModel.Section?) -> [String] {
        (section?.items ?? []).map { item in
            switch item {
            case .header(let title): "# \(title)"
            case .row(let row): row.id
            case .error(let row): "! \(row.fileName)"
            }
        }
    }

    @Test func theBrowserNamesItsAreaAfterTheSlot() {
        #expect(model(expanded: .light).browser?.accessibilityLabel == "Light Mode schemes")
        #expect(model(expanded: .dark).browser?.accessibilityLabel == "Dark Mode schemes")
        let fixed = ThemeChoice(light: "github", dark: "github-dark", mode: .fixed, fixed: "nord")
        #expect(model(fixed, expanded: .fixed).browser?.accessibilityLabel == "All schemes")
    }

    /// Custom on top even without custom themes, then Built-in, each a radio group for VoiceOver.
    @Test func theSectionsAreCustomThenBuiltIn() {
        let browser = model(expanded: .dark).browser
        #expect(browser?.sections.map(\.id) == [.custom, .builtIn])
        #expect(browser?.sections.map(\.title) == ["Custom", "Built-in"])
        #expect(browser?.sections.map(\.accessibilityLabel) == ["Dark Mode, custom themes", "Dark Mode, built-in schemes"])
        #expect(section(.custom, browser)?.items == [])
        let fixed = ThemeChoice(light: "github", dark: "github-dark", mode: .fixed, fixed: "nord")
        #expect(model(fixed, expanded: .fixed).browser?.sections.map(\.accessibilityLabel)
            == ["Scheme, custom themes", "Scheme, built-in schemes"])
    }

    /// The list's name for VoiceOver carries the count: a group has no value VoiceOver reads.
    @Test func theListIsNamedLikeTheBrowserWithTheCount() {
        #expect(model(expanded: .dark, query: "catppuccin").browser?.listAccessibilityLabel == "Dark Mode schemes, 3 schemes")
        #expect(model(expanded: .light, query: "gruv").browser?.listAccessibilityLabel == "Light Mode schemes, 1 scheme")
    }

    /// For VoiceOver each section is its heading, its error rows as text where they stand
    /// and its rows as one radio group; the variant headers are left out.
    @Test func voiceOverReadsASectionAsHeadingTextAndRadioGroup() throws {
        let catalog = try mixedFolder()
        let match = try #require(section(.custom, model(catalog: catalog, expanded: .dark).browser))
        #expect(voiceOver(match) == ["radio custom:ocean custom:horizon-dark", "text Error, broken.yaml, missing palette key base0D", "text Error, ocean.yml, same file name as ocean.yaml"])
        let fixed = try #require(section(.custom, model(fixedNord, catalog: catalog, expanded: .fixed).browser))
        #expect(voiceOver(fixed) == ["text Error, broken.yaml, missing palette key base0D", "text Error, ocean.yml, same file name as ocean.yaml", "radio custom:embers-light custom:ocean custom:horizon-dark"])
        let builtIn = try #require(section(.builtIn, model(fixedNord, expanded: .fixed).browser))
        #expect(voiceOver(builtIn) == ["radio " + (Self.lightIDs + Self.darkIDs).joined(separator: " ")])
        #expect(voiceOver(try #require(section(.custom, model(expanded: .dark).browser))) == [])
    }

    private func voiceOver(_ section: AppearanceModel.Section) -> [String] {
        section.accessibilityParts.map { part in
            switch part {
            case .radioGroup(let rows): "radio " + rows.map(\.id).joined(separator: " ")
            case .error(let row): "text \(row.accessibilityLabel)"
            }
        }
    }

    /// The count waits 0.5 s after the last keystroke; the sentence without matches is
    /// read at once.
    @Test func theCountWaitsAndTheSentenceDoesNot() {
        #expect(model(expanded: .dark, query: "gruv").browser?.announcementDelay == .milliseconds(500))
        #expect(model(expanded: .dark, query: "xyz").browser?.announcementDelay == .zero)
    }

    @Test func aRowIsFoundByItsID() {
        let browser = model(expanded: .dark).browser
        #expect(browser?.row("nord")?.accessibilityLabel == "Nord")
        #expect(browser?.row("catppuccin-latte") == nil)
    }

    /// Families alphabetically, "Rosé Pine" as "Rose" between One and Solarized; within a
    /// family Unimatrix's order, Moon before Dawn.
    @Test func matchListsTheSlotsVariantFamiliesAlphabetically() {
        #expect(layout(section(.builtIn, model(expanded: .light).browser)) == Self.lightIDs)
        #expect(layout(section(.builtIn, model(expanded: .dark).browser)) == Self.darkIDs)
    }

    /// Light first under its header, then dark, the family order kept within each.
    @Test func oneSchemeListsEveryLightSchemeThenEveryDarkOneUnderHeaders() {
        let fixed = ThemeChoice(light: "github", dark: "github-dark", mode: .fixed, fixed: "nord")
        let builtIn = section(.builtIn, model(fixed, expanded: .fixed).browser)
        #expect(layout(builtIn) == ["# Light"] + Self.lightIDs + ["# Dark"] + Self.darkIDs)
    }

    @Test func aBuiltInRowShowsShortNameAndFamilyWithDefaultInMatch() {
        let light = Dictionary(uniqueKeysWithValues: rows(section(.builtIn, model(expanded: .light).browser)).map { ($0.id, $0) })
        #expect(light["catppuccin-latte"]?.name == "Latte")
        #expect(light["catppuccin-latte"]?.secondaryText == "Catppuccin · Default")
        #expect(light["github"]?.name == "Light")
        #expect(light["github"]?.secondaryText == "GitHub")
        #expect(light["rose-pine-dawn"]?.secondaryText == "Rosé Pine")
        #expect(light["github"]?.appearance == .light)
        #expect(light["github"]?.fileURL == nil)
        let dark = Dictionary(uniqueKeysWithValues: rows(section(.builtIn, model(expanded: .dark).browser)).map { ($0.id, $0) })
        #expect(dark["catppuccin-macchiato"]?.secondaryText == "Catppuccin · Default")
        // The family in every row, also where it is the short name.
        #expect(dark["dracula"]?.name == "Dracula")
        #expect(dark["dracula"]?.secondaryText == "Dracula")
        #expect(dark["catppuccin-frappe"]?.name == "Frappé")
    }

    @Test func oneSchemeMarksNoDefault() {
        let fixed = ThemeChoice(light: "github", dark: "github-dark", mode: .fixed, fixed: "nord")
        let rows = rows(section(.builtIn, model(fixed, expanded: .fixed).browser))
        #expect(rows.first { $0.id == "catppuccin-latte" }?.secondaryText == "Catppuccin")
        #expect(rows.allSatisfy { !$0.secondaryText.contains("Default") && !$0.accessibilityLabel.contains("Default") })
    }

    /// The VoiceOver table: the full name, "Default" in Match, the variant in fixed mode.
    @Test func voiceOverReadsARowsFullNameWithDefaultOrVariant() {
        let dark = Dictionary(uniqueKeysWithValues: rows(section(.builtIn, model(expanded: .dark).browser)).map { ($0.id, $0.accessibilityLabel) })
        #expect(dark["catppuccin-macchiato"] == "Catppuccin Macchiato, Default")
        #expect(dark["gruvbox-dark"] == "Gruvbox Dark")
        #expect(dark["dracula"] == "Dracula")
        #expect(dark["rose-pine-moon"] == "Rosé Pine Moon")
        let fixed = ThemeChoice(light: "github", dark: "github-dark", mode: .fixed, fixed: "nord")
        let all = Dictionary(uniqueKeysWithValues: rows(section(.builtIn, model(fixed, expanded: .fixed).browser)).map { ($0.id, $0.accessibilityLabel) })
        #expect(all["catppuccin-macchiato"] == "Catppuccin Macchiato, Dark")
        #expect(all["catppuccin-latte"] == "Catppuccin Latte, Light")
    }

    @Test func theSlotsSchemeIsChecked() {
        let choice = ThemeChoice(light: "github", dark: "gruvbox-dark")
        #expect(rows(section(.builtIn, model(choice, expanded: .light).browser)).filter(\.isSelected).map(\.id) == ["github"])
        #expect(rows(section(.builtIn, model(choice, expanded: .dark).browser)).filter(\.isSelected).map(\.id) == ["gruvbox-dark"])
        let fixed = ThemeChoice(light: "github", dark: "github-dark", mode: .fixed, fixed: "nord")
        #expect(rows(section(.builtIn, model(fixed, expanded: .fixed).browser)).filter(\.isSelected).map(\.id) == ["nord"])
    }

    /// Like the slot: an id no scheme has, say from an old setting, shows and checks the default.
    @Test func anUnknownBundledIDChecksTheDefault() {
        let choice = ThemeChoice(light: "gone", dark: "")
        #expect(rows(section(.builtIn, model(choice, expanded: .light).browser)).filter(\.isSelected).map(\.id) == ["catppuccin-latte"])
        #expect(model(choice).slots.map(\.themeName) == ["Catppuccin Latte", "Catppuccin Macchiato"])
    }

    /// Closed slots derive only the themes they show; the open browser lists every scheme.
    @Test func closedSlotsDeriveOnlyTheirOwnThemes() {
        let shelf = ThemeShelf(folder: FixtureThemes.folder)
        let catalog = ThemeCatalog(shelf: shelf, custom: [])
        _ = model(ThemeChoice(light: "github", dark: "nord"), catalog: catalog)
        #expect(shelf.derivedIDs == ["github", "nord"])
    }

    // MARK: custom themes

    /// Two dark custom themes, a light one, a file that loses its stem to another and a file
    /// missing a color.
    private func mixedFolder() throws -> ThemeCatalog {
        try catalog([
            "horizon-dark.yaml": "horizon-dark.yaml",
            "ocean.yaml": "espresso.yaml",
            "ocean.yml": "horizon-dark.yaml",
            "embers-light.yaml": "embers-light.yaml",
            "broken.yaml": "missing-base0D.yaml",
        ])
    }

    /// Custom rows of the slot's variant by name, then the error rows.
    @Test func matchListsTheSlotsCustomThemesByNameThenTheErrorRows() throws {
        let catalog = try mixedFolder()
        #expect(layout(section(.custom, model(catalog: catalog, expanded: .dark).browser))
            == ["custom:ocean", "custom:horizon-dark", "! broken.yaml", "! ocean.yml"])
        #expect(layout(section(.custom, model(catalog: catalog, expanded: .light).browser))
            == ["custom:embers-light", "! broken.yaml", "! ocean.yml"])
    }

    /// In fixed mode the error rows sit right under Custom, before the variant headers: their
    /// variant is unknown.
    @Test func oneSchemePutsTheErrorRowsBeforeTheVariantHeaders() throws {
        let fixed = ThemeChoice(light: "github", dark: "github-dark", mode: .fixed, fixed: "nord")
        #expect(layout(section(.custom, try model(fixed, catalog: mixedFolder(), expanded: .fixed).browser))
            == ["! broken.yaml", "! ocean.yml", "# Light", "custom:embers-light", "# Dark", "custom:ocean", "custom:horizon-dark"])
    }

    @Test func aCustomRowShowsTheNameFromItsFileAndTheFileName() throws {
        let catalog = try mixedFolder()
        let row = try #require(rows(section(.custom, model(catalog: catalog, expanded: .dark).browser)).first { $0.id == "custom:horizon-dark" })
        #expect(row.name == "Horizon Dark")
        #expect(row.secondaryText == "horizon-dark.yaml")
        #expect(row.appearance == .dark)
        #expect(row.fileURL?.lastPathComponent == "horizon-dark.yaml")
        #expect(row.accessibilityLabel == "Horizon Dark, custom, horizon-dark.yaml")
        let fixed = ThemeChoice(light: "github", dark: "github-dark", mode: .fixed, fixed: "nord")
        let all = rows(section(.custom, model(fixed, catalog: catalog, expanded: .fixed).browser))
        #expect(all.map(\.accessibilityLabel) == [
            "Embers Light, custom, embers-light.yaml, Light",
            "Espresso, custom, ocean.yaml, Dark",
            "Horizon Dark, custom, horizon-dark.yaml, Dark",
        ])
    }

    /// File name and problem, the whole of both as the tooltip, read as text.
    @Test func anErrorRowNamesItsFileAndProblem() throws {
        let items = section(.custom, try model(catalog: mixedFolder(), expanded: .dark).browser)?.items ?? []
        let errors = items.compactMap { if case .error(let row) = $0 { row } else { nil } }
        #expect(errors.map(\.fileName) == ["broken.yaml", "ocean.yml"])
        #expect(errors.map(\.problem) == ["missing palette key base0D", "same file name as ocean.yaml"])
        #expect(errors.map(\.tooltip) == ["broken.yaml · missing palette key base0D", "ocean.yml · same file name as ocean.yaml"])
        #expect(errors.map(\.accessibilityLabel) == [
            "Error, broken.yaml, missing palette key base0D", "Error, ocean.yml, same file name as ocean.yaml",
        ])
        #expect(errors.map(\.url.lastPathComponent) == ["broken.yaml", "ocean.yml"])
    }

    /// A custom file named like a bundled scheme sits beside it, in its own section.
    @Test func aCustomThemeNamedLikeABundledOneIsListedInBothSections() throws {
        let browser = model(catalog: try catalog(["github-dark.yaml": "horizon-dark.yaml"]), expanded: .dark).browser
        #expect(layout(section(.custom, browser)) == ["custom:github-dark"])
        #expect(layout(section(.builtIn, browser)) == Self.darkIDs)
    }

    @Test func theChosenCustomThemeIsChecked() throws {
        let catalog = try mixedFolder()
        let choice = defaults.choosing("custom:horizon-dark", for: .dark, catalog: catalog)
        let browser = model(choice, catalog: catalog, expanded: .dark).browser
        #expect(rows(section(.custom, browser)).filter(\.isSelected).map(\.id) == ["custom:horizon-dark"])
        #expect(rows(section(.builtIn, browser)).allSatisfy { !$0.isSelected })
        #expect(model(choice, catalog: catalog).slots[1].themeName == "Horizon Dark")
    }

    /// The default stands in with a notice on the slot, and no row carries the check, not
    /// even the default's.
    @Test func aMissingCustomThemeShowsTheNoticeAndChecksNothing() throws {
        let choice = defaults.choosing("custom:horizon-dark", for: .dark, catalog: try mixedFolder())
        let gone = try catalog(["embers-light.yaml": "embers-light.yaml"])
        let model = model(choice, catalog: gone, inUse: .dark, expanded: .dark)
        #expect(model.slots.map(\.notice) == [nil, "Horizon Dark is gone. Using Catppuccin Macchiato."])
        #expect(model.slots[1].themeName == "Catppuccin Macchiato")
        #expect(model.slots[1].theme.id == "catppuccin-macchiato")
        #expect(model.slots[1].accessibilityValue == "Catppuccin Macchiato, in use, expanded")
        #expect(model.browser?.sections.flatMap { rows($0) }.allSatisfy { !$0.isSelected } == true)
    }

    // MARK: search

    private let fixedNord = ThemeChoice(light: "github", dark: "github-dark", mode: .fixed, fixed: "nord")

    private func builtIn(_ query: String, _ slot: ThemeSlot = .dark, _ choice: ThemeChoice? = nil) -> [String] {
        layout(section(.builtIn, model(choice, expanded: slot, query: query).browser))
    }

    @Test func searchIgnoresCaseAndAccents() {
        #expect(builtIn("rose") == ["rose-pine", "rose-pine-moon"])
        #expect(builtIn("rose", .light) == ["rose-pine-dawn"])
        #expect(builtIn("ROSÉ") == ["rose-pine", "rose-pine-moon"])
        #expect(builtIn("frappe") == ["catppuccin-frappe"])
        #expect(builtIn("Frappé") == ["catppuccin-frappe"])
    }

    /// The variant word matches too: "dark" finds Mocha and Dracula, whose names lack it.
    @Test func searchFindsTheVariant() {
        let all = builtIn("dark", .fixed, fixedNord)
        #expect(all == ["# Dark"] + Self.darkIDs)
        #expect(all.contains("catppuccin-mocha") && all.contains("dracula"))
        #expect(builtIn("light", .fixed, fixedNord) == ["# Light"] + Self.lightIDs)
    }

    /// Every word must match, whatever the spaces between them.
    @Test func everyWordOfTheQueryMustMatch() {
        #expect(builtIn("gruv dark", .fixed, fixedNord) == ["# Dark", "gruvbox-dark"])
        #expect(builtIn("  tokyo   MOON ") == ["tokyo-night-moon"])
        #expect(builtIn("tokyo night") == ["tokyo-night-dark", "tokyo-night-moon", "tokyo-night-storm"])
    }

    @Test func anEmptyOrBlankQueryListsEverything() {
        #expect(builtIn("") == Self.darkIDs)
        #expect(builtIn("   ") == Self.darkIDs)
    }

    /// Custom rows match on name, file name and variant; error rows on the file name.
    @Test func searchFindsCustomThemesByNameFileNameAndVariant() throws {
        let catalog = try mixedFolder()
        func custom(_ query: String, _ slot: ThemeSlot = .dark, _ choice: ThemeChoice? = nil) -> [String] {
            layout(section(.custom, model(choice, catalog: catalog, expanded: slot, query: query).browser))
        }
        #expect(custom("horizon") == ["custom:horizon-dark"])
        #expect(custom("Espresso") == ["custom:ocean"])
        #expect(custom("ocean") == ["custom:ocean", "! ocean.yml"])
        #expect(custom("horizon-dark.yaml") == ["custom:horizon-dark"])
        #expect(custom("light", .fixed, fixedNord) == ["# Light", "custom:embers-light"])
        #expect(layout(section(.builtIn, model(catalog: catalog, expanded: .dark, query: "horizon").browser)) == [])
    }

    /// A row that does not match loses its check: nothing in the list is checked then.
    @Test func aFilteredOutChoiceChecksNothing() {
        let browser = model(ThemeChoice(light: "github", dark: "gruvbox-dark"), expanded: .dark, query: "rose").browser
        #expect(browser?.sections.flatMap { rows($0) }.allSatisfy { !$0.isSelected } == true)
    }

    // MARK: no matches and the count

    @Test func withoutMatchesTheListGivesWayToASentence() {
        let dark = model(expanded: .dark, query: "xyz").browser
        #expect(dark?.sections == [])
        #expect(dark?.emptyText == "No dark schemes match “xyz”.")
        #expect(dark?.countAnnouncement == "No dark schemes match “xyz”.")
        #expect(dark?.rowIDs == [])
        #expect(model(expanded: .light, query: "xyz").browser?.emptyText == "No light schemes match “xyz”.")
        #expect(model(fixedNord, expanded: .fixed, query: "Gruv xyz").browser?.emptyText == "No schemes match “Gruv xyz”.")
        #expect(model(expanded: .dark, query: "rose").browser?.emptyText == nil)
    }

    /// Error rows are no schemes: matching one keeps no list (it would have no row to select).
    @Test func anErrorRowAloneDoesNotKeepTheList() throws {
        let browser = model(catalog: try mixedFolder(), expanded: .dark, query: "broken").browser
        #expect(browser?.sections == [])
        #expect(browser?.emptyText == "No dark schemes match “broken”.")
    }

    @Test func theCountNamesTheSelectableMatches() throws {
        #expect(model(expanded: .dark, query: "catppuccin").browser?.countAnnouncement == "3 schemes")
        #expect(model(expanded: .dark, query: "gruv").browser?.countAnnouncement == "1 scheme")
        #expect(model(expanded: .dark).browser?.countAnnouncement == "26 schemes")
        #expect(model(fixedNord, expanded: .fixed).browser?.countAnnouncement == "38 schemes")
        // Custom rows count, error rows do not.
        #expect(model(catalog: try mixedFolder(), expanded: .dark).browser?.countAnnouncement == "28 schemes")
        #expect(model(catalog: try mixedFolder(), expanded: .dark, query: "ocean").browser?.countAnnouncement == "1 scheme")
    }

    // MARK: selecting

    @Test func selectingInALightBrowserChangesOnlyLight() {
        let choice = ThemeChoice(light: "catppuccin-latte", dark: "github-dark")
        #expect(model(choice, expanded: .light).selecting("github-light-high-contrast")
            == ThemeChoice(light: "github-light-high-contrast", dark: "github-dark"))
    }

    @Test func selectingACustomThemeRemembersItsName() throws {
        let catalog = try mixedFolder()
        let choice = ThemeChoice(light: "github", dark: "github-dark")
        #expect(model(choice, catalog: catalog, expanded: .dark).selecting("custom:horizon-dark") == ThemeChoice(
            light: "github", dark: "custom:horizon-dark",
            darkRemembered: RememberedCustomTheme(name: "Horizon Dark", appearance: .dark)
        ))
    }

    @Test func selectingInOneSchemeChangesOnlyTheFixedScheme() throws {
        #expect(model(fixedNord, expanded: .fixed).selecting("catppuccin-latte")
            == ThemeChoice(light: "github", dark: "github-dark", mode: .fixed, fixed: "catppuccin-latte"))
        let catalog = try mixedFolder()
        #expect(model(fixedNord, catalog: catalog, expanded: .fixed).selecting("custom:embers-light") == ThemeChoice(
            light: "github", dark: "github-dark", mode: .fixed, fixed: "custom:embers-light",
            fixedRemembered: RememberedCustomTheme(name: "Embers Light", appearance: .light)
        ))
    }

    /// Error rows, rows of another browser and closed browsers select nothing.
    @Test func onlyARowOfTheOpenBrowserCanBeSelected() throws {
        let catalog = try mixedFolder()
        let choice = ThemeChoice(light: "github", dark: "github-dark")
        #expect(model(choice, catalog: catalog, expanded: .light).selecting("catppuccin-mocha") == choice)
        #expect(model(choice, catalog: catalog, expanded: .light).selecting("ocean.yml") == choice)
        #expect(model(choice, catalog: catalog, expanded: .light).selecting("error:ocean.yml") == choice)
        #expect(model(choice, catalog: catalog, expanded: .light).selecting("custom:ocean") == choice)
        #expect(model(choice, catalog: catalog).selecting("github-light-high-contrast") == choice)
        #expect(model(choice, catalog: catalog, expanded: .dark, query: "rose").selecting("gruvbox-dark") == choice)
    }

    /// A pick for the slot macOS does not show changes its check and preview, not the
    /// windows.
    @Test func aPickForTheSlotNotInUseChangesOnlyThatSlot() {
        let next = model(inUse: .light, expanded: .dark).selecting("gruvbox-dark")
        #expect(next.activeTheme(system: .light, catalog: .bundled).id == "catppuccin-latte")
        let after = model(next, inUse: .light, expanded: .dark)
        #expect(after.slots.map(\.theme.id) == ["catppuccin-latte", "gruvbox-dark"])
        #expect(rows(section(.builtIn, after.browser)).filter(\.isSelected).map(\.id) == ["gruvbox-dark"])
    }

    /// A pick ends a fallback: the notice goes, the new row carries the check.
    @Test func aPickEndsTheFallback() throws {
        let choice = defaults.choosing("custom:horizon-dark", for: .dark, catalog: try mixedFolder())
        let gone = ThemeCatalog.bundled
        let next = model(choice, catalog: gone, expanded: .dark).selecting("catppuccin-macchiato")
        let after = model(next, catalog: gone, expanded: .dark)
        #expect(after.slots[1].notice == nil)
        #expect(rows(section(.builtIn, after.browser)).filter(\.isSelected).map(\.id) == ["catppuccin-macchiato"])
    }

    // MARK: keyboard

    /// Across both sections in list order, past the variant headers, without the error rows.
    @Test func theArrowKeysPathIsEverySelectableRowInListOrder() throws {
        let catalog = try mixedFolder()
        #expect(model(catalog: catalog, expanded: .dark).browser?.rowIDs
            == ["custom:ocean", "custom:horizon-dark"] + Self.darkIDs)
        #expect(model(fixedNord, catalog: catalog, expanded: .fixed).browser?.rowIDs
            == ["custom:embers-light", "custom:ocean", "custom:horizon-dark"] + Self.lightIDs + Self.darkIDs)
    }

    @Test func enteringTheListLandsOnTheCheckedRowIfItMatches() throws {
        let choice = ThemeChoice(light: "github", dark: "rose-pine-moon")
        #expect(model(choice, expanded: .dark).browser?.entryRowID == "rose-pine-moon")
        #expect(model(choice, expanded: .dark, query: "rose").browser?.entryRowID == "rose-pine-moon")
        #expect(model(choice, expanded: .dark, query: "gruv").browser?.entryRowID == "gruvbox-dark")
        #expect(model(choice, catalog: try mixedFolder(), expanded: .dark, query: "o").browser?.entryRowID == "rose-pine-moon")
        #expect(model(choice, expanded: .dark, query: "xyz").browser?.entryRowID == nil)
    }

    @Test func duringAFallbackEnteringTheListLandsOnTheFirstRow() throws {
        let choice = defaults.choosing("custom:horizon-dark", for: .dark, catalog: try mixedFolder())
        #expect(model(choice, expanded: .dark).browser?.entryRowID == "ayu-dark")
    }

    /// Held at both ends; the step from the last custom row lands on the first built-in one.
    @Test func stepsCrossTheSectionsAndHoldAtTheEnds() throws {
        let browser = try #require(model(catalog: try mixedFolder(), expanded: .dark).browser)
        #expect(browser.rowID(from: "custom:horizon-dark", by: 1) == "ayu-dark")
        #expect(browser.rowID(from: "ayu-dark", by: -1) == "custom:horizon-dark")
        #expect(browser.rowID(from: "custom:ocean", by: -1) == "custom:ocean")
        #expect(browser.rowID(from: "tomorrow-night-eighties", by: 1) == "tomorrow-night-eighties")
        // A page: as many rows as the box holds, past headers like ↓.
        #expect(browser.rowID(from: "custom:ocean", by: 6) == "catppuccin-mocha")
        #expect(browser.rowID(from: "tokyo-night-storm", by: 6) == "tomorrow-night-eighties")
        #expect(browser.rowID(from: "ayu-dark", by: -6) == "custom:ocean")
        #expect(browser.rowIDs.first == "custom:ocean")
        #expect(browser.rowIDs.last == "tomorrow-night-eighties")
        #expect(browser.rowID(from: "ocean.yml", by: 1) == nil)
    }

    @Test func inOneSchemeAStepCrossesTheVariantHeader() throws {
        let browser = try #require(model(fixedNord, expanded: .fixed).browser)
        #expect(browser.rowID(from: "tomorrow", by: 1) == "ayu-dark")
        #expect(browser.rowID(from: "ayu-dark", by: -1) == "tomorrow")
    }

    // MARK: mode

    @Test func theModeIsStoredAsSystemOrFixed() {
        #expect(ThemeMode.system.rawValue == "system")
        #expect(ThemeMode.fixed.rawValue == "fixed")
        #expect(ThemeMode(rawValue: "fixed") == .fixed)
        #expect(ThemeMode(rawValue: "other") == nil)
    }

    @Test func aChoiceMatchesTheSystemByDefault() {
        let choice = ThemeChoice(light: "github", dark: "github-dark")
        #expect(choice.mode == .system)
        #expect(choice.fixed == "catppuccin-latte")
    }

    @Test func matchingTheSystemTheSlotOfTheSystemAppearanceIsActive() {
        let choice = ThemeChoice(light: "github", dark: "github-dark", mode: .system, fixed: "catppuccin-mocha")
        #expect(choice.activeTheme(system: .light, catalog: .bundled).id == "github")
        #expect(choice.activeTheme(system: .dark, catalog: .bundled).id == "github-dark")
        #expect(choice.activeAppearance(system: .light, catalog: .bundled) == .light)
        #expect(choice.activeAppearance(system: .dark, catalog: .bundled) == .dark)
    }

    @Test func oneSchemeIsActiveWhateverTheSystemAppearance() {
        let choice = ThemeChoice(light: "github", dark: "github-dark", mode: .fixed, fixed: "catppuccin-mocha")
        #expect(choice.activeTheme(system: .light, catalog: .bundled).id == "catppuccin-mocha")
        #expect(choice.activeTheme(system: .dark, catalog: .bundled).id == "catppuccin-mocha")
        #expect(choice.activeAppearance(system: .light, catalog: .bundled) == .dark)
    }

    @Test func aFixedLightSchemeStaysLightInDarkMode() {
        let choice = ThemeChoice(light: "catppuccin-latte", dark: "catppuccin-macchiato", mode: .fixed, fixed: "github")
        #expect(choice.activeTheme(system: .dark, catalog: .bundled).id == "github")
        #expect(choice.activeAppearance(system: .dark, catalog: .bundled) == .light)
    }

    @Test func anUnknownFixedIDFallsBackToTheDefaultOfTheSystemAppearance() {
        let choice = ThemeChoice(light: "github", dark: "github-dark", mode: .fixed, fixed: "gone")
        #expect(choice.activeTheme(system: .light, catalog: .bundled).id == "catppuccin-latte")
        #expect(choice.activeTheme(system: .dark, catalog: .bundled).id == "catppuccin-macchiato")
    }

    @Test func switchingToOneSchemePreselectsTheSchemeActiveNow() {
        let choice = ThemeChoice(light: "github", dark: "github-dark-dimmed", mode: .system, fixed: "catppuccin-latte")
        #expect(choice.switching(to: .fixed, system: .dark, catalog: .bundled)
            == ThemeChoice(light: "github", dark: "github-dark-dimmed", mode: .fixed, fixed: "github-dark-dimmed"))
        #expect(choice.switching(to: .fixed, system: .light, catalog: .bundled)
            == ThemeChoice(light: "github", dark: "github-dark-dimmed", mode: .fixed, fixed: "github"))
    }

    @Test func switchingBackToTheSystemKeepsTheSlots() {
        let choice = ThemeChoice(light: "github", dark: "github-dark-dimmed", mode: .fixed, fixed: "catppuccin-mocha")
        #expect(choice.switching(to: .system, system: .light, catalog: .bundled)
            == ThemeChoice(light: "github", dark: "github-dark-dimmed", mode: .system, fixed: "catppuccin-mocha"))
    }

    @Test func switchingToTheCurrentModeChangesNothing() {
        let choice = ThemeChoice(light: "github", dark: "github-dark", mode: .fixed, fixed: "catppuccin-mocha")
        #expect(choice.switching(to: .fixed, system: .light, catalog: .bundled) == choice)
    }

    // MARK: texts

    @Test func theModeTexts() {
        #expect(text(AppearanceModel.matchSystemLabel) == "Match the macOS appearance")
        #expect(text(AppearanceModel.fixedLabel) == "Always use one scheme")
        #expect(text(AppearanceModel.searchPlaceholder) == "Search schemes")
        #expect(text(AppearanceModel.clearSearch) == "Clear search")
        #expect(text(AppearanceModel.done) == "Done")
        #expect(text(AppearanceModel.defaultMarker) == " · Default")
    }

    // MARK: custom theme controls

    @Test func theCustomThemeControlsUseTheDesignsTexts() {
        #expect(text(AppearanceModel.importTheme) == "Import Theme…")
        #expect(text(AppearanceModel.showInFinder) == "Show in Finder")
        #expect(text(AppearanceModel.moveToTrash) == "Move to Trash")
    }

    /// The footnote's link is the run „tinted-theming ↗", to the schemes repo; the rest is text.
    @Test func theFootnoteLinksTintedTheming() throws {
        let footnote = AppearanceModel.customThemesFootnote
        #expect(String(footnote.characters) == "Custom themes are base16 or base24 YAML files, like those from tinted-theming\u{00A0}↗.")
        let links = footnote.runs.compactMap { run in run.link.map { (String(footnote[run.range].characters), $0) } }
        #expect(links.count == 1)
        #expect(links.first?.0 == "tinted-theming\u{00A0}↗")
        #expect(links.first?.1 == URL(string: "https://github.com/tinted-theming/schemes"))
    }

    /// The path under the footnote names the home folder `~`, with a closing slash.
    @Test func theFolderPathStartsAtTheHomeFolder() {
        let folder = URL(fileURLWithPath: "/Users/user/Library/Application Support/The Collective/Themes", isDirectory: true)
        #expect(AppearanceModel.folderPath(folder, home: "/Users/user") == "~/Library/Application Support/The Collective/Themes/")
        #expect(AppearanceModel.folderPath(folder, home: "/Users/user/Lib") == "/Users/user/Library/Application Support/The Collective/Themes/")
        #expect(AppearanceModel.folderPath(folder, home: "/Users/user/") == "~/Library/Application Support/The Collective/Themes/")
    }
}

