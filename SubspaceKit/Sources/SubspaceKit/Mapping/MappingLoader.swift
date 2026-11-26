import Foundation
import os

/// File access behind `MappingLoader`, so tests need no real disk.
public protocol MappingFileSystem {
    /// A cheap `stat`; nil when the file does not exist.
    func modificationDate(of url: URL) -> Date?
    /// The file's bytes.
    func contents(of url: URL) throws -> Data
}

/// The real file system, the default outside tests.
public struct DiskMappingFileSystem: MappingFileSystem {
    /// Stateless; reads straight from disk.
    public init() {}

    /// The file's modification date, nil when it does not exist.
    public func modificationDate(of url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }

    /// The file's bytes.
    public func contents(of url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}

/// Finds the mapping document for a name (subspace contract §12): the one the
/// installed plugin wrote to `$ROOT/model/<name>.json` or the copy bundled with
/// this package, whichever has the higher revision (the root's on a tie). A
/// source that spools into several roots has a copy in each: the highest
/// revision among them counts, the earlier root's on a tie. Documents of a
/// format the interpreter does not know never win.
///
/// A plain class without its own lock: callers confine it to one actor. The
/// plugin rewrites the file on every session start, so each call
/// stats it and re-reads only when the modification date changed. It only reads.
public final class MappingLoader {
    private struct RootEntry {
        var modified: Date?
        var document: MappingDocument?
    }

    private static let log = Logger(subsystem: "SubspaceKit", category: "mapping")

    private let roots: [URL]
    private let fileSystem: any MappingFileSystem
    private let bundled: (String) -> MappingDocument?
    /// By the mapping file's URL, so each root's copy is cached on its own.
    private var rootEntries: [URL: RootEntry] = [:]
    private var bundledEntries: [String: MappingDocument?] = [:]
    private var lastChoice: [String: String] = [:]

    /// `bundled` defaults to the documents shipped as package resources.
    public convenience init(
        root: URL,
        fileSystem: any MappingFileSystem = DiskMappingFileSystem(),
        bundled: @escaping (String) -> MappingDocument? = MappingLoader.bundledDocument
    ) {
        self.init(roots: [root], fileSystem: fileSystem, bundled: bundled)
    }

    /// `roots` are a source's roots in order of precedence, the primary first;
    /// `bundled` as for `init(root:)`.
    public init(
        roots: [URL],
        fileSystem: any MappingFileSystem = DiskMappingFileSystem(),
        bundled: @escaping (String) -> MappingDocument? = MappingLoader.bundledDocument
    ) {
        self.roots = roots
        self.fileSystem = fileSystem
        self.bundled = bundled
    }

    /// The document to apply for `name`, nil when neither a root nor the
    /// package has a usable one. Logs when the choice changes.
    public func document(named name: String) -> MappingDocument? {
        var fromRoot: MappingDocument?
        for root in roots {
            guard let document = rootDocument(named: name, in: root) else { continue }
            // Strictly higher, so an earlier root keeps a tie.
            if let best = fromRoot, (document.revision ?? 0) <= (best.revision ?? 0) { continue }
            fromRoot = document
        }
        let fromBundle = bundledDocument(named: name)
        let chosen: MappingDocument?
        let origin: String
        switch (fromRoot, fromBundle) {
        case let (root?, bundle?):
            // A missing `revision` counts as 0, so any document with a
            // revision wins over one without.
            if (bundle.revision ?? 0) > (root.revision ?? 0) { chosen = bundle; origin = "bundled" } else { chosen = root; origin = "root" }
        case let (root?, nil): chosen = root; origin = "root"
        case let (nil, bundle?): chosen = bundle; origin = "bundled"
        case (nil, nil): chosen = nil; origin = "none"
        }
        let choice = "\(origin) revision \(chosen?.revision.map(String.init) ?? "-")"
        if lastChoice[name] != choice {
            lastChoice[name] = choice
            Self.log.info("Mapping \(name, privacy: .public): using \(choice, privacy: .public)")
        }
        return chosen
    }

    /// Reads the bundled copy of `name`, nil when the package ships none.
    public static func bundledDocument(named name: String) -> MappingDocument? {
        guard let url = bundledURL(named: name),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? MappingDocument(data: data)
    }

    /// Where the package ships `name`, e.g. to compare the bundled copy with another;
    /// the test target has a `Bundle.module` of its own.
    public static func bundledURL(named name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Mappings")
    }

    private func rootDocument(named name: String, in root: URL) -> MappingDocument? {
        let url = root.appending(path: "model/\(name).json", directoryHint: .notDirectory)
        let modified = fileSystem.modificationDate(of: url)
        if let entry = rootEntries[url], entry.modified == modified { return entry.document }
        var document: MappingDocument?
        if modified != nil {
            do {
                document = try MappingDocument(data: fileSystem.contents(of: url))
            } catch {
                Self.log.error("Ignoring mapping file \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        // Logged here, so once per file change rather than on every call.
        if let parsed = document, Self.known(parsed) == nil {
            let format = parsed.format.map(String.init) ?? "none"
            Self.log.notice("Ignoring mapping file \(url.path, privacy: .public): unsupported format \(format, privacy: .public)")
        }
        document = Self.known(document)
        rootEntries[url] = RootEntry(modified: modified, document: document)
        return document
    }

    private func bundledDocument(named name: String) -> MappingDocument? {
        if let cached = bundledEntries[name] { return cached }
        let document = Self.known(bundled(name))
        bundledEntries[name] = .some(document)
        return document
    }

    private static func known(_ document: MappingDocument?) -> MappingDocument? {
        document?.format == MappingInterpreter.supportedFormat ? document : nil
    }
}
