import Foundation
import Testing
@testable import CollectiveKit

/// Reads folders built in a temporary directory from the real schemes in
/// `Fixtures/custom-themes` (see its README), copied under the names a test needs.
@Suite("Custom theme folder")
struct CustomThemeFolderTests {
    private static let fixtures = Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures/custom-themes")

    /// A fresh folder holding each fixture under the file name it maps to.
    private func folder(_ files: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-themes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, fixture) in files {
            try FileManager.default.copyItem(
                at: Self.fixtures.appendingPathComponent(fixture),
                to: url.appendingPathComponent(name)
            )
        }
        return url
    }

    private func themes(_ entries: [CustomThemeEntry]) -> [CustomTheme] {
        entries.compactMap { if case .valid(let theme) = $0 { theme } else { nil } }
    }

    private func broken(_ entries: [CustomThemeEntry]) -> [BrokenCustomTheme] {
        entries.compactMap { if case .broken(let file) = $0 { file } else { nil } }
    }

    private func english(_ text: LocalizedStringResource) -> String {
        var text = text
        text.locale = Locale(identifier: "en")
        return String(localized: text)
    }

    @Test("a valid scheme becomes a theme with the custom id, its name and appearance", arguments: [
        ("horizon-dark.yaml", "custom:horizon-dark", "Horizon Dark", ThemeAppearance.dark),
        ("embers-light.yaml", "custom:embers-light", "Embers Light", .light),
        ("espresso.yaml", "custom:espresso", "Espresso", .dark),
        ("horizon-light-without-variant.yaml", "custom:horizon-light-without-variant", "Horizon Light", .light),
    ])
    func validScheme(file: String, id: String, name: String, appearance: ThemeAppearance) throws {
        let url = try folder([file: file])
        let entries = CustomThemeFolder.entries(in: url)
        let theme = try #require(themes(entries).first)
        #expect(entries.count == 1)
        #expect(theme.id == id)
        #expect(theme.fileName == file)
        #expect(theme.url.lastPathComponent == file)
        #expect(theme.url.deletingLastPathComponent().standardizedFileURL.path == url.standardizedFileURL.path)
        #expect(theme.name == name)
        #expect(theme.appearance == appearance)
        #expect(theme.theme.id == id)
        #expect(theme.theme.name == name)
        #expect(theme.theme.appearance == appearance)
    }

    @Test("a broken file becomes an error entry naming what to fix", arguments: [
        ("missing-base0D.yaml", "missing palette key base0D"),
        ("base0A-not-a-color.yaml", "base0A is not a color"),
        ("missing-name.yaml", "missing name"),
        ("empty-name.yaml", "missing name"),
        ("missing-palette.yaml", "missing palette"),
        ("invalid-variant.yaml", "variant is not light or dark"),
        ("invalid-author.yaml", "author is not text"),
        ("not-yaml.yaml", "not a base16 or base24 scheme"),
        ("two-documents.yaml", "not a base16 or base24 scheme"),
        ("not-a-mapping.yaml", "not a base16 or base24 scheme"),
        ("wrong-system.yaml", "not a base16 or base24 scheme"),
        ("missing-system.yaml", "not a base16 or base24 scheme"),
        ("not-utf8.yaml", "can’t be read"),
    ])
    func brokenFile(file: String, text: String) throws {
        let url = try folder([file: file])
        let entries = CustomThemeFolder.entries(in: url)
        let entry = try #require(broken(entries).first)
        #expect(entries.count == 1)
        #expect(entry.fileName == file)
        #expect(entry.url.lastPathComponent == file)
        #expect(entry.stem == String(file.dropLast(".yaml".count)))
        #expect(english(entry.problem.text) == text)
    }

    @Test("a file without read permission can’t be read")
    func noPermission() throws {
        let url = try folder(["horizon-dark.yaml": "horizon-dark.yaml"])
        let file = url.appendingPathComponent("horizon-dark.yaml")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let entry = try #require(broken(CustomThemeFolder.entries(in: url)).first)
        #expect(english(entry.problem.text) == "can’t be read")
    }

    @Test("degenerate palettes still derive a theme", arguments: ["all-same.yaml", "all-black.yaml", "all-white.yaml"])
    func degeneratePalette(file: String) throws {
        let theme = try #require(themes(CustomThemeFolder.entries(in: folder([file: file]))).first)
        #expect(theme.id == "custom:\(file.dropLast(".yaml".count))")
        #expect(theme.name == "Espresso")
        // Derivation is lazy, so only asking for the theme proves these palettes do not trap.
        #expect(theme.theme.id == theme.id)
        #expect(theme.theme.appearance == theme.appearance)
        // Even a palette of one color keeps the text apart from the surface it reads on.
        #expect(theme.theme.roles[.text] != theme.theme.roles[.surface])
    }

    @Test("reads .yaml and .yml in any case, ignores other files, hidden files and subfolders")
    func whichFiles() throws {
        let url = try folder([
            "horizon-dark.yaml": "horizon-dark.yaml",
            "embers-light.yml": "embers-light.yaml",
            "Espresso.YML": "espresso.yaml",
            "horizon-light.txt": "horizon-light-without-variant.yaml",
            "horizon-light": "horizon-light-without-variant.yaml",
            ".hidden.yaml": "horizon-light-without-variant.yaml",
            "README.md": "README.md",
        ])
        let sub = url.appendingPathComponent("nested.yaml", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        try FileManager.default.copyItem(
            at: Self.fixtures.appendingPathComponent("horizon-light-without-variant.yaml"),
            to: sub.appendingPathComponent("inside.yaml")
        )
        let entries = CustomThemeFolder.entries(in: url)
        #expect(entries.count == 3)
        #expect(Set(themes(entries).map(\.id)) == ["custom:horizon-dark", "custom:embers-light", "custom:Espresso"])
    }

    @Test("a missing folder has no entries")
    func missingFolder() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-folder-\(UUID().uuidString)")
        #expect(CustomThemeFolder.entries(in: url).isEmpty)
    }

    @Test("of two files with one stem the byte-wise first wins, the other names it")
    func duplicateStem() throws {
        let url = try folder(["ocean.yml": "horizon-dark.yaml", "ocean.yaml": "embers-light.yaml"])
        let entries = CustomThemeFolder.entries(in: url)
        #expect(themes(entries).map(\.fileName) == ["ocean.yaml"])
        #expect(themes(entries).map(\.name) == ["Embers Light"])
        let loser = try #require(broken(entries).first)
        #expect(entries.count == 2)
        #expect(loser.fileName == "ocean.yml")
        #expect(english(loser.problem.text) == "same file name as ocean.yaml")
    }

    @Test("a broken winner still keeps the other file of its stem out")
    func brokenWinner() throws {
        let url = try folder(["ocean.yaml": "missing-name.yaml", "ocean.yml": "horizon-dark.yaml"])
        let texts = broken(CustomThemeFolder.entries(in: url)).map { "\($0.fileName): \(english($0.problem.text))" }
        #expect(texts == ["ocean.yaml: missing name", "ocean.yml: same file name as ocean.yaml"])
    }

    @Test("valid themes by name, ties by id, then errors by file name")
    func order() throws {
        let url = try folder([
            "b-dark.yaml": "horizon-dark.yaml",
            "a-dark.yaml": "horizon-dark.yaml",
            "light.yaml": "embers-light.yaml",
            "zz.yaml": "espresso.yaml",
            "z-broken.yaml": "not-yaml.yaml",
            "a-broken.yaml": "missing-name.yaml",
            "B-broken.yaml": "wrong-system.yaml",
        ])
        let names = CustomThemeFolder.entries(in: url).map { entry in
            switch entry {
            case .valid(let theme): theme.id
            case .broken(let file): file.fileName
            }
        }
        #expect(names == [
            "custom:light", "custom:zz", "custom:a-dark", "custom:b-dark",
            "a-broken.yaml", "B-broken.yaml", "z-broken.yaml",
        ])
    }

    @Test("a link to a YAML file elsewhere counts, under the link's name and URL")
    func symlinkToFile() throws {
        let url = try folder([:])
        let dotfiles = try folder(["horizon-dark.yaml": "horizon-dark.yaml"])
        let link = url.appendingPathComponent("horizon.yaml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dotfiles.appendingPathComponent("horizon-dark.yaml"))
        let entries = CustomThemeFolder.entries(in: url)
        let theme = try #require(themes(entries).first)
        #expect(entries.count == 1)
        #expect(theme.id == "custom:horizon")
        #expect(theme.name == "Horizon Dark")
        #expect(theme.fileName == "horizon.yaml")
        // The link, not its target: moving the theme to the Trash must not take the user's dotfile.
        #expect(theme.url.lastPathComponent == "horizon.yaml")
    }

    @Test("a link to a folder and a broken link are ignored")
    func symlinkIgnored() throws {
        let url = try folder([:])
        let target = try folder(["inside.yaml": "horizon-dark.yaml"])
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("folder.yaml"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(
            at: url.appendingPathComponent("gone.yaml"),
            withDestinationURL: target.appendingPathComponent("no-such-file.yaml")
        )
        #expect(CustomThemeFolder.entries(in: url).isEmpty)
    }
}
