import Foundation
import SubspaceKit
import Synchronization
import Testing
@testable import CollectiveKit

/// The user's folder of custom themes, kept current: read once on start, then a new catalog per
/// change the watcher reports, plus import and Move to Trash. Folders are temporary directories
/// filled from the real schemes in `Fixtures/custom-themes` (see its README); FSEvents is faked by
/// a watcher the test drives, the Trash by a folder of the test's own.
@Suite("Custom theme library")
struct CustomThemeLibraryTests {
    private static let fixtures = Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures/custom-themes")

    /// A fresh, empty directory.
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-theme-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A fresh folder holding each fixture under the file name it maps to.
    private func folder(_ files: [String: String]) throws -> URL {
        let url = try temporaryDirectory()
        for (name, fixture) in files { try add(fixture, as: name, to: url) }
        return url
    }

    private func add(_ fixture: String, as name: String, to folder: URL) throws {
        try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(fixture), to: folder.appendingPathComponent(name))
    }

    /// Overwrites `name` in `folder` with another fixture's bytes.
    private func write(_ fixture: String, over name: String, in folder: URL) throws {
        try Data(contentsOf: Self.fixtures.appendingPathComponent(fixture)).write(to: folder.appendingPathComponent(name))
    }

    private func library(_ folder: URL, watcher: ManualWatcher = ManualWatcher(), trash: URL? = nil) -> CustomThemeLibrary {
        CustomThemeLibrary(folder: folder, watcher: watcher, pollInterval: .milliseconds(20)) { file in
            let bin = trash ?? FileManager.default.temporaryDirectory.appendingPathComponent("trash-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: bin.appendingPathComponent(file.lastPathComponent))
        }
    }

    /// The ids of the valid themes, then the file names of the broken ones.
    private func names(_ catalog: ThemeCatalog) -> [String] {
        catalog.custom.map { entry in
            switch entry {
            case .valid(let theme): theme.id
            case .broken(let file): file.fileName
            }
        }
    }

    // MARK: Reading and watching

    @Test func readsTheFolderOnceBeforeAnythingIsWatched() throws {
        let url = try folder(["horizon-dark.yaml": "horizon-dark.yaml", "ocean.yaml": "missing-name.yaml"])
        let watcher = ManualWatcher()
        let library = library(url, watcher: watcher)
        #expect(names(library.initialCatalog) == ["custom:horizon-dark", "ocean.yaml"])
        #expect(watcher.directories.isEmpty)
    }

    @Test func aFileAddedChangedRenamedOrRemovedYieldsANewCatalog() async throws {
        let url = try folder(["horizon-dark.yaml": "horizon-dark.yaml"])
        let watcher = ManualWatcher()
        let recorder = Recorder(library(url, watcher: watcher).catalogs())
        #expect(await eventually { watcher.directories == [url] })

        try add("embers-light.yaml", as: "embers-light.yaml", to: url)
        watcher.send([url])
        #expect(await recorder.waitFor(1).map(names).last == ["custom:embers-light", "custom:horizon-dark"])

        try write("missing-base0D.yaml", over: "horizon-dark.yaml", in: url)
        watcher.send([url])
        #expect(await recorder.waitFor(2).map(names).last == ["custom:embers-light", "horizon-dark.yaml"])

        try FileManager.default.moveItem(at: url.appendingPathComponent("embers-light.yaml"), to: url.appendingPathComponent("ember.yml"))
        watcher.send([url])
        #expect(await recorder.waitFor(3).map(names).last == ["custom:ember", "horizon-dark.yaml"])

        try FileManager.default.removeItem(at: url.appendingPathComponent("horizon-dark.yaml"))
        // A lost track rescans like a change.
        watcher.send(nil)
        #expect(await recorder.waitFor(4).map(names).last == ["custom:ember"])
        await recorder.stop()
    }

    @Test func aChangeThatLeavesTheEntriesAsTheyWerePublishesNothing() async throws {
        let url = try folder(["horizon-dark.yaml": "horizon-dark.yaml"])
        let watcher = ManualWatcher()
        let recorder = Recorder(library(url, watcher: watcher).catalogs())
        #expect(await eventually { watcher.directories == [url] })

        // Same bytes rewritten, a file the folder does not read, a lost track.
        try write("horizon-dark.yaml", over: "horizon-dark.yaml", in: url)
        try Data("notes".utf8).write(to: url.appendingPathComponent("notes.txt"))
        watcher.send([url])
        watcher.send(nil)
        // Then one real change: the only catalog published is the one after it.
        try add("embers-light.yaml", as: "embers-light.yaml", to: url)
        watcher.send([url])
        let catalogs = await recorder.waitFor(1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.catalogs.count == 1)
        #expect(catalogs.map(names) == [["custom:embers-light", "custom:horizon-dark"]])
        await recorder.stop()
    }

    @Test func reloadReadsTheFolderWithoutAWatcherEvent() async throws {
        let url = try folder([:])
        let watcher = ManualWatcher()
        let library = library(url, watcher: watcher)
        let recorder = Recorder(library.catalogs())
        #expect(await eventually { watcher.directories == [url] })

        try add("horizon-dark.yaml", as: "horizon-dark.yaml", to: url)
        await library.reload()
        #expect(await recorder.waitFor(1).map(names) == [["custom:horizon-dark"]])
        await library.reload()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await recorder.catalogs.count == 1)
        await recorder.stop()
    }

    @Test func aMissingFolderIsNeitherCreatedNorWatchedUntilItExists() async throws {
        let url = try temporaryDirectory().appendingPathComponent("The Collective/Themes", isDirectory: true)
        let watcher = ManualWatcher()
        let library = library(url, watcher: watcher)
        #expect(library.initialCatalog.custom.isEmpty)
        let recorder = Recorder(library.catalogs())
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(watcher.directories.isEmpty)

        try await library.ensureFolder()
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(await eventually { watcher.directories == [url] })
        try add("horizon-dark.yaml", as: "horizon-dark.yaml", to: url)
        watcher.send([url])
        #expect(await recorder.waitFor(1).map(names) == [["custom:horizon-dark"]])
        await recorder.stop()
    }

    @Test func aFolderCreatedByHandIsPickedUp() async throws {
        let url = try temporaryDirectory().appendingPathComponent("Themes", isDirectory: true)
        let watcher = ManualWatcher()
        let recorder = Recorder(library(url, watcher: watcher).catalogs())
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(await eventually { watcher.directories == [url] })
        try add("horizon-dark.yaml", as: "horizon-dark.yaml", to: url)
        watcher.send([url])
        #expect(await recorder.waitFor(1).map(names) == [["custom:horizon-dark"]])
        await recorder.stop()
    }

    @Test func aRemovedFolderLeavesNoThemesAndIsWatchedAgainOnceBack() async throws {
        let url = try folder(["horizon-dark.yaml": "horizon-dark.yaml"])
        let watcher = ManualWatcher()
        let recorder = Recorder(library(url, watcher: watcher).catalogs())
        #expect(await eventually { watcher.directories == [url] })

        try FileManager.default.removeItem(at: url)
        watcher.send(nil)
        #expect(await recorder.waitFor(1).map(names) == [[]])

        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(await eventually { watcher.directories == [url, url] })
        try add("embers-light.yaml", as: "embers-light.yaml", to: url)
        watcher.send([url])
        #expect(await recorder.waitFor(2).map(names).last == ["custom:embers-light"])
        await recorder.stop()
    }

    @Test func anEndedWatchIsStartedAgain() async throws {
        let url = try folder([:])
        let watcher = ManualWatcher()
        let recorder = Recorder(library(url, watcher: watcher).catalogs())
        #expect(await eventually { watcher.directories == [url] })
        watcher.finish()
        #expect(await eventually { watcher.directories == [url, url] })
        try add("horizon-dark.yaml", as: "horizon-dark.yaml", to: url)
        watcher.send([url])
        #expect(await recorder.waitFor(1).map(names) == [["custom:horizon-dark"]])
        await recorder.stop()
    }

    @Test func symlinkedThemeFilesCount() async throws {
        let url = try folder([:])
        let dotfiles = try folder(["horizon-dark.yaml": "horizon-dark.yaml"])
        let watcher = ManualWatcher()
        let recorder = Recorder(library(url, watcher: watcher).catalogs())
        #expect(await eventually { watcher.directories == [url] })

        try FileManager.default.createSymbolicLink(
            at: url.appendingPathComponent("horizon.yaml"), withDestinationURL: dotfiles.appendingPathComponent("horizon-dark.yaml")
        )
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("folder.yaml"), withDestinationURL: dotfiles)
        try FileManager.default.createSymbolicLink(
            at: url.appendingPathComponent("gone.yaml"), withDestinationURL: dotfiles.appendingPathComponent("gone.yaml")
        )
        watcher.send([url])
        #expect(await recorder.waitFor(1).map(names) == [["custom:horizon"]])
        await recorder.stop()
    }

    // MARK: Import

    @Test func importPlanNamesTheFilesThatWouldReplaceOne() async throws {
        let url = try folder(["horizon-dark.yaml": "horizon-dark.yaml"])
        let downloads = try folder([
            "horizon-dark.yaml": "embers-light.yaml",
            "espresso.yaml": "espresso.yaml",
        ])
        let other = try folder(["espresso.yaml": "all-black.yaml"])
        let library = library(url)
        let plan = await library.importPlan(for: [
            downloads.appendingPathComponent("horizon-dark.yaml"),
            downloads.appendingPathComponent("espresso.yaml"),
            // Picked twice under one name: the second would replace the first.
            other.appendingPathComponent("espresso.yaml"),
            // Already in the folder: nothing to replace.
            url.appendingPathComponent("horizon-dark.yaml"),
        ])
        #expect(plan.conflicts == [downloads.appendingPathComponent("horizon-dark.yaml"), other.appendingPathComponent("espresso.yaml")])
    }

    /// Two picked files of a name the folder has ask twice; each answer holds for its own file,
    /// so "No" then "Yes" replaces with the second only.
    @Test func twoPickedFilesOfOneNameAreConfirmedEachOnItsOwn() async throws {
        let url = try folder(["espresso.yaml": "espresso.yaml"])
        let first = try folder(["espresso.yaml": "embers-light.yaml"])
        let second = try folder(["espresso.yaml": "horizon-dark.yaml"])
        let picked = [first.appendingPathComponent("espresso.yaml"), second.appendingPathComponent("espresso.yaml")]
        let library = library(url)
        #expect(await library.importPlan(for: picked).conflicts == picked)
        let results = await library.import(picked, replacing: [picked[1]])
        #expect(results.map(\.outcome) == [.declined, .replaced])
        #expect(CustomThemeLibrary(folder: url, watcher: ManualWatcher()).initialCatalog.customTheme("custom:espresso")?.name == "Horizon Dark")
    }

    /// Of two picked files of a new name the first goes in unasked; the second replaces it only
    /// when confirmed, so the later confirmed one wins.
    @Test func ofTwoPickedFilesOfANewNameTheLaterConfirmedOneWins() async throws {
        let first = try folder(["ocean.yaml": "embers-light.yaml"])
        let second = try folder(["ocean.yaml": "horizon-dark.yaml"])
        let picked = [first.appendingPathComponent("ocean.yaml"), second.appendingPathComponent("ocean.yaml")]
        for (replacing, outcomes, name) in [
            (Set<URL>(), [CustomThemeImport.Outcome.imported, .declined], "Embers Light"),
            ([picked[1]], [.imported, .replaced], "Horizon Dark"),
        ] {
            let url = try folder([:])
            let library = library(url)
            #expect(await library.importPlan(for: picked).conflicts == [picked[1]])
            #expect(await library.import(picked, replacing: replacing).map(\.outcome) == outcomes)
            #expect(CustomThemeLibrary(folder: url, watcher: ManualWatcher()).initialCatalog.customTheme("custom:ocean")?.name == name)
        }
    }

    @Test func importCreatesTheFolderAndCopiesEveryFileInvalidOnesToo() async throws {
        let url = try temporaryDirectory().appendingPathComponent("The Collective/Themes", isDirectory: true)
        let downloads = try folder(["horizon-dark.yaml": "horizon-dark.yaml", "ocean.yml": "missing-base0D.yaml"])
        let library = library(url)
        let recorder = Recorder(library.catalogs())
        let results = await library.import(
            [downloads.appendingPathComponent("horizon-dark.yaml"), downloads.appendingPathComponent("ocean.yml")],
            replacing: []
        )
        #expect(results.map(\.outcome) == [.imported, .imported])
        #expect(results.map(\.fileName) == ["horizon-dark.yaml", "ocean.yml"])
        #expect(results.map(\.id) == ["custom:horizon-dark", "custom:ocean"])
        #expect(FileManager.default.fileExists(atPath: downloads.appendingPathComponent("ocean.yml").path))
        #expect(names(CustomThemeLibrary(folder: url, watcher: ManualWatcher()).initialCatalog) == ["custom:horizon-dark", "ocean.yml"])
        #expect(await recorder.waitFor(1).map(names).last == ["custom:horizon-dark", "ocean.yml"])
        // Only the themes: no half-copied leftovers.
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() == ["horizon-dark.yaml", "ocean.yml"])
        await recorder.stop()
    }

    @Test func aConflictIsReplacedOnlyWhenConfirmed() async throws {
        let url = try folder(["horizon-dark.yaml": "horizon-dark.yaml", "espresso.yaml": "espresso.yaml"])
        let downloads = try folder(["horizon-dark.yaml": "embers-light.yaml", "espresso.yaml": "all-black.yaml"])
        let library = library(url)
        let results = await library.import(
            [downloads.appendingPathComponent("horizon-dark.yaml"), downloads.appendingPathComponent("espresso.yaml")],
            replacing: [downloads.appendingPathComponent("horizon-dark.yaml")]
        )
        #expect(results.map(\.outcome) == [.replaced, .declined])
        let catalog = CustomThemeLibrary(folder: url, watcher: ManualWatcher()).initialCatalog
        #expect(catalog.customTheme("custom:horizon-dark")?.name == "Embers Light")
        #expect(try Data(contentsOf: url.appendingPathComponent("espresso.yaml")) == Data(contentsOf: Self.fixtures.appendingPathComponent("espresso.yaml")))
    }

    @Test func replacingALinkReplacesTheLinkNotItsTarget() async throws {
        let url = try folder([:])
        let dotfiles = try folder(["horizon-dark.yaml": "horizon-dark.yaml"])
        try FileManager.default.createSymbolicLink(
            at: url.appendingPathComponent("horizon.yaml"), withDestinationURL: dotfiles.appendingPathComponent("horizon-dark.yaml")
        )
        let downloads = try folder(["horizon.yaml": "embers-light.yaml"])
        let library = library(url)
        let source = downloads.appendingPathComponent("horizon.yaml")
        #expect(await library.importPlan(for: [source]).conflicts == [source])
        let results = await library.import([source], replacing: [source])
        #expect(results.map(\.outcome) == [.replaced])
        #expect(CustomThemeLibrary(folder: url, watcher: ManualWatcher()).initialCatalog.customTheme("custom:horizon")?.name == "Embers Light")
        #expect(CustomThemeFolder.entries(in: dotfiles).count == 1)
        #expect(try Data(contentsOf: dotfiles.appendingPathComponent("horizon-dark.yaml")) == Data(contentsOf: Self.fixtures.appendingPathComponent("horizon-dark.yaml")))
    }

    @Test func importingAFileFromTheFolderItselfChangesNothing() async throws {
        let url = try folder(["horizon-dark.yaml": "horizon-dark.yaml"])
        let library = library(url)
        let source = url.appendingPathComponent("horizon-dark.yaml")
        let results = await library.import([source], replacing: [source])
        #expect(results.map(\.outcome) == [.alreadyInFolder])
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path) == ["horizon-dark.yaml"])
    }

    @Test func aFileThatIsNoYAMLIsNotCopied() async throws {
        let url = try folder([:])
        let downloads = try folder(["horizon-dark.txt": "horizon-dark.yaml"])
        let results = await library(url).import([downloads.appendingPathComponent("horizon-dark.txt")], replacing: [])
        #expect(results.map(\.outcome) == [.notYAML])
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
    }

    @Test func aFileThatCannotBeCopiedSaysWhyAndTheRestGoIn() async throws {
        let url = try folder([:])
        let downloads = try folder(["horizon-dark.yaml": "horizon-dark.yaml"])
        let results = await library(url).import(
            [downloads.appendingPathComponent("no-such-file.yaml"), downloads.appendingPathComponent("horizon-dark.yaml")],
            replacing: []
        )
        guard case .failed = results.first?.outcome else {
            Issue.record("expected a failure, got \(String(describing: results.first?.outcome))")
            return
        }
        #expect(results.last?.outcome == .imported)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path) == ["horizon-dark.yaml"])
    }

    // MARK: Move to Trash

    @Test func aThemeOrBrokenFileInTheFolderGoesToTheTrash() async throws {
        let url = try folder(["horizon-dark.yaml": "horizon-dark.yaml", "ocean.yaml": "missing-name.yaml"])
        let bin = try temporaryDirectory()
        let library = library(url, trash: bin)
        let recorder = Recorder(library.catalogs())
        let theme = try #require(library.initialCatalog.customTheme("custom:horizon-dark"))
        try await library.moveToTrash(theme.url)
        #expect(await recorder.waitFor(1).map(names).last == ["ocean.yaml"])
        let broken = try #require(library.initialCatalog.brokenThemes.first)
        try await library.moveToTrash(broken.url)
        #expect(await recorder.waitFor(2).map(names).last == [])
        #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).sorted() == ["horizon-dark.yaml", "ocean.yaml"])
        await recorder.stop()
    }

    @Test func aFileOutsideTheFolderIsNotMovedToTheTrash() async throws {
        let url = try folder(["horizon-dark.yaml": "horizon-dark.yaml"])
        let elsewhere = try folder(["horizon-dark.yaml": "horizon-dark.yaml"])
        let bin = try temporaryDirectory()
        let library = library(url, trash: bin)
        for file in [
            elsewhere.appendingPathComponent("horizon-dark.yaml"),
            url.appendingPathComponent("../\(elsewhere.lastPathComponent)/horizon-dark.yaml"),
            url,
        ] {
            await #expect(throws: CustomThemeLibrary.TrashError.notInFolder) { try await library.moveToTrash(file) }
        }
        #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("horizon-dark.yaml").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).isEmpty)
    }
}

// MARK: Remembered names

@Suite("Theme choice remembered names")
struct RefreshingRememberedTests {
    private static let fixtures = Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures/custom-themes")

    private func catalog(_ files: [String: String]) throws -> ThemeCatalog {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remembered-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, fixture) in files {
            try FileManager.default.copyItem(at: Self.fixtures.appendingPathComponent(fixture), to: url.appendingPathComponent(name))
        }
        return ThemeCatalog(custom: CustomThemeFolder.entries(in: url))
    }

    private let defaults = ThemeChoice(light: BundledThemes.defaultLight, dark: BundledThemes.defaultDark)

    @Test func aChangedNameOrVariantIsRememberedInEverySlotThatChoseIt() throws {
        let before = try catalog(["mine.yaml": "horizon-dark.yaml", "light.yaml": "embers-light.yaml"])
        let choice = defaults
            .choosing("custom:light", for: .light, catalog: before)
            .choosing("custom:mine", for: .dark, catalog: before)
            .choosing("custom:mine", for: .fixed, catalog: before)
        // The file now holds a light scheme of another name.
        let after = try catalog(["mine.yaml": "horizon-light-without-variant.yaml", "light.yaml": "embers-light.yaml"])
        let refreshed = choice.refreshingRemembered(catalog: after)
        let horizonLight = RememberedCustomTheme(name: "Horizon Light", appearance: .light)
        #expect(refreshed.darkRemembered == horizonLight)
        #expect(refreshed.fixedRemembered == horizonLight)
        #expect(refreshed.lightRemembered == RememberedCustomTheme(name: "Embers Light", appearance: .light))
        #expect(refreshed.dark == "custom:mine")
        #expect(refreshed.fixed == "custom:mine")
    }

    @Test func aGoneOrBrokenFileKeepsWhatTheSlotRemembered() throws {
        let before = try catalog(["mine.yaml": "horizon-dark.yaml", "light.yaml": "embers-light.yaml"])
        let choice = defaults
            .choosing("custom:light", for: .light, catalog: before)
            .choosing("custom:mine", for: .dark, catalog: before)
        let after = try catalog(["mine.yaml": "missing-name.yaml"])
        #expect(choice.refreshingRemembered(catalog: after) == choice)
    }

    @Test func anUnchangedOrBundledChoiceStaysAsItIs() throws {
        let catalog = try catalog(["mine.yaml": "horizon-dark.yaml"])
        let choice = defaults.choosing("custom:mine", for: .dark, catalog: catalog)
        #expect(choice.refreshingRemembered(catalog: catalog) == choice)
        #expect(defaults.refreshingRemembered(catalog: catalog) == defaults)
    }
}

// MARK: Helpers

/// A watcher the test drives by hand. `Mutex` keeps it `Sendable` without `@unchecked`.
private final class ManualWatcher: DirectoryWatching {
    private struct State {
        var continuations: [AsyncStream<Set<URL>?>.Continuation] = []
        var watched: [URL] = []
    }

    private let state = Mutex(State())

    var directories: [URL] { state.withLock { $0.watched } }

    func changes(under directory: URL) -> AsyncStream<Set<URL>?> {
        let (stream, continuation) = AsyncStream.makeStream(of: Set<URL>?.self)
        state.withLock {
            $0.watched.append(directory)
            $0.continuations.append(continuation)
        }
        return stream
    }

    func send(_ changed: Set<URL>?) {
        state.withLock { $0.continuations }.forEach { $0.yield(changed) }
    }

    /// Ends every stream, as FSEvents does when it cannot watch.
    func finish() {
        state.withLock { $0.continuations }.forEach { $0.finish() }
    }
}

/// Collects the published catalogs in the background.
private actor Recorder {
    private(set) var catalogs: [ThemeCatalog] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<ThemeCatalog>) {
        Task { await self.start(stream) }
    }

    private func start(_ stream: AsyncStream<ThemeCatalog>) {
        task = Task { for await catalog in stream { self.append(catalog) } }
    }

    private func append(_ catalog: ThemeCatalog) { catalogs.append(catalog) }

    func stop() { task?.cancel() }

    /// Waits until at least `count` catalogs arrived, at most `timeout`.
    func waitFor(_ count: Int, timeout: Duration = .seconds(30)) async -> [ThemeCatalog] {
        let deadline = ContinuousClock.now + timeout
        while catalogs.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return catalogs
    }
}

/// Polls until `condition` holds, at most `timeout`.
private func eventually(timeout: Duration = .seconds(30), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
