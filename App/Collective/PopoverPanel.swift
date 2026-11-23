import AppKit
import CollectiveKit
import SubspaceKit
import SwiftUI

/// Shows the popover in a borderless panel under the status item and closes it
/// the way a menu bar popover closes: on a click anywhere else, Esc, a Space
/// change or the panel losing key. `MenuBarExtra` did this before the app had its own status item.
///
/// The SwiftUI content exists only while the panel shows, so its clock neither
/// ticks nor renders in the background; the expansion state lives in the model
/// and survives.
final class PopoverController: NSObject, NSWindowDelegate {
    private let model: CollectiveModel
    private let panel = PopoverPanel()
    /// Set while the panel shows, so a second close is a no-op.
    private var content: NSView?
    private var clickMonitor: Any?
    private var spaceObserver: (any NSObjectProtocol)?

    /// "Set Up…" in the warning block; whoever opens the window closes the popover.
    var onSetUp: () -> Void = {}
    /// The gear in the footer; whoever opens the window closes the popover.
    var onSettings: () -> Void = {}
    /// The footer's update link; whoever opens the source's settings pane or the update window closes the popover.
    var onOpenUpdate: (UpdateFooterLink.Target) -> Void = { _ in }
    /// Called after every open and close, for the status item's highlight.
    var onOpenChange: (Bool) -> Void = { _ in }

    var isOpen: Bool { content != nil }

    init(model: CollectiveModel) {
        self.model = model
        super.init()
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        followSystemAppearance()
    }

    /// The content's preferred color scheme reaches a window only from its content view, and
    /// the hosting view sits in `container`; so the panel takes the active scheme's variant
    /// itself, for the menus, dialogs and scroll bars the system draws in it.
    /// Read on every open, as only the settings change the choice and the popover is closed
    /// then.
    private func applyAppearance() {
        panel.appearance = ThemeDefaults.activeNSAppearance()
    }

    /// macOS can turn light or dark while the popover shows, e.g. on the automatic schedule, and
    /// a custom theme's file can change or vanish.
    private func followSystemAppearance() {
        withObservationTracking {
            _ = SystemAppearance.shared.value
            _ = ThemeCatalogStore.shared.catalog
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyAppearance()
                self?.followSystemAppearance()
            }
        }
    }

    func open(under button: NSStatusBarButton) {
        guard !isOpen, let buttonWindow = button.window, let screen = buttonWindow.screen else { return }
        // Before the hosting view builds the first model: the idle classification is fixed at this moment, or at the backlog's end when the popover opens during loading (`CollectiveModel.popoverOpened`, `IdleOpening`).
        model.popoverOpened()
        applyAppearance()
        let hostingView = NSHostingView(rootView: PopoverContent(
            model: model,
            onSetUp: { [weak self] in self?.onSetUp() },
            onSettings: { [weak self] in self?.onSettings() },
            onOpenUpdate: { [weak self] in self?.onOpenUpdate($0) }
        )
        .themedFromDefaults())
        // The default sizing options let the content size the panel: AppKit
        // then keeps the top edge in place when cards fold or rows appear.
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        let container = panel.container
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        content = hostingView
        model.checkIntegrationsIfStale()

        // The first layout pass measures the list, which starts out empty.
        container.layoutSubtreeIfNeeded()
        let iconFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let frame = PopoverPlacement.frame(iconFrame: iconFrame, contentSize: hostingView.fittingSize, visibleFrame: screen.visibleFrame)
        panel.setFrame(frame, display: false)
        // Key without activating the app: the frontmost app stays frontmost,
        // while ⌘Z, ⌘⌫, ⌘, and the arrow keys reach the popover.
        panel.makeKeyAndOrderFront(nil)
        panel.showShadow()

        // Clicks in other apps, on the desktop or on another status item. The
        // mouse-down on this app's own icon reaches the monitor as well, as if
        // it went to another app; it is left to the toggle, which would
        // otherwise reopen what the monitor just closed. A global event has no
        // window, so its location is on the screen.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard !iconFrame.contains(event.locationInWindow) else { return }
            MainActor.assumeIsolated { self?.close() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        onOpenChange(true)
    }

    /// Every path that hides the panel ends here; closing commits the archives
    /// that could still be undone.
    func close() {
        // Cleared first: ordering out resigns key, which calls back in here.
        guard let content else { return }
        self.content = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        panel.hideShadow()
        panel.orderOut(nil)
        content.removeFromSuperview()
        model.popoverClosed()
        onOpenChange(false)
    }

    // MARK: NSWindowDelegate

    /// Covers clicks into this app's other windows and the app being switched away from.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// The shadow is a window of its own, which resizing the panel leaves
    /// behind; AppKit keeps the top edge, so the frame moves as well.
    func windowDidResize(_ notification: Notification) {
        panel.updateShadowFrame()
    }
}

/// The popover's window. Non-activating, so opening it leaves the frontmost
/// app active, yet it can become key for the popover's shortcuts and focus.
///
/// Level `.statusBar` puts it with the menu bar it hangs from: above normal
/// and floating windows and the Dock, below menus and tooltips, including the
/// popover's own. The collection behavior shows it on the active Space, also
/// over a full-screen app, and keeps it out of Mission Control and window
/// cycling; a Space change closes it anyway.
///
/// The popover draws its own surface and border; the panel adds
/// Unimatrix's popover shadow, `0 10 30` black 30 %, which the window
/// server's shadow cannot be set to.
final class PopoverPanel: NSPanel {
    /// Hosts the SwiftUI content.
    let container = NSView()
    private let shadow = PopoverShadowWindow()
    var onCancel: () -> Void = {}

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .statusBar
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        // The controller closes on resigning key; hiding on its own would skip that.
        hidesOnDeactivate = false
        // The app stays inactive while the popover shows; AppKit suppresses tool tips then.
        allowsToolTipsWhenApplicationIsInactive = true
        contentView = container
    }

    override var canBecomeKey: Bool { true }

    /// Esc.
    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

    /// Puts the shadow under the panel; as a child window it follows the panel's
    /// moves and Spaces and stays right below it.
    func showShadow() {
        updateShadowFrame()
        addChildWindow(shadow, ordered: .below)
    }

    func hideShadow() {
        removeChildWindow(shadow)
        shadow.orderOut(nil)
    }

    func updateShadowFrame() {
        shadow.setFrame(frame.insetBy(dx: -PopoverShadowWindow.margin, dy: -PopoverShadowWindow.margin), display: true)
    }
}

/// Only the popover's shadow, in a window that lets every click through, so a
/// click beside the popover still reaches the app below and closes it.
final class PopoverShadowWindow: NSWindow {
    /// Room around the panel for the blur and the offset: 30 blur reaches 30
    /// beyond the outline, 10 more below.
    static let margin: CGFloat = 40

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = .statusBar
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = PopoverShadowView()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws the shadow of a rectangle `margin` inside its bounds. CSS's blur 30
/// is a Gaussian of deviation 15, which is Core Animation's shadow radius 15.
///
/// The shadow sits on a sublayer: AppKit owns the view's backing layer and
/// resets its shadow from `NSView.shadow` when the view moves into a window,
/// which left the opacity at 0.
private final class PopoverShadowView: NSView {
    private let shadowLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.3
        shadowLayer.shadowRadius = 15
        // The layer's y axis points up: the shadow falls 10 below.
        shadowLayer.shadowOffset = CGSize(width: 0, height: -10)
        layer?.addSublayer(shadowLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Unlike the backing layer, a sublayer animates implicitly; the shadow
        // would trail behind the panel when its cards fold.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = CGPath(rect: bounds.insetBy(dx: PopoverShadowWindow.margin, dy: PopoverShadowWindow.margin), transform: nil)
        CATransaction.commit()
    }
}
