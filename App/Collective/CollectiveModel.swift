import AppKit
import CollectiveKit
import Foundation
import Observation
import os
import SubspaceKit

/// Owns the state shown in the menu bar: reads the subspace spool and applies
/// its events. Thin on purpose; presentation rules belong in the kit.
@MainActor @Observable
final class CollectiveModel {
    private(set) var state = CollectiveState() {
        didSet { refreshMenuBarIcon() }
    }
    /// The aggregated icon, derived when `state` changes or a tool reports
    /// rather than per animation frame: it walks every agent of every session.
    private(set) var menuBarIcon = MenuBarIcon.idle
    /// What the user opened in the list (finished replies, the Finished group,
    /// the earlier sessions); it outlives popover rebuilds.
    private(set) var expansion = PopoverExpansion()
    /// Archives the user can still take back; their undo rows show in the popover.
    private(set) var undo = ArchiveUndo()
    /// Newest timestamp among spooled events, for the footer's "last event" line.
    private(set) var lastEventAt: Date?
    /// Newest timestamp per source among events read fresh from the spool, not
    /// replayed from the store, for the setup window's cards and the settings.
    private(set) var lastEvents = LastEventTimes()
    /// Advanced only while the icon animates; the kit derives the scene from it.
    private(set) var frameDate = Date()
    /// True until the spool reader has replayed its backlog, so the popover
    /// doesn't call the Collective dormant before it has read anything.
    private(set) var isLoading = true
    /// Whether the loading state is on screen. Stored rather than derived from the
    /// popover's clock: that turns only when the model asks for it, which the
    /// indicator's 300 ms delay and 500 ms minimum are not part of, so
    /// `loadingTask` updates this on time.
    private(set) var loadingIndicatorVisible = false
    private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// What each tool's last check found, in registration order; a tool that
    /// hasn't reported yet is absent, which warns about nothing.
    var integrations: [IntegrationStatus] { checks.statuses }
    /// Checks the tools, each on its own, so a slow CLI holds back only its
    /// own tool. Observed through itself, `checkedAt` too: an update group
    /// waiting for a probe after its run redraws even when the result didn't change.
    @ObservationIgnored private(set) lazy var checks = IntegrationChecks(
        probes: [],
        onResult: { [weak self] status, startedAt in self?.integrationChecked(status, startedAt: startedAt) }
    )
    /// Since when a source runs a newer subspace, for the popover's restart hint.
    private(set) var restartHints = SubspaceRestartHints()
    /// Set when the setup window should open without the user asking (first
    /// launch); the status item opens it, since no window is sure to exist.
    private(set) var setupWindowRequested = false
    /// The setup window's runs of a card's commands; a run that
    /// succeeded checks the tools again at once. Observed through itself.
    @ObservationIgnored private(set) lazy var setupRuns = SetupRuns(
        environment: ProcessInfo.processInfo.environment,
        runner: ProcessCommandRunner(),
        onSuccess: { [weak self] in self?.checks.check() }
    )
    /// Which subspace releases are published; observed through itself.
    /// The settings window binds its switch to `checksForUpdates`.
    @ObservationIgnored let releaseChecker = SubspaceReleaseChecker(
        client: URLSessionHTTPGetting(), store: UserDefaultsSubspaceReleaseStore()
    )
    /// The app's own updates (Sparkle); its `state` is observed through itself.
    @ObservationIgnored let appUpdater = SparkleUpdater()

    /// "Check for updates automatically": one switch for the app and subspace,
    /// stored by the release checker.
    var checksForUpdates: Bool {
        get { releaseChecker.checksForUpdates }
        set {
            releaseChecker.checksForUpdates = newValue
            appUpdater.setChecksAutomatically(newValue)
        }
    }
    /// The registered push adapters, in registration order, for the settings window.
    private(set) var sources: [RegisteredSource] = []
    /// The event folders the user chose, by source; a source without one reads its default.
    private(set) var chosenFolders: [SourceID: URL] = CollectiveModel.loadChosenFolders()
    /// How long the popover keeps finished sessions; observed, so a change shows at once.
    var finishedRetention = FinishedRetention(
        rawValue: UserDefaults.standard.string(forKey: CollectiveModel.finishedRetentionKey) ?? ""
    ) ?? .tenMinutes {
        didSet { UserDefaults.standard.set(finishedRetention.rawValue, forKey: Self.finishedRetentionKey) }
    }
    /// How long a session waits for the next prompt before the popover moves it to Idle.
    var idleAfter = IdleAfter(
        rawValue: UserDefaults.standard.string(forKey: CollectiveModel.idleAfterKey) ?? ""
    ) ?? .default {
        didSet { UserDefaults.standard.set(idleAfter.rawValue, forKey: Self.idleAfterKey) }
    }
    /// Holds the rests the open popover found when it opened, or once the backlog it
    /// opened during was read; none while closed. Only these may stand in Idle
    /// while it is open, so no row jumps into the group under the pointer.
    var idleOpening = IdleOpening()
    /// How long the app keeps the events it stored; a change applies at once (`eventRetentionChanged`).
    var eventRetention = EventRetention(
        rawValue: UserDefaults.standard.string(forKey: CollectiveModel.eventRetentionKey) ?? ""
    ) ?? .default {
        didSet {
            guard eventRetention != oldValue else { return }
            UserDefaults.standard.set(eventRetention.rawValue, forKey: Self.eventRetentionKey)
            eventRetentionChanged(from: oldValue)
        }
    }
    /// What the user wants to be notified of; the next batch follows a change.
    var notificationPreferences = NotificationPreferences(
        fromStored: UserDefaults.standard.object(forKey: CollectiveModel.notificationPreferencesKey)
    ) {
        didSet { UserDefaults.standard.set(notificationPreferences.stored, forKey: Self.notificationPreferencesKey) }
    }
    /// When and how fast the menu bar cube moves; a change starts,
    /// stops or retimes the frame tick at once.
    var menuBarAnimation = MenuBarAnimation(
        fromStored: UserDefaults.standard.object(forKey: CollectiveModel.menuBarAnimationKey)
    ) {
        didSet {
            guard menuBarAnimation != oldValue else { return }
            UserDefaults.standard.set(menuBarAnimation.stored, forKey: Self.menuBarAnimationKey)
            updateAnimation()
        }
    }
    /// Whether each effort gauge takes its level's color; observed, so an open popover follows at once.
    var colorsEffortLevels = UserDefaults.standard.object(forKey: CollectiveModel.colorsEffortLevelsKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(colorsEffortLevels, forKey: Self.colorsEffortLevelsKey) }
    }
    /// Posts and withdraws what `planner` plans; the app delegate sets it up at launch.
    @ObservationIgnored let notifier = Notifier()
    /// Disarmed while a backlog is read: from launch and from every rebuild of
    /// the state until its reader reports `.backlogFinished`.
    @ObservationIgnored private var planner = NotificationPlanner()
    /// The bytes the app keeps of the spool's events on disk; nil until first read.
    private(set) var storedEventsSize: Int64?
    /// True from the user's confirmation until the deletion is over, successful or not. Reading restarts after it,
    /// except when a clear next to a reader that doesn't hold the store fails: then nothing restarts.
    private(set) var isClearingStoredEvents = false
    /// Why the last clear failed; the settings window alerts while it is set and resets it.
    var storedEventsClearFailure: StoredEventsClearFailure?
    @ObservationIgnored private var sourceNames: [SourceID: String] = [:]
    @ObservationIgnored private var sourceLogos: [SourceID: String] = [:]
    @ObservationIgnored private var modelNaming: [SourceID: any ModelNaming] = [:]
    @ObservationIgnored private var resumeCommands: [SourceID: ResumeCommand] = [:]
    /// Keeps previews used by the popover across its rebuilds.
    @ObservationIgnored private let replyPreviewCache = ReplyPreviewCache()
    /// Which app shows a session's terminal; kept so its lookups are cached across rebuilds.
    @ObservationIgnored private let terminalApps = WorkspaceTerminalApps()
    /// After a jump to a session's terminal; the app delegate closes the popover.
    @ObservationIgnored var onTerminalShown: () -> Void = {}
    /// Sweep and reduce motion: they run from launch to quit.
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// The spool reader and the pull sources; rebuilt when a source's root moves.
    @ObservationIgnored private var readerTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var spoolReader: SpoolReader?
    /// Bumped whenever the readers are replaced; their consumers drop whatever
    /// arrives once it moved on, so a late batch or `.backlogFinished` of the old
    /// reader never lands in the fresh state or ends its loading.
    @ObservationIgnored private var readGeneration = 0
    /// The rebuild in progress, if any; the next one waits for it.
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var loadingIndicator = LoadingIndicator(launchedAt: Date())
    @ObservationIgnored private var loadingTask: Task<Void, Never>?
    @ObservationIgnored private var undoExpiryTask: Task<Void, Never>?
    @ObservationIgnored private let archiveFile = ArchiveFile(url: CollectiveModel.archiveURL)
    @ObservationIgnored private let readFile = ReadFile(url: CollectiveModel.readURL)
    /// How the current reading took the read marks; its backlog may mark everything read.
    @ObservationIgnored private var readMarksStart: ReadMarksStart?
    /// The unread rows the open popover showed; read only once it closes.
    @ObservationIgnored private var unreadReading = UnreadReading()
    /// Defensive guard: only rows seen while the popover is open count as read,
    /// whatever the hosting view's lifetime.
    @ObservationIgnored private var isPopoverOpen = false
    /// Set once the backlog is read: until then the reader's own prune at its
    /// start is still to come or running.
    @ObservationIgnored private var storeReader: SpoolReader?
    @ObservationIgnored private var storePrunedAt = Date()
    /// The prune in progress, if any; a rebuild waits for it (`restartReading`).
    /// A clear next to a running reader queues here too (`clearStoredEvents`).
    @ObservationIgnored private var pruneTask: Task<Void, Never>?
    /// Bumped with every size read; only the newest one publishes, so a read
    /// from before a clear never lands after the one that follows it.
    @ObservationIgnored private var storedEventsRefresh = 0
    /// The setup window opens by itself once, after every tool reported for the first time on the very first launch.
    private static let setupOfferedKey = "setupOffered"
    private static let finishedRetentionKey = "finishedRetention"
    private static let idleAfterKey = "idleAfter"
    private static let eventRetentionKey = "eventRetention"
    private static let notificationPreferencesKey = "notificationPreferences"
    private static let menuBarAnimationKey = "menuBarAnimation"
    private static let colorsEffortLevelsKey = "colorsEffortLevels"
    /// Paths by `SourceID` raw value; no sandbox, so plain paths keep working.
    private static let chosenFoldersKey = "eventFolders"
    /// The popover checks a tool again when it opens, unless its check finished this recently.
    private static let checkFreshness: TimeInterval = 10
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Collective", category: "StoredEvents")

    func start() {
        guard tasks.isEmpty else { return }
        appUpdater.start(checksAutomatically: checksForUpdates)
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.sweep()
                try? await Task.sleep(for: .seconds(5))
            }
        })
        tasks.append(Task { [weak self] in
            let center = NSWorkspace.shared.notificationCenter
            for await _ in center.notifications(named: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
                self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self?.updateAnimation()
            }
        })
        startReading()
    }

    /// The one place that names tools; everything else iterates what it returns.
    /// `chosen` are the folders the user picked, by source.
    nonisolated private static func register(chosen: [SourceID: URL]) -> Registration {
        // The adapter knows its own id; its mapping is only read on first use.
        let claudeCodeRoot = chosen[ClaudeCodeAdapter().source]
        let codexRoot = chosen[CodexAdapter().source]
        let antigravityRoot = chosen[AntigravityAdapter().source]
        return Registration(
            adapters: [
                ClaudeCodeAdapter(mapping: ClaudeCodeAdapter.defaultMapping(chosen: claudeCodeRoot)),
                CodexAdapter(mapping: CodexAdapter.defaultMapping(chosen: codexRoot)),
                AntigravityAdapter(mapping: AntigravityAdapter.defaultMapping(chosen: antigravityRoot)),
            ],
            pullSources: [ClaudeCodeSessionStatusSource(chosenRoot: claudeCodeRoot)],
            probes: [
                ClaudeCodeIntegrationProbe(chosenRoot: claudeCodeRoot),
                CodexIntegrationProbe(chosenRoot: codexRoot),
                // The kit doesn't import AppKit: the desktop app without `agy` is found here.
                AntigravityIntegrationProbe(chosenRoot: antigravityRoot, isAppInstalled: {
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
                }),
            ]
        )
    }

    /// Reads every registered source from its current root into a fresh state,
    /// at launch, after the user moved a root (`chooseFolder`) and after a longer
    /// `eventRetention`. Whatever read before must have stopped (`restartReading`).
    private func startReading() {
        loadingIndicator = LoadingIndicator(launchedAt: Date())
        isLoading = true
        idleOpening.readingStarted()
        updateLoadingIndicator()
        readGeneration += 1
        let generation = readGeneration
        lastEventAt = nil
        lastEvents = LastEventTimes()
        storeReader = nil
        // The reader prunes at its start; the sweep's next prune is an hour later.
        storePrunedAt = Date()
        // A rebuild queued behind another can follow a reader that already
        // armed the planner; the backlog about to be read must not notify.
        planner.disarm()
        // Before any reader starts, so the replayed backlog never shows or counts
        // an archived session.
        var state = CollectiveState()
        state.restoreArchive(archiveFile.load(now: Date()))
        readMarksStart = ReadMarksStart(restoring: readFile.load(now: Date()), into: &state)
        self.state = state
        let chosen = chosenFolders
        let registration = Self.register(chosen: chosen)
        let pullSources = registration.pullSources
        sources = registration.sources
        // No dictionary literal: several sources may serve the same tool and share a SourceID.
        sourceNames = Dictionary(
            registration.sources.map { ($0.source, $0.name) } + pullSources.map { ($0.source, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        sourceLogos = registration.logos
        // Only push adapters name models; pull sources report none.
        modelNaming = registration.modelNaming
        resumeCommands = registration.resumeCommands
        checks.replaceProbes(registration.probes)
        // Statuses of tools no longer registered are gone.
        refreshMenuBarIcon()
        let reader = SpoolReader(
            adapters: registration.adapters, chosenRoots: chosen,
            store: SpoolReader.Store(path: Self.storeURL, maxAge: eventRetention.interval)
        )
        spoolReader = reader
        readerTasks = [Task { [weak self] in
            for await output in await reader.events() {
                guard self?.readGeneration == generation else { continue }
                switch output {
                // Only what the spool still holds dates the sources for setup.
                case .events(let batch):
                    self?.lastEvents.record(batch)
                    self?.apply(batch, fromSpool: true)
                case .replay(let batch, let freshTimes):
                    self?.lastEvents.merge(freshTimes)
                    self?.apply(batch, fromSpool: true)
                case .backlogFinished:
                    self?.storeReader = reader
                    self?.backlogFinished()
                }
            }
        }]
        for pullSource in pullSources {
            readerTasks.append(Task { [weak self] in
                for await batch in pullSource.events() {
                    guard self?.readGeneration == generation else { continue }
                    self?.apply(batch, fromSpool: false)
                }
            })
        }
        updateAnimation()
        checks.check()
    }

    /// Stops the reader and the pull sources, waits until they have ended, and
    /// starts over. The old reader's watch loops and its last prune have ended
    /// before the new one opens the same store (`SpoolReader.stop`); the pull
    /// sources share nothing with their successors, so ending their streams is
    /// enough. Rebuilds run one after another; each starts from the folders chosen by then.
    /// `whileStopped` runs once nothing reads or prunes the store any more and
    /// before the new reader opens it (`clearStoredEvents`).
    private func restartReading(whileStopped: (() async -> Void)? = nil) {
        // Undo rows refer to the state about to be replaced. Their marks are
        // saved and restored into the new state, so committing keeps them
        // archived; the popover is closed anyway while the settings window is used.
        undo.commitAll()
        updateUndoExpiry()
        // The state is about to be read anew; the new reader's backlog arms it again.
        planner.disarm()
        // No new hourly prune on the old reader and nothing more from the old
        // readers from here on; `startReading` sets the next ones.
        storeReader = nil
        readGeneration += 1
        let previous = restartTask
        restartTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let old = readerTasks
            let oldReader = spoolReader
            readerTasks = []
            spoolReader = nil
            old.forEach { $0.cancel() }
            await oldReader?.stop()
            for task in old { await task.value }
            await pruneTask?.value
            await whileStopped?()
            startReading()
        }
    }

    /// `folder` nil, or one of the source's default folders, goes back to the
    /// defaults. Rebuilds only if a source now reads from other roots:
    /// choosing a default folder while none is chosen changes nothing.
    func chooseFolder(_ folder: URL?, for source: SourceID) {
        let old = chosenFolders
        let defaults = Dictionary(sources.map { ($0.source, $0.defaultFolders) }, uniquingKeysWith: { first, _ in first })
        chosenFolders[source] = SubspaceRoot.choice(folder, defaults: defaults[source] ?? [])
        UserDefaults.standard.set(
            Dictionary(uniqueKeysWithValues: chosenFolders.map { ($0.key.rawValue, $0.value.path) }),
            forKey: Self.chosenFoldersKey
        )
        if SubspaceRoot.rootsChange(defaults: defaults, from: old, to: chosenFolders) { restartReading() }
    }

    /// Deletes the events the app stored and reads the spool anew, like a folder
    /// change with the deletion in between: only then does no reader of this
    /// app hold the store. A reader that read its backlog without the store
    /// holds nothing to let go of: the store is someone else's, e.g. a second
    /// copy of the app's, or unusable. Then the deletion is tried next to it,
    /// and a failure leaves the popover as it is instead of reading everything anew.
    func clearStoredEvents() {
        guard !isClearingStoredEvents else { return }
        isClearingStoredEvents = true
        guard let reader = storeReader else {
            clearWhileStopped()
            return
        }
        let generation = readGeneration
        Task { [weak self] in
            let holdsStore = await reader.holdsStore
            guard let self else { return }
            // A rebuild that began meanwhile takes the clear along.
            guard !holdsStore, readGeneration == generation, storeReader === reader else {
                clearWhileStopped()
                return
            }
            // In `pruneTask`, so a rebuild asked for from here on opens the
            // store only once the deletion is over.
            let previous = pruneTask
            pruneTask = Task { [weak self] in
                await previous?.value
                // Built only now: a folder chosen meanwhile is a root to keep out of.
                guard let stored = self?.storedEvents else { return }
                let error = await Self.clear(stored)
                guard let self else { return }
                // Only now is the store free for a reader of this app.
                if error == nil { restartReading() }
                storedEventsCleared(error)
            }
        }
    }

    /// The clear as a rebuild's step: nothing of this app reads or prunes the
    /// store then. Reading restarts whether or not it deleted anything.
    private func clearWhileStopped() {
        restartReading { [weak self] in
            // Built only now: a folder chosen meanwhile is a root to keep out of.
            guard let stored = self?.storedEvents else { return }
            let error = await Self.clear(stored)
            self?.storedEventsCleared(error)
        }
    }

    /// `error` is what the clear failed with, nil if it deleted everything.
    private func storedEventsCleared(_ error: (any Error)?) {
        if let error {
            Self.log.error("Could not clear the stored events: \(String(describing: error), privacy: .public)")
            storedEventsClearFailure = StoredEventsClearFailure(error)
        }
        isClearingStoredEvents = false
        // After a rebuild the new reader's backlog refreshes it once more (`backlogFinished`).
        refreshStoredEventsSize()
    }

    /// Reads the size off the main actor: it walks files. While the settings
    /// window shows it, when the backlog is read, and after a clear.
    func refreshStoredEventsSize() {
        storedEventsRefresh += 1
        let refresh = storedEventsRefresh
        let stored = storedEvents
        Task { [weak self] in
            let size = await Self.size(of: stored)
            guard let self, storedEventsRefresh == refresh else { return }
            storedEventsSize = size
        }
    }

    @concurrent nonisolated private static func size(of stored: StoredEvents) async -> Int64 {
        stored.size()
    }

    /// The error, if any, rather than a throw: the caller reports it and goes on.
    @concurrent nonisolated private static func clear(_ stored: StoredEvents) async -> (any Error)? {
        do {
            try stored.clear()
            return nil
        } catch {
            return error
        }
    }

    private static func loadChosenFolders() -> [SourceID: URL] {
        let stored = UserDefaults.standard.dictionary(forKey: chosenFoldersKey) as? [String: String] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { source, path in
            path.isEmpty ? nil : (SourceID(rawValue: source), URL(fileURLWithPath: path, isDirectory: true))
        })
    }

    /// The settings window's sidebar and source panes.
    func settingsModel() -> SettingsModel {
        SettingsModel(sources: sources.map { source in
            SettingsSourceModel(
                source: source.source,
                name: source.name,
                sourceURL: source.sourceURL,
                status: integrations.first { $0.source == source.source },
                checkedAt: checks.checkedAt[source.source],
                lastEventAt: lastEvents.bySource[source.source],
                defaultFolders: source.defaultFolders,
                chosenFolder: chosenFolders[source.source],
                availability: updateAvailability(for: source.source),
                updateRun: setupRuns.updateSnapshots[source.source],
                outputShown: setupRuns.outputShown.contains(source.source),
                checksForUpdates: releaseChecker.checksForUpdates,
                now: Date()
            )
        }, storedEvents: StoredEventsModel(size: storedEventsSize, isClearing: isClearingStoredEvents),
           appUpdateAvailable: appUpdater.state.available != nil)
    }

    /// Whether subspace is missing or disabled, from each tool's last check;
    /// missing only once every tool has reported.
    var connection: ConnectionStatus { ConnectionStatus(integrations: integrations, allReported: checks.allReported) }

    /// When the popover opens; the probes run CLIs, so not on every open. A
    /// tool still in its check, the first one too, is not checked again.
    func checkIntegrationsIfStale() {
        checks.checkIfStale(freshness: Self.checkFreshness)
    }

    func setupWindowOpened() {
        setupWindowRequested = false
    }

    /// The card's button; `SetupRuns` checks it against the card as the window shows it now.
    func runSetup(_ source: SourceID, _ kind: SetupCardModel.CommandsBox.Footer.Button.Kind) {
        guard let status = integrations.first(where: { $0.source == source }) else { return }
        setupRuns.run(kind, for: status)
    }

    /// The update group's button; `SetupRuns` checks it against the group as the windows show it now.
    func runUpdate(_ source: SourceID, _ kind: SetupCardModel.CommandsBox.Footer.Button.Kind) {
        guard let status = integrations.first(where: { $0.source == source }) else { return }
        setupRuns.runUpdate(kind, for: status, checkedAt: checks.checkedAt[source], availability: releaseChecker.updateAvailability(for: status),
                            checksForUpdates: releaseChecker.checksForUpdates)
    }

    /// Whether the source's subspace should be updated, from its last check.
    func updateAvailability(for source: SourceID) -> UpdateAvailability {
        integrations.first { $0.source == source }.map(releaseChecker.updateAvailability) ?? .upToDate
    }

    /// The same per tool, for the setup window and the popover's update link.
    var updateAvailabilities: [SourceID: UpdateAvailability] {
        Dictionary(integrations.map { ($0.source, releaseChecker.updateAvailability(for: $0)) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// About's `Check Now`: the app and every subspace plugin at once, whatever the switch says.
    func checkForUpdatesNow() {
        appUpdater.checkNow()
        releaseChecker.checkNow(now: Date(), sources: releaseSources)
    }

    /// `Update…` and the popover's app update link: Sparkle's update window.
    func showAppUpdate() {
        appUpdater.showUpdateWindow()
    }

    /// About's status line.
    func appUpdateStatusLine(now: Date) -> AppUpdateStatusLine {
        AppUpdateStatusLine(appUpdater.state, checksAutomatically: checksForUpdates,
                            pluginsChecking: releaseChecker.isChecking, now: now)
    }

    /// When the setup window or a source pane opens; the checker decides whether it is due.
    func checkSubspaceReleasesOnOpen() {
        releaseChecker.checkOnOpen(now: Date(), sources: releaseSources)
    }

    /// From the sweep and after every tool's result; cheap when nothing is due.
    /// Nothing until every tool has reported once, so the launch lookup asks
    /// for all of them together rather than for the first to report alone.
    private func checkSubspaceReleasesIfDue() {
        guard checks.allReported else { return }
        releaseChecker.checkIfDue(now: Date(), sources: releaseSources)
    }

    /// Only sources whose probe names where their releases are tagged.
    private var releaseSources: [SourceID: SubspaceRelease] {
        Dictionary(integrations.compactMap { status in status.commands.release.map { (status.source, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Each tool's result as it arrives; `checks` holds it already.
    private func integrationChecked(_ status: IntegrationStatus, startedAt: Date) {
        refreshMenuBarIcon()
        restartHints.observe([status], probeStartedAt: startedAt)
        checkSubspaceReleasesIfDue()
        updateAnimation()
        // Only once every tool reported: one still in its first check may have subspace enabled.
        let defaults = UserDefaults.standard
        if checks.allReported, !defaults.bool(forKey: Self.setupOfferedKey) {
            defaults.set(true, forKey: Self.setupOfferedKey)
            if connection != .ok { setupWindowRequested = true }
        }
    }

    /// The popover content at `now`; the view's clock (`ModelClock`) passes it.
    func popoverModel(now: Date) -> PopoverModel {
        PopoverModel(
            state: state,
            now: now,
            settings: PopoverSettings(
                finishedRetention: finishedRetention, idleAfter: idleAfter, idleSnapshot: idleOpening.snapshot,
                colorsEffortLevels: colorsEffortLevels
            ),
            sourceNames: sourceNames,
            sourceLogos: sourceLogos,
            modelNaming: modelNaming,
            resumeCommands: resumeCommands,
            lastEventAt: lastEventAt,
            expansion: expansion,
            undo: undo,
            isLoading: isLoading,
            loadingIndicatorVisible: loadingIndicatorVisible,
            connection: connection,
            replyPreviewCache: replyPreviewCache,
            terminalApps: terminalApps,
            updateLink: UpdateFooterLink(statuses: integrations, availability: updateAvailabilities,
                                         checksForUpdates: releaseChecker.checksForUpdates,
                                         appUpdate: appUpdater.state.available),
            restartHints: restartHints
        )
    }

    /// Brings the session's terminal to the front when the kit offers it
    /// (`TerminalAction`); false when there is none to bring, so the caller
    /// can fall back, e.g. a notification click opens the popover.
    @discardableResult
    func showTerminal(_ key: SessionKey) -> Bool {
        guard let session = state.sessions[key],
              let action = TerminalAction(session: session, apps: terminalApps) else { return false }
        TerminalFocuser.show(action)
        markTurnRead(key)
        onTerminalShown()
        return true
    }

    /// The user went to the session, by the jump button or a notification:
    /// its turn end is read at once.
    func markTurnRead(_ key: SessionKey) {
        if state.markTurnRead(key) { readFile.save(state.readMarks, now: Date()) }
    }

    /// A row of the open popover came into view; read once it closes.
    func rowSeen(_ item: SessionItem) {
        guard isPopoverOpen else { return }
        unreadReading.saw(item)
    }

    func selectTab(_ tab: PopoverTab) {
        expansion.select(tab)
    }

    func toggleEarlierSessions() {
        expansion.toggleEarlierSessions()
    }

    /// - Parameter isOpen: Whether the card's list shows open now; the rule may have opened it.
    func toggleSubagents(_ key: SessionKey, isOpen: Bool) {
        expansion.toggleSubagents(key, isOpen: isOpen)
    }

    func toggleSubagentFold(_ id: SubagentFoldID) {
        expansion.toggleSubagentFold(id)
    }

    /// Marks are saved right away, so an archive outlives a crash before the
    /// popover closes; the undo row only lives in memory.
    func archive(_ kind: ArchiveUndo.Kind) {
        let now = Date()
        undo.archive(kind, in: &state, at: now)
        archiveFile.save(state.archiveMarks, now: now)
        // Archiving says the user has seen to it.
        notifier.withdraw(planner.reconcile(state))
        updateAnimation()
        updateUndoExpiry()
    }

    func undo(_ id: ArchiveUndo.ID) {
        let marks = state.archiveMarks
        undo.undo(id, in: &state)
        archiveChanged(from: marks)
    }

    /// ⌘Z while the popover is key.
    func undoLast() {
        let marks = state.archiveMarks
        undo.undoLast(in: &state)
        archiveChanged(from: marks)
    }

    /// A row under the pointer holds its countdown.
    func undoHover(_ id: ArchiveUndo.ID, hovering: Bool) {
        if hovering { undo.pause(id, at: Date()) } else { undo.resume(id, at: Date()) }
        updateUndoExpiry()
    }

    /// Fixes the idle classification before the first model build of the
    /// popover, which starts on Active every time; while the backlog is
    /// read, only at its end (`backlogFinished`).
    func popoverOpened() {
        idleOpening.popoverOpened(state, at: Date(), isLoading: isLoading)
        expansion.popoverOpened()
        isPopoverOpen = true
    }

    /// Closing the popover commits every archive; the marks are already saved.
    /// What it showed unread is read from now on.
    func popoverClosed() {
        idleOpening.popoverClosed()
        undo.commitAll()
        updateUndoExpiry()
        isPopoverOpen = false
        guard !unreadReading.isEmpty else { return }
        let marks = state.readMarks
        unreadReading.commit(into: &state)
        if state.readMarks != marks { readFile.save(state.readMarks, now: Date()) }
    }

    /// ⌘Z with nothing left to undo writes nothing.
    private func archiveChanged(from marks: [ArchiveTarget: Date]) {
        if state.archiveMarks != marks { archiveFile.save(state.archiveMarks, now: Date()) }
        notifier.withdraw(planner.reconcile(state))
        updateAnimation()
        updateUndoExpiry()
    }

    /// Keeps at most one wakeup pending, for the next undo row to expire, and
    /// none while every row is paused or gone.
    private func updateUndoExpiry() {
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        let now = Date()
        undo.removeExpired(at: now)
        guard let next = undo.nextExpiry(after: now) else { return }
        undoExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSince(now)))
            guard !Task.isCancelled else { return }
            self?.updateUndoExpiry()
        }
    }

    /// The finish time can move the indicator's hide time, so the wakeup is rescheduled.
    private func backlogFinished() {
        // What the backlog showed to be over goes; only what follows notifies.
        notifier.withdraw(planner.arm(state))
        if readMarksStart?.backlogFinished(in: &state) == true { readFile.save(state.readMarks, now: Date()) }
        isLoading = false
        idleOpening.backlogFinished(state, at: Date())
        loadingIndicator.backlogFinishedAt = Date()
        updateLoadingIndicator()
        refreshStoredEventsSize()
    }

    /// Keeps at most one wakeup pending, for the indicator's next change, and none
    /// once it never changes again.
    private func updateLoadingIndicator() {
        loadingTask?.cancel()
        loadingTask = nil
        let now = Date()
        loadingIndicatorVisible = loadingIndicator.isVisible(at: now)
        guard let next = loadingIndicator.nextChange(after: now) else { return }
        loadingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSince(now)))
            guard !Task.isCancelled else { return }
            self?.updateLoadingIndicator()
        }
    }

    /// Assigns `state` once per batch, so the backlog redraws the icon once, and
    /// sweeps before assigning, so dead sessions in it never show as working.
    /// Only spooled batches date the footer: "last event" means the newest
    /// subspace event, not a status file the app polls itself.
    /// New work clears an archive mark; only then is the file written and are
    /// undo entries checked. The planner applies the batch, so it sees what
    /// is new; pull sources report answers to permission requests too.
    private func apply(_ batch: [AgentEvent], fromSpool: Bool) {
        var state = state
        let plan = planner.apply(
            batch, to: &state, now: Date(), preferences: notificationPreferences, sourceNames: sourceNames
        )
        if fromSpool, let newest = batch.map(\.timestamp).max() {
            lastEventAt = max(lastEventAt ?? newest, newest)
        }
        Self.sweep(&state, now: Date())
        let marksChanged = state.archiveMarks != self.state.archiveMarks
        self.state = state
        // Posted first: a wish the sweep already ended is then withdrawn before it shows.
        notifier.post(plan.wishes)
        notifier.withdraw(plan.withdrawals + planner.reconcile(state))
        if marksChanged {
            archiveFile.save(state.archiveMarks, now: Date())
            // A comeback ends its undo row, paused or not.
            undo.dropRevived(in: state)
            updateUndoExpiry()
        }
        updateAnimation()
    }

    /// Runs every 5 s. Assigns `state` only when the sweep changed it: every
    /// assignment rebuilds the open popover's model, and most sweeps find nothing.
    private func sweep() {
        let now = Date()
        var swept = state
        Self.sweep(&swept, now: now)
        if swept != state { state = swept }
        notifier.withdraw(planner.reconcile(state))
        updateAnimation()
        checkSubspaceReleasesIfDue()
        // At most once an hour, and only once the backlog is read (`storeReader`).
        if let reader = storeReader, now.timeIntervalSince(storePrunedAt) >= 3600 {
            storePrunedAt = now
            prune { await reader.pruneStore(now: now) }
        }
    }

    /// The app's store of the spool's events, so shown sessions survive subspace's retention.
    private static var storeURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Collective", isDirectory: true)
            .appendingPathComponent("events.sqlite")
    }

    /// Everything the app keeps of the spool's events: the store and the spool
    /// mirror that preceded it. Neither the archive marks nor a setting.
    /// With the roots as they are now, a chosen folder before the default one:
    /// a clear touches nothing in a spool root.
    private var storedEvents: StoredEvents {
        StoredEvents(
            store: Self.storeURL,
            leftovers: [Self.storeURL.deletingLastPathComponent().appendingPathComponent("spool-mirror", isDirectory: true)],
            roots: sources.flatMap { chosenFolders[$0.source].map { [$0] } ?? $0.defaultFolders }
        )
    }

    /// The user's archive marks; next to the event store, apart from it (`ArchiveFile`).
    private static var archiveURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Collective", isDirectory: true)
            .appendingPathComponent("archive.json")
    }

    /// The user's read marks, next to the archive marks (`ReadFile`).
    private static var readURL: URL {
        archiveURL.deletingLastPathComponent().appendingPathComponent("read.json")
    }

    /// A longer time rebuilds the state like a folder change: the new reader
    /// takes in the older events still in the spool, in order instead of on top
    /// of newer state. A shorter one prunes the store right away; the sessions
    /// shown stay until the next start. Without a reader a rebuild is in
    /// progress, and the reader it builds reads the new time.
    private func eventRetentionChanged(from old: EventRetention) {
        guard let reader = spoolReader else { return }
        if eventRetention > old {
            restartReading()
        } else {
            let maxAge = eventRetention.interval
            let now = Date()
            prune {
                await reader.setMaxAge(maxAge)
                await reader.pruneStore(now: now)
            }
        }
    }

    /// Runs after the prune in progress and is kept in `pruneTask`, so a rebuild
    /// can wait for all of them.
    private func prune(_ work: @escaping @Sendable () async -> Void) {
        let previous = pruneTask
        pruneTask = Task {
            await previous?.value
            await work()
        }
    }

    /// Sessions with a pid are checked against the process; the silence
    /// timeouts only apply to sessions without one: 30 min, or 12 h while the
    /// session really waits for the user. `markInterrupted` is the
    /// fallback for sessions without a session status report: 2 min of silence
    /// (30 min with a tool open) makes the orchestrator wait again.
    private static func sweep(_ state: inout CollectiveState, now: Date) {
        state.markStale(now: now, silenceTimeout: 30 * 60, waitingTimeout: 12 * 60 * 60, processStart: ProcessStartTime.of)
        state.markInterrupted(now: now, idleTimeout: 2 * 60, toolTimeout: 30 * 60)
        // Keep ended sessions as long as the longest "keep finished visible"
        // setting, whatever is chosen now, so a longer choice later still finds
        // them; the popover's own filter decides what shows.
        state.prune(now: now, retention: FinishedRetention.oneHour.interval)
    }

    /// Keeps exactly one frame tick running while the icon animates and none
    /// otherwise, so idle, warning, a still setting and Reduce Motion
    /// cost no wakeups. While the cube moves it never rests: one wakeup per
    /// frame at the chosen rate (12, 8 or 4 a second). A running tick reads
    /// the rate anew for every frame, so a new rate needs no restart.
    private func updateAnimation() {
        let animated = nextSceneChange(after: Date()) != nil
        if animated, tickTask == nil {
            tickTask = Task { [weak self] in
                var date = Date()
                while !Task.isCancelled {
                    self?.frameDate = date
                    // Every change calls `updateAnimation`, which cancels the
                    // tick once nothing moves. Should one slip past it, the tick
                    // ends and clears itself, so the next animation starts anew.
                    guard let next = self?.nextSceneChange(after: date) else {
                        if !Task.isCancelled { self?.tickTask = nil }
                        return
                    }
                    try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
                    // Waking a little early must still draw the new frame.
                    date = max(Date(), next)
                }
            }
        } else if !animated, let tickTask {
            tickTask.cancel()
            self.tickTask = nil
        }
    }

    private func nextSceneChange(after date: Date) -> Date? {
        menuBarIcon.nextSceneChange(after: date, animation: menuBarAnimation, reduceMotion: reduceMotion)
    }

    /// Observation fires on every set, so only a changed icon is assigned.
    private func refreshMenuBarIcon() {
        let icon = MenuBarIcon(state: state, connection: connection)
        if icon != menuBarIcon { menuBarIcon = icon }
    }
}

/// A registered push adapter as the settings window lists it.
nonisolated struct RegisteredSource: Sendable {
    let source: SourceID
    let name: String
    /// Where its events are without a chosen folder, `SUBSPACE_DIR` applied:
    /// the primary of `defaultFolders`, where the folder panel opens.
    let defaultFolder: URL
    /// Every root it reads without a chosen folder, the primary first, as the settings window lists them.
    let defaultFolders: [URL]
    /// Its probe's plugin repository, so About and the source pane link it before the first check returns.
    let sourceURL: URL?
}

/// What `CollectiveModel.register(chosen:)` builds for every tool.
nonisolated private struct Registration {
    let adapters: [any PushAdapter]
    let pullSources: [any PullSource]
    let probes: [any IntegrationProbe]
    /// Read from the adapters up front: they belong to the spool reader once it has them.
    let sources: [RegisteredSource]
    let modelNaming: [SourceID: any ModelNaming]
    let resumeCommands: [SourceID: ResumeCommand]
    /// As `sourceNames`: the push adapter's first, then a pull source's of the same tool.
    let logos: [SourceID: String]

    init(adapters: [any PushAdapter], pullSources: [any PullSource], probes: [any IntegrationProbe]) {
        self.adapters = adapters
        self.pullSources = pullSources
        self.probes = probes
        sources = adapters.map { adapter in
            RegisteredSource(
                source: adapter.source, name: adapter.displayName,
                defaultFolder: SubspaceRoot.resolve(adapter: adapter),
                defaultFolders: SubspaceRoot.resolveAll(adapter: adapter),
                sourceURL: probes.first { $0.source == adapter.source }?.commands.sourceURL
            )
        }
        modelNaming = Dictionary(adapters.map { ($0.source, $0.modelNaming) }, uniquingKeysWith: { first, _ in first })
        resumeCommands = Dictionary(
            adapters.compactMap { adapter in adapter.resumeCommand.map { (adapter.source, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        logos = Dictionary(
            adapters.compactMap { adapter in adapter.logoName.map { (adapter.source, $0) } }
                + pullSources.compactMap { source in source.logoName.map { (source.source, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
