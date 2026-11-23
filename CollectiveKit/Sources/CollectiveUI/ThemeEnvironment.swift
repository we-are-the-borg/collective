import CollectiveKit
import SwiftUI

extension EnvironmentValues {
    /// Defaults to the Catppuccin pair, following the system, so previews and tests render
    /// themed without setup. The whole choice rather than one active id, so the system switching
    /// between light and dark swaps the theme without the selection changing.
    @Entry public var themeChoice = ThemeChoice(light: BundledThemes.defaultLight, dark: BundledThemes.defaultDark)

    /// The themes `themeChoice` names, bundled and custom. The bundled ones alone by default, so
    /// previews and tests need no folder; the app injects the live catalog, so a custom file
    /// that changes or vanishes recolors every window and the popover.
    @Entry public var themeCatalog = ThemeCatalog.bundled

    /// The appearance macOS shows, which picks the slot in `ThemeMode.system`. The app injects
    /// it because it forces the windows' color scheme to the active scheme's variant (decision
    /// 82), so `colorScheme` no longer tells the system's apart; without it (previews, tests)
    /// `colorScheme` stands in.
    @Entry public var systemAppearance: ThemeAppearance?

    /// `systemAppearance`, or `colorScheme` where nobody injected it.
    public var resolvedSystemAppearance: ThemeAppearance {
        systemAppearance ?? (colorScheme == .dark ? .dark : .light)
    }

    /// One theme for a subtree in place of the choice, set by `themeFixed(_:)`.
    @Entry var pinnedTheme: Theme?

    /// The active theme. Computed instead of stored, so a change of system appearance or of the
    /// choice gets the matching theme without anyone injecting it again.
    public var theme: Theme {
        pinnedTheme ?? themeChoice.activeTheme(system: resolvedSystemAppearance, catalog: themeCatalog)
    }
}

extension View {
    /// Sets the themes for the subtree, following the system; what is not given keeps the
    /// bundled default. Where the choice comes from (the setting) stays outside, so
    /// previews and tests inject any.
    public func themeSelection(
        light: String = BundledThemes.defaultLight,
        dark: String = BundledThemes.defaultDark
    ) -> some View {
        environment(\.themeChoice, ThemeChoice(light: light, dark: dark))
    }

    /// One scheme for the subtree whatever the system shows, in its own variant, e.g. a scheme
    /// preview inside a window of another scheme. The theme itself rather than an id, so a custom
    /// one needs no catalog lookup and keeps its own variant.
    func themeFixed(_ theme: Theme) -> some View {
        environment(\.pinnedTheme, theme)
            .environment(\.colorScheme, theme.appearance == .dark ? .dark : .light)
    }
}

/// A theme role as a style, in place of `.secondary` & co. It resolves where it is drawn, so one
/// view tree follows the active theme and a change of appearance without reading `\.theme` itself.
public struct RoleStyle: ShapeStyle {
    public var role: ThemeRole

    public init(_ role: ThemeRole) {
        self.role = role
    }

    public func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        Color(environment.theme.roles[role]).resolve(in: environment)
    }
}

extension ShapeStyle where Self == RoleStyle {
    /// `.foregroundStyle(.role(.textMuted))`, `.background(.role(.surface))`.
    public static func role(_ role: ThemeRole) -> RoleStyle {
        RoleStyle(role)
    }
}

extension Color {
    /// For places that need a `Color` value rather than a style, such as a `Canvas`. The roles
    /// are derived as sRGB bytes, so the components go in unchanged; a role drawn this way
    /// matches the same role drawn through `.role(_:)`.
    public init(_ color: ThemeColor) {
        self.init(
            .sRGB,
            red: Double(color.r) / 255,
            green: Double(color.g) / 255,
            blue: Double(color.b) / 255,
            opacity: Double(color.a) / 255
        )
    }
}
