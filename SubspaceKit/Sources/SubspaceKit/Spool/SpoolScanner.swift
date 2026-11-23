import Foundation

/// Finds event files in one spool root that weren't returned before.
///
/// Read-only: seen files are tracked in memory, per day folder, so the record
/// shrinks when subspace deletes old days (contract §5).
public struct SpoolScanner {
    let root: URL
    private var seen: [String: Set<String>] = [:]

    /// Scans `root`'s `events/` folder; nothing has been seen yet.
    public init(root: URL) { self.root = root }

    /// New files in all day folders, in the order of the contract's hint:
    /// mtime (nanoseconds), then name (contract §6).
    public mutating func scanAll() -> [URL] {
        let days = SpoolListing.days(in: root)
        seen = seen.filter { days.contains($0.key) }
        return Self.sorted(days.flatMap { scan(day: $0) })
    }

    /// New files after a change. `changed` holds what a watcher reported,
    /// directories and files, `nil` asks for a full scan. A change to a day
    /// folder, or to an event file in it, rescans only that day: unlike
    /// `EventStore`, the scanner has no database a day's listing would have
    /// to be compared against. Paths that hold no events (`schema/`, `model/`,
    /// files being written, any file outside a day folder such as
    /// `plugin.json`) scan nothing; other directories rescan everything.
    public mutating func scan(changed: Set<URL>?) -> [URL] {
        guard let report = SpoolListing.report(changed: changed) else { return scanAll() }
        return Self.sorted(report.days.union(report.files.keys).flatMap { scan(day: $0) })
    }

    private mutating func scan(day: String) -> [URL] {
        let names = SpoolListing.entries(in: root, day: day)
        var known = seen[day] ?? []
        let new = names.filter { known.insert($0).inserted }
        if !names.isEmpty { seen[day] = known }
        return new.map { SpoolListing.file(in: root, day: day, name: $0) }.filter { !SpoolListing.isDirectory($0) }
    }

    /// The contract's order (§6), also across spool and mirror: mtime, then name.
    public static func sorted(_ files: [URL]) -> [URL] {
        files
            .map { (url: $0, mtime: mtimeNanoseconds($0)) }
            .sorted { ($0.mtime, $0.url.lastPathComponent) < ($1.mtime, $1.url.lastPathComponent) }
            .map(\.url)
    }

    /// 0 for a file that vanished; reading it fails later and is skipped.
    static func mtimeNanoseconds(_ url: URL) -> Int64 {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return 0 }
        return Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }
}
