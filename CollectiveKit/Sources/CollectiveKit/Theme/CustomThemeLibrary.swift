import Darwin
import Foundation
import SubspaceKit

/// The user's folder of custom themes, kept current (design `themes.md` › Eigene Themes): read
/// once on start, so a chosen custom theme shows from the first frame, then a new catalog
/// whenever what the folder holds changes. Also the only way the app writes to the folder:
/// import and Move to Trash.
///
/// The folder does not exist until the first import or `Show in Finder` (`ensureFolder()`), and
/// reading or watching never creates it. While it is missing, the library checks every
/// `pollInterval` whether it exists, like the session status source does with its folder: a
/// stat every few seconds is cheaper and simpler than watching `The Collective/` or Application
/// Support for a folder that may never come. Import and `ensureFolder()` publish right away;
/// watching starts with the next check. A theme linked from elsewhere (dotfiles) is only
/// re-read when the folder itself changes or on `reload()`, since FSEvents watches the folder,
/// not where its links point.
public actor CustomThemeLibrary {
    public nonisolated let folder: URL
    /// The folder as it was when the library was made; later states come from `catalogs()`.
    public nonisolated let initialCatalog: ThemeCatalog

    private let watcher: any DirectoryWatching
    private let pollInterval: Duration
    private let trash: @Sendable (URL) throws -> Void
    /// What the consumer last got, so a read that changes nothing publishes nothing.
    private var published: [CustomThemeEntry]
    private var continuation: AsyncStream<ThemeCatalog>.Continuation?

    public init(
        folder: URL = CustomThemeFolder.location,
        watcher: any DirectoryWatching = FSEventsWatcher(),
        pollInterval: Duration = .seconds(5)
    ) {
        self.init(folder: folder, watcher: watcher, pollInterval: pollInterval) { file in
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
    }

    /// With a Trash of its own, so tests do not fill the user's.
    init(
        folder: URL,
        watcher: any DirectoryWatching,
        pollInterval: Duration,
        trash: @escaping @Sendable (URL) throws -> Void
    ) {
        self.folder = folder
        self.watcher = watcher
        self.pollInterval = pollInterval
        self.trash = trash
        let entries = CustomThemeFolder.entries(in: folder)
        self.published = entries
        self.initialCatalog = ThemeCatalog(custom: entries)
    }

    /// Starts watching and yields a catalog each time the folder's entries differ from the last
    /// one handed out, starting from `initialCatalog`. Only the newest is kept for a slow
    /// consumer: an older catalog is of no use once a newer one exists. Ending the iteration
    /// stops watching. Call once.
    public nonisolated func catalogs() -> AsyncStream<ThemeCatalog> {
        let (stream, continuation) = AsyncStream.makeStream(of: ThemeCatalog.self, bufferingPolicy: .bufferingNewest(1))
        let task = Task { await self.watch(into: continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Reads the folder again now, e.g. when the Appearance pane opens: a linked file's target
    /// may have changed unseen.
    public func reload() {
        refresh()
    }

    /// Creates the folder if it is missing, for `Show in Finder`.
    public func ensureFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    // MARK: Watching

    private func watch(into continuation: AsyncStream<ThemeCatalog>.Continuation) async {
        self.continuation = continuation
        defer { self.continuation = nil }
        while !Task.isCancelled {
            guard Self.directoryExists(folder) else {
                // A folder that went away leaves no themes.
                refresh()
                try? await Task.sleep(for: pollInterval)
                continue
            }
            // Subscribe before reading, so nothing written in between is missed.
            let changes = watcher.changes(under: folder)
            refresh()
            var vanished = false
            // A handful of small files: any change, and a lost track (`nil`) alike, rereads all.
            for await _ in changes {
                refresh()
                vanished = !Self.directoryExists(folder)
                if vanished { break }
            }
            // A watcher that ended on its own must not make this loop spin.
            if !vanished { try? await Task.sleep(for: pollInterval) }
        }
    }

    private func refresh() {
        let entries = CustomThemeFolder.entries(in: folder)
        guard entries != published, let continuation else { return }
        published = entries
        continuation.yield(ThemeCatalog(custom: entries))
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Import

    /// The files of `urls` whose name the folder already has, in order, so the app can ask
    /// "Replace?" for each. Two picked files of one name count too: the
    /// second would replace the first. A file already in the folder replaces nothing.
    public func importPlan(for urls: [URL]) -> CustomThemeImportPlan {
        var taken = Set(existingNames())
        var conflicts: [URL] = []
        for source in urls where !isInFolder(source) && Self.isYAML(source) {
            if !taken.insert(source.lastPathComponent.lowercased()).inserted { conflicts.append(source) }
        }
        return CustomThemeImportPlan(conflicts: conflicts)
    }

    /// Copies `urls` into the folder, creating it, in order. A name already there is replaced
    /// only if its source is in `replacing`, else the file is left out. Keyed by source, not by
    /// name: two picked files of one name each have their own answer, and of those confirmed the
    /// later one wins. Files that do not read as a
    /// theme are copied all the same and show as error rows. Each file is copied under a
    /// hidden name first and then renamed into place, so a read in between never sees half a
    /// file or, on replace, no file; a replaced link is replaced itself, not the file it points to.
    public func `import`(_ urls: [URL], replacing: Set<URL>) -> [CustomThemeImport] {
        do {
            try ensureFolder()
        } catch {
            return urls.map { CustomThemeImport(source: $0, outcome: .failed(error.localizedDescription)) }
        }
        var taken = Set(existingNames())
        let results = urls.map { source -> CustomThemeImport in
            let name = source.lastPathComponent
            let outcome: CustomThemeImport.Outcome
            if isInFolder(source) {
                outcome = .alreadyInFolder
            } else if !Self.isYAML(source) {
                outcome = .notYAML
            } else if taken.contains(name.lowercased()) {
                outcome = replacing.contains(source) ? copy(source, replace: true) : .declined
            } else {
                outcome = copy(source, replace: false)
            }
            if outcome == .imported || outcome == .replaced { taken.insert(name.lowercased()) }
            return CustomThemeImport(source: source, outcome: outcome)
        }
        refresh()
        return results
    }

    private func copy(_ source: URL, replace: Bool) -> CustomThemeImport.Outcome {
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        let staging = folder.appendingPathComponent(".import-\(UUID().uuidString)-\(source.lastPathComponent)")
        do {
            // The file itself, should the panel hand over a link.
            try FileManager.default.copyItem(at: source.resolvingSymlinksInPath(), to: staging)
        } catch {
            return .failed(error.localizedDescription)
        }
        // Exclusive unless replacing: a file of that name that appeared since stays.
        let flags = replace ? 0 : UInt32(RENAME_EXCL)
        guard renamex_np(staging.path, destination.path, flags) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: staging)
            return .failed(error.localizedDescription)
        }
        return replace ? .replaced : .imported
    }

    /// Lowercased: macOS volumes are usually case-insensitive, so `Ocean.yaml` replaces `ocean.yaml`.
    private func existingNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() }
    }

    // MARK: Move to Trash

    public enum TrashError: Error, Sendable, Hashable {
        /// Not a YAML file directly in the folder; the library only removes its own files.
        case notInFolder
    }

    /// Moves a custom or broken entry's file to the Trash, without asking, since the Trash
    /// gives it back. A link goes itself, not the file it points to.
    /// Refuses anything that is not a YAML file directly in the folder.
    public func moveToTrash(_ file: URL) throws {
        guard isInFolder(file), Self.isYAML(file) else { throw TrashError.notInFolder }
        try trash(file)
        refresh()
    }

    // MARK: Paths

    /// Whether `url` names an entry directly in the folder, whatever links lead to either.
    /// The entry itself is not resolved: a link in the folder is the folder's.
    private func isInFolder(_ url: URL) -> Bool {
        let parent = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.path == folder.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func isYAML(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "yaml" || ext == "yml"
    }
}

/// What an import would replace.
public struct CustomThemeImportPlan: Sendable, Hashable {
    /// The picked files whose name the folder already has, one "Replace?" each; the alert names
    /// the file by `lastPathComponent`.
    public var conflicts: [URL]
}

/// What happened to one file of an import.
public struct CustomThemeImport: Sendable, Hashable {
    public enum Outcome: Sendable, Hashable {
        case imported
        case replaced
        /// Its name was taken and the user kept the file there.
        case declined
        /// It is in the folder already; nothing to copy.
        case alreadyInFolder
        /// Not `.yaml` or `.yml`: the folder would not read it.
        case notYAML
        /// Could not be copied; the system's reason.
        case failed(String)
    }

    public var source: URL
    public var outcome: Outcome

    public var fileName: String { source.lastPathComponent }

    /// The id the copied file became in the folder, for callers and tests; the app selects nothing after an import.
    public var id: String { CustomThemeID.prefix + source.deletingPathExtension().lastPathComponent }
}
