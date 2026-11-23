import AppKit
import CollectiveKit
import CollectiveUI
import Foundation
import Testing

/// Samples the drawn cube at 2×, drawing the image as the status item does.
/// The still frame (Reduce Motion) at yaw 45° has no sparkles or glitter, so
/// the probes on it hit only cube, badge or glow.
@MainActor @Suite struct MenuBarSceneImageTests {
    private static let scale = 2

    private func still(_ icon: MenuBarIcon, _ appearance: MenuBarScene.Appearance) throws -> MenuBarScene {
        try #require(icon.scene(at: Date(timeIntervalSinceReferenceDate: 0), appearance: appearance, animation: MenuBarAnimation(), reduceMotion: true))
    }

    private func render(_ scene: MenuBarScene) throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 22 * Self.scale, pixelsHigh: 18 * Self.scale, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = NSSize(width: 22, height: 18)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        MenuBarSceneImage.image(for: scene, scales: [Double(Self.scale)]).draw(in: NSRect(x: 0, y: 0, width: 22, height: 18))
        return rep
    }

    /// Canvas coordinates, y down like the scene; the pixel whose square holds the point.
    private func pixel(_ rep: NSBitmapImageRep, _ x: Double, _ y: Double) throws -> NSColor {
        let color = try #require(rep.colorAt(x: Int(x * Double(Self.scale)), y: Int(y * Double(Self.scale))))
        return try #require(color.usingColorSpace(.sRGB))
    }

    private func matches(_ color: NSColor, _ expected: MenuBarScene.RGBA, within tolerance: Double = 0.06) -> Bool {
        abs(color.redComponent - expected.red) <= tolerance
            && abs(color.greenComponent - expected.green) <= tolerance
            && abs(color.blueComponent - expected.blue) <= tolerance
            && abs(color.alphaComponent - expected.alpha) <= tolerance
    }

    @Test func isAColoredImageOnTheMenuBarCanvas() throws {
        let image = MenuBarSceneImage.image(for: try still(.working(count: 3), .light), scales: [2])
        #expect(!image.isTemplate)
        #expect(image.size == NSSize(width: 22, height: 18))
    }

    /// One bitmap per display scale, each with native pixels on the 22 × 18 pt canvas.
    @Test func holdsABitmapForEveryScale() throws {
        let image = MenuBarSceneImage.image(for: try still(.working(count: 3), .light), scales: [1, 2])
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        #expect(reps.count == 2)
        #expect(Set(reps.map { [$0.pixelsWide, $0.pixelsHigh] }) == [[22, 18], [44, 36]])
        #expect(reps.allSatisfy { $0.size == NSSize(width: 22, height: 18) })
    }

    /// AppKit draws the status item's image several times per frame;
    /// the image must hold only bitmaps, since a drawing-handler rep would be
    /// re-run by AppKit on every one of those draws.
    @Test(arguments: [MenuBarIcon.working(count: 3), .backgroundShell])
    func holdsOnlyBitmaps(icon: MenuBarIcon) throws {
        let image = MenuBarSceneImage.image(for: try still(icon, .light), scales: [1, 2])
        #expect(!image.representations.isEmpty)
        #expect(image.representations.allSatisfy { $0 is NSBitmapImageRep })
    }

    /// Top face, between its top corner and the grid's crossing, clear of every cut.
    @Test func facesAreFilledInTheirColor() throws {
        let scene = try still(.working(count: 3), .light)
        let color = try pixel(try render(scene), 9, 2.7)
        #expect(scene.faces.contains { matches(color, $0.color) })
    }

    /// The three visible edges meet in the middle; they are cut out, not drawn.
    @Test func edgesAreCutOutOfTheFaces() throws {
        let rep = try render(try still(.working(count: 3), .light))
        #expect(try pixel(rep, 9, 9).alphaComponent < 0.1)
    }

    /// On the way from the badge to the cube's middle, 6 pt from the badge's
    /// center: inside the cube, but within the knockout (5.5 + 1.1 pt).
    @Test(arguments: [MenuBarIcon.working(count: 3), .needsPermission])
    func theBadgeStandsFreeOfTheCube(icon: MenuBarIcon) throws {
        let scene = try still(icon, .light)
        let rep = try render(scene)
        let length = (7.5 * 7.5 + 3.5 * 3.5).squareRoot()
        let x = 16.5 - 7.5 / length * 6, y = 5.5 + 3.5 / length * 6
        let gap = try pixel(rep, x, y)
        // Amber glows on a light bar too; the gap stays far below the cube's own cover.
        #expect(gap.alphaComponent < (scene.glow == nil ? 0.05 : 0.6))
        #expect(matches(try pixel(rep, 16.5, 0.8), try #require(scene.badge).fill))
    }

    @Test(arguments: [MenuBarIcon.working(count: 3), .working(count: 12), .needsPermission])
    func theBadgeTextIsDrawnInItsColor(icon: MenuBarIcon) throws {
        let scene = try still(icon, .dark)
        let badge = try #require(scene.badge)
        let rep = try render(scene)
        var textPixels = 0
        for px in Int(9.5 * Double(Self.scale))..<(22 * Self.scale) {
            for py in 0..<(11 * Self.scale) {
                let color = try #require(rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB))
                if matches(color, badge.textColor, within: 0.1) { textPixels += 1 }
            }
        }
        #expect(textPixels > 10)
    }

    /// The background shell's glimmer is ink for macOS to tint.
    @Test func theGlimmerIsATemplate() throws {
        let image = MenuBarSceneImage.image(for: try still(.backgroundShell, .light), scales: [2])
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 22, height: 18))
    }

    /// The still frame: the top face at 30 % ink, the edges drawn in full
    /// ink rather than cut out, the grid's crossing in between.
    @Test func theGlimmerDrawsFacesEdgesAndGridInInk() throws {
        let rep = try render(try still(.backgroundShell, .light))
        #expect(matches(try pixel(rep, 9, 2.7), MenuBarScene.RGBA(red: 0, green: 0, blue: 0, alpha: 0.3)))
        #expect(matches(try pixel(rep, 9, 9), MenuBarScene.RGBA(red: 0, green: 0, blue: 0, alpha: 1)))
        let crossing = try pixel(rep, 9, 9 - 3.9 * 1.1)
        #expect(crossing.alphaComponent > 0.45 && crossing.alphaComponent < 0.8, "\(crossing.alphaComponent)")
    }

    /// Just left of the hull: only the glow reaches there.
    @Test func theNebulaGlowsOnlyOnADarkBar() throws {
        let light = try pixel(try render(try still(.working(count: 3), .light)), 0.6, 9)
        let dark = try pixel(try render(try still(.working(count: 3), .dark)), 0.6, 9)
        #expect(light.alphaComponent < 0.02)
        #expect(dark.alphaComponent > 0.05)
    }

    /// Over a minute of a light bar (no glow), every speck large enough to
    /// cover a whole pixel shows its own color there: drawn, and on top of
    /// the cube and of the stars it crosses.
    @Test func glitterLiesOnTopOfCubeAndStars() throws {
        var checked = 0, overStars = 0
        for tick in 1...720 {
            let scene = try #require(MenuBarIcon.working(count: 3).scene(
                at: Date(timeIntervalSinceReferenceDate: (Double(tick) + 0.5) / 12), appearance: .light, animation: MenuBarAnimation(), reduceMotion: false
            ))
            var rep: NSBitmapImageRep?
            for speck in scene.glitter {
                let px = (speck.center.x * Double(Self.scale)).rounded(.down), py = (speck.center.y * Double(Self.scale)).rounded(.down)
                guard px >= 0, py >= 0 else { continue }
                let corners = [(px, py), (px + 1, py), (px, py + 1), (px + 1, py + 1)].map {
                    CGPoint(x: $0.0 / Double(Self.scale), y: $0.1 / Double(Self.scale))
                }
                guard corners.allSatisfy({ abs($0.x - speck.center.x) + abs($0.y - speck.center.y) < speck.radius - 0.02 }) else { continue }
                if rep == nil { rep = try render(scene) }
                #expect(matches(try pixel(try #require(rep), speck.center.x, speck.center.y), speck.color), "tick \(tick)")
                checked += 1
                let crossed = scene.sparkles.contains { star in
                    let path = CGMutablePath()
                    path.addLines(between: star.points.map { CGPoint(x: $0.x, y: $0.y) })
                    path.closeSubpath()
                    return corners.allSatisfy { path.contains($0) }
                }
                if crossed { overStars += 1 }
            }
        }
        #expect(checked > 20)
        #expect(overStars > 0)
    }

    @Test func appearanceFollowsTheMenuBar() throws {
        #expect(MenuBarScene.Appearance(try #require(NSAppearance(named: .aqua))) == .light)
        #expect(MenuBarScene.Appearance(try #require(NSAppearance(named: .vibrantLight))) == .light)
        #expect(MenuBarScene.Appearance(try #require(NSAppearance(named: .darkAqua))) == .dark)
        #expect(MenuBarScene.Appearance(try #require(NSAppearance(named: .vibrantDark))) == .dark)
    }
}
