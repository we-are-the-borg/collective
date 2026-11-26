import Foundation
import Observation

/// Runs one setup card's terminal commands for the user, behind the card's
/// button ("Install", "Enable", "Try Again"). Tool-neutral: the card brings
/// its lines and the program its probe found: the tool's CLI, or the
/// program of the path without it (`SetupCommands.withoutCLI`). Nothing runs before `start()`, and
/// a run outlives the view that started it: the task holds the run until its
/// last command ends, and no command is cancelled.
@MainActor @Observable
public final class SetupCommandRun {
    /// Per command: an install clones from GitHub, which takes far longer than
    /// the probes' few seconds.
    public static let commandTimeout: Duration = .seconds(120)

    public struct Line: Sendable, Equatable {
        public enum State: Sendable, Equatable { case pending, skipped, running, succeeded, failed }
        /// As the card shows it, starting with the program's name.
        public let command: String
        public internal(set) var state: State
        /// What the command left behind, shown verbatim: `$ <command>`, then
        /// stdout, then stderr, each without trailing newlines and on lines of
        /// their own, and a last line if the command timed out. Empty parts
        /// are left out, so a silent command shows only `$ <command>`. `nil`
        /// until the line ran.
        public internal(set) var output: String?

        public init(command: String, state: State, output: String? = nil) {
            self.command = command
            self.state = state
            self.output = output
        }
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case running(line: Int)
        case succeeded(at: Date)
        case failed(line: Int)
    }

    /// Whether the lines install the plugin or enable it; the card words its footer by it.
    public let kind: SetupCardModel.RunPlan.Kind
    public private(set) var lines: [Line]
    public private(set) var phase: Phase = .idle
    private let programName: String
    private let programPath: String
    private let environment: [String: String]
    private let runner: any CommandRunner
    private let now: @MainActor () -> Date
    private let onSuccess: @MainActor () -> Void

    /// - Parameters:
    ///   - kind: Which of the card's buttons started the run.
    ///   - lines: The card's terminal commands, in order. Each starts with
    ///     `programName`; anything else is a programmer error, since the lines are
    ///     the adapters' own constants, and stops the app.
    ///   - skipping: Indices of lines already done (a marketplace already
    ///     added); they are never run.
    ///   - programName: The program every line starts with: the tool's CLI, or
    ///     the program of the path without it.
    ///   - programPath: Where the probe found the program. It stands in for the
    ///     name, so the run uses the program the card reports, whatever the
    ///     login shell's `PATH` finds first.
    ///   - environment: The app's environment; the commands get the one the
    ///     probes run a CLI at `programPath` in.
    ///   - onSuccess: Called once when every line succeeded, so the app checks
    ///     the tools again at once. A failure does not call it: nothing changed
    ///     that a check would show sooner, and the output says what went wrong.
    public init(kind: SetupCardModel.RunPlan.Kind, lines: [String], skipping: Set<Int> = [], programName: String, programPath: String,
                environment: [String: String], runner: any CommandRunner,
                now: @escaping @MainActor () -> Date = { Date() }, onSuccess: @escaping @MainActor () -> Void) {
        // Deliberately a trap: the lines are adapter constants, programmer-controlled
        // and covered by tests (`adapterLinesStartWithTheirCLI`), so a malformed one
        // fails loudly in development rather than running some other command.
        for line in lines {
            precondition(line == programName || line.hasPrefix(programName + " "), "Not a command of \(programName): \(line)")
        }
        self.kind = kind
        self.lines = lines.enumerated().map { index, command in
            Line(command: command, state: skipping.contains(index) ? .skipped : .pending, output: nil)
        }
        self.programName = programName
        self.programPath = programPath
        self.environment = CLILocator.environment(forCLIAt: URL(fileURLWithPath: programPath), base: environment)
        self.runner = runner
        self.now = now
        self.onSuccess = onSuccess
    }

    /// Runs the lines from the first; only from `.idle`.
    /// - Returns: The started run, or `nil` if nothing was started.
    @discardableResult
    public func start() -> Task<Void, Never>? {
        guard phase == .idle else { return nil }
        return run(from: 0)
    }

    /// Runs again from the failed line; the lines before it succeeded and are
    /// not repeated. Only after a failure.
    /// - Returns: The started run, or `nil` if nothing was started.
    @discardableResult
    public func retry() -> Task<Void, Never>? {
        guard case .failed(let line) = phase else { return nil }
        return run(from: line)
    }

    /// Runs every line again from the first, skipped ones still skipped. Only
    /// after a success the tool didn't confirm: an update whose commands all
    /// exited 0 while the tool kept the old version.
    /// - Returns: The started run, or `nil` if nothing was started.
    @discardableResult
    public func runAgain() -> Task<Void, Never>? {
        guard case .succeeded = phase else { return nil }
        for index in lines.indices where lines[index].state != .skipped {
            lines[index].state = .pending
            lines[index].output = nil
        }
        return run(from: 0)
    }

    /// Marks the first line running before the task begins, so a second tap
    /// in between finds the run busy.
    private func run(from first: Int) -> Task<Void, Never> {
        let indices = (first..<lines.count).filter { lines[$0].state != .skipped }
        guard let next = indices.first else {
            finish()
            return Task {}
        }
        markRunning(next)
        let shell = CLILocator.loginShell(in: environment)
        return Task {
            for index in indices {
                markRunning(index)
                // A login shell reads the user's profile, as the terminal the card's commands are meant for does.
                let rest = lines[index].command.dropFirst(programName.count)
                let result = await runner.run(executable: shell,
                                              arguments: ["-l", "-c", ShellQuoting.singleQuoted(programPath) + rest],
                                              environment: environment, timeout: Self.commandTimeout)
                lines[index].output = Self.output(of: lines[index].command, result)
                guard result.succeeded else {
                    lines[index].state = .failed
                    phase = .failed(line: index)
                    return
                }
                lines[index].state = .succeeded
            }
            finish()
        }
    }

    private func markRunning(_ index: Int) {
        lines[index].state = .running
        phase = .running(line: index)
    }

    private func finish() {
        phase = .succeeded(at: now())
        onSuccess()
    }

    /// The format `Line.output` describes. The timeout line is English like
    /// the CLI's own output around it.
    static func output(of command: String, _ result: CommandResult) -> String {
        let timeout = result.timedOut ? "Timed out after \(commandTimeout.components.seconds) s." : ""
        return (["$ \(command)", result.stdout, result.stderr].map(\.trimmingTrailingNewlines) + [timeout])
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

extension SetupCommandRun {
    /// The run as a value, so the card model that shows it stays `Sendable`
    /// and `Equatable`; read on the main actor, it is observed like the run.
    public struct Snapshot: Sendable, Equatable {
        public let kind: SetupCardModel.RunPlan.Kind
        public let lines: [Line]
        public let phase: Phase

        public init(kind: SetupCardModel.RunPlan.Kind, lines: [Line], phase: Phase) {
            self.kind = kind
            self.lines = lines
            self.phase = phase
        }
    }

    public var snapshot: Snapshot { Snapshot(kind: kind, lines: lines, phase: phase) }
}

private extension String {
    var trimmingTrailingNewlines: String {
        var result = Substring(self)
        while result.last?.isNewline == true { result.removeLast() }
        return String(result)
    }
}
