import Foundation

/// Locates the optional subspace dev checkout (we-are-the-borg/subspace) for tests: relative to
/// this file, or via `SUBSPACE_DEV_DIR`. Callers gate on `isAvailable` so a
/// missing repo shows up as skipped, never as passed with nothing checked.
enum SubspaceDevRepo {
    static let root: URL = {
        if let override = ProcessInfo.processInfo.environment["SUBSPACE_DEV_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // <parent>/<owner>/<repo>/SubspaceKit/Tests/SubspaceKitTests/<this file>,
        // subspace checked out at <parent>/we-are-the-borg/subspace
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("we-are-the-borg/subspace", isDirectory: true)
    }()

    static let isAvailable = FileManager.default.fileExists(
        atPath: root.appendingPathComponent("fixtures").path)
        && FileManager.default.fileExists(atPath: root.appendingPathComponent("model").path)
}
