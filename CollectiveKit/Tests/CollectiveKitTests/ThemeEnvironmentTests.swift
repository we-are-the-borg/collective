import CollectiveKit
import CollectiveUI
import SwiftUI
import Testing

/// The theme roles as the views read them: the active theme from the choice and the system
/// appearance (or the color scheme where none is injected), the roles as shape styles and
/// `ThemeColor` as SwiftUI `Color`.
@Suite struct ThemeEnvironmentTests {
    private func environment(
        _ scheme: ColorScheme, selection: ThemeChoice? = nil, system: ThemeAppearance? = nil
    ) -> EnvironmentValues {
        var env = EnvironmentValues()
        env.colorScheme = scheme
        if let selection {
            env.themeChoice = selection
        }
        env.systemAppearance = system
        return env
    }

    @Test func withoutASelectionTheSchemePicksTheCatppuccinDefault() {
        #expect(environment(.light).theme.id == "catppuccin-latte")
        #expect(environment(.dark).theme.id == "catppuccin-macchiato")
    }

    @Test func aSelectionPicksItsIDPerScheme() {
        let selection = ThemeChoice(light: "github", dark: "github-dark")
        #expect(environment(.light, selection: selection).theme.id == "github")
        #expect(environment(.dark, selection: selection).theme.id == "github-dark")
    }

    @Test func anUnknownIDFallsBackToTheDefaultOfItsAppearance() {
        let selection = ThemeChoice(light: "no-such-theme", dark: "no-such-theme")
        #expect(environment(.light, selection: selection).theme.id == "catppuccin-latte")
        #expect(environment(.dark, selection: selection).theme.id == "catppuccin-macchiato")
    }

    /// The app forces the window to the active scheme's variant, so the color scheme there is
    /// no longer the system's: the injected system appearance picks the slot.
    @Test func theInjectedSystemAppearancePicksTheSlotWhateverTheColorScheme() {
        let selection = ThemeChoice(light: "github", dark: "github-dark")
        #expect(environment(.dark, selection: selection, system: .light).theme.id == "github")
        #expect(environment(.light, selection: selection, system: .dark).theme.id == "github-dark")
    }

    @Test func oneSchemeShowsWhateverTheSystemAndTheColorScheme() {
        let selection = ThemeChoice(light: "github", dark: "github-dark", mode: .fixed, fixed: "catppuccin-mocha")
        #expect(environment(.light, selection: selection, system: .light).theme.id == "catppuccin-mocha")
        #expect(environment(.dark, selection: selection, system: .dark).theme.id == "catppuccin-mocha")
        #expect(environment(.light, selection: selection).theme.id == "catppuccin-mocha")
    }

    /// `Color.Resolved`'s `red`, `green`, `blue` are sRGB-encoded (its `linearRed` & co. are
    /// not), so ×255 must give back the bytes; a mid value would expose a linear read.
    private func bytes(_ resolved: Color.Resolved) -> ThemeColor {
        func byte(_ component: Float) -> UInt8 {
            UInt8((component * 255).rounded())
        }
        return ThemeColor(r: byte(resolved.red), g: byte(resolved.green), b: byte(resolved.blue), a: byte(resolved.opacity))
    }

    @Test(arguments: [
        ThemeColor(r: 0, g: 0, b: 0, a: 255),
        ThemeColor(r: 255, g: 255, b: 255, a: 255),
        ThemeColor(r: 128, g: 64, b: 1, a: 255),
        ThemeColor(r: 36, g: 39, b: 58, a: 38),
        ThemeColor(r: 254, g: 127, b: 0, a: 0),
    ])
    func colorKeepsTheExactSRGBBytes(_ color: ThemeColor) {
        #expect(bytes(Color(color).resolve(in: EnvironmentValues())) == color)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func everyRoleResolvesToTheActiveThemesColor(_ scheme: ColorScheme) {
        let env = environment(scheme)
        for role in ThemeRole.allCases {
            #expect(bytes(RoleStyle.role(role).resolve(in: env)) == env.theme.roles[role], "\(role.name)")
        }
    }

    /// Literals from Unimatrix's reference `roles.json`, independent of `theme.roles`.
    @Test func theDefaultSelectionResolvesSurfaceToTheReferenceLiterals() {
        #expect(bytes(RoleStyle.role(.surface).resolve(in: environment(.light))) == ThemeColor.rgb(0xeff1f5)) // Catppuccin Latte
        #expect(bytes(RoleStyle.role(.surface).resolve(in: environment(.dark))) == ThemeColor.rgb(0x24273a)) // Catppuccin Macchiato
    }

    @Test func aRoleFollowsTheSelection() {
        let selection = ThemeChoice(light: "github", dark: "github-dark")
        let env = environment(.dark, selection: selection)
        #expect(bytes(RoleStyle.role(.surface).resolve(in: env)) == BundledThemes.resolve(id: "github-dark", appearance: .dark).roles.surface)
    }

    /// The modifier end to end: a rendered fill under a forced dark scheme shows the selected
    /// dark theme's surface.
    @MainActor @Test func theModifierSetsTheSelectionForTheSubtree() throws {
        let view = Rectangle()
            .fill(.role(.surface))
            .frame(width: 4, height: 4)
            .themeSelection(light: "github", dark: "github-dark")
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        let image = try #require(renderer.cgImage)
        let pixel = try #require(srgbPixel(image))
        // GitHub Dark's base00, which `surface` takes unchanged.
        #expect(pixel == ThemeColor.rgb(0x0d1117))
    }

    /// The centre pixel of `image`, drawn into an sRGB bitmap.
    private func srgbPixel(_ image: CGImage) -> ThemeColor? {
        var data = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        guard drawn else { return nil }
        return ThemeColor(r: data[0], g: data[1], b: data[2], a: data[3])
    }
}
