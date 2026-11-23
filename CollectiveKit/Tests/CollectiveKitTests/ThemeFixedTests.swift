import CollectiveKit
@testable import CollectiveUI
import Foundation
import SwiftUI
import Testing

/// `themeFixed(_:)`: a subtree in one scheme and its variant whatever the window shows, as the
/// Appearance pane's slot previews and color strips need, custom themes included.
@Suite struct ThemeFixedTests {
    /// Fills with `--surface` in a dark color scheme and `--text` in a light one, so one pixel
    /// tells both the theme and the variant.
    private struct Probe: View {
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            Rectangle()
                .fill(.role(colorScheme == .dark ? .surface : .text))
                .frame(width: 4, height: 4)
        }
    }

    private func horizonDark() throws -> Theme {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-fixed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/custom-themes/horizon-dark.yaml"),
            to: url.appendingPathComponent("horizon-dark.yaml")
        )
        return try #require(ThemeCatalog(custom: CustomThemeFolder.entries(in: url)).customThemes.first).theme
    }

    @MainActor private func pixel<V: View>(_ view: V) throws -> ThemeColor {
        let image = try #require(ImageRenderer(content: view).cgImage)
        var data = [UInt8](repeating: 0, count: 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return ThemeColor(r: data[0], g: data[1], b: data[2], a: data[3])
    }

    /// A custom theme the environment's catalog does not hold still draws in its own colors and
    /// its own dark variant inside a light window.
    @MainActor @Test func aCustomThemeDrawsInItsOwnColorsAndVariant() throws {
        let theme = try horizonDark()
        #expect(theme.appearance == .dark)
        let view = Probe().themeFixed(theme).environment(\.colorScheme, .light)
        #expect(try pixel(view) == theme.roles.surface)
    }

    @MainActor @Test func aLightSchemeInADarkWindowIsLight() throws {
        let latte = BundledThemes.resolve(id: BundledThemes.defaultLight, appearance: .light)
        let view = Probe().themeFixed(latte).environment(\.colorScheme, .dark)
        #expect(try pixel(view) == latte.roles.text)
    }
}
