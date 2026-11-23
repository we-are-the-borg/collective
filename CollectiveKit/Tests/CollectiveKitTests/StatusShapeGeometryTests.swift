import CollectiveKit
import SwiftUI
import Testing
@testable import CollectiveUI

/// The working dot's halo and dot share one centre inside the rows' 14 pt status column, layered
/// in one `ZStack` rather than stacked.
@Suite("Status shape geometry")
@MainActor
struct StatusShapeGeometryTests {
    private static let column: CGFloat = 14
    /// Room around the column, so a halo that overflows it shows up instead of being clipped.
    private static let canvas: CGFloat = 28
    private static let scale: CGFloat = 4

    /// Bounding box of the non-transparent pixels, in points of the canvas around the column.
    private func drawnBounds(_ shape: StatusShape, size: CGFloat) throws -> CGRect {
        let view = StatusShapeView(shape, role: .agentWorking, size: size)
            .frame(width: Self.column, height: Self.column)
            .frame(width: Self.canvas, height: Self.canvas)
        let renderer = ImageRenderer(content: view)
        renderer.scale = Self.scale
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(drawn)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where data[(y * width + x) * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        try #require(maxX >= 0, "nothing drawn")
        return CGRect(
            x: CGFloat(minX) / Self.scale, y: CGFloat(minY) / Self.scale,
            width: CGFloat(maxX - minX + 1) / Self.scale, height: CGFloat(maxY - minY + 1) / Self.scale
        )
    }

    /// Circles drawn about one centre: a square box, centred, no wider than the column.
    private func expectCentred(_ bounds: CGRect) {
        let tolerance: CGFloat = 0.5
        #expect(abs(bounds.midX - Self.canvas / 2) <= tolerance)
        #expect(abs(bounds.midY - Self.canvas / 2) <= tolerance)
        #expect(abs(bounds.width - bounds.height) <= tolerance)
        #expect(bounds.width <= Self.column + tolerance && bounds.height <= Self.column + tolerance)
    }

    @Test func theStillDotIsCentred() throws {
        expectCentred(try drawnBounds(.haloDot(bright: false), size: 12))
    }

    @Test func theWorkingDotAndHaloShareTheCentre() throws {
        expectCentred(try drawnBounds(.haloDot(bright: true), size: 12))
    }

    /// The working halo stands still: always 6.25 on the 12 grid, whatever the clock says.
    @Test func theWorkingHaloStandsAtItsRestingSize() throws {
        let bounds = try drawnBounds(.haloDot(bright: true), size: 12)
        #expect(abs(bounds.width - 12.5) <= 0.5)
        #expect(abs(bounds.height - 12.5) <= 0.5)
    }
}
