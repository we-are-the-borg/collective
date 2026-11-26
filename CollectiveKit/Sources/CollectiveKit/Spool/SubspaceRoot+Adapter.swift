import Foundation
import SubspaceKit

public extension SubspaceRoot {
    /// The root `adapter`'s events and mapping come from. With no chosen folder
    /// this is the source's default, e.g. what a settings window marks "(default)".
    static func resolve(
        adapter: any PushAdapter,
        chosen: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        resolve(adapter.spoolRoot(environment: environment, home: home), chosen: chosen, environment: environment)
    }

    /// Every root `adapter`'s events and mapping come from, the primary first,
    /// each path once. A chosen folder or `SUBSPACE_DIR` replaces all of the
    /// adapter's roots with that one, by the same precedence as `resolve`.
    static func resolveAll(
        adapter: any PushAdapter,
        chosen: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        resolveAll(adapter.spoolRoots(environment: environment, home: home), chosen: chosen, environment: environment)
    }

    /// `resolveAll(adapter:)` for an adapter's own roots, for where there is no
    /// adapter yet, e.g. its default mapping.
    static func resolveAll(_ roots: [URL], chosen: URL?, environment: [String: String]) -> [URL] {
        var paths: Set<String> = []
        return roots
            .map { resolve($0, chosen: chosen, environment: environment) }
            .filter { paths.insert($0.path).inserted }
    }

    /// What choosing `folder` for a source leaves chosen. One of its `defaults`
    /// (the roots it reads without a choice, `SUBSPACE_DIR` applied), with or
    /// without a trailing slash, is a reset to all of them: a chosen folder
    /// replaces every root, so keeping it would silently drop the others.
    static func choice(_ folder: URL?, defaults: [URL]) -> URL? {
        guard let folder else { return nil }
        let path = folder.standardizedFileURL.path
        return defaults.contains { $0.standardizedFileURL.path == path } ? nil : folder
    }
}

extension SubspaceRoot {
    /// When a source's last session started: subspace rewrites `$ROOT/plugin.json`
    /// on every session start, so the newest of the files `roots` hold, nil
    /// when none does.
    static func lastSessionStart(in roots: [URL]) -> Date? {
        roots.compactMap { root in
            let path = root.appendingPathComponent("plugin.json").path
            return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }.max()
    }
}
