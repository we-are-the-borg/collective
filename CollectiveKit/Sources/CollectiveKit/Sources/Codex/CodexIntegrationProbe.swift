import Foundation
import SubspaceKit

/// Asks Codex whether subspace is installed and enabled (subspace contract §11).
/// Read-only: it runs `codex --version`, `codex plugin list --json` and
/// `codex plugin marketplace list --json` and never installs or enables anything.
///
/// There is no file fallback: if the CLI is missing or its list fails, the
/// plugin state is unknown.
public struct CodexIntegrationProbe: IntegrationProbe {
    public let source: SourceID
    public var commands: SetupCommands { CodexSubspace.commands }

    static let candidateDirectories = CLILocator.candidateDirectories
    static let cliName = "codex"

    private let runner: any CommandRunner
    private let isExecutable: @Sendable (String) -> Bool
    private let environment: [String: String]
    private let home: URL
    private let spoolRoot: URL

    public init(
        runner: any CommandRunner = ProcessCommandRunner(),
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        chosenRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let adapter = CodexAdapter()
        self.source = adapter.source
        self.runner = runner
        self.isExecutable = isExecutable
        self.environment = environment
        self.home = home
        self.spoolRoot = SubspaceRoot.resolve(adapter: adapter, chosen: chosenRoot, environment: environment, home: home)
    }

    private var locator: CLILocator {
        CLILocator(cliName: Self.cliName, runner: runner, isExecutable: isExecutable, environment: environment, home: home)
    }

    public func check() async -> IntegrationStatus {
        var cli = IntegrationStatus.CLI.notFound
        var plugin: IntegrationStatus.Plugin?
        var marketplaceAdded: Bool?
        let locator = locator
        if let path = await locator.locate() {
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
            toolName: "Codex",
            cliName: Self.cliName,
            cli: cli,
            plugin: plugin ?? .unknown,
            marketplaceAdded: marketplaceAdded,
            lastSessionStartAt: lastSessionStart(),
            commands: commands,
            searchedLocations: Self.candidateDirectories
        )
    }

    // MARK: Reading the answers

    /// `codex-cli 0.160.1` → `0.160.1`. Only stdout is passed in: Codex prints
    /// warnings to stderr.
    static func version(fromVersionOutput output: String) -> String? {
        output.split(whereSeparator: \.isNewline).first
            .flatMap { $0.split(whereSeparator: \.isWhitespace).last }
            .map(String.init)
    }

    private struct List: Decodable {
        struct Entry: Decodable {
            var pluginId: String
            var marketplaceName: String?
            var installed: Bool?
            var enabled: Bool?
            var version: String?
        }
        var installed: [Entry]
    }

    /// The state `codex plugin list --json` reports; nil if the output is not that object.
    static func pluginState(fromList data: Data) -> IntegrationStatus.Plugin? {
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { return nil }
        guard let entry = list.installed.first(where: {
            $0.pluginId == CodexSubspace.pluginID && $0.marketplaceName == CodexSubspace.marketplaceName
        }), entry.installed == true else { return .notInstalled }
        return entry.enabled == true ? .enabled(version: entry.version) : .disabled(version: entry.version)
    }

    private struct MarketplaceList: Decodable {
        struct Marketplace: Decodable {
            struct Source: Decodable {
                var sourceType: String?
                var source: String?
            }
            var name: String
            var marketplaceSource: Source?
        }
        var marketplaces: [Marketplace]
    }

    /// Whether `codex plugin marketplace list --json` has the subspace marketplace;
    /// nil if the output is not that object. Either key counts: the name is what
    /// `codex plugin add subspace@subspace` resolves against, and the git source is
    /// what the add line adds. The capture of 0.166.0 carries both on one entry
    /// (`"name": "subspace"`, source `https://github.com/we-are-the-borg/subspace-codex.git`).
    static func marketplaceAdded(fromList data: Data) -> Bool? {
        guard let list = try? JSONDecoder().decode(MarketplaceList.self, from: data) else { return nil }
        return list.marketplaces.contains { entry in
            if entry.name == CodexSubspace.marketplaceName { return true }
            guard entry.marketplaceSource?.sourceType == "git", var source = entry.marketplaceSource?.source else { return false }
            if source.hasSuffix(".git") { source.removeLast(4) }
            return source == CodexSubspace.sourceURL?.absoluteString
        }
    }

    // MARK: First session

    /// subspace rewrites `$ROOT/plugin.json` on every session start.
    func lastSessionStart() -> Date? {
        let path = spoolRoot.appendingPathComponent("plugin.json").path
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
