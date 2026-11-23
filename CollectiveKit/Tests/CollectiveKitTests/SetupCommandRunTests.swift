import Foundation
import Synchronization
import Testing
@testable import CollectiveKit

// MARK: - Helpers

/// Answers with the queued results in call order (success once they run
/// out) and records every call. With `held`, each call waits until the test
/// releases it, so a test can look at the run while a command is running.
private final class FakeRunner: CommandRunner, Sendable {
    struct Call: Sendable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]
        var timeout: Duration
    }

    private struct State {
        var results: [CommandResult]
        var calls: [Call] = []
        var waiting: CheckedContinuation<Void, Never>?
    }

    private let state: Mutex<State>
    private let held: Bool
    /// Yields once per call, after the call is recorded and, if held, waiting.
    let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation

    init(_ results: [CommandResult] = [], held: Bool = false) {
        state = Mutex(State(results: results))
        self.held = held
        (started, startedContinuation) = AsyncStream.makeStream()
    }

    var calls: [Call] { state.withLock { $0.calls } }

    /// Lets the waiting call return.
    func release() {
        state.withLock { $0.waiting?.resume(); $0.waiting = nil }
    }

    func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async -> CommandResult {
        let result = state.withLock { state in
            state.calls.append(Call(executable: executable.path, arguments: arguments, environment: environment, timeout: timeout))
            return state.results.isEmpty ? CommandResult(exitCode: 0) : state.results.removeFirst()
        }
        if held {
            await withCheckedContinuation { continuation in
                state.withLock { $0.waiting = continuation }
                startedContinuation.yield()
            }
        } else {
            startedContinuation.yield()
        }
        return result
    }
}

private let install = [
    "tool plugin marketplace add example/marketplace",
    "tool plugin install example@example --scope user",
]

@MainActor
private func makeRun(
    _ runner: FakeRunner,
    lines: [String] = install,
    skipping: Set<Int> = [],
    cliPath: String = "/opt/homebrew/bin/tool",
    environment: [String: String] = ["SHELL": "/bin/bash", "PATH": "/usr/bin"],
    now: @escaping @MainActor () -> Date = { Date(timeIntervalSince1970: 0) },
    onSuccess: @escaping @MainActor () -> Void = {}
) -> SetupCommandRun {
    SetupCommandRun(kind: .install, lines: lines, skipping: skipping, cliName: "tool", cliPath: cliPath, environment: environment,
                    runner: runner, now: now, onSuccess: onSuccess)
}

// MARK: - Commands

@Suite @MainActor struct SetupCommandRunCommandTests {
    @Test func linesRunInOrderInTheLoginShellWithTheFoundCLI() async {
        let runner = FakeRunner()
        let run = makeRun(runner)
        await run.start()?.value
        #expect(runner.calls.map(\.executable) == ["/bin/bash", "/bin/bash"])
        #expect(runner.calls.map(\.arguments) == [
            ["-l", "-c", "'/opt/homebrew/bin/tool' plugin marketplace add example/marketplace"],
            ["-l", "-c", "'/opt/homebrew/bin/tool' plugin install example@example --scope user"],
        ])
    }

    @Test(arguments: [nil, ""])
    func withoutAShellTheLoginShellIsZsh(shell: String?) async {
        let runner = FakeRunner()
        let run = makeRun(runner, lines: [install[0]], environment: shell.map { ["SHELL": $0] } ?? [:])
        await run.start()?.value
        #expect(runner.calls.map(\.executable) == ["/bin/zsh"])
    }

    @Test(arguments: [
        ("/Users/user/My Tools/tool", "'/Users/user/My Tools/tool' plugin marketplace add example/marketplace"),
        ("/Users/user/o'brien/bin/tool", #"'/Users/user/o'\''brien/bin/tool' plugin marketplace add example/marketplace"#),
    ])
    func theCLIPathIsSingleQuoted(path: String, script: String) async {
        let runner = FakeRunner()
        let run = makeRun(runner, lines: [install[0]], cliPath: path)
        await run.start()?.value
        #expect(runner.calls.map(\.arguments) == [["-l", "-c", script]])
    }

    /// The probe found the CLI in this environment; a Homebrew install may need `node` next to it.
    @Test func theEnvironmentIsTheOneTheProbesRunTheCLIIn() async {
        let runner = FakeRunner()
        let base = ["SHELL": "/bin/bash", "PATH": "/usr/bin", "HOME": "/Users/user"]
        let path = "/Users/user/.local/bin/tool"
        let run = makeRun(runner, lines: [install[0]], cliPath: path, environment: base)
        await run.start()?.value
        let expected = [
            "SHELL": "/bin/bash", "HOME": "/Users/user",
            "PATH": "/Users/user/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/bin",
        ]
        let probe = CLILocator(cliName: "tool", runner: runner, isExecutable: { _ in false }, environment: base,
                               home: URL(fileURLWithPath: "/Users/user"))
        #expect(runner.calls.map(\.environment) == [expected])
        #expect(probe.environment(forCLIAt: URL(fileURLWithPath: path)) == expected)
    }

    /// Installs clone from GitHub, which takes longer than the probes' few seconds.
    @Test func eachCommandMayTakeTwoMinutes() async {
        let runner = FakeRunner()
        let run = makeRun(runner)
        await run.start()?.value
        #expect(runner.calls.map(\.timeout) == [.seconds(120), .seconds(120)])
        #expect(SetupCommandRun.commandTimeout == .seconds(120))
    }
}

/// Every terminal line the adapters offer starts with their CLI, so the run can put its path in front.
@Suite struct SetupCommandRunAdapterLineTests {
    @Test(arguments: [
        (ClaudeCodeIntegrationProbe.cliName, ClaudeCodeSubspace.commands),
        (CodexIntegrationProbe.cliName, CodexSubspace.commands),
    ])
    func adapterLinesStartWithTheirCLI(cliName: String, commands: SetupCommands) {
        #expect(!commands.update.isEmpty)
        for line in commands.install + commands.enable + commands.update {
            #expect(line.hasPrefix(cliName + " "), "\(line)")
        }
    }

    @Test func aLineForAnotherProgramIsAProgrammerError() async {
        await #expect(processExitsWith: .failure) {
            await MainActor.run {
                _ = SetupCommandRun(kind: .install, lines: ["git clone example"], cliName: "tool", cliPath: "/usr/local/bin/tool",
                                    environment: [:], runner: ProcessCommandRunner(), onSuccess: {})
            }
        }
    }
}

// MARK: - Order

@Suite @MainActor struct SetupCommandRunOrderTests {
    /// The marketplace is already added: only the install runs.
    @Test func aSatisfiedLineIsSkippedAndNeverRun() async {
        let runner = FakeRunner()
        let run = makeRun(runner, skipping: [0])
        #expect(run.lines.map(\.state) == [.skipped, .pending])
        await run.start()?.value
        #expect(runner.calls.map { $0.arguments.last } == ["'/opt/homebrew/bin/tool' plugin install example@example --scope user"])
        #expect(run.lines.map(\.state) == [.skipped, .succeeded])
        #expect(run.lines.map(\.command) == install)
        #expect(run.lines[0].output == nil)
    }

    @Test func withEveryLineSatisfiedTheRunSucceedsAtOnce() async {
        let runner = FakeRunner()
        var completions = 0
        let run = makeRun(runner, skipping: [0, 1], onSuccess: { completions += 1 })
        run.start()
        #expect(run.phase == .succeeded(at: Date(timeIntervalSince1970: 0)))
        #expect(runner.calls.isEmpty)
        #expect(completions == 1)
    }

    @Test func aFailureInTheLastLineKeepsTheEarlierSuccess() async {
        let runner = FakeRunner([
            CommandResult(exitCode: 0, stdout: "Adding marketplace…\nAdded.\n"),
            CommandResult(exitCode: 1, stderr: "Plugin not found\n\n"),
        ])
        var completions = 0
        let run = makeRun(runner, onSuccess: { completions += 1 })
        await run.start()?.value
        #expect(run.lines.map(\.state) == [.succeeded, .failed])
        #expect(run.lines.map(\.output) == [
            "$ tool plugin marketplace add example/marketplace\nAdding marketplace…\nAdded.",
            "$ tool plugin install example@example --scope user\nPlugin not found",
        ])
        #expect(run.phase == .failed(line: 1))
        #expect(completions == 0)
    }

    @Test func aFailureInTheFirstLineStopsTheRun() async {
        let runner = FakeRunner([CommandResult(exitCode: 2)])
        let run = makeRun(runner)
        await run.start()?.value
        #expect(runner.calls.count == 1)
        #expect(run.lines.map(\.state) == [.failed, .pending])
        #expect(run.lines.map(\.output) == ["$ tool plugin marketplace add example/marketplace", nil])
        #expect(run.phase == .failed(line: 0))
    }

    /// `ProcessCommandRunner` reports a command that could not start as exit code -1 with the error in stderr.
    @Test func aCommandThatCouldNotStartFails() async {
        let runner = FakeRunner([CommandResult(exitCode: -1, stderr: "The file “bash” doesn’t exist.")])
        let run = makeRun(runner, lines: [install[0]])
        await run.start()?.value
        #expect(run.lines.map(\.state) == [.failed])
        #expect(run.lines[0].output == "$ tool plugin marketplace add example/marketplace\nThe file “bash” doesn’t exist.")
    }

    @Test func stdoutComesBeforeStderr() async {
        let runner = FakeRunner([CommandResult(exitCode: 0, stdout: "out\n", stderr: "warning: slow network\n")])
        let run = makeRun(runner, lines: [install[0]])
        await run.start()?.value
        #expect(run.lines[0].output == "$ tool plugin marketplace add example/marketplace\nout\nwarning: slow network")
    }

    @Test func aTimeoutFailsAndSaysSo() async {
        let runner = FakeRunner([CommandResult(exitCode: 15, stdout: "Cloning…\n", timedOut: true)])
        let run = makeRun(runner, lines: [install[0]])
        await run.start()?.value
        #expect(run.lines.map(\.state) == [.failed])
        #expect(run.lines[0].output == "$ tool plugin marketplace add example/marketplace\nCloning…\nTimed out after 120 s.")
        #expect(run.phase == .failed(line: 0))
    }
}

// MARK: - Start, retry, finish

@Suite @MainActor struct SetupCommandRunLifecycleTests {
    @Test func nothingRunsUntilStarted() {
        let runner = FakeRunner()
        let run = makeRun(runner)
        #expect(run.phase == .idle)
        #expect(run.lines.map(\.state) == [.pending, .pending])
        #expect(runner.calls.isEmpty)
    }

    @Test func successRecordsTheTimeAndCallsBackOnce() async {
        let finished = Date(timeIntervalSince1970: 1_000_000)
        var completions = 0
        let run = makeRun(FakeRunner(), now: { finished }, onSuccess: { completions += 1 })
        await run.start()?.value
        #expect(run.phase == .succeeded(at: finished))
        #expect(run.lines.map(\.state) == [.succeeded, .succeeded])
        #expect(completions == 1)
        #expect(run.start() == nil)
        #expect(run.retry() == nil)
        #expect(completions == 1)
    }

    @Test func tryAgainRestartsAtTheFailedLine() async {
        let runner = FakeRunner([
            CommandResult(exitCode: 0, stdout: "Added."),
            CommandResult(exitCode: 1, stderr: "network down"),
            CommandResult(exitCode: 0, stdout: "Installed."),
        ])
        let finished = Date(timeIntervalSince1970: 2_000_000)
        var completions = 0
        let run = makeRun(runner, now: { finished }, onSuccess: { completions += 1 })
        await run.start()?.value
        #expect(run.phase == .failed(line: 1))

        await run.retry()?.value
        #expect(runner.calls.map { $0.arguments.last } == [
            "'/opt/homebrew/bin/tool' plugin marketplace add example/marketplace",
            "'/opt/homebrew/bin/tool' plugin install example@example --scope user",
            "'/opt/homebrew/bin/tool' plugin install example@example --scope user",
        ])
        #expect(run.lines.map(\.state) == [.succeeded, .succeeded])
        #expect(run.lines[1].output == "$ tool plugin install example@example --scope user\nInstalled.")
        #expect(run.phase == .succeeded(at: finished))
        #expect(completions == 1)
    }

    /// An update whose commands all exited 0 but the tool kept the old version.
    @Test func runAgainAfterASuccessRunsEveryLineAgainAndCallsBackAgain() async {
        let runner = FakeRunner([
            CommandResult(exitCode: 0, stdout: "Added."), CommandResult(exitCode: 0, stdout: "Installed."),
            CommandResult(exitCode: 0), CommandResult(exitCode: 0, stdout: "Installed again."),
        ])
        var completions = 0
        let run = makeRun(runner, skipping: [], onSuccess: { completions += 1 })
        #expect(run.runAgain() == nil)
        await run.start()?.value
        await run.runAgain()?.value
        #expect(runner.calls.count == 4)
        #expect(run.lines.map(\.state) == [.succeeded, .succeeded])
        #expect(run.lines.map(\.output) == [
            "$ tool plugin marketplace add example/marketplace", "$ tool plugin install example@example --scope user\nInstalled again.",
        ])
        #expect(completions == 2)
    }

    @Test func runAgainSkipsTheSkippedLines() async {
        let runner = FakeRunner()
        let run = makeRun(runner, skipping: [0])
        await run.start()?.value
        await run.runAgain()?.value
        #expect(runner.calls.count == 2)
        #expect(run.lines.map(\.state) == [.skipped, .succeeded])
    }

    @Test func tryAgainBeforeAFailureDoesNothing() {
        let runner = FakeRunner()
        let run = makeRun(runner)
        #expect(run.retry() == nil)
        #expect(run.phase == .idle)
    }

    @Test func whileRunningThePhaseNamesTheLineAndStartingAgainDoesNothing() async {
        let runner = FakeRunner(held: true)
        var started = runner.started.makeAsyncIterator()
        let run = makeRun(runner, skipping: [0])
        let task = run.start()
        #expect(run.phase == .running(line: 1))
        await started.next()
        #expect(run.lines.map(\.state) == [.skipped, .running])
        #expect(run.start() == nil)
        #expect(run.retry() == nil)
        #expect(runner.calls.count == 1)

        runner.release()
        await task?.value
        #expect(runner.calls.count == 1)
        #expect(run.lines.map(\.state) == [.skipped, .succeeded])
    }
}
