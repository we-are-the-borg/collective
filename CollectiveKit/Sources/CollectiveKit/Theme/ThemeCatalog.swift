import Foundation

/// Every theme a choice can name: the bundled ones and what the user's folder holds right now.
/// A value, so a folder change hands out a new catalog and whatever resolved against the old one
/// stays as it was. The bundled themes stay derived lazily: looking up one does not derive the
/// rest.
public struct ThemeCatalog: Sendable, Equatable {
    /// The folder as `CustomThemeFolder.entries(in:)` read it, in its order.
    public let custom: [CustomThemeEntry]
    private let shelf: ThemeShelf

    /// The bundled themes alone, until a folder has been read.
    public static let bundled = ThemeCatalog(custom: [])

    public init(custom: [CustomThemeEntry]) {
        self.init(shelf: BundledThemes.shelf, custom: custom)
    }

    /// With a shelf of its own, so a test can see which bundled themes a lookup derived.
    init(shelf: ThemeShelf, custom: [CustomThemeEntry]) {
        self.shelf = shelf
        self.custom = custom
    }

    /// Every bundled theme, sorted by id; derives them all, so only for a list that shows them.
    var bundledThemes: [Theme] {
        shelf.all
    }

    /// The custom files that read as themes, by name.
    public var customThemes: [CustomTheme] {
        custom.compactMap { if case .valid(let theme) = $0 { theme } else { nil } }
    }

    /// The custom files that do not, by file name; shown as error rows.
    public var brokenThemes: [BrokenCustomTheme] {
        custom.compactMap { if case .broken(let file) = $0 { file } else { nil } }
    }

    /// The theme `id`, `nil` if nothing in the catalog has it. A `custom:` id only ever names a
    /// file, any other id only a bundled scheme, so a custom `github` and the bundled one both
    /// stay reachable.
    public func theme(_ id: String) -> Theme? {
        if CustomThemeID.isCustom(id) {
            return customTheme(id)?.theme
        }
        return shelf.theme(id)
    }

    /// The valid custom theme `id`.
    public func customTheme(_ id: String) -> CustomTheme? {
        customThemes.first { $0.id == id }
    }

    /// The file that gives `id` its stem but does not read; not one that only lost to another
    /// file of the same stem, since that one never had the id.
    func brokenTheme(_ id: String) -> BrokenCustomTheme? {
        guard let stem = CustomThemeID.stem(id) else { return nil }
        return brokenThemes.first { file in
            guard file.stem == stem else { return false }
            if case .duplicateStem = file.problem { return false }
            return true
        }
    }

    /// The default theme for `appearance`. Stops if it is not bundled, which
    /// `holdsEveryShippedSchemeOnceSortedByID` rules out.
    func defaultTheme(for appearance: ThemeAppearance) -> Theme {
        let id = BundledThemes.defaultID(for: appearance)
        guard let theme = shelf.theme(id) else {
            preconditionFailure("default theme Schemes/\(id).yaml is not bundled")
        }
        return theme
    }

    public static func == (lhs: ThemeCatalog, rhs: ThemeCatalog) -> Bool {
        lhs.shelf === rhs.shelf && lhs.custom == rhs.custom
    }
}

/// The `custom:` prefix that keeps custom ids apart from bundled ones.
enum CustomThemeID {
    static let prefix = "custom:"

    static func isCustom(_ id: String) -> Bool {
        id.hasPrefix(prefix)
    }

    /// The file stem a custom id names, `nil` for a bundled id.
    static func stem(_ id: String) -> String? {
        isCustom(id) ? String(id.dropFirst(prefix.count)) : nil
    }
}
