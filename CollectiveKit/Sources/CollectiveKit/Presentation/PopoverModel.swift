import Foundation
import SubspaceKit

/// How long finished sessions stay visible in the popover.
/// The raw value is what the app persists.
public enum FinishedRetention: String, CaseIterable, Sendable, Equatable {
    case fiveMinutes
    case tenMinutes
    case thirtyMinutes
    case oneHour

    public var interval: TimeInterval {
        switch self {
        case .fiveMinutes: 5 * 60
        case .tenMinutes: 10 * 60
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        }
    }

    /// The entry in the settings window's popup.
    public var optionText: LocalizedStringResource {
        switch self {
        case .fiveMinutes: .kit("5 minutes", defaultValue: "5 minutes")
        case .tenMinutes: .kit("10 minutes", defaultValue: "10 minutes")
        case .thirtyMinutes: .kit("30 minutes", defaultValue: "30 minutes")
        case .oneHour: .kit("1 hour", defaultValue: "1 hour")
        }
    }

    /// The Finished tab's tooltip.
    public var clearedAfterText: LocalizedStringResource {
        .kit("Cleared after %@", defaultValue: "Cleared after \(DurationText.format(interval))")
    }
}

/// How long a session rests before the popover moves it to the Idle tab
/// The raw value is what the app persists.
public enum IdleAfter: String, CaseIterable, Sendable, Equatable {
    case fiveMinutes
    case tenMinutes
    case thirtyMinutes
    case oneHour
    /// Every session stays at the top, as before the Idle tab existed.
    case never

    public static let `default`: IdleAfter = .fiveMinutes

    /// Nil never moves a session.
    public var interval: TimeInterval? {
        switch self {
        case .fiveMinutes: 5 * 60
        case .tenMinutes: 10 * 60
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .never: nil
        }
    }

    /// The entry in the settings window's popup.
    public var optionText: LocalizedStringResource {
        switch self {
        case .fiveMinutes: .kit("5 minutes", defaultValue: "5 minutes")
        case .tenMinutes: .kit("10 minutes", defaultValue: "10 minutes")
        case .thirtyMinutes: .kit("30 minutes", defaultValue: "30 minutes")
        case .oneHour: .kit("1 hour", defaultValue: "1 hour")
        case .never: .kit("Never", defaultValue: "Never")
        }
    }

    /// The Idle tab's tooltip; nil for `never`, which moves no session there.
    public var waitingOverText: LocalizedStringResource? {
        interval.map { .kit("Waiting over %@", defaultValue: "Waiting over \(DurationText.format($0))") }
    }
}

/// How long the app keeps the events it stored from subspace's spool.
/// The raw value is what the app persists.
public enum EventRetention: String, CaseIterable, Sendable, Equatable, Comparable {
    case oneDay
    case threeDays
    case oneWeek
    case unlimited

    public static let `default`: EventRetention = .threeDays

    /// Nil keeps the events forever.
    public var interval: TimeInterval? {
        switch self {
        case .oneDay: 24 * 3600
        case .threeDays: 3 * 24 * 3600
        case .oneWeek: 7 * 24 * 3600
        case .unlimited: nil
        }
    }

    /// The entry in the settings window's popup.
    public var optionText: LocalizedStringResource {
        switch self {
        case .oneDay: .kit("1 day", defaultValue: "1 day")
        case .threeDays: .kit("3 days", defaultValue: "3 days")
        case .oneWeek: .kit("1 week", defaultValue: "1 week")
        case .unlimited: .kit("Unlimited", defaultValue: "Unlimited")
        }
    }

    /// By length, `unlimited` the longest: a longer time brings events back
    /// that a shorter one left out, so the app handles the two differently.
    public static func < (lhs: EventRetention, rhs: EventRetention) -> Bool {
        (lhs.interval ?? .infinity) < (rhs.interval ?? .infinity)
    }
}

public struct PopoverSettings: Sendable, Equatable {
    public var finishedRetention: FinishedRetention
    public var idleAfter: IdleAfter
    /// The rests found when the popover opened; nil while it is closed, which
    /// classifies by `now`, and while an open popover waits for the backlog to
    /// end (`IdleOpening`). While it is open, nothing moves into the group
    /// under the user's eyes: the next opening moves it.
    public var idleSnapshot: IdleSnapshot?
    /// Whether each effort gauge takes its level's color or the model name's
    /// gray; the fill shows the level either way.
    public var colorsEffortLevels: Bool

    public init(
        finishedRetention: FinishedRetention = .tenMinutes, idleAfter: IdleAfter = .default, idleSnapshot: IdleSnapshot? = nil,
        colorsEffortLevels: Bool = true
    ) {
        self.finishedRetention = finishedRetention
        self.idleAfter = idleAfter
        self.idleSnapshot = idleSnapshot
        self.colorsEffortLevels = colorsEffortLevels
    }
}

/// The sessions that rested when the popover opened, each with when its rest
/// began. The open popover's "Idle" group takes only these, and each only
/// while the same rest lasts and had lasted `IdleAfter` by the opening: a
/// rest noted later can be dated back (a guessed interruption, a backlog
/// replayed late), and a time passing is no reason either, so no card moves
/// into the group while the user looks at the list.
public struct IdleSnapshot: Sendable, Equatable {
    public let openedAt: Date
    private let rests: [SessionKey: Rest]

    public init(_ state: CollectiveState, openedAt: Date) {
        self.openedAt = openedAt
        rests = Dictionary(uniqueKeysWithValues: state.shownSessions.compactMap { session in
            PopoverModel.restStart(of: session).map { (session.key, Rest(start: $0, ordinal: session.restsBegun)) }
        })
    }

    /// Whether `session`'s rest, begun at `restStart`, is the one it had at
    /// the opening. A rest begun anew has counted on, even when late backlog
    /// dates it from the same moment; a later run, which counts from the
    /// start again, starts later.
    func holds(_ session: Session, restingSince restStart: Date) -> Bool {
        rests[session.key] == Rest(start: restStart, ordinal: session.restsBegun)
    }

    private struct Rest: Sendable, Equatable {
        let start: Date
        let ordinal: Int
    }
}

/// When the open popover fixes its `IdleSnapshot`. An opening while the
/// backlog is read counts as an opening at the backlog's end: until
/// then the state holds none of the sessions the backlog brings, and a
/// snapshot without them would keep every one of them out of Idle until the
/// next opening. Meanwhile there is no snapshot, so the popover classifies by
/// `now`; a rest that crosses the threshold in those seconds can change tabs.
public struct IdleOpening: Sendable, Equatable {
    /// What the popover classifies by; nil while it is closed or the backlog is read.
    public private(set) var snapshot: IdleSnapshot?
    private var isOpen = false
    /// Open while the backlog is read, so the snapshot waits for its end.
    private var isDeferred = false

    public init() {}

    public mutating func popoverOpened(_ state: CollectiveState, at date: Date, isLoading: Bool) {
        isOpen = true
        isDeferred = isLoading
        snapshot = isLoading ? nil : IdleSnapshot(state, openedAt: date)
    }

    /// Reading anew starts from an empty state; an open popover waits for
    /// the new backlog's end as if it had opened during it.
    public mutating func readingStarted() {
        guard isOpen else { return }
        isDeferred = true
        snapshot = nil
    }

    /// Fixes the snapshot of a popover opened while the backlog was read.
    public mutating func backlogFinished(_ state: CollectiveState, at date: Date) {
        guard isDeferred else { return }
        isDeferred = false
        snapshot = IdleSnapshot(state, openedAt: date)
    }

    public mutating func popoverClosed() {
        isOpen = false
        isDeferred = false
        snapshot = nil
    }
}

/// How an agent is shown. `unassigned` is a running subagent the source has
/// named neither by type nor by title yet.
public enum AgentDisplayState: Sendable, Equatable {
    case working
    case waiting
    /// Only for a session's orchestrator: its turn is over while background
    /// subagents still work. Whether it waits on them the sources don't say,
    /// so the card claims background work, never waiting.
    case backgroundWorking
    /// Only for a session's orchestrator: its turn is over while a shell
    /// command it started in the background still runs. Not the agent
    /// working, so never counted as working and no call to act either.
    case backgroundShell
    case done
    case stale
    case unassigned
    /// Put away by the user; never counted as working, whatever the source
    /// still reports.
    case archived
}

/// What an undo row shows in place of the item it took back: "alpha archived"
/// for a session, "Explore archived" for a subagent in a card's list, or one
/// row for "Archive All Finished".
public struct UndoRow: Sendable, Equatable {
    /// The entry the row's Undo button takes back.
    public let id: ArchiveUndo.ID
    /// What it stands in for. The text is written from it when the view asks,
    /// so a model compares this rather than a text and its locale.
    let subject: Subject

    enum Subject: Sendable, Equatable {
        case session(name: String)
        /// The subagent's type, else its title; nil while the source names neither.
        case subagent(name: String?)
        case finishedSessions(count: Int)
    }

    public var text: LocalizedStringResource {
        switch subject {
        case let .session(name), let .subagent(name?): .kit("%@ archived", defaultValue: "\(name) archived")
        case .subagent(nil): .kit("Subagent archived", defaultValue: "Subagent archived")
        case let .finishedSessions(count): .kit("%lld finished sessions archived", defaultValue: "\(count) finished sessions archived")
        }
    }
}

/// The block above the list while subspace is missing or disabled: what is
/// wrong, the commands that fix it and a way to the setup window.
public struct WarningBlock: Sendable, Equatable {
    /// Command lines to copy, in order; plain strings, never translated.
    public let commands: [String]
    /// "Set Up…" next to "Check Again".
    public let showsSetUp = true
    /// What is wrong; the texts are written from it, as `UndoRow`'s.
    private let problem: Problem

    private enum Problem: Sendable, Equatable {
        /// Named after the tool whose install commands follow.
        case missing(toolName: String)
        case disabled(toolName: String)
    }

    init?(_ connection: ConnectionStatus) {
        switch connection {
        case .ok:
            return nil
        case .missing(let status):
            problem = .missing(toolName: status.toolName)
            commands = status.commands.install
        case .disabled(let status):
            problem = .disabled(toolName: status.toolName)
            commands = status.commands.enable
        }
    }

    public var title: LocalizedStringResource {
        switch problem {
        case .missing: .kit("subspace isn’t installed", defaultValue: "subspace isn’t installed")
        case .disabled: .kit("subspace is disabled", defaultValue: "subspace is disabled")
        }
    }

    public var text: LocalizedStringResource {
        switch problem {
        case let .missing(toolName):
            .kit(
                "The Collective sees your agents through subspace, a small plugin for %@ that records session events. Install it once; sessions you start afterwards appear here.",
                defaultValue: "The Collective sees your agents through subspace, a small plugin for \(toolName) that records session events. Install it once; sessions you start afterwards appear here."
            )
        case let .disabled(toolName):
            .kit(
                "subspace is switched off in %@. Sessions you start from now on won’t appear here; running ones keep reporting until they end.",
                defaultValue: "subspace is switched off in \(toolName). Sessions you start from now on won’t appear here; running ones keep reporting until they end."
            )
        }
    }

    public var hint: LocalizedStringResource {
        .kit("Restart running sessions afterwards.", defaultValue: "Restart running sessions afterwards.")
    }
}

/// The line under a working agent. Always set while it works, so cards
/// don't jump between tool calls.
public enum ActivityLine: Sendable, Equatable {
    /// How many of its foreground subagents are working while it waits on
    /// them; only on a subagent's row, the toggle line counts the orchestrator's.
    case subagentsWorking(Int)
    case tool(ToolActivity)
    /// Between tool calls, while events still come in.
    case thinking
    /// "No activity for 2 min": silent for `quietThreshold` or longer, so
    /// the user can tell a hanging agent from a thinking one. The view writes
    /// the time since the agent's last event at its own clock (`noActivityText`).
    case noActivity(since: Date)

    /// How long a finished tool call stays on the line, so a quick one is
    /// readable rather than a flicker.
    public static let minimumToolDisplay: TimeInterval = 1
    /// Silence after which "Thinking…" gives way to "No activity". A running
    /// tool stays regardless: a long build is busy, not hanging.
    public static let quietThreshold: TimeInterval = 60

    /// "No activity for 2 min" at the view's clock.
    public static func noActivityText(since: Date, at now: Date) -> LocalizedStringResource {
        .kit("No activity for %@", defaultValue: "No activity for \(DurationText.format(now.timeIntervalSince(since)))")
    }
}

/// Everything the popover shows, derived from a `CollectiveState` at one moment.
/// A pure value: the app rebuilds it whenever the state changes, and at
/// `nextChange`. Times that count ("4 min", "Done 2 min ago") are not part of
/// it: the views write them at their own clock (`SessionItem.timeText(at:)`),
/// so a model built a second later is the same model, and every text is
/// written from cheap values only when a view asks for it.
public struct PopoverModel: Sendable, Equatable {
    /// The tab the user selected (`PopoverExpansion.selectedTab`).
    public let selectedTab: PopoverTab
    /// Active, Idle and Finished in this order, always all three.
    public let tabs: [TabItem]
    /// Active sessions in which anyone needs the user: "◆ n" on the Active
    /// tab, whatever tab is selected.
    public var needYouCount: Int { tabs[0].needYouCount }
    /// Active sessions (working, background working, waiting) in one list, newest
    /// prompt first; a session without a prompt sorts by its start. Those
    /// resting long enough stand in `idle` instead.
    /// A session archived moments ago keeps its place as an undo row (`undo`)
    /// but no longer counts.
    public let sessions: [SessionItem]
    /// Active sessions that rested at least `PopoverSettings.idleAfter` by
    /// the moment the popover opened (`PopoverSettings.idleSnapshot`), most
    /// recent rest first; the Idle tab's rows. Undo rows as in `sessions`.
    /// Empty for `IdleAfter.never`.
    public let idle: [SessionItem]
    /// Done or stale sessions within `finishedRetention`, most recently ended
    /// first; undo rows as in `sessions`.
    public let finished: [SessionItem]
    /// While "Archive All Finished" can be undone, the one row standing in for
    /// the sessions it archived; sessions finishing later follow below it.
    public let finishedBulkUndo: UndoRow?

    public let finishedRetention: FinishedRetention
    /// What the footer's connection line says (`footerParts(at:)`).
    private let footer: Footer
    /// The footer's dot takes `--warning` instead of `--success`.
    public let footerIsWarning: Bool
    /// Right in the footer, before the gear; never while a warning shows,
    /// which comes first and already leads to the setup window.
    public let footerLink: UpdateFooterLink?
    /// Shown above `content`.
    public let warning: WarningBlock?
    /// While a warning shows, the known sessions stand folded under one
    /// heading, since no new events arrive for them; `nil` without a warning
    /// or without sessions. While it is closed the view hides the list.
    public let earlierSessions: EarlierSessionsHeader?
    /// The spool's backlog is still being read, so an empty list may only mean
    /// "not read yet" rather than "nothing runs".
    public let isLoading: Bool
    /// What fills the selected tab between title bar and footer.
    public let content: Content
    /// When a model built later would differ without any event: a finished
    /// session leaves the list after its retention, an undo row goes, an item
    /// changes by the clock (`SessionItem.nextChange`). The owner builds the
    /// model again then. A session's rest running out is no such change: it
    /// goes idle by `PopoverSettings.idleSnapshot`, at the next opening.
    public let nextChange: Date?

    private enum Footer: Sendable, Equatable {
        case reading
        case lastEvent(Date)
        case listening
        /// In place of the last event or listening: sessions still run an older subspace.
        case restart(SubspaceVersion)
        case missing
        case disabled
    }

    public enum Content: Sendable, Equatable {
        /// The selected tab has nothing to list yet while the backlog is read,
        /// or the indicator is still within its minimum time after reading
        /// ended. It shows only once reading takes long enough to notice;
        /// until then the space stays as it is, so nothing flickers.
        case loading(indicatorVisible: Bool)
        /// Active without a row and no session rests: "The Collective is
        /// dormant.", only true once the backlog has been read. Finished
        /// sessions don't count: no agent runs in them.
        case dormant
        /// Active without a row while `idleCount` sessions rest, at least one:
        /// the tab stays Active and offers the way to them.
        case allQuiet(idleCount: Int)
        /// The Idle tab without a row, under "Never" always.
        case nothingIdle
        case nothingFinished
        /// The selected tab's `rows`; rows read so far show right away, even
        /// while loading.
        case list

        /// "All quiet", "Nothing idle", "Nothing finished"; nil for the rest,
        /// whose texts the view has.
        public var title: LocalizedStringResource? {
            switch self {
            case .allQuiet: .kit("All quiet", defaultValue: "All quiet")
            case .nothingIdle: .kit("Nothing idle", defaultValue: "Nothing idle")
            case .nothingFinished: .kit("Nothing finished", defaultValue: "Nothing finished")
            case .loading, .dormant, .list: nil
            }
        }

        /// The line under `title`; only all quiet has one.
        public var message: LocalizedStringResource? {
            guard case .allQuiet = self else { return nil }
            return .kit("No session is working or waiting for you.", defaultValue: "No session is working or waiting for you.")
        }

        /// The button that selects the Idle tab, "Show 2 idle"; only all
        /// quiet has one, so "Show 0 idle" never shows.
        public var showIdleText: LocalizedStringResource? {
            guard case let .allQuiet(count) = self else { return nil }
            return .kit("Show %lld idle", defaultValue: "Show \(count) idle")
        }
    }

    /// - Parameters:
    ///   - sourceNames: Display names per source, from the registered adapters;
    ///     a source without one shows its raw id.
    ///   - sourceLogos: Logos per source, from the registered adapters: images
    ///     in `ToolLogo.bundle`; a source without one shows its raw id instead.
    ///   - modelNaming: Short model names per source, from the registered
    ///     adapters; a source without one shows its model names as delivered.
    ///   - resumeCommands: How each source resumes a session, from the
    ///     registered adapters; a source without one offers no resume command.
    ///   - lastEventAt: When the newest spooled event arrived; `nil` while none has.
    ///   - expansion: The selected tab and what the user opened in the list: replies, the earlier sessions, subagent lists.
    ///   - undo: Archives that can still be taken back; their items show as undo rows.
    ///   - isLoading: Whether the spool's backlog is still being replayed.
    ///   - loadingIndicatorVisible: Whether the loading state is due on screen,
    ///     decided by the caller's timing; with nothing listed it keeps the
    ///     loading state up even after `isLoading` ended, so the indicator
    ///     never vanishes right after it appeared.
    ///   - connection: Whether subspace is missing or disabled; `.ok` until
    ///     the first check has finished.
    ///   - replyPreviewCache: A presentation cache owned across rebuilds by
    ///     the caller. The default is fresh for a one-off model.
    ///   - terminalApps: Which app shows a session's terminal; the default
    ///     resolves none, so nothing offers "Show in …".
    ///   - updateLink: Where the footer's update link leads, if a source's subspace should be updated.
    ///   - restartHints: Since when each source runs a newer subspace; the
    ///     footer asks to restart the listed sessions started before.
    public init(
        state: CollectiveState,
        now: Date,
        settings: PopoverSettings,
        sourceNames: [SourceID: String] = [:],
        sourceLogos: [SourceID: String] = [:],
        modelNaming: [SourceID: any ModelNaming] = [:],
        resumeCommands: [SourceID: ResumeCommand] = [:],
        lastEventAt: Date? = nil,
        expansion: PopoverExpansion = PopoverExpansion(),
        undo: ArchiveUndo = ArchiveUndo(),
        isLoading: Bool = false,
        loadingIndicatorVisible: Bool = false,
        connection: ConnectionStatus = .ok,
        replyPreviewCache: ReplyPreviewCache = ReplyPreviewCache(),
        terminalApps: any TerminalApps = NoTerminalApps(),
        updateLink: UpdateFooterLink? = nil,
        restartHints: SubspaceRestartHints = SubspaceRestartHints()
    ) {
        let replyPreviews = replyPreviewCache.beginBuild()
        defer { replyPreviews.finish() }
        let undoRows = UndoRows(undo, in: state, at: now)
        let items = SessionItems(
            state: state, now: now, sourceNames: sourceNames, sourceLogos: sourceLogos, modelNaming: modelNaming,
            resumeCommands: resumeCommands,
            expansion: expansion, replyPreviews: replyPreviews, undoRows: undoRows, undo: undo,
            terminalApps: terminalApps, colorsEffortLevels: settings.colorsEffortLevels
        )
        // Archived sessions are gone, unless their undo row still holds the place.
        let all = state.shownSessions.filter { !state.isArchived($0.key) || undoRows.sessions[$0.key] != nil }
        let archives = Dictionary(uniqueKeysWithValues: all.map { ($0.key, items.archive(of: $0)) })
        // Background work going on shows a resting orchestrator as `.backgroundWorking`
        // or `.backgroundShell`; it does not affect the position.
        let states = Dictionary(uniqueKeysWithValues: all.map {
            ($0.key, AgentDisplayState(orchestratorOf: $0, archive: archives[$0.key] ?? SessionArchive()))
        })
        let active = all
            .filter { [.working, .backgroundWorking, .backgroundShell, .waiting].contains(states[$0.key]) }
            .sorted(by: Self.mostRecentPrompt)
        let counted = active.filter { !state.isArchived($0.key) }
        // While the popover is open, only a rest of the opening that had
        // lasted long enough by then counts, so a session whose time is up
        // meanwhile, or whose rest is noted only now, keeps its card until
        // the next opening; one that gets work again leaves the group at
        // once, as it no longer rests.
        let snapshot = settings.idleSnapshot
        let reference = snapshot?.openedAt ?? now
        let restStarts: [SessionKey: Date] = settings.idleAfter.interval.map { interval in
            Dictionary(uniqueKeysWithValues: active.compactMap { session in
                Self.restStart(of: session).flatMap { start in
                    start.addingTimeInterval(interval) <= reference && snapshot?.holds(session, restingSince: start) != false
                        ? (session.key, start) : nil
                }
            })
        } ?? [:]

        finishedRetention = settings.finishedRetention
        sessions = active.filter { restStarts[$0.key] == nil }.map { items.item($0, archive: archives[$0.key]) }
        idle = active
            .compactMap { session in restStarts[session.key].map { (session, $0) } }
            .sorted { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 > rhs.1 : Self.isStableBefore(lhs.0, rhs.0)
            }
            .map { session, restStart in items.item(session, archive: archives[session.key], idleSince: restStart) }
        let retained = all
            .compactMap { session in session.endedAt.map { (session, $0) } }
            .filter { _, endedAt in now.timeIntervalSince(endedAt) <= settings.finishedRetention.interval }
            .sorted { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 > rhs.1 : Self.isStableBefore(lhs.0, rhs.0)
            }
        finished = retained.map { session, _ in items.item(session, archive: archives[session.key]) }
        finishedBulkUndo = undoRows.bulk.map { id, count in UndoRow(id: id, subject: .finishedSessions(count: count)) }
        self.isLoading = isLoading
        let showsItems = !(sessions.isEmpty && idle.isEmpty && finished.isEmpty) || finishedBulkUndo != nil

        // The menu bar's rule, session by session, and "waiting for you" besides.
        let needYou = counted.count { session in
            restStarts[session.key] == nil
                && (state.awaitsPermission(in: session) || state.awaitsAnswer(in: session) || states[session.key] == .waiting)
        }
        let lists: [PopoverTab: [SessionItem]] = [.active: sessions, .idle: idle, .finished: finished]
        let selected = expansion.selectedTab
        selectedTab = selected
        tabs = PopoverTab.allCases.map { tab in
            let rule: TabItem.Rule? = switch tab {
            case .active: nil
            case .idle: .idle(settings.idleAfter)
            case .finished: .finished(settings.finishedRetention)
            }
            let shown = lists[tab, default: []].filter { $0.undo == nil }
            return TabItem(
                tab: tab, count: shown.count,
                needYouCount: tab == .active ? needYou : 0, isSelected: tab == selected, rule: rule,
                // Active is shown on opening, so it needs no sign.
                hasUnread: tab != .active && shown.contains(where: \.isUnread)
            )
        }
        let reading = isLoading || loadingIndicatorVisible
        let idleCount = tabs[1].count
        content = if !lists[selected, default: []].isEmpty || selected == .finished && finishedBulkUndo != nil {
            .list
        } else if reading {
            .loading(indicatorVisible: loadingIndicatorVisible)
        } else {
            switch selected {
            case .active: idleCount > 0 ? .allQuiet(idleCount: idleCount) : .dormant
            case .idle: .nothingIdle
            case .finished: .nothingFinished
            }
        }
        // With nothing on screen there is no event worth dating.
        let footerState: Footer = if isLoading {
            .reading
        } else if let version = Self.restartVersion(restartHints, among: sessions + idle) {
            .restart(version)
        } else if let lastEventAt, showsItems {
            .lastEvent(lastEventAt)
        } else {
            .listening
        }
        warning = WarningBlock(connection)
        let knownCount = (sessions + idle + finished).count { $0.undo == nil }
        earlierSessions = warning != nil && knownCount > 0
            ? EarlierSessionsHeader(count: knownCount, isExpanded: expansion.isEarlierSessionsOpen)
            : nil
        footerIsWarning = warning != nil
        footerLink = warning == nil ? updateLink : nil
        footer = switch connection {
        case .ok: footerState
        case .missing: .missing
        case .disabled: .disabled
        }
        // A retained session goes once its retention is over: still listed at
        // its very end, so a millisecond past it, as `DurationText.nextChange`.
        let leaving = retained.map { $0.1.addingTimeInterval(settings.finishedRetention.interval + 0.001) }
        nextChange = ([undo.nextExpiry(after: now)] + (sessions + idle + finished).map(\.nextChange) + leaving).compactMap { $0 }.min()
    }

    /// The connection line in the footer while subspace is linked: the link,
    /// then its state, e.g. "Linked to subspace", "listening", "last event
    /// 2 min ago" at the view's clock. The view joins the parts, so the
    /// separator stays out of the strings. While subspace is missing or
    /// disabled, the one part says so instead.
    public func footerParts(at now: Date) -> [LocalizedStringResource] {
        let linked: LocalizedStringResource = .kit("Linked to subspace", defaultValue: "Linked to subspace")
        return switch footer {
        case .reading: [linked, .kit("reading events…", defaultValue: "reading events…")]
        case let .lastEvent(at):
            [linked, .kit("last event %@ ago", defaultValue: "last event \(DurationText.format(now.timeIntervalSince(at))) ago")]
        case .listening: [linked, .kit("listening", defaultValue: "listening")]
        case let .restart(version):
            [linked, .kit("Restart sessions to use subspace %@", defaultValue: "Restart sessions to use subspace \(version.description)")]
        case .missing: [.kit("subspace not installed", defaultValue: "subspace not installed")]
        case .disabled: [.kit("subspace is disabled", defaultValue: "subspace is disabled")]
        }
    }

    /// What the footer's "last event" counts from; nil while it counts nothing.
    public var footerCountsFrom: Date? {
        if case let .lastEvent(at) = footer { at } else { nil }
    }

    /// The newest update some listed session started before; an undo row's
    /// session is on its way out and doesn't count. Equal times: the first source id.
    private static func restartVersion(_ hints: SubspaceRestartHints, among items: [SessionItem]) -> SubspaceVersion? {
        hints.hints
            .filter { source, hint in items.contains { $0.undo == nil && $0.key.source == source && $0.startedAt < hint.since } }
            .max { lhs, rhs in
                lhs.value.since != rhs.value.since ? lhs.value.since < rhs.value.since : lhs.key.rawValue > rhs.key.rawValue
            }?
            .value.version
    }

    /// One list for every active session, by the user's last prompt (the start
    /// without one). Tool calls and status changes don't count, so rows move
    /// only when the user sends a prompt and don't jump under the pointer.
    private static func mostRecentPrompt(_ lhs: Session, _ rhs: Session) -> Bool {
        let (l, r) = (lhs.lastPromptAt ?? lhs.startedAt, rhs.lastPromptAt ?? rhs.startedAt)
        return l != r ? l > r : isStableBefore(lhs, rhs)
    }

    /// When `session` began to rest, nil while it doesn't; the reducer keeps
    /// the time (`Session.restingSince`).
    static func restStart(of session: Session) -> Date? {
        session.rests ? session.restingSince : nil
    }

    /// Tiebreak for equal timestamps: sessions come from dictionary values, so
    /// without it rows could swap places between two renders.
    private static func isStableBefore(_ lhs: Session, _ rhs: Session) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
        if lhs.key.source.rawValue != rhs.key.source.rawValue { return lhs.key.source.rawValue < rhs.key.source.rawValue }
        return lhs.key.sessionID < rhs.key.sessionID
    }

    /// The selected tab's rows, undo rows included.
    public var rows: [SessionItem] {
        switch selectedTab {
        case .active: sessions
        case .idle: idle
        case .finished: finished
        }
    }

    /// Keyboard focus order: the selected tab's rows; nothing while the
    /// earlier sessions are folded. Undo rows take no focus.
    public var focusOrder: [SessionKey] {
        if earlierSessions?.isExpanded == false { return [] }
        return rows.filter { $0.undo == nil }.map(\.key)
    }
}

/// The popover's tabs in the title bar, in their order.
public enum PopoverTab: CaseIterable, Sendable, Hashable {
    /// Working, background working and waiting sessions, by last prompt.
    case active
    /// Sessions resting long enough, by when their rest began.
    case idle
    /// Done and stale sessions within their retention, by end.
    case finished

    public var title: LocalizedStringResource {
        switch self {
        case .active: .kit("Active", defaultValue: "Active")
        case .idle: .kit("Idle", defaultValue: "Idle")
        case .finished: .kit("Finished", defaultValue: "Finished")
        }
    }
}

/// One tab in the title bar: its name, how many rows it shows, on Active
/// how many sessions need the user, on Idle and Finished which sessions it
/// holds.
public struct TabItem: Sendable, Equatable, Identifiable {
    public let tab: PopoverTab
    /// The rows the tab shows, undo rows left out.
    public let count: Int
    /// "◆ n": Active sessions in which anyone needs the user; 0 on the other tabs.
    public let needYouCount: Int
    public let isSelected: Bool
    /// The setting `help` is written from when the view asks; nil on Active.
    let rule: Rule?
    /// The dot after the count: one of the rows on Idle or Finished is
    /// unread; never on Active, which opens with the popover.
    public let hasUnread: Bool

    enum Rule: Sendable, Equatable {
        case idle(IdleAfter)
        case finished(FinishedRetention)
    }

    public var id: PopoverTab { tab }
    public var title: LocalizedStringResource { tab.title }

    /// The tooltip of "◆ n", "2 need you"; nil while it doesn't show.
    public var needYouText: LocalizedStringResource? {
        needYouCount > 0 ? .kit("%lld need you", defaultValue: "\(needYouCount) need you") : nil
    }

    /// The tab's tooltip, the rule its sessions follow: "Waiting over 5 min",
    /// "Cleared after 10 min"; nil on Active, whose "◆ n" has its own, and on
    /// Idle under "Never", which moves no session there.
    public var help: LocalizedStringResource? {
        switch rule {
        case let .idle(idleAfter): idleAfter.waitingOverText
        case let .finished(retention): retention.clearedAfterText
        case nil: nil
        }
    }

    /// "Active, 4 sessions, 2 need you", "Idle, 3 sessions, Waiting over
    /// 5 min", "Idle, 3 sessions, unread, Waiting over 5 min"; VoiceOver adds
    /// whether it is selected. Only a tab with a rule holds rows that
    /// can be unread.
    public var accessibilityLabel: LocalizedStringResource {
        let title = tab.title
        if needYouCount > 0 {
            return .kit("%@, %lld sessions, %lld need you", defaultValue: "\(title), \(count) sessions, \(needYouCount) need you")
        }
        if hasUnread, let help {
            return .kit("%@, %lld sessions, unread, %@", defaultValue: "\(title), \(count) sessions, unread, \(help)")
        }
        if let help {
            return .kit("%@, %lld sessions, %@", defaultValue: "\(title), \(count) sessions, \(help)")
        }
        return .kit("%@, %lld sessions", defaultValue: "\(title), \(count) sessions")
    }
}

/// The visible undo entries, sorted by where their rows go. An entry whose
/// targets came back meanwhile (new work, see `CollectiveState.apply`) has
/// nothing left to undo, so the item shows as usual. A row shows what its
/// Undo takes back (`ownTargets`), so one archived again by a newer entry
/// belongs to that one.
struct UndoRows {
    var sessions: [SessionKey: ArchiveUndo.ID] = [:]
    /// Subagents archived on their own, per session; their rows in the
    /// card's subagent list show the undo row.
    var agents: [SessionKey: [AgentRef: ArchiveUndo.ID]] = [:]
    /// The newest "Archive All Finished" and how many of its sessions Undo takes back.
    var bulk: (id: ArchiveUndo.ID, count: Int)?

    init(_ undo: ArchiveUndo, in state: CollectiveState, at now: Date) {
        for entry in undo.entries where undo.isVisible(entry.id, at: now) {
            let own = entry.ownTargets(in: state)
            switch entry.kind {
            case let .session(key), let .finishedSession(key):
                if !own.isEmpty { sessions[key] = entry.id }
            case .allFinished:
                if !own.isEmpty { bulk = (entry.id, own.count) }
            case let .subagent(key, agent):
                if !own.isEmpty { agents[key, default: [:]][agent] = entry.id }
            }
        }
    }
}

/// Builds a session's item for the popover's list: one place for source
/// name, model name, archive state, undo row and reply previews.
struct SessionItems {
    let state: CollectiveState
    let now: Date
    let sourceNames: [SourceID: String]
    let sourceLogos: [SourceID: String]
    let modelNaming: [SourceID: any ModelNaming]
    let resumeCommands: [SourceID: ResumeCommand]
    let expansion: PopoverExpansion
    let replyPreviews: ReplyPreviewCache.Build
    let undoRows: UndoRows
    /// For when the undo rows go (`SessionItem.nextChange`).
    let undo: ArchiveUndo
    let terminalApps: any TerminalApps
    let colorsEffortLevels: Bool

    func archive(of session: Session) -> SessionArchive {
        SessionArchive(session, in: state, undo: undoRows.agents[session.key] ?? [:])
    }

    /// - Parameters:
    ///   - archive: The session's archive when the caller has it
    ///     already; built here otherwise.
    ///   - idleSince: When the session began to rest, for a row in the "Idle" group.
    func item(_ session: Session, archive: SessionArchive? = nil, idleSince: Date? = nil) -> SessionItem {
        let source = session.key.source
        return SessionItem(
            session,
            sourceName: sourceNames[source] ?? source.rawValue,
            logoName: sourceLogos[source],
            modelNaming: modelNaming[source] ?? PlainModelNaming(),
            resumeCommand: resumeCommands[source],
            terminalAction: TerminalAction(session: session, apps: terminalApps),
            awaitsPermission: state.awaitsPermission(in: session),
            now: now,
            expansion: expansion,
            replyPreviews: replyPreviews,
            archive: archive ?? self.archive(of: session),
            undo: undoRows.sessions[session.key],
            undoExpiry: undo.nextExpiry(after: now),
            idleSince: idleSince,
            unreadTurnEndedAt: state.isUnread(session.key) ? session.turnEndedAt : nil,
            colorsEffortLevels: colorsEffortLevels
        )
    }
}

/// What of one session the user archived, as its rows need it.
struct SessionArchive {
    /// When each archived agent was archived, on its own, with an ancestor or with its session.
    var marks: [AgentRef: Date] = [:]
    /// Subagents archived on their own whose undo row is still up: until it
    /// goes, the row keeps its place in the card's list.
    var undo: [AgentRef: ArchiveUndo.ID] = [:]

    init() {}

    init(_ session: Session, in state: CollectiveState, undo: [AgentRef: ArchiveUndo.ID] = [:]) {
        for ref in session.agents.keys {
            if let mark = state.archiveMark(of: ref, in: session.key) {
                marks[ref] = mark
            }
        }
        self.undo = undo
    }

    func isArchived(_ ref: AgentRef) -> Bool { marks[ref] != nil }
}

/// An agent's last reply, as the popover shows it.
public struct ReplyItem: Sendable, Equatable, Identifiable {
    public let id: ReplyID
    /// The reply as the agent wrote it, Markdown included: what the reply
    /// card renders.
    public let text: String
    /// What the row shows of it.
    public let preview: ReplyPreview

    /// `nil` only without a reply or for whitespace. A nonblank reply stays
    /// available for rendering even when its plain preview is empty.
    init?(_ reply: String?, id: ReplyID, previews: ReplyPreviewCache.Build) {
        guard let reply, let preview = previews.preview(of: reply) else { return nil }
        self.id = id
        text = reply
        self.preview = preview
    }

}

/// One session in the list; its orchestrator is the item itself, not a row.
public struct SessionItem: Sendable, Equatable, Identifiable {
    public let key: SessionKey
    /// The tool the session runs in, e.g. "Claude Code": the adapter's
    /// display name, else the raw source id.
    public let sourceName: String
    /// The tool's logo in `ToolLogo.bundle`; nil and the jump line shows the
    /// raw source id in its place.
    public let logoName: String?
    /// The card's title: the name the tool gave the session, else the last
    /// path component of the working directory, else the first 8 characters
    /// of the session ID (never the full UUID).
    public let name: String
    public let state: AgentDisplayState
    /// What the active card's surface shows; `nil` on an idle row, a finished
    /// row and an undo row, which have no surface.
    public let cardState: CardState?
    /// Trimmed of surrounding whitespace and newlines, so the one-line view
    /// never starts on an empty line; nil if blank.
    public let prompt: String?
    public let activity: ActivityLine?
    /// The orchestrator's current model; `nil` while unknown.
    public let model: ModelLabel?
    public let startedAt: Date
    public let endedAt: Date?
    public let lastActivity: Date
    /// When the user last sent a prompt; `nil` before the first.
    public let lastPromptAt: Date?
    /// What the menu's "Copy Session ID" copies.
    public var sessionID: String { key.sessionID }
    /// What the menu's "Copy Resume Command" copies, ready to paste into a
    /// terminal; nil if the tool names no resume command.
    public let resumeCommand: String?
    /// What the menu's "Copy Path" copies: the session's folder, quoted for a
    /// terminal when needed; nil without a known folder.
    public let quotedPath: String?
    /// "Show in <App>" on the card, the idle row and the finished row; nil
    /// without a known terminal or app, and on an undo row.
    public let terminalAction: TerminalAction?
    /// What the jump line's button does; nil and the line takes the form
    /// without target. A host's terminal counts too (`claude
    /// --bg`, Codex on the shared daemon), only its app comes forward; a
    /// finished row never jumps, while its menu and ⌘↩ keep `terminalAction`.
    public var jumpAction: TerminalAction? {
        endedAt == nil ? terminalAction : nil
    }
    /// Set while the session's archive can be undone: the card shows this row
    /// instead and no longer counts.
    public let undo: UndoRow?
    /// When the item reads differently by the clock alone: a quiet agent's
    /// "Thinking…" gives way to "No activity", a quick tool call's line
    /// clears, an undo row goes. Nil while nothing waits. The times that count are not part
    /// of it; the views write them at their own clock.
    public let nextChange: Date?
    /// The orchestrator's last reply: on a card only while its turn is over,
    /// since a working one shows its activity there; on a finished row
    /// always. `nil` without a reply.
    public let reply: ReplyItem?
    /// Background subagents at any depth that are working and not archived.
    public let backgroundWorkingCount: Int
    /// Not while any of its agents works, archived ones aside, background
    /// subagents included: their next tool start or spawn would bring the
    /// session back by itself.
    public var isArchivable: Bool { state != .working && summary.workingCount == 0 }
    /// The question the row's question box shows; nil on any other row, a
    /// permission row too (`CardState.question`).
    public let question: QuestionPrompt?
    /// Set while a background shell runs, whatever the orchestrator does:
    /// it can outlive the turn and run on into the next.
    public let shellPill: ShellPill?
    /// An idle row's subagents for its preview; nil on any other item and without subagents.
    public let idleSubagents: IdleSubagents?
    /// The restyled row's one button for its subagents, on active, idle and
    /// finished rows alike; nil without any left to count or a
    /// subagent's undo row to reach, and on the session's own undo row.
    public let subagentToggle: SubagentToggle?
    /// What the permission box shows (`rowDetail`); nil unless the row needs permission.
    let permissionCommand: PermissionCommand?
    /// The turn end the row shows unread, nil while it is read: what the
    /// popover reports as seen (`UnreadReading`), so a turn ending later
    /// stays unread.
    public let unreadTurnEndedAt: Date?
    /// The dot after the name.
    public var isUnread: Bool { unreadTurnEndedAt != nil }
    /// What VoiceOver reads right after the status word, "agent-collective,
    /// waiting for you, unread, 2 minutes"; nil while read.
    public var unreadAccessibilityText: LocalizedStringResource? {
        isUnread ? .kit("unread", defaultValue: "unread") : nil
    }

    public var id: SessionKey { key }

    /// Runtime while active ("4 min"); once finished, how long ago it ended
    /// ("Done 2 min ago", "Lost contact 6 min ago"). At the view's clock, which
    /// counts from `timeCountsFrom`.
    public func timeText(at now: Date) -> LocalizedStringResource {
        // The duration nests as a resource of its own, resolved together with
        // the sentence around it, so both follow the same language.
        guard let endedAt else { return DurationText.format(now.timeIntervalSince(startedAt)) }
        let ago = DurationText.format(now.timeIntervalSince(endedAt))
        return state == .stale
            ? .kit("Lost contact %@ ago", defaultValue: "Lost contact \(ago) ago")
            : .kit("Done %@ ago", defaultValue: "Done \(ago) ago")
    }

    /// What `timeText(at:)` counts from: the start, or the end once it ended.
    public var timeCountsFrom: Date { endedAt ?? startedAt }

    /// When the session began to rest; set only on a row of the "Idle" group.
    public let idleSince: Date?

    /// The restyled row's time, without the state its status word shows
    /// already: the runtime ("31 min"), the rest ("12 min") or how long ago it
    /// ended ("2 min ago"). At the view's clock, which counts from `rowTimeCountsFrom`.
    public func rowTimeText(at now: Date) -> LocalizedStringResource {
        if let idleSince { return DurationText.format(now.timeIntervalSince(idleSince)) }
        guard let endedAt else { return DurationText.format(now.timeIntervalSince(startedAt)) }
        return .kit("%@ ago", defaultValue: "\(DurationText.format(now.timeIntervalSince(endedAt))) ago")
    }

    /// What `rowTimeText(at:)` counts from: the rest on an idle row, else as `timeCountsFrom`.
    public var rowTimeCountsFrom: Date { idleSince ?? timeCountsFrom }

    /// The idle row's time as VoiceOver reads it, "idle for 48 min": the row's
    /// terse "48 min" reads as a fragment when spoken.
    public func idleAccessibilityText(at now: Date) -> LocalizedStringResource? {
        idleSince.map { .kit("idle for %@", defaultValue: "idle for \(DurationText.format(now.timeIntervalSince($0)))") }
    }

    /// When the reply in `reply` was written, what the preview's
    /// "Last reply, … ago" counts from; nil without a reply.
    public var lastReplyAt: Date? { reply?.id.repliedAt }

    /// The head of a row's reply card in any tab, "Last reply, 48 min ago",
    /// at the view's clock; nil without a reply, which shows no card.
    public func lastReplyText(at now: Date) -> LocalizedStringResource? {
        lastReplyAt.map { .kit("Last reply, %@ ago", defaultValue: "Last reply, \(DurationText.format(now.timeIntervalSince($0))) ago") }
    }

    /// What VoiceOver reads for the reply after the card's label, "Last reply:
    /// <text>"; nil without a reply.
    public var lastReplyAccessibilityText: LocalizedStringResource? {
        reply.map { .kit("Last reply: %@", defaultValue: "Last reply: \($0.preview.multiline)") }
    }

    /// The disabled first line of the card's menu, so the user can tell a
    /// hanging session from a quiet one before archiving it; counts from
    /// `lastActivity`.
    public func lastEventText(at now: Date) -> LocalizedStringResource {
        .lastEvent(now.timeIntervalSince(lastActivity))
    }

    /// The subagent counts behind `idleSubagents` and `subagentToggle`.
    public let summary: Summary

    public struct Summary: Sendable, Equatable {
        /// Every subagent at any depth, folded ones included.
        public let subagentCount: Int
        /// Working or still unassigned, those that need the user included;
        /// archived ones are neither. What keeps a session from being archived.
        public let workingCount: Int
        /// Not archived and waiting for the user to allow a tool call or to
        /// answer a question: "2 need you", no longer counted as working or
        /// waiting for a type.
        public let needYouCount: Int
        /// Working, named by a type or a title, and not needing the user: the
        /// summary's "3 working".
        public let busyCount: Int
        /// Working without a type or a title yet and not needing the user:
        /// "1 waiting for a type".
        public let unassignedCount: Int
        /// Archived subagents count only as archived, whatever their status.
        public let doneCount: Int
        public let staleCount: Int
        public let archivedCount: Int

        init(_ session: Session, archive: SessionArchive) {
            self.init(session.descendants(of: .root).map { agent in
                let archived = archive.isArchived(agent.id)
                return (
                    AgentDisplayState(subagent: agent, archived: archived),
                    !archived && (session.awaitsPermission(agent.id) || session.awaitsAnswer(agent.id))
                )
            })
        }

        /// The counts of the states of some subagents, none of them needing the user.
        init(states all: [AgentDisplayState]) {
            self.init(all.map { ($0, false) })
        }

        /// The counts of some subagents: each one's state and whether it needs the user.
        init(_ all: [(state: AgentDisplayState, needsYou: Bool)]) {
            subagentCount = all.count
            workingCount = all.count { $0.state == .working || $0.state == .unassigned }
            needYouCount = all.count(where: \.needsYou)
            busyCount = all.count { $0.state == .working && !$0.needsYou }
            unassignedCount = all.count { $0.state == .unassigned && !$0.needsYou }
            doneCount = all.count { $0.state == .done }
            staleCount = all.count { $0.state == .stale }
            archivedCount = all.count { $0.state == .archived }
        }
    }

    /// - Parameters:
    ///   - awaitsPermission: An agent not archived waits for the user to allow
    ///     a tool call (`CollectiveState.awaitsPermission(in:)`), as the menu
    ///     bar and "◆ n" count it.
    ///   - undoExpiry: When the next undo row goes, of any item.
    ///   - idleSince: When the session began to rest, for a row in the "Idle" group.
    ///   - unreadTurnEndedAt: The turn end `CollectiveState.isUnread` holds unread.
    ///   - colorsEffortLevels: `PopoverSettings.colorsEffortLevels`.
    init(
        _ session: Session, sourceName: String, logoName: String? = nil, modelNaming: any ModelNaming,
        resumeCommand: ResumeCommand?, terminalAction: TerminalAction? = nil, awaitsPermission: Bool, now: Date,
        expansion: PopoverExpansion, replyPreviews: ReplyPreviewCache.Build,
        archive: SessionArchive, undo: ArchiveUndo.ID?, undoExpiry: Date?, idleSince: Date? = nil,
        unreadTurnEndedAt: Date? = nil, colorsEffortLevels: Bool = true
    ) {
        key = session.key
        self.sourceName = sourceName
        self.logoName = logoName
        name = session.title
        backgroundWorkingCount = session.backgroundWorkingCount(archive: archive)
        state = AgentDisplayState(orchestratorOf: session, archive: archive)
        let asked = QuestionPrompt(session, archive: archive, appName: terminalAction?.appName)
        cardState = session.endedAt == nil && idleSince == nil && undo == nil
            ? CardState(state, awaitsPermission: awaitsPermission, awaitsAnswer: asked != nil) : nil
        question = cardState == .question ? asked : nil
        permissionCommand = cardState == .needsPermission ? PermissionCommand(session, archive: archive) : nil
        shellPill = if !session.runsBackgroundShell {
            nil
        } else if session.listsNewestBackgroundShell {
            ShellPill(listed: session.backgroundShells, at: session.backgroundShellsListedAt)
        } else {
            // A shell started since the listing, which names too few: only
            // that one runs is certain (4c).
            ShellPill()
        }
        prompt = PromptText.display(session.root.spec.prompt)
        let waitingOn = ActivityLine.waitingOn(in: session, archive: archive)
        // The call that asks is no activity worth showing next to the question.
        // The detail counts no subagents: the toggle line does.
        activity = cardState == .question ? nil : ActivityLine(session.root, waitingOn: [:], archive: archive, now: now)
        model = ModelLabel(orchestratorOf: session, naming: modelNaming, colorsEffort: colorsEffortLevels)
        startedAt = session.startedAt
        endedAt = session.endedAt
        lastActivity = session.lastActivity
        lastPromptAt = session.lastPromptAt
        self.idleSince = idleSince
        self.unreadTurnEndedAt = unreadTurnEndedAt
        self.resumeCommand = resumeCommand?.commandLine(sessionID: session.key.sessionID, cwd: session.cwd)
        self.quotedPath = session.cwd.flatMap { $0.isEmpty ? nil : ShellQuoting.quoted($0) }
        self.terminalAction = undo == nil ? terminalAction : nil
        self.undo = undo.map { [name] in UndoRow(id: $0, subject: .session(name: name)) }
        let replyID: ReplyID? = if session.endedAt != nil {
            session.rootRepliedAt.map { .finished(session.key, repliedAt: $0) }
        } else if [.waiting, .backgroundWorking, .backgroundShell].contains(state) {
            session.rootRepliedAt.map { .session(session.key, repliedAt: $0) }
        } else {
            nil
        }
        reply = replyID.flatMap { ReplyItem(session.root.reply, id: $0, previews: replyPreviews) }
        summary = Summary(session, archive: archive)
        idleSubagents = idleSince != nil ? IdleSubagents(session, summary: summary, naming: modelNaming) : nil
        // Active, idle and finished rows open the same list.
        subagentToggle = undo == nil && summary.subagentCount > 0
            ? SubagentToggle(
                list: SubagentList(
                    SubagentListBuild(
                        session: session, archive: archive, modelNaming: modelNaming, now: now,
                        expansion: expansion, replyPreviews: replyPreviews, waitingOn: waitingOn,
                        colorsEffortLevels: colorsEffortLevels
                    ),
                    needsYou: summary.needYouCount > 0
                ),
                summary: summary,
                showsUndoRows: !archive.undo.isEmpty
            )
            : nil
        let activityChanges = session.agents.values.compactMap {
            // The root's line as `activity` has it; the subagents' as their rows do.
            ActivityLine.nextChange(of: $0, waitingOn: $0.id == .root ? [:] : waitingOn, archive: archive, after: now)
        }
        nextChange = (activityChanges + [undo != nil || !archive.undo.isEmpty ? undoExpiry : nil]).compactMap { $0 }.min()
    }
}

/// What an active card's surface shows: the state, not the tool.
public enum CardState: Sendable, Equatable {
    /// The orchestrator works, or it rests while at least one background
    /// agent works: the row looks the same, only the status word tells the
    /// background agent apart.
    case working
    /// Waits for the user's next prompt.
    case waiting
    /// Only a background shell runs: no agent works, no call to act.
    case background
    /// Any agent of the session waits for the user to allow a tool call, the
    /// orchestrator or a subagent, in the foreground or the background. A
    /// call to act, so it wins over every other state.
    case needsPermission
    /// An agent of the session that is not archived waits for the user to
    /// answer its questions (`SessionItem.question`), any agent as for
    /// `needsPermission`. A call to act as well; only a permission request
    /// wins over it, since a tool call waiting blocks the agent the same way
    /// and the permission card says what to allow.
    case question

    /// - Parameters:
    ///   - state: The orchestrator's state as its card shows it.
    ///   - awaitsAnswer: An agent not archived waits for its questions' answers.
    init?(_ state: AgentDisplayState, awaitsPermission: Bool, awaitsAnswer: Bool = false) {
        let shown: CardState? = switch state {
        case .working: .working
        case .backgroundWorking: .working
        case .waiting: .waiting
        case .backgroundShell: .background
        case .done, .stale, .unassigned, .archived: nil
        }
        guard let shown else { return nil }
        self = awaitsPermission ? .needsPermission : awaitsAnswer ? .question : shown
    }
}

/// A shell command the orchestrator started in the background still runs,
/// as the live report says. Which ones only the listing at the last turn end
/// tells, and a shell that ended since is still on it: so the pill names a
/// shell only when exactly one was listed, and the tooltip says as of when.
public struct ShellPill: Sendable, Equatable {
    private let listedCount: Int
    /// After the separator: the only listed shell's command, else its
    /// description; nil with none or several listed.
    public let shellText: String?
    /// Nil when nothing was listed: the pill's text says all there is.
    public let tooltip: Tooltip?

    /// The listing, one line each: `head`, then `shells`, then `foot`.
    public struct Tooltip: Sendable, Equatable {
        let listedAt: Date
        /// Each listed shell's command, else its description; shells with
        /// neither are left out.
        public let shells: [String]
        let mayBeStale: Bool

        /// "As of last turn end · 14:05", the time in the text's locale when shown.
        public var head: LocalizedStringResource {
            .kit("As of last turn end · %@", defaultValue: "As of last turn end · \(listedAt, format: Date.FormatStyle(date: .omitted, time: .shortened))")
        }

        /// With several listed, some may have ended since the listing.
        public var foot: LocalizedStringResource? {
            mayBeStale ? .kit("Some may have finished since.", defaultValue: "Some may have finished since.") : nil
        }
    }

    /// - Parameters:
    ///   - listed: The shells the last turn end listed, as of `listedAt`.
    init(listed: [BackgroundShell] = [], at listedAt: Date? = nil) {
        let texts = listed.map { shell in
            [shell.command, shell.description].lazy.compactMap { $0 }.first { !$0.isEmpty }
        }
        listedCount = texts.count
        shellText = texts.count == 1 ? texts[0] : nil
        tooltip = if let listedAt, !texts.isEmpty {
            Tooltip(listedAt: listedAt, shells: texts.compactMap { $0 }, mayBeStale: texts.count > 1)
        } else {
            nil
        }
    }

    /// The last turn end listed more than one: "shells running".
    var listsSeveral: Bool { listedCount > 1 }
}

/// A session's subagents counted by status, "2 working | 1 done", as the
/// idle row's preview has them.
struct SubagentsHeader: Sendable, Equatable {
    /// The texts are written from the counts when a view asks.
    private let summary: SessionItem.Summary

    init(summary: SessionItem.Summary) {
        self.summary = summary
    }

    /// The non-zero counts in a fixed order: need you, working, waiting for
    /// a type, done, lost contact, archived, all over every depth; empty
    /// without subagents.
    public var parts: [SubagentStatusPart] {
        let counts: [(SubagentStatusPart.Kind, Int)] = [
            (.needYou, summary.needYouCount), (.working, summary.busyCount), (.waitingForType, summary.unassignedCount),
            (.done, summary.doneCount), (.lostContact, summary.staleCount), (.archived, summary.archivedCount),
        ]
        return counts.compactMap { kind, count in count > 0 ? SubagentStatusPart(kind: kind, count: count) : nil }
    }

    /// The texts of `parts`, e.g. "1 need you", "2 working", "13 done".
    public var statusParts: [LocalizedStringResource] { parts.map(\.text) }
}

/// One count of the subagents, on the toggle line or in the idle row's
/// preview. The text is written from the count when a view asks.
public struct SubagentStatusPart: Sendable, Equatable {
    let kind: Kind
    public let count: Int

    enum Kind: Sendable, Equatable {
        case needYou, working, waitingForType, done, lostContact, archived
    }

    public var text: LocalizedStringResource {
        switch kind {
        case .needYou: .kit("%lld need you", defaultValue: "\(count) need you")
        case .working: .kit("%lld working", defaultValue: "\(count) working")
        case .waitingForType: .kit("%lld waiting for a type", defaultValue: "\(count) waiting for a type")
        case .done: .kit("%lld done", defaultValue: "\(count) done")
        case .lostContact: .kit("%lld lost contact", defaultValue: "\(count) lost contact")
        case .archived: .kit("%lld archived", defaultValue: "\(count) archived")
        }
    }
}

/// The heading the known sessions fold under while subspace is missing or
/// disabled. Counts every session the list
/// would show, undo rows left out.
public struct EarlierSessionsHeader: Sendable, Equatable {
    public let count: Int
    public let isExpanded: Bool

    init(count: Int, isExpanded: Bool) {
        self.count = count
        self.isExpanded = isExpanded
    }

    public var title: LocalizedStringResource { .kit("%lld earlier sessions", defaultValue: "\(count) earlier sessions") }
}

/// A model as the popover names it, with what its tooltip explains.
public struct ModelLabel: Sendable, Equatable {
    /// The short name, e.g. "Opus 5.5", or the raw name if the source's
    /// naming knows no shorter one.
    public let name: String
    /// The model as the source names it; the tooltip's first line.
    public let rawName: String
    /// What `helpDetail` says, written from it when the view asks.
    private let detail: Detail?
    /// The gauge next to the name; nil while the effort is unknown, which
    /// leaves the row as it was without one.
    public let effort: EffortLabel?
    /// The orchestrator's last effort change, the level it left and when;
    /// a subagent's never shows: only the session's are kept.
    private let effortChange: EffortChangeText?

    private struct EffortChangeText: Sendable, Equatable {
        let from: String
        let at: String
    }

    private enum Detail: Sendable, Equatable {
        case switched(from: String, at: String)
        case setAtSpawn
        case inherited
    }

    /// The tooltip's second line: the last switch for an orchestrator, whether
    /// a subagent's model was chosen or inherited.
    public var helpDetail: LocalizedStringResource? {
        switch detail {
        case let .switched(from, at): .kit("Switched from %@ at %@", defaultValue: "Switched from \(from) at \(at)")
        case .setAtSpawn: .kit("Set at spawn", defaultValue: "Set at spawn")
        case .inherited: .kit("Inherited", defaultValue: "Inherited")
        case nil: nil
        }
    }

    /// The tooltip's lines under `rawName`, in order: `helpDetail`, then
    /// the effort, then its last change. Name and gauge share one tooltip,
    /// so the view joins these.
    public var helpLines: [LocalizedStringResource] {
        [helpDetail, effort?.helpLine, effortChangeLine].compactMap { $0 }
    }

    /// "Effort changed from high at 14:20"; only with a known effort, which
    /// the line explains.
    private var effortChangeLine: LocalizedStringResource? {
        guard effort != nil, let effortChange else { return nil }
        let (from, at) = (effortChange.from, effortChange.at)
        return .kit("Effort changed from %@ at %@", defaultValue: "Effort changed from \(from) at \(at)")
    }

    /// The model element's VoiceOver label, "Opus 5.5, effort high"; the
    /// gauge is no element of its own, so its level is read here.
    public var accessibilityLabel: LocalizedStringResource {
        guard let effort else { return .kit("%@", defaultValue: "\(name)") }
        let level = effort.name
        return .kit("%@, effort %@", defaultValue: "\(name), effort \(level)")
    }

    /// Raw names can be long and have no fixed form, so the view caps their width.
    public var isRawName: Bool { name == rawName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private init?(
        _ rawName: String, naming: any ModelNaming, detail: Detail?, effort: EffortLevel?, colorsEffort: Bool,
        effortChange: EffortChangeText? = nil
    ) {
        guard let name = naming.displayName(forModel: rawName) else { return nil }
        self.name = name
        self.rawName = rawName
        self.detail = detail
        self.effort = effort.map { EffortLabel($0, isColored: colorsEffort) }
        self.effortChange = effortChange
    }

    /// The same model without its effort: a finished row names the model
    /// without a gauge, and then neither tooltip nor VoiceOver read one.
    var withoutEffort: ModelLabel {
        ModelLabel(name: name, rawName: rawName, detail: detail, effort: nil, effortChange: nil)
    }

    private init(name: String, rawName: String, detail: Detail?, effort: EffortLabel?, effortChange: EffortChangeText?) {
        self.name = name
        self.rawName = rawName
        self.detail = detail
        self.effort = effort
        self.effortChange = effortChange
    }

    init?(orchestratorOf session: Session, naming: any ModelNaming, colorsEffort: Bool = true) {
        guard let model = session.model else { return nil }
        // The time follows the system's 12/24-hour setting.
        let detail = session.lastModelSwitch.map { last in
            Detail.switched(from: naming.displayName(forModel: last.from) ?? last.from, at: last.at.formatted(date: .omitted, time: .shortened))
        }
        let effortChange = session.lastEffortChange.map {
            EffortChangeText(from: $0.from.name, at: $0.at.formatted(date: .omitted, time: .shortened))
        }
        self.init(model, naming: naming, detail: detail, effort: session.effort, colorsEffort: colorsEffort, effortChange: effortChange)
    }

    /// The subagent's own model whenever the source reports one, with whether
    /// it was chosen or inherited. Never the session's: a subagent may run
    /// with another, so an unknown one stays unnamed. The same holds for its
    /// effort, and only the orchestrator's changes are kept.
    init?(knownModelOf agent: Agent, naming: any ModelNaming, colorsEffort: Bool = true) {
        let chosen = agent.spec.modelAlias != nil
        // The full id replaces the alias once the source reports it.
        guard let raw = agent.spec.modelID ?? agent.spec.modelAlias else { return nil }
        self.init(raw, naming: naming, detail: chosen ? .setAtSpawn : .inherited, effort: agent.effort, colorsEffort: colorsEffort)
    }
}

/// An effort as the gauge next to a model name shows it. Only the step and
/// the tool's name for the level: the gauge needs no tool's scale.
public struct EffortLabel: Sendable, Equatable {
    /// How full the gauge is, 1 to 5.
    public let step: Int
    /// The level as the tool writes it, e.g. "high"; never translated.
    public let name: String
    /// Whether the fill takes the step's own color or the model name's gray
    /// (`PopoverSettings.colorsEffortLevels`); the colors are the view's.
    public let isColored: Bool

    init(_ level: EffortLevel, isColored: Bool) {
        step = level.step
        name = level.name
        self.isColored = isColored
    }

    /// The tooltip line "Effort: high".
    public var helpLine: LocalizedStringResource { .kit("Effort: %@", defaultValue: "Effort: \(name)") }

    /// The fill: one hue of the scheme per step, 4 and 5 sharing the violet
    /// since red, orange and yellow carry meaning; off, the model name's role.
    public var role: ThemeRole { Self.role(step: step, isColored: isColored) }

    /// `role` for any gauge, the settings' preview included.
    static func role(step: Int, isColored: Bool) -> ThemeRole {
        guard isColored else { return .textSubtle }
        return switch step {
        case 1: .success
        case 2: .info
        case 3: .classCode
        default: .accent
        }
    }

    /// The gauge's empty part.
    public static let emptyRole: ThemeRole = .border
}

extension AgentDisplayState {
    init(_ agent: Agent) {
        switch agent.status {
        case .working: self = .working
        case .waiting: self = .waiting
        case .done: self = .done
        case .stale: self = .stale
        }
    }

    /// The orchestrator's state as its card shows it. Precedence: its own
    /// turn > background agents > a background shell > waiting for the user.
    init(orchestratorOf session: Session, archive: SessionArchive) {
        self = if session.root.status != .waiting {
            AgentDisplayState(session.root)
        } else if session.backgroundWorkingCount(archive: archive) > 0 {
            .backgroundWorking
        } else if session.runsBackgroundShell {
            .backgroundShell
        } else {
            .waiting
        }
    }

    /// A type or a title names a subagent ("Awaiting designation…" until
    /// one comes); a finished one keeps its final state. The user's archive
    /// wins over whatever the source reports.
    init(subagent agent: Agent, archived: Bool) {
        self = if archived {
            .archived
        } else if agent.status == .working && agent.spec.type == nil && agent.spec.title == nil {
            .unassigned
        } else {
            AgentDisplayState(agent)
        }
    }
}

private extension Session {
    /// Agents with `isBackground` unknown don't count: nothing says they run
    /// on their own.
    func backgroundWorkingCount(archive: SessionArchive) -> Int {
        agents.values.count {
            $0.id != .root && $0.status == .working && $0.spec.isBackground == true && !archive.isArchived($0.id)
        }
    }
}

private extension LocalizedStringResource {
    static func lastEvent(_ interval: TimeInterval) -> LocalizedStringResource {
        .kit("Last event %@ ago", defaultValue: "Last event \(DurationText.format(interval)) ago")
    }
}

extension ActivityLine {
    /// Foreground children are what a working agent is waiting on, so they
    /// say more than the tool call that started them.
    init?(_ agent: Agent, waitingOn: [AgentRef: Int], archive: SessionArchive, now: Date) {
        guard agent.status == .working, !archive.isArchived(agent.id) else { return nil }
        if let count = waitingOn[agent.id], count > 0 {
            self = .subagentsWorking(count)
        } else if let tool = agent.currentTool {
            self = .tool(tool)
        } else if let call = agent.lastToolCall, now.timeIntervalSince(call.startedAt) < Self.minimumToolDisplay {
            self = .tool(call.tool)
        } else if now.timeIntervalSince(agent.lastActivity) >= Self.quietThreshold {
            self = .noActivity(since: agent.lastActivity)
        } else {
            self = .thinking
        }
    }

    /// When the line of `init` changes by the clock alone: a finished quick
    /// tool call gives way, "Thinking…" turns into "No activity".
    static func nextChange(of agent: Agent, waitingOn: [AgentRef: Int], archive: SessionArchive, after now: Date) -> Date? {
        guard agent.status == .working, !archive.isArchived(agent.id), agent.currentTool == nil,
              waitingOn[agent.id, default: 0] == 0 else { return nil }
        let toolEnds = agent.lastToolCall.map { $0.startedAt.addingTimeInterval(minimumToolDisplay) }
        let quiet = agent.lastActivity.addingTimeInterval(quietThreshold)
        return [toolEnds, quiet].compactMap { $0 }.filter { $0 > now }.min()
    }

    /// How many working foreground children each agent waits on, counted
    /// in one pass: asking each agent for its children would scan the whole
    /// session once per agent.
    static func waitingOn(in session: Session, archive: SessionArchive) -> [AgentRef: Int] {
        session.agents.values.reduce(into: [:]) { counts, child in
            guard let parent = child.parent, child.status == .working, child.spec.isBackground != true,
                  !archive.isArchived(child.id) else { return }
            counts[parent, default: 0] += 1
        }
    }
}

/// One normalisation for every prompt the popover shows, so a leading newline
/// in the payload cannot turn a one-line view into an empty line.
enum PromptText {
    /// A blank prompt is no prompt: the card has nothing to show for it.
    static func display(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
