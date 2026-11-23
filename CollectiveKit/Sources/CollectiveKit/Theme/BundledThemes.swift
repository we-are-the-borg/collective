import Foundation
import Synchronization

// The themes shipped with the app, a port of Unimatrix Zero's `theme/builtin.rs` (commit
// 43f1307) and `theme::roles` and `theme::chosen_roles` in `theme/mod.rs` (commit 43f1307; there
// `docs/decisions.md` §13), whose choice `resolve` takes. Every scheme file in the bundled
// `Schemes` folder is a theme: a file dropped there joins without a code change, as Unimatrix's
// `build.rs` embeds its folder. The folder is Unimatrix's, file for file
// (`schemesFolderIsTheFixtureFolder`), so the app offers what Unimatrix's reference file checks and
// no scheme of its own.

/// The bundled themes and the default pair for each appearance.
public enum BundledThemes {
    /// Shown when the system is light and no other theme is chosen.
    public static let defaultLight = "catppuccin-latte"

    /// Shown when the system is dark and no other theme is chosen.
    public static let defaultDark = "catppuccin-macchiato"

    /// Every bundled theme, sorted by id; derived once, on first use. The launch path takes
    /// `resolve`, which derives only the theme it needs.
    public static let all: [Theme] = shelf.all

    /// Stops if the folder is missing: it is part of the build, like the files in it.
    static let shelf: ThemeShelf = {
        guard let folder = Bundle.collectiveKit.url(forResource: "Schemes", withExtension: nil) else {
            preconditionFailure("the Schemes folder is not bundled")
        }
        return ThemeShelf(folder: folder)
    }()

    /// The contrast the family table gives `id`; every bundled id has an entry
    /// (`coversEveryBundledTheme`).
    static func contrast(_ id: String) -> ThemeContrast {
        ThemeFamily.naming(id)?.contrast ?? .regular
    }

    /// The id of the default theme for `appearance`.
    static func defaultID(for appearance: ThemeAppearance) -> String {
        switch appearance {
        case .light: defaultLight
        case .dark: defaultDark
        }
    }

    /// The theme `id`, whatever the appearance; an unknown id, say from an old setting, falls
    /// back to the default for `appearance`. Stops if a default is not bundled, which
    /// `holdsEveryShippedSchemeOnceSortedByID` rules out.
    public static func resolve(id: String, appearance: ThemeAppearance) -> Theme {
        if let theme = shelf.theme(id) {
            return theme
        }
        let fallback = defaultID(for: appearance)
        guard let theme = shelf.theme(fallback) else {
            preconditionFailure("default theme Schemes/\(fallback).yaml is not bundled")
        }
        return theme
    }

    /// The roles of the default theme for `appearance`: Catppuccin Latte when light, Macchiato
    /// when dark.
    public static func roles(for appearance: ThemeAppearance) -> ThemeRoles {
        resolve(id: defaultID(for: appearance), appearance: appearance).roles
    }

    /// `(id, text)` of every `Schemes/*.yaml` in the kit's bundle, sorted by id.
    static var schemeFiles: [(id: String, text: String)] {
        shelf.ids.map { ($0, shelf.text($0)) }
    }
}

/// The scheme files of a folder and their themes, each derived when first asked for: deriving
/// all 38 costs about 20 ms cold in a release build, the launch needs one of them.
final class ThemeShelf: Sendable {
    /// The file stems of every `*.yaml`, sorted by id rather than file name: `github.yaml` sorts
    /// after `github-dark.yaml`, `github` before. Byte-wise, as Rust sorts.
    let ids: [String]
    private let urls: [String: URL]
    private let derived = Mutex<[String: Theme]>([:])

    init(folder: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        urls = Dictionary(
            files.filter { $0.pathExtension == "yaml" }.map { ($0.deletingPathExtension().lastPathComponent, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        ids = urls.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// Every theme, sorted by id.
    var all: [Theme] {
        ids.compactMap(theme)
    }

    /// The theme of `id`, derived on the first call; `nil` for an id without a file. Derived
    /// under the lock, so two callers never derive the same theme twice.
    func theme(_ id: String) -> Theme? {
        guard urls[id] != nil else { return nil }
        return derived.withLock { derived in
            if let theme = derived[id] {
                return theme
            }
            let theme = deriveTheme(id: id, scheme: parse(id), contrast: BundledThemes.contrast(id))
            derived[id] = theme
            return theme
        }
    }

    /// The ids derived so far, for the test that the launch derives one theme, not all.
    var derivedIDs: Set<String> {
        derived.withLock { Set($0.keys) }
    }

    /// Part of the build, like a file Rust embeds: unreadable means a broken bundle.
    func text(_ id: String) -> String {
        guard let url = urls[id], let text = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("bundled scheme Schemes/\(id).yaml cannot be read")
        }
        return text
    }

    /// Stops: a bundled file is part of the build, not user data, so failing to parse it is a
    /// defect the tests catch before shipping (`everyBundledSchemeParses`).
    private func parse(_ id: String) -> Scheme {
        do {
            return try Scheme.parse(text(id))
        } catch {
            preconditionFailure("bundled scheme Schemes/\(id).yaml does not parse: \(error)")
        }
    }
}
