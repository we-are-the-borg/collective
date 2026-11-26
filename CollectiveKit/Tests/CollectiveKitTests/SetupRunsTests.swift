import Foundation
import SubspaceKit
import Synchronization
import Testing
@testable import CollectiveKit

// The setup window's runs, by tool, and how long they live.

// MARK: - Helpers

/// Answers with the queued results in call order (success once they run
/// out) and records each call's arguments. With `held`, each call waits until
/// the test releases it, so a test can act while a command is running.
private final class FakeRunner: CommandRunner, Sendable {
    private struct State {
        var results: [CommandResult]
        var arguments: [[String]] = []
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

    var arguments: [[String]] { state.withLock { $0.arguments } }

    /// Lets the waiting call return.
    func release() {
        state.withLock { $0.waiting?.resume(); $0.waiting = nil }
    }

    func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async -> CommandResult {
        let result = state.withLock { state in
            state.arguments.append(arguments)
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

private let source: SourceID = "claude-code"
private let cliPath = "/Users/user/.local/bin/claude"
private let succeededAt = Date(timeIntervalSince1970: 13_560)

private func claudeCode(_ plugin: IntegrationStatus.Plugin, cli: IntegrationStatus.CLI = .found(path: cliPath, version: "2.1.285")) -> IntegrationStatus {
    IntegrationStatus(
        source: source, toolName: "Claude Code", cliName: "claude", cli: cli, plugin: plugin,
        marketplaceAdded: false, commands: ClaudeCodeSubspace.commands
    )
}

/// The card the window shows for `status` with the tool's current run.
@MainActor
private func card(_ status: IntegrationStatus, _ runs: SetupRuns) -> SetupCardModel {
    SetupCardModel(status, run: runs.snapshots[status.source], now: succeededAt)
}

/// The command each call ran, as the card shows it.
private func commands(_ runner: FakeRunner) -> [String] {
    runner.arguments.map { "claude" + ($0.last ?? "").dropFirst("'\(cliPath)'".count) }
}

@MainActor
private final class Counter {
    var count = 0
}

/// With the window open, as it is whenever a card's button can be pressed.
@MainActor
private func makeRuns(_ runner: FakeRunner, successes: Counter = Counter()) -> SetupRuns {
    let runs = SetupRuns(environment: ["SHELL": "/bin/bash", "PATH": "/usr/bin"], runner: runner,
                         now: { succeededAt }, onSuccess: { successes.count += 1 })
    runs.windowDidAppear(.setup)
    return runs
}

// MARK: - Running

@Suite @MainActor struct SetupRunsRunTests {
    @Test func installRunsTheCardsPlanAndChecksOnceItSucceeded() async throws {
        let runner = FakeRunner()
        let successes = Counter()
        let runs = makeRuns(runner, successes: successes)
        await runs.run(.install, for: claudeCode(.notInstalled))?.value
        #expect(commands(runner) == ClaudeCodeSubspace.commands.install)
        #expect(runs.snapshots[source]?.phase == .succeeded(at: succeededAt))
        #expect(successes.count == 1)
    }

    /// A tool there without its CLI installs through the program of its path without it.
    @Test func installWithoutTheCLIRunsTheAlternativeProgram() async {
        let runner = FakeRunner()
        let runs = makeRuns(runner)
        var status = integration(.notInstalled, cli: .notFound)
        status.commands.withoutCLI = SetupCommands.Alternative(program: "fetch", install: ["fetch clone https://example.com/subspace.git"])
        status.alternative = .found(path: "/usr/bin/fetch", version: nil)
        await runs.run(.install, for: status)?.value
        #expect(runner.arguments == [["-l", "-c", "'/usr/bin/fetch' clone https://example.com/subspace.git"]])
        #expect(runs.snapshots["test-tool"]?.phase == .succeeded(at: succeededAt))
    }

    @Test(arguments: [
        claudeCode(.enabled(version: "0.4.0")),
        claudeCode(.notInstalled, cli: .notFound),
    ])
    func nothingRunsWithoutAPlan(status: IntegrationStatus) async {
        let runner = FakeRunner()
        let runs = makeRuns(runner)
        #expect(runs.run(.install, for: status) == nil)
        #expect(runs.snapshots.isEmpty)
        #expect(runner.arguments.isEmpty)
    }

    /// A button the card no longer offers (a stale tap) runs nothing.
    @Test(arguments: [
        (SetupCardModel.CommandsBox.Footer.Button.Kind.enable, claudeCode(.notInstalled)),
        (.install, claudeCode(.disabled(version: "0.4.0"))),
    ])
    func nothingRunsForAnotherKindThanThePlan(kind: SetupCardModel.CommandsBox.Footer.Button.Kind, status: IntegrationStatus) async {
        let runner = FakeRunner()
        let runs = makeRuns(runner)
        #expect(runs.run(kind, for: status) == nil)
        #expect(runs.snapshots.isEmpty)
        #expect(runner.arguments.isEmpty)
    }

    @Test func aSecondInstallWhileTheRunIsRunningDoesNothing() async throws {
        let runner = FakeRunner(held: true)
        let runs = makeRuns(runner)
        let status = claudeCode(.notInstalled)
        var started = runner.started.makeAsyncIterator()
        let task = try #require(runs.run(.install, for: status))
        await started.next()
        #expect(runs.run(.install, for: status) == nil)
        #expect(runs.snapshots[source]?.phase == .running(line: 0))
        runner.release()
        await started.next()
        runner.release()
        await task.value
        #expect(commands(runner) == ClaudeCodeSubspace.commands.install)
        #expect(runs.snapshots[source]?.phase == .succeeded(at: succeededAt))
    }

    /// The recheck after an install finds the plugin disabled: the card's
    /// Enable replaces the succeeded install.
    @Test func enableAfterASucceededInstallStartsANewRun() async throws {
        let runner = FakeRunner()
        let successes = Counter()
        let runs = makeRuns(runner, successes: successes)
        await runs.run(.install, for: claudeCode(.notInstalled))?.value
        let task = try #require(runs.run(.enable, for: claudeCode(.disabled(version: "0.4.0"))))
        await task.value
        #expect(commands(runner) == ClaudeCodeSubspace.commands.install + ClaudeCodeSubspace.commands.enable)
        #expect(runs.snapshots[source]?.kind == .enable)
        #expect(runs.snapshots[source]?.phase == .succeeded(at: succeededAt))
        #expect(successes.count == 2)
    }

    /// The recheck after a succeeded install still finds the plugin missing:
    /// the card shows no button, so a stale Install tap runs nothing.
    @Test func installDoesNothingWhileTheCardShowsNoButton() async throws {
        let runner = FakeRunner()
        let runs = makeRuns(runner)
        let status = claudeCode(.notInstalled)
        await runs.run(.install, for: status)?.value
        #expect(runs.snapshots[source]?.phase == .succeeded(at: succeededAt))
        #expect(card(status, runs).commands?.footer?.button == nil)
        #expect(runs.run(.install, for: status) == nil)
        #expect(commands(runner) == ClaudeCodeSubspace.commands.install)
    }

    @Test func tryAgainRunsAgainFromTheFailedLine() async throws {
        let runner = FakeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 1, stderr: "Plugin not found")])
        let successes = Counter()
        let runs = makeRuns(runner, successes: successes)
        await runs.run(.install, for: claudeCode(.notInstalled))?.value
        #expect(runs.snapshots[source]?.phase == .failed(line: 1))
        #expect(successes.count == 0)
        await runs.run(.tryAgain, for: claudeCode(.notInstalled))?.value
        let install = ClaudeCodeSubspace.commands.install
        #expect(commands(runner) == install + [install[1]])
        #expect(runs.snapshots[source]?.phase == .succeeded(at: succeededAt))
        #expect(successes.count == 1)
    }

    /// The card SetupRuns builds itself offers Try Again after a failure, so a
    /// caller asking for Install with the bare status starts nothing anew.
    @Test func installAfterAFailedInstallDoesNothingButTryAgainRetries() async throws {
        let runner = FakeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 1, stderr: "Plugin not found")])
        let runs = makeRuns(runner)
        let status = claudeCode(.notInstalled)
        await runs.run(.install, for: status)?.value
        #expect(runs.run(.install, for: status) == nil)
        #expect(commands(runner) == ClaudeCodeSubspace.commands.install)
        #expect(runs.snapshots[source]?.phase == .failed(line: 1))
        let task = try #require(runs.run(.tryAgain, for: status))
        await task.value
        let install = ClaudeCodeSubspace.commands.install
        #expect(commands(runner) == install + [install[1]])
        #expect(runs.snapshots[source]?.phase == .succeeded(at: succeededAt))
    }

    @Test func tryAgainWithoutAFailedRunDoesNothing() async {
        let runner = FakeRunner()
        let runs = makeRuns(runner)
        #expect(runs.run(.tryAgain, for: claudeCode(.notInstalled)) == nil)
        #expect(runs.snapshots.isEmpty)
        #expect(runner.arguments.isEmpty)
    }

    /// The recheck no longer finds the CLI: the card dropped Try Again, so
    /// the failed run stays as it is.
    @Test func tryAgainDoesNothingOnceTheCardNoLongerOffersIt() async throws {
        let runner = FakeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 1, stderr: "Plugin not found")])
        let runs = makeRuns(runner)
        await runs.run(.install, for: claudeCode(.notInstalled))?.value
        let status = claudeCode(.notInstalled, cli: .notFound)
        #expect(card(status, runs).commands?.footer?.button == nil)
        #expect(runs.run(.tryAgain, for: status) == nil)
        #expect(commands(runner) == ClaudeCodeSubspace.commands.install)
        #expect(runs.snapshots[source]?.phase == .failed(line: 1))
    }
}

// MARK: - Output

@Suite @MainActor struct SetupRunsOutputTests {
    @Test func theToggleShowsAndHidesATool() {
        let runs = makeRuns(FakeRunner())
        runs.toggleOutput(for: source)
        #expect(runs.outputShown == [source])
        runs.toggleOutput(for: "codex")
        #expect(runs.outputShown == [source, "codex"])
        runs.toggleOutput(for: source)
        #expect(runs.outputShown == ["codex"])
    }

    @Test func aNewRunHidesTheOutputOfTheOneBefore() async {
        let runs = makeRuns(FakeRunner())
        await runs.run(.install, for: claudeCode(.notInstalled))?.value
        runs.toggleOutput(for: source)
        runs.toggleOutput(for: "codex")
        await runs.run(.enable, for: claudeCode(.disabled(version: "0.4.0")))?.value
        #expect(runs.outputShown == ["codex"])
    }
}

// MARK: - Window

@Suite @MainActor struct SetupRunsWindowTests {
    @Test(arguments: [false, true])
    func closingOrOpeningDropsEndedRunsAndHidesOutput(reopening: Bool) async {
        let runs = makeRuns(FakeRunner())
        await runs.run(.install, for: claudeCode(.notInstalled))?.value
        runs.toggleOutput(for: source)
        if reopening { runs.windowDidAppear(.setup) } else { runs.windowDidDisappear(.setup) }
        #expect(runs.snapshots.isEmpty)
        #expect(runs.outputShown.isEmpty)
    }

    @Test func aRunStillRunningWhenTheWindowClosesKeepsRunningAndShowsOnReopen() async throws {
        let runner = FakeRunner(held: true)
        let successes = Counter()
        let runs = makeRuns(runner, successes: successes)
        var started = runner.started.makeAsyncIterator()
        let task = try #require(runs.run(.install, for: claudeCode(.notInstalled)))
        await started.next()
        runs.windowDidDisappear(.setup)
        #expect(runs.snapshots[source]?.phase == .running(line: 0))
        runs.windowDidAppear(.setup)
        #expect(runs.snapshots[source]?.phase == .running(line: 0))
        runner.release()
        await started.next()
        runner.release()
        await task.value
        #expect(runs.snapshots[source]?.phase == .succeeded(at: succeededAt))
        #expect(successes.count == 1)
    }

    @Test func aRunThatEndedWhileTheWindowWasClosedIsGoneOnReopen() async throws {
        let runner = FakeRunner(held: true)
        let runs = makeRuns(runner)
        var started = runner.started.makeAsyncIterator()
        let task = try #require(runs.run(.install, for: claudeCode(.notInstalled)))
        await started.next()
        runs.windowDidDisappear(.setup)
        runner.release()
        await started.next()
        runner.release()
        await task.value
        runs.windowDidAppear(.setup)
        #expect(runs.snapshots.isEmpty)
    }

    /// The window's first frame reads the runs before `windowDidAppear(.setup)`.
    @Test func aRunThatEndedWhileTheWindowWasClosedIsNotShownBeforeTheWindowAppears() async throws {
        let runner = FakeRunner(held: true)
        let runs = makeRuns(runner)
        var started = runner.started.makeAsyncIterator()
        let task = try #require(runs.run(.install, for: claudeCode(.notInstalled)))
        await started.next()
        runs.windowDidDisappear(.setup)
        runner.release()
        await started.next()
        runner.release()
        await task.value
        #expect(runs.snapshots.isEmpty)
    }
}

// MARK: - Update

private let updateLines = ClaudeCodeSubspace.commands.update
private let v1_0_1 = SubspaceVersion(major: 1, minor: 0, patch: 1)
private let v1_3_0 = SubspaceVersion(major: 1, minor: 3, patch: 0)
private let available = UpdateAvailability.available(installed: v1_0_1, latest: v1_3_0)

/// The update group the settings pane shows for `status` with the source's current update run.
@MainActor
private func group(_ status: IntegrationStatus, _ availability: UpdateAvailability, _ runs: SetupRuns,
                   checkedAt: Date? = nil) -> SourceUpdateModel? {
    SourceUpdateModel(status, checkedAt: checkedAt, availability: availability, run: runs.updateSnapshots[status.source],
                      outputShown: runs.outputShown.contains(status.source), checksForUpdates: true, now: succeededAt)
}

@Suite @MainActor struct SetupRunsUpdateTests {
    @Test func updateRunsTheAdapterLinesAndChecksOnceItSucceeded() async throws {
        let runner = FakeRunner()
        let successes = Counter()
        let runs = makeRuns(runner, successes: successes)
        let task = try #require(runs.runUpdate(.update, for: claudeCode(.enabled(version: "1.0.1")), checkedAt: nil, availability: available, checksForUpdates: true))
        await task.value
        #expect(commands(runner) == updateLines)
        #expect(runs.updateSnapshots[source]?.kind == .update(from: v1_0_1, to: v1_3_0))
        #expect(runs.updateSnapshots[source]?.phase == .succeeded(at: succeededAt))
        #expect(successes.count == 1)
    }

    /// The recheck after the run reports the new version and nothing to update.
    @Test func aSucceededUpdateShowsUpdatedAfterTheRecheck() async {
        let runs = makeRuns(FakeRunner())
        await runs.runUpdate(.update, for: claudeCode(.enabled(version: "1.0.1")), checkedAt: nil, availability: available, checksForUpdates: true)?.value
        let rechecked = group(claudeCode(.enabled(version: "1.3.0")), .upToDate, runs, checkedAt: succeededAt.addingTimeInterval(1))
        #expect(rechecked?.state == .updated)
    }

    /// The setup card sees only its own install and enable runs.
    @Test func anUpdateRunIsNotTheSetupCards() async {
        let runs = makeRuns(FakeRunner())
        await runs.runUpdate(.update, for: claudeCode(.enabled(version: "1.0.1")), checkedAt: nil, availability: available, checksForUpdates: true)?.value
        #expect(runs.snapshots.isEmpty)
        await runs.run(.install, for: claudeCode(.notInstalled))?.value
        #expect(runs.updateSnapshots.isEmpty)
        #expect(runs.snapshots[source]?.kind == .install)
    }

    @Test func tryAgainRunsTheUpdateAgainFromTheFailedLine() async throws {
        let runner = FakeRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 1, stderr: "Network down")])
        let runs = makeRuns(runner)
        let status = claudeCode(.enabled(version: "1.0.1"))
        await runs.runUpdate(.update, for: status, checkedAt: nil, availability: available, checksForUpdates: true)?.value
        #expect(runs.updateSnapshots[source]?.phase == .failed(line: 1))
        // The group offers Try Again now, so a stale Update starts nothing anew.
        #expect(runs.runUpdate(.update, for: status, checkedAt: nil, availability: available, checksForUpdates: true) == nil)
        let task = try #require(runs.runUpdate(.tryAgain, for: status, checkedAt: nil, availability: available, checksForUpdates: true))
        await task.value
        #expect(commands(runner) == updateLines + [updateLines[1]])
        #expect(runs.updateSnapshots[source]?.phase == .succeeded(at: succeededAt))
    }

    /// No line failed, so Try Again runs them all again; Update stays a stale tap.
    @Test func tryAgainAfterAnUnconfirmedUpdateRunsEveryLineAgain() async throws {
        let codexLines = CodexSubspace.commands.update
        let codexPath = "/opt/homebrew/bin/codex"
        let codex = IntegrationStatus(source: "codex", toolName: "Codex", cliName: "codex", cli: .found(path: codexPath, version: "0.160.0"),
                                      plugin: .enabled(version: "1.0.1"), commands: CodexSubspace.commands)
        let runner = FakeRunner()
        let runs = makeRuns(runner)
        await runs.runUpdate(.update, for: codex, checkedAt: nil, availability: available, checksForUpdates: true)?.value
        let probedAt = succeededAt.addingTimeInterval(1)
        #expect(runs.runUpdate(.update, for: codex, checkedAt: probedAt, availability: available, checksForUpdates: true) == nil)
        // Before a probe after the success the group still runs and offers nothing.
        #expect(runs.runUpdate(.tryAgain, for: codex, checkedAt: nil, availability: available, checksForUpdates: true) == nil)
        let task = try #require(runs.runUpdate(.tryAgain, for: codex, checkedAt: probedAt, availability: available, checksForUpdates: true))
        await task.value
        let ran = runner.arguments.map { "codex" + ($0.last ?? "").dropFirst("'\(codexPath)'".count) }
        #expect(ran == codexLines + codexLines)
        #expect(runs.updateSnapshots["codex"]?.phase == .succeeded(at: succeededAt))
        #expect(runs.updateSnapshots["codex"]?.kind == .update(from: v1_0_1, to: v1_3_0))
    }

    /// A button the group doesn't offer enabled (a stale tap) runs nothing.
    @Test(arguments: [
        (SetupCardModel.CommandsBox.Footer.Button.Kind.update, UpdateAvailability.upToDate, true),
        (.update, available, false),
        (.tryAgain, available, true),
        (.install, available, true),
    ])
    func nothingRunsUnlessTheGroupOffersTheButton(kind: SetupCardModel.CommandsBox.Footer.Button.Kind,
                                                  availability: UpdateAvailability, checksForUpdates: Bool) {
        let runner = FakeRunner()
        let runs = makeRuns(runner)
        #expect(runs.runUpdate(kind, for: claudeCode(.enabled(version: "1.0.1")), checkedAt: nil, availability: availability, checksForUpdates: checksForUpdates) == nil)
        #expect(runs.updateSnapshots.isEmpty)
        #expect(runner.arguments.isEmpty)
    }

    @Test func aSecondUpdateWhileTheUpdateIsRunningDoesNothing() async throws {
        let runner = FakeRunner(held: true)
        let runs = makeRuns(runner)
        let status = claudeCode(.enabled(version: "1.0.1"))
        var started = runner.started.makeAsyncIterator()
        let task = try #require(runs.runUpdate(.update, for: status, checkedAt: nil, availability: available, checksForUpdates: true))
        await started.next()
        #expect(group(status, available, runs)?.commands?.footer?.button?.isEnabled == false)
        #expect(runs.runUpdate(.update, for: status, checkedAt: nil, availability: available, checksForUpdates: true) == nil)
        runner.release()
        await started.next()
        runner.release()
        await task.value
        #expect(commands(runner) == updateLines)
    }

    /// The probe rechecks during an install and finds an old plugin: the
    /// update waits until the install is done.
    @Test func aRunningInstallBlocksAnUpdate() async throws {
        let runner = FakeRunner(held: true)
        let runs = makeRuns(runner)
        var started = runner.started.makeAsyncIterator()
        let task = try #require(runs.run(.install, for: claudeCode(.notInstalled)))
        await started.next()
        #expect(runs.runUpdate(.update, for: claudeCode(.enabled(version: "1.0.1")), checkedAt: nil, availability: available, checksForUpdates: true) == nil)
        runner.release()
        await started.next()
        runner.release()
        await task.value
        #expect(commands(runner) == ClaudeCodeSubspace.commands.install)
        #expect(runs.snapshots[source]?.kind == .install)
    }

    @Test func aRunningUpdateBlocksAnEnable() async throws {
        let runner = FakeRunner(held: true)
        let runs = makeRuns(runner)
        var started = runner.started.makeAsyncIterator()
        let task = try #require(runs.runUpdate(.update, for: claudeCode(.disabled(version: "1.0.1")), checkedAt: nil, availability: available, checksForUpdates: true))
        await started.next()
        #expect(runs.run(.enable, for: claudeCode(.disabled(version: "1.0.1"))) == nil)
        runner.release()
        await started.next()
        runner.release()
        await task.value
        #expect(commands(runner) == updateLines)
    }
}

// MARK: - Two windows

@Suite @MainActor struct SetupRunsTwoWindowsTests {
    private func endedUpdate(_ runs: SetupRuns) async {
        await runs.runUpdate(.update, for: claudeCode(.enabled(version: "1.0.1")), checkedAt: nil, availability: available, checksForUpdates: true)?.value
        runs.toggleOutput(for: source)
    }

    @Test func closingOneOfTwoWindowsKeepsTheEndedRun() async {
        let runs = makeRuns(FakeRunner())
        runs.windowDidAppear(.settings)
        await endedUpdate(runs)
        runs.windowDidDisappear(.setup)
        #expect(runs.updateSnapshots[source]?.phase == .succeeded(at: succeededAt))
        #expect(runs.outputShown == [source])
        runs.windowDidDisappear(.settings)
        #expect(runs.updateSnapshots.isEmpty)
        #expect(runs.outputShown.isEmpty)
    }

    /// The settings window opened while the setup window shows the run shares it.
    @Test func openingTheSecondWindowKeepsTheEndedRun() async {
        let runs = makeRuns(FakeRunner())
        await endedUpdate(runs)
        runs.windowDidAppear(.settings)
        #expect(runs.updateSnapshots[source]?.phase == .succeeded(at: succeededAt))
        #expect(runs.outputShown == [source])
    }

    @Test func theSettingsWindowAloneDropsTheEndedRunWhenItCloses() async {
        let runs = SetupRuns(environment: ["SHELL": "/bin/bash", "PATH": "/usr/bin"], runner: FakeRunner(),
                             now: { succeededAt }, onSuccess: {})
        runs.windowDidAppear(.settings)
        await endedUpdate(runs)
        #expect(runs.updateSnapshots[source] != nil)
        runs.windowDidDisappear(.settings)
        #expect(runs.updateSnapshots.isEmpty)
    }
}

// MARK: - Install runs and the settings window

/// The settings window doesn't share install and enable runs.
@Suite @MainActor struct SetupRunsInstallWithSettingsTests {
    @Test func closingTheSetupWindowDropsTheEndedInstallWhileSettingsIsOpen() async {
        let runs = makeRuns(FakeRunner())
        runs.windowDidAppear(.settings)
        await runs.run(.install, for: claudeCode(.notInstalled))?.value
        runs.toggleOutput(for: source)
        runs.windowDidDisappear(.setup)
        #expect(runs.snapshots.isEmpty)
        #expect(runs.outputShown.isEmpty)
        runs.windowDidAppear(.setup)
        #expect(runs.snapshots.isEmpty)
    }

    /// The setup window's first frame reads the runs before `windowDidAppear(.setup)`.
    @Test func anInstallThatEndedWhileOnlySettingsWasOpenIsNotShownBeforeTheSetupWindowAppears() async throws {
        let runner = FakeRunner(held: true)
        let runs = makeRuns(runner)
        runs.windowDidAppear(.settings)
        var started = runner.started.makeAsyncIterator()
        let task = try #require(runs.run(.install, for: claudeCode(.notInstalled)))
        await started.next()
        runs.windowDidDisappear(.setup)
        runner.release()
        await started.next()
        runner.release()
        await task.value
        #expect(runs.snapshots.isEmpty)
    }
}
