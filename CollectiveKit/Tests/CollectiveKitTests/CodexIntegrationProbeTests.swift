import Foundation
import SubspaceKit
import Synchronization
import Testing
@testable import CollectiveKit

/// A real `codex plugin list --json` of Codex 0.160.1, reduced to two installed entries.
private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures/codex/plugin-detection/\(name)"))
}

/// The captured list with `subspace@subspace` changed.
private func list(_ change: (inout [String: Any]) -> Void) throws -> Data {
    var object = try #require(try JSONSerialization.jsonObject(with: fixture("plugin-list.json")) as? [String: Any])
    var entries = try #require(object["installed"] as? [[String: Any]])
    let index = try #require(entries.firstIndex { $0["pluginId"] as? String == "subspace@subspace" })
    change(&entries[index])
    object["installed"] = entries
    return try JSONSerialization.data(withJSONObject: object)
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

private let home = URL(fileURLWithPath: "/Users/user", isDirectory: true)
private let cli = "/opt/homebrew/bin/codex"

private func probe(_ runner: FakeRunner, executables: Set<String> = [cli], environment: [String: String] = [:]) -> CodexIntegrationProbe {
    CodexIntegrationProbe(runner: runner, isExecutable: { executables.contains($0) }, environment: environment, home: home)
}

@Suite struct CodexSetupCommandsTests {
    @Test func commandsInstallFromTheMarketplaceAndOfferNoEnable() {
        #expect(CodexSubspace.commands == SetupCommands(
            install: ["codex plugin marketplace add we-are-the-borg/subspace-codex", "codex plugin add subspace@subspace"],
            installInApp: [], enable: [], enableInApp: [],
            marketplaceLine: "codex plugin marketplace add we-are-the-borg/subspace-codex",
            sourceURL: URL(string: "https://github.com/we-are-the-borg/subspace-codex"),
            firstSessionHint: .kit(
                "Start a new Codex session, then approve subspace’s hooks with /hooks.",
                defaultValue: "Start a new Codex session, then approve subspace’s hooks with /hooks."
            ),
            update: ["codex plugin marketplace upgrade subspace", "codex plugin add subspace@subspace"],
            updateHint: .kit(
                "Start a new Codex session, then approve subspace’s changed hooks with /hooks.",
                defaultValue: "Start a new Codex session, then approve subspace’s changed hooks with /hooks."
            ),
            release: SubspaceRelease(
                tagsRepository: "we-are-the-borg/subspace-codex", tagPrefix: "codex-",
                changesRepository: "we-are-the-borg/subspace"
            )))
    }

    /// Codex holds changed hooks back until they are approved again, so the update says so.
    @Test func anUpdateAsksToApproveTheChangedHooksAndRequiresNoMinimumVersion() throws {
        let commands = CodexSubspace.commands
        #expect(commands.updateHint != nil)
        #expect(try #require(commands.release).minimumVersion == nil)
    }

    @Test func theChangesLinkComparesTheTwoTagsInTheDevRepo() throws {
        let release = try #require(CodexSubspace.commands.release)
        #expect(release.changesURL(from: "1.0.1", to: "1.1.0")
            == URL(string: "https://github.com/we-are-the-borg/subspace/compare/codex-1.0.1...codex-1.1.0"))
    }

    @Test func theMarketplaceLineIsPartOfTheInstallAndTheSourceIsOnGitHub() throws {
        let commands = CodexSubspace.commands
        #expect(commands.install.contains(try #require(commands.marketplaceLine)))
        #expect(commands.sourceURL?.host() == "github.com")
    }
}

@Suite struct CodexVersionTests {
    @Test func versionIsTheLastTokenOfTheFirstLine() {
        #expect(CodexIntegrationProbe.version(fromVersionOutput: "codex-cli 0.160.1\n") == "0.160.1")
        #expect(CodexIntegrationProbe.version(fromVersionOutput: "codex-cli 0.160.1\nsecond line 9\n") == "0.160.1")
    }

    @Test func emptyOutputHasNoVersion() {
        #expect(CodexIntegrationProbe.version(fromVersionOutput: " \n") == nil)
    }
}

@Suite struct CodexPluginListTests {
    @Test func enabledWithTheVersionFromTheCapture() throws {
        #expect(CodexIntegrationProbe.pluginState(fromList: try fixture("plugin-list.json")) == .enabled(version: "1.0.1"))
    }

    @Test func disabled() throws {
        let data = try list { $0["enabled"] = false }
        #expect(CodexIntegrationProbe.pluginState(fromList: data) == .disabled(version: "1.0.1"))
    }

    @Test func anEntryThatIsNotInstalledIsNotInstalled() throws {
        let data = try list { $0["installed"] = false }
        #expect(CodexIntegrationProbe.pluginState(fromList: data) == .notInstalled)
    }

    @Test func aMissingEntryIsNotInstalled() throws {
        let data = try list { $0["pluginId"] = "other@subspace" }
        #expect(CodexIntegrationProbe.pluginState(fromList: data) == .notInstalled)
        #expect(CodexIntegrationProbe.pluginState(fromList: Data(#"{"installed":[]}"#.utf8)) == .notInstalled)
    }

    @Test func anEntryFromAnotherMarketplaceIsIgnored() throws {
        let data = try list { $0["marketplaceName"] = "elsewhere" }
        #expect(CodexIntegrationProbe.pluginState(fromList: data) == .notInstalled)
    }

    @Test(arguments: ["", "Error: unknown option '--json'", "[]", "{\"available\":[]}"])
    func unparseableOutputHasNoAnswer(output: String) {
        #expect(CodexIntegrationProbe.pluginState(fromList: Data(output.utf8)) == nil)
    }
}

@Suite struct CodexMarketplaceListTests {
    @Test func theCapturedListHasTheSubspaceMarketplace() throws {
        #expect(CodexIntegrationProbe.marketplaceAdded(fromList: try fixture("marketplace-list.json")) == true)
    }

    @Test func anEmptyListHasNoMarketplace() throws {
        #expect(CodexIntegrationProbe.marketplaceAdded(fromList: try fixture("marketplace-list-empty.json")) == false)
    }

    /// The captured list without subspace, with subspace under another name, or from another repo.
    @Test(arguments: [
        ("drop", false),
        ("name", true),
        ("source", true),
    ])
    func eitherTheNameOrTheRepoCounts(change: String, expected: Bool) throws {
        var object = try #require(try JSONSerialization.jsonObject(with: fixture("marketplace-list.json")) as? [String: Any])
        var entries = try #require(object["marketplaces"] as? [[String: Any]])
        let index = try #require(entries.firstIndex { $0["name"] as? String == "subspace" })
        switch change {
        case "drop": entries.remove(at: index)
        case "name": entries[index]["name"] = "subspace-fork"
        default: entries[index]["marketplaceSource"] = ["sourceType": "git", "source": "https://github.com/someone/subspace-fork.git"]
        }
        object["marketplaces"] = entries
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(CodexIntegrationProbe.marketplaceAdded(fromList: data) == expected)
    }

    @Test(arguments: ["", "Error: unknown option '--json'", "[]", "{\"installed\":[]}"])
    func unparseableOutputHasNoAnswer(output: String) {
        #expect(CodexIntegrationProbe.marketplaceAdded(fromList: Data(output.utf8)) == nil)
    }
}

@Suite struct CodexIntegrationCheckTests {
    /// The settings window links the plugin before the first check returns, so the
    /// probe names its commands up front and every check reports the same ones.
    @Test func theCommandsAreKnownBeforeTheCheckAndTheCheckReportsThem() async {
        let probe = probe(FakeRunner())
        #expect(probe.commands == CodexSubspace.commands)
        #expect(probe.commands.sourceURL == URL(string: "https://github.com/we-are-the-borg/subspace-codex"))
        #expect(await probe.check().commands == probe.commands)
    }

    @Test func asksTheCLIForVersionAndPluginList() async throws {
        let runner = FakeRunner([
            "codex --version": CommandResult(exitCode: 0, stdout: "codex-cli 0.160.1\n", stderr: "WARNING: noise 9.9.9\n"),
            "codex plugin list --json": CommandResult(exitCode: 0, stdout: String(decoding: try fixture("plugin-list.json"), as: UTF8.self),
                                          stderr: "warning: something\n"),
        ])
        let status = await probe(runner).check()
        #expect(status.source == "codex")
        #expect(status.toolName == "Codex")
        #expect(status.cliName == "codex")
        #expect(status.cli == .found(path: cli, version: "0.160.1"))
        #expect(status.plugin == .enabled(version: "1.0.1"))
        #expect(status.commands == CodexSubspace.commands)
        #expect(status.commands.update == ["codex plugin marketplace upgrade subspace", "codex plugin add subspace@subspace"])
        #expect(status.commands.release?.tagsRepository == "we-are-the-borg/subspace-codex")
        #expect(status.searchedLocations == ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"])
        #expect(Set(runner.calls.map(\.arguments))
            == [["--version"], ["plugin", "list", "--json"], ["plugin", "marketplace", "list", "--json"]])
        #expect(runner.calls.allSatisfy { $0.executable == cli })
        let environments = runner.calls.map(\.environment)
        #expect(environments.allSatisfy { $0 == environments.first })
        #expect(environments.first?["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
    }

    @Test(arguments: [("marketplace-list.json", true), ("marketplace-list-empty.json", false)])
    func reportsWhetherTheMarketplaceIsAdded(capture: String, added: Bool) async throws {
        let runner = FakeRunner([
            "codex plugin marketplace list --json": CommandResult(exitCode: 0, stdout: String(decoding: try fixture(capture), as: UTF8.self)),
        ])
        #expect(await probe(runner).check().marketplaceAdded == added)
    }

    @Test(arguments: [
        CommandResult(exitCode: 1, stderr: "Error"),
        CommandResult(exitCode: 0, stdout: "not json"),
        CommandResult(exitCode: 0, stdout: "{\"marketplaces\":[]}", timedOut: true),
    ])
    func aFailedMarketplaceListIsUnknown(list: CommandResult) async {
        let runner = FakeRunner(["codex plugin marketplace list --json": list])
        #expect(await probe(runner).check().marketplaceAdded == nil)
    }

    /// A cold `codex plugin list --json` took 38 s; the lists get the
    /// long timeout, the version stays quick.
    @Test func theListsWaitLongerThanTheVersion() async {
        let runner = FakeRunner()
        _ = await probe(runner).check()
        let timeouts = Dictionary(uniqueKeysWithValues: runner.calls.map { ($0.arguments, $0.timeout) })
        #expect(timeouts == [
            ["--version"]: .seconds(5),
            ["plugin", "list", "--json"]: .seconds(60),
            ["plugin", "marketplace", "list", "--json"]: .seconds(60),
        ])
    }

    @Test func withoutTheCLIThePluginIsUnknown() async {
        let status = await probe(FakeRunner(), executables: []).check()
        #expect(status.cli == .notFound)
        #expect(status.plugin == .unknown)
        #expect(status.marketplaceAdded == nil)
    }

    @Test(arguments: [
        CommandResult(exitCode: 1, stderr: "Error"),
        CommandResult(exitCode: 0, stdout: "not json"),
        CommandResult(exitCode: 0, stdout: "{\"installed\":[]}", timedOut: true),
    ])
    func aFailedListIsUnknown(list: CommandResult) async {
        let runner = FakeRunner(["codex --version": CommandResult(exitCode: 1), "codex plugin list --json": list])
        let status = await probe(runner).check()
        #expect(status.cli == .found(path: cli, version: nil))
        #expect(status.plugin == .unknown)
    }
}

@Suite struct CodexSessionStartTests {
    private func pluginJSON(in root: URL, at started: Date) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("plugin.json")
        try Data(#"{"v":1,"version":"1.0.1"}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: started], ofItemAtPath: file.path)
    }

    private let started = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func theDefaultRootIsUnderTheHomeFolder() {
        #expect(SubspaceRoot.resolve(adapter: CodexAdapter(), environment: [:], home: home).path
            == "/Users/user/.codex/plugins/data/subspace-subspace")
    }

    @Test func anEmptyCODEX_HOMECountsAsUnset() {
        #expect(SubspaceRoot.resolve(adapter: CodexAdapter(), environment: ["CODEX_HOME": ""], home: home).path
            == "/Users/user/.codex/plugins/data/subspace-subspace")
    }

    @Test func CODEX_HOMEIsWherePluginJSONIsRead() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try pluginJSON(in: folder.appendingPathComponent("plugins/data/subspace-subspace"), at: started)
        let status = await probe(FakeRunner(), executables: [], environment: ["CODEX_HOME": folder.path]).check()
        #expect(status.lastSessionStartAt == started)
    }

    @Test func aChosenFolderWins() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try pluginJSON(in: folder, at: started)
        let probe = CodexIntegrationProbe(runner: FakeRunner(), isExecutable: { _ in false }, chosenRoot: folder,
                                          environment: ["CODEX_HOME": "/nowhere", "SUBSPACE_DIR": "/nowhere"], home: home)
        #expect(await probe.check().lastSessionStartAt == started)
    }

    @Test func noPluginJSONMeansNoSessionYet() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let status = await probe(FakeRunner(), executables: [], environment: ["CODEX_HOME": folder.path]).check()
        #expect(status.lastSessionStartAt == nil)
    }
}
