import Foundation

/// Where a source's `$ROOT` is (subspace contract §2). One place for reading
/// the spool and loading the mapping, so a mapping always comes from the root
/// its events come from.
public enum SubspaceRoot {
    /// A folder the user chose for the source wins; otherwise `SUBSPACE_DIR`
    /// replaces every source's own root with one shared root. A chosen folder
    /// without a path counts as none.
    public static func resolve(_ adapterRoot: URL, chosen: URL? = nil, environment: [String: String]) -> URL {
        if let chosen, !chosen.path.isEmpty {
            return chosen.standardizedFileURL
        }
        if let shared = environment["SUBSPACE_DIR"], !shared.isEmpty {
            return URL(fileURLWithPath: shared, isDirectory: true).standardizedFileURL
        }
        return adapterRoot.standardizedFileURL
    }

    /// Whether going from the chosen folders `old` to `new` reads any source
    /// from another root, i.e. whether the reader must start over. `defaults`
    /// are the registered sources' roots without a choice (`SUBSPACE_DIR`
    /// applied). Compares paths, so choosing the folder that is the default
    /// already, with or without a trailing slash, changes nothing.
    public static func rootsChange(defaults: [SourceID: URL], from old: [SourceID: URL], to new: [SourceID: URL]) -> Bool {
        defaults.contains { source, root in
            resolve(root, chosen: old[source], environment: [:]).path
                != resolve(root, chosen: new[source], environment: [:]).path
        }
    }
}
