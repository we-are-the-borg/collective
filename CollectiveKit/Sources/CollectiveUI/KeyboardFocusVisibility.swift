import AppKit
import SwiftUI

/// Sets `isKeyboardFocusVisible` on any key press and clears it on any mouse press, so
/// focus rings are for keyboard users only (like CSS `:focus-visible`); clicks and opening
/// the popover give focus without a ring. The monitor never consumes events.
/// It also publishes the system's keyboard navigation setting, read here on the main
/// actor rather than in the nonisolated environment getter; refreshed on each key press,
/// so toggling it while the popover is open counts from the next key.
private struct KeyboardUseTracker: ViewModifier {
    @State private var keyboardUsed = false
    @State private var fullKeyboardAccess = false
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .environment(\.isKeyboardFocusVisible, keyboardUsed)
            .environment(\.isFullKeyboardAccessEnabled, fullKeyboardAccess)
            .onAppear {
                fullKeyboardAccess = NSApp.isFullKeyboardAccessEnabled
                guard monitor == nil else { return }
                let flag = $keyboardUsed
                let access = $fullKeyboardAccess
                monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
                ) { event in
                    let isKey = event.type == .keyDown
                    // Local monitors run on the main thread.
                    MainActor.assumeIsolated {
                        flag.wrappedValue = isKey
                        if isKey { access.wrappedValue = NSApp.isFullKeyboardAccessEnabled }
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

extension View {
    /// Once around the whole popover, so the rows and every button read the same flag.
    func tracksKeyboardUse() -> some View {
        modifier(KeyboardUseTracker())
    }
}

extension EnvironmentValues {
    /// A key was pressed since the last mouse press; set by `tracksKeyboardUse()`.
    @Entry var isKeyboardFocusVisible = false

    /// The system's keyboard navigation (Tab reaches buttons); set by `tracksKeyboardUse()`.
    @Entry var isFullKeyboardAccessEnabled = false

    /// Whether a button style draws its own focus ring. `isFocused` tells whether the
    /// nearest focusable ancestor has focus; while buttons cannot take focus themselves,
    /// that is the row a click or ↑ ↓ focused, so its buttons would all show a ring.
    /// Buttons take focus only with keyboard navigation on (Tab), and then the ring
    /// waits for a key press like the row's.
    var showsButtonFocusRing: Bool {
        isFocused && isKeyboardFocusVisible && isFullKeyboardAccessEnabled
    }
}
