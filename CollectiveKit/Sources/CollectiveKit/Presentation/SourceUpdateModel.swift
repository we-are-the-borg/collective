import Foundation
import SubspaceKit

/// The "Update" group of a source's settings pane, under its subspace row,
/// while there is something to do about the installed plugin. The
/// box is the setup card's: numbered lines, a footer with the consent
/// sentence and one button.
public struct SourceUpdateModel: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// A newer release is published; the installed plugin still works.
        case available
        /// Also after every line succeeded, until a probe confirms or refutes it.
        case running
        /// A line failed, or every line succeeded yet the tool doesn't report the new version.
        case failed
        /// A probe after the run reports the new version; the group stays until the windows close.
        case updated
        /// The installed plugin is older than this app needs.
        case required
    }

    public let source: SourceID
    public let state: State
    /// The form in front of the title, in the role it takes; the sources' status forms,
    /// so a run shows a halo rather than a spinner.
    public let statusMark: SourceStatusMark
    public let title: LocalizedStringResource
    /// Right of the title; nil once updated.
    public let subtitle: LocalizedStringResource?
    /// Under the header; only for a required update.
    public let text: LocalizedStringResource?
    /// Always set: without update lines there is no group.
    public let commands: SetupCardModel.CommandsBox?
    /// What "Update" runs; nil while a run shows or without a found CLI.
    public let runPlan: SetupCardModel.RunPlan?

    /// - Parameters:
    ///   - checkedAt: When the probe that reported `status` started. Only a
    ///     probe started after an update run succeeded can confirm it: the
    ///     commands' exit codes alone don't prove the tool took the new version.
    ///   - availability: What the release check says about the installed plugin.
    ///   - run: The source's update run as the windows show it. One that
    ///     started always shows, so an ended run keeps the group although the
    ///     recheck after a success turns `availability` to `.upToDate`.
    ///   - outputShown: Whether the user asked to see a succeeded run's output.
    ///   - checksForUpdates: The switch in General › Updates. Off, only a
    ///     required update shows, since the app knows its minimum without asking GitHub.
    ///   - now: Caps how long a succeeded run waits for a probe to confirm it.
    ///   - timeZone: Of the time a run succeeded at.
    /// - Returns: nil while there is nothing to do: up to date, no readable
    ///   installed version, a source that is not installed or not found, an
    ///   adapter without update lines, or an available update with the switch off.
    public init?(
        _ status: IntegrationStatus,
        checkedAt: Date?,
        availability: UpdateAvailability,
        run: SetupCommandRun.Snapshot? = nil,
        outputShown: Bool = false,
        checksForUpdates: Bool,
        now: Date,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        if let run, case .update(let from, let to) = run.kind, run.phase != .idle {
            let outcome = Self.outcome(of: run.phase, to: to, status: status, checkedAt: checkedAt, now: now)
            self.init(status, run: run, outcome: outcome, from: from, to: to, outputShown: outputShown, timeZone: timeZone)
            return
        }
        // Without lines there is no box and no button; a required update
        // still shows in the status row.
        guard Self.installedVersion(status) != nil, !Self.updateCommands(status).lines.isEmpty else { return nil }
        switch SetupCardModel.state(of: status) {
        case .ready, .waiting, .disabled: break
        case .notInstalled, .notFound, .checking: return nil
        }
        switch availability {
        case .upToDate:
            return nil
        case .available(let installed, let latest):
            guard checksForUpdates else { return nil }
            self.init(
                offering: status, from: installed, to: latest, state: .available, statusMark: .updateAvailable,
                title: .kit("subspace %@ is available", defaultValue: "subspace \(latest.description) is available"),
                text: nil
            )
        case .required(let installed, let minimum, let latest):
            // Without a lookup the minimum is the release known to exist.
            self.init(
                offering: status, from: installed, to: latest ?? minimum, state: .required, statusMark: .warning,
                title: .kit("The Collective needs subspace %@ or later", defaultValue: "The Collective needs subspace \(minimum.description) or later"),
                text: .kit(
                    "Until you update, some events from %@ sessions won’t show up here.",
                    defaultValue: "Until you update, some events from \(status.toolName) sessions won’t show up here."
                )
            )
        }
    }

    /// Before a run: the numbered lines and the Update button. Only a program
    /// the probe found can run them; without one they are only there to copy,
    /// as on the setup card.
    private init(
        offering status: IntegrationStatus,
        from: SubspaceVersion,
        to: SubspaceVersion,
        state: State,
        statusMark: SourceStatusMark,
        title: LocalizedStringResource,
        text: LocalizedStringResource?
    ) {
        source = status.source
        self.state = state
        self.statusMark = statusMark
        self.title = title
        subtitle = Self.youHave(from)
        self.text = text
        let (update, program) = Self.updateCommands(status)
        guard let program else {
            let lines = update.map { SetupCardModel.CommandsBox.Line(command: $0, slot: nil, tag: nil, output: nil) }
            (commands, runPlan) = (SetupCardModel.CommandsBox(lines: lines, footer: nil, inApp: []), nil)
            return
        }
        runPlan = SetupCardModel.RunPlan(kind: .update(from: from, to: to), lines: update, skipping: [],
                                         programName: program.name, programPath: program.path)
        let lines = update.enumerated().map { index, command in
            SetupCardModel.CommandsBox.Line(command: command, slot: .number(index + 1), tag: nil, output: nil)
        }
        let footer = SetupCardModel.CommandsBox.Footer(
            text: Self.intro(lineCount: update.count, hint: status.commands.updateHint),
            isWarning: false,
            link: status.commands.release?.changesURL(from: from.description, to: to.description).map { .init(kind: .changes, url: $0) },
            outputToggle: nil,
            button: Self.updateButton(lines: update)
        )
        commands = SetupCardModel.CommandsBox(lines: lines, footer: footer, inApp: [])
    }

    /// What a started run shows: a succeeded one only counts once a probe confirms it.
    private enum Outcome {
        case running
        case failed(line: Int)
        /// Every line succeeded, yet the probe after it still reports `installed`
        /// (nil: no readable version) instead of the target.
        case notConfirmed(installed: SubspaceVersion?)
        case updated(at: Date, installed: SubspaceVersion)
    }

    /// How long a succeeded run waits for a probe to confirm it; an open
    /// source pane probes every 5 s. A single list may legitimately take up to
    /// its timeout, so the window follows that bound plus a margin.
    static let confirmationTimeout: TimeInterval = {
        let bound = CLILocator.listTimeout + confirmationMargin
        return TimeInterval(bound.components.seconds)
    }()

    /// Covers the runner's drain and terminate grace after a timed-out list
    /// and the start of the next probe.
    static let confirmationMargin: Duration = .seconds(15)

    private static func outcome(of phase: SetupCommandRun.Phase, to: SubspaceVersion, status: IntegrationStatus,
                                checkedAt: Date?, now: Date) -> Outcome {
        switch phase {
        case .idle, .running:
            return .running
        case .failed(let line):
            return .failed(line: line)
        case .succeeded(let date):
            // A probe started before the success may have read the old plugin,
            // and an unknown state (a timed-out list) says nothing either way,
            // nor does the earlier check's state the app kept in its place.
            guard let checkedAt, checkedAt > date, status.plugin != .unknown, !status.pluginIsCarriedOver else {
                return now.timeIntervalSince(date) >= confirmationTimeout ? .notConfirmed(installed: nil) : .running
            }
            // The marketplace may have known a newer release than the lookup.
            let installed = installedVersion(status)
            if let installed, installed >= to { return .updated(at: date, installed: installed) }
            return .notConfirmed(installed: installed)
        }
    }

    private init(
        _ status: IntegrationStatus,
        run: SetupCommandRun.Snapshot,
        outcome: Outcome,
        from: SubspaceVersion,
        to: SubspaceVersion,
        outputShown: Bool,
        timeZone: TimeZone
    ) {
        source = status.source
        text = nil
        runPlan = nil
        typealias Footer = SetupCardModel.CommandsBox.Footer
        let footer: Footer
        switch outcome {
        case .running:
            state = .running
            statusMark = .updating
            title = .kit("Updating to %@…", defaultValue: "Updating to \(to.description)…")
            subtitle = Self.youHave(from)
            footer = Footer(
                text: .kit("Updating subspace…", defaultValue: "Updating subspace…"),
                isWarning: false,
                link: nil,
                outputToggle: nil,
                button: Footer.Button(
                    kind: .update, title: Self.update, isEnabled: false,
                    accessibilityLabel: .kit("Update, running", defaultValue: "Update, running")
                )
            )
        case .failed(let line):
            state = .failed
            statusMark = .failed
            title = .kit("Update to %@ failed", defaultValue: "Update to \(to.description) failed")
            subtitle = .kit("You still have %@", defaultValue: "You still have \(from.description)")
            footer = Footer(
                text: .kit(
                    "Update failed. subspace is downloaded from GitHub; check your connection, then try again.",
                    defaultValue: "Update failed. subspace is downloaded from GitHub; check your connection, then try again."
                ),
                isWarning: true,
                link: nil,
                outputToggle: nil,
                button: Footer.Button(
                    kind: .tryAgain,
                    title: .kit("Try Again", defaultValue: "Try Again"),
                    isEnabled: true,
                    accessibilityLabel: .kit("Try again: runs %@", defaultValue: "Try again: runs \(run.lines[line].command)")
                )
            )
        case .notConfirmed(let installed):
            state = .failed
            statusMark = .failed
            title = .kit("Update to %@ failed", defaultValue: "Update to \(to.description) failed")
            subtitle = installed.map { .kit("You still have %@", defaultValue: "You still have \($0.description)") }
            footer = Footer(
                text: installed.map {
                    .kit("The commands finished, but %@ still reports %@.",
                         defaultValue: "The commands finished, but \(status.toolName) still reports \($0.description).")
                } ?? .kit("The commands finished, but %@ doesn’t report the new version.",
                          defaultValue: "The commands finished, but \(status.toolName) doesn’t report the new version."),
                isWarning: true,
                link: nil,
                outputToggle: outputShown ? .showing : .hidden,
                // No line failed, so it runs them all again.
                button: Self.tryAgainButton(lines: run.lines.map(\.command))
            )
        case .updated(let date, let installed):
            state = .updated
            // Connected again, as the setup card shows it.
            statusMark = .connected
            title = .kit("Updated to %@", defaultValue: "Updated to \(installed.description)")
            subtitle = nil
            footer = Footer(
                text: Self.updated(at: date, version: installed, hint: status.commands.updateHint, timeZone: timeZone),
                isWarning: false,
                link: nil,
                outputToggle: outputShown ? .showing : .hidden,
                button: nil
            )
        }
        // After a success the outputs wait for the toggle; after a failure
        // only the failed line's output shows, and always.
        let lines = run.lines.map { line in
            let slot: SetupCardModel.CommandsBox.Line.Slot = switch line.state {
            case .pending: .todo
            case .skipped, .succeeded: .done
            case .running: .running
            case .failed: .failed
            }
            let output: String? = switch outcome {
            case .updated where outputShown, .notConfirmed where outputShown: line.output
            case .failed: line.state == .failed ? line.output : nil
            case .running, .updated, .notConfirmed: nil
            }
            return SetupCardModel.CommandsBox.Line(command: line.command, slot: slot, tag: nil, output: output)
        }
        commands = SetupCardModel.CommandsBox(lines: lines, footer: footer, inApp: [])
    }

    /// The update's lines and, where the probe found it, the program they start
    /// with: the CLI's own, or without it those of the path without it.
    private static func updateCommands(_ status: IntegrationStatus) -> (lines: [String], program: (name: String, path: String)?) {
        if let alternative = status.withoutCLI {
            let path: String? = if case .found(let path, _) = alternative.program { path } else { nil }
            return (alternative.commands.update, path.map { (alternative.commands.program, $0) })
        }
        let path: String? = if case .found(let path, _) = status.cli { path } else { nil }
        return (status.commands.update, path.map { (status.cliName, $0) })
    }

    /// The installed version as the probe reports it, if it reads as one.
    static func installedVersion(_ status: IntegrationStatus) -> SubspaceVersion? {
        switch status.plugin {
        case .enabled(let version), .disabled(let version): version.flatMap(SubspaceVersion.init)
        case .notInstalled, .unknown: nil
        }
    }

    private static func youHave(_ version: SubspaceVersion) -> LocalizedStringResource {
        .kit("You have %@", defaultValue: "You have \(version.description)")
    }

    /// The consent sentence by line count, then what to do after the update:
    /// the adapter's hint, or restarting the sessions that run the old plugin.
    private static func intro(lineCount: Int, hint: LocalizedStringResource?) -> LocalizedStringResource {
        let after = hint ?? .kit("Restart running sessions afterwards.", defaultValue: "Restart running sessions afterwards.")
        return switch lineCount {
        case 1: .kit("Runs this command in your login shell. %@", defaultValue: "Runs this command in your login shell. \(after)")
        case 2: .kit("Runs both commands in your login shell. %@", defaultValue: "Runs both commands in your login shell. \(after)")
        default: .kit("Runs these %lld commands in your login shell. %@", defaultValue: "Runs these \(lineCount) commands in your login shell. \(after)")
        }
    }

    /// The time resolves in the text's locale when it is shown.
    private static func updated(at date: Date, version: SubspaceVersion, hint: LocalizedStringResource?, timeZone: TimeZone) -> LocalizedStringResource {
        let time = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)
        if let hint {
            return .kit("Updated at %@. %@", defaultValue: "Updated at \(date, format: time). \(hint)")
        }
        return .kit(
            "Updated at %@. Restart running sessions to use %@.",
            defaultValue: "Updated at \(date, format: time). Restart running sessions to use \(version.description)."
        )
    }

    private static func updateButton(lines: [String]) -> SetupCardModel.CommandsBox.Footer.Button {
        // "runs A, B, then C": every line but the last, then the last.
        let last = lines.last ?? ""
        let before = lines.dropLast().joined(separator: ", ")
        return SetupCardModel.CommandsBox.Footer.Button(
            kind: .update,
            title: update,
            isEnabled: true,
            accessibilityLabel: before.isEmpty
                ? .kit("Update subspace: runs %@", defaultValue: "Update subspace: runs \(last)")
                : .kit("Update subspace: runs %@, then %@", defaultValue: "Update subspace: runs \(before), then \(last)")
        )
    }

    private static func tryAgainButton(lines: [String]) -> SetupCardModel.CommandsBox.Footer.Button {
        let last = lines.last ?? ""
        let before = lines.dropLast().joined(separator: ", ")
        return SetupCardModel.CommandsBox.Footer.Button(
            kind: .tryAgain,
            title: .kit("Try Again", defaultValue: "Try Again"),
            isEnabled: true,
            accessibilityLabel: before.isEmpty
                ? .kit("Try again: runs %@", defaultValue: "Try again: runs \(last)")
                : .kit("Try again: runs %@, then %@", defaultValue: "Try again: runs \(before), then \(last)")
        )
    }

    private static let update: LocalizedStringResource = .kit("Update", defaultValue: "Update")
}
