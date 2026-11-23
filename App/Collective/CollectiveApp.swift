import CollectiveKit
import CollectiveUI
import SwiftUI

@main
struct CollectiveApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    // No `.commandsRemoved()` on the scenes: on every scene it would take the
    // standard menus with it, and with them ⌘C, ⌘V, ⌘Z and ⌘A in the settings'
    // text fields and ⌘C in the popover's text, and ⌘Q and ⌘W from the menu
    // bar the app has while one of its windows is open (`DockPresence`).
    var body: some Scene {
        Window(SetupWindowView.title, id: SetupWindow.id) {
            SetupWindowContent(model: appDelegate.model)
                .themedFromDefaults()
        }
        // The view draws its own title bar and places the traffic lights in it (`WindowTitleBar`).
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        // Opens only when asked: from the popover, the icon menu, or once at the first launch.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window(SettingsView.title, id: SettingsWindow.id) {
            SettingsWindowContent(model: appDelegate.model, themes: .shared)
                .themedFromDefaults()
        }
        // The view draws its own title bar and places the traffic lights in it (`WindowTitleBar`).
        .windowStyle(.hiddenTitleBar)
        // The view's frame: fixed width, resizable height.
        .windowResizability(.contentSize)
        // Opens only from the popover and the icon menu.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            // There is only one About, the settings pane; the standard panel
            // would show "1.0.0 (1.0.0)", where a build number belongs only when it differs.
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
            }
        }
    }
}

/// A view, because only a view gets the `openWindow` action from the environment.
private struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(AppMenuText.about) { openWindow.openSettingsWindow(on: .about) }
    }
}

/// Owns the model and the status item, which is AppKit's.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = CollectiveModel()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything themed shows: the folder is read once here, then followed.
        ThemeCatalogStore.shared.start()
        // Before the model reads anything it could notify of.
        // A click brings the session's terminal forward if it can come, else the popover.
        // Either way the click read the session.
        model.notifier.onOpen = { [weak self] key in
            guard let self else { return }
            if let key { model.markTurnRead(key) }
            if let key, model.showTerminal(key) { return }
            statusItem?.openPopover()
        }
        model.onTerminalShown = { [weak self] in self?.statusItem?.closePopover() }
        model.notifier.start()
        model.start()
        statusItem = StatusItemController(model: model)
    }

    /// A menu bar app: closing the setup or settings window leaves it running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The Dock icon exists only while setup or settings is open; a click
    /// brings that window back instead of letting SwiftUI open a new one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !DockPresence.raiseOpenWindows()
    }
}
