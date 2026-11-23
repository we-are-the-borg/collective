import Testing
@testable import CollectiveKit

/// The family table, ported from Unimatrix Zero's `theme/family.rs` (commit 43f1307). Unimatrix
/// checks it against its bundled themes; here they are the fixture schemes, all 38 of them, which
/// the app bundles too.
@Suite struct ThemeFamilyTests {
    private var tableIDs: [String] {
        ThemeFamily.all.flatMap { $0.schemes.map(\.id) }
    }

    @Test func coversEveryFixtureThemeExactlyOnce() {
        let table = tableIDs
        for id in FixtureThemes.ids {
            let count = table.filter { $0 == id }.count
            #expect(count == 1, "theme `\(id)` needs exactly one entry in ThemeFamily.all")
        }
        let fixtures = Set(FixtureThemes.ids)
        for id in table {
            #expect(fixtures.contains(id), "ThemeFamily.all lists `\(id)`, which is no fixture scheme")
        }
    }

    @Test func coversEveryBundledTheme() {
        for theme in BundledThemes.all {
            #expect(ThemeFamily.naming(theme.id) != nil, "\(theme.id)")
        }
    }

    @Test func noIDAppearsTwice() {
        var seen = Set<String>()
        for id in tableIDs {
            #expect(seen.insert(id).inserted, "`\(id)` appears twice in ThemeFamily.all")
        }
    }

    @Test func namesFamilyAndShortName() {
        func check(_ id: String, _ family: String, _ shortName: String) {
            let expected = ThemeNaming(family: family, shortName: shortName, contrast: .regular)
            #expect(ThemeFamily.naming(id) == expected, "\(id)")
        }
        check("catppuccin-frappe", "Catppuccin", "Frappé")
        check("github", "GitHub", "Light")
        check("tokyo-night-moon", "Tokyo Night", "Moon")
        check("nord", "Nord", "Nord")
        #expect(ThemeFamily.naming("no-such-theme") == nil)
    }

    /// Every bundled theme, as the app names it: family and short name from the table, the
    /// display name both joined, or only the family where the short name is the family.
    private static let names: [(id: String, family: String, shortName: String, displayName: String)] = [
        ("ayu-dark", "Ayu", "Dark", "Ayu Dark"),
        ("ayu-light", "Ayu", "Light", "Ayu Light"),
        ("ayu-mirage", "Ayu", "Mirage", "Ayu Mirage"),
        ("catppuccin-frappe", "Catppuccin", "Frappé", "Catppuccin Frappé"),
        ("catppuccin-latte", "Catppuccin", "Latte", "Catppuccin Latte"),
        ("catppuccin-macchiato", "Catppuccin", "Macchiato", "Catppuccin Macchiato"),
        ("catppuccin-mocha", "Catppuccin", "Mocha", "Catppuccin Mocha"),
        ("dracula", "Dracula", "Dracula", "Dracula"),
        ("everforest-dark-medium", "Everforest", "Dark Medium", "Everforest Dark Medium"),
        ("everforest-light-medium", "Everforest", "Light Medium", "Everforest Light Medium"),
        ("github", "GitHub", "Light", "GitHub Light"),
        ("github-dark", "GitHub", "Dark", "GitHub Dark"),
        ("github-dark-dimmed", "GitHub", "Dark Dimmed", "GitHub Dark Dimmed"),
        ("github-dark-high-contrast", "GitHub", "Dark High Contrast", "GitHub Dark High Contrast"),
        ("github-light-high-contrast", "GitHub", "Light High Contrast", "GitHub Light High Contrast"),
        ("gruvbox-dark", "Gruvbox", "Dark", "Gruvbox Dark"),
        ("gruvbox-light", "Gruvbox", "Light", "Gruvbox Light"),
        ("kanagawa", "Kanagawa", "Wave", "Kanagawa Wave"),
        ("kanagawa-dragon", "Kanagawa", "Dragon", "Kanagawa Dragon"),
        ("material", "Material", "Material", "Material"),
        ("material-darker", "Material", "Darker", "Material Darker"),
        ("material-lighter", "Material", "Lighter", "Material Lighter"),
        ("material-palenight", "Material", "Palenight", "Material Palenight"),
        ("nord", "Nord", "Nord", "Nord"),
        ("one-dark", "One", "Dark", "One Dark"),
        ("one-light", "One", "Light", "One Light"),
        ("rose-pine", "Rosé Pine", "Rosé Pine", "Rosé Pine"),
        ("rose-pine-dawn", "Rosé Pine", "Dawn", "Rosé Pine Dawn"),
        ("rose-pine-moon", "Rosé Pine", "Moon", "Rosé Pine Moon"),
        ("solarized-dark", "Solarized", "Dark", "Solarized Dark"),
        ("solarized-light", "Solarized", "Light", "Solarized Light"),
        ("tokyo-night-dark", "Tokyo Night", "Dark", "Tokyo Night Dark"),
        ("tokyo-night-light", "Tokyo Night", "Light", "Tokyo Night Light"),
        ("tokyo-night-moon", "Tokyo Night", "Moon", "Tokyo Night Moon"),
        ("tokyo-night-storm", "Tokyo Night", "Storm", "Tokyo Night Storm"),
        ("tomorrow", "Tomorrow", "Tomorrow", "Tomorrow"),
        ("tomorrow-night", "Tomorrow", "Night", "Tomorrow Night"),
        ("tomorrow-night-eighties", "Tomorrow", "Night Eighties", "Tomorrow Night Eighties"),
    ]

    @Test func namesEveryBundledThemeFromTheTableNotItsFile() {
        #expect(BundledThemes.all.map(\.id) == Self.names.map(\.id))
        for (theme, name) in zip(BundledThemes.all, Self.names) {
            #expect(theme.family == name.family, "\(theme.id)")
            #expect(theme.shortName == name.shortName, "\(theme.id)")
            #expect(theme.displayName == name.displayName, "\(theme.id)")
        }
    }

    /// A theme the table does not know, such as a custom one, goes by the name in its file.
    @Test func aThemeWithoutAnEntryGoesByItsFilesName() throws {
        var theme = try #require(BundledThemes.all.first)
        theme.id = "no-such-theme"
        theme.name = "Ocean dark, hard"
        #expect(theme.family == nil)
        #expect(theme.shortName == nil)
        #expect(theme.displayName == "Ocean dark, hard")
    }

    @Test func flagsExactlyTheTwoGitHubHighContrastSchemes() {
        let flagged = tableIDs.filter { ThemeFamily.naming($0)?.contrast == .high }.sorted()
        #expect(flagged == ["github-dark-high-contrast", "github-light-high-contrast"])
    }
}
