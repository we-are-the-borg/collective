import Foundation
import SubspaceKit

/// Asks Antigravity whether subspace is installed and enabled (subspace contract §11).
/// Read-only: it runs `agy --version` and `agy plugin list --json` and never
/// installs or enables anything.
///
/// If the CLI is missing or its list fails, the probe falls back to the files
/// `agy` keeps in `~/.gemini/config/`; those are internal and can change. Not
/// to `plugin_data/`: it can be left over (`agy` 1.5.16 kept it on uninstall,
/// 1.5.17 removes both folders), so a `plugin.json` there only dates the last session.
///
/// Without `agy` but with the desktop app, the setup goes through `git`
/// (`SetupCommands.withoutCLI`), which the probe only locates: `/usr/bin/git`
/// without the Command Line Tools opens an install dialog when run.
public struct AntigravityIntegrationProbe: IntegrationProbe {
    public let source: SourceID
    public var commands: SetupCommands { AntigravitySubspace.commands }

    static let candidateDirectories = CLILocator.candidateDirectories
    static let cliName = "agy"
    static let appBundleIdentifier = "com.google.antigravity"

    private let runner: any CommandRunner
    private let isExecutable: @Sendable (String) -> Bool
    private let environment: [String: String]
    private let home: URL
    private let spoolRoots: [URL]
    private let isAppInstalled: @Sendable (String) -> Bool

    /// `isAppInstalled` answers for a bundle identifier; the kit doesn't import
    /// AppKit, so the default knows no app and the app passes the real lookup.
    public init(
        runner: any CommandRunner = ProcessCommandRunner(),
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        chosenRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isAppInstalled: @escaping @Sendable (String) -> Bool = { _ in false }
    ) {
        let adapter = AntigravityAdapter()
        self.source = adapter.source
        self.runner = runner
        self.isExecutable = isExecutable
        self.environment = environment
        self.home = home
        self.isAppInstalled = isAppInstalled
        self.spoolRoots = SubspaceRoot.resolveAll(adapter: adapter, chosen: chosenRoot, environment: environment, home: home)
    }

    private var locator: CLILocator {
        CLILocator(cliName: Self.cliName, runner: runner, isExecutable: isExecutable, environment: environment, home: home)
    }

    public func check() async -> IntegrationStatus {
        var cli = IntegrationStatus.CLI.notFound
        var plugin: IntegrationStatus.Plugin?
        let locator = locator
        if let path = await locator.locate() {
            let executable = URL(fileURLWithPath: path)
            let cliEnvironment = locator.environment(forCLIAt: executable)
            async let version = runner.run(executable: executable, arguments: ["--version"],
                                           environment: cliEnvironment, timeout: CLILocator.commandTimeout)
            async let list = runner.run(executable: executable, arguments: ["plugin", "list", "--json"],
                                        environment: cliEnvironment, timeout: CLILocator.listTimeout)
            let (versionResult, listResult) = await (version, list)
            cli = .found(path: path, version: versionResult.succeeded ? Self.version(fromVersionOutput: versionResult.stdout) : nil)
            if listResult.succeeded { plugin = Self.pluginState(fromList: Data(listResult.stdout.utf8)) }
        }
        var alternative: IntegrationStatus.CLI?
        if cli == .notFound, let program = commands.withoutCLI?.program, isAppInstalled(Self.appBundleIdentifier) {
            let programLocator = CLILocator(cliName: program, runner: runner, isExecutable: isExecutable,
                                            environment: environment, home: home)
            alternative = await programLocator.locate().map { .found(path: $0, version: nil) } ?? .notFound
        }
        return IntegrationStatus(
            source: source,
            toolName: "Antigravity",
            cliName: Self.cliName,
            cli: cli,
            plugin: plugin ?? Self.pluginState(home: home),
            lastSessionStartAt: SubspaceRoot.lastSessionStart(in: spoolRoots),
            commands: commands,
            searchedLocations: Self.candidateDirectories,
            alternative: alternative
        )
    }

    // MARK: Reading the answers

    /// `1.5.17` → `1.5.17`: the last token of the first line, as for Codex, in
    /// case a later version puts a name in front.
    static func version(fromVersionOutput output: String) -> String? {
        output.split(whereSeparator: \.isNewline).first
            .flatMap { $0.split(whereSeparator: \.isWhitespace).last }
            .map(String.init)
    }

    private struct Entry: Decodable {
        var name: String
        var enabled: Bool?
        var version: String?
    }

    /// The state `agy plugin list --json` reports; nil if the output is not its array.
    /// An uninstalled plugin is simply missing from the array.
    static func pluginState(fromList data: Data) -> IntegrationStatus.Plugin? {
        guard let list = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        guard let entry = list.first(where: { $0.name == AntigravitySubspace.pluginName }) else { return .notInstalled }
        return entry.enabled == true ? .enabled(version: entry.version) : .disabled(version: entry.version)
    }

    struct Manifest: Decodable {
        var name: String
        var version: String?
    }

    /// The manifest `agy plugin install` writes; nil if the data is not one of subspace.
    static func manifest(from data: Data) -> Manifest? {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.name == AntigravitySubspace.pluginName
        else { return nil }
        return manifest
    }

    private struct Config: Decodable {
        struct Plugin: Decodable { var enabled: Bool? }
        /// Only subspace's entry is decoded: another plugin's, however it looks,
        /// must not make the whole file unreadable.
        var subspace: Plugin?

        private enum CodingKeys: String, CodingKey { case plugins }

        private struct PluginName: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.plugins), try !container.decodeNil(forKey: .plugins) else { return }
            let plugins = try container.nestedContainer(keyedBy: PluginName.self, forKey: .plugins)
            let name = PluginName(stringValue: AntigravitySubspace.pluginName)
            if plugins.contains(name) { subspace = try plugins.decode(Plugin.self, forKey: name) }
        }
    }

    /// `plugins.subspace.enabled` of `config.json`, `.some(nil)` without that
    /// entry; nil if the data is not a JSON object or subspace's entry is
    /// malformed (not an object, `enabled` not a bool). The other keys and the
    /// other plugins' entries are not read.
    static func enabled(fromConfig data: Data) -> Bool?? {
        guard let config = try? JSONDecoder().decode(Config.self, from: data) else { return nil }
        return .some(config.subspace?.enabled)
    }

    /// The state from the plugin's manifest and `config.json` in `~/.gemini/config/`.
    /// `agy plugin uninstall` removes the plugin folder; `agy plugin disable` sets
    /// the entry to false, and right after the install there is none while the
    /// CLI lists it enabled, so only false counts as disabled.
    static func pluginState(home: URL) -> IntegrationStatus.Plugin {
        let configDirectory = home.appendingPathComponent(".gemini/config", isDirectory: true)
        let manifestURL = configDirectory
            .appendingPathComponent("plugins/\(AntigravitySubspace.pluginName)/.antigravity-plugin/plugin.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return .notInstalled }
        guard let data = try? Data(contentsOf: manifestURL), let manifest = manifest(from: data) else { return .unknown }
        let configURL = configDirectory.appendingPathComponent("config.json")
        var enabled: Bool? = nil
        if FileManager.default.fileExists(atPath: configURL.path) {
            guard let data = try? Data(contentsOf: configURL), let entry = Self.enabled(fromConfig: data) else { return .unknown }
            enabled = entry
        }
        return enabled == false ? .disabled(version: manifest.version) : .enabled(version: manifest.version)
    }
}
