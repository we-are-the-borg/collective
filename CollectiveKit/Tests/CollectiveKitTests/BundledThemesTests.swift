import Foundation
import Testing
@testable import CollectiveKit

/// The bundled themes and the default pair, ported from Unimatrix Zero's `theme/builtin.rs`
/// and `theme/mod.rs` (commit 43f1307) with the same expectations. mod.rs'
/// `chosen_roles` tests run against `resolve`, which takes the chosen id here.
@Suite struct BundledThemesTests {
    private var ids: [String] {
        BundledThemes.all.map(\.id)
    }

    @Test func holdsEveryShippedSchemeOnceSortedByID() {
        let ids = ids
        #expect(zip(ids, ids.dropFirst()).allSatisfy { $0.utf8.lexicographicallyPrecedes($1.utf8) }, "\(ids)")
        #expect(ids.contains(BundledThemes.defaultLight))
        #expect(ids.contains(BundledThemes.defaultDark))
    }

    /// Read from the source folder, independent of the bundle: a file dropped into the folder
    /// must show up.
    @Test func holdsExactlyTheYAMLFilesOfTheSchemesFolder() throws {
        let folder = Self.sourceFolder("../../Sources/CollectiveKit/Resources/Schemes")
        let stems = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "yaml" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        #expect(ids == stems)
    }

    /// Least OKLCH lightness gap that reads as a separate surface.
    private static let visibleLightnessGap = 0.02

    private func lightness(_ color: ThemeColor) -> Double {
        toOKLCH(SRGB(r: color.r, g: color.g, b: color.b)).l
    }

    /// The rest of abnahme's per-theme cases, contrast and layering, are the contract tests in
    /// `ThemeDerivationTests`, which run over every bundled theme. In a light theme sunken is
    /// raised to one step above `surface-raised`, which may bring it closer to `surface` than the
    /// gap (Unimatrix `docs/design/durchsicht.md`: gutter against code 1.02:1 in Latte, accepted).
    @Test func recessedSurfacesSitAVisibleGapApart() {
        for theme in BundledThemes.all {
            let roles = theme.roles
            let sunkenFromSurface = theme.appearance == .dark ? [(roles.surfaceSunken, roles.surface)] : []
            for (a, b) in sunkenFromSurface + [
                (roles.surfaceDeep, roles.surfaceSunken),
                (roles.surfaceDeep, roles.surface),
            ] {
                let gap = abs(lightness(a) - lightness(b))
                #expect(gap >= Self.visibleLightnessGap, "\(theme.id) \(a) \(b): \(gap)")
            }
        }
    }

    private static func sourceFolder(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: path).standardized
    }

    /// The app ships every scheme Unimatrix bundles, unmodified, so the reference
    /// file and the contract tests over `FixtureThemes` cover exactly what the app shows. Read
    /// from both source folders: a file added to or dropped from either side fails here, the
    /// `NOTICE.md` that carries the schemes' licenses included.
    @Test func schemesFolderIsTheFixtureFolder() throws {
        let bundled = Self.sourceFolder("../../Sources/CollectiveKit/Resources/Schemes")
        let fixture = Self.sourceFolder("Fixtures/unimatrix/schemes")
        func names(_ folder: URL) throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        }
        let bundledNames = try names(bundled)
        let fixtureNames = try names(fixture)
        #expect(bundledNames.contains("NOTICE.md"))
        #expect(bundledNames.subtracting(fixtureNames).isEmpty, "only in Schemes: \(bundledNames.subtracting(fixtureNames).sorted())")
        #expect(fixtureNames.subtracting(bundledNames).isEmpty, "only in the fixture: \(fixtureNames.subtracting(bundledNames).sorted())")
        for name in bundledNames.intersection(fixtureNames).sorted() {
            let same = try Data(contentsOf: bundled.appending(path: name)) == Data(contentsOf: fixture.appending(path: name))
            #expect(same, "Schemes/\(name) differs from its Unimatrix copy")
        }
    }

    /// The reference test and the contract tests go through `FixtureThemes`, so without this
    /// nothing pins that the app derives its bundled themes the same way, e.g. at the
    /// high-contrast level from the family table for the two GitHub High Contrast schemes.
    @Test func bundledThemesEqualTheirFixtureDerivations() {
        #expect(BundledThemes.all.map(\.id) == FixtureThemes.ids)
        for theme in BundledThemes.all {
            #expect(theme == FixtureThemes.theme(theme.id), "\(theme.id)")
        }
    }

    /// Over the files the bundle holds, so a dropped-in scheme is checked too; a failure here
    /// rather than the `preconditionFailure` that `BundledThemes.all` would stop at.
    @Test func everyBundledSchemeParses() {
        for file in BundledThemes.schemeFiles {
            #expect(throws: Never.self, "Schemes/\(file.id).yaml") { try Scheme.parse(file.text) }
        }
    }

    @Test func returnsAKnownThemeWhateverTheAppearance() {
        #expect(BundledThemes.resolve(id: "github", appearance: .dark).id == "github")
        #expect(BundledThemes.resolve(id: "catppuccin-mocha", appearance: .light).id == "catppuccin-mocha")
    }

    @Test func fallsBackToTheDefaultOfTheAppearanceForAnUnknownID() {
        #expect(BundledThemes.resolve(id: "no-such-theme", appearance: .light).id == "catppuccin-latte")
        #expect(BundledThemes.resolve(id: "no-such-theme", appearance: .dark).id == "catppuccin-macchiato")
        // An empty id is no theme either.
        #expect(BundledThemes.resolve(id: "", appearance: .light).id == "catppuccin-latte")
        #expect(BundledThemes.resolve(id: "", appearance: .dark).id == "catppuccin-macchiato")
    }

    // MARK: lazy derivation

    /// The launch resolves one theme to color the popover; deriving all 38 there costs about
    /// 20 ms, so a theme is derived when first asked for and only `all` derives the rest.
    @Test func resolvingDerivesOnlyTheThemeItNeeds() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "shelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for id in ["nord", "catppuccin-latte", "github"] {
            try FileManager.default.copyItem(
                at: FixtureThemes.folder.appending(path: "\(id).yaml"),
                to: folder.appending(path: "\(id).yaml")
            )
        }
        try Data("not a scheme".utf8).write(to: folder.appending(path: "NOTICE.md"))

        let shelf = ThemeShelf(folder: folder)
        #expect(shelf.ids == ["catppuccin-latte", "github", "nord"])
        #expect(shelf.derivedIDs.isEmpty)
        #expect(shelf.theme("nord") == FixtureThemes.theme("nord"))
        #expect(shelf.derivedIDs == ["nord"])
        #expect(shelf.theme("no-such-theme") == nil)
        #expect(shelf.theme("NOTICE") == nil)
        #expect(shelf.derivedIDs == ["nord"])
        #expect(shelf.all == ["catppuccin-latte", "github", "nord"].map(FixtureThemes.theme))
        #expect(shelf.derivedIDs == Set(shelf.ids))
    }

    /// The popover, the settings window and the custom folder's watcher resolve themes from
    /// different threads; the shelf and a custom theme derive under their locks, so concurrent
    /// first calls agree and derive nothing they were not asked for.
    @Test func concurrentLookupsAgreeAndDeriveOnlyWhatTheyAskFor() async throws {
        let shelf = ThemeShelf(folder: FixtureThemes.folder)
        let folder = FileManager.default.temporaryDirectory.appending(path: "custom-themes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixtures = try #require(Bundle.module.resourceURL).appending(path: "Fixtures/custom-themes")
        for file in ["horizon-dark.yaml", "espresso.yaml"] {
            try FileManager.default.copyItem(at: fixtures.appending(path: file), to: folder.appending(path: file))
        }
        let catalog = ThemeCatalog(shelf: shelf, custom: CustomThemeFolder.entries(in: folder))
        let custom = try #require(catalog.customTheme("custom:horizon-dark"))
        let ids = ["nord", "github", "catppuccin-latte", custom.id]
        let results = await withTaskGroup(of: (String, Theme?).self) { group in
            for index in 0..<300 {
                let id = ids[index % ids.count]
                group.addTask { (id, index.isMultiple(of: 2) ? shelf.theme(id) : catalog.theme(id)) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 300)
        // Derived on its own once all lookups are done, so it compares against no lookup's result.
        let expectedCustom = deriveTheme(id: custom.id, scheme: custom.scheme, contrast: .regular)
        for (id, theme) in results {
            #expect(theme == (id == custom.id ? expectedCustom : FixtureThemes.theme(id)), "\(id)")
        }
        #expect(shelf.derivedIDs == Set(ids.dropLast()))
        #expect(catalog.customThemes.filter(\.isDerived).map(\.id) == [custom.id])
    }

    // MARK: mod.rs

    private func derived(_ id: String) throws -> ThemeRoles {
        try #require(BundledThemes.all.first { $0.id == id }).roles
    }

    @Test func lightAndDarkAreTheDerivedDefaultPair() throws {
        #expect(BundledThemes.roles(for: .light) == (try derived("catppuccin-latte")))
        #expect(BundledThemes.roles(for: .dark) == (try derived("catppuccin-macchiato")))
    }
}
