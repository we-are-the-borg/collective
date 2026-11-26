import Foundation
import SubspaceKit

/// One tool's card in the setup window: how far its subspace integration
/// got and what the user can copy, or have the card run, to finish it.
public struct SetupCardModel: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case notInstalled
        case disabled
        /// Enabled, but neither has subspace seen a session start nor the app an event.
        case waiting
        case ready
        /// The tool's CLI is not on this Mac, no path without it applies, and
        /// subspace is neither enabled nor disabled for it.
        case notFound
        /// The CLI is found, but its list could not be read and no earlier check
        /// knew the plugin: like Settings before the first check, no claim.
        case checking

        var pluginEnabled: Bool { self == .waiting || self == .ready }
    }

    public struct Pill: Sendable, Equatable {
        public let text: LocalizedStringResource
    }

    public struct Step: Sendable, Equatable {
        public enum Symbol: Sendable, Equatable { case done, waiting, open, warning }
        public let symbol: Symbol
        public let title: LocalizedStringResource
        public let detail: LocalizedStringResource?
    }

    /// The command boxes, shown whenever a card has them; command lines are plain strings.
    public struct CommandsBox: Sendable, Equatable {
        /// Typed in a terminal, or run by the card's button.
        public let lines: [Line]
        /// Under the terminal lines; nil when the card cannot run them (no program found)
        /// or a failed run left nothing to try again (the plugin is enabled after all).
        public let footer: Footer?
        /// Typed in a session of the tool itself; never run by the card.
        public let inApp: [String]

        /// The terminal lines' commands alone.
        public var terminal: [String] { lines.map(\.command) }
    }

    public let source: SourceID
    public let state: State
    public let title: String
    public let pill: Pill?
    /// The restyled section header's form, in the role it and the status word
    /// take; not installed shows its hollow ring without a word.
    public let statusMark: SourceStatusMark
    /// One monospaced line under the title.
    public let subtitle: LocalizedStringResource
    /// Empty when ready or not found.
    public let steps: [Step]
    /// Stands in for the steps when the CLI was not found, or the program of
    /// the path without it (`SetupCommands.withoutCLI`).
    public let note: LocalizedStringResource?
    /// The update box's while `update` is set.
    public let commands: CommandsBox?
    /// What the button runs when no run exists yet; nil when the card has no button.
    /// Never an update's: that is `update.runPlan`.
    public let runPlan: RunPlan?
    /// The subspace update a connected or waiting card offers, or a started
    /// run of it on any card; nil when there is none, and on a disabled card
    /// without a run, whose Enable box matters more (one box per card).
    public let update: SourceUpdateModel?
    /// Under the header while an update is offered or required.
    public let updateText: LocalizedStringResource?

    /// The box's button goes to the update run (`SetupRuns.runUpdate`), not
    /// to the card's install or enable (`SetupRuns.run`): "Try Again" is in both.
    public var buttonRunsUpdate: Bool { update != nil }

    /// - Parameters:
    ///   - lastEventAt: When the newest event the app read from the tool's spool happened.
    ///     It stands in for a session start subspace has no record of.
    ///   - run: This window's run of the card's commands, if one was started.
    ///     A running run always shows; a finished one only while the probe's
    ///     plan is its own step or the plugin is enabled, otherwise the card
    ///     is the one without a run (`standing(of:plan:state:programFound:)`).
    ///   - outputShown: Whether the user asked to see a succeeded run's output.
    ///   - availability: What the release check says about the installed plugin.
    ///   - updateRun: The tool's update run as the windows show it (`SetupRuns.updateSnapshots`).
    ///   - checksForUpdates: The switch in General › Updates.
    ///   - checkedAt: When the probe that reported `status` started; only a
    ///     later one confirms an update run (`SourceUpdateModel`).
    ///   - home: The home folder shown as `~` in paths.
    ///   - timeZone: Of the time a run succeeded at.
    public init(
        _ status: IntegrationStatus,
        lastEventAt: Date? = nil,
        run: SetupCommandRun.Snapshot? = nil,
        outputShown: Bool = false,
        availability: UpdateAvailability = .upToDate,
        updateRun: SetupCommandRun.Snapshot? = nil,
        checksForUpdates: Bool = true,
        checkedAt: Date? = nil,
        now: Date,
        home: String = NSHomeDirectory(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        let toolName = status.toolName
        source = status.source
        title = toolName
        let connection = Self.connection(status, lastEventAt: lastEventAt)
        state = Self.state(of: status, lastEventAt: lastEventAt)
        let plan = Self.runPlan(status, state: state)
        runPlan = plan
        // The CLI, or the program of the path without it: whichever ran the card's lines.
        let programFound = switch (status.cli, status.withoutCLI?.program) {
        case (.found, _), (_, .found?): true
        default: false
        }
        // An update run is the update box's (`SourceUpdateModel`), not one of the card's steps.
        let run: (snapshot: SetupCommandRun.Snapshot, standing: RunStanding, step: RunPlan.Step)? =
            if let run, let step = run.kind.step, let standing = Self.standing(of: run, plan: plan, state: state, programFound: programFound) {
                (run, standing, step)
            } else {
                nil
            }
        // The same group the settings pane shows, so both windows agree on it.
        // A started run shows whatever the card's state, as in the pane: a
        // probe that briefly can't read the plugin, or a disabled source
        // updated from Settings, keeps the run's progress.
        let runStarted = updateRun.map { $0.phase != .idle } ?? false
        let update: SourceUpdateModel? = if runStarted || state == .ready || state == .waiting {
            SourceUpdateModel(status, checkedAt: checkedAt, availability: availability, run: updateRun, outputShown: outputShown,
                              checksForUpdates: checksForUpdates, now: now, timeZone: timeZone)
        } else {
            nil
        }
        self.update = update
        updateText = switch (update?.state, availability) {
        case let (.available?, .available(installed, latest)):
            .kit("subspace %@ is available. You have %@.", defaultValue: "subspace \(latest.description) is available. You have \(installed.description).")
        case let (.required?, .required(installed, minimum, _)):
            .kit(
                "This version of The Collective needs subspace %@ or later. You have %@, so some events from %@ sessions won’t show up.",
                defaultValue: "This version of The Collective needs subspace \(minimum.description) or later. You have \(installed.description), so some events from \(toolName) sessions won’t show up."
            )
        default:
            nil
        }

        subtitle = switch (state, status.plugin, status.cli, connection) {
        case (.ready, .enabled(let version?), _, .sessionStarted(let date)?):
            .kit(
                "subspace %@ · last session started %@ ago",
                defaultValue: "subspace \(version) · last session started \(DurationText.format(now.timeIntervalSince(date))) ago"
            )
        case (.ready, _, _, .sessionStarted(let date)?):
            .kit(
                "subspace · last session started %@ ago",
                defaultValue: "subspace · last session started \(DurationText.format(now.timeIntervalSince(date))) ago"
            )
        case (.ready, .enabled(let version?), _, .event(let date)?):
            .kit(
                "subspace %@ · last event %@ ago",
                defaultValue: "subspace \(version) · last event \(DurationText.format(now.timeIntervalSince(date))) ago"
            )
        case (.ready, _, _, .event(let date)?):
            .kit(
                "subspace · last event %@ ago",
                defaultValue: "subspace · last event \(DurationText.format(now.timeIntervalSince(date))) ago"
            )
        // The defaults spell out the keys although English drops the labels:
        // Xcode extracts every default as a key, and one that differs from its
        // key lands in the catalog as a new, comment-less entry.
        case (_, _, .found(let path, let version?), _):
            .kit("CLI path %@ · version %@", defaultValue: "CLI path \(Self.abbreviating(path, home: home)) · version \(version)")
        case (_, _, .found(let path, nil), _):
            .kit("CLI path %@", defaultValue: "CLI path \(Self.abbreviating(path, home: home))")
        case (_, _, .notFound, _):
            .kit("%@ · not on this Mac", defaultValue: "\(status.cliName) · not on this Mac")
        }

        // An update's pill outranks the probe's until it is done; only a
        // failure that stays to be tried again does as well.
        (pill, statusMark) = if let updatePill = update.flatMap(Self.updatePill) {
            updatePill
        } else if case .failed = run?.snapshot.phase, run?.standing == .ownStep {
            (Pill(text: .kit("Failed", defaultValue: "Failed")), .failed)
        } else {
            switch state {
            case .notInstalled: (nil, .unknown)
            case .disabled: (Pill(text: .kit("Disabled", defaultValue: "Disabled")), .warning)
            case .waiting: (Pill(text: .kit("Waiting for a session", defaultValue: "Waiting for a session")), .waiting)
            case .ready: (Pill(text: .kit("Connected", defaultValue: "Connected")), .connected)
            case .notFound: (Pill(text: .kit("Not found", defaultValue: "Not found")), .unknown)
            case .checking: (Pill(text: .kit("Checking…", defaultValue: "Checking…")), .unknown)
            }
        }

        // Only a CLI the probe actually found gets its tick.
        var found: [Step] = []
        if case .found = status.cli {
            found = [Step(symbol: .done, title: .kit("%@ found", defaultValue: "\(toolName) found"), detail: nil)]
        }
        let firstSessionSeen = Step(symbol: .open, title: .kit("First session seen", defaultValue: "First session seen"), detail: nil)
        steps = switch state {
        case .notInstalled:
            found + [
                Step(symbol: .open, title: .kit("subspace installed", defaultValue: "subspace installed"), detail: nil),
                Step(symbol: .open, title: .kit("Plugin enabled", defaultValue: "Plugin enabled"), detail: nil),
                firstSessionSeen,
            ]
        case .disabled:
            found + [
                Step(symbol: .done, title: .kit("subspace installed", defaultValue: "subspace installed"), detail: Self.installedDetail(status.plugin)),
                Step(
                    symbol: .warning,
                    title: .kit("Plugin is disabled", defaultValue: "Plugin is disabled"),
                    detail: .kit(
                        "subspace is switched off in %@, so sessions you start from now on won’t report here.",
                        defaultValue: "subspace is switched off in \(toolName), so sessions you start from now on won’t report here."
                    )
                ),
                firstSessionSeen,
            ]
        case .waiting:
            found + [
                Step(symbol: .done, title: .kit("subspace installed", defaultValue: "subspace installed"), detail: nil),
                Step(symbol: .done, title: .kit("Plugin enabled", defaultValue: "Plugin enabled"), detail: nil),
                Step(
                    symbol: .waiting,
                    title: .kit("Waiting for the first session", defaultValue: "Waiting for the first session"),
                    detail: status.commands.firstSessionHint ?? .kit(
                        "Start a new %@ session. Sessions that were already running pick up subspace after a restart.",
                        defaultValue: "Start a new \(toolName) session. Sessions that were already running pick up subspace after a restart."
                    )
                ),
            ]
        case .ready, .notFound, .checking:
            []
        }

        note = if state == .notFound {
            Self.notFoundNote(status)
        } else if state == .notInstalled, let alternative = status.withoutCLI, alternative.program == .notFound {
            Self.programMissingNote(alternative.commands)
        } else {
            nil
        }

        commands = update?.commands ?? Self.commandsBox(status, state: state, plan: plan, run: run, outputShown: outputShown, timeZone: timeZone)
    }

    /// Updated, the card is connected again, and its subtitle names the new version.
    /// The form is the update's own, so the card and the source's pane agree.
    private static func updatePill(_ update: SourceUpdateModel) -> (Pill, SourceStatusMark)? {
        let pill: Pill? = switch update.state {
        case .available: Pill(text: .kit("Update available", defaultValue: "Update available"))
        case .running: Pill(text: .kit("Updating…", defaultValue: "Updating…"))
        case .failed: Pill(text: .kit("Update failed", defaultValue: "Update failed"))
        case .required: Pill(text: .kit("Update required", defaultValue: "Update required"))
        case .updated: nil
        }
        return pill.map { ($0, update.statusMark) }
    }

    /// A known plugin state counts even without a CLI (read from the tool's
    /// settings as a fallback), so the card agrees with the popover's warning;
    /// otherwise a missing CLI explains the rest, unless the tool is there
    /// with a path without it: then subspace is just not installed yet. Events
    /// only stand in for a session start, never for an enabled plugin. An
    /// unknown plugin with the CLI found is a failed check, not a missing install.
    static func state(of status: IntegrationStatus, lastEventAt: Date? = nil) -> State {
        let missing: State = status.withoutCLI == nil ? .notFound : .notInstalled
        return switch status.plugin {
        case .enabled: connection(status, lastEventAt: lastEventAt) == nil ? .waiting : .ready
        case .disabled: .disabled
        case .notInstalled: status.cli == .notFound ? missing : .notInstalled
        case .unknown: status.cli == .notFound ? missing : .checking
        }
    }

    /// What shows an enabled plugin works: subspace's record of a session start
    /// or an event the app read. A reinstall can lose the record (the tool
    /// recreates its data folder) while running sessions go on delivering, so
    /// either counts, and the newer one is named; a tie names the start.
    private enum Connection { case sessionStarted(Date), event(Date) }

    private static func connection(_ status: IntegrationStatus, lastEventAt: Date?) -> Connection? {
        switch (status.lastSessionStartAt, lastEventAt) {
        case let (started?, event?): event > started ? .event(event) : .sessionStarted(started)
        case let (started?, nil): .sessionStarted(started)
        case let (nil, event?): .event(event)
        case (nil, nil): nil
        }
    }

    /// Only a user-scope install counts as installed, so the scope is known.
    private static func installedDetail(_ plugin: IntegrationStatus.Plugin) -> LocalizedStringResource {
        if case .disabled(let version?) = plugin {
            return .kit("%@ · user scope", defaultValue: "\(version) · user scope")
        }
        return .kit("user scope", defaultValue: "user scope")
    }

    private static func notFoundNote(_ status: IntegrationStatus) -> LocalizedStringResource {
        let toolName = status.toolName
        switch status.searchedLocations.count {
        case 0:
            return .kit(
                "The Collective looked in your login shell’s PATH. If you don’t use %@, you can ignore this.",
                defaultValue: "The Collective looked in your login shell’s PATH. If you don’t use \(toolName), you can ignore this."
            )
        case 1:
            let location = status.searchedLocations[0]
            return .kit(
                "The Collective looked in %@ and your login shell’s PATH. If you don’t use %@, you can ignore this.",
                defaultValue: "The Collective looked in \(location) and your login shell’s PATH. If you don’t use \(toolName), you can ignore this."
            )
        default:
            let locations = status.searchedLocations.joined(separator: ", ")
            return .kit(
                "The Collective looked in %@, and your login shell’s PATH. If you don’t use %@, you can ignore this.",
                defaultValue: "The Collective looked in \(locations), and your login shell’s PATH. If you don’t use \(toolName), you can ignore this."
            )
        }
    }

    /// The tool is there, only the program its lines start with is missing, so
    /// they are left to copy; the adapter may say how to get the program.
    private static func programMissingNote(_ alternative: SetupCommands.Alternative) -> LocalizedStringResource {
        let program = alternative.program
        if let hint = alternative.missingProgramHint {
            return .kit(
                "%@ is not on this Mac, so The Collective can’t run these commands. %@",
                defaultValue: "\(program) is not on this Mac, so The Collective can’t run these commands. \(hint)"
            )
        }
        return .kit(
            "%@ is not on this Mac, so The Collective can’t run these commands. Install it first.",
            defaultValue: "\(program) is not on this Mac, so The Collective can’t run these commands. Install it first."
        )
    }

    /// `~` only for the home folder itself or a path inside it, not for a sibling sharing its prefix.
    static func abbreviating(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// The setup window: one card per probed tool and the button that closes it.
public struct SetupWindowModel: Sendable, Equatable {
    public enum PrimaryButton: Sendable, Equatable {
        /// Accent, once nothing is left to do: a tool is installed and enabled, none still needs
        /// install or enable or is still being checked (tools not found on this Mac don't count),
        /// and no run is active.
        case done
        /// Plain, otherwise.
        case later
    }

    public let cards: [SetupCardModel]
    public let primaryButton: PrimaryButton

    /// - Parameters:
    ///   - runs: The runs started in this window, by tool.
    ///   - lastEvents: When the newest event the app read from each tool's spool happened.
    ///   - outputShown: The tools whose succeeded run shows its output.
    ///   - updateRuns: The update runs both windows show, by tool. They never
    ///     count as active: an update doesn't hold back Done.
    ///   - availability: What the release check says per tool; a missing tool is up to date.
    ///   - checksForUpdates: The switch in General › Updates.
    ///   - checkedAt: When the probe behind each tool's status in `integrations` started, by tool.
    public init(
        integrations: [IntegrationStatus],
        runs: [SourceID: SetupCommandRun.Snapshot] = [:],
        lastEvents: [SourceID: Date] = [:],
        outputShown: Set<SourceID> = [],
        updateRuns: [SourceID: SetupCommandRun.Snapshot] = [:],
        availability: [SourceID: UpdateAvailability] = [:],
        checksForUpdates: Bool = true,
        checkedAt: [SourceID: Date] = [:],
        now: Date,
        home: String = NSHomeDirectory(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        cards = integrations.map { status in
            SetupCardModel(
                status,
                lastEventAt: lastEvents[status.source],
                run: runs[status.source],
                outputShown: outputShown.contains(status.source),
                availability: availability[status.source] ?? .upToDate,
                updateRun: updateRuns[status.source],
                checksForUpdates: checksForUpdates,
                checkedAt: checkedAt[status.source],
                now: now,
                home: home,
                timeZone: timeZone
            )
        }
        let installed = cards.contains { $0.state.pluginEnabled }
        // A tool still being checked may yet need setup.
        let pending = cards.contains { [.notInstalled, .disabled, .checking].contains($0.state) }
        let running = runs.values.contains { if case .running = $0.phase { true } else { false } }
        primaryButton = installed && !pending && !running ? .done : .later
    }
}
