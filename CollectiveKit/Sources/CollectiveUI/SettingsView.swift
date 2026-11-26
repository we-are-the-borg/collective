import AppKit
import CollectiveKit
import SubspaceKit
import SwiftUI

/// The settings window: the self-drawn title bar, a sidebar with one entry per source and the
/// selected entry's pane. All rules (panes, states, buttons) come from `SettingsModel`.
/// The window's scene hides the system's title bar (`WindowTitleBar`).
public struct SettingsView: View {
    let model: SettingsModel
    @Binding var selection: SettingsPane
    @Binding var launchAtLogin: Bool
    @Binding var finishedRetention: FinishedRetention
    @Binding var idleAfter: IdleAfter
    @Binding var eventRetention: EventRetention
    @Binding var clearFailure: StoredEventsClearFailure?
    @Binding var notificationPreferences: NotificationPreferences
    @Binding var checksForUpdates: Bool
    @Binding var menuBarAnimation: MenuBarAnimation
    @Binding var colorsEffortLevels: Bool
    @Binding var themeChoice: ThemeChoice
    let notificationsTurnedOff: Bool
    let reduceMotion: Bool
    let appIcon: Image
    let appName: String
    let version: String
    let installedVersion: String?
    let appUpdate: AppUpdateStatusLine?
    let onSetUp: (SourceID) -> Void
    let onUpdate: (SourceID, SetupCardModel.CommandsBox.Footer.Button.Kind) -> Void
    let onToggleUpdateOutput: (SourceID) -> Void
    let onChooseFolder: (SourceID) -> Void
    let onResetFolder: (SourceID) -> Void
    let onClearStoredEvents: () -> Void
    let onOpenNotificationSettings: () -> Void
    let onOpenDisplaySettings: () -> Void
    let onImportThemes: () -> Void
    let onShowThemesFolder: () -> Void
    let onShowThemeFile: (URL) -> Void
    let onMoveThemeToTrash: (URL) -> Void
    let onCheckForUpdates: () -> Void
    let onShowAppUpdate: () -> Void
    let onQuit: () -> Void

    /// The window's own title, in the Window menu and the self-drawn title bar; the pane's
    /// name is its heading.
    public static var title: Text { Text("The Collective Settings", bundle: .module) }

    /// - Parameters:
    ///   - appIcon: The app's own icon; the package cannot reach it.
    ///   - clearFailure: Why the last clear of the stored events failed; the view alerts while it is set and resets it on dismissal.
    ///   - notificationsTurnedOff: The user denied the app notifications in System Settings.
    ///   - checksForUpdates: "Check for updates automatically" in General › Updates, for the app and subspace.
    ///   - menuBarAnimation: When and how fast the menu bar cube moves, in the Menu Bar pane.
    ///   - colorsEffortLevels: "Color effort levels" in General › Popover.
    ///   - themeChoice: The scheme per appearance, chosen in the Appearance pane; the app themes every window from it.
    ///   - reduceMotion: The system's Reduce Motion is on; the Menu Bar pane shows its note and greys out its controls.
    ///   - appUpdate: About's update status line; nil draws neither it nor `Check Now`.
    ///   - onSetUp: "Set Up…"; the app opens the setup window.
    ///   - onUpdate: The update group's Update or Try Again; the app starts or retries that source's update.
    ///   - onToggleUpdateOutput: The update group's Show/Hide Output.
    ///   - onChooseFolder: "Choose…"; the app asks for the event folder.
    ///   - onResetFolder: "Reset"; the app goes back to the default folder.
    ///   - onClearStoredEvents: "Clear" in the confirmation of the Stored events row; the app deletes its stored events.
    ///   - onOpenNotificationSettings: "Open System Settings"; the app opens its page in System Settings → Notifications.
    ///   - onOpenDisplaySettings: "Open System Settings…" in the Reduce Motion note; the app opens Accessibility › Display.
    ///   - onImportThemes: "Import Theme…" in the Appearance pane; the app asks for YAML files, asks "Replace?" per taken name and copies them into the themes folder.
    ///   - onShowThemesFolder: The Appearance pane's "Show in Finder"; the app creates the themes folder if needed and opens it in Finder.
    ///   - onShowThemeFile: "Show in Finder" in a custom or error row's context menu; the app selects the file in Finder.
    ///   - onMoveThemeToTrash: "Move to Trash" in a custom or error row's context menu; the app moves the file to the Trash.
    ///   - onCheckForUpdates: About's "Check Now"; the app checks itself and every subspace plugin.
    ///   - onShowAppUpdate: About's "Update…"; the app opens its update window.
    ///   - onQuit: "Quit The Collective" under the sidebar; the app terminates.
    public init(
        model: SettingsModel,
        selection: Binding<SettingsPane>,
        launchAtLogin: Binding<Bool>,
        finishedRetention: Binding<FinishedRetention>,
        idleAfter: Binding<IdleAfter>,
        eventRetention: Binding<EventRetention>,
        clearFailure: Binding<StoredEventsClearFailure?>,
        notificationPreferences: Binding<NotificationPreferences>,
        checksForUpdates: Binding<Bool>,
        menuBarAnimation: Binding<MenuBarAnimation>,
        colorsEffortLevels: Binding<Bool>,
        themeChoice: Binding<ThemeChoice>,
        notificationsTurnedOff: Bool,
        reduceMotion: Bool,
        appIcon: Image,
        appName: String,
        version: String,
        installedVersion: String?,
        appUpdate: AppUpdateStatusLine? = nil,
        onSetUp: @escaping (SourceID) -> Void,
        onUpdate: @escaping (SourceID, SetupCardModel.CommandsBox.Footer.Button.Kind) -> Void,
        onToggleUpdateOutput: @escaping (SourceID) -> Void,
        onChooseFolder: @escaping (SourceID) -> Void,
        onResetFolder: @escaping (SourceID) -> Void,
        onClearStoredEvents: @escaping () -> Void,
        onOpenNotificationSettings: @escaping () -> Void,
        onOpenDisplaySettings: @escaping () -> Void,
        onImportThemes: @escaping () -> Void,
        onShowThemesFolder: @escaping () -> Void,
        onShowThemeFile: @escaping (URL) -> Void,
        onMoveThemeToTrash: @escaping (URL) -> Void,
        onCheckForUpdates: @escaping () -> Void = {},
        onShowAppUpdate: @escaping () -> Void = {},
        onQuit: @escaping () -> Void
    ) {
        self.model = model
        _selection = selection
        _launchAtLogin = launchAtLogin
        _finishedRetention = finishedRetention
        _idleAfter = idleAfter
        _eventRetention = eventRetention
        _clearFailure = clearFailure
        _notificationPreferences = notificationPreferences
        _checksForUpdates = checksForUpdates
        _menuBarAnimation = menuBarAnimation
        _colorsEffortLevels = colorsEffortLevels
        _themeChoice = themeChoice
        self.notificationsTurnedOff = notificationsTurnedOff
        self.reduceMotion = reduceMotion
        self.appIcon = appIcon
        self.appName = appName
        self.version = version
        self.installedVersion = installedVersion
        self.appUpdate = appUpdate
        self.onSetUp = onSetUp
        self.onUpdate = onUpdate
        self.onToggleUpdateOutput = onToggleUpdateOutput
        self.onChooseFolder = onChooseFolder
        self.onResetFolder = onResetFolder
        self.onClearStoredEvents = onClearStoredEvents
        self.onOpenNotificationSettings = onOpenNotificationSettings
        self.onOpenDisplaySettings = onOpenDisplaySettings
        self.onImportThemes = onImportThemes
        self.onShowThemesFolder = onShowThemesFolder
        self.onShowThemeFile = onShowThemeFile
        self.onMoveThemeToTrash = onMoveThemeToTrash
        self.onCheckForUpdates = onCheckForUpdates
        self.onShowAppUpdate = onShowAppUpdate
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            WindowTitleBar(Self.title)
            HStack(spacing: 0) {
                SettingsSidebar(model: model, selection: $selection, onQuit: onQuit)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.role(.surface))
            }
            // Fixed width, the height grows with the window, like System Settings;
            // the scene's `.contentSize` resizability turns this into the window's limits, with
            // the 400 under the bar.
            .frame(minHeight: 400, idealHeight: 400, maxHeight: .infinity)
        }
        .frame(width: 660)
        // The title bar draws where the system's would.
        .ignoresSafeArea(.container, edges: .top)
        .tracksKeyboardUse()
        .alert(
            Text(SettingsText.clearFailedTitle),
            isPresented: Binding(get: { clearFailure != nil }, set: { if !$0 { clearFailure = nil } }),
            presenting: clearFailure
        ) { _ in
            Button { } label: { Text(SettingsText.ok) }
        } message: { failure in
            Text(failure.message)
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch selection {
        case .general:
            GeneralPane(launchAtLogin: $launchAtLogin, colorsEffortLevels: $colorsEffortLevels, checksForUpdates: $checksForUpdates)
        case .appearance:
            AppearancePane(
                choice: $themeChoice,
                customThemes: CustomThemeActions(
                    importThemes: onImportThemes, showFolder: onShowThemesFolder,
                    showFile: onShowThemeFile, moveToTrash: onMoveThemeToTrash
                )
            )
        case .sessions:
            SessionsPane(
                storedEvents: model.storedEvents, finishedRetention: $finishedRetention, idleAfter: $idleAfter,
                eventRetention: $eventRetention, onClearStoredEvents: onClearStoredEvents
            )
        case .notifications:
            NotificationsPane(
                sources: model.sources, notificationPreferences: $notificationPreferences,
                notificationsTurnedOff: notificationsTurnedOff, onOpenNotificationSettings: onOpenNotificationSettings
            )
        case .menuBar:
            MenuBarPane(menuBarAnimation: $menuBarAnimation, reduceMotion: reduceMotion, onOpenDisplaySettings: onOpenDisplaySettings)
        case .source(let id):
            if let source = model.sources.first(where: { $0.source == id }) {
                SourcePane(
                    source: source, onSetUp: onSetUp, onUpdate: onUpdate, onToggleUpdateOutput: onToggleUpdateOutput,
                    onChooseFolder: onChooseFolder, onResetFolder: onResetFolder
                )
            }
        case .about:
            AboutPane(appIcon: appIcon, appName: appName, version: version, installedVersion: installedVersion,
                      sources: model.sources, update: appUpdate, onCheckNow: onCheckForUpdates, onUpdate: onShowAppUpdate)
        }
    }
}

#if DEBUG
private struct SettingsPreview: View {
    @State var selection: SettingsPane
    @State var launchAtLogin = true
    @State var retention = FinishedRetention.allCases[0]
    @State var idleAfter = IdleAfter.default
    @State var eventRetention = EventRetention.default
    @State var notificationPreferences = NotificationPreferences()
    @State var checksForUpdates = true
    @State var menuBarAnimation: MenuBarAnimation
    @State var colorsEffortLevels: Bool
    @State var themeChoice = ThemeChoice(light: BundledThemes.defaultLight, dark: BundledThemes.defaultDark)
    let notificationsTurnedOff: Bool
    let reduceMotion: Bool
    let model: SettingsModel

    /// - Parameters:
    ///   - availability: The release check's answer, for the sources at `updating` only.
    ///   - updateRun: Those sources' update run.
    init(
        _ selection: SettingsPane, statuses: [IntegrationStatus?] = [PreviewData.readyIntegration],
        chosen: Bool = false, notificationsTurnedOff: Bool = false,
        menuBarAnimation: MenuBarAnimation = MenuBarAnimation(), reduceMotion: Bool = false, colorsEffortLevels: Bool = true,
        availability: UpdateAvailability = .upToDate, updateRun: SetupCommandRun.Snapshot? = nil, outputShown: Bool = false,
        updating: Set<Int> = [0]
    ) {
        _selection = State(initialValue: selection)
        self.notificationsTurnedOff = notificationsTurnedOff
        _menuBarAnimation = State(initialValue: menuBarAnimation)
        _colorsEffortLevels = State(initialValue: colorsEffortLevels)
        self.reduceMotion = reduceMotion
        let home = "/Users/user"
        model = SettingsModel(sources: statuses.enumerated().map { index, status in
            // The first two are named like the registered tools.
            let known = PreviewData.sourceIDs.indices.contains(index) ? PreviewData.sourceIDs[index] : nil
            return SettingsSourceModel(
                source: SourceID(rawValue: "source-\(index)"),
                name: known.flatMap { PreviewData.sourceNames[$0] } ?? "Source \(index)",
                status: status,
                // A probe after the run, so a succeeded one shows what that probe found.
                checkedAt: PreviewData.now.addingTimeInterval(1),
                defaultFolders: [URL(fileURLWithPath: "\(home)/.claude/plugins/data/subspace-subspace")],
                chosenFolder: chosen ? URL(fileURLWithPath: "\(home)/Library/Mobile Documents/com~apple~CloudDocs/Shared/subspace/claude-code/events") : nil,
                availability: updating.contains(index) ? availability : .upToDate,
                updateRun: updating.contains(index) ? updateRun : nil,
                outputShown: outputShown,
                home: home,
                now: PreviewData.now.addingTimeInterval(2),
                timeZone: TimeZone(identifier: "Europe/Berlin") ?? .current
            )
        }, storedEvents: StoredEventsModel(size: 15_300_000))
    }

    var body: some View {
        SettingsView(
            model: model, selection: $selection, launchAtLogin: $launchAtLogin, finishedRetention: $retention,
            idleAfter: $idleAfter, eventRetention: $eventRetention, clearFailure: .constant(nil),
            notificationPreferences: $notificationPreferences, checksForUpdates: $checksForUpdates,
            menuBarAnimation: $menuBarAnimation, colorsEffortLevels: $colorsEffortLevels, themeChoice: $themeChoice,
            notificationsTurnedOff: notificationsTurnedOff, reduceMotion: reduceMotion,
            appIcon: Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage()), appName: "The Collective", version: "1.0 (42)", installedVersion: "1.0",
            onSetUp: { _ in }, onUpdate: { _, _ in }, onToggleUpdateOutput: { _ in }, onChooseFolder: { _ in }, onResetFolder: { _ in },
            onClearStoredEvents: {},
            onOpenNotificationSettings: {}, onOpenDisplaySettings: {},
            onImportThemes: {}, onShowThemesFolder: {}, onShowThemeFile: { _ in }, onMoveThemeToTrash: { _ in }, onQuit: {}
        )
    }
}

@MainActor
private enum FramePreview {
    static var window: SettingsPreview {
        SettingsPreview(
            .general,
            statuses: [PreviewData.updatableIntegration, PreviewData.waitingIntegration],
            availability: PreviewData.updateAvailable
        )
    }
}

// The frame in the design's four schemes, with a second source waiting
// and an update on offer, so every sidebar form shows.
#Preview("Frame – Catppuccin Latte") { FramePreview.window.themeSelection(light: "catppuccin-latte") }
#Preview("Frame – Catppuccin Macchiato") {
    FramePreview.window.themeSelection(dark: "catppuccin-macchiato").preferredColorScheme(.dark)
}
#Preview("Frame – GitHub Light") { FramePreview.window.themeSelection(light: "github") }
#Preview("Frame – GitHub Dark") { FramePreview.window.themeSelection(dark: "github-dark").preferredColorScheme(.dark) }
#endif
