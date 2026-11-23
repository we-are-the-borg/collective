import Foundation

/// One frame of the colored menu bar icon, as plain geometry the app
/// draws with Core Graphics. Everything lies in the 22 × 18 pt canvas of
/// `MenuBarIcon`, y down like the SVG.
///
/// Ported from the design's cube renderer (geometry, colors, timing). Working
/// is look nebula (motion drift, sparkles, badge L in color), needs permission
/// look amber (motion pulse, no sparkles, badge "?"), a background shell look
/// glimmer (motion glow, a template).
///
/// Drawing order, bottom to top: the cube group (faces with `edges` and `grid`
/// cut out of them, then the `hull` outline), all of it scaled by `cubeScale`
/// around `cubeCenter`; then the `sparkles` and on top of them the `glitter`,
/// untransformed. The badge knockout erases all of it. Then the badge shape
/// and its text. The `glow` is a shadow of the whole image.
///
/// A template (`isTemplate`) is drawn like the idle outline instead, all in
/// the cube transform: the faces, then the `grid` stroked in `outline` at
/// `templateGridOpacity` and `templateGridWidth`, then the `edges` in
/// `outline` at `edgeWidth`, with round caps and joins. Nothing is cut out
/// and the `hull` stays undrawn: the edges include it. macOS tints the image.
public struct MenuBarScene: Sendable, Equatable {
    /// The cube's turn: 45° shows it corner-on; drift moves on to 135°, which
    /// looks the same, then starts over.
    public let yawDegrees: Double
    /// Pulse strength, 0.5...1; 1 for a cube that doesn't pulse. For a
    /// glimmer the faces' share of the working shading, 0...0.4.
    public let intensity: Double
    /// Visible faces only. Cube space: draw them through the cube transform.
    public let faces: [Face]
    /// The face edges, erased from the faces at `edgeWidth` (cube space).
    public let edges: [Segment]
    /// The midlines that split each face in four, erased at `gridWidth` (cube space).
    public let grid: [Segment]
    /// The silhouette, stroked at `outlineWidth` with round joins (cube space).
    public let hull: [Point]
    public let outline: RGBA
    public let sparkles: [Sparkle]
    public let glitter: [Glitter]
    /// Nil for a template, which shows no number.
    public let badge: Badge?
    public let glow: Glow?
    /// Ink in black and alpha only, for macOS to tint like the template
    /// assets: the background shell, whose cube no color marks.
    public let isTemplate: Bool

    /// The cube transform: scaled by `cubeScale` around `cubeCenter`, line
    /// widths included.
    public static let cubeCenter = Point(x: 9, y: 9)
    public static let cubeScale = 1.1
    /// Round caps for edges and grid.
    public static let edgeWidth = 0.909
    public static let gridWidth = 0.591
    public static let outlineWidth = 0.909
    /// The grid of a template, stroked at half the ink as in the idle asset.
    public static let templateGridWidth = 0.636
    public static let templateGridOpacity = 0.5

    public struct Point: Sendable, Equatable {
        public let x: Double
        public let y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// A color in sRGB with its opacity, components in 0...1.
    public struct RGBA: Sendable, Equatable {
        public let red: Double
        public let green: Double
        public let blue: Double
        public let alpha: Double

        public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        /// CSS `#RRGGBB`.
        public init(hex: UInt32, alpha: Double = 1) {
            self.init(
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255,
                alpha: alpha
            )
        }

        /// CSS `hsl(h s% l% / a)`: hue in degrees, saturation and lightness in
        /// percent, as the design writes them. The CSS Color 4 algorithm.
        public init(hue: Double, saturation: Double, lightness: Double, alpha: Double = 1) {
            let s = saturation / 100, l = lightness / 100
            let a = s * min(l, 1 - l)
            func channel(_ n: Double) -> Double {
                let k = (n + hue / 30).truncatingRemainder(dividingBy: 12)
                return l - a * max(-1, min(k - 3, 9 - k, 1))
            }
            self.init(red: channel(0), green: channel(8), blue: channel(4), alpha: alpha)
        }
    }
}

extension MenuBarScene {
    /// The menu bar's appearance; the looks pick brighter outlines, other
    /// sparkle colors and a glow on a dark bar.
    public enum Appearance: Sendable, Equatable {
        case light
        case dark
    }

    /// A visible cube face, `color.alpha` is its fill opacity.
    public struct Face: Sendable, Equatable {
        public let points: [Point]
        public let color: RGBA
    }

    public struct Segment: Sendable, Equatable {
        public let from: Point
        public let to: Point
    }

    /// A four-pointed star around the cube, in canvas coordinates.
    public struct Sparkle: Sendable, Equatable {
        public let center: Point
        public let radius: Double
        public let color: RGBA

        /// Clockwise from the top tip; the waist sits at 0.3 of the radius.
        public var points: [Point] {
            let x = center.x, y = center.y, r = radius, w = radius * 0.3
            return [
                Point(x: x, y: y - r), Point(x: x + w, y: y - w), Point(x: x + r, y: y), Point(x: x + w, y: y + w),
                Point(x: x, y: y + r), Point(x: x - w, y: y + w), Point(x: x - r, y: y), Point(x: x - w, y: y - w),
            ]
        }
    }

    /// A speck of glitter dust, a diamond in canvas coordinates.
    public struct Glitter: Sendable, Equatable {
        public let center: Point
        public let radius: Double
        public let color: RGBA

        /// Clockwise from the top tip.
        public var points: [Point] {
            let x = center.x, y = center.y, r = radius
            return [Point(x: x, y: y - r), Point(x: x + r, y: y), Point(x: x, y: y + r), Point(x: x - r, y: y)]
        }
    }

    public struct Badge: Sendable, Equatable {
        public enum Shape: Sendable, Equatable {
            case circle(center: Point, radius: Double)
            /// Fully rounded: the corner radius is half the height.
            case pill(x: Double, y: Double, width: Double, height: Double)
        }

        public let shape: Shape
        /// The shape grown by `knockoutGrowth`, erased from cube, sparkles and glitter
        /// so the badge stands free.
        public let knockout: Shape
        public let fill: RGBA
        public let text: String
        public let textColor: RGBA
        /// SF Pro Rounded, bold.
        public let fontSize: Double
        /// The text is centered on this x, with its baseline at `baseline`.
        public let textCenterX: Double
        public let baseline: Double

        public static let knockoutGrowth = 1.1
    }

    /// A shadow of the whole image without offset.
    public struct Glow: Sendable, Equatable {
        public let color: RGBA
        /// The blur radius in points as CSS `drop-shadow` takes it: the
        /// Gaussian's standard deviation is half of it.
        public let radius: Double
    }
}

extension MenuBarScene {
    /// The amber of an open permission request, shared with the popover card
    /// so menu bar and card cannot drift apart.
    public static let permissionAmber = RGBA(hex: 0xFF9F0A)
    /// The "?" on the amber badge.
    public static let permissionGlyph = RGBA(hex: 0x3A2200)

    /// The two colored looks and the template of the background shell. Each comes with its motion: nebula
    /// drifts and sparkles, amber pulses, glimmer breathes its faces in.
    enum Look: Sendable {
        case nebula
        case amber
        case glimmer
    }

    /// The scene clock runs at 24 ticks a second, so 12, 8 and 4 fps each
    /// sample it on whole ticks and the motion keeps its speed.
    static let ticksPerSecond = 24

    /// `tick` counts 1/24 s from the reference date; nil is the still frame,
    /// the one Reduce Motion shows. No `badgeText`, no badge, as for the glimmer.
    init(look: Look, badgeText: String?, tick: Int?, appearance: Appearance) {
        // The glimmer's still frame shows 30 % of the shading.
        var yaw = 45.0, k = look == .glimmer ? 0.3 : 1.0
        if let tick {
            switch look {
            case .nebula:
                // Drift: a quarter turn in 4 s (96 ticks) with cosine easing, no rest.
                let u = Double(Self.modulo(tick, 96)) / 96
                yaw = 45 + 90 * (0.5 - 0.5 * cos(.pi * u))
            case .amber:
                // Pulse every 1.4 s; 168 ticks (7 s) hold whole periods, which
                // keeps the cosine's argument small far from the reference date.
                let t = Double(Self.modulo(tick, 168)) / Double(Self.ticksPerSecond)
                k = 0.5 + 0.5 * (0.5 + 0.5 * cos(2 * .pi * t / 1.4))
            case .glimmer:
                // 3.2 s per breath from 40 % to nothing and back, no rest;
                // 384 ticks (16 s) hold five whole ones, as for the pulse.
                let t = Double(Self.modulo(tick, 384)) / Double(Self.ticksPerSecond)
                k = 0.2 + 0.2 * cos(2 * .pi * t / 3.2)
            }
        }
        yawDegrees = yaw
        intensity = k

        // Isometric pitch of 35.26°; the cube spans ±1 and projects at 4.808 pt
        // across, 4.776 pt up, centered on (9 | 9).
        let radians = Double.pi / 180
        let cp = cos(35.26 * radians), sp = sin(35.26 * radians)
        let c = cos(yaw * radians), s = sin(yaw * radians)
        func rotate(_ v: Vector) -> Vector {
            let x1 = v.x * c - v.z * s, z1 = v.x * s + v.z * c
            return Vector(x: x1, y: v.y * cp - z1 * sp, z: v.y * sp + z1 * cp)
        }
        func project(_ v: Vector) -> Point {
            let r = rotate(v)
            return Point(x: 9 + r.x * 4.808, y: 9 - r.y * 4.776)
        }
        func mid(_ a: Point, _ b: Point) -> Point { Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

        var faces: [Face] = [], edges: [Segment] = [], grid: [Segment] = []
        faces.reserveCapacity(3)
        edges.reserveCapacity(12)
        grid.reserveCapacity(6)
        for (index, face) in Self.cubeFaces.enumerated() {
            let n = rotate(face.normal)
            guard n.z > 0.002 else { continue }
            let light = n.x * Self.light.x + n.y * Self.light.y + n.z * Self.light.z
            let opacity = min(1, max(0.4, 0.58 + (light + 0.096) * 0.397))
            let p = face.corners.map(project)
            for j in 0..<4 { edges.append(Segment(from: p[j], to: p[(j + 1) % 4])) }
            grid.append(Segment(from: mid(p[0], p[1]), to: mid(p[2], p[3])))
            grid.append(Segment(from: mid(p[1], p[2]), to: mid(p[3], p[0])))
            faces.append(Face(points: p, color: look.faceColor(faceIndex: index, opacity: opacity, intensity: k)))
        }
        self.faces = faces
        self.edges = edges
        self.grid = grid
        hull = Self.convexHull(Self.cubeCorners.map(project))
        outline = look.outline(appearance)

        sparkles = tick.map { look.sparkles(atTick: $0, appearance: appearance) } ?? []
        glitter = tick.map { look.glitter(atTick: $0, appearance: appearance) } ?? []
        badge = badgeText.map(look.badge(text:))
        glow = look.glow(appearance, intensity: k)
        isTemplate = look == .glimmer
    }

    // MARK: Cube

    private struct Vector {
        let x: Double, y: Double, z: Double
    }

    private static let cubeFaces: [(normal: Vector, corners: [Vector])] = [
        (Vector(x: 1, y: 0, z: 0), [Vector(x: 1, y: -1, z: -1), Vector(x: 1, y: 1, z: -1), Vector(x: 1, y: 1, z: 1), Vector(x: 1, y: -1, z: 1)]),
        (Vector(x: -1, y: 0, z: 0), [Vector(x: -1, y: -1, z: -1), Vector(x: -1, y: -1, z: 1), Vector(x: -1, y: 1, z: 1), Vector(x: -1, y: 1, z: -1)]),
        (Vector(x: 0, y: 1, z: 0), [Vector(x: -1, y: 1, z: -1), Vector(x: -1, y: 1, z: 1), Vector(x: 1, y: 1, z: 1), Vector(x: 1, y: 1, z: -1)]),
        (Vector(x: 0, y: -1, z: 0), [Vector(x: -1, y: -1, z: -1), Vector(x: 1, y: -1, z: -1), Vector(x: 1, y: -1, z: 1), Vector(x: -1, y: -1, z: 1)]),
        (Vector(x: 0, y: 0, z: 1), [Vector(x: -1, y: -1, z: 1), Vector(x: 1, y: -1, z: 1), Vector(x: 1, y: 1, z: 1), Vector(x: -1, y: 1, z: 1)]),
        (Vector(x: 0, y: 0, z: -1), [Vector(x: -1, y: -1, z: -1), Vector(x: -1, y: 1, z: -1), Vector(x: 1, y: 1, z: -1), Vector(x: 1, y: -1, z: -1)]),
    ]

    private static let cubeCorners: [Vector] = [-1.0, 1].flatMap { x in
        [-1.0, 1].flatMap { y in [-1.0, 1].map { z in Vector(x: x, y: y, z: z) } }
    }

    /// Light from the upper left front, normalized.
    private static let light: Vector = {
        let length = (0.25 * 0.25 + 0.72 * 0.72 + 0.65 * 0.65).squareRoot()
        return Vector(x: -0.25 / length, y: 0.72 / length, z: 0.65 / length)
    }()

    /// Monotone chain, as the renderer does it: collinear points drop out.
    private static func convexHull(_ points: [Point]) -> [Point] {
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        func cross(_ o: Point, _ a: Point, _ b: Point) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        func chain(_ points: some Sequence<Point>) -> [Point] {
            var result: [Point] = []
            for p in points {
                while result.count >= 2, cross(result[result.count - 2], result[result.count - 1], p) <= 0 { result.removeLast() }
                result.append(p)
            }
            return result
        }
        return chain(sorted).dropLast() + chain(sorted.reversed()).dropLast()
    }

    private static func modulo(_ value: Int, _ divisor: Int) -> Int {
        ((value % divisor) + divisor) % divisor
    }

    /// JavaScript's `Math.round`, which the design uses for lightness: halves round up.
    fileprivate static func jsRound(_ value: Double) -> Double {
        (value + 0.5).rounded(.down)
    }

    // MARK: Badge

    /// Size L: circle at (16.5 | 5.5), r 5.5; two
    /// characters as a pill from x 9.5, 12.5 wide, 11 high.
    fileprivate static let badgeCenter = Point(x: 16.5, y: 5.5)
    fileprivate static let badgeRadius = 5.5
    fileprivate static let pillX = 9.5
    fileprivate static let pillWidth = 12.5
    fileprivate static let badgeFontSize = 9.0

    fileprivate static func badgeShape(wide: Bool, grow: Double) -> Badge.Shape {
        guard wide else { return .circle(center: badgeCenter, radius: badgeRadius + grow) }
        return .pill(x: pillX - grow, y: -grow, width: pillWidth + 2 * grow, height: 2 * badgeRadius + 2 * grow)
    }

    // MARK: Sparkles

    /// x, y, period (s), phase (s), size, color index: the renderer's ten
    /// stars plus the six nebula adds. Each star flares for `starLifetime` per
    /// period, its size grown by `starGrowth`.
    fileprivate static let stars: [(x: Double, y: Double, period: Double, phase: Double, size: Double, color: Int)] = [
        (3.2, 3.4, 2.9, 0.0, 1.7, 0), (1.6, 11.2, 3.7, 1.1, 1.4, 1), (6.4, 15.9, 3.1, 2.0, 1.6, 2),
        (14.6, 15.7, 4.1, 0.5, 1.5, 0), (20.2, 12.4, 3.3, 1.6, 1.8, 1), (12.8, 6.8, 3.9, 2.6, 1.3, 2),
        (5.6, 7.4, 4.6, 3.1, 1.4, 0), (19.8, 3.0, 3.5, 0.8, 1.7, 2), (9.0, 10.2, 5.2, 1.9, 1.2, 1),
        (16.4, 1.8, 4.4, 2.3, 1.4, 0),
        (2.4, 6.8, 2.6, 0.4, 1.9, 1), (11.2, 16.6, 2.8, 1.4, 1.7, 2), (17.8, 16.2, 3.0, 2.2, 1.9, 0),
        (7.6, 2.0, 2.4, 1.7, 1.6, 1), (0.9, 15.6, 3.4, 0.9, 1.5, 2), (21.0, 8.4, 2.7, 0.2, 1.6, 0),
    ]
    fileprivate static let starLifetime = 0.75
    fileprivate static let starGrowth = 1.35
    /// Glitter dust: 22 specks spread over the canvas, each showing for 0.35 s
    /// of a 1.6 s cycle that runs 1.7 times as fast as the clock.
    fileprivate static let glitterCount = 22
    /// Stars and glitter right of x 9 and above y 12.6 would sit in the L badge's corner.
    fileprivate static let badgeCornerX = 9.0
    fileprivate static let badgeCornerY = 12.6
}

extension MenuBarScene.Look {
    private typealias RGBA = MenuBarScene.RGBA

    private static let nebulaHues: [Double] = [266, 254, 280, 260, 248, 286]

    func faceColor(faceIndex: Int, opacity o: Double, intensity k: Double) -> MenuBarScene.RGBA {
        switch self {
        case .nebula:
            RGBA(hue: Self.nebulaHues[faceIndex], saturation: 72, lightness: MenuBarScene.jsRound(28 + 38 * o))
        case .amber:
            RGBA(hue: 36, saturation: 100, lightness: MenuBarScene.jsRound((24 + 36 * o) * (0.55 + 0.45 * k)))
        case .glimmer:
            RGBA(red: 0, green: 0, blue: 0, alpha: o * k)
        }
    }

    func outline(_ appearance: MenuBarScene.Appearance) -> MenuBarScene.RGBA {
        switch (self, appearance) {
        case (.nebula, .light): RGBA(hue: 262, saturation: 70, lightness: 30, alpha: 0.95)
        case (.nebula, .dark): RGBA(hue: 268, saturation: 100, lightness: 84, alpha: 0.95)
        case (.amber, .light): RGBA(hue: 30, saturation: 100, lightness: 30, alpha: 0.95)
        case (.amber, .dark): RGBA(hue: 40, saturation: 100, lightness: 72, alpha: 0.95)
        case (.glimmer, _): RGBA(red: 0, green: 0, blue: 0)
        }
    }

    func glow(_ appearance: MenuBarScene.Appearance, intensity k: Double) -> MenuBarScene.Glow? {
        switch (self, appearance) {
        case (.nebula, .light): nil
        case (.nebula, .dark): MenuBarScene.Glow(color: RGBA(hue: 275, saturation: 100, lightness: 70, alpha: 0.65), radius: 0.9)
        case (.amber, _): MenuBarScene.Glow(color: RGBA(hue: 36, saturation: 100, lightness: 55, alpha: 0.85 * k), radius: 1.4 * k)
        case (.glimmer, _): nil
        }
    }

    func badge(text: String) -> MenuBarScene.Badge {
        let wide = text.count > 1
        let center = MenuBarScene.badgeCenter
        return MenuBarScene.Badge(
            shape: MenuBarScene.badgeShape(wide: wide, grow: 0),
            knockout: MenuBarScene.badgeShape(wide: wide, grow: MenuBarScene.Badge.knockoutGrowth),
            fill: self == .nebula ? RGBA(hex: 0x6A3FE8) : MenuBarScene.permissionAmber,
            text: text,
            textColor: self == .nebula ? RGBA(hex: 0xFFFFFF) : MenuBarScene.permissionGlyph,
            fontSize: MenuBarScene.badgeFontSize,
            textCenterX: wide ? MenuBarScene.pillX + MenuBarScene.pillWidth / 2 : center.x,
            // The pill's middle is its radius from the top, the same as the circle's center for L.
            baseline: (wide ? MenuBarScene.badgeRadius : center.y) + MenuBarScene.badgeFontSize * 0.36
        )
    }

    /// Grouped by color in palette order, so later colors lie on top as in the design.
    func sparkles(atTick tick: Int, appearance: MenuBarScene.Appearance) -> [MenuBarScene.Sparkle] {
        guard self == .nebula else { return [] }
        let palette = appearance == .dark
            ? [RGBA(hex: 0xFFFFFF), RGBA(hex: 0xFFE27A), RGBA(hex: 0xFFB8F0)]
            : [RGBA(hex: 0x7B4DFF), RGBA(hex: 0xD99A00), RGBA(hex: 0xD63FB0)]
        let t = Double(tick) / Double(MenuBarScene.ticksPerSecond)
        var result: [MenuBarScene.Sparkle] = []
        for colorIndex in palette.indices {
            for star in MenuBarScene.stars where star.color == colorIndex {
                if star.x > MenuBarScene.badgeCornerX && star.y < MenuBarScene.badgeCornerY { continue }
                var cycle = (t + star.phase).truncatingRemainder(dividingBy: star.period)
                if cycle < 0 { cycle += star.period }
                let p = cycle / MenuBarScene.starLifetime
                guard p < 1 else { continue }
                let r = star.size * MenuBarScene.starGrowth * sin(.pi * p)
                guard r > 0.15 else { continue }
                result.append(MenuBarScene.Sparkle(center: MenuBarScene.Point(x: star.x, y: star.y), radius: r, color: palette[colorIndex]))
            }
        }
        return result
    }

    /// In the order of the renderer's loop; drawn above all sparkles.
    func glitter(atTick tick: Int, appearance: MenuBarScene.Appearance) -> [MenuBarScene.Glitter] {
        guard self == .nebula else { return [] }
        let color = appearance == .dark ? RGBA(hex: 0xFFFFFF) : RGBA(hex: 0x5A2FD6)
        let t = Double(tick) / Double(MenuBarScene.ticksPerSecond)
        var result: [MenuBarScene.Glitter] = []
        for index in 0..<MenuBarScene.glitterCount {
            let i = Double(index)
            let x = (i * 7.31).truncatingRemainder(dividingBy: 22), y = (i * 4.77 + 1.3).truncatingRemainder(dividingBy: 18)
            if x > MenuBarScene.badgeCornerX && y < MenuBarScene.badgeCornerY { continue }
            var cycle = (t * 1.7 + i * 0.37).truncatingRemainder(dividingBy: 1.6)
            if cycle < 0 { cycle += 1.6 }
            let p = cycle / 0.35
            guard p < 1 else { continue }
            result.append(MenuBarScene.Glitter(center: MenuBarScene.Point(x: x, y: y), radius: 0.55 * sin(.pi * p) + 0.15, color: color))
        }
        return result
    }
}
