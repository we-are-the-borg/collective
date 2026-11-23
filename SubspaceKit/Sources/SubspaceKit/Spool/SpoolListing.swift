import Foundation

/// Which day folders and event files a spool root holds right now (contract
/// §3, §4, §6), without remembering anything: `SpoolScanner` keeps what it
/// returned in memory, `EventStore` in its database.
enum SpoolListing {
    /// What a watcher's `changed` calls for, short of every day.
    struct Report: Equatable, Sendable {
        /// Day folders to list in full.
        var days: Set<String> = []
        /// Event file names per day folder, to look at one by one: a busy day
        /// holds thousands of files, and listing it costs that many.
        var files: [String: Set<String>] = [:]
    }

    static func eventsDirectory(of root: URL) -> URL {
        root.appendingPathComponent("events", isDirectory: true)
    }

    static func file(in root: URL, day: String, name: String) -> URL {
        eventsDirectory(of: root).appendingPathComponent(day, isDirectory: true)
            // isDirectory: false so Foundation does not stat every entry; callers check for directories.
            .appendingPathComponent(name, isDirectory: false)
    }

    /// The day folders in `root`'s `events/` folder; empty if it doesn't exist (yet).
    static func days(in root: URL) -> [String] {
        let events = eventsDirectory(of: root)
        return names(in: events).filter { isDirectory(events.appendingPathComponent($0, isDirectory: true)) }
    }

    /// What a watcher's `changed` paths call for, or nil for every day.
    /// Paths are told apart by their last components only: FSEvents reports
    /// resolved paths (`/private/var/…`), which needn't start with the root
    /// the app passes.
    ///
    /// A day folder calls for its listing, an event file only for itself; a
    /// dot-name or another extension in a day folder is a file being written
    /// or none of ours (§4, §6). `schema/` and `model/` are rewritten on every
    /// SessionStart (§3) and hold no events; a mapping change is found in the
    /// database, not by listing. Any other file URL, e.g. `plugin.json`,
    /// which the plugin also rewrites in the root on every SessionStart
    /// (§3, §11), is ignored: a changed file outside a day folder is never an
    /// event, and a new or removed folder is reported as a directory. Only a
    /// watcher that reports files yields file URLs, and a day folder passed
    /// without a trailing slash is still a day. Any other directory, e.g.
    /// `events/` itself or the root, or `changed` nil (the watcher lost
    /// track), lists every day.
    static func report(changed: Set<URL>?) -> Report? {
        guard let changed else { return nil }
        var report = Report()
        for url in changed {
            let name = url.lastPathComponent
            let parent = url.deletingLastPathComponent()
            if parent.lastPathComponent == "events" {
                report.days.insert(name)
            } else if parent.deletingLastPathComponent().lastPathComponent == "events" {
                if isEventFile(name) { report.files[parent.lastPathComponent, default: []].insert(name) }
            } else if !["schema", "model"].contains(name), !["schema", "model"].contains(parent.lastPathComponent),
                      url.hasDirectoryPath {
                return nil
            }
        }
        return report
    }

    /// The names of one day folder's `*.json` entries, without dot-names
    /// (files being written); empty if the folder doesn't exist or vanished.
    /// Names, not URLs: a URL per entry of a busy day costs more than the
    /// listing, and callers build them only for the entries they open.
    /// Directories are not filtered out here: that takes a stat per entry,
    /// so callers do it for the entries they would open.
    static func entries(in root: URL, day: String) -> [String] {
        names(in: eventsDirectory(of: root).appendingPathComponent(day, isDirectory: true)).filter(isEventFile)
    }

    static func isEventFile(_ name: String) -> Bool {
        name.hasSuffix(".json") && !name.hasPrefix(".")
    }

    /// Empty if the folder doesn't exist (yet) or vanished. `readdir` gives
    /// the names as native strings, which hash and compare fast, at a
    /// fraction of what `FileManager` takes for a folder of thousands.
    private static func names(in directory: URL) -> [String] {
        guard let stream = opendir(directory.path) else { return [] }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
