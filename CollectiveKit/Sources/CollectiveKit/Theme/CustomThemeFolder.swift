import Foundation
import Synchronization

/// A custom theme that reads: a tinted-theming base16 or base24 file from the user's folder,
/// derived like a bundled scheme but never with overrides (design `themes.md` › Eigene Themes).
public struct CustomTheme: Sendable, Hashable {
    /// `custom:<file stem>`, so a custom file named like a bundled scheme sits beside it
    /// instead of replacing it.
    public let id: String
    public let fileName: String
    public let url: URL
    /// The scheme's `name` as written; the row shows it instead of a short name.
    public let name: String
    public let appearance: ThemeAppearance
    /// What the file says; equality compares it, so a changed file is a change whether or not
    /// either theme has been derived.
    let scheme: Scheme
    /// Shared by the copies of one read, so a theme derived for the popover is not derived again
    /// for the Appearance pane.
    private let derivation: CustomThemeDerivation

    init(id: String, fileName: String, url: URL, scheme: Scheme) {
        self.id = id
        self.fileName = fileName
        self.url = url
        name = scheme.name
        appearance = scheme.appearance
        self.scheme = scheme
        derivation = CustomThemeDerivation()
    }

    /// Derived on first use: about 0.4 ms each, so reading a large folder at launch must not
    /// derive every file in it.
    public var theme: Theme {
        derivation.theme(id: id, scheme: scheme)
    }

    /// Whether `theme` has been asked for, for the test that reading the folder derives nothing.
    var isDerived: Bool {
        derivation.isDerived
    }

    public static func == (lhs: CustomTheme, rhs: CustomTheme) -> Bool {
        lhs.id == rhs.id && lhs.fileName == rhs.fileName && lhs.url == rhs.url
            && lhs.name == rhs.name && lhs.appearance == rhs.appearance && lhs.scheme == rhs.scheme
    }

    /// Leaves out the scheme, which is not `Hashable`; equal themes still hash alike.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(fileName)
        hasher.combine(url)
        hasher.combine(name)
        hasher.combine(appearance)
    }
}

/// The theme of one custom file, derived under the lock like a `ThemeShelf` theme, so two
/// callers never derive it twice.
private final class CustomThemeDerivation: Sendable {
    private let derived = Mutex<Theme?>(nil)

    func theme(id: String, scheme: Scheme) -> Theme {
        derived.withLock { derived in
            if let theme = derived {
                return theme
            }
            let theme = deriveTheme(id: id, scheme: scheme, contrast: .regular)
            derived = theme
            return theme
        }
    }

    var isDerived: Bool {
        derived.withLock { $0 != nil }
    }
}

/// A file in the folder that does not read as a theme. It stays visible as an error row, so the
/// user sees why an imported file does not show up.
public struct BrokenCustomTheme: Sendable, Hashable {
    public var fileName: String
    public var url: URL
    public var stem: String
    public var problem: CustomThemeProblem
}

/// Why a custom file is no theme, in the few words an error row has room for. Several parser
/// errors share one text: a user fixing a file that is not a scheme at all gains nothing from
/// knowing which of the structural checks failed first.
public enum CustomThemeProblem: Sendable, Hashable {
    case missingColor(key: String)
    case invalidColor(key: String)
    case missingName
    case missingPalette
    case invalidVariant
    case invalidAuthor
    /// Invalid YAML, several documents, no mapping, or a missing or unknown `system`.
    case notAScheme
    /// No permission, or not UTF-8.
    case unreadable
    /// Another file has the same stem and so the same id; `winner` is its file name.
    case duplicateStem(winner: String)

    public var text: LocalizedStringResource {
        switch self {
        case .missingColor(let key): .kit("missing palette key %@", defaultValue: "missing palette key \(key)")
        case .invalidColor(let key): .kit("%@ is not a color", defaultValue: "\(key) is not a color")
        case .missingName: .kit("missing name", defaultValue: "missing name")
        case .missingPalette: .kit("missing palette", defaultValue: "missing palette")
        case .invalidVariant: .kit("variant is not light or dark", defaultValue: "variant is not light or dark")
        case .invalidAuthor: .kit("author is not text", defaultValue: "author is not text")
        case .notAScheme: .kit("not a base16 or base24 scheme", defaultValue: "not a base16 or base24 scheme")
        case .unreadable: .kit("can’t be read", defaultValue: "can’t be read")
        case .duplicateStem(let winner): .kit("same file name as %@", defaultValue: "same file name as \(winner)")
        }
    }

    init(_ error: SchemeError) {
        switch error {
        case .invalidYAML, .multipleDocuments, .notMapping, .missingSystem, .unknownSystem: self = .notAScheme
        case .missingName: self = .missingName
        case .invalidAuthor: self = .invalidAuthor
        case .invalidVariant: self = .invalidVariant
        case .missingPalette: self = .missingPalette
        case .missingColor(let key): self = .missingColor(key: key.name)
        case .invalidColor(let key, _): self = .invalidColor(key: key.name)
        }
    }
}

public enum CustomThemeEntry: Sendable, Hashable {
    case valid(CustomTheme)
    case broken(BrokenCustomTheme)
}

/// Reads the user's folder of custom themes. These are user files, so nothing here may trap,
/// unlike the bundled schemes, whose failure is a build mistake.
public enum CustomThemeFolder {
    /// `~/Library/Application Support/The Collective/Themes/`: a folder of the app's own,
    /// not Unimatrix's. Named for the user, not by bundle id, since the footnote shows the path.
    public static var location: URL {
        URL.applicationSupportDirectory.appending(path: "The Collective/Themes", directoryHint: .isDirectory)
    }

    /// Every YAML file directly in `folder`, as a theme or the reason it is none: valid themes
    /// by name, then broken files by file name. A missing or unreadable folder has no entries;
    /// it simply does not exist until the first import.
    public static func entries(in folder: URL) -> [CustomThemeEntry] {
        let files = yamlFiles(in: folder)
        var winners: [String: String] = [:]
        var valid: [CustomTheme] = []
        var broken: [BrokenCustomTheme] = []
        // Byte-wise, so the winner of a shared stem does not depend on the locale.
        for url in files.sorted(by: { $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8) }) {
            let fileName = url.lastPathComponent
            let stem = url.deletingPathExtension().lastPathComponent
            func fail(_ problem: CustomThemeProblem) {
                broken.append(BrokenCustomTheme(fileName: fileName, url: url, stem: stem, problem: problem))
            }
            if let winner = winners[stem] {
                fail(.duplicateStem(winner: winner))
                continue
            }
            winners[stem] = fileName
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                fail(.unreadable)
                continue
            }
            let scheme: Scheme
            do {
                scheme = try Scheme.parse(text)
            } catch {
                fail(CustomThemeProblem(error))
                continue
            }
            let id = CustomThemeID.prefix + stem
            valid.append(CustomTheme(id: id, fileName: fileName, url: url, scheme: scheme))
        }
        valid.sort { a, b in
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: a.id.utf8.lexicographicallyPrecedes(b.id.utf8)
            }
        }
        broken.sort { a, b in
            switch a.fileName.localizedStandardCompare(b.fileName) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: a.fileName.utf8.lexicographicallyPrecedes(b.fileName.utf8)
            }
        }
        return valid.map(CustomThemeEntry.valid) + broken.map(CustomThemeEntry.broken)
    }

    /// Regular, visible files directly in `folder` ending in `yaml` or `yml`, and links named so
    /// whose target is a regular file: users keep their themes in dotfiles. A link to a folder or
    /// to nothing is skipped like any other non-file. The extension is compared ignoring case:
    /// macOS volumes are usually case-insensitive, so `Ocean.YAML` is as much a YAML file to the
    /// user as `ocean.yaml`. The URLs stay the folder's own, links included, so moving a theme to
    /// the Trash takes the link and not the file it points to.
    private static func yamlFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }
        return urls.filter { url in
            let ext = url.pathExtension.lowercased()
            guard ext == "yaml" || ext == "yml",
                  let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            if values.isSymbolicLink == true {
                return isRegularFile(url.resolvingSymlinksInPath())
            }
            return values.isRegularFile == true
        }
    }

    /// Whether `url` is a regular file, following no further links: a link whose target cannot
    /// be resolved stays a link and so is none.
    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
