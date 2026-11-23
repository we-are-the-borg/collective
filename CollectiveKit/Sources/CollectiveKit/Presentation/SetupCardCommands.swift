import Foundation

/// The card's terminal box around a run of its commands:
/// a slot per line, a footer that says what the button will do or is doing,
/// and the button itself. The session box ("Or type this in a session:")
/// stays copy-only.
extension SetupCardModel {
    /// What the app hands a new `SetupCommandRun` when the button is pressed.
    public struct RunPlan: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case install, enable
            /// Carries the versions it set out from and to, so a run that ended
            /// still names them once the recheck reports the new version.
            case update(from: SubspaceVersion, to: SubspaceVersion)

            var isUpdate: Bool { if case .update = self { true } else { false } }

            /// The card's own step; nil for an update, whose box is `SourceUpdateModel`'s,
            /// so the card's texts and buttons can't be an install's or enable's for one.
            var step: Step? {
                switch self {
                case .install: .install
                case .enable: .enable
                case .update: nil
                }
            }
        }

        enum Step: Sendable, Equatable { case install, enable }
        public let kind: Kind
        public let lines: [String]
        /// The marketplace line, once the tool already knows the marketplace.
        public let skipping: Set<Int>
        public let cliName: String
        /// Where the probe found the CLI; the run uses it in place of the name.
        public let cliPath: String
    }
}

extension SetupCardModel.CommandsBox {
    public struct Line: Sendable, Equatable {
        /// The column in front of a command.
        public enum Slot: Sendable, Equatable {
            /// Its place among the lines the button will run.
            case number(Int)
            case done
            case running
            /// Not run yet, after an earlier line.
            case todo
            case failed
        }

        public let command: String
        /// nil when the card cannot run the lines.
        public let slot: Slot?
        /// After the command, in secondary ink ("Already added").
        public let tag: LocalizedStringResource?
        /// Shown under the command; nil when it is not to be shown.
        public let output: String?
    }

    public struct Footer: Sendable, Equatable {
        /// The Show/Hide Output toggle, offered only after a run succeeded.
        public enum OutputToggle: Sendable, Equatable {
            /// The outputs are shown; the toggle hides them.
            case showing
            /// The outputs are hidden; the toggle shows them.
            case hidden
        }

        public struct Button: Sendable, Equatable {
            public enum Kind: Sendable, Equatable {
                /// Starts a run from the plan.
                case install, enable, update
                /// Runs again from the failed line.
                case tryAgain
            }

            public let kind: Kind
            public let title: LocalizedStringResource
            /// Off while the run is running.
            public let isEnabled: Bool
            /// Names the commands the button runs.
            public let accessibilityLabel: LocalizedStringResource
        }

        /// The link at the end of the footer's text.
        public struct Link: Sendable, Equatable {
            public enum Kind: Sendable, Equatable {
                /// The repository the tool installs subspace from.
                case source
                /// What changed between the installed and the offered version.
                case changes
            }

            public let kind: Kind
            public let url: URL

            public var title: LocalizedStringResource {
                switch kind {
                case .source: .kit("View source on GitHub ↗", defaultValue: "View source on GitHub ↗")
                case .changes: .kit("View changes on GitHub ↗", defaultValue: "View changes on GitHub ↗")
                }
            }
        }

        public let text: LocalizedStringResource
        /// `--danger` ink: the run failed.
        public let isWarning: Bool
        public let link: Link?
        public let outputToggle: OutputToggle?
        public let button: Button?
    }
}

extension SetupCardModel {
    /// Only a CLI the probe found can run, and only the state's own terminal
    /// lines; a waiting or ready tool has nothing left to run.
    static func runPlan(_ status: IntegrationStatus, state: State) -> RunPlan? {
        guard case .found(let path, _) = status.cli else { return nil }
        let commands = status.commands
        let plan: RunPlan? = switch state {
        case .notInstalled:
            RunPlan(
                kind: .install,
                lines: commands.install,
                skipping: status.marketplaceAdded == true
                    ? Set(commands.install.indices.filter { commands.install[$0] == commands.marketplaceLine })
                    : [],
                cliName: status.cliName,
                cliPath: path
            )
        case .disabled:
            RunPlan(kind: .enable, lines: commands.enable, skipping: [], cliName: status.cliName, cliPath: path)
        case .waiting, .ready, .notFound, .checking:
            nil
        }
        return plan?.lines.isEmpty == false ? plan : nil
    }

    /// No box at all when a tool has nothing to type, e.g. no command to enable a plugin.
    /// `run` is one still shown (see `standing(of:plan:state:cliFound:)`), not one that gave way.
    static func commandsBox(
        _ status: IntegrationStatus,
        state: State,
        plan: RunPlan?,
        run: (snapshot: SetupCommandRun.Snapshot, standing: RunStanding, step: RunPlan.Step)?,
        outputShown: Bool,
        timeZone: TimeZone
    ) -> CommandsBox? {
        let commands = status.commands
        let (terminal, inApp): ([String], [String]) = switch state {
        case .notInstalled, .notFound: (commands.install, commands.installInApp)
        case .disabled: (commands.enable, commands.enableInApp)
        case .waiting, .ready, .checking: ([], [])
        }
        if let run {
            return runBox(status, run: run.snapshot, standing: run.standing, step: run.step, inApp: inApp, outputShown: outputShown, timeZone: timeZone)
        }
        guard !terminal.isEmpty || !inApp.isEmpty else { return nil }
        guard let plan, let step = plan.kind.step else {
            let lines = terminal.map { CommandsBox.Line(command: $0, slot: nil, tag: nil, output: nil) }
            return CommandsBox(lines: lines, footer: nil, inApp: inApp)
        }
        var number = 0
        let lines = plan.lines.enumerated().map { index, command in
            guard !plan.skipping.contains(index) else {
                return CommandsBox.Line(command: command, slot: .done, tag: alreadyAdded, output: nil)
            }
            number += 1
            return CommandsBox.Line(command: command, slot: .number(number), tag: nil, output: nil)
        }
        let toRun = plan.lines.enumerated().filter { !plan.skipping.contains($0.offset) }.map(\.element)
        let footer = CommandsBox.Footer(
            text: intro(step, skipping: !plan.skipping.isEmpty, toRun: toRun, toolName: status.toolName),
            isWarning: false,
            link: commands.sourceLink,
            outputToggle: nil,
            button: startButton(step, toRun: toRun, toolName: status.toolName)
        )
        return CommandsBox(lines: lines, footer: footer, inApp: inApp)
    }

    private static let alreadyAdded: LocalizedStringResource = .kit("Already added", defaultValue: "Already added")

    private static func runBox(
        _ status: IntegrationStatus,
        run: SetupCommandRun.Snapshot,
        standing: RunStanding,
        step: RunPlan.Step,
        inApp: [String],
        outputShown: Bool,
        timeZone: TimeZone
    ) -> CommandsBox {
        let commands = status.commands
        // After a success the outputs wait for the toggle; after a failure
        // only the failed line's output shows, and always.
        let lines = run.lines.map { line in
            let slot: CommandsBox.Line.Slot = switch line.state {
            case .pending: .todo
            case .skipped, .succeeded: .done
            case .running: .running
            case .failed: .failed
            }
            let output: String? = switch run.phase {
            case .succeeded where outputShown: line.output
            case .failed: line.state == .failed ? line.output : nil
            case .idle, .running, .succeeded: nil
            }
            return CommandsBox.Line(command: line.command, slot: slot, tag: line.state == .skipped ? alreadyAdded : nil, output: output)
        }
        let footer: CommandsBox.Footer? = switch run.phase {
        case .idle, .running:
            CommandsBox.Footer(
                text: progress(step, command: run.phase.line.map { run.lines[$0].command }, marketplaceLine: commands.marketplaceLine),
                isWarning: false,
                link: commands.sourceLink,
                outputToggle: nil,
                button: CommandsBox.Footer.Button(
                    kind: step == .install ? .install : .enable,
                    title: step == .install ? install : enable,
                    isEnabled: false,
                    accessibilityLabel: step == .install
                        ? .kit("Install, running", defaultValue: "Install, running")
                        : .kit("Enable, running", defaultValue: "Enable, running")
                )
            )
        case .succeeded(let date):
            CommandsBox.Footer(
                text: succeeded(step, at: date, timeZone: timeZone),
                isWarning: false,
                link: commands.sourceLink,
                outputToggle: outputShown ? .showing : .hidden,
                button: nil
            )
        // Enabled after all: the pill and steps say so, and nothing is left to
        // try again, so the box keeps only the lines and the failed output.
        case .failed where standing == .pluginEnabled:
            nil
        case .failed(let line):
            CommandsBox.Footer(
                text: step == .install
                    ? .kit(
                        "Installation failed. subspace is downloaded from GitHub; check your connection, then try again.",
                        defaultValue: "Installation failed. subspace is downloaded from GitHub; check your connection, then try again."
                    )
                    : .kit("Enabling failed. Check the output, then try again.", defaultValue: "Enabling failed. Check the output, then try again."),
                isWarning: true,
                link: commands.sourceLink,
                outputToggle: nil,
                button: CommandsBox.Footer.Button(
                    kind: .tryAgain,
                    title: .kit("Try Again", defaultValue: "Try Again"),
                    isEnabled: true,
                    accessibilityLabel: .kit("Try again: runs %@", defaultValue: "Try again: runs \(run.lines[line].command)")
                )
            )
        }
        // A succeeded run leaves nothing to type; a failed one leaves the way by hand open.
        let succeeded = if case .succeeded = run.phase { true } else { false }
        return CommandsBox(lines: lines, footer: footer, inApp: succeeded ? [] : inApp)
    }

    private static func progress(_ step: RunPlan.Step, command: String?, marketplaceLine: String?) -> LocalizedStringResource {
        if step == .enable {
            return .kit("Enabling subspace…", defaultValue: "Enabling subspace…")
        }
        if command != nil, command == marketplaceLine {
            return .kit("Adding the marketplace…", defaultValue: "Adding the marketplace…")
        }
        return .kit("Installing subspace…", defaultValue: "Installing subspace…")
    }

    /// The time resolves in the text's locale when it is shown.
    private static func succeeded(_ step: RunPlan.Step, at date: Date, timeZone: TimeZone) -> LocalizedStringResource {
        let time = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)
        return switch step {
        case .install: .kit("Installed at %@.", defaultValue: "Installed at \(date, format: time).")
        case .enable: .kit("Enabled at %@.", defaultValue: "Enabled at \(date, format: time).")
        }
    }

    /// What the button is about to do, before it is pressed.
    private static func intro(_ step: RunPlan.Step, skipping: Bool, toRun: [String], toolName: String) -> LocalizedStringResource {
        switch step {
        case .install where skipping:
            .kit(
                "The marketplace is already there. Runs %lld command in your login shell. subspace adds hooks that run in every %@ session.",
                defaultValue: "The marketplace is already there. Runs \(toRun.count) command in your login shell. subspace adds hooks that run in every \(toolName) session."
            )
        case .install where toRun.count == 2:
            .kit(
                "Runs both commands in your login shell. subspace adds hooks that run in every %@ session.",
                defaultValue: "Runs both commands in your login shell. subspace adds hooks that run in every \(toolName) session."
            )
        case .install:
            .kit(
                "Runs %lld command in your login shell. subspace adds hooks that run in every %@ session.",
                defaultValue: "Runs \(toRun.count) command in your login shell. subspace adds hooks that run in every \(toolName) session."
            )
        case .enable where toRun.count == 1:
            .kit("Runs this command in your login shell.", defaultValue: "Runs this command in your login shell.")
        case .enable:
            .kit("Runs %lld command in your login shell.", defaultValue: "Runs \(toRun.count) command in your login shell.")
        }
    }

    private static func startButton(_ step: RunPlan.Step, toRun: [String], toolName: String) -> CommandsBox.Footer.Button {
        // "runs A, B, then C": every line but the last, then the last.
        let last = toRun.last ?? ""
        let before = toRun.dropLast().joined(separator: ", ")
        return switch step {
        case .install:
            CommandsBox.Footer.Button(
                kind: .install,
                title: install,
                isEnabled: true,
                accessibilityLabel: before.isEmpty
                    ? .kit("Install subspace for %@: runs %@", defaultValue: "Install subspace for \(toolName): runs \(last)")
                    : .kit("Install subspace for %@: runs %@, then %@", defaultValue: "Install subspace for \(toolName): runs \(before), then \(last)")
            )
        case .enable:
            CommandsBox.Footer.Button(
                kind: .enable,
                title: enable,
                isEnabled: true,
                accessibilityLabel: before.isEmpty
                    ? .kit("Enable subspace: runs %@", defaultValue: "Enable subspace: runs \(last)")
                    : .kit("Enable subspace: runs %@, then %@", defaultValue: "Enable subspace: runs \(before), then \(last)")
            )
        }
    }

    private static let install: LocalizedStringResource = .kit("Install", defaultValue: "Install")
    private static let enable: LocalizedStringResource = .kit("Enable", defaultValue: "Enable")
}

extension SetupCardModel {
    /// Why a run still shows on the card. Decided once, so the pill and the
    /// box can't disagree about it.
    enum RunStanding: Sendable, Equatable {
        /// It can't be stopped and its progress matters.
        case running
        /// The probe's plan is the run's own step: a failure stays to be tried
        /// again, and a success stays until the recheck it triggered comes
        /// back, rather than flashing the same step's button.
        case ownStep
        /// The recheck finds the plugin enabled: the run's lines stay, the
        /// pill follows the probe, and nothing is left to try again.
        case pluginEnabled
    }

    /// A finished run stays only for its own step or an enabled plugin;
    /// otherwise it gives way and the card is the one without a run: the next
    /// step's box, or the commands to copy once the CLI is gone.
    /// A run made but not started shows nothing of its own yet.
    static func standing(of run: SetupCommandRun.Snapshot, plan: RunPlan?, state: State, cliFound: Bool) -> RunStanding? {
        switch run.phase {
        case .idle: nil
        case .running: .running
        case .succeeded, .failed:
            if let plan, plan.kind == run.kind, plan.lines == run.lines.map(\.command) {
                .ownStep
            } else if cliFound, state.pluginEnabled {
                .pluginEnabled
            } else {
                nil
            }
        }
    }
}

private extension SetupCommands {
    var sourceLink: SetupCardModel.CommandsBox.Footer.Link? {
        sourceURL.map { .init(kind: .source, url: $0) }
    }
}

private extension SetupCommandRun.Phase {
    var line: Int? {
        switch self {
        case .running(let line), .failed(let line): line
        case .idle, .succeeded: nil
        }
    }
}
