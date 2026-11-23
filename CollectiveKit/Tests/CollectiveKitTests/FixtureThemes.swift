import Foundation
@testable import CollectiveKit

/// Every scheme Unimatrix Zero bundles, copied unchanged to `Fixtures/unimatrix/schemes` (its
/// `crates/core/src/theme/schemes` at commit 43f1307), and the themes derived from them. The app
/// bundles the same files (`Resources/Schemes`, `schemesFolderIsTheFixtureFolder`); the reference
/// file and the contract tests cover them all, as Unimatrix's tests do over its `bundled_themes`.
enum FixtureThemes {
    static let folder = Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures/unimatrix/schemes")

    /// `(id, text)` of every `*.yaml` in the folder, sorted by id byte-wise, as Unimatrix's
    /// `build.rs` sorts them.
    static let files: [(id: String, text: String)] = {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "yaml" }
            .map { url in (id: url.deletingPathExtension().lastPathComponent, url: url) }
            .sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
            .map { file in
                guard let text = try? String(contentsOf: file.url, encoding: .utf8) else {
                    preconditionFailure("fixture scheme \(file.id).yaml cannot be read")
                }
                return (file.id, text)
            }
    }()

    /// `(id, scheme)` of every file, sorted by id.
    static let schemes: [(id: String, scheme: Scheme)] = files.map { file in
        do {
            return (file.id, try Scheme.parse(file.text))
        } catch {
            preconditionFailure("fixture scheme \(file.id).yaml does not parse: \(error)")
        }
    }

    /// Every theme, sorted by id, at the contrast the family table gives it, as the app's are.
    static let all: [Theme] = schemes.map {
        deriveTheme(id: $0.id, scheme: $0.scheme, contrast: BundledThemes.contrast($0.id))
    }

    static var ids: [String] { all.map(\.id) }

    static var lightIDs: [String] { all.filter { $0.appearance == .light }.map(\.id) }

    /// The theme `id`; stops for an id that is not a fixture, a typo in the test.
    static func theme(_ id: String) -> Theme {
        guard let theme = all.first(where: { $0.id == id }) else {
            preconditionFailure("no fixture scheme \(id).yaml")
        }
        return theme
    }

    /// The scheme `id` as in the fixture, for comparing roles with its slots.
    static func scheme(_ id: String) -> Scheme {
        guard let scheme = schemes.first(where: { $0.id == id })?.scheme else {
            preconditionFailure("no fixture scheme \(id).yaml")
        }
        return scheme
    }
}
