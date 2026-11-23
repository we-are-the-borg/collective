@testable import CollectiveKit

/// The text of a bundled scheme file by id, for tests that start from a real scheme.
func bundledSchemeText(_ id: String) throws -> String {
    guard let file = BundledThemes.schemeFiles.first(where: { $0.id == id }) else {
        throw BundledSchemeMissing(id: id)
    }
    return file.text
}

struct BundledSchemeMissing: Error { let id: String }
