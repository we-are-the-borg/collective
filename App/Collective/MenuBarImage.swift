import AppKit
import CollectiveKit
import CollectiveUI

/// The status item's image: idle and warning are template assets, which
/// macOS tints for the bar; working, needs permission and an open question are the colored cube
/// drawn for the bar's appearance; a background shell is a drawn
/// template cube, tinted like the assets. Every image is 22 × 18 pt, so the
/// status item never changes width between states.
@MainActor
enum MenuBarImage {
    /// Not cached: while animating every tick is a new frame, and a still frame
    /// (Reduce Motion, or a state the setting keeps still) is drawn again only
    /// when the state, the setting, the bar or the set of screen backing
    /// scales changes (a new screen needs its own pixels).
    /// Each frame is rendered once, for each of `scales` (see `screenScales`),
    /// so the bar on each screen gets native pixels.
    static func image(for icon: MenuBarIcon, at date: Date, appearance: NSAppearance, scales: [Double], animation: MenuBarAnimation, reduceMotion: Bool) -> NSImage? {
        if let scene = icon.scene(at: date, appearance: MenuBarScene.Appearance(appearance), animation: animation, reduceMotion: reduceMotion) {
            return MenuBarSceneImage.image(for: scene, scales: scales)
        }
        guard let name = icon.templateImageName, let image = NSImage(named: name) else {
            assertionFailure("Missing menu bar asset for \(icon)")
            return nil
        }
        return image
    }

    /// The distinct backing scales of the connected displays, sorted so two
    /// reads compare equal when nothing changed. The status item compares
    /// them to redraw when a display with a new scale arrives. Without a
    /// screen (headless, between reconfigurations) it falls back to Retina.
    static var screenScales: [Double] {
        let scales = Set(NSScreen.screens.map { Double($0.backingScaleFactor) })
        return scales.isEmpty ? [2] : scales.sorted()
    }
}
