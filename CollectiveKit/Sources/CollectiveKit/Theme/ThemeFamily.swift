import Foundation

// Which family a scheme belongs to and what it is called inside it, a port of Unimatrix Zero's
// `theme/family.rs` (commit 43f1307), so a picker can group "Tokyo Night" and show "Moon"
// instead of "Tokyo Night Moon". The scheme files stay as imported, so their own `name` field
// cannot serve: it has no family boundary ("Tokyo Night Moon"), drops accents ("Catppuccin
// Frappe") and has typos ("Github").
//
// The table stays a copy of Unimatrix's, entry for entry, so the reference file can check it;
// the app bundles the same schemes, so every bundled theme has an entry.

/// A group of related schemes. The names are brand and scheme names, data like the scheme files,
/// not translated UI text.
struct ThemeFamily: Sendable {
    var name: String
    /// Where nothing remains after the family name, the short name is the family name (Dracula,
    /// Nord, Tomorrow, Material, Rosé Pine). The contrast is here because the scheme files carry
    /// no flag for it, and a name ("… High Contrast") is no contract.
    var schemes: [(id: String, shortName: String, contrast: ThemeContrast)]

    /// Every scheme, by family in display order. A scheme file added to the schemes needs an
    /// entry here; `coversEveryFixtureThemeExactlyOnce` fails otherwise.
    static let all: [ThemeFamily] = [
        ThemeFamily(name: "Catppuccin", schemes: [
            ("catppuccin-frappe", "Frappé", .regular),
            ("catppuccin-latte", "Latte", .regular),
            ("catppuccin-macchiato", "Macchiato", .regular),
            ("catppuccin-mocha", "Mocha", .regular),
        ]),
        ThemeFamily(name: "GitHub", schemes: [
            ("github", "Light", .regular),
            ("github-dark", "Dark", .regular),
            ("github-dark-dimmed", "Dark Dimmed", .regular),
            ("github-dark-high-contrast", "Dark High Contrast", .high),
            ("github-light-high-contrast", "Light High Contrast", .high),
        ]),
        ThemeFamily(name: "Dracula", schemes: [("dracula", "Dracula", .regular)]),
        ThemeFamily(name: "Gruvbox", schemes: [
            ("gruvbox-dark", "Dark", .regular),
            ("gruvbox-light", "Light", .regular),
        ]),
        ThemeFamily(name: "Tokyo Night", schemes: [
            ("tokyo-night-dark", "Dark", .regular),
            ("tokyo-night-light", "Light", .regular),
            ("tokyo-night-moon", "Moon", .regular),
            ("tokyo-night-storm", "Storm", .regular),
        ]),
        ThemeFamily(name: "One", schemes: [
            ("one-dark", "Dark", .regular),
            ("one-light", "Light", .regular),
        ]),
        ThemeFamily(name: "Ayu", schemes: [
            ("ayu-dark", "Dark", .regular),
            ("ayu-light", "Light", .regular),
            ("ayu-mirage", "Mirage", .regular),
        ]),
        ThemeFamily(name: "Kanagawa", schemes: [
            ("kanagawa", "Wave", .regular),
            ("kanagawa-dragon", "Dragon", .regular),
        ]),
        ThemeFamily(name: "Tomorrow", schemes: [
            ("tomorrow", "Tomorrow", .regular),
            ("tomorrow-night", "Night", .regular),
            ("tomorrow-night-eighties", "Night Eighties", .regular),
        ]),
        ThemeFamily(name: "Material", schemes: [
            ("material", "Material", .regular),
            ("material-darker", "Darker", .regular),
            ("material-lighter", "Lighter", .regular),
            ("material-palenight", "Palenight", .regular),
        ]),
        ThemeFamily(name: "Solarized", schemes: [
            ("solarized-dark", "Dark", .regular),
            ("solarized-light", "Light", .regular),
        ]),
        ThemeFamily(name: "Nord", schemes: [("nord", "Nord", .regular)]),
        ThemeFamily(name: "Rosé Pine", schemes: [
            ("rose-pine", "Rosé Pine", .regular),
            ("rose-pine-moon", "Moon", .regular),
            ("rose-pine-dawn", "Dawn", .regular),
        ]),
        ThemeFamily(name: "Everforest", schemes: [
            ("everforest-dark-medium", "Dark Medium", .regular),
            ("everforest-light-medium", "Light Medium", .regular),
        ]),
    ]

    /// The rank of every scheme in the order lists show them: families alphabetically as the
    /// user's language sorts them, ignoring accents, so "Rosé Pine" sits between "One" and
    /// "Solarized"; within a family the table's order, which is Unimatrix's.
    static let displayRank: [String: Int] = {
        let families = all.sorted {
            $0.name.compare($1.name, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == .orderedAscending
        }
        let ids = families.flatMap { $0.schemes.map(\.id) }
        return Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
    }()

    /// Family, short name and contrast of the scheme `id`; `nil` for an id without an entry, such
    /// as a custom scheme.
    static func naming(_ id: String) -> ThemeNaming? {
        for family in all {
            if let scheme = family.schemes.first(where: { $0.id == id }) {
                return ThemeNaming(
                    family: family.name,
                    shortName: scheme.shortName,
                    contrast: scheme.contrast
                )
            }
        }
        return nil
    }
}

/// Family, short name and contrast of one scheme, as `ThemeFamily.naming` returns them.
struct ThemeNaming: Sendable, Hashable {
    var family: String
    var shortName: String
    var contrast: ThemeContrast
}

extension Theme {
    /// The family a list groups the theme under, e.g. "Tokyo Night"; `nil` for a theme the family
    /// table does not know, such as a custom one.
    public var family: String? {
        ThemeFamily.naming(id)?.family
    }

    /// The name within the family, e.g. "Moon"; the family name itself where nothing remains
    /// after it (Dracula). `nil` without an entry in the family table.
    public var shortName: String? {
        ThemeFamily.naming(id)?.shortName
    }

    /// What the app calls the theme: family and short name, "Tokyo Night Moon", or only the
    /// family where the short name is the family, "Dracula" rather than "Dracula Dracula". A theme
    /// the table does not know goes by the name in its file.
    public var displayName: String {
        guard let naming = ThemeFamily.naming(id) else { return name }
        return naming.shortName == naming.family ? naming.family : "\(naming.family) \(naming.shortName)"
    }
}
