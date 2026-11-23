import AppKit
import CollectiveKit
import CollectiveUI
import Observation
import os
import SubspaceKit
import SwiftUI

/// The menu bar icon. Its image follows the model; a left click toggles the
/// popover, a right click or Control-click opens the icon menu, which
/// `MenuBarExtra` could not offer.
final class StatusItemController: NSObject {
    private let model: CollectiveModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover: PopoverController
    /// Handed over by `WindowOpener` as soon as it is in `openerPanel`.
    private var openWindow: OpenWindowAction?
    /// Holds `WindowOpener` and is never ordered in: a hosting view needs a
    /// window to appear, not a visible one (measured). Not the status
    /// item button: AppKit snapshots it after every new image and lays out
    /// its subviews, a hosting view's environment included, which at 12 fps
    /// was a good part of the animation's CPU. Should anything order the
    /// panel in, it shows nothing, takes no clicks, and keeps out of the
    /// Window menu, ⌘` and Mission Control; borderless, it can become
    /// neither key nor main.
    private let openerPanel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.transient, .ignoresCycle]
        return panel
    }()
    /// What the image shows, kept so a change of the bar's appearance can
    /// draw it again without arming the model's observation a second time.
    private var shown: (icon: MenuBarIcon, date: Date, animation: MenuBarAnimation, reduceMotion: Bool)?
    /// The bar's appearance the image was last drawn for. The observation
    /// reports far more often than the bar changes: every new image makes
    /// AppKit redraw the item, which reports `effectiveAppearance` again,
    /// about eight times per image (measured). Redrawing on each report
    /// fed itself and kept the main thread busy.
    private var drawnAppearance: MenuBarScene.Appearance?
    private var appearanceObservation: NSKeyValueObservation?
    /// The display scales the image holds bitmaps for. A still frame (Reduce
    /// Motion) is not drawn again by a tick, so a display with a new scale
    /// would show the icon scaled from the wrong bitmap until the state changed.
    private var drawnScales: [Double]?
    private var accessibilityValue: String?
    /// What `accessibilityValue` was localized from. Keyed on the connection
    /// too: missing and disabled both show the warning icon.
    private var accessibilityIcon: MenuBarIcon?
    private var accessibilityConnection: ConnectionStatus?

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Collective", category: "Windows")

    init(model: CollectiveModel) {
        self.model = model
        popover = PopoverController(model: model)
        super.init()
        popover.onSetUp = { [weak self] in self?.openSetUp() }
        popover.onSettings = { [weak self] in self?.openSettings() }
        popover.onOpenUpdate = { [weak self] in self?.openUpdate($0) }
        popover.onOpenChange = { [weak self] isOpen in self?.highlight(isOpen) }
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(buttonClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let opener = NSHostingView(rootView: WindowOpener(
            model: model,
            onAppear: { [weak self] in self?.openWindow = $0 },
            onSetupRequested: { [weak self] in self?.openSetUp() }
        ))
        // The empty view has nothing to size the panel to.
        opener.sizingOptions = []
        openerPanel.contentView = opener
        button.setAccessibilityLabel(String(localized: MenuBarIcon.accessibilityLabel))
        // The menu bar is light or dark by the wallpaper behind it, not by the
        // system setting; the button's appearance follows it. The image is a
        // fixed bitmap for one appearance (the scene's colors, sparkles and glow
        // depend on it), so it is drawn again when the bar turns light or dark.
        // The observation reports far more often than that, about eight times
        // per image, hence the comparison in `appearanceChanged`.
        appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.appearanceChanged() }
        }
        // Selector-based, so the center drops it when the controller goes away.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        updateImage()
    }

    @objc private nonisolated func screenParametersChanged() {
        Task { @MainActor [weak self] in self?.screensChanged() }
    }

    /// Only a change between light and dark draws again; the reports in
    /// between leave the image alone, a template icon included.
    private func appearanceChanged() {
        guard let button = statusItem.button, MenuBarScene.Appearance(button.effectiveAppearance) != drawnAppearance else { return }
        drawImage()
    }

    /// The notification also comes for moved or resized displays; only a
    /// scale the image has no bitmap for (or one it no longer needs) draws again.
    private func screensChanged() {
        guard MenuBarImage.screenScales != drawnScales else { return }
        drawImage()
    }

    /// Observation fires once per change, so the tracking is armed again with
    /// every image, each animation frame included.
    private func updateImage() {
        // The connection is cheap and decides the VoiceOver words; it can change
        // without changing the icon (missing to disabled).
        let (image, connection) = withObservationTracking {
            ((icon: model.menuBarIcon, date: model.frameDate, animation: model.menuBarAnimation, reduceMotion: model.reduceMotion), model.connection)
        } onChange: { [weak self] in
            // Called before the change lands; the next turn reads the new value.
            Task { @MainActor in self?.updateImage() }
        }
        shown = image
        drawImage()
        updateAccessibilityValue(connection: connection)
    }

    /// The colored cube keeps its colors on the highlight while the popover is
    /// open, a template is tinted for it; the bar draws its selection pill
    /// behind the image. Only if the highlight turns the button's resolved
    /// appearance from light to dark or back does the observation redraw.
    private func drawImage() {
        guard let button = statusItem.button, let shown else { return }
        let appearance = button.effectiveAppearance
        let scales = MenuBarImage.screenScales
        drawnAppearance = MenuBarScene.Appearance(appearance)
        drawnScales = scales
        button.image = MenuBarImage.image(for: shown.icon, at: shown.date, appearance: appearance, scales: scales, animation: shown.animation, reduceMotion: shown.reduceMotion)
    }

    /// Only on a change, not with every animation frame.
    private func updateAccessibilityValue(connection: ConnectionStatus) {
        guard let icon = shown?.icon, icon != accessibilityIcon || connection != accessibilityConnection else { return }
        accessibilityIcon = icon
        accessibilityConnection = connection
        let value = String(localized: MenuBarIcon.accessibilityValue(icon: icon, connection: connection))
        guard value != accessibilityValue else { return }
        accessibilityValue = value
        statusItem.button?.setAccessibilityValue(value)
    }

    /// Without a mouse event, e.g. pressed through VoiceOver, it acts as a left click.
    @objc private func buttonClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if popover.isOpen {
            popover.close()
        } else if let button = statusItem.button {
            popover.open(under: button)
        }
    }

    /// A click on a notification: opens the popover, and leaves it open if it is.
    func openPopover() {
        guard !popover.isOpen, let button = statusItem.button else { return }
        popover.open(under: button)
    }

    /// After a jump to a session's terminal; nothing happens if it is closed.
    func closePopover() {
        popover.close()
    }

    /// The button drops its highlight when the click that opened the popover
    /// ends, so it is set again on the next turn.
    private func highlight(_ isOpen: Bool) {
        Task { @MainActor in statusItem.button?.highlight(isOpen && popover.isOpen) }
    }

    // MARK: Menu

    /// Built on every open, so "Set Up…" follows the current connection. Set
    /// only for this click, so a left click keeps toggling the popover.
    private func showMenu() {
        popover.close()
        let menu = NSMenu()
        for item in StatusMenuModel(connection: model.connection).items {
            menu.addItem(menuItem(for: item))
        }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func menuItem(for item: StatusMenuItem) -> NSMenuItem {
        guard let title = item.title else { return .separator() }
        let menuItem = NSMenuItem(title: String(localized: title), action: action(for: item), keyEquivalent: item.keyEquivalent?.key ?? "")
        menuItem.keyEquivalentModifierMask = item.keyEquivalent?.command == true ? .command : []
        menuItem.target = self
        if let symbolName = item.symbolName {
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            menuItem.image = item.isWarning
                ? image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
                : image
        }
        return menuItem
    }

    private func action(for item: StatusMenuItem) -> Selector? {
        switch item {
        case .settings: #selector(openSettings)
        case .setUp: #selector(openSetUp)
        case .quit: #selector(quit)
        case .separator: nil
        }
    }

    // MARK: Windows

    @objc private func openSettings() {
        popover.close()
        withOpenWindow { $0.openSettingsWindow() }
    }

    private func openUpdate(_ target: UpdateFooterLink.Target) {
        popover.close()
        switch target {
        case .source(let source): withOpenWindow { $0.openSettingsWindow(on: .source(source)) }
        case .app: model.showAppUpdate()
        }
    }

    @objc private func openSetUp() {
        popover.close()
        withOpenWindow { $0.openSetupWindow() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func withOpenWindow(_ open: (OpenWindowAction) -> Void) {
        guard let openWindow else {
            Self.log.error("No openWindow action yet; the window opener has not appeared")
            return
        }
        open(openWindow)
    }
}

/// AppKit cannot open a SwiftUI `Window` scene, only a view's `openWindow` can.
/// This empty view lives from launch on in a hidden panel of the status item
/// controller (not in the popover, whose content exists only while it shows;
/// not in the status item button, which is snapshotted with every frame)
/// and hands the action over. It also opens the setup window when the
/// model asks without the user (first launch).
private struct WindowOpener: View {
    let model: CollectiveModel
    let onAppear: (OpenWindowAction) -> Void
    let onSetupRequested: () -> Void

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear { onAppear(openWindow) }
            .task(id: model.setupWindowRequested) {
                guard model.setupWindowRequested else { return }
                model.setupWindowOpened()
                onSetupRequested()
            }
    }
}
