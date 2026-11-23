import Foundation
import Markdown

/// The Sparkle appcast `scripts/release.sh publish` attaches to every GitHub
/// release. The app reads it from the latest release
/// (`…/releases/latest/download/appcast.xml`, `SUFeedURL`), so each release
/// carries the whole history: the previous release's appcast with the new
/// version on top.
public enum Appcast {
    /// Where the release's assets live; the tag is `v` plus the version.
    public static let releasesURL = URL(string: "https://github.com/we-are-the-borg/collective/releases")!
    /// Three parts, as Sparkle asks; the app's deployment target.
    public static let minimumSystemVersion = "15.0.0"

    public struct Item: Sendable, Equatable {
        /// `X.Y.Z`; also the bundle version, which `Version.xcconfig` keeps equal.
        public let version: String
        /// The signed archive's size in bytes, as `sign_update` prints it.
        public let length: Int
        /// The archive's EdDSA signature, as `sign_update` prints it.
        public let edSignature: String
        /// The version's section of `ReleaseNotes.md`, as a page for the update window.
        public let notesHTML: String
        public let date: Date

        public init(version: String, length: Int, edSignature: String, notesHTML: String, date: Date) {
            self.version = version
            self.length = length
            self.edSignature = edSignature
            self.notesHTML = notesHTML
            self.date = date
        }

        /// `…/releases/download/vX.Y.Z/The-Collective-X.Y.Z.zip`, as `publish` names the archive.
        public var archiveURL: URL {
            Appcast.releasesURL.appending(path: "download/v\(version)/The-Collective-\(version).zip")
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noNotes(version: String)
        case unreadablePrevious(String)

        public var description: String {
            switch self {
            case .noNotes(let version): "ReleaseNotes.md has no notes for \(version)"
            case .unreadablePrevious(let reason): "the previous appcast does not read: \(reason)"
            }
        }
    }

    private static let sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"

    /// The appcast with `item` on top of the previous one's items. An item of the same
    /// version is replaced, so a repeated run never lists a version twice.
    /// - Parameter previous: The latest release's `appcast.xml`; nil for the first release.
    public static func adding(_ item: Item, to previous: Data?) throws -> Data {
        let document: XMLDocument
        if let previous {
            do {
                document = try XMLDocument(data: previous, options: [.nodePreserveCDATA])
            } catch {
                throw Failure.unreadablePrevious(String(describing: error))
            }
        } else {
            document = empty()
        }
        guard let channel = try document.nodes(forXPath: "/rss/channel").first as? XMLElement else {
            throw Failure.unreadablePrevious("no <rss><channel>")
        }
        for old in channel.elements(forName: "item") where old.child("sparkle:version") == item.version {
            old.detach()
        }
        let new = element(for: item)
        if let first = channel.elements(forName: "item").first {
            channel.insertChild(new, at: first.index)
        } else {
            channel.addChild(new)
        }
        return document.xmlData(options: [.nodePrettyPrint, .nodeCompactEmptyElement])
    }

    /// The version's section of `ReleaseNotes.md` as a page: the version as a heading,
    /// then the notes, in the system font at 12/17, light or dark with the window.
    /// - Throws: `Failure.noNotes` when the section is missing or holds only comments.
    public static func notesHTML(releaseNotes markdown: String, version: String) throws -> String {
        let release = ReleaseNotes(markdown: markdown, installedVersion: version).releases.first { $0.version == version }
        guard let release else { throw Failure.noNotes(version: version) }
        var escaping = EscapingText()
        let body = escaping.visit(Document(parsing: release.markdown)).map { HTMLFormatter.format($0) } ?? ""
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        body { font: 12px/17px -apple-system, sans-serif; margin: 0; }
        h1 { font-size: 13px; font-weight: 600; margin: 0 0 6px; }
        ul { margin: 0; padding-left: 18px; }
        li { margin: 2px 0; }
        code { font: 11px ui-monospace, monospace; }
        </style></head><body>
        <h1>\(version)</h1>
        \(body)</body></html>
        """
    }

    private static func empty() -> XMLDocument {
        let rss = XMLElement(name: "rss")
        rss.addAttribute(XMLNode.attribute(withName: "version", stringValue: "2.0") as! XMLNode)
        rss.addNamespace(XMLNode.namespace(withName: "sparkle", stringValue: sparkle) as! XMLNode)
        let channel = XMLElement(name: "channel")
        channel.addChild(XMLElement(name: "title", stringValue: "The Collective"))
        channel.addChild(XMLElement(name: "link", stringValue: "https://github.com/we-are-the-borg/collective"))
        rss.addChild(channel)
        let document = XMLDocument(rootElement: rss)
        document.version = "1.0"
        document.characterEncoding = "utf-8"
        return document
    }

    private static func element(for item: Item) -> XMLElement {
        let element = XMLElement(name: "item")
        element.addChild(XMLElement(name: "title", stringValue: item.version))
        element.addChild(XMLElement(name: "pubDate", stringValue: pubDate(item.date)))
        element.addChild(XMLElement(name: "sparkle:version", stringValue: item.version))
        element.addChild(XMLElement(name: "sparkle:shortVersionString", stringValue: item.version))
        element.addChild(XMLElement(name: "sparkle:minimumSystemVersion", stringValue: minimumSystemVersion))
        let description = XMLElement(name: "description")
        let notes = XMLNode(kind: .text, options: .nodeIsCDATA)
        notes.stringValue = item.notesHTML
        description.addChild(notes)
        element.addChild(description)
        let enclosure = XMLElement(name: "enclosure")
        for (name, value) in [
            ("url", item.archiveURL.absoluteString), ("length", String(item.length)),
            ("type", "application/octet-stream"), ("sparkle:edSignature", item.edSignature),
        ] {
            enclosure.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
        }
        element.addChild(enclosure)
        return element
    }

    /// RFC 822, as RSS wants it: "Mon, 23 Nov 2026 21:04:48 +0000".
    static func pubDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}

/// `HTMLFormatter` writes text and code as they are; an `<` or `&` in the notes would break
/// the page. Inline and block HTML stay as written, as Markdown means them.
private struct EscapingText: MarkupRewriter {
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    mutating func visitText(_ text: Text) -> Markup? {
        Text(Self.escaped(text.string))
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> Markup? {
        InlineCode(Self.escaped(inlineCode.code))
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> Markup? {
        CodeBlock(language: codeBlock.language, Self.escaped(codeBlock.code))
    }
}

private extension XMLElement {
    func child(_ name: String) -> String? {
        elements(forName: name).first?.stringValue
    }
}
