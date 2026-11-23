import Foundation
import Testing
@testable import CollectiveKit

/// The bundled themes plus the user's folder, and a stored choice resolved against them with the
/// fallback to the default of its variant. Folders are built in a temporary directory from the real schemes in
/// `Fixtures/custom-themes` (see its README) and read with `CustomThemeFolder`.
@Suite("Theme catalog")
struct ThemeCatalogTests {
    private static let fixtures = Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures/custom-themes")

    /// A fresh folder holding each fixture under the file name it maps to.
    private func folder(_ files: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, fixture) in files {
            try add(fixture, as: name, to: url)
        }
        return url
    }

    private func add(_ fixture: String, as name: String, to folder: URL) throws {
        try FileManager.default.copyItem(
            at: Self.fixtures.appendingPathComponent(fixture),
            to: folder.appendingPathComponent(name)
        )
    }

    private func catalog(_ folder: URL) -> ThemeCatalog {
        ThemeCatalog(custom: CustomThemeFolder.entries(in: folder))
    }

    private func english(_ text: LocalizedStringResource) -> String {
        var text = text
        text.locale = Locale(identifier: "en")
        return String(localized: text)
    }

    // MARK: lookup

    @Test func theBundledCatalogHasNoCustomThemes() {
        #expect(ThemeCatalog.bundled.customThemes.isEmpty)
        #expect(ThemeCatalog.bundled.brokenThemes.isEmpty)
        #expect(ThemeCatalog.bundled.theme("github")?.name == "Github Light")
        #expect(ThemeCatalog.bundled.theme("custom:github") == nil)
        #expect(ThemeCatalog.bundled.theme("no-such-theme") == nil)
    }

    @Test func aCustomThemeNamedLikeABundledOneSitsBesideIt() throws {
        let catalog = try catalog(folder(["github.yaml": "horizon-dark.yaml"]))
        #expect(catalog.theme("github")?.name == "Github Light")
        #expect(catalog.theme("custom:github")?.name == "Horizon Dark")
        #expect(catalog.theme("custom:github")?.id == "custom:github")
    }

    @Test func theCatalogListsValidAndBrokenCustomFiles() throws {
        let catalog = try catalog(folder([
            "horizon-dark.yaml": "horizon-dark.yaml",
            "embers-light.yaml": "embers-light.yaml",
            "ocean.yaml": "missing-name.yaml",
        ]))
        #expect(catalog.customThemes.map(\.id) == ["custom:embers-light", "custom:horizon-dark"])
        #expect(catalog.brokenThemes.map(\.fileName) == ["ocean.yaml"])
        #expect(catalog.theme("custom:ocean") == nil)
    }

    // MARK: choosing

    private let defaults = ThemeChoice(light: BundledThemes.defaultLight, dark: BundledThemes.defaultDark)

    @Test func choosingACustomThemeRemembersItsNameAndVariant() throws {
        let catalog = try catalog(folder(["horizon-dark.yaml": "horizon-dark.yaml", "embers-light.yaml": "embers-light.yaml"]))
        let choice = defaults
            .choosing("custom:embers-light", for: .light, catalog: catalog)
            .choosing("custom:horizon-dark", for: .dark, catalog: catalog)
            .choosing("custom:embers-light", for: .fixed, catalog: catalog)
        #expect(choice == ThemeChoice(
            light: "custom:embers-light", dark: "custom:horizon-dark", fixed: "custom:embers-light",
            lightRemembered: RememberedCustomTheme(name: "Embers Light", appearance: .light),
            darkRemembered: RememberedCustomTheme(name: "Horizon Dark", appearance: .dark),
            fixedRemembered: RememberedCustomTheme(name: "Embers Light", appearance: .light)
        ))
    }

    @Test func choosingABundledThemeForgetsTheCustomOne() throws {
        let catalog = try catalog(folder(["horizon-dark.yaml": "horizon-dark.yaml"]))
        let custom = defaults
            .choosing("custom:horizon-dark", for: .dark, catalog: catalog)
            .choosing("custom:horizon-dark", for: .fixed, catalog: catalog)
        #expect(custom.choosing("github-dark", for: .dark, catalog: catalog).darkRemembered == nil)
        #expect(custom.choosing("github-dark", for: .dark, catalog: catalog).dark == "github-dark")
        #expect(custom.choosing("nord", for: .fixed, catalog: catalog).fixedRemembered == nil)
        #expect(custom.choosing("nord", for: .fixed, catalog: catalog).fixed == "nord")
        #expect(custom.choosing("nord", for: .fixed, catalog: catalog).darkRemembered
            == RememberedCustomTheme(name: "Horizon Dark", appearance: .dark))
    }

    @Test func theRememberedThemeIsStoredAsOneString() {
        let remembered = RememberedCustomTheme(name: "Horizon: Dark", appearance: .dark)
        #expect(remembered.rawValue == "dark:Horizon: Dark")
        #expect(RememberedCustomTheme(rawValue: "dark:Horizon: Dark") == remembered)
        #expect(RememberedCustomTheme(rawValue: "light:Embers Light") == RememberedCustomTheme(name: "Embers Light", appearance: .light))
        #expect(RememberedCustomTheme(rawValue: "dusk:Horizon Dark") == nil)
        #expect(RememberedCustomTheme(rawValue: "Horizon Dark") == nil)
        #expect(RememberedCustomTheme(rawValue: "") == nil)
    }

    // MARK: resolving

    private func notice(_ resolved: ResolvedTheme) -> String? {
        resolved.notice.map { english($0.text) }
    }

    @Test(arguments: [ThemeAppearance.light, .dark])
    func aBundledIDResolvesToItsThemeWithoutANotice(system: ThemeAppearance) {
        let choice = ThemeChoice(light: "github", dark: "github-dark", mode: .fixed, fixed: "nord")
        #expect(choice.resolve(.light, system: system, catalog: .bundled).theme.id == "github")
        #expect(choice.resolve(.dark, system: system, catalog: .bundled).theme.id == "github-dark")
        #expect(choice.resolve(.fixed, system: system, catalog: .bundled).theme.id == "nord")
        #expect(choice.resolve(.fixed, system: system, catalog: .bundled).notice == nil)
    }

    @Test func anUnknownBundledIDFallsBackSilentlyToTheDefaultOfTheSlot() {
        let choice = ThemeChoice(light: "gone", dark: "gone", mode: .fixed, fixed: "gone")
        #expect(choice.resolve(.light, system: .dark, catalog: .bundled) == ResolvedTheme(
            theme: BundledThemes.resolve(id: "catppuccin-latte", appearance: .light), notice: nil
        ))
        #expect(choice.resolve(.dark, system: .light, catalog: .bundled).theme.id == "catppuccin-macchiato")
        #expect(choice.resolve(.fixed, system: .light, catalog: .bundled).theme.id == "catppuccin-latte")
        #expect(choice.resolve(.fixed, system: .dark, catalog: .bundled).theme.id == "catppuccin-macchiato")
        #expect(choice.resolve(.fixed, system: .dark, catalog: .bundled).notice == nil)
    }

    @Test(arguments: [ThemeAppearance.light, .dark])
    func aValidCustomIDResolvesToItsTheme(system: ThemeAppearance) throws {
        let catalog = try catalog(folder(["horizon-dark.yaml": "horizon-dark.yaml", "embers-light.yaml": "embers-light.yaml"]))
        let choice = defaults
            .choosing("custom:embers-light", for: .light, catalog: catalog)
            .choosing("custom:horizon-dark", for: .dark, catalog: catalog)
            .choosing("custom:horizon-dark", for: .fixed, catalog: catalog)
        #expect(choice.resolve(.light, system: system, catalog: catalog).theme.name == "Embers Light")
        #expect(choice.resolve(.dark, system: system, catalog: catalog).theme.name == "Horizon Dark")
        #expect(choice.resolve(.fixed, system: system, catalog: catalog).theme.name == "Horizon Dark")
        #expect(choice.resolve(.fixed, system: system, catalog: catalog).notice == nil)
    }

    @Test func aCustomAndABundledThemeOfOneNameResolveToTheirOwn() throws {
        let catalog = try catalog(folder(["github.yaml": "horizon-dark.yaml"]))
        let choice = defaults
            .choosing("github", for: .light, catalog: catalog)
            .choosing("custom:github", for: .dark, catalog: catalog)
        #expect(choice.activeTheme(system: .light, catalog: catalog).name == "Github Light")
        #expect(choice.activeTheme(system: .dark, catalog: catalog).name == "Horizon Dark")
        #expect(choice.activeTheme(system: .dark, catalog: catalog).id == "custom:github")
    }

    @Test func aSlotsGoneCustomThemeShowsTheDefaultOfItsVariantAndNamesIt() throws {
        let url = try folder(["horizon-dark.yaml": "horizon-dark.yaml", "embers-light.yaml": "embers-light.yaml"])
        let choice = defaults
            .choosing("custom:embers-light", for: .light, catalog: catalog(url))
            .choosing("custom:horizon-dark", for: .dark, catalog: catalog(url))
        try FileManager.default.removeItem(at: url.appendingPathComponent("horizon-dark.yaml"))
        try FileManager.default.removeItem(at: url.appendingPathComponent("embers-light.yaml"))
        let gone = catalog(url)
        // The notice shows at both slots in Match, whichever is in use.
        for system in [ThemeAppearance.light, .dark] {
            let dark = choice.resolve(.dark, system: system, catalog: gone)
            #expect(dark.theme.id == "catppuccin-macchiato")
            #expect(notice(dark) == "Horizon Dark is gone. Using Catppuccin Macchiato.")
            let light = choice.resolve(.light, system: system, catalog: gone)
            #expect(light.theme.id == "catppuccin-latte")
            #expect(notice(light) == "Embers Light is gone. Using Catppuccin Latte.")
        }
        #expect(choice.activeTheme(system: .dark, catalog: gone).id == "catppuccin-macchiato")
        #expect(choice.activeTheme(system: .light, catalog: gone).id == "catppuccin-latte")
    }

    @Test func aRestoredFileShowsAgainWithoutTheNotice() throws {
        let url = try folder(["horizon-dark.yaml": "horizon-dark.yaml"])
        let choice = defaults.choosing("custom:horizon-dark", for: .dark, catalog: catalog(url))
        try FileManager.default.removeItem(at: url.appendingPathComponent("horizon-dark.yaml"))
        #expect(notice(choice.resolve(.dark, system: .dark, catalog: catalog(url))) != nil)
        try add("horizon-dark.yaml", as: "horizon-dark.yaml", to: url)
        let back = choice.resolve(.dark, system: .dark, catalog: catalog(url))
        #expect(back.theme.id == "custom:horizon-dark")
        #expect(back.theme.name == "Horizon Dark")
        #expect(back.notice == nil)
    }

    @Test func aBrokenCustomThemeShowsTheDefaultAndSaysItCantBeRead() throws {
        let url = try folder(["embers-light.yaml": "embers-light.yaml"])
        let choice = defaults.choosing("custom:embers-light", for: .light, catalog: catalog(url))
        try FileManager.default.removeItem(at: url.appendingPathComponent("embers-light.yaml"))
        try add("missing-base0D.yaml", as: "embers-light.yaml", to: url)
        let resolved = choice.resolve(.light, system: .light, catalog: catalog(url))
        #expect(resolved.theme.id == "catppuccin-latte")
        #expect(notice(resolved) == "Embers Light can’t be read. Using Catppuccin Latte.")
    }

    @Test func withoutARememberedNameTheNoticeNamesTheFileOrTheStem() throws {
        let url = try folder(["ocean.yaml": "not-yaml.yaml"])
        // As if stored before the name was: a bare id.
        let choice = ThemeChoice(light: "custom:ocean", dark: "custom:horizon-dark")
        #expect(notice(choice.resolve(.light, system: .light, catalog: catalog(url)))
            == "ocean.yaml can’t be read. Using Catppuccin Latte.")
        #expect(notice(choice.resolve(.dark, system: .dark, catalog: catalog(url)))
            == "horizon-dark is gone. Using Catppuccin Macchiato.")
    }

    @Test func aFileThatOnlyLostItsStemToAnotherDoesNotCountAsBroken() throws {
        // `ocean.YML` wins the stem byte-wise and is broken; `ocean.yaml` reads but only names
        // the winner, and its error row sorts first by file name.
        let url = try folder(["ocean.YML": "missing-name.yaml", "ocean.yaml": "horizon-dark.yaml"])
        let choice = ThemeChoice(light: "github", dark: "custom:ocean")
        #expect(catalog(url).brokenThemes.map(\.fileName) == ["ocean.yaml", "ocean.YML"])
        #expect(notice(choice.resolve(.dark, system: .dark, catalog: catalog(url)))
            == "ocean.YML can’t be read. Using Catppuccin Macchiato.")
    }

    @Test(arguments: [ThemeAppearance.light, .dark])
    func inFixedModeAGoneCustomThemeFallsBackToTheDefaultOfItsOwnVariant(system: ThemeAppearance) throws {
        let url = try folder(["horizon-dark.yaml": "horizon-dark.yaml", "embers-light.yaml": "embers-light.yaml"])
        let dark = ThemeChoice(light: "github", dark: "github-dark", mode: .fixed)
            .choosing("custom:horizon-dark", for: .fixed, catalog: catalog(url))
        let light = ThemeChoice(light: "github", dark: "github-dark", mode: .fixed)
            .choosing("custom:embers-light", for: .fixed, catalog: catalog(url))
        try FileManager.default.removeItem(at: url.appendingPathComponent("horizon-dark.yaml"))
        try FileManager.default.removeItem(at: url.appendingPathComponent("embers-light.yaml"))
        let gone = catalog(url)
        #expect(dark.activeTheme(system: system, catalog: gone).id == "catppuccin-macchiato")
        #expect(dark.activeAppearance(system: system, catalog: gone) == .dark)
        #expect(notice(dark.resolve(.fixed, system: system, catalog: gone)) == "Horizon Dark is gone. Using Catppuccin Macchiato.")
        #expect(light.activeTheme(system: system, catalog: gone).id == "catppuccin-latte")
        #expect(notice(light.resolve(.fixed, system: system, catalog: gone)) == "Embers Light is gone. Using Catppuccin Latte.")
    }

    @Test(arguments: [ThemeAppearance.light, .dark])
    func inFixedModeWithoutARememberedVariantTheSystemDecides(system: ThemeAppearance) {
        let choice = ThemeChoice(light: "github", dark: "github-dark", mode: .fixed, fixed: "custom:horizon-dark")
        let resolved = choice.resolve(.fixed, system: system, catalog: .bundled)
        #expect(resolved.theme.id == (system == .light ? "catppuccin-latte" : "catppuccin-macchiato"))
        #expect(notice(resolved) == (system == .light
            ? "horizon-dark is gone. Using Catppuccin Latte."
            : "horizon-dark is gone. Using Catppuccin Macchiato."))
    }

    @Test func resolvingNeverRewritesTheChoice() throws {
        let url = try folder(["horizon-dark.yaml": "horizon-dark.yaml"])
        let choice = defaults.choosing("custom:horizon-dark", for: .dark, catalog: catalog(url))
        let stored = choice
        try FileManager.default.removeItem(at: url.appendingPathComponent("horizon-dark.yaml"))
        _ = choice.resolve(.dark, system: .dark, catalog: catalog(url))
        _ = choice.activeTheme(system: .dark, catalog: catalog(url))
        #expect(choice == stored)
        #expect(choice.dark == "custom:horizon-dark")
        #expect(choice.darkRemembered == RememberedCustomTheme(name: "Horizon Dark", appearance: .dark))
    }

    // MARK: switching

    @Test func switchingToOneSchemeCarriesAValidCustomThemeInUse() throws {
        let catalog = try catalog(folder(["horizon-dark.yaml": "horizon-dark.yaml"]))
        let choice = defaults.choosing("custom:horizon-dark", for: .dark, catalog: catalog)
        let fixed = choice.switching(to: .fixed, system: .dark, catalog: catalog)
        #expect(fixed.mode == .fixed)
        #expect(fixed.fixed == "custom:horizon-dark")
        #expect(fixed.fixedRemembered == RememberedCustomTheme(name: "Horizon Dark", appearance: .dark))
        #expect(fixed.activeTheme(system: .light, catalog: catalog).name == "Horizon Dark")
    }

    @Test func switchingToOneSchemeWhileTheCustomThemeIsGoneKeepsItsIDAndNotice() throws {
        let url = try folder(["horizon-dark.yaml": "horizon-dark.yaml"])
        let choice = defaults.choosing("custom:horizon-dark", for: .dark, catalog: catalog(url))
        try FileManager.default.removeItem(at: url.appendingPathComponent("horizon-dark.yaml"))
        let fixed = choice.switching(to: .fixed, system: .dark, catalog: catalog(url))
        #expect(fixed.fixed == "custom:horizon-dark")
        #expect(fixed.fixedRemembered == RememberedCustomTheme(name: "Horizon Dark", appearance: .dark))
        // Still dark when the system turns light: the variant came along.
        let resolved = fixed.resolve(.fixed, system: .light, catalog: catalog(url))
        #expect(resolved.theme.id == "catppuccin-macchiato")
        #expect(notice(resolved) == "Horizon Dark is gone. Using Catppuccin Macchiato.")
    }

    @Test func switchingToOneSchemeFromABundledSlotForgetsAFormerCustomFixedTheme() throws {
        let catalog = try catalog(folder(["embers-light.yaml": "embers-light.yaml"]))
        let choice = ThemeChoice(light: "github", dark: "github-dark")
            .choosing("custom:embers-light", for: .fixed, catalog: catalog)
        let fixed = choice.switching(to: .fixed, system: .light, catalog: catalog)
        #expect(fixed == ThemeChoice(light: "github", dark: "github-dark", mode: .fixed, fixed: "github"))
    }

    // MARK: lazy derivation

    /// The launch resolves one theme to color the popover; through a catalog it still derives
    /// only that one, and a custom theme or its fallback no more than the default.
    @Test func resolvingThroughACatalogDerivesOnlyTheThemeItNeeds() throws {
        let shelf = ThemeShelf(folder: FixtureThemes.folder)
        let url = try folder(["horizon-dark.yaml": "horizon-dark.yaml"])
        let catalog = ThemeCatalog(shelf: shelf, custom: CustomThemeFolder.entries(in: url))
        let choice = ThemeChoice(light: "github", dark: "custom:horizon-dark", mode: .system, fixed: "nord")
        #expect(choice.activeTheme(system: .dark, catalog: catalog).name == "Horizon Dark")
        #expect(shelf.derivedIDs.isEmpty)
        #expect(choice.activeTheme(system: .light, catalog: catalog).id == "github")
        #expect(shelf.derivedIDs == ["github"])
        let gone = ThemeCatalog(shelf: shelf, custom: [])
        #expect(choice.activeTheme(system: .dark, catalog: gone).id == "catppuccin-macchiato")
        #expect(shelf.derivedIDs == ["github", "catppuccin-macchiato"])
    }

    /// A large custom folder must not slow the launch: reading it only parses, so it still
    /// tells valid files from error rows, and a theme is derived when a choice first needs it.
    @Test func readingACustomFolderDerivesNothingAndResolvingDerivesOnlyTheChosenTheme() throws {
        let url = try folder([
            "horizon-dark.yaml": "horizon-dark.yaml",
            "embers-light.yaml": "embers-light.yaml",
            "espresso.yaml": "espresso.yaml",
            "ocean.yaml": "missing-name.yaml",
        ])
        let entries = CustomThemeFolder.entries(in: url)
        let catalog = ThemeCatalog(shelf: ThemeShelf(folder: FixtureThemes.folder), custom: entries)
        #expect(catalog.customThemes.count == 3)
        #expect(catalog.brokenThemes.map(\.fileName) == ["ocean.yaml"])
        #expect(catalog.customThemes.filter(\.isDerived).isEmpty)

        let choice = defaults.choosing("custom:horizon-dark", for: .dark, catalog: catalog)
        #expect(catalog.customThemes.filter(\.isDerived).isEmpty)
        let theme = choice.activeTheme(system: .dark, catalog: catalog)
        #expect(catalog.customThemes.filter(\.isDerived).map(\.id) == ["custom:horizon-dark"])

        let text = try String(contentsOf: Self.fixtures.appending(path: "horizon-dark.yaml"), encoding: .utf8)
        #expect(theme == deriveTheme(id: "custom:horizon-dark", scheme: try Scheme.parse(text), contrast: .regular))
        #expect(choice.activeTheme(system: .dark, catalog: catalog) == theme)
    }

    /// The derived theme is a cache: two reads of the same file are equal whether or not one
    /// was derived, and a changed file is a change even if neither was.
    @Test func customEntriesCompareByTheirFileNotByTheCache() throws {
        let url = try folder(["horizon-dark.yaml": "horizon-dark.yaml"])
        let first = CustomThemeFolder.entries(in: url)
        let second = CustomThemeFolder.entries(in: url)
        _ = ThemeCatalog(custom: first).theme("custom:horizon-dark")
        #expect(first == second)

        let file = url.appending(path: "horizon-dark.yaml")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(##"base00: "#1C1E26""##))
        try text.replacingOccurrences(of: ##"base00: "#1C1E26""##, with: ##"base00: "#123456""##)
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(CustomThemeFolder.entries(in: url) != second)
    }
}
