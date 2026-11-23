import Foundation

/// The three places a `ThemeChoice` holds a scheme: one per macOS appearance, and the one scheme
/// of fixed mode.
public enum ThemeSlot: String, Sendable, Hashable, CaseIterable {
    case light
    case dark
    case fixed
}

/// What a slot keeps of a chosen custom theme besides its id: the file can vanish or break, and
/// the notice still has to name it, the fixed slot to know which default stands in. The
/// app stores `rawValue` next to the slot's id.
public struct RememberedCustomTheme: Sendable, Hashable, RawRepresentable {
    /// The theme's `name` as its file wrote it.
    public var name: String
    public var appearance: ThemeAppearance

    public init(name: String, appearance: ThemeAppearance) {
        self.name = name
        self.appearance = appearance
    }

    init(_ theme: CustomTheme) {
        self.init(name: theme.name, appearance: theme.appearance)
    }

    /// `<variant>:<name>`, e.g. `dark:Horizon Dark`: one string, so one defaults key per slot.
    /// The variant comes first because a name may hold a colon.
    public var rawValue: String {
        "\(appearance == .light ? "light" : "dark"):\(name)"
    }

    public init?(rawValue: String) {
        guard let colon = rawValue.firstIndex(of: ":") else { return nil }
        let appearance: ThemeAppearance
        switch rawValue[..<colon] {
        case "light": appearance = .light
        case "dark": appearance = .dark
        default: return nil
        }
        self.init(name: String(rawValue[rawValue.index(after: colon)...]), appearance: appearance)
    }
}

/// A slot resolved against a catalog: the theme it shows and, while a chosen custom theme is
/// missing, why it shows a default instead.
public struct ResolvedTheme: Sendable, Hashable {
    public var theme: Theme
    public var notice: ThemeFallbackNotice?
}

/// The line under a slot whose custom theme is gone or broken. It has no close button: it
/// lasts while the stored choice cannot be shown, so it carries no state of its own.
public struct ThemeFallbackNotice: Sendable, Hashable {
    public enum Reason: Sendable, Hashable {
        /// No file has the stem any more.
        case gone
        /// The file is there but does not read as a theme.
        case unreadable
    }

    public var reason: Reason
    /// The remembered name, else the file name or the stem.
    public var name: String
    /// The display name of the default shown instead, e.g. "Catppuccin Macchiato".
    public var fallbackName: String

    /// `Horizon Dark is gone. Using Catppuccin Macchiato.`
    public var text: LocalizedStringResource {
        switch reason {
        case .gone: .kit("%@ is gone. Using %@.", defaultValue: "\(name) is gone. Using \(fallbackName).")
        case .unreadable: .kit("%@ can’t be read. Using %@.", defaultValue: "\(name) can’t be read. Using \(fallbackName).")
        }
    }
}

extension ThemeChoice {
    /// The id stored in `slot`.
    public func id(of slot: ThemeSlot) -> String {
        switch slot {
        case .light: light
        case .dark: dark
        case .fixed: fixed
        }
    }

    /// What `slot` remembers of its custom theme.
    public func remembered(_ slot: ThemeSlot) -> RememberedCustomTheme? {
        switch slot {
        case .light: lightRemembered
        case .dark: darkRemembered
        case .fixed: fixedRemembered
        }
    }

    /// The choice after the user picks `id` for `slot`: a custom theme is remembered by its name
    /// and variant as the catalog reads it now, a bundled one clears what the slot remembered.
    /// The only way a selection should enter the choice, so the remembered record never belongs
    /// to another id.
    public func choosing(_ id: String, for slot: ThemeSlot, catalog: ThemeCatalog) -> ThemeChoice {
        var next = self
        let remembered = catalog.customTheme(id).map(RememberedCustomTheme.init)
        switch slot {
        case .light: next.light = id; next.lightRemembered = remembered
        case .dark: next.dark = id; next.darkRemembered = remembered
        case .fixed: next.fixed = id; next.fixedRemembered = remembered
        }
        return next
    }

    /// The choice with each slot's record brought up to date with `catalog`: a chosen custom
    /// theme that reads, but whose file now writes another name or variant, is remembered as it
    /// reads now, so a later notice names what the user last saw. A slot whose file is gone
    /// or broken keeps its record; that is what the record is for. For the app to apply when a
    /// new catalog arrives.
    public func refreshingRemembered(catalog: ThemeCatalog) -> ThemeChoice {
        var next = self
        for slot in ThemeSlot.allCases {
            guard let theme = catalog.customTheme(id(of: slot)) else { continue }
            let current = RememberedCustomTheme(theme)
            guard remembered(slot) != current else { continue }
            switch slot {
            case .light: next.lightRemembered = current
            case .dark: next.darkRemembered = current
            case .fixed: next.fixedRemembered = current
            }
        }
        return next
    }

    /// What `slot` shows against `catalog` while macOS shows `system`, and the notice if its
    /// custom theme is missing. A missing custom theme falls back to the default of its own
    /// variant: a slot's variant, or for the fixed slot the one remembered, so a vanished
    /// dark theme in fixed mode stays dark in light mode. An unknown bundled id, say from an old
    /// setting, falls back silently to the default of the slot's appearance. Never rewrites the
    /// choice: once the file reads again, the same choice shows it again.
    public func resolve(_ slot: ThemeSlot, system: ThemeAppearance, catalog: ThemeCatalog) -> ResolvedTheme {
        let id = id(of: slot)
        if let theme = catalog.theme(id) {
            return ResolvedTheme(theme: theme, notice: nil)
        }
        let remembered = remembered(slot)
        let variant: ThemeAppearance = switch slot {
        case .light: .light
        case .dark: .dark
        case .fixed: remembered?.appearance ?? system
        }
        let fallback = catalog.defaultTheme(for: variant)
        guard let stem = CustomThemeID.stem(id) else {
            return ResolvedTheme(theme: fallback, notice: nil)
        }
        let notice = if let broken = catalog.brokenTheme(id) {
            ThemeFallbackNotice(reason: .unreadable, name: remembered?.name ?? broken.fileName, fallbackName: fallback.displayName)
        } else {
            ThemeFallbackNotice(reason: .gone, name: remembered?.name ?? stem, fallbackName: fallback.displayName)
        }
        return ResolvedTheme(theme: fallback, notice: notice)
    }
}
