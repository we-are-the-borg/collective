import Foundation
import Testing
@testable import CollectiveKit

@Suite struct SettingsModelTests {
    let home = "/Users/user"
    let defaultFolder = URL(filePath: "/Users/user/.tool/data/subspace")

    func row(_ status: IntegrationStatus?, chosen: URL? = nil, defaults folders: [URL]? = nil, sourceURL: URL? = nil) -> SettingsSourceModel {
        SettingsSourceModel(
            source: "test-tool", name: "Test Tool", sourceURL: sourceURL, status: status,
            defaultFolders: folders ?? [defaultFolder], chosenFolder: chosen, home: home
        )
    }

    func text(_ resource: LocalizedStringResource) -> String { String(localized: resource) }

    // MARK: status

    @Test(arguments: [
        (IntegrationStatus.Plugin.enabled(version: "1.0.1"), Date?.some(Date(timeIntervalSince1970: 1)), "Connected · 1.0.1", SettingsSourceModel.ButtonStyle?.none),
        (.enabled(version: "1.0.1"), nil, "Waiting for a session · 1.0.1", .normal),
        (.disabled(version: "1.0.1"), nil, "Disabled · 1.0.1", .primary),
        (.enabled(version: nil), Date(timeIntervalSince1970: 1), "Connected", nil),
        (.enabled(version: nil), nil, "Waiting for a session", .normal),
        (.disabled(version: nil), nil, "Disabled", .primary),
        (.notInstalled, nil, "Not set up", .primary),
        // A failed check with nothing known before it claims nothing, as before the first one.
        (.unknown, nil, "Checking…", nil),
    ])
    func statusRow(plugin: IntegrationStatus.Plugin, started: Date?, label: String, button: SettingsSourceModel.ButtonStyle?) {
        let model = row(integration(plugin, lastSessionStartAt: started))
        #expect(text(model.status.text) == label)
        #expect(model.setUpButton == button)
    }

    /// The pane draws the word in the form's role and the version after it in `--text-subtle`;
    /// together they read as the sidebar's status text.
    @Test(arguments: [
        (IntegrationStatus.Plugin.enabled(version: "1.0.1"), Date?.some(Date(timeIntervalSince1970: 1)), "Connected", String?.some("1.0.1")),
        (.enabled(version: "1.0.1"), nil, "Waiting for a session", "1.0.1"),
        (.disabled(version: "1.0.1"), nil, "Disabled", "1.0.1"),
        (.enabled(version: nil), Date(timeIntervalSince1970: 1), "Connected", nil),
        (.disabled(version: nil), nil, "Disabled", nil),
        (.notInstalled, nil, "Not set up", nil),
        (.unknown, nil, "Checking…", nil),
    ])
    func statusWordAndVersion(plugin: IntegrationStatus.Plugin, started: Date?, word: String, version: String?) {
        let model = row(integration(plugin, lastSessionStartAt: started))
        #expect(text(model.statusWord) == word)
        #expect(model.statusVersion == version)
        #expect(text(model.status.text) == ([word] + (version.map { [$0] } ?? [])).joined(separator: " · "))
    }

    @Test func notFoundAndNotCheckedYetShowNoVersion() {
        for model in [row(integration(.notInstalled, cli: .notFound)), row(integration(.unknown, cli: .notFound)), row(nil)] {
            #expect(model.statusVersion == nil)
        }
        #expect(text(row(nil).statusWord) == "Checking…")
        #expect(text(row(integration(.notInstalled, cli: .notFound)).statusWord) == "Not found")
    }

    /// The restyled form in front of the sidebar row and the pane's status word, which takes its role.
    @Test(arguments: [
        (IntegrationStatus.Plugin.enabled(version: "1.0.1"), Date?.some(Date(timeIntervalSince1970: 1)), SourceStatusShape.dot, ThemeRole.success),
        (.enabled(version: "1.0.1"), nil, .ringWithDot, .info),
        (.disabled(version: "1.0.1"), nil, .triangle, .warning),
        (.notInstalled, nil, .hollowRing, .textSubtle),
        (.unknown, nil, .hollowRing, .textSubtle),
    ])
    func statusMark(plugin: IntegrationStatus.Plugin, started: Date?, shape: SourceStatusShape, role: ThemeRole) {
        let mark = row(integration(plugin, lastSessionStartAt: started)).statusMark
        #expect(mark == SourceStatusMark(shape: shape, role: role))
    }

    @Test func notFoundAndNotCheckedYetShowAHollowRing() {
        let hollow = SourceStatusMark(shape: .hollowRing, role: .textSubtle)
        #expect(row(integration(.notInstalled, cli: .notFound)).statusMark == hollow)
        #expect(row(integration(.unknown, cli: .notFound)).statusMark == hollow)
        #expect(row(nil).statusMark == hollow)
    }

    @Test func notFound() {
        let model = row(integration(.notInstalled, cli: .notFound))
        #expect(text(model.status.text) == "Not found")
        #expect(model.setUpButton == .normal)
    }

    @Test func unknownPluginWithoutCLIIsNotFound() {
        let model = row(integration(.unknown, cli: .notFound))
        #expect(text(model.status.text) == "Not found")
        #expect(model.setUpButton == .normal)
    }

    @Test func notCheckedYetClaimsNothing() {
        let model = row(nil)
        #expect(text(model.status.text) == "Checking…")
        #expect(model.setUpButton == nil)
    }

    @Test func stateComesFromTheSetupCard() {
        let status = integration(.disabled(version: nil))
        #expect(SetupCardModel.state(of: status) == .disabled)
        #expect(text(row(status).status.text) == text(SetupCardModel(status, now: .now, home: home).pill!.text))
    }

    /// An event the app read stands in for subspace's record of a
    /// session start, here as in the setup window.
    @Test func anEventConnectsAnEnabledPluginLikeTheSetupCard() {
        let status = integration(.enabled(version: nil), lastSessionStartAt: nil)
        let event = Date(timeIntervalSince1970: 1)
        let model = SettingsSourceModel(
            source: "test-tool", name: "Test Tool", status: status, lastEventAt: event,
            defaultFolders: [defaultFolder], chosenFolder: nil, home: home
        )
        let card = SetupCardModel(status, lastEventAt: event, now: .now, home: home)
        #expect(card.state == .ready)
        #expect(text(model.status.text) == text(card.pill!.text))
        #expect(model.setUpButton == nil)
        #expect(text(row(status).status.text) == "Waiting for a session")
        #expect(row(status).setUpButton == .normal)
    }

    // MARK: event folder

    @Test func unchosenFolderIsTheDefault() {
        let model = row(nil)
        #expect(model.eventFolderPaths == ["~/.tool/data/subspace"])
        #expect(model.showsDefaultMarker)
        #expect(!model.canReset)
    }

    @Test func chosenFolder() {
        let model = row(nil, chosen: URL(filePath: "/Users/user/Dropbox/events"))
        #expect(model.eventFolderPaths == ["~/Dropbox/events"])
        #expect(!model.showsDefaultMarker)
        #expect(model.canReset)
    }

    @Test func folderOutsideHomeStaysAbsolute() {
        let model = row(nil, chosen: URL(filePath: "/Volumes/Data/events"))
        #expect(model.eventFolderPaths == ["/Volumes/Data/events"])
    }

    @Test func everyDefaultFolderShowsWhileNoneIsChosen() {
        let defaults = [URL(filePath: "/Users/user/.tool/cli/subspace"), URL(filePath: "/Users/user/.tool/app/subspace")]
        let model = row(nil, defaults: defaults)
        #expect(model.eventFolderPaths == ["~/.tool/cli/subspace", "~/.tool/app/subspace"])
        #expect(model.showsDefaultMarker)
        #expect(!model.canReset)
    }

    @Test func aChosenFolderShowsAloneInsteadOfAllDefaults() {
        let defaults = [URL(filePath: "/Users/user/.tool/cli/subspace"), URL(filePath: "/Users/user/.tool/app/subspace")]
        let model = row(nil, chosen: URL(filePath: "/Users/user/Dropbox/events"), defaults: defaults)
        #expect(model.eventFolderPaths == ["~/Dropbox/events"])
        #expect(!model.showsDefaultMarker)
        #expect(model.canReset)
    }

    // MARK: source link

    func status(url: String?) -> IntegrationStatus {
        var status = integration(.enabled(version: "1.0.1"))
        status.commands.sourceURL = url.flatMap(URL.init(string:))
        return status
    }

    @Test func sourceLinkPassesThrough() {
        let model = row(status(url: "https://github.com/we-are-the-borg/subspace-codex"))
        #expect(model.sourceURL == URL(string: "https://github.com/we-are-the-borg/subspace-codex"))
        #expect(model.repositoryName == "we-are-the-borg/subspace-codex")
    }

    @Test(arguments: [nil, "https://github.com/"] as [String?])
    func noSourceLink(url: String?) {
        #expect(row(status(url: url)).repositoryName == nil)
        #expect(row(nil).sourceURL == nil)
    }

    /// The registered source names its plugin before the first probe returns.
    @Test func sourceLinkWithoutAProbe() {
        let model = row(nil, sourceURL: URL(string: "https://github.com/we-are-the-borg/subspace-codex"))
        #expect(model.sourceURL == URL(string: "https://github.com/we-are-the-borg/subspace-codex"))
        #expect(model.repositoryName == "we-are-the-borg/subspace-codex")
    }

    @Test(arguments: ["https://github.com/owner/repo/", "https://github.com/owner/repo.git", "https://github.com/owner/repo.git/"])
    func repositoryNameDropsATrailingSlashAndGitSuffix(url: String) {
        #expect(row(nil, sourceURL: URL(string: url)).repositoryName == "owner/repo")
    }

    @Test func realProbesNameTheirRepositoryBeforeTheyCheck() {
        let home = URL(filePath: home, directoryHint: .isDirectory)
        let probes: [(any IntegrationProbe, String)] = [
            (ClaudeCodeIntegrationProbe(environment: [:], home: home), "we-are-the-borg/subspace-claude-code"),
            (CodexIntegrationProbe(environment: [:], home: home), "we-are-the-borg/subspace-codex"),
            (AntigravityIntegrationProbe(environment: [:], home: home), "we-are-the-borg/subspace-antigravity"),
        ]
        for (probe, name) in probes {
            #expect(row(nil, sourceURL: probe.commands.sourceURL).repositoryName == name)
        }
    }

    @Test func realAdaptersNameTheirRepository() {
        for (commands, name) in [(ClaudeCodeSubspace.commands, "we-are-the-borg/subspace-claude-code"),
                                 (CodexSubspace.commands, "we-are-the-borg/subspace-codex"),
                                 (AntigravitySubspace.commands, "we-are-the-borg/subspace-antigravity")] {
            var status = integration(.enabled(version: "1.0.1"))
            status.commands = commands
            #expect(row(status).repositoryName == name)
        }
    }

    // MARK: panes

    @Test func paneOrder() {
        let a = row(nil)
        let b = SettingsSourceModel(source: "other", name: "Other", status: nil, defaultFolders: [defaultFolder], chosenFolder: nil, home: home)
        #expect(SettingsModel(sources: [a, b]).panes == [.general, .appearance, .sessions, .notifications, .menuBar, .source("test-tool"), .source("other"), .about])
        #expect(SettingsModel(sources: []).panes == [.general, .appearance, .sessions, .notifications, .menuBar, .about])
    }

    @Test(arguments: [SettingsPane.general, .appearance, .sessions, .notifications, .menuBar, .source("test-tool"), .source("a:b"), .about])
    func paneRoundTrip(pane: SettingsPane) {
        #expect(SettingsPane(rawValue: pane.rawValue) == pane)
    }

    @Test func paneEncoding() {
        #expect(SettingsPane.source("claude-code").rawValue == "source:claude-code")
        #expect(SettingsPane.notifications.rawValue == "notifications")
        #expect(SettingsPane.appearance.rawValue == "appearance")
        #expect(SettingsPane(rawValue: "nonsense") == nil)
        #expect(SettingsPane(rawValue: "source:") == nil)
    }

    /// ↑ ↓ in the sidebar walk `panes` like the list they replace: one step, stopping at either end.
    @Test func arrowKeysWalkThePanesInSidebarOrder() {
        let model = SettingsModel(sources: [row(nil)])
        #expect(model.pane(from: .general, moving: 1) == .appearance)
        #expect(model.pane(from: .menuBar, moving: 1) == .source("test-tool"))
        #expect(model.pane(from: .source("test-tool"), moving: 1) == .about)
        #expect(model.pane(from: .about, moving: -1) == .source("test-tool"))
        #expect(model.pane(from: .appearance, moving: -1) == .general)
    }

    @Test func arrowKeysStopAtEitherEnd() {
        let model = SettingsModel(sources: [row(nil)])
        #expect(model.pane(from: .general, moving: -1) == .general)
        #expect(model.pane(from: .about, moving: 1) == .about)
    }

    /// A selection the sidebar does not list, e.g. of a source removed meanwhile, starts over at the top.
    @Test func arrowKeysFromAPaneNotListedStartAtTheTop() {
        let model = SettingsModel(sources: [row(nil)])
        #expect(model.pane(from: .source("gone"), moving: 1) == .general)
        #expect(model.pane(from: .source("gone"), moving: -1) == .general)
    }

    @Test func removedSourceFallsBackToGeneral() {
        #expect(SettingsPane.restoring("source:gone", sources: ["test-tool"]) == .general)
        #expect(SettingsPane.restoring("source:test-tool", sources: ["test-tool"]) == .source("test-tool"))
        #expect(SettingsPane.restoring("about", sources: []) == .about)
        #expect(SettingsPane.restoring("appearance", sources: []) == .appearance)
        #expect(SettingsPane.restoring("notifications", sources: []) == .notifications)
        #expect(SettingsPane.restoring("", sources: []) == .general)
    }

    // MARK: restyled texts

    @Test func everyPaneHasItsDescription() {
        #expect(text(SettingsText.appearance) == "Appearance")
        #expect(text(SettingsText.generalDescription) == "How The Collective starts, what the popover shows and when it looks for updates.")
        #expect(text(SettingsText.appearanceDescription) == "Colors for the popover, settings and setup.")
        #expect(text(SettingsText.sessionsDescription) == "How long finished sessions stay, when sessions go idle and what is kept on this Mac.")
        #expect(text(SettingsText.notificationsDescription) == "When The Collective notifies you, for which tools and with which sound.")
        #expect(text(SettingsText.menuBarDescription) == "When the cube in the menu bar moves and how smoothly.")
        #expect(text(SettingsText.sourceDescription(name: "Codex")) == "How The Collective sees your Codex sessions through subspace.")
    }

    @Test func theQuitButtonsTooltipNamesItsShortcut() {
        #expect(text(SettingsText.quitTooltip) == "⌘Q")
    }

    /// The info row under a source's subspace group, linking the tool's own plugin.
    @Test func theSourceInfoRowExplainsSubspace() {
        #expect(text(SettingsText.sourceInfo(name: "Claude Code"))
            == "subspace is the small plugin through which The Collective sees your Claude Code sessions. It records what they do and never steers them.")
        #expect(text(SettingsText.sourceInfoLink(name: "Codex")) == "subspace for Codex on GitHub ↗")
    }

    /// The setup header and the About group: the sentence, its link and where it points.
    @Test func subspaceIsExplainedWithALinkToItsBase() {
        #expect(text(SettingsText.subspaceSentence)
            == "The Collective sees your agents through subspace, a small plugin that records what they do and never steers them.")
        #expect(text(SettingsText.learnMore) == "Learn more ↗")
        #expect(text(SettingsText.learnMoreAccessibilityLabel) == "Learn more about subspace on GitHub")
        #expect(SettingsModel.subspaceURL.absoluteString == "https://github.com/we-are-the-borg/subspace")
    }

    @Test func aboutTexts() {
        #expect(text(SettingsText.aboutSourceLink(name: "Claude Code")) == "subspace for Claude Code ↗")
        #expect(text(SettingsText.acknowledgements) == "Acknowledgements")
        #expect(text(SettingsText.libraries) == "Libraries")
        #expect(text(SettingsText.fontsAndIcons) == "Fonts and icons")
        #expect(text(SettingsText.colorSchemes) == "Color schemes")
        #expect(text(SettingsText.licenseTextsFootnote) == "The full license texts ship with the app.")
        #expect(text(SettingsText.showLicenseTexts) == "Show License Texts…")
        #expect(text(SettingsText.website(name: "GRDB.swift")) == "GRDB.swift website")
        #expect(text(SettingsText.done) == "Done")
    }

    // MARK: notifications

    @Test func notificationsFootnoteFollowsTheSystemSetting() {
        #expect(text(SettingsModel.notificationsFootnote(turnedOff: false)) == "Banner style and Focus are set in System Settings.")
        #expect(text(SettingsModel.notificationsFootnote(turnedOff: true)) == "Notifications for The Collective are turned off in System Settings.")
    }

    /// Questions have their own switch, between permission and finished turns.
    @Test func theQuestionSwitchIsLabelled() {
        #expect(text(SettingsText.notifyPermission) == "An agent needs permission")
        #expect(text(SettingsText.notifyQuestion) == "An agent asks a question")
        #expect(text(SettingsText.notifyTurnFinished) == "A turn finishes")
    }

    // MARK: effort gauge

    @Test func theEffortColorSwitchIsLabelled() {
        #expect(text(SettingsText.popover) == "Popover")
        #expect(text(SettingsText.colorEffortLevels) == "Color effort levels")
        #expect(text(SettingsText.effortGaugeFootnote)
            == "The effort gauge sits next to the model name in session rows and in the subagent list. Its fill shows the level either way; the exact level is in the tooltip.")
    }

    @Test func theEffortPreviewShowsFiveLevelsAndFollowsTheSwitch() {
        let colored = EffortGaugePreview(colorsEffortLevels: true)
        #expect(colored.gauges.map(\.step) == [1, 2, 3, 4, 5])
        #expect(colored.gauges.map { text($0.label) } == ["low", "medium", "high", "xhigh", "max"])
        #expect(colored.gauges.allSatisfy { $0.isColored })
        #expect(text(colored.hint) == "Each level has its own color, from green for low to purple for max.")

        let gray = EffortGaugePreview(colorsEffortLevels: false)
        #expect(gray.gauges.map(\.step) == [1, 2, 3, 4, 5])
        #expect(gray.gauges.allSatisfy { !$0.isColored })
        #expect(text(gray.hint) == "All levels in gray, like the model name.")
    }

    /// The preview's gauges take the popover's roles.
    @Test func theEffortPreviewUsesThePopoversRoles() {
        #expect(EffortGaugePreview(colorsEffortLevels: true).gauges.map(\.role) == [.success, .info, .classCode, .accent, .accent])
        #expect(EffortGaugePreview(colorsEffortLevels: false).gauges.allSatisfy { $0.role == .textSubtle })
    }

    @Test func notificationSettingsOpenOnTheAppsPage() {
        #expect(SettingsModel.notificationSettingsURL(bundleIdentifier: "de.example.App")?.absoluteString
            == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=de.example.App")
    }

    // MARK: retention

    @Test func retentionOptions() {
        let options = SettingsModel.retentionOptions
        #expect(options == [.fiveMinutes, .tenMinutes, .thirtyMinutes, .oneHour])
        #expect(options.map { text($0.optionText) } == ["5 minutes", "10 minutes", "30 minutes", "1 hour"])
        #expect(text(SettingsModel.retentionFootnote) == "Applies to done and stale sessions. Working sessions always stay.")
        #expect(PopoverSettings().finishedRetention == .tenMinutes)
    }

    @Test func retentionRawValueRoundTrip() {
        for option in FinishedRetention.allCases {
            #expect(FinishedRetention(rawValue: option.rawValue) == option)
        }
        #expect(FinishedRetention(rawValue: "bogus") == nil)
    }

    @Test func turnFinishedOptions() {
        #expect(SettingsModel.turnFinishedOptions == [.always, .oneMinute, .threeMinutes, .fiveMinutes, .tenMinutes, .thirtyMinutes, .never])
    }

    @Test func idleOptions() {
        #expect(SettingsModel.idleOptions == [.fiveMinutes, .tenMinutes, .thirtyMinutes, .oneHour, .never])
        #expect(SettingsModel.idleOptions.map { text($0.optionText) } == ["5 minutes", "10 minutes", "30 minutes", "1 hour", "Never"])
        #expect(text(SettingsText.moveToIdleAfter) == "Move sessions to Idle after")
        #expect(text(SettingsModel.idleFootnote).hasPrefix("A session goes idle when"))
        // An open question keeps a session out of the group like a permission request.
        #expect(text(SettingsModel.idleFootnote).contains("Sessions waiting for permission or an answer never go idle."))
    }

    // MARK: event retention

    @Test func eventRetentionOptions() {
        #expect(SettingsModel.eventRetentionOptions == EventRetention.allCases)
        #expect(EventRetention.allCases == [.oneDay, .threeDays, .oneWeek, .unlimited])
        #expect(EventRetention.allCases.map { text($0.optionText) } == ["1 day", "3 days", "1 week", "Unlimited"])
        #expect(text(SettingsModel.eventRetentionFootnote) == "Stored events let sessions survive a restart. A shorter time uses less space; a session open longer loses its beginning after a restart.")
        #expect(text(SettingsText.keepEvents) == "Keep events for")
    }

    @Test func eventRetentionValues() {
        #expect(EventRetention.default == .threeDays)
        #expect(EventRetention.allCases.map(\.rawValue) == ["oneDay", "threeDays", "oneWeek", "unlimited"])
        #expect(EventRetention.oneDay.interval == 86_400)
        #expect(EventRetention.threeDays.interval == 259_200)
        #expect(EventRetention.oneWeek.interval == 604_800)
        #expect(EventRetention.unlimited.interval == nil)
        for option in EventRetention.allCases {
            #expect(EventRetention(rawValue: option.rawValue) == option)
        }
        #expect(EventRetention(rawValue: "bogus") == nil)
    }

    /// The app rebuilds its state for a longer time and prunes for a shorter one.
    @Test func eventRetentionOrdersByLength() {
        let shortestFirst: [EventRetention] = [.oneDay, .threeDays, .oneWeek, .unlimited]
        for (i, a) in shortestFirst.enumerated() {
            for (j, b) in shortestFirst.enumerated() {
                #expect((a < b) == (i < j), "\(a) < \(b)")
                #expect((a > b) == (i > j), "\(a) > \(b)")
            }
        }
    }

    // MARK: stored events

    @Test func storedEventsUnknownSizeCannotClear() {
        let stored = StoredEventsModel(size: nil)
        #expect(stored.sizeText == nil)
        #expect(stored.confirmationMessage == nil)
        #expect(!stored.canClear)
        #expect(!StoredEventsModel(size: 0).canClear)
    }

    @Test func storedEventsShowSizeAndClear() {
        let stored = StoredEventsModel(size: 15_300_000)
        #expect(stored.sizeText == Int64(15_300_000).formatted(.byteCount(style: .file)))
        #expect(stored.canClear)
        #expect(text(stored.confirmationMessage ?? "").contains(stored.sizeText ?? "?"))
        #expect(!StoredEventsModel(size: 15_300_000, isClearing: true).canClear)
    }

    @Test func settingsModelDefaultsToUnknownStoredEvents() {
        #expect(!SettingsModel(sources: []).storedEvents.canClear)
        #expect(SettingsModel(sources: [], storedEvents: StoredEventsModel(size: 1)).storedEvents.canClear)
    }

    @Test func storedEventsTexts() {
        #expect(text(SettingsText.storedEvents) == "Stored events")
        #expect(text(SettingsText.clear) == "Clear…")
        #expect(text(SettingsText.clearTitle) == "Clear stored events?")
        #expect(text(SettingsText.clearConfirm) == "Clear")
        #expect(text(SettingsText.cancel) == "Cancel")
    }

    @Test func storedEventsClearFailureTexts() {
        #expect(text(SettingsText.clearFailedTitle) == "Stored events couldn’t be cleared")
        #expect(text(SettingsText.ok) == "OK")
        #expect(text(StoredEventsClearFailure.inUse.message)
            == "Another copy of The Collective is using them. Quit it and try again.")
        #expect(text(StoredEventsClearFailure.failed.message) == "Some files couldn’t be deleted. Try again.")
    }

    @Test func storedEventsClearFailureFromError() {
        #expect(StoredEventsClearFailure(POSIXError(.EWOULDBLOCK)) == .inUse)
        #expect(StoredEventsClearFailure(POSIXError(.EACCES)) == .failed)
        #expect(StoredEventsClearFailure(CocoaError(.fileWriteNoPermission)) == .failed)
        #expect(StoredEventsClearFailure(StoredEvents.ClearError.overlapsSpoolRoot) == .failed)
    }
}
