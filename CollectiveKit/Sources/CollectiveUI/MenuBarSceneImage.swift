import AppKit
import CollectiveKit

/// Draws a `MenuBarScene` with Core Graphics: the colored cube of the
/// menu bar for working and needs permission. Follows the SVG of the design's
/// cube icon step by step; its masks become destination-out inside
/// transparency layers. A template scene, the background shell's glimmer,
/// follows the SVG of the design's shell cube.
public enum MenuBarSceneImage {
    /// A colored image on the 22 × 18 pt canvas, or a template for a
    /// template scene, with one bitmap per backing scale, so every screen
    /// gets native pixels. Drawn once, not in a drawing handler: AppKit draws
    /// a status item's image several times per frame, and a handler would
    /// run the scene's layers and glow blur each time.
    public static func image(for scene: MenuBarScene, scales: [Double]) -> NSImage {
        let size = NSSize(width: MenuBarIcon.canvasWidth, height: MenuBarIcon.canvasHeight)
        let image = NSImage(size: size)
        for scale in scales {
            if let rep = bitmap(of: scene, size: size, scale: scale) { image.addRepresentation(rep) }
        }
        image.isTemplate = scene.isTemplate
        return image
    }

    /// Tagged sRGB, the space the scene's colors are given in, so the screen
    /// matches them as it did when the scene was drawn straight to it.
    private static func bitmap(of scene: MenuBarScene, size: NSSize, scale: Double) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()), pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )?.retagging(with: .sRGB) else { return nil }
        // In points, so the glow's blur scales with the pixels (see `draw`).
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
        // Flipped, so canvas coordinates go in as the SVG writes them, y down.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        draw(scene, in: context)
        return rep
    }

    /// Draws into a context whose user space is the canvas, y down.
    ///
    /// The glow is CSS `drop-shadow(0 0 r color)` on the whole icon, a Gaussian
    /// with σ = r / 2. A Core Graphics shadow blur of b gives σ ≈ b / 2 in user
    /// space, measured on a 1× and a 2× bitmap (an edge's falloff: σ 3.85 and
    /// 3.78 pt for b = 8), so the radius goes in unchanged. The shadow falls
    /// outside the 22 × 18 canvas where the badge touches its edge; the image
    /// clips it there, as the design's `overflow: hidden` does not.
    public static func draw(_ scene: MenuBarScene, in context: CGContext) {
        guard !scene.isTemplate else {
            drawTemplate(scene, in: context)
            return
        }
        context.saveGState()
        defer { context.restoreGState() }
        if let glow = scene.glow {
            context.setShadow(offset: .zero, blur: glow.radius, color: cgColor(glow.color))
        }
        // One layer for everything: the shadow then falls from the finished
        // icon, and the knockouts below erase only what this layer holds, never
        // what lies under the image.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        drawCube(scene, in: context)
        for sparkle in scene.sparkles {
            context.setFillColor(cgColor(sparkle.color))
            context.addLines(between: sparkle.points.map(cgPoint))
            context.closePath()
            context.fillPath()
        }
        // The design's fourth star layer, so the dust lies on top of the stars.
        for speck in scene.glitter {
            context.setFillColor(cgColor(speck.color))
            context.addLines(between: speck.points.map(cgPoint))
            context.closePath()
            context.fillPath()
        }
        if let badge = scene.badge {
            context.setBlendMode(.destinationOut)
            context.addPath(path(badge.knockout))
            context.fillPath()
            context.setBlendMode(.normal)
            context.setFillColor(cgColor(badge.fill))
            context.addPath(path(badge.shape))
            context.fillPath()
            drawText(of: badge, in: context)
        }
        context.endTransparencyLayer()
    }

    /// Faces, then grid, then edges, painted over each other with nothing cut
    /// out, as the idle asset is.
    private static func drawTemplate(_ scene: MenuBarScene, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        applyCubeTransform(to: context)
        for face in scene.faces {
            context.setFillColor(cgColor(face.color))
            context.addLines(between: face.points.map(cgPoint))
            context.closePath()
            context.fillPath()
        }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let ink = scene.outline
        context.setStrokeColor(cgColor(MenuBarScene.RGBA(
            red: ink.red, green: ink.green, blue: ink.blue, alpha: ink.alpha * MenuBarScene.templateGridOpacity
        )))
        stroke(scene.grid, width: MenuBarScene.templateGridWidth, in: context)
        context.setStrokeColor(cgColor(ink))
        stroke(scene.edges, width: MenuBarScene.edgeWidth, in: context)
    }

    /// Scales by `cubeScale` around `cubeCenter`, line widths included.
    private static func applyCubeTransform(to context: CGContext) {
        let center = MenuBarScene.cubeCenter, scale = MenuBarScene.cubeScale
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -center.x, y: -center.y)
    }

    /// Faces with edges and grid cut out of them, in a layer of their own so
    /// the cuts stay inside the faces; then the hull on top.
    private static func drawCube(_ scene: MenuBarScene, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        applyCubeTransform(to: context)

        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for face in scene.faces {
            context.setFillColor(cgColor(face.color))
            context.addLines(between: face.points.map(cgPoint))
            context.closePath()
            context.fillPath()
        }
        context.setBlendMode(.destinationOut)
        context.setLineCap(.round)
        context.setStrokeColor(.black)
        stroke(scene.edges, width: MenuBarScene.edgeWidth, in: context)
        stroke(scene.grid, width: MenuBarScene.gridWidth, in: context)
        context.endTransparencyLayer()

        context.setBlendMode(.normal)
        context.setStrokeColor(cgColor(scene.outline))
        context.setLineWidth(MenuBarScene.outlineWidth)
        context.setLineJoin(.round)
        context.addLines(between: scene.hull.map(cgPoint))
        context.closePath()
        context.strokePath()
    }

    private static func stroke(_ segments: [MenuBarScene.Segment], width: Double, in context: CGContext) {
        context.setLineWidth(width)
        for segment in segments {
            context.move(to: cgPoint(segment.from))
            context.addLine(to: cgPoint(segment.to))
        }
        context.strokePath()
    }

    /// SF Pro Rounded Bold, centered on `textCenterX` by its advance like SVG's
    /// `text-anchor="middle"`, baseline at `baseline`.
    private static func drawText(of badge: MenuBarScene.Badge, in context: CGContext) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: badge.text, attributes: [
            .font: badgeFont(size: badge.fontSize),
            // Core Text reads a CGColor under this key.
            .foregroundColor: cgColor(badge.textColor),
        ]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.saveGState()
        // The canvas is flipped; glyphs need an unflipped text matrix to stand upright.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: badge.textCenterX - width / 2, y: badge.baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func badgeFont(size: Double) -> NSFont {
        let bold = NSFont.systemFont(ofSize: size, weight: .bold)
        guard let rounded = bold.fontDescriptor.withDesign(.rounded) else { return bold }
        return NSFont(descriptor: rounded, size: size) ?? bold
    }

    private static func path(_ shape: MenuBarScene.Badge.Shape) -> CGPath {
        switch shape {
        case let .circle(center, radius):
            CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius), transform: nil)
        case let .pill(x, y, width, height):
            CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
        }
    }

    private static func cgPoint(_ point: MenuBarScene.Point) -> CGPoint {
        CGPoint(x: point.x, y: point.y)
    }

    private static func cgColor(_ color: MenuBarScene.RGBA) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

extension MenuBarScene.Appearance {
    /// The menu bar's own appearance, which follows the wallpaper rather than
    /// the system setting; vibrant and high-contrast variants match their base.
    public init(_ appearance: NSAppearance) {
        self = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}
