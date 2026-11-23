import AppKit
import CollectiveKit
import CollectiveUI
import Observation
import SwiftUI

/// Where the chosen themes live in `UserDefaults`: a theme id of the `ThemeCatalog` (bundled or
/// `custom:`) per appearance, whether the system picks one of them, and the one scheme used
/// otherwise, each with what it remembers of a custom theme. The Appearance
/// pane writes them (`SettingsWindowContent`), `ThemeCatalogStore` refreshes what is
/// remembered; every window and the popover read them through `themedFromDefaults()`.
enum ThemeDefaults {
    static let lightKey = "themeLight"
    static let darkKey = "themeDark"
    /// `ThemeMode`'s raw value; an unknown one matches the system.
    static let modeKey = "themeMode"
    static let fixedKey = "themeFixed"
    /// `RememberedCustomTheme`'s raw value per slot; absent for a bundled id.
    static let lightRememberedKey = "themeLightRemembered"
    static let darkRememberedKey = "themeDarkRemembered"
    static let fixedRememberedKey = "themeFixedRemembered"

    /// For AppKit, outside the views' `@AppStorage`; the same keys and defaults.
    static func choice(in defaults: UserDefaults = .standard) -> ThemeChoice {
        ThemeChoice(
            light: defaults.string(forKey: lightKey) ?? BundledThemes.defaultLight,
            dark: defaults.string(forKey: darkKey) ?? BundledThemes.defaultDark,
            mode: defaults.string(forKey: modeKey).flatMap(ThemeMode.init(rawValue:)) ?? .system,
            fixed: defaults.string(forKey: fixedKey) ?? BundledThemes.defaultLight,
            lightRemembered: defaults.string(forKey: lightRememberedKey).flatMap(RememberedCustomTheme.init(rawValue:)),
            darkRemembered: defaults.string(forKey: darkRememberedKey).flatMap(RememberedCustomTheme.init(rawValue:)),
            fixedRemembered: defaults.string(forKey: fixedRememberedKey).flatMap(RememberedCustomTheme.init(rawValue:))
        )
    }

    /// Writes what `choice` remembers, removing a slot's key where it remembers nothing.
    static func storeRemembered(of choice: ThemeChoice, in defaults: UserDefaults = .standard) {
        for (key, remembered) in [
            (lightRememberedKey, choice.lightRemembered),
            (darkRememberedKey, choice.darkRemembered),
            (fixedRememberedKey, choice.fixedRemembered),
        ] {
            defaults.set(remembered?.rawValue, forKey: key)
        }
    }

    /// The AppKit variant of the active scheme, for windows and dialogs the system draws itself.
    @MainActor
    static func activeNSAppearance() -> NSAppearance? {
        let active = choice().activeAppearance(system: SystemAppearance.shared.value, catalog: ThemeCatalogStore.shared.catalog)
        return NSAppearance(named: active == .dark ? .darkAqua : .aqua)
    }
}

/// The appearance macOS shows. The windows and the popover are forced to the active scheme's
/// variant, so their own appearance no longer tells; the application's still does, as long as
/// nobody sets `NSApp.appearance`.
@MainActor @Observable
final class SystemAppearance {
    static let shared = SystemAppearance()

    private(set) var value: ThemeAppearance
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        value = Self.current
        observation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                // Reported more often than it changes; only a change re-renders the windows.
                guard let self, self.value != Self.current else { return }
                self.value = Self.current
            }
        }
    }

    private static var current: ThemeAppearance {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

extension View {
    /// The themes from `ThemeDefaults` for this window's content, resolved against the live
    /// catalog. `@AppStorage` and `ThemeCatalogStore` are observed, so a new choice and a custom
    /// file that changes or vanishes show without a restart; an id the catalog lacks falls back
    /// to a bundled default (`ThemeChoice.resolve`). The window takes the active scheme's variant, so what
    /// the system draws in it (menus, dialogs, sheets, scroll bars, traffic lights) matches a
    /// dark scheme in light mode too.
    func themedFromDefaults() -> some View {
        modifier(ThemeFromDefaults())
    }
}

private struct ThemeFromDefaults: ViewModifier {
    @AppStorage(ThemeDefaults.lightKey) private var light = BundledThemes.defaultLight
    @AppStorage(ThemeDefaults.darkKey) private var dark = BundledThemes.defaultDark
    @AppStorage(ThemeDefaults.modeKey) private var mode = ThemeMode.system
    @AppStorage(ThemeDefaults.fixedKey) private var fixed = BundledThemes.defaultLight
    @AppStorage(ThemeDefaults.lightRememberedKey) private var lightRemembered: RememberedCustomTheme?
    @AppStorage(ThemeDefaults.darkRememberedKey) private var darkRemembered: RememberedCustomTheme?
    @AppStorage(ThemeDefaults.fixedRememberedKey) private var fixedRemembered: RememberedCustomTheme?
    private let system = SystemAppearance.shared
    private let themes = ThemeCatalogStore.shared

    func body(content: Content) -> some View {
        let choice = ThemeChoice(
            light: light, dark: dark, mode: mode, fixed: fixed,
            lightRemembered: lightRemembered, darkRemembered: darkRemembered, fixedRemembered: fixedRemembered
        )
        content
            .environment(\.themeChoice, choice)
            .environment(\.themeCatalog, themes.catalog)
            .environment(\.systemAppearance, system.value)
            .preferredColorScheme(choice.activeAppearance(system: system.value, catalog: themes.catalog) == .dark ? .dark : .light)
    }
}
