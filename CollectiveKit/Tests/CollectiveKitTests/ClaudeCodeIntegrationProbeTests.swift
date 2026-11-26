import Foundation
import Synchronization
import Testing
@testable import CollectiveKit

// MARK: - Helpers

/// Real outputs of Claude Code 2.1.292 (see the folder's README).
private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures/claude-code/plugin-detection/\(name)"))
}

private func fixtureText(_ name: String) throws -> String {
    String(decoding: try fixture(name), as: UTF8.self)
}

// MARK: - Commands

@Suite struct ClaudeCodeSetupCommandsTests {
    @Test func commandsNameTheMarketplaceAndThePlugin() {
        #expect(ClaudeCodeSubspace.commands == SetupCommands(
            install: [
                "claude plugin marketplace add we-are-the-borg/subspace-claude-code",
                "claude plugin install subspace@subspace --scope user",
            ],
            installInApp: ["/plugin marketplace add we-are-the-borg/subspace-claude-code", "/plugin install subspace@subspace"],
            enable: ["claude plugin enable subspace@subspace"],
            enableInApp: ["/plugin enable subspace@subspace"],
            marketplaceLine: "claude plugin marketplace add we-are-the-borg/subspace-claude-code",
            sourceURL: URL(string: "https://github.com/we-are-the-borg/subspace-claude-code"),
            update: ["claude plugin marketplace update subspace", "claude plugin update subspace@subspace --scope user"],
            release: SubspaceRelease(
                tagsRepository: "we-are-the-borg/subspace-claude-code", tagPrefix: "claude-code-",
                changesRepository: "we-are-the-borg/subspace"
            )
        ))
    }

    /// Restarting sessions is all an update needs, so the general advice stays.
    @Test func anUpdateNeedsNoHintAndRequiresNoMinimumVersion() throws {
        let commands = ClaudeCodeSubspace.commands
        #expect(commands.updateHint == nil)
        #expect(try #require(commands.release).minimumVersion == nil)
    }

    /// The dev repo carries the same tags as the distribution repo; its changelog links this form.
    @Test func theChangesLinkComparesTheTwoTagsInTheDevRepo() throws {
        let release = try #require(ClaudeCodeSubspace.commands.release)
        #expect(release.changesURL(from: "1.0.1", to: "1.3.0")
            == URL(string: "https://github.com/we-are-the-borg/subspace/compare/claude-code-1.0.1...claude-code-1.3.0"))
    }

    @Test func theMarketplaceLineIsPartOfTheInstallAndTheSourceIsOnGitHub() throws {
        let commands = ClaudeCodeSubspace.commands
        #expect(commands.install.contains(try #require(commands.marketplaceLine)))
        #expect(commands.sourceURL?.host() == "github.com")
    }
}

// MARK: - Version

@Suite struct ClaudeCodeVersionTests {
    @Test func versionIsTheFirstTokenOfTheCapturedOutput() throws {
        #expect(ClaudeCodeIntegrationProbe.version(fromVersionOutput: try fixtureText("version.txt")) == "2.1.292")
    }

    @Test func emptyOutputHasNoVersion() {
        #expect(ClaudeCodeIntegrationProbe.version(fromVersionOutput: " \n") == nil)
    }
}

// MARK: - `claude plugin list --json`

@Suite struct ClaudeCodePluginListTests {
    @Test func subspaceInstalledForTheUserAndEnabled() throws {
        #expect(ClaudeCodeIntegrationProbe.pluginState(fromList: try fixture("plugin-list-enabled.json"))
            == .enabled(version: "0.11.0"))
    }

    @Test func aDisabledUserEntryIsDisabled() throws {
        let state = ClaudeCodeIntegrationProbe.pluginState(
            fromList: try fixture("plugin-list-enabled.json"), pluginID: "swift-lsp@claude-plugins-official")
        #expect(state == .disabled(version: "1.0.0"))
    }

    @Test func anEmptyListMeansNotInstalled() throws {
        #expect(ClaudeCodeIntegrationProbe.pluginState(fromList: try fixture("plugin-list-empty.json")) == .notInstalled)
    }

    /// The capture lists `mattpocock-skills` once per scope; without its user entry
    /// only the project entry is left, which is enabled there but must not count.
    @Test func aProjectOnlyInstallIsNotInstalled() throws {
        let id = "mattpocock-skills@mattpocock"
        let entries = try #require(try JSONSerialization.jsonObject(with: fixture("plugin-list-enabled.json")) as? [[String: Any]])
        let projectOnly = entries.filter { !($0["id"] as? String == id && $0["scope"] as? String == "user") }
        #expect(projectOnly.contains { $0["id"] as? String == id && $0["scope"] as? String == "project" })
        let data = try JSONSerialization.data(withJSONObject: projectOnly)
        #expect(ClaudeCodeIntegrationProbe.pluginState(fromList: data, pluginID: id) == .notInstalled)
    }

    @Test(arguments: ["", "Error: unknown option '--json'", "{\"id\":\"subspace@subspace\"}"])
    func unparseableOutputHasNoAnswer(output: String) {
        #expect(ClaudeCodeIntegrationProbe.pluginState(fromList: Data(output.utf8)) == nil)
    }
}

// MARK: - `claude plugin marketplace list --json`

@Suite struct ClaudeCodeMarketplaceListTests {
    @Test func theCapturedListHasTheSubspaceMarketplace() throws {
        #expect(ClaudeCodeIntegrationProbe.marketplaceAdded(fromList: try fixture("marketplace-list.json")) == true)
    }

    @Test func anEmptyListHasNoMarketplace() throws {
        #expect(ClaudeCodeIntegrationProbe.marketplaceAdded(fromList: try fixture("marketplace-list-empty.json")) == false)
    }

    /// The captured list without subspace, with subspace under another name, or from another repo.
    @Test(arguments: [
        ("drop", false),
        ("name", true),
        ("repo", true),
    ])
    func eitherTheNameOrTheRepoCounts(change: String, expected: Bool) throws {
        var entries = try #require(try JSONSerialization.jsonObject(with: fixture("marketplace-list.json")) as? [[String: Any]])
        let index = try #require(entries.firstIndex { $0["repo"] as? String == "we-are-the-borg/subspace-claude-code" })
        switch change {
        case "drop": entries.remove(at: index)
        case "name": entries[index]["name"] = "subspace-fork"
        default: entries[index]["repo"] = "someone/subspace-fork"
        }
        let data = try JSONSerialization.data(withJSONObject: entries)
        #expect(ClaudeCodeIntegrationProbe.marketplaceAdded(fromList: data) == expected)
    }

    @Test(arguments: ["", "Error: unknown option '--json'", "{\"name\":\"subspace\"}"])
    func unparseableOutputHasNoAnswer(output: String) {
        #expect(ClaudeCodeIntegrationProbe.marketplaceAdded(fromList: Data(output.utf8)) == nil)
    }
}

/// A fresh, empty directory; removed when the test's `defer` runs.
private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CollectiveKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A Claude Code config folder holding the captured files, `settings.json` possibly changed.
private func configDirectory(installed: Bool = true, settings: ((inout [String: Any]) -> Void)? = { _ in }) throws -> URL {
    let folder = try temporaryDirectory()
    if installed {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("plugins"), withIntermediateDirectories: true)
        try fixture("installed_plugins.json").write(to: folder.appendingPathComponent("plugins/installed_plugins.json"))
    }
    if let settings {
        var object = try #require(try JSONSerialization.jsonObject(with: fixture("settings-enabledPlugins.json")) as? [String: Any])
        settings(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: folder.appendingPathComponent("settings.json"))
    }
    return folder
}

/// Answers by executable name and all arguments, records every call.
private final class FakeRunner: CommandRunner, Sendable {
    typealias Call = (executable: String, arguments: [String], environment: [String: String], timeout: Duration)
    private let answers: [String: CommandResult]
    private let recorded = Mutex<[Call]>([])

    init(_ answers: [String: CommandResult] = [:]) { self.answers = answers }

    var calls: [Call] { recorded.withLock { $0 } }

    func run(executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async -> CommandResult {
        recorded.withLock { $0.append((executable.path, arguments, environment, timeout)) }
        return answers[([executable.lastPathComponent] + arguments).joined(separator: " ")] ?? CommandResult(exitCode: 127)
    }
}

/// For checks of strings only; a probe that reads files gets a temporary home.
private let home = URL(fileURLWithPath: "/Users/user", isDirectory: true)

private func probe(_ runner: FakeRunner, executables: Set<String> = [], environment: [String: String] = [:],
                   home probeHome: URL = home) -> ClaudeCodeIntegrationProbe {
    ClaudeCodeIntegrationProbe(runner: runner, isExecutable: { executables.contains($0) }, environment: environment, home: probeHome)
}

// MARK: - Fallback files

@Suite struct ClaudeCodePluginFilesTests {
    @Test func installedForTheUserAndEnabledInSettings() throws {
        let folder = try configDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ClaudeCodeIntegrationProbe.pluginState(configDirectory: folder) == .enabled(version: "0.11.0"))
    }

    @Test func installedForTheUserAndDisabledInSettings() throws {
        let folder = try configDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ClaudeCodeIntegrationProbe.pluginState(configDirectory: folder, pluginID: "swift-lsp@claude-plugins-official")
            == .disabled(version: "1.0.0"))
    }

    @Test func notListedIsNotInstalled() throws {
        let folder = try configDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ClaudeCodeIntegrationProbe.pluginState(configDirectory: folder, pluginID: "other@nowhere") == .notInstalled)
    }

    @Test func aProjectOnlyInstallIsNotInstalled() throws {
        let folder = try configDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("plugins/installed_plugins.json")
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var plugins = try #require(object["plugins"] as? [String: [[String: Any]]])
        plugins["mattpocock-skills@mattpocock"] = plugins["mattpocock-skills@mattpocock"]?.filter { $0["scope"] as? String != "user" }
        object["plugins"] = plugins
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        #expect(ClaudeCodeIntegrationProbe.pluginState(configDirectory: folder, pluginID: "mattpocock-skills@mattpocock") == .notInstalled)
    }

    @Test func noSettingsKeyIsUnknown() throws {
        let folder = try configDirectory(settings: { settings in
            var enabled = settings["enabledPlugins"] as? [String: Any]
            enabled?["subspace@subspace"] = nil
            settings["enabledPlugins"] = enabled
        })
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ClaudeCodeIntegrationProbe.pluginState(configDirectory: folder) == .unknown)
    }

    @Test func noSettingsFileIsUnknown() throws {
        let folder = try configDirectory(settings: nil)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ClaudeCodeIntegrationProbe.pluginState(configDirectory: folder) == .unknown)
    }

    @Test func noInstalledPluginsFileIsUnknown() throws {
        let folder = try configDirectory(installed: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ClaudeCodeIntegrationProbe.pluginState(configDirectory: folder) == .unknown)
    }
}

// MARK: - Locating the CLI

@Suite struct ClaudeCodeCLILookupTests {
    @Test func theFirstExecutableCandidateWins() async {
        let runner = FakeRunner()
        let found = await probe(runner, executables: ["/Users/user/.local/bin/claude", "/opt/homebrew/bin/claude"]).locateCLI()
        #expect(found == "/Users/user/.local/bin/claude")
        #expect(runner.calls.isEmpty)
    }

    @Test func laterCandidatesAreTriedInOrder() async {
        let found = await probe(FakeRunner(), executables: ["/usr/local/bin/claude", "/opt/homebrew/bin/claude"]).locateCLI()
        #expect(found == "/opt/homebrew/bin/claude")
    }

    @Test func theLoginShellIsAskedOnlyWhenNoCandidateExists() async {
        let runner = FakeRunner(["fish -l -c command -v claude": CommandResult(exitCode: 0, stdout: "/Users/user/bin/claude\n")])
        let found = await probe(runner, executables: ["/Users/user/bin/claude"], environment: ["SHELL": "/usr/local/bin/fish"]).locateCLI()
        #expect(found == "/Users/user/bin/claude")
        #expect(runner.calls.map(\.executable) == ["/usr/local/bin/fish"])
        #expect(runner.calls.first?.arguments == ["-l", "-c", "command -v claude"])
    }

    @Test func withoutSHELLTheLoginShellIsZsh() async {
        let runner = FakeRunner()
        _ = await probe(runner).locateCLI()
        #expect(runner.calls.map(\.executable) == ["/bin/zsh"])
    }

    @Test func profileNoiseAndNonExecutablePathsAreIgnored() async {
        let output = "Welcome back!\nclaude\n/Users/user/old/claude\n/Users/user/bin/claude\n"
        let runner = FakeRunner(["zsh -l -c command -v claude": CommandResult(exitCode: 0, stdout: output)])
        let found = await probe(runner, executables: ["/Users/user/bin/claude"]).locateCLI()
        #expect(found == "/Users/user/bin/claude")
    }

    @Test func aLoginShellThatTimesOutFindsNothing() async {
        let runner = FakeRunner(["zsh -l -c command -v claude": CommandResult(exitCode: 15, stdout: "/Users/user/bin/claude\n", timedOut: true)])
        let found = await probe(runner, executables: ["/Users/user/bin/claude"]).locateCLI()
        #expect(found == nil)
    }
}

// MARK: - The whole check

/// A class for its `deinit`: every test gets an empty home of its own, so a
/// check reads no file of the real one.
@Suite final class ClaudeCodeIntegrationCheckTests {
    private static let cli = "/opt/homebrew/bin/claude"
    private let home: URL

    init() throws { home = try temporaryDirectory() }
    deinit { try? FileManager.default.removeItem(at: home) }

    /// The settings window links the plugin before the first check returns, so the
    /// probe names its commands up front and every check reports the same ones.
    @Test func theCommandsAreKnownBeforeTheCheckAndTheCheckReportsThem() async {
        let probe = probe(FakeRunner(), home: home)
        #expect(probe.commands == ClaudeCodeSubspace.commands)
        #expect(probe.commands.sourceURL == URL(string: "https://github.com/we-are-the-borg/subspace-claude-code"))
        #expect(await probe.check().commands == probe.commands)
    }

    @Test func asksTheCLIForVersionAndPluginList() async throws {
        let runner = FakeRunner([
            "claude --version": CommandResult(exitCode: 0, stdout: try fixtureText("version.txt")),
            "claude plugin list --json": CommandResult(exitCode: 0, stdout: try fixtureText("plugin-list-enabled.json")),
        ])
        let status = await probe(runner, executables: [Self.cli], environment: ["PATH": "/usr/bin"], home: home).check()
        #expect(status.source == "claude-code")
        #expect(status.toolName == "Claude Code")
        #expect(status.cliName == "claude")
        #expect(status.cli == .found(path: Self.cli, version: "2.1.292"))
        #expect(status.plugin == .enabled(version: "0.11.0"))
        #expect(status.commands == ClaudeCodeSubspace.commands)
        #expect(status.commands.update == ["claude plugin marketplace update subspace", "claude plugin update subspace@subspace --scope user"])
        #expect(status.commands.release?.tagsRepository == "we-are-the-borg/subspace-claude-code")
        #expect(status.searchedLocations == ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"])
        #expect(Set(runner.calls.map(\.arguments))
            == [["--version"], ["plugin", "list", "--json"], ["plugin", "marketplace", "list", "--json"]])
        #expect(runner.calls.allSatisfy { $0.executable == Self.cli })
        #expect(runner.calls.allSatisfy {
            $0.environment["PATH"] == "/opt/homebrew/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/bin"
        })
    }

    @Test(arguments: [("marketplace-list.json", true), ("marketplace-list-empty.json", false)])
    func reportsWhetherTheMarketplaceIsAdded(capture: String, added: Bool) async throws {
        let runner = FakeRunner([
            "claude plugin marketplace list --json": CommandResult(exitCode: 0, stdout: try fixtureText(capture)),
        ])
        let status = await probe(runner, executables: [Self.cli], home: home).check()
        #expect(status.marketplaceAdded == added)
    }

    @Test(arguments: [
        CommandResult(exitCode: 1, stderr: "Error"),
        CommandResult(exitCode: 0, stdout: "not json"),
        CommandResult(exitCode: 0, stdout: "[]", timedOut: true),
    ])
    func aFailedMarketplaceListIsUnknown(list: CommandResult) async {
        let runner = FakeRunner(["claude plugin marketplace list --json": list])
        let status = await probe(runner, executables: [Self.cli], home: home).check()
        #expect(status.marketplaceAdded == nil)
    }

    /// The same lists as Codex's, so the same long timeout; the version stays quick.
    @Test func theListsWaitLongerThanTheVersion() async {
        let runner = FakeRunner()
        _ = await probe(runner, executables: [Self.cli], home: home).check()
        let timeouts = Dictionary(uniqueKeysWithValues: runner.calls.map { ($0.arguments, $0.timeout) })
        #expect(timeouts == [
            ["--version"]: .seconds(5),
            ["plugin", "list", "--json"]: .seconds(60),
            ["plugin", "marketplace", "list", "--json"]: .seconds(60),
        ])
    }

    @Test func withoutTheCLITheMarketplaceIsUnknown() async throws {
        let folder = try configDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let status = await probe(FakeRunner(), environment: ["CLAUDE_CONFIG_DIR": folder.path], home: home).check()
        #expect(status.marketplaceAdded == nil)
    }

    @Test(arguments: [
        CommandResult(exitCode: 1, stderr: "Error"),
        CommandResult(exitCode: 0, stdout: "not json"),
        CommandResult(exitCode: 0, stdout: "[]", timedOut: true),
    ])
    func aFailedListFallsBackToTheFiles(list: CommandResult) async throws {
        let folder = try configDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = FakeRunner(["claude --version": CommandResult(exitCode: 1), "claude plugin list --json": list])
        let status = await probe(runner, executables: [Self.cli], environment: ["CLAUDE_CONFIG_DIR": folder.path], home: home).check()
        #expect(status.cli == .found(path: Self.cli, version: nil))
        #expect(status.plugin == .enabled(version: "0.11.0"))
    }

    @Test func withoutTheCLITheFilesAnswer() async throws {
        let folder = try configDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let status = await probe(FakeRunner(), environment: ["CLAUDE_CONFIG_DIR": folder.path], home: home).check()
        #expect(status.cli == .notFound)
        #expect(status.plugin == .enabled(version: "0.11.0"))
    }

    @Test func withoutCLIOrFilesTheStateIsUnknown() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let status = await probe(FakeRunner(), environment: ["CLAUDE_CONFIG_DIR": folder.path], home: home).check()
        #expect(status.plugin == .unknown)
    }

    @Test func theLastSessionStartIsTheMtimeOfPluginJSON() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("plugins/data/subspace-subspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("plugin.json")
        try Data(#"{"v":1,"version":"0.11.0"}"#.utf8).write(to: file)
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: started], ofItemAtPath: file.path)

        let status = await probe(FakeRunner(), environment: ["CLAUDE_CONFIG_DIR": folder.path], home: home).check()
        #expect(status.lastSessionStartAt == started)
    }

    @Test func sharedSUBSPACE_DIRIsWherePluginJSONIsRead() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("plugin.json")
        try Data(#"{"v":1,"version":"0.11.0"}"#.utf8).write(to: file)
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: started], ofItemAtPath: file.path)

        let status = await probe(FakeRunner(), environment: ["SUBSPACE_DIR": folder.path], home: home).check()
        #expect(status.lastSessionStartAt == started)
    }

    @Test func aChosenFolderIsWherePluginJSONIsRead() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("plugin.json")
        try Data(#"{"v":1,"version":"0.11.0"}"#.utf8).write(to: file)
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: started], ofItemAtPath: file.path)

        let probe = ClaudeCodeIntegrationProbe(runner: FakeRunner(), isExecutable: { _ in false }, chosenRoot: folder,
                                               environment: ["SUBSPACE_DIR": "/nowhere"], home: home)
        #expect(await probe.check().lastSessionStartAt == started)
    }

    @Test func noPluginJSONMeansNoSessionYet() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let status = await probe(FakeRunner(), environment: ["CLAUDE_CONFIG_DIR": folder.path], home: home).check()
        #expect(status.lastSessionStartAt == nil)
    }
}
