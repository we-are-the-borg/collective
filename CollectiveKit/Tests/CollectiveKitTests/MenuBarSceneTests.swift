import Foundation
import Testing
@testable import CollectiveKit

/// Reference values come from the design's own renderer: its `CubeIcon`
/// component, run outside the page in node with the props of the chosen
/// variants (working, open question) at the given t. The renderer prints three decimals, hence the tolerance.
private let tolerance = 0.0006

private func close(_ a: Double, _ b: Double, _ within: Double = tolerance) -> Bool { abs(a - b) <= within }

private func close(_ a: MenuBarScene.Point, _ b: (Double, Double)) -> Bool { close(a.x, b.0) && close(a.y, b.1) }

private func close(_ a: [MenuBarScene.Point], _ b: [(Double, Double)]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { close($0, $1) }
}

private func close(_ a: MenuBarScene.RGBA, _ b: MenuBarScene.RGBA) -> Bool {
    close(a.red, b.red, 1e-9) && close(a.green, b.green, 1e-9) && close(a.blue, b.blue, 1e-9) && close(a.alpha, b.alpha, 1e-9)
}

private func at(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

@Suite struct MenuBarSceneColorTests {
    /// Expected components from the CSS Color 4 reference algorithm, checked by hand for the first.
    @Test func hslConvertsLikeCSS() {
        let green = MenuBarScene.RGBA(hue: 145, saturation: 78, lightness: 42)
        #expect(close(green.red, 0.0924, 1e-9) && close(green.green, 0.7476, 1e-9) && close(green.blue, 0.3654, 1e-9))
        #expect(green.alpha == 1)
        let amberGlow = MenuBarScene.RGBA(hue: 36, saturation: 100, lightness: 55, alpha: 0.5)
        #expect(close(amberGlow, MenuBarScene.RGBA(red: 1, green: 0.64, blue: 0.1, alpha: 0.5)))
        let nebulaOutline = MenuBarScene.RGBA(hue: 268, saturation: 100, lightness: 84)
        #expect(close(nebulaOutline.red, 0.829333, 1e-6) && close(nebulaOutline.green, 0.68, 1e-9) && nebulaOutline.blue == 1)
        #expect(close(MenuBarScene.RGBA(hue: 0, saturation: 100, lightness: 50), MenuBarScene.RGBA(red: 1, green: 0, blue: 0)))
        #expect(close(MenuBarScene.RGBA(hue: 360, saturation: 100, lightness: 50), MenuBarScene.RGBA(red: 1, green: 0, blue: 0)))
    }

    @Test func hexConvertsToComponents() {
        #expect(MenuBarScene.RGBA(hex: 0x6A3FE8) == MenuBarScene.RGBA(red: 106.0 / 255, green: 63.0 / 255, blue: 232.0 / 255))
        #expect(MenuBarScene.RGBA(hex: 0xFFFFFF, alpha: 0.95) == MenuBarScene.RGBA(red: 1, green: 1, blue: 1, alpha: 0.95))
    }
}

@Suite struct MenuBarSceneTimingTests {
    private let working = MenuBarIcon.working(count: 3)

    private func scene(_ icon: MenuBarIcon, _ seconds: Double, _ appearance: MenuBarScene.Appearance = .light, reduceMotion: Bool = false) -> MenuBarScene? {
        icon.scene(at: at(seconds), appearance: appearance, animation: MenuBarAnimation(), reduceMotion: reduceMotion)
    }

    /// 12 fps from the wall clock: every date inside a tick shows that tick's frame.
    @Test func timeIsQuantizedToTicksOfTheClock() {
        #expect(scene(working, 1.07) == scene(working, 1.0))
        #expect(scene(working, 1.0 + 1.0 / 12 - 0.001) == scene(working, 1.0))
        #expect(scene(working, 1.0 + 1.0 / 12 + 0.001) != scene(working, 1.0))
        // 0.7 s lies in tick 8 (0.667 s).
        #expect(scene(.needsPermission, 0.7) == scene(.needsPermission, 8.0 / 12))
    }

    /// Drift: a quarter turn every 4 s with the cosine easing, no rest.
    @Test func driftTurnsAQuarterEveryFourSeconds() throws {
        let expected: [(Double, Double)] = [(0, 45), (1, 58.180195), (2, 90), (3, 121.819805), (4, 45), (781_000_000, 45)]
        for (seconds, yaw) in expected {
            let yawDegrees = try #require(scene(working, seconds)).yawDegrees
            #expect(close(yawDegrees, yaw, 1e-6), "t = \(seconds)")
        }
        #expect(try #require(scene(working, 1)).intensity == 1)
    }

    /// Pulse: 1.4 s from full to half and back; the cube doesn't turn.
    @Test func pulseFadesToHalfEveryOnePointFourSeconds() throws {
        let expected: [(Double, Double)] = [(0, 1), (8.0 / 12, 0.502792), (0.75, 0.506268), (1.4 * 1_000, 1)]
        for (seconds, k) in expected {
            let frame = try #require(scene(.needsPermission, seconds))
            #expect(close(frame.intensity, k, 1e-6), "t = \(seconds)")
            #expect(frame.yawDegrees == 45)
        }
    }

    /// The app sleeps until the returned date and draws that date: strictly
    /// later, on the next tick, already showing the new frame.
    @Test(arguments: [MenuBarIcon.working(count: 1), .working(count: 12), .needsPermission, .backgroundShell])
    func nextSceneChangeIsTheNextTick(icon: MenuBarIcon) throws {
        for base in [0.0, 1.0 / 12, 0.04, 1_000, 781_000_000.123, -12_345.678] {
            let date = at(base)
            let next = try #require(icon.nextSceneChange(after: date, animation: MenuBarAnimation(), reduceMotion: false))
            #expect(next > date)
            let tick = (base * 12).rounded(.down)
            #expect(abs(next.timeIntervalSinceReferenceDate - (tick + 1) / 12) < 1e-6)
            #expect((next.timeIntervalSinceReferenceDate * 12).rounded(.down) == tick + 1)
        }
    }

    @Test func nothingChangesWithoutAnimation() {
        for icon in [MenuBarIcon.working(count: 2), .needsPermission] {
            #expect(icon.nextSceneChange(after: at(5), animation: MenuBarAnimation(), reduceMotion: true) == nil)
        }
        for icon in [MenuBarIcon.idle, .warning, .working(count: 0)] {
            #expect(icon.nextSceneChange(after: at(5), animation: MenuBarAnimation(), reduceMotion: false) == nil)
        }
    }

    /// Reduce Motion: the cube stands at 45°, full strength, no sparkles; colors and badge stay.
    @Test(arguments: [MenuBarIcon.working(count: 4), .needsPermission])
    func reduceMotionIsOneStillFrame(icon: MenuBarIcon) throws {
        let still = try #require(scene(icon, 2.0, reduceMotion: true))
        #expect(still.yawDegrees == 45 && still.intensity == 1)
        #expect(still.sparkles.isEmpty)
        for seconds in [0.0, 0.75, 3.0, 781_000_000.123] {
            #expect(scene(icon, seconds, reduceMotion: true) == still)
        }
        let moving = try #require(scene(icon, 0.0))
        #expect(still.badge == moving.badge)
        #expect(still.faces.map(\.color) == moving.faces.map(\.color))
    }

    /// Idle and warning stay template images.
    @Test func onlyWorkingAndNeedsPermissionHaveAScene() {
        #expect(scene(.idle, 1) == nil)
        #expect(scene(.warning, 1) == nil)
        #expect(scene(.working(count: 0), 1) == nil)
        #expect(scene(.working(count: 1), 1) != nil)
        #expect(scene(.needsPermission, 1) != nil)
    }
}

private func hsl(_ h: Double, _ s: Double, _ l: Double, _ a: Double = 1) -> MenuBarScene.RGBA {
    MenuBarScene.RGBA(hue: h, saturation: s, lightness: l, alpha: a)
}

@Suite struct MenuBarSceneGeometryTests {
    private func scene(_ icon: MenuBarIcon, _ seconds: Double, _ appearance: MenuBarScene.Appearance = .light) throws -> MenuBarScene {
        try #require(icon.scene(at: at(seconds), appearance: appearance, animation: MenuBarAnimation(), reduceMotion: false))
    }

    /// Renderer at t = 0 (yaw 45°): the right, top and front faces, in that order.
    @Test func cornerOnShowsThreeFacesAsTheRendererDoes() throws {
        let frame = try scene(.working(count: 3), 0)
        #expect(frame.faces.count == 3)
        #expect(close(frame.faces[0].points, [(15.8, 12.9), (15.8, 5.1), (9, 8.999), (9, 16.799)]))
        #expect(close(frame.faces[1].points, [(9, 1.201), (2.2, 5.1), (9, 8.999), (15.8, 5.1)]))
        #expect(close(frame.faces[2].points, [(2.2, 12.9), (9, 16.799), (9, 8.999), (2.2, 5.1)]))
        #expect(frame.faces.map(\.color) == [hsl(266, 72, 50), hsl(280, 72, 66), hsl(248, 72, 55)])
        #expect(close(frame.hull, [(2.2, 5.1), (9, 1.201), (15.8, 5.1), (15.8, 12.9), (9, 16.799), (2.2, 12.9)]))
    }

    /// Four edges and two midlines per visible face, knocked out of the faces.
    @Test func edgesAndGridFollowTheVisibleFaces() throws {
        let frame = try scene(.working(count: 3), 0)
        #expect(frame.edges.count == 12)
        #expect(close([frame.edges[0].from, frame.edges[0].to], [(15.8, 12.9), (15.8, 5.1)]))
        let grid = frame.grid.flatMap { [$0.from, $0.to] }
        #expect(close(grid, [
            (15.8, 9), (9, 12.899), (12.4, 7.05), (12.4, 14.849), (5.6, 3.151), (12.4, 7.05),
            (5.6, 7.05), (12.4, 3.151), (5.6, 14.849), (5.6, 7.05), (9, 12.899), (2.2, 9),
        ]))
        #expect(MenuBarScene.edgeWidth == 0.909 && MenuBarScene.gridWidth == 0.591 && MenuBarScene.outlineWidth == 0.909)
        #expect(MenuBarScene.cubeScale == 1.1 && MenuBarScene.cubeCenter == MenuBarScene.Point(x: 9, y: 9))
    }

    /// Renderer at t = 1 s, dark bar: yaw 58.18°, the colors wander with the turn.
    @Test func driftFrameMatchesTheRenderer() throws {
        let frame = try scene(.working(count: 3), 1, .dark)
        #expect(frame.faces.map(\.color) == [hsl(266, 72, 51), hsl(280, 72, 66), hsl(248, 72, 56)])
        #expect(close(frame.faces[0].points, [(15.62, 13.789), (15.62, 5.989), (7.45, 8.897), (7.45, 16.696)]))
        #expect(close(frame.hull, [(2.38, 4.211), (10.55, 1.304), (15.62, 5.989), (15.62, 13.789), (7.45, 16.696), (2.38, 12.011)]))
        // At 3 s the back face (hue 286) has come round instead of the front one.
        #expect(try scene(.working(count: 3), 3).faces.map(\.color) == [hsl(266, 72, 55), hsl(280, 72, 66), hsl(286, 72, 49)])
    }

    /// Halfway through the turn the cube faces the viewer: two faces.
    @Test func faceOnShowsTwoFaces() throws {
        let frame = try scene(.working(count: 3), 2)
        #expect(frame.faces.map(\.color) == [hsl(266, 72, 53), hsl(280, 72, 66)])
        #expect(frame.edges.count == 8 && frame.grid.count == 4)
    }

    /// The silhouette of a cube seen corner-on is a convex hexagon, also mid-drift.
    @Test(arguments: [0.0, 0.5, 1, 1.5, 3, 3.5])
    func hullIsAConvexHexagon(seconds: Double) throws {
        let hull = try scene(.working(count: 1), seconds).hull
        #expect(hull.count == 6)
        for i in hull.indices {
            let o = hull[i], a = hull[(i + 1) % 6], b = hull[(i + 2) % 6]
            #expect((a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) > 0)
        }
    }

    /// Renderer, amber at 0.667 s (light), 0.75 s (dark) and 0: the faces darken with the pulse.
    @Test func amberFacesAndGlowFollowThePulse() throws {
        let light = try scene(.needsPermission, 8.0 / 12)
        #expect(light.faces.map(\.color) == [hsl(36, 100, 35), hsl(36, 100, 47), hsl(36, 100, 39)])
        let lightGlow = try #require(light.glow)
        #expect(close(lightGlow.radius, 0.704) && close(lightGlow.color.alpha, 0.427))
        #expect(close(lightGlow.color, hsl(36, 100, 55, lightGlow.color.alpha)))
        let darkGlow = try #require(try scene(.needsPermission, 0.75, .dark).glow)
        #expect(close(darkGlow.radius, 0.70875) && close(darkGlow.color.alpha, 0.43))
        let full = try #require(try scene(.needsPermission, 0).glow)
        #expect(close(full.radius, 1.4, 1e-9) && close(full.color.alpha, 0.85, 1e-9))
        #expect(try scene(.needsPermission, 0).faces.map(\.color) == [hsl(36, 100, 45), hsl(36, 100, 60), hsl(36, 100, 50)])
    }

    @Test func outlinesPerLookAndAppearance() throws {
        #expect(try scene(.working(count: 2), 0).outline == hsl(262, 70, 30, 0.95))
        #expect(try scene(.working(count: 2), 0, .dark).outline == hsl(268, 100, 84, 0.95))
        #expect(try scene(.needsPermission, 0).outline == hsl(30, 100, 30, 0.95))
        #expect(try scene(.needsPermission, 0, .dark).outline == hsl(40, 100, 72, 0.95))
    }

    /// Nebula glows on a dark bar only; amber always, with the pulse.
    @Test func nebulaGlowsOnlyOnADarkBar() throws {
        #expect(try scene(.working(count: 2), 1).glow == nil)
        #expect(try scene(.working(count: 2), 1, .dark).glow == MenuBarScene.Glow(color: hsl(275, 100, 70, 0.65), radius: 0.9))
    }
}

@Suite struct MenuBarSceneBadgeTests {
    private func badge(_ icon: MenuBarIcon, _ appearance: MenuBarScene.Appearance = .light) throws -> MenuBarScene.Badge {
        try #require(icon.scene(at: at(1), appearance: appearance, animation: MenuBarAnimation(), reduceMotion: false)?.badge)
    }

    /// Size L: circle (16.5 | 5.5) r 5.5, knockout 1.1 pt larger.
    @Test(arguments: 1...9)
    func oneToNineIsALargeCircle(count: Int) throws {
        let badge = try badge(.working(count: count))
        #expect(badge.text == "\(count)")
        #expect(badge.shape == .circle(center: MenuBarScene.Point(x: 16.5, y: 5.5), radius: 5.5))
        guard case .circle(let center, let radius) = badge.knockout else { Issue.record("knockout is no circle"); return }
        #expect(center == MenuBarScene.Point(x: 16.5, y: 5.5) && close(radius, 6.6, 1e-9))
        #expect(badge.textCenterX == 16.5 && close(badge.baseline, 8.74, 1e-9) && badge.fontSize == 9)
    }

    /// Renderer: "9+" as the pill M15 0 H16.5 a5.5…, knockout M15 -1.1 H16.5 a6.6…, text at 15.75.
    @Test(arguments: [10, 11, 250])
    func tenOrMoreIsNinePlusInAPill(count: Int) throws {
        let badge = try badge(.working(count: count))
        #expect(badge.text == "9+")
        #expect(badge.shape == .pill(x: 9.5, y: 0, width: 12.5, height: 11))
        guard case .pill(let x, let y, let width, let height) = badge.knockout else { Issue.record("knockout is no pill"); return }
        #expect(close(x, 8.4, 1e-9) && close(y, -1.1, 1e-9) && close(width, 14.7, 1e-9) && close(height, 13.2, 1e-9))
        #expect(badge.textCenterX == 15.75 && close(badge.baseline, 8.74, 1e-9))
    }

    @Test(arguments: [MenuBarScene.Appearance.light, .dark])
    func nebulaBadgeIsVioletWithWhiteText(appearance: MenuBarScene.Appearance) throws {
        let badge = try badge(.working(count: 3), appearance)
        #expect(badge.fill == MenuBarScene.RGBA(hex: 0x6A3FE8))
        #expect(badge.textColor == MenuBarScene.RGBA(red: 1, green: 1, blue: 1))
    }

    @Test(arguments: [MenuBarScene.Appearance.light, .dark])
    func permissionBadgeIsAnAmberQuestionMark(appearance: MenuBarScene.Appearance) throws {
        let badge = try badge(.needsPermission, appearance)
        #expect(badge.text == "?")
        #expect(badge.shape == .circle(center: MenuBarScene.Point(x: 16.5, y: 5.5), radius: 5.5))
        #expect(badge.fill == MenuBarScene.RGBA(hex: 0xFF9F0A))
        #expect(badge.textColor == MenuBarScene.RGBA(hex: 0x3A2200))
    }
}

@Suite struct MenuBarSceneSparkleTests {
    private func sparkles(_ icon: MenuBarIcon, _ seconds: Double, _ appearance: MenuBarScene.Appearance = .light, reduceMotion: Bool = false) throws -> [MenuBarScene.Sparkle] {
        try #require(icon.scene(at: at(seconds), appearance: appearance, animation: MenuBarAnimation(), reduceMotion: reduceMotion)).sparkles
    }

    /// Every tick of a minute, both appearances.
    private static let sweep = (0..<720).map { Double($0) / 12 + 0.01 }

    /// Renderer at t = 2 s: a star of the first ten, path M5.6 5.763 L6.091 6.909 …,
    /// and one of the six nebula adds, grown by 1.35 and flaring for 0.75 s.
    @Test func sparkleMatchesTheRenderer() throws {
        let stars = try sparkles(.working(count: 3), 2)
        #expect(stars.count == 2)
        #expect(stars.map(\.color) == [MenuBarScene.RGBA(hex: 0x7B4DFF), MenuBarScene.RGBA(hex: 0xD63FB0)])
        #expect(close(stars[0].points, [(5.6, 5.763), (6.091, 6.909), (7.237, 7.4), (6.091, 7.891), (5.6, 9.037), (5.109, 7.891), (3.963, 7.4), (5.109, 6.909)]))
        #expect(close(stars[1].points, [(11.2, 15.251), (11.605, 16.195), (12.549, 16.6), (11.605, 17.005), (11.2, 17.949), (10.795, 17.005), (9.851, 16.6), (10.795, 16.195)]))
    }

    /// Renderer at t = 3 s: three stars, colors from the light or dark palette.
    @Test func paletteFollowsTheAppearance() throws {
        let light = try sparkles(.working(count: 3), 3)
        let dark = try sparkles(.working(count: 3), 3, .dark)
        #expect(light.map(\.color) == [MenuBarScene.RGBA(hex: 0x7B4DFF), MenuBarScene.RGBA(hex: 0xD99A00), MenuBarScene.RGBA(hex: 0xD63FB0)])
        #expect(dark.map(\.color) == [MenuBarScene.RGBA(hex: 0xFFFFFF), MenuBarScene.RGBA(hex: 0xFFE27A), MenuBarScene.RGBA(hex: 0xFFB8F0)])
        #expect(close(light.map(\.center), [(3.2, 3.4), (1.6, 11.2), (0.9, 15.6)]))
        #expect(close(light[0].radius, 0.933) && close(light[1].radius, 1.88) && close(light[2].radius, 1.754))
        #expect(light.map(\.center) == dark.map(\.center))
    }

    /// The third palette color shows up too, so a sweep sees all three.
    @Test func allThreeColorsTwinkleOverAMinute() throws {
        var colors: [MenuBarScene.RGBA] = []
        for seconds in Self.sweep {
            for star in try sparkles(.working(count: 3), seconds, .dark) where !colors.contains(star.color) { colors.append(star.color) }
        }
        #expect(colors.count == 3 && colors.contains(MenuBarScene.RGBA(hex: 0xFFB8F0)))
    }

    /// Nothing right of x 9 and above y 12.6, where the L badge sits; the
    /// stars below it, right of x 9, still twinkle.
    @Test(arguments: [MenuBarIcon.working(count: 3), .working(count: 42)])
    func noSparklesInTheBadgeCorner(icon: MenuBarIcon) throws {
        var rightOfCenter = false
        for seconds in Self.sweep {
            for star in try sparkles(icon, seconds) {
                #expect(!(star.center.x > 9 && star.center.y < 12.6), "t = \(seconds)")
                if star.center.x > 9 { rightOfCenter = true }
            }
        }
        #expect(rightOfCenter)
    }

    @Test func amberHasNoSparkles() throws {
        for seconds in Self.sweep {
            #expect(try sparkles(.needsPermission, seconds).isEmpty)
            #expect(try sparkles(.needsPermission, seconds, .dark).isEmpty)
        }
    }

    @Test func reduceMotionHasNoSparkles() throws {
        for seconds in Self.sweep {
            #expect(try sparkles(.working(count: 3), seconds, reduceMotion: true).isEmpty)
        }
    }
}

@Suite struct MenuBarSceneGlitterTests {
    private func glitter(_ icon: MenuBarIcon, _ seconds: Double, _ appearance: MenuBarScene.Appearance = .light, reduceMotion: Bool = false) throws -> [MenuBarScene.Glitter] {
        try #require(icon.scene(at: at(seconds), appearance: appearance, animation: MenuBarAnimation(), reduceMotion: reduceMotion)).glitter
    }

    private static let sweep = (0..<720).map { Double($0) / 12 + 0.01 }

    /// Renderer at t = 2 s, light bar: three specks, path M0 0.614 L0.686 1.3 L0 1.986 L-0.686 1.3.
    @Test func glitterMatchesTheRenderer() throws {
        let specks = try glitter(.working(count: 3), 2)
        #expect(close(specks.map(\.center), [(0, 1.3), (7.24, 2.38), (7.03, 9.31)]))
        #expect(close(specks[0].points, [(0, 0.614), (0.686, 1.3), (0, 1.986), (-0.686, 1.3)]))
        #expect(close(specks[1].radius, 0.512) && close(specks[2].radius, 0.673))
        #expect(specks.allSatisfy { $0.color == MenuBarScene.RGBA(hex: 0x5A2FD6) })
    }

    /// Renderer at t = 1 s, dark bar: white dust.
    @Test func darkGlitterIsWhite() throws {
        let specks = try glitter(.working(count: 3), 1, .dark)
        #expect(close(specks.map(\.center), [(0, 1.3), (7.03, 9.31)]))
        #expect(close(specks[0].radius, 0.58) && close(specks[1].radius, 0.609))
        #expect(specks.allSatisfy { $0.color == MenuBarScene.RGBA(hex: 0xFFFFFF) })
    }

    /// The badge corner stays clear of dust as of stars; below the badge it glitters.
    @Test(arguments: [MenuBarIcon.working(count: 3), .working(count: 42)])
    func noGlitterInTheBadgeCorner(icon: MenuBarIcon) throws {
        var rightOfCenter = false
        for seconds in Self.sweep {
            let specks = try glitter(icon, seconds)
            #expect(specks.count <= 22)
            for speck in specks {
                #expect(!(speck.center.x > 9 && speck.center.y < 12.6), "t = \(seconds)")
                #expect(speck.radius >= 0.15 && speck.radius <= 0.7 + 1e-9)
                if speck.center.x > 9 { rightOfCenter = true }
            }
        }
        #expect(rightOfCenter)
    }

    @Test func amberAndReduceMotionHaveNoGlitter() throws {
        for seconds in Self.sweep {
            #expect(try glitter(.needsPermission, seconds).isEmpty)
            #expect(try glitter(.needsPermission, seconds, .dark).isEmpty)
            #expect(try glitter(.working(count: 3), seconds, reduceMotion: true).isEmpty)
        }
    }
}

/// The background shell's glimmering cube. Reference values from the
/// design's renderer, its background-shell cube component with motion `glow`,
/// run in node at the given t.
@Suite struct MenuBarSceneGlimmerTests {
    private let shell = MenuBarIcon.backgroundShell

    private func scene(_ seconds: Double, _ appearance: MenuBarScene.Appearance = .light, reduceMotion: Bool = false) throws -> MenuBarScene {
        try #require(shell.scene(at: at(seconds), appearance: appearance, animation: MenuBarAnimation(), reduceMotion: reduceMotion))
    }

    private func opacities(_ frame: MenuBarScene) -> [Double] { frame.faces.map(\.color.alpha) }

    private func closeAll(_ a: [Double], _ b: [Double], _ within: Double = tolerance) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= within }
    }

    /// macOS tints it for the bar, highlight included: one image for light
    /// and dark, nothing colored, nothing on top of the cube.
    @Test(arguments: [0.0, 1, 1.6, 2.5, 781_000_000.123])
    func aTemplateCubeWithoutExtras(seconds: Double) throws {
        let frame = try scene(seconds)
        #expect(frame.isTemplate)
        #expect(frame.badge == nil)
        #expect(frame.sparkles.isEmpty && frame.glitter.isEmpty && frame.glow == nil)
        #expect(frame.yawDegrees == 45)
        #expect(try scene(seconds, .dark) == frame)
    }

    /// Ink only: black faces at an opacity, a full black outline for edges and grid.
    @Test func everythingIsDrawnInInk() throws {
        let frame = try scene(0)
        #expect(frame.faces.allSatisfy { $0.color.red == 0 && $0.color.green == 0 && $0.color.blue == 0 })
        #expect(frame.outline == MenuBarScene.RGBA(red: 0, green: 0, blue: 0))
        #expect(MenuBarScene.templateGridWidth == 0.636 && MenuBarScene.templateGridOpacity == 0.5)
    }

    /// The idle cube's geometry: corner-on, three faces, the same edges and grid.
    @Test func theGeometryIsTheCornerOnCube() throws {
        let frame = try scene(0)
        #expect(frame.faces.count == 3)
        #expect(close(frame.faces[0].points, [(15.8, 12.9), (15.8, 5.1), (9, 8.999), (9, 16.799)]))
        #expect(close(frame.faces[1].points, [(9, 1.201), (2.2, 5.1), (9, 8.999), (15.8, 5.1)]))
        #expect(close(frame.faces[2].points, [(2.2, 12.9), (9, 16.799), (9, 8.999), (2.2, 5.1)]))
        #expect(frame.edges.count == 12)
        #expect(close(frame.grid.flatMap { [$0.from, $0.to] }, [
            (15.8, 9), (9, 12.899), (12.4, 7.05), (12.4, 14.849), (5.6, 3.151), (12.4, 7.05),
            (5.6, 7.05), (12.4, 3.151), (5.6, 14.849), (5.6, 7.05), (9, 12.899), (2.2, 9),
        ]))
    }

    /// Frame 0 shows 40 % of the working shading (right 58 %, top 100 %,
    /// left 72 %), 1 s later less, at 1.6 s (between ticks 19 and 20) nothing.
    @Test func theFacesBreatheFromFortyPercentToNothing() throws {
        #expect(closeAll(opacities(try scene(0)), [0.232, 0.4, 0.288]))
        #expect(closeAll(opacities(try scene(1)), [0.072, 0.123, 0.089]))
        #expect(closeAll(opacities(try scene(19.0 / 12)), [0, 0, 0]))
        #expect(closeAll(opacities(try scene(20.0 / 12)), [0.001, 0.002, 0.001]))
    }

    /// 3.2 s per breath; 16 s (192 ticks) hold five whole ones.
    @Test func theBreathRepeatsEveryThreePointTwoSeconds() throws {
        #expect(closeAll(opacities(try scene(3.2)), [0.232, 0.4, 0.288], 0.002))
        for tick in [0, 5, 19, 100, 191] {
            let seconds = Double(tick) / 12
            #expect(try scene(seconds) == scene(seconds + 16), "tick \(tick)")
        }
        #expect(try scene(16_000_000) == scene(0))
    }

    /// Reduce Motion: one still frame at 30 % of the shading.
    @Test func reduceMotionIsOneStillFrame() throws {
        let still = try scene(1, reduceMotion: true)
        #expect(closeAll(opacities(still), [0.174, 0.3, 0.216]))
        #expect(still.isTemplate && still.badge == nil && still.yawDegrees == 45)
        for seconds in [0.0, 1.6, 781_000_000.123] {
            #expect(try scene(seconds, reduceMotion: true) == still)
        }
        #expect(shell.nextSceneChange(after: at(5), animation: MenuBarAnimation(), reduceMotion: true) == nil)
    }

    @Test func theColoredLooksAreNoTemplates() throws {
        for icon in [MenuBarIcon.working(count: 3), .needsPermission] {
            let frame = try #require(icon.scene(at: at(0), appearance: .light, animation: MenuBarAnimation(), reduceMotion: false))
            #expect(!frame.isTemplate)
            #expect(frame.badge != nil)
        }
    }
}
