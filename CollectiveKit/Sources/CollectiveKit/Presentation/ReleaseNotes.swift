import Foundation

/// The user release notes the About pane's "Release Notes…" sheet shows.
/// `ReleaseNotes.md` in the repo root is written by hand in each release PR; the kit bundles a
/// copy that `scripts/release.sh` keeps in step and `ReleaseNotesTests` checks.
public struct ReleaseNotes: Sendable, Equatable {
    /// One `## X.Y.Z` section.
    public struct Release: Sendable, Equatable, Identifiable {
        /// The heading as written, e.g. `1.2.0`.
        public let version: String
        /// The section's Markdown, without HTML comments and surrounding blank lines.
        public let markdown: String
        /// `markdown` parsed once, for the reply views that lay the sheet out. Never too large or
        /// too deep for the parser (`ReplyPreview.rendersAsPlainText`): the notes are ours.
        public let blocks: [ReplyBlock]
        /// The release this copy of the app is; at most one is.
        public let isInstalled: Bool

        public var id: String { version }

        init(version: String, markdown: String, isInstalled: Bool) {
            self.version = version
            self.markdown = markdown
            blocks = ReplyBlock.blocks(from: markdown)
            self.isInstalled = isInstalled
        }
    }

    /// Newest first, none newer than the installed version: a copy of the app knows nothing of
    /// later releases, and the bundled file may already hold the next one's notes on main.
    public let releases: [Release]

    /// Every release with its notes and the changelog. The public repo after the move (go-live
    /// phase 4); until then the link may lead nowhere.
    public static let allReleasesURL = URL(string: "https://github.com/we-are-the-borg/collective/releases")!

    /// The copy in the kit's bundle. Stops when it is missing or not UTF-8: it is part of the
    /// build, which `ReleaseNotesTests` checks before shipping.
    public static func bundled(installedVersion: String?) -> ReleaseNotes {
        guard let url = Bundle.collectiveKit.url(forResource: "ReleaseNotes", withExtension: "md") else {
            preconditionFailure("ReleaseNotes.md is not bundled")
        }
        do {
            return ReleaseNotes(markdown: try String(contentsOf: url, encoding: .utf8), installedVersion: installedVersion)
        } catch {
            preconditionFailure("bundled ReleaseNotes.md does not read: \(error)")
        }
    }

    /// - Parameter installedVersion: The app's `CFBundleShortVersionString`. When it is no plain
    ///   `X.Y.Z` there is no bound, so every release shows and none is flagged; when it has no
    ///   section (a build between releases), the older releases show and none is flagged.
    public init(markdown: String, installedVersion: String?) {
        var sections: [(heading: String, lines: [Substring])] = []
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                sections.append((String(line.dropFirst(3)), []))
            } else if !sections.isEmpty {
                sections[sections.count - 1].lines.append(line)
            }
        }
        let installed = installedVersion.flatMap(SubspaceVersion.init)
        var parsed: [(version: SubspaceVersion, release: Release)] = []
        var seen: Set<SubspaceVersion> = []
        for section in sections {
            // A heading that is no plain release (`1.3.0-rc1`, prose) only ends the section
            // above it; a repeated one is ignored, as `publish` reads the first.
            guard let version = SubspaceVersion(section.heading),
                  seen.insert(version).inserted,
                  installed.map({ version <= $0 }) ?? true
            else { continue }
            let body = Self.trimmingBlankLines(Self.removingComments(from: section.lines.joined(separator: "\n")))
            guard !body.isEmpty else { continue }
            parsed.append((version, Release(version: section.heading, markdown: body, isInstalled: version == installed)))
        }
        releases = parsed.sorted { $0.version > $1.version }.map(\.release)
    }

    /// As `strip_html_comments` in `scripts/release.sh`, per section: an unclosed comment hides
    /// the rest when rendered, so it counts as comment up to the end.
    private static func removingComments(from text: String) -> String {
        var rest = Substring(text)
        var kept = ""
        while let start = rest.range(of: "<!--") {
            kept += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].range(of: "-->") else { return kept }
            rest = rest[end.upperBound...]
        }
        return kept + rest
    }

    /// Leading and trailing lines with only whitespace; the first line keeps its indentation.
    private static func trimmingBlankLines(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while lines.first?.allSatisfy(\.isWhitespace) == true { lines.removeFirst() }
        while lines.last?.allSatisfy(\.isWhitespace) == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
