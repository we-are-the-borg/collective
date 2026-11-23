import AppKit
import CollectiveKit

/// While the setup or the settings window is open the app is regular, with a
/// Dock icon, ⌘Tab and its menu bar, so a window that slipped behind another
/// app's can be found again; once both are closed it is a menu bar app again.
/// The popover does not count. `LSUIElement` stays set, so the app launches
/// as an accessory.
@MainActor
enum DockPresence {
    /// The scenes whose windows count.
    private static let sceneIDs = [SetupWindow.id, SettingsWindow.id]
    private static var presence = WindowPresence(counting: Set(sceneIDs))
    private static var closeObserver: (any NSObjectProtocol)?

    /// `bringToFront(id:)` calls this before it opens the window, so the
    /// window comes up with the Dock icon and the menu bar instead of the app
    /// turning regular under it. The window's content calls it again as it
    /// appears, which covers SwiftUI opening it by itself (the Window menu);
    /// a second call changes nothing. Other scene ids are ignored.
    static func opened(_ id: String) {
        guard sceneIDs.contains(id) else { return }
        observeCloses()
        presence.opened(id)
        follow()
    }

    /// Undoes `opened(_:)` when no window came up, so the app does not stay
    /// regular with a Dock icon and nothing to show.
    static func closed(_ id: String) {
        guard sceneIDs.contains(id) else { return }
        presence.closed(id)
        follow()
    }

    /// The window's own close, not its content's disappearance: AppKit posts
    /// it for the close button, ⌘W and `dismissWindow` alike.
    private static func observeCloses() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: nil
        ) { notification in
            // No queue: the block runs synchronously on the posting thread
            // (AppKit posts on main), while the window is still there.
            // Only a Sendable handle crosses into the main actor.
            guard let closing = (notification.object as AnyObject?).map(ObjectIdentifier.init) else { return }
            MainActor.assumeIsolated {
                guard let window = NSApp.windows.first(where: { ObjectIdentifier($0) == closing }),
                      let id = sceneIDs.first(where: window.belongs(toScene:))
                else { return }
                presence.closed(id)
                follow()
            }
        }
    }

    private static func follow() {
        let policy: NSApplication.ActivationPolicy = presence.showsInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// A click on the Dock icon: brings the open windows forward. Returns
    /// whether there was one, so the app opens nothing else.
    static func raiseOpenWindows() -> Bool {
        let windows = NSApp.windows.filter { window in presence.open.contains { window.belongs(toScene: $0) } }
        guard !windows.isEmpty else { return false }
        NSApp.activate(ignoringOtherApps: true)
        for window in windows {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
