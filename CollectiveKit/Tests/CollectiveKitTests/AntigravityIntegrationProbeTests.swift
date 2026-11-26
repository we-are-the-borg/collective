import Foundation
import SubspaceKit
import Synchronization
import Testing
@testable import CollectiveKit

/// Real outputs of `agy` 1.5.17 (see the folder's README).
private func fixture(_ name: String) throws -> String {
    try String(decoding: Data(contentsOf: Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures/antigravity/plugin-detection/\(name)")), as: UTF8.self)
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CollectiveKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
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


/// `agy` answering `--version` and `plugin list --json` with the captures.
private func runner(list capture: String) throws -> FakeRunner {
    FakeRunner([
        "agy --version": CommandResult(exitCode: 0, stdout: try fixture("version.txt")),
        "agy plugin list --json": CommandResult(exitCode: 0, stdout: try fixture(capture)),
    ])
}

/// `agy` where the probe looks first, in `home`.
private func agyPath(in home: URL) -> String { home.path + "/.local/bin/agy" }

/// Without `executables`, `agy` is found in `home`.
private func probe(_ runner: FakeRunner, home: URL, executables: Set<String>? = nil, chosenRoot: URL? = nil) -> AntigravityIntegrationProbe {
    let executables = executables ?? [agyPath(in: home)]
    return AntigravityIntegrationProbe(runner: runner, isExecutable: { executables.contains($0) }, chosenRoot: chosenRoot,
                                       environment: [:], home: home)
}

private let installLine = "agy plugin install https://github.com/we-are-the-borg/subspace-antigravity"

@Suite struct AntigravitySetupCommandsTests {
    @Test func commandsInstallFromTheRepoAndEnableByName() {
        #expect(AntigravitySubspace.commands == SetupCommands(
            install: [installLine],
            installInApp: [], enable: ["agy plugin enable subspace"], enableInApp: [],
            marketplaceLine: nil,
            sourceURL: URL(string: "https://github.com/we-are-the-borg/subspace-antigravity"),
            firstSessionHint: .kit(
                "Start a new Antigravity conversation.",
                defaultValue: "Start a new Antigravity conversation."
            ),
            update: [installLine],
            updateHint: .kit(
                "Start a new Antigravity conversation to use the updated subspace.",
                defaultValue: "Start a new Antigravity conversation to use the updated subspace."
            ),
            release: SubspaceRelease(
                tagsRepository: "we-are-the-borg/subspace-antigravity", tagPrefix: "antigravity-",
                minimumVersion: "1.0.0", changesRepository: "we-are-the-borg/subspace"
            )))
    }

    /// Installing again from the repo is the update; there is no marketplace to skip.
    @Test func theUpdateIsTheInstallAndThereIsNoMarketplaceLine() {
        let commands = AntigravitySubspace.commands
        #expect(commands.update == commands.install)
        #expect(commands.marketplaceLine == nil)
        #expect(commands.sourceURL?.host() == "github.com")
    }

    @Test func theChangesLinkComparesTheTwoTagsInTheDevRepo() throws {
        let release = try #require(AntigravitySubspace.commands.release)
        #expect(release.changesURL(from: "1.0.0", to: "1.1.0")
            == URL(string: "https://github.com/we-are-the-borg/subspace/compare/antigravity-1.0.0...antigravity-1.1.0"))
    }
}

@Suite struct AntigravityPluginListTests {
    @Test func enabledWithTheVersionFromTheCapture() throws {
        #expect(AntigravityIntegrationProbe.pluginState(fromList: Data(try fixture("enabled.json").utf8)) == .enabled(version: "1.0.0"))
    }

    @Test func disabledWithTheVersionFromTheCapture() throws {
        #expect(AntigravityIntegrationProbe.pluginState(fromList: Data(try fixture("disabled.json").utf8)) == .disabled(version: "1.0.0"))
    }

    @Test(arguments: ["not-installed.json", "uninstalled.json"])
    func anEmptyListIsNotInstalled(capture: String) throws {
        #expect(AntigravityIntegrationProbe.pluginState(fromList: Data(try fixture(capture).utf8)) == .notInstalled)
    }

    @Test func anotherPluginIsNotSubspace() throws {
        let other = try fixture("enabled.json").replacingOccurrences(of: #""name": "subspace""#, with: #""name": "other""#)
        #expect(AntigravityIntegrationProbe.pluginState(fromList: Data(other.utf8)) == .notInstalled)
    }

    @Test(arguments: ["", "Error: unknown flag: --json", "{}", "{\"installed\":[]}"])
    func unparseableOutputHasNoAnswer(output: String) {
        #expect(AntigravityIntegrationProbe.pluginState(fromList: Data(output.utf8)) == nil)
    }
}

/// A class for its `deinit`: every test gets an empty home of its own, so a
/// check reads no file of the real one.
@Suite final class AntigravityIntegrationCheckTests {
    private let home: URL
    private var cli: String { agyPath(in: home) }

    init() throws { home = try temporaryDirectory() }
    deinit { try? FileManager.default.removeItem(at: home) }

    @Test func theCommandsAreKnownBeforeTheCheckAndTheCheckReportsThem() async {
        let probe = probe(FakeRunner(), home: home)
        #expect(probe.commands == AntigravitySubspace.commands)
        #expect(await probe.check().commands == probe.commands)
    }

    @Test func enabledWithTheCLIVersion() async throws {
        let runner = try runner(list: "enabled.json")
        let status = await probe(runner, home: home).check()
        #expect(status.source == "antigravity")
        #expect(status.toolName == "Antigravity")
        #expect(status.cliName == "agy")
        #expect(status.cli == .found(path: cli, version: "1.5.17"))
        #expect(status.plugin == .enabled(version: "1.0.0"))
        #expect(status.marketplaceAdded == nil)
        #expect(status.searchedLocations == ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"])
        #expect(Set(runner.calls.map(\.arguments)) == [["--version"], ["plugin", "list", "--json"]])
        #expect(runner.calls.allSatisfy { $0.executable == cli })
        let timeouts = Dictionary(uniqueKeysWithValues: runner.calls.map { ($0.arguments, $0.timeout) })
        #expect(timeouts == [["--version"]: .seconds(5), ["plugin", "list", "--json"]: .seconds(60)])
    }

    @Test func disabledOffersTheEnableLine() async throws {
        let status = await probe(try runner(list: "disabled.json"), home: home).check()
        #expect(status.plugin == .disabled(version: "1.0.0"))
        #expect(status.commands.enable == ["agy plugin enable subspace"])
    }

    @Test(arguments: ["not-installed.json", "uninstalled.json"])
    func notInstalledOffersTheInstallLine(capture: String) async throws {
        let status = await probe(try runner(list: capture), home: home).check()
        #expect(status.plugin == .notInstalled)
        #expect(status.commands.install == [installLine])
    }

    /// `agy plugin uninstall` keeps `plugin_data/`, so a `plugin.json` can outlive
    /// the plugin: it only dates the last session, the list decides the state.
    @Test func aLeftoverPluginJSONDoesNotMakeItInstalled() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("plugin.json")
        // The body has the contract §11 shape; the probe only reads the modification time.
        try Data(#"{"v":1,"version":"1.0.0"}"#.utf8).write(to: file)
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: started], ofItemAtPath: file.path)
        let status = await probe(try runner(list: "uninstalled.json"), home: home, chosenRoot: root).check()
        #expect(status.plugin == .notInstalled)
        #expect(status.lastSessionStartAt == started)
    }

    /// A session in the desktop app writes into its own root, not the CLI's.
    @Test func theNewestPluginJSONOfBothRootsDatesTheLastSession() async throws {
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        for (folder, date) in [("antigravity-cli", started.addingTimeInterval(-60)), ("antigravity", started)] {
            let root = home.appendingPathComponent(".gemini/\(folder)/plugin_data/subspace", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("plugin.json")
            // The body has the contract §11 shape; the probe only reads the modification time.
            try Data(#"{"v":1,"version":"1.0.0"}"#.utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
        let status = await AntigravityIntegrationProbe(runner: FakeRunner(), isExecutable: { _ in false },
                                                       environment: [:], home: home).check()
        #expect(status.lastSessionStartAt == started)
    }

    /// Only a string: this home is never read.
    @Test func theDefaultRootIsTheCLIsPluginData() {
        let home = URL(fileURLWithPath: "/Users/user", isDirectory: true)
        #expect(SubspaceRoot.resolve(adapter: AntigravityAdapter(), environment: [:], home: home).path
            == "/Users/user/.gemini/antigravity-cli/plugin_data/subspace")
    }

    @Test func withoutTheCLIOrItsFilesThePluginIsNotInstalled() async {
        let status = await probe(FakeRunner(), home: home, executables: []).check()
        #expect(status.cli == .notFound)
        #expect(status.plugin == .notInstalled)
        #expect(status.searchedLocations == ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"])
    }

    @Test(arguments: [
        CommandResult(exitCode: 1, stderr: "Error"),
        CommandResult(exitCode: 0, stdout: "not json"),
        CommandResult(exitCode: 0, stdout: "[]", timedOut: true),
    ])
    func aFailedListFallsBackToTheFiles(list: CommandResult) async throws {
        let home = try temporaryHome(manifest: "manifest-plugin.json", config: "config-disabled.json")
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = FakeRunner(["agy --version": CommandResult(exitCode: 1), "agy plugin list --json": list])
        let status = await AntigravityIntegrationProbe(runner: runner, isExecutable: { $0 == home.path + "/.local/bin/agy" },
                                                       environment: [:], home: home).check()
        #expect(status.cli == .found(path: home.path + "/.local/bin/agy", version: nil))
        #expect(status.plugin == .disabled(version: "1.0.0"))
    }

    /// The CLI's list wins over the files, which are Antigravity's internals.
    @Test func aParsedListIgnoresTheFiles() async throws {
        let home = try temporaryHome(manifest: "manifest-plugin.json", config: "config-disabled.json")
        defer { try? FileManager.default.removeItem(at: home) }
        let status = await AntigravityIntegrationProbe(
            runner: try runner(list: "enabled.json"), isExecutable: { $0 == home.path + "/.local/bin/agy" },
            environment: [:], home: home).check()
        #expect(status.plugin == .enabled(version: "1.0.0"))
    }

    @Test func aParsedEmptyListIgnoresTheFiles() async throws {
        let folder = home.appendingPathComponent(".gemini/config/plugins/subspace/.antigravity-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(try fixture("manifest-plugin.json").utf8).write(to: folder.appendingPathComponent("plugin.json"))
        try Data(try fixture("config-enabled.json").utf8).write(to: home.appendingPathComponent(".gemini/config/config.json"))
        let status = await probe(try runner(list: "not-installed.json"), home: home).check()
        #expect(status.plugin == .notInstalled)
    }

    @Test func withoutTheCLITheFilesDecide() async throws {
        let home = try temporaryHome(manifest: "manifest-plugin.json", config: "config-disabled.json")
        defer { try? FileManager.default.removeItem(at: home) }
        let status = await AntigravityIntegrationProbe(runner: FakeRunner(), isExecutable: { _ in false },
                                                       environment: [:], home: home).check()
        #expect(status.cli == .notFound)
        #expect(status.plugin == .disabled(version: "1.0.0"))
    }
}

/// A home with the files `agy plugin install` writes, filled from the captures.
private func temporaryHome(manifest: String?, config: String?, leftoverPluginData: Bool = false) throws -> URL {
    let home = try temporaryDirectory()
    let gemini = home.appendingPathComponent(".gemini", isDirectory: true)
    if let manifest {
        let folder = gemini.appendingPathComponent("config/plugins/subspace/.antigravity-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(try fixture(manifest).utf8).write(to: folder.appendingPathComponent("plugin.json"))
    }
    if let config {
        let folder = gemini.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(try fixture(config).utf8).write(to: folder.appendingPathComponent("config.json"))
    }
    if leftoverPluginData {
        let folder = gemini.appendingPathComponent("antigravity-cli/plugin_data/subspace", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The body has the contract §11 shape, as subspace writes it on a session start.
        try Data(#"{"v":1,"version":"1.0.0"}"#.utf8).write(to: folder.appendingPathComponent("plugin.json"))
    }
    return home
}

/// Without the CLI: the manifest `agy plugin install` writes and the `plugins`
/// key of `config.json`, captured with `agy` 1.5.17.
@Suite struct AntigravityPluginFilesTests {
    private func state(manifest: String?, config: String?, leftoverPluginData: Bool = false) throws -> IntegrationStatus.Plugin {
        let home = try temporaryHome(manifest: manifest, config: config, leftoverPluginData: leftoverPluginData)
        defer { try? FileManager.default.removeItem(at: home) }
        return AntigravityIntegrationProbe.pluginState(home: home)
    }

    @Test func enabledInTheConfigIsEnabledWithTheManifestVersion() throws {
        #expect(try state(manifest: "manifest-plugin.json", config: "config-enabled.json") == .enabled(version: "1.0.0"))
    }

    @Test func disabledInTheConfigIsDisabled() throws {
        #expect(try state(manifest: "manifest-plugin.json", config: "config-disabled.json") == .disabled(version: "1.0.0"))
    }

    /// Right after `agy plugin install` the config has no entry, and the CLI lists it enabled.
    @Test(arguments: ["config-no-entry.json", nil])
    func noEntryOrNoConfigIsEnabled(config: String?) throws {
        #expect(try state(manifest: "manifest-plugin.json", config: config) == .enabled(version: "1.0.0"))
    }

    /// `agy plugin uninstall` removes the manifest but keeps `plugin_data/`.
    @Test func withoutTheManifestItIsNotInstalledEvenWithLeftoverPluginData() throws {
        #expect(try state(manifest: nil, config: "config-enabled.json", leftoverPluginData: true) == .notInstalled)
    }

    @Test func aGarbageManifestIsUnknown() throws {
        let home = try temporaryHome(manifest: "manifest-plugin.json", config: "config-enabled.json")
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("not json".utf8).write(to: home.appendingPathComponent(".gemini/config/plugins/subspace/.antigravity-plugin/plugin.json"))
        #expect(AntigravityIntegrationProbe.pluginState(home: home) == .unknown)
    }

    /// A config the app can't read can't tell whether the plugin is switched off.
    @Test func aGarbageConfigIsUnknown() throws {
        let home = try temporaryHome(manifest: "manifest-plugin.json", config: nil)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("not json".utf8).write(to: home.appendingPathComponent(".gemini/config/config.json"))
        #expect(AntigravityIntegrationProbe.pluginState(home: home) == .unknown)
    }

    @Test func theManifestGivesItsNameAndVersion() throws {
        let manifest = try #require(AntigravityIntegrationProbe.manifest(from: Data(try fixture("manifest-plugin.json").utf8)))
        #expect(manifest.name == "subspace")
        #expect(manifest.version == "1.0.0")
    }

    @Test(arguments: ["", "[]", "{}", "{\"version\":\"1.0.0\"}"])
    func somethingElseIsNoManifest(data: String) {
        #expect(AntigravityIntegrationProbe.manifest(from: Data(data.utf8)) == nil)
    }

    @Test func theConfigGivesTheSwitchOfSubspaceOnly() throws {
        #expect(AntigravityIntegrationProbe.enabled(fromConfig: Data(try fixture("config-enabled.json").utf8)) == .some(true))
        #expect(AntigravityIntegrationProbe.enabled(fromConfig: Data(try fixture("config-disabled.json").utf8)) == .some(false))
        #expect(AntigravityIntegrationProbe.enabled(fromConfig: Data(try fixture("config-no-entry.json").utf8)) == .some(nil))
        // The real file has more top-level keys; only `plugins` is read.
        let full = #"{"sidecars":{},"userSettings":{"x":1},"plugins":{"subspace":{"enabled":false}}}"#
        #expect(AntigravityIntegrationProbe.enabled(fromConfig: Data(full.utf8)) == .some(false))
        #expect(AntigravityIntegrationProbe.enabled(fromConfig: Data("{}".utf8)) == .some(nil))
        #expect(AntigravityIntegrationProbe.enabled(fromConfig: Data("not json".utf8)) == nil)
    }

    /// `config-disabled.json` with one entry's value replaced, built here from the capture.
    private func config(_ entry: String, replacedWith value: Any) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(try fixture("config-disabled.json").utf8)) as? [String: Any])
        var plugins = try #require(object["plugins"] as? [String: Any])
        plugins[entry] = value
        object["plugins"] = plugins
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Another plugin's entry is Antigravity's business, however it looks.
    @Test(arguments: [["enabled": "yes"], "swarm", 1, [true]] as [any Sendable])
    func anotherPluginsMalformedEntryLeavesTheSwitchOfSubspace(value: any Sendable) throws {
        #expect(AntigravityIntegrationProbe.enabled(fromConfig: try config("swarm", replacedWith: value)) == .some(false))
    }

    /// A malformed entry of subspace itself can't tell whether it is switched off.
    @Test(arguments: [["enabled": "no"], "subspace", 0, [false]] as [any Sendable])
    func aMalformedSubspaceEntryIsUnknown(value: any Sendable) throws {
        #expect(AntigravityIntegrationProbe.enabled(fromConfig: try config("subspace", replacedWith: value)) == nil)
    }
}
