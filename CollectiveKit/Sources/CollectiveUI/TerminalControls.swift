import AppKit
import CollectiveKit
import SwiftUI

// "Show in <App>" on rows: the menus, VoiceOver and ⌘↩;
// the row draws its jump button itself.

/// Icons by bundle ID: the popover rebuilds its rows on every model change,
/// and a lookup goes through Launch Services.
@MainActor
enum TerminalAppIcons {
    private static var cache: [String: NSImage?] = [:]

    static func icon(bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = icon
        return icon
    }

    /// A 16 pt copy for the context menu, which draws an image at its own size.
    static func menuIcon(bundleID: String) -> NSImage? {
        guard let icon = icon(bundleID: bundleID)?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}

/// The context menu's first entry, with ⌘↩ shown; its own divider follows.
struct TerminalMenuItems: View {
    let action: TerminalAction?
    let onShow: () -> Void

    var body: some View {
        if let action {
            Button(action: onShow) {
                Label {
                    Text(action.title)
                } icon: {
                    if action.appName != nil, let icon = TerminalAppIcons.menuIcon(bundleID: action.bundleID) {
                        Image(nsImage: icon)
                    } else {
                        Image(systemName: "terminal")
                    }
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            Divider()
        }
    }
}

extension View {
    /// VoiceOver's "Show in Warp" on a card or row; nothing without an action.
    func terminalAccessibilityAction(_ action: TerminalAction?, show: @escaping () -> Void) -> some View {
        accessibilityActions {
            if let action {
                Button(action: show) { Text(action.title) }
            }
        }
    }
}
