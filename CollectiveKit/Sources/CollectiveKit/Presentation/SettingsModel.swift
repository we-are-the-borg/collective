import Foundation
import SubspaceKit

/// A sidebar entry of the settings window. The raw value is what the app
/// persists as the selection, so a pane that no longer exists (a removed
/// source) decodes to `nil` and the caller falls back to `.general`.
public enum SettingsPane: Sendable, Hashable, RawRepresentable {
    case general
    case appearance
    case sessions
    case notifications
    case menuBar
    case source(SourceID)
    case about

    private static let sourcePrefix = "source:"

    public init?(rawValue: String) {
        switch rawValue {
        case "general": self = .general
        case "appearance": self = .appearance
        case "sessions": self = .sessions
        case "notifications": self = .notifications
        case "menuBar": self = .menuBar
        case "about": self = .about
        case _ where rawValue.hasPrefix(Self.sourcePrefix) && rawValue.count > Self.sourcePrefix.count:
            self = .source(SourceID(rawValue: String(rawValue.dropFirst(Self.sourcePrefix.count))))
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .general: "general"
        case .appearance: "appearance"
        case .sessions: "sessions"
        case .notifications: "notifications"
        case .menuBar: "menuBar"
        case .source(let id): Self.sourcePrefix + id.rawValue
        case .about: "about"
        }
    }

    /// The stored selection if it still names a pane of this window, else General.
    public static func restoring(_ rawValue: String, sources: [SourceID]) -> SettingsPane {
        guard let pane = SettingsPane(rawValue: rawValue) else { return .general }
        if case .source(let id) = pane, !sources.contains(id) { return .general }
        return pane
    }
}

/// One source in the settings window: its sidebar row and its detail pane.
public struct SettingsSourceModel: Sendable, Equatable {
    public enum ButtonStyle: Sendable, Equatable { case normal, primary }

    public let source: SourceID
    public let name: String
    /// The state of the subspace row as one text, the same as the setup window's status word
    /// plus the version; the sidebar row reads it.
    public let status: SetupCardModel.Pill
    /// `status` without the version: the pane draws it in the form's role.
    public let statusWord: LocalizedStringResource
    /// The version `status` ends with; the pane draws it after the word in `--text-subtle`.
    /// Nil where the status names none (Not set up, Not found, Checking…, no version known).
    public let statusVersion: String?
    /// The restyled form in front of the sidebar row and the status word, in
    /// the role both are drawn in. An offered update leaves it alone: the
    /// sidebar shows that as its arrow.
    public let statusMark: SourceStatusMark
    /// "Set Up…", which opens the setup window; nil while connected or not yet checked.
    public let setUpButton: ButtonStyle?
    /// Home shown as `~`.
    public let eventFolderPath: String
    /// "(default)" follows the path while no folder is chosen.
    public let showsDefaultMarker: Bool
    /// Only a chosen folder can be reset.
    public let canReset: Bool
    /// The "Update" group under the subspace row; nil while there is nothing to do.
    public let update: SourceUpdateModel?
    /// The sidebar arrow before the dot: an optional update on offer, under
    /// way or failed. A required one is a warning the dot already shows.
    public let showsUpdateArrow: Bool
    /// The registered source's plugin repository (`IntegrationProbe.commands.sourceURL`);
    /// nil when it names none.
    public let sourceURL: URL?
    /// `sourceURL` as About shows it, `owner/repo`, without host, leading or trailing slash or `.git`.
    public let repositoryName: String?

    /// The sidebar row's VoiceOver label: name and status as the pane shows
    /// them, plus the update the arrow stands for, which is hidden itself.
    public var rowAccessibilityLabel: LocalizedStringResource {
        guard showsUpdateArrow else { return .kit("%@, %@", defaultValue: "\(name), \(status.text)") }
        return .kit("%@, %@, update available", defaultValue: "\(name), \(status.text), update available")
    }

    /// - Parameters:
    ///   - sourceURL: The registered probe's `commands.sourceURL`, known before any
    ///     probe finished; nil falls back to the one `status` reports.
    ///   - status: The latest probe result; nil until the first probe finished.
    ///   - checkedAt: When the probe that reported `status` started; only one
    ///     started after an update succeeded confirms it.
    ///   - lastEventAt: When the newest event the app read from the source's
    ///     spool happened; as in the setup window it stands in for a session
    ///     start subspace has no record of.
    ///   - defaultFolder: Where subspace writes without a choice.
    ///   - chosenFolder: The folder the user picked; nil = the default.
    ///   - availability: What the release check says about the installed plugin.
    ///   - updateRun: The source's update run as the windows show it.
    ///   - outputShown: Whether the user asked to see a succeeded update's output.
    ///   - checksForUpdates: The switch in General › Updates.
    ///   - home: The home folder shown as `~` in paths.
    ///   - now: Caps how long a succeeded update waits for a probe to confirm it.
    ///   - timeZone: Of the time an update succeeded at.
    public init(
        source: SourceID,
        name: String,
        sourceURL: URL? = nil,
        status: IntegrationStatus?,
        checkedAt: Date? = nil,
        lastEventAt: Date? = nil,
        defaultFolder: URL,
        chosenFolder: URL?,
        availability: UpdateAvailability = .upToDate,
        updateRun: SetupCommandRun.Snapshot? = nil,
        outputShown: Bool = false,
        checksForUpdates: Bool = true,
        home: String = NSHomeDirectory(),
        now: Date = Date(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.source = source
        self.name = name
        self.sourceURL = sourceURL ?? status?.commands.sourceURL
        repositoryName = self.sourceURL.flatMap(Self.repositoryName)

        // Before the first probe nothing is known, so no claim and no button.
        guard let status else {
            self.status = .init(text: Self.checking)
            statusWord = Self.checking
            statusVersion = nil
            statusMark = .unknown
            setUpButton = nil
            update = nil
            showsUpdateArrow = false
            (eventFolderPath, showsDefaultMarker, canReset) = Self.folder(defaultFolder, chosenFolder, home)
            return
        }
        let update = SourceUpdateModel(status, checkedAt: checkedAt, availability: availability, run: updateRun, outputShown: outputShown,
                                       checksForUpdates: checksForUpdates, now: now, timeZone: timeZone)
        self.update = update
        let isRequired = if case .required = availability { true } else { false }
        showsUpdateArrow = switch update?.state {
        case .available?, .running?, .failed?: checksForUpdates && !isRequired
        case .updated?, .required?, nil: false
        }
        // The installed version rides along wherever the plugin is installed, so a
        // stale subspace shows here; without one the status stands alone.
        let version: String? = switch status.plugin {
        case .enabled(let version), .disabled(let version): version
        case .notInstalled, .unknown: nil
        }
        let text: LocalizedStringResource
        let word: LocalizedStringResource
        let shownVersion: String?
        let mark: SourceStatusMark
        let state = SetupCardModel.state(of: status, lastEventAt: lastEventAt)
        switch state {
        // Connected or waiting, the app's own minimum is the worst news, so the
        // form turns into the warning triangle; disabled says more than it and keeps its text.
        case .ready where isRequired, .waiting where isRequired:
            text = .kit("Update required · %@", defaultValue: "Update required · \(version ?? "")")
            word = .kit("Update required", defaultValue: "Update required")
            shownVersion = version
            mark = .warning
            setUpButton = state == .waiting ? .normal : nil
        case .ready:
            text = version.map { .kit("Connected · %@", defaultValue: "Connected · \($0)") }
                ?? .kit("Connected", defaultValue: "Connected")
            word = .kit("Connected", defaultValue: "Connected")
            shownVersion = version
            mark = .connected
            setUpButton = nil
        case .waiting:
            text = version.map { .kit("Waiting for a session · %@", defaultValue: "Waiting for a session · \($0)") }
                ?? .kit("Waiting for a session", defaultValue: "Waiting for a session")
            word = .kit("Waiting for a session", defaultValue: "Waiting for a session")
            shownVersion = version
            mark = .waiting
            setUpButton = .normal
        case .disabled:
            text = version.map { .kit("Disabled · %@", defaultValue: "Disabled · \($0)") }
                ?? .kit("Disabled", defaultValue: "Disabled")
            word = .kit("Disabled", defaultValue: "Disabled")
            shownVersion = version
            mark = .warning
            setUpButton = .primary
        // A failed check nothing was known before claims as little as no check yet.
        case .checking:
            text = Self.checking
            word = text
            shownVersion = nil
            mark = .unknown
            setUpButton = nil
        case .notFound:
            text = .kit("Not found", defaultValue: "Not found")
            word = text
            shownVersion = nil
            mark = .unknown
            setUpButton = .normal
        case .notInstalled:
            text = .kit("Not set up", defaultValue: "Not set up")
            word = text
            shownVersion = nil
            mark = .unknown
            setUpButton = .primary
        }
        self.status = .init(text: text)
        statusWord = word
        statusVersion = shownVersion
        statusMark = mark
        (eventFolderPath, showsDefaultMarker, canReset) = Self.folder(defaultFolder, chosenFolder, home)
    }

    private static let checking: LocalizedStringResource = .kit("Checking…", defaultValue: "Checking…")

    private static func folder(_ defaultFolder: URL, _ chosen: URL?, _ home: String) -> (String, Bool, Bool) {
        let shown = chosen ?? defaultFolder
        return (SetupCardModel.abbreviating(shown.path, home: home), chosen == nil, chosen != nil)
    }

    /// A clone URL may end in `/` or `.git`; About names the repository without either.
    private static func repositoryName(_ url: URL) -> String? {
        var name = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name.isEmpty ? nil : name
    }
}

/// The settings window's sidebar and the Sessions pane.
public struct SettingsModel: Sendable, Equatable {
    /// General, Appearance, Sessions, Notifications, Menu Bar, one pane per source in the given order, About.
    public let panes: [SettingsPane]
    public let sources: [SettingsSourceModel]
    public let storedEvents: StoredEventsModel

    public init(sources: [SettingsSourceModel], storedEvents: StoredEventsModel = StoredEventsModel(size: nil)) {
        self.sources = sources
        self.storedEvents = storedEvents
        panes = [.general, .appearance, .sessions, .notifications, .menuBar] + sources.map { .source($0.source) } + [.about]
    }

    /// The pane ↑ (-1) or ↓ (1) selects in the sidebar: like the list it replaces, one step
    /// along `panes` that stops at either end. A selection the sidebar does not list starts
    /// over at the top.
    public func pane(from pane: SettingsPane, moving offset: Int) -> SettingsPane {
        panes.arrowKeyStep(from: pane, by: offset) ?? panes.first ?? pane
    }

    /// Under the "Check for subspace updates" switch: the first time the app
    /// itself goes online, so it names where, how often, and that nothing is sent.
    public static let updatesFootnote: LocalizedStringResource = .kit(
        "Once a day, and when you open Setup or a source, The Collective asks GitHub which versions of subspace are published. Nothing about you or your sessions is sent. A required update is shown even when this is off.",
        defaultValue: "Once a day, and when you open Setup or a source, The Collective asks GitHub which versions of subspace are published. Nothing about you or your sessions is sent. A required update is shown even when this is off."
    )

    /// The popup of "Keep finished sessions visible".
    public static let retentionOptions = FinishedRetention.allCases

    public static let retentionFootnote: LocalizedStringResource = .kit(
        "Applies to done and stale sessions. Working sessions always stay.",
        defaultValue: "Applies to done and stale sessions. Working sessions always stay."
    )

    /// The popup of "Move sessions to Idle after"; `never` comes last, after a divider.
    public static let idleOptions = IdleAfter.allCases

    /// The popup of "A turn finishes"; `never` comes last, after a divider.
    public static let turnFinishedOptions = TurnFinishedAfter.allCases

    public static let idleFootnote: LocalizedStringResource = .kit(
        "A session goes idle when it has waited this long for your next prompt and nothing runs in the background. Sessions waiting for permission or an answer never go idle. Never keeps every session at the top.",
        defaultValue: "A session goes idle when it has waited this long for your next prompt and nothing runs in the background. Sessions waiting for permission or an answer never go idle. Never keeps every session at the top."
    )

    /// The popup of "Keep events for".
    public static let eventRetentionOptions = EventRetention.allCases

    public static let eventRetentionFootnote: LocalizedStringResource = .kit(
        "Stored events let sessions survive a restart. A shorter time uses less space; a session open longer loses its beginning after a restart.",
        defaultValue: "Stored events let sessions survive a restart. A shorter time uses less space; a session open longer loses its beginning after a restart."
    )

    /// The last row of the Notifications pane, next to "Open System Settings":
    /// how notifications look is the system's, and while the user turned them
    /// off there no switch here shows anything.
    /// - Parameter turnedOff: The user denied the app notifications.
    public static func notificationsFootnote(turnedOff: Bool) -> LocalizedStringResource {
        turnedOff
            ? .kit(
                "Notifications for The Collective are turned off in System Settings.",
                defaultValue: "Notifications for The Collective are turned off in System Settings."
            )
            : .kit(
                "Banner style and Focus are set in System Settings.",
                defaultValue: "Banner style and Focus are set in System Settings."
            )
    }

    /// The app's own page in System Settings → Notifications.
    public static func notificationSettingsURL(bundleIdentifier: String) -> URL? {
        var components = URLComponents()
        components.scheme = "x-apple.systempreferences"
        components.path = "com.apple.Notifications-Settings.extension"
        components.queryItems = [URLQueryItem(name: "id", value: bundleIdentifier)]
        return components.url
    }

    /// Accessibility › Display, where Reduce Motion is switched. The legacy pane
    /// id with the `Seeing_Display` anchor is what macOS itself opens it with
    /// (its Siri settings code ships this exact URL); the Accessibility
    /// extension declares `com.apple.preference.universalaccess` as its legacy
    /// id, so System Settings routes the id and anchor to it.
    public static let reduceMotionSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display")!

    /// The subspace base link for the explanation in Setup and About. A tool's own
    /// row links its adapter's `IntegrationProbe.commands.sourceURL`, not this.
    public static let subspaceURL = URL(string: "https://github.com/we-are-the-borg/subspace")!
}

/// The "Stored events" row of the Sessions pane.
public struct StoredEventsModel: Sendable, Equatable {
    /// The size on disk as text, e.g. "14.6 MB"; nil while unknown.
    public let sizeText: String?
    /// False while the size is unknown or zero, and while a clear runs.
    public let canClear: Bool
    /// The confirmation dialog's message; names the size. Nil while the size is unknown, so it never reads "the  of events".
    public let confirmationMessage: LocalizedStringResource?

    public init(size: Int64?, isClearing: Bool = false) {
        let text = size?.formatted(.byteCount(style: .file))
        sizeText = text
        canClear = (size ?? 0) > 0 && !isClearing
        confirmationMessage = text.map { shown in
            .kit(
                "This deletes the %@ of events The Collective stored on this Mac. Events still in subspace’s folders are read again right away; archived sessions and settings stay.",
                defaultValue: "This deletes the \(shown) of events The Collective stored on this Mac. Events still in subspace’s folders are read again right away; archived sessions and settings stay."
            )
        }
    }
}

/// Why "Clear…" deleted nothing or not everything.
public enum StoredEventsClearFailure: Sendable, Equatable {
    /// Another copy of the app uses the stored events.
    case inUse
    /// Files could not be deleted.
    case failed

    /// Sorts what `StoredEvents.clear` threw: it throws `EWOULDBLOCK` while anyone holds the store's lock.
    public init(_ error: any Error) {
        self = (error as? POSIXError)?.code == .EWOULDBLOCK ? .inUse : .failed
    }

    public var message: LocalizedStringResource {
        switch self {
        case .inUse:
            .kit(
                "Another copy of The Collective is using them. Quit it and try again.",
                defaultValue: "Another copy of The Collective is using them. Quit it and try again."
            )
        case .failed:
            .kit(
                "Some files couldn’t be deleted. Try again.",
                defaultValue: "Some files couldn’t be deleted. Try again."
            )
        }
    }
}

/// Fixed labels of the settings window, kept here so every text lives in the kit's catalog.
public enum SettingsText {
    public static let general: LocalizedStringResource = .kit("General", defaultValue: "General")
    /// The pane with the scheme slots and their browsers.
    public static let appearance: LocalizedStringResource = .kit("Appearance", defaultValue: "Appearance")
    public static let sessions: LocalizedStringResource = .kit("Sessions", defaultValue: "Sessions")
    public static let sources: LocalizedStringResource = .kit("Sources", defaultValue: "Sources")
    public static let about: LocalizedStringResource = .kit("About", defaultValue: "About")
    public static let launchAtLogin: LocalizedStringResource = .kit("Launch at login", defaultValue: "Launch at login")
    /// The header of General's group with the effort gauge's switch.
    public static let popover: LocalizedStringResource = .kit("Popover", defaultValue: "Popover")
    public static let colorEffortLevels: LocalizedStringResource = .kit("Color effort levels", defaultValue: "Color effort levels")
    /// Under the group with the switch and its preview.
    public static let effortGaugeFootnote: LocalizedStringResource = .kit(
        "The effort gauge sits next to the model name in session rows and in the subagent list. Its fill shows the level either way; the exact level is in the tooltip.",
        defaultValue: "The effort gauge sits next to the model name in session rows and in the subagent list. Its fill shows the level either way; the exact level is in the tooltip."
    )
    public static let keepFinishedVisible: LocalizedStringResource = .kit(
        "Keep finished sessions visible", defaultValue: "Keep finished sessions visible"
    )
    public static let moveToIdleAfter: LocalizedStringResource = .kit(
        "Move sessions to Idle after", defaultValue: "Move sessions to Idle after"
    )
    public static let keepEvents: LocalizedStringResource = .kit(
        "Keep events for", defaultValue: "Keep events for"
    )
    /// The label of the row that shows a source's integration state.
    public static let subspace: LocalizedStringResource = .kit("subspace", defaultValue: "subspace")
    public static let data: LocalizedStringResource = .kit("Data", defaultValue: "Data")
    public static let eventFolder: LocalizedStringResource = .kit("Event folder", defaultValue: "Event folder")
    public static let reset: LocalizedStringResource = .kit("Reset", defaultValue: "Reset")
    public static let choose: LocalizedStringResource = .kit("Choose…", defaultValue: "Choose…")
    public static let defaultMarker: LocalizedStringResource = .kit("(default)", defaultValue: "(default)")
    public static let setUp: LocalizedStringResource = .kit("Set Up…", defaultValue: "Set Up…")
    /// The row that shows how much space the stored events use, with its clear button.
    public static let storedEvents: LocalizedStringResource = .kit("Stored events", defaultValue: "Stored events")
    public static let clear: LocalizedStringResource = .kit("Clear…", defaultValue: "Clear…")
    public static let clearTitle: LocalizedStringResource = .kit("Clear stored events?", defaultValue: "Clear stored events?")
    /// The destructive button of the confirmation.
    public static let clearConfirm: LocalizedStringResource = .kit("Clear", defaultValue: "Clear")
    public static let cancel: LocalizedStringResource = .kit("Cancel", defaultValue: "Cancel")
    /// The title of the alert that follows a failed clear.
    public static let clearFailedTitle: LocalizedStringResource = .kit(
        "Stored events couldn’t be cleared", defaultValue: "Stored events couldn’t be cleared"
    )
    public static let ok: LocalizedStringResource = .kit("OK", defaultValue: "OK")
    public static let notifications: LocalizedStringResource = .kit("Notifications", defaultValue: "Notifications")
    /// The header of the switches for what is notified.
    public static let notifyWhen: LocalizedStringResource = .kit("Notify when", defaultValue: "Notify when")
    public static let notifyPermission: LocalizedStringResource = .kit(
        "An agent needs permission", defaultValue: "An agent needs permission"
    )
    public static let notifyQuestion: LocalizedStringResource = .kit(
        "An agent asks a question", defaultValue: "An agent asks a question"
    )
    public static let notifyTurnFinished: LocalizedStringResource = .kit(
        "A turn finishes", defaultValue: "A turn finishes"
    )
    /// The header of one switch per source, each labelled with the tool's name.
    public static let notifyFor: LocalizedStringResource = .kit("Notify for", defaultValue: "Notify for")
    public static let playSound: LocalizedStringResource = .kit("Play sound", defaultValue: "Play sound")
    public static let openSystemSettings: LocalizedStringResource = .kit(
        "Open System Settings", defaultValue: "Open System Settings"
    )
    /// The sidebar entry and title of the pane with the cube's animation.
    public static let menuBar: LocalizedStringResource = .kit("Menu Bar", defaultValue: "Menu Bar")
    /// The header of the radio group that sets when the cube moves.
    public static let animateTheIcon: LocalizedStringResource = .kit("Animate the icon", defaultValue: "Animate the icon")
    public static let frameRate: LocalizedStringResource = .kit("Frame rate", defaultValue: "Frame rate")
    public static let menuBarFootnote: LocalizedStringResource = .kit(
        "The app draws the cube frame by frame while it moves, which costs some CPU; a still icon costs nothing. Idle and warnings never move, and every state keeps its color.",
        defaultValue: "The app draws the cube frame by frame while it moves, which costs some CPU; a still icon costs nothing. Idle and warnings never move, and every state keeps its color."
    )
    /// The note above the radio group while the system's Reduce Motion is on.
    public static let reduceMotionIsOn: LocalizedStringResource = .kit("Reduce Motion is on", defaultValue: "Reduce Motion is on")
    public static let reduceMotionNote: LocalizedStringResource = .kit(
        "The icon stays still in its color. Your choice below applies again when you turn Reduce Motion off.",
        defaultValue: "The icon stays still in its color. Your choice below applies again when you turn Reduce Motion off."
    )
    /// The note's button, which opens Accessibility › Display
    /// (`SettingsModel.reduceMotionSettingsURL`). Its own key: the design
    /// gives it the ellipsis the Notifications button doesn't have.
    public static let openDisplaySettings: LocalizedStringResource = .kit(
        "Open System Settings…", defaultValue: "Open System Settings…"
    )
    /// The header of General's section with the update switch.
    public static let updates: LocalizedStringResource = .kit("Updates", defaultValue: "Updates")
    /// One switch for all sources, on by default.
    public static let checkForSubspaceUpdates: LocalizedStringResource = .kit(
        "Check for subspace updates", defaultValue: "Check for subspace updates"
    )
    // The line under each pane's heading.
    public static let generalDescription: LocalizedStringResource = .kit(
        "How The Collective starts, what the popover shows and when it looks for updates.",
        defaultValue: "How The Collective starts, what the popover shows and when it looks for updates."
    )
    public static let appearanceDescription: LocalizedStringResource = .kit(
        "Colors for the popover, settings and setup.",
        defaultValue: "Colors for the popover, settings and setup."
    )
    public static let sessionsDescription: LocalizedStringResource = .kit(
        "How long finished sessions stay, when sessions go idle and what is kept on this Mac.",
        defaultValue: "How long finished sessions stay, when sessions go idle and what is kept on this Mac."
    )
    public static let notificationsDescription: LocalizedStringResource = .kit(
        "When The Collective notifies you, for which tools and with which sound.",
        defaultValue: "When The Collective notifies you, for which tools and with which sound."
    )
    public static let menuBarDescription: LocalizedStringResource = .kit(
        "When the cube in the menu bar moves and how smoothly.",
        defaultValue: "When the cube in the menu bar moves and how smoothly."
    )
    public static func sourceDescription(name: String) -> LocalizedStringResource {
        .kit("How The Collective sees your %@ sessions through subspace.", defaultValue: "How The Collective sees your \(name) sessions through subspace.")
    }

    /// "Quit The Collective" shows its shortcut only here.
    public static let quitTooltip: LocalizedStringResource = .kit("⌘Q", defaultValue: "⌘Q")

    /// The info row under a source's subspace group, in every state.
    public static func sourceInfo(name: String) -> LocalizedStringResource {
        .kit(
            "subspace is the small plugin through which The Collective sees your %@ sessions. It records what they do and never steers them.",
            defaultValue: "subspace is the small plugin through which The Collective sees your \(name) sessions. It records what they do and never steers them."
        )
    }

    /// The info row's link to the adapter's `sourceURL`.
    public static func sourceInfoLink(name: String) -> LocalizedStringResource {
        .kit("subspace for %@ on GitHub ↗", defaultValue: "subspace for \(name) on GitHub ↗")
    }

    /// What subspace is, word for word in the setup window's head and About's subspace group.
    public static let subspaceSentence: LocalizedStringResource = .kit(
        "The Collective sees your agents through subspace, a small plugin that records what they do and never steers them.",
        defaultValue: "The Collective sees your agents through subspace, a small plugin that records what they do and never steers them."
    )
    /// After `subspaceSentence`, to `SettingsModel.subspaceURL`.
    public static let learnMore: LocalizedStringResource = .kit("Learn more ↗", defaultValue: "Learn more ↗")
    public static let learnMoreAccessibilityLabel: LocalizedStringResource = .kit(
        "Learn more about subspace on GitHub", defaultValue: "Learn more about subspace on GitHub"
    )

    /// About's row per source, to the adapter's `sourceURL`.
    public static func aboutSourceLink(name: String) -> LocalizedStringResource {
        .kit("subspace for %@ ↗", defaultValue: "subspace for \(name) ↗")
    }

    /// About's group of licenses and the sheet's title.
    public static let acknowledgements: LocalizedStringResource = .kit("Acknowledgements", defaultValue: "Acknowledgements")
    public static let libraries: LocalizedStringResource = .kit("Libraries", defaultValue: "Libraries")
    public static let fontsAndIcons: LocalizedStringResource = .kit("Fonts and icons", defaultValue: "Fonts and icons")
    public static let colorSchemes: LocalizedStringResource = .kit("Color schemes", defaultValue: "Color schemes")
    public static let licenseTextsFootnote: LocalizedStringResource = .kit(
        "The full license texts ship with the app.", defaultValue: "The full license texts ship with the app."
    )
    /// Opens the Acknowledgements sheet.
    public static let showLicenseTexts: LocalizedStringResource = .kit("Show License Texts…", defaultValue: "Show License Texts…")
    /// VoiceOver of an acknowledgement's ↗, e.g. "GRDB.swift website".
    public static func website(name: String) -> LocalizedStringResource {
        .kit("%@ website", defaultValue: "\(name) website")
    }
    /// Closes the Acknowledgements and the Release Notes sheet.
    public static let done: LocalizedStringResource = .kit("Done", defaultValue: "Done")

    /// About's button that opens the Release Notes sheet.
    public static let releaseNotesButton: LocalizedStringResource = .kit("Release Notes…", defaultValue: "Release Notes…")
    /// The Release Notes sheet's title.
    public static let releaseNotes: LocalizedStringResource = .kit("Release Notes", defaultValue: "Release Notes")
    /// The pill after the version this copy of the app is.
    public static let installed: LocalizedStringResource = .kit("Installed", defaultValue: "Installed")
    /// The sheet's link to `ReleaseNotes.allReleasesURL`.
    public static let allReleasesOnGitHub: LocalizedStringResource = .kit(
        "All releases on GitHub ↗", defaultValue: "All releases on GitHub ↗"
    )

    /// The tooltip of a source's sidebar arrow.
    public static let updateAvailable: LocalizedStringResource = .kit("Update available", defaultValue: "Update available")
}

/// The live preview under "Color effort levels": all five gauges side by
/// side, colored or gray as the switch is, so the user sees what the switch
/// does before opening the popover.
public struct EffortGaugePreview: Sendable, Equatable {
    public struct Gauge: Sendable, Equatable {
        public let step: Int
        /// Under the gauge, e.g. "high".
        public let label: LocalizedStringResource
        public let isColored: Bool

        /// The fill, as in the popover (`EffortLabel.role`).
        public var role: ThemeRole { EffortLabel.role(step: step, isColored: isColored) }
    }

    public let gauges: [Gauge]
    public let isColored: Bool

    public init(colorsEffortLevels: Bool) {
        isColored = colorsEffortLevels
        // The labels follow the design's sample scale; real levels come
        // named by their tool and show only in the popover.
        let labels: [LocalizedStringResource] = [
            .kit("low", defaultValue: "low"), .kit("medium", defaultValue: "medium"), .kit("high", defaultValue: "high"),
            .kit("xhigh", defaultValue: "xhigh"), .kit("max", defaultValue: "max"),
        ]
        gauges = labels.enumerated().map { Gauge(step: $0.offset + 1, label: $0.element, isColored: colorsEffortLevels) }
    }

    /// The hint under the switch, which changes with it.
    public var hint: LocalizedStringResource {
        isColored
            ? .kit("Each level has its own color, from green for low to purple for max.", defaultValue: "Each level has its own color, from green for low to purple for max.")
            : .kit("All levels in gray, like the model name.", defaultValue: "All levels in gray, like the model name.")
    }
}
