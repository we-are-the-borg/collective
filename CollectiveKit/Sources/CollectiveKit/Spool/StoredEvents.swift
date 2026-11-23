import Foundation

/// What the app keeps of the spool's events on disk: the event store's files
/// and what earlier versions left next to it. For the settings, which show how
/// much that is and delete it on request. The spool itself is subspace's and
/// never touched.
public struct StoredEvents: Sendable {
    /// What the store's files add to its path: nothing for the database, then
    /// as SQLite names its side files and `EventStore` a store it moved aside
    /// as corrupt.
    private static let suffixes = ["", "-wal", "-shm", ".corrupt", ".corrupt-wal"]

    /// Why `clear()` refused before touching anything.
    public enum ClearError: Error, Sendable, Equatable {
        /// The store or a leftover is a spool root, lies inside one or
        /// contains one, e.g. after the user chose the app's own folder as
        /// event folder. A receiver never writes into a root (contract §3/§4).
        case overlapsSpoolRoot
    }

    private let store: URL
    private let leftovers: [URL]
    private let roots: [URL]

    /// - Parameters:
    ///   - store: The path a `SpoolReader` keeps its store at.
    ///   - leftovers: Files or folders the app once kept its events in, e.g.
    ///     the spool mirror that preceded the store. A folder goes with
    ///     everything in it.
    ///   - roots: The spool roots read from. `clear()` creates and deletes
    ///     nothing in them.
    public init(store: URL, leftovers: [URL] = [], roots: [URL] = []) {
        self.store = store
        self.leftovers = leftovers
        self.roots = roots
    }

    /// Everything `clear()` deletes. The lock file is not among it.
    private var entries: [URL] {
        Self.suffixes.map { URL(fileURLWithPath: store.path + $0) } + leftovers
    }

    /// The bytes of all that together, 0 when nothing of it exists. What can't
    /// be read counts as nothing: the number is information next to a button,
    /// not a reason to fail.
    public func size() -> Int64 {
        entries.reduce(0) { $0 + Self.size(of: $1) }
    }

    /// Deletes all of it. What is missing is not an error. What can't be
    /// deleted doesn't keep the rest: every entry is tried, and the first
    /// failure is thrown once all were, so one stuck leftover doesn't leave the
    /// store's files behind.
    ///
    /// The caller stops its own reader first: `SpoolReader.stop()` lets go of
    /// the store and its lock. If anyone still holds the lock, a reader of this
    /// process or of a second copy of the app, this throws `EWOULDBLOCK` and
    /// deletes nothing, so no open database loses its file. It only throws once
    /// the lock is still held after the grace `SpoolReader.lock` gives it, and
    /// waits that long on the calling thread first (call it off the main
    /// actor); `SpoolReader.lock` explains why. The lock is
    /// held while deleting, which keeps a reader from opening the store halfway
    /// through, and is free again when this returns or throws. The lock file
    /// itself stays, as `SpoolReader.lock` requires.
    ///
    /// A receiver never writes into a spool root (contract §3/§4), and both
    /// the lock file and the deletion would: if the store or a leftover
    /// overlaps a root, as `SpoolReader` judges it for its store, this throws
    /// `ClearError.overlapsSpoolRoot` before it creates or deletes anything.
    public func clear() throws {
        // SQLite's side files and the lock lie next to the store's, as in `SpoolReader.openedStore`.
        let own = [store] + leftovers
        if roots.contains(where: { root in own.contains { SpoolReader.overlap(root, $0) } }) {
            throw ClearError.overlapsSpoolRoot
        }
        let lock = try SpoolReader.lock(store)
        defer { close(lock) }
        var failure: (any Error)?
        for entry in entries {
            do {
                try FileManager.default.removeItem(at: entry)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
    }

    /// The bytes of the file at `url`, or of every file below it if it is a
    /// folder. Links are not followed: deleting removes the link, not its target.
    private static func size(of url: URL) -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            return Int64(info.st_size)
        case S_IFDIR:
            let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            return children.reduce(0) { $0 + size(of: $1) }
        default:
            return 0
        }
    }
}
