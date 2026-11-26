import Foundation
import SubspaceKit

/// Asks Claude Code whether subspace is installed and enabled (subspace contract
/// §11). Read-only: it runs `claude --version`, `claude plugin list --json` and
/// `claude plugin marketplace list --json` and never installs or enables anything.
///
/// Only a `user` scope install counts: whether a project install is enabled
/// depends on the directory the CLI runs in, which the app has none of. If the
/// CLI is missing or its list fails, the probe falls back to the files Claude
/// Code keeps in its config folder; those are internal and can change.
public struct ClaudeCodeIntegrationProbe: IntegrationProbe {
    public let source: SourceID
    public var commands: SetupCommands { ClaudeCodeSubspace.commands }

    static let candidateDirectories = CLILocator.candidateDirectories
    static let cliName = "claude"

    private let runner: any CommandRunner
    private let isExecutable: @Sendable (String) -> Bool
    private let environment: [String: String]
    private let home: URL
    private let spoolRoots: [URL]

    public init(
        runner: any CommandRunner = ProcessCommandRunner(),
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        chosenRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let adapter = ClaudeCodeAdapter()
        self.source = adapter.source
        self.runner = runner
        self.isExecutable = isExecutable
        self.environment = environment
        self.home = home
        self.spoolRoots = SubspaceRoot.resolveAll(adapter: adapter, chosen: chosenRoot, environment: environment, home: home)
    }

    public func check() async -> IntegrationStatus {
        var cli = IntegrationStatus.CLI.notFound
        var plugin: IntegrationStatus.Plugin?
        var marketplaceAdded: Bool?
        if let path = await locateCLI() {
            let executable = URL(fileURLWithPath: path)
            let cliEnvironment = locator.environment(forCLIAt: executable)
            async let version = runner.run(executable: executable, arguments: ["--version"],
                                           environment: cliEnvironment, timeout: CLILocator.commandTimeout)
            async let list = runner.run(executable: executable, arguments: ["plugin", "list", "--json"],
                                        environment: cliEnvironment, timeout: CLILocator.listTimeout)
            async let marketplaces = runner.run(executable: executable, arguments: ["plugin", "marketplace", "list", "--json"],
                                                environment: cliEnvironment, timeout: CLILocator.listTimeout)
            let (versionResult, listResult, marketplacesResult) = await (version, list, marketplaces)
            cli = .found(path: path, version: versionResult.succeeded ? Self.version(fromVersionOutput: versionResult.stdout) : nil)
            if listResult.succeeded { plugin = Self.pluginState(fromList: Data(listResult.stdout.utf8)) }
            if marketplacesResult.succeeded { marketplaceAdded = Self.marketplaceAdded(fromList: Data(marketplacesResult.stdout.utf8)) }
        }
        return IntegrationStatus(
            source: source,
            toolName: "Claude Code",
            cliName: Self.cliName,
            cli: cli,
            plugin: plugin ?? Self.pluginState(
                configDirectory: ClaudeCodeAdapter.configDirectory(environment: environment, home: home)),
            marketplaceAdded: marketplaceAdded,
            lastSessionStartAt: lastSessionStart(),
            commands: commands,
            searchedLocations: Self.candidateDirectories
        )
    }

    // MARK: Locating the CLI

    private var locator: CLILocator {
        CLILocator(cliName: Self.cliName, runner: runner, isExecutable: isExecutable, environment: environment, home: home)
    }

    func locateCLI() async -> String? { await locator.locate() }

    // MARK: Reading the answers

    /// `2.1.292 (Claude Code)` → `2.1.292`.
    static func version(fromVersionOutput output: String) -> String? {
        output.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    private struct ListEntry: Decodable {
        var id: String
        var version: String?
        var scope: String?
        var enabled: Bool?
    }

    /// The state `claude plugin list --json` reports; nil if the output is not that list.
    static func pluginState(fromList data: Data, pluginID: String = ClaudeCodeSubspace.pluginID) -> IntegrationStatus.Plugin? {
        guard let entries = try? JSONDecoder().decode([ListEntry].self, from: data) else { return nil }
        guard let entry = entries.first(where: { $0.id == pluginID && $0.scope == "user" }) else { return .notInstalled }
        return entry.enabled == true ? .enabled(version: entry.version) : .disabled(version: entry.version)
    }

    private struct Marketplace: Decodable {
        var name: String
        var repo: String?
    }

    /// Whether `claude plugin marketplace list --json` has the subspace marketplace;
    /// nil if the output is not that list. Either key counts: the repo is what the
    /// add line adds, and the name is what the install line resolves
    /// `subspace@subspace` against, so a marketplace with that name from a fork or
    /// local clone makes the add line just as unnecessary. The capture of 2.1.316
    /// carries both on one entry (`"name": "subspace"`, `"repo": "we-are-the-borg/subspace-claude-code"`).
    static func marketplaceAdded(fromList data: Data) -> Bool? {
        guard let entries = try? JSONDecoder().decode([Marketplace].self, from: data) else { return nil }
        return entries.contains { $0.repo == ClaudeCodeSubspace.marketplace || $0.name == ClaudeCodeSubspace.marketplaceName }
    }

    private struct InstalledPlugins: Decodable {
        struct Install: Decodable {
            var scope: String?
            var version: String?
        }
        var plugins: [String: [Install]]
    }

    private struct Settings: Decodable {
        var enabledPlugins: [String: Bool]?
    }

    /// The state from `plugins/installed_plugins.json` and `settings.json` in the config folder.
    static func pluginState(configDirectory: URL, pluginID: String = ClaudeCodeSubspace.pluginID) -> IntegrationStatus.Plugin {
        let installedURL = configDirectory.appendingPathComponent("plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: installedURL),
              let installed = try? JSONDecoder().decode(InstalledPlugins.self, from: data)
        else { return .unknown }
        guard let install = installed.plugins[pluginID]?.first(where: { $0.scope == "user" }) else { return .notInstalled }
        let settingsURL = configDirectory.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(Settings.self, from: data),
              let enabled = settings.enabledPlugins?[pluginID]
        else { return .unknown }
        return enabled ? .enabled(version: install.version) : .disabled(version: install.version)
    }

    // MARK: First session

    /// subspace rewrites `$ROOT/plugin.json` on every session start.
    func lastSessionStart() -> Date? {
        SubspaceRoot.lastSessionStart(in: spoolRoots)
    }
}
