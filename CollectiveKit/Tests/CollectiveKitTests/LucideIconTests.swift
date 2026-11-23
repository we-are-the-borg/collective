import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CollectiveUI

/// The bundled Lucide icons: one case per imageset, each a template that renders strokes.
@Suite struct LucideIconTests {
    /// The source catalog; the compiled `Assets.car` cannot list its names.
    private static let catalog = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/CollectiveUI/Resources/Lucide.xcassets")

    @Test func everyImagesetHasACaseAndEveryCaseAnImageset() throws {
        let sets = try FileManager.default.contentsOfDirectory(atPath: Self.catalog.path)
            .filter { $0.hasSuffix(".imageset") }
            .map { String($0.dropLast(".imageset".count)) }
        #expect(Set(sets) == Set(LucideIcon.allCases.map(\.rawValue)))
    }

    @Test(arguments: LucideIcon.allCases)
    func everyIconLoadsAsATemplate(_ icon: LucideIcon) throws {
        let image = try #require(Bundle.collectiveUI.image(forResource: icon.rawValue))
        #expect(image.isTemplate)
        #expect(image.size.width > 0)
    }

    /// A template draws in the foreground color through its alpha only: strokes come out
    /// opaque, the rest of the 24 pt field stays clear (not an empty image, not a filled box).
    /// The color check is loose because the renderer's color conversion shifts the edges a
    /// little; it only has to tell red strokes from the SVG's own black.
    @Test(arguments: LucideIcon.allCases)
    @MainActor func everyIconRendersStrokesInTheForegroundColor(_ icon: LucideIcon) throws {
        let renderer = ImageRenderer(content: LucideImage(icon, size: 24).foregroundStyle(Color(.sRGB, red: 1, green: 0, blue: 0)))
        renderer.scale = 2
        let cgImage = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var opaque = 0, clear = 0, offColor = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if color.alphaComponent > 0.9 {
                    opaque += 1
                    if color.redComponent < 0.8 || color.greenComponent > 0.3 || color.blueComponent > 0.3 {
                        offColor += 1
                    }
                } else if color.alphaComponent < 0.1 {
                    clear += 1
                }
            }
        }
        #expect(bitmap.pixelsWide == 48)
        #expect(opaque > 0)
        #expect(clear > 0)
        #expect(offColor == 0)
    }

    /// The icons take their color from a theme role: GitHub Dark's `danger` literal
    /// (reference `roles.json`), judged on the most opaque pixels because edges are blended.
    @Test @MainActor func anIconUnderARoleStyleRendersTheRolesLiteral() throws {
        let view = LucideImage(.circleX, size: 24)
            .foregroundStyle(.role(.danger))
            .themeSelection(light: "github", dark: "github-dark")
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        // Redraw into an sRGB bitmap: the renderer's own color space would shift the bytes.
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var solid = 0, offColor = 0
        for i in stride(from: 0, to: data.count, by: 4) where data[i + 3] == 255 {
            solid += 1
            // #ff7b72
            if abs(Int(data[i]) - 0xff) > 2 || abs(Int(data[i + 1]) - 0x7b) > 2 || abs(Int(data[i + 2]) - 0x72) > 2 {
                offColor += 1
            }
        }
        #expect(solid > 0)
        #expect(offColor == 0)
    }

    @Test func theIconsHaveALicenseAndANoticeNamingEveryIcon() throws {
        let license = try #require(Bundle.collectiveUI.url(forResource: "LICENSE", withExtension: nil, subdirectory: "Lucide"))
        #expect(try String(contentsOf: license, encoding: .utf8).contains("ISC License"))
        let notice = try #require(Bundle.collectiveUI.url(forResource: "NOTICE", withExtension: "md", subdirectory: "Lucide"))
        let text = try String(contentsOf: notice, encoding: .utf8)
        #expect(text.contains("lucide-static"))
        for icon in LucideIcon.allCases {
            #expect(text.contains("`\(icon.rawValue)`"), "\(icon)")
        }
    }
}
