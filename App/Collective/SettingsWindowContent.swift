import AppKit
import CollectiveKit
import CollectiveUI
import os
import ServiceManagement
import SubspaceKit
import SwiftUI

/// The settings window's scene id.
enum SettingsWindow {
    static let id = "settings"
    /// The pane the window shows, in `UserDefaults`; writing it switches an open window too.
    static let paneKey = "settingsPane"
}

extension OpenWindowAction {
    func openSettingsWindow() {
        bringToFront(id: SettingsWindow.id)
    }

    /// The pane is stored before the window opens, so a new window starts on
    /// it and an open one switches (`SettingsWindowContent` observes the key).
    func openSettingsWindow(on pane: SettingsPane) {
        UserDefaults.standard.set(pane.rawValue, forKey: SettingsWindow.paneKey)
        openSettingsWindow()
    }
}

/// Wires the settings window to the model, the login item and the open panel.
struct SettingsWindowContent: View {
    @Bindable var model: CollectiveModel
    /// The live catalog and the custom folder, for the Appearance pane.
    let themes: ThemeCatalogStore

    /// A pane that no longer exists, e.g. of a removed source, falls back to General.
    @AppStorage(SettingsWindow.paneKey) private var storedPane = SettingsPane.general.rawValue
    /// The login item's real state, read again after every change and whenever
    /// the app becomes active.
    @State private var launchAtLogin = LoginItem.isEnabled
    /// Read when the Notifications pane shows and whenever the app becomes
    /// active, e.g. back from System Settings.
    @State private var notificationsTurnedOff = false
    /// The same keys `themedFromDefaults()` reads, so a choice in the Appearance pane recolors
    /// this window, the setup window and the popover at once, with no change notice to wire up.
    @AppStorage(ThemeDefaults.lightKey) private var themeLight = BundledThemes.defaultLight
    @AppStorage(ThemeDefaults.darkKey) private var themeDark = BundledThemes.defaultDark
    @AppStorage(ThemeDefaults.modeKey) private var themeMode = ThemeMode.system
    @AppStorage(ThemeDefaults.fixedKey) private var themeFixed = BundledThemes.defaultLight
    @AppStorage(ThemeDefaults.lightRememberedKey) private var themeLightRemembered: RememberedCustomTheme?
    @AppStorage(ThemeDefaults.darkRememberedKey) private var themeDarkRemembered: RememberedCustomTheme?
    @AppStorage(ThemeDefaults.fixedRememberedKey) private var themeFixedRemembered: RememberedCustomTheme?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsView(
            model: model.settingsModel(),
            selection: Binding(
                get: { SettingsPane.restoring(storedPane, sources: model.sources.map(\.source)) },
                set: { storedPane = $0.rawValue }
            ),
            launchAtLogin: Binding(
                get: { launchAtLogin },
                set: { launchAtLogin = LoginItem.set($0) }
            ),
            finishedRetention: $model.finishedRetention,
            idleAfter: $model.idleAfter,
            eventRetention: $model.eventRetention,
            clearFailure: $model.storedEventsClearFailure,
            notificationPreferences: $model.notificationPreferences,
            checksForUpdates: $model.checksForUpdates,
            menuBarAnimation: $model.menuBarAnimation,
            colorsEffortLevels: $model.colorsEffortLevels,
            themeChoice: Binding(
                get: {
                    ThemeChoice(
                        light: themeLight, dark: themeDark, mode: themeMode, fixed: themeFixed,
                        lightRemembered: themeLightRemembered, darkRemembered: themeDarkRemembered,
                        fixedRemembered: themeFixedRemembered
                    )
                },
                set: {
                    themeLight = $0.light; themeDark = $0.dark; themeMode = $0.mode; themeFixed = $0.fixed
                    themeLightRemembered = $0.lightRemembered; themeDarkRemembered = $0.darkRemembered
                    themeFixedRemembered = $0.fixedRemembered
                }
            ),
            notificationsTurnedOff: notificationsTurnedOff,
            reduceMotion: model.reduceMotion,
            appIcon: Image(nsImage: NSApp.applicationIconImage),
            appName: Self.appName,
            version: Self.version,
            installedVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appUpdate: model.appUpdateStatusLine(now: Date()),
            onSetUp: { _ in openWindow.openSetupWindow() },
            onUpdate: model.runUpdate,
            onToggleUpdateOutput: model.setupRuns.toggleOutput(for:),
            onChooseFolder: chooseFolder,
            onResetFolder: { model.chooseFolder(nil, for: $0) },
            onClearStoredEvents: { model.clearStoredEvents() },
            onOpenNotificationSettings: openNotificationSettings,
            onOpenDisplaySettings: { NSWorkspace.shared.open(SettingsModel.reduceMotionSettingsURL) },
            onImportThemes: { CustomThemeCommands.importThemes(into: themes.library) },
            onShowThemesFolder: { CustomThemeCommands.showFolder(of: themes.library) },
            onShowThemeFile: CustomThemeCommands.showFile,
            onMoveThemeToTrash: { CustomThemeCommands.moveToTrash($0, in: themes.library) },
            onCheckForUpdates: model.checkForUpdatesNow,
            onShowAppUpdate: model.showAppUpdate,
            onQuit: { NSApplication.shared.terminate(nil) }
        )
        // Update runs show until the last of this and the setup window closes; see `SetupRuns`.
        .onAppear {
            model.setupRuns.windowDidAppear(.settings)
            DockPresence.opened(SettingsWindow.id)
            launchAtLogin = LoginItem.isEnabled
            // A source pane's task loop below probes right away; a second probe here would run back to back.
            if case .source = pane {} else { model.checkIntegrationsIfStale() }
        }
        .onDisappear { model.setupRuns.windowDidDisappear(.settings) }
        // The size is only on the Sessions pane, and the store grows while the
        // window is open: read when that pane is selected and every 5 s while
        // it shows. Another pane or a closed window cancels this. The
        // Notifications pane reads the system's authorization when it shows, a
        // source pane asks for subspace releases if the last lookup is old enough
        // and checks the tools every 5 s, like the setup window, so an update's
        // result is confirmed while it shows (checks never overlap). Appearance reads the themes
        // folder again: FSEvents does not see a linked theme's target change.
        .task(id: pane) {
            switch pane {
            case .appearance:
                await themes.library.reload()
            case .sessions:
                while !Task.isCancelled {
                    model.refreshStoredEventsSize()
                    try? await Task.sleep(for: .seconds(5))
                }
            case .notifications:
                notificationsTurnedOff = await model.notifier.isTurnedOff()
            case .source:
                model.checkSubspaceReleasesOnOpen()
                while !Task.isCancelled {
                    model.checks.check()
                    try? await Task.sleep(for: .seconds(5))
                }
            default:
                return
            }
        }
        // The user can switch the login item off in System Settings while this
        // window stays open; coming back to the app is when that can have happened.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin = LoginItem.isEnabled
            guard pane == .notifications else { return }
            Task { notificationsTurnedOff = await model.notifier.isTurnedOff() }
        }
    }

    private var pane: SettingsPane {
        SettingsPane.restoring(storedPane, sources: model.sources.map(\.source))
    }

    private func openNotificationSettings() {
        guard let id = Bundle.main.bundleIdentifier,
              let url = SettingsModel.notificationSettingsURL(bundleIdentifier: id) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Any folder will do: an empty one is a valid root (subspace contract §2).
    private func chooseFolder(for source: SourceID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.chosenFolders[source]
            ?? model.sources.first { $0.source == source }?.defaultFolder
        // App-modal, so it would otherwise follow the system, not the active scheme.
        panel.appearance = ThemeDefaults.activeNSAppearance()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.chooseFolder(url, for: source)
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? ProcessInfo.processInfo.processName
    }

    /// E.g. "1.0.0", or "1.0.0 (42)" when the build differs.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        return AppVersionLabel.text(
            short: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String
        )
    }
}

/// Launch at login through `SMAppService`; the system owns the state, so the
/// toggle always shows what it reports rather than what was asked for.
@MainActor
enum LoginItem {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Collective", category: "LoginItem")

    /// Waiting for the user's approval in System Settings counts as off.
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registers or unregisters the app and returns the state afterwards, so a
    /// failed registration leaves the toggle off.
    static func set(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            log.error("Could not \(enabled ? "register" : "unregister", privacy: .public) the login item: \(String(describing: error), privacy: .public)")
        }
        // The user turned login items off for the app before: only they can allow it again.
        if enabled, service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        return isEnabled
    }
}
