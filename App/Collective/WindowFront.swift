import AppKit
import os
import SwiftUI

extension OpenWindowAction {
    /// Opens the `Window` scene `id` and brings it in front of the frontmost
    /// app, whether it was closed, open but covered, minimized or on another
    /// Space.
    ///
    /// An `LSUIElement` app is not active on its own, and opening a window does
    /// not activate it, so the window lands behind the frontmost app. The
    /// cooperative `activate()` is not enough: neither the popover nor the
    /// first launch makes the frontmost app yield, so the request is refused.
    /// Even the forced activation can lose a race: the popover closes after
    /// the click and the system hands focus back to the app that had it before
    /// (Xcode right after a launch from it). So the window is ordered front
    /// again on the following run-loop turns, until the app is active and the
    /// window key; `orderFrontRegardless()` puts it on top even if activation
    /// is refused for good.
    ///
    /// The setup and the settings window turn the app regular first
    /// (`DockPresence`), so the activation that follows brings the Dock icon
    /// and the menu bar along.
    func bringToFront(id: String) {
        DockPresence.opened(id)
        NSApp.activate(ignoringOtherApps: true)
        self(id: id)
        Task { @MainActor in
            // SwiftUI creates the window and dismisses the popover
            // asynchronously; ten tries over half a second covers both.
            for _ in 0..<10 {
                if let window = Self.window(for: id) {
                    if window.isMiniaturized { window.deminiaturize(nil) }
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    if NSApp.isActive, window.isKeyWindow { return }
                }
                try? await Task.sleep(for: .milliseconds(50))
                NSApp.activate(ignoringOtherApps: true)
            }
            if Self.window(for: id) == nil {
                Self.log.error("No window found for scene \(id, privacy: .public)")
                DockPresence.closed(id)
            }
        }
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Collective", category: "Windows")

    @MainActor
    private static func window(for id: String) -> NSWindow? {
        NSApp.windows.first { $0.belongs(toScene: id) }
    }
}

extension NSWindow {
    /// SwiftUI names a scene's window after the scene id, for windows that can
    /// exist more than once with a suffix (`settings-AppWindow-1`).
    func belongs(toScene id: String) -> Bool {
        guard let identifier = identifier?.rawValue else { return false }
        return identifier == id || identifier.hasPrefix("\(id)-")
    }
}
