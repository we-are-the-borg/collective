import Foundation
import Testing
@testable import CollectiveKit

// The Sparkle appcast scripts/release.sh attaches to each release.

/// Monday, 23 November 2026, 21:04:48 GMT.
private let date = Date(timeIntervalSince1970: 1_795_467_888)

private let notes = """
# Release Notes

Intro with a [link](https://example.com).

## 1.3.0

<!-- Write the notes for users here. -->

- **App updates:** The Collective updates itself. Check `Settings › About`.
- Fixes 2 < 3 & more.
- Code `a <b>` and raw <kbd>⌘,</kbd> HTML.

## 1.2.0

- Older notes.
"""

private func item(_ version: String, notesHTML: String = "<p>Notes</p>") -> Appcast.Item {
    Appcast.Item(version: version, length: 11_357_703, edSignature: "c2lnbmF0dXJl", notesHTML: notesHTML, date: date)
}

private func document(_ data: Data) throws -> XMLDocument {
    try XMLDocument(data: data, options: [.nodePreserveCDATA])
}

private func values(_ data: Data, _ xpath: String) throws -> [String] {
    try document(data).nodes(forXPath: xpath).compactMap(\.stringValue)
}

@Suite struct AppcastTests {
    @Test func theFirstReleaseStartsTheFeed() throws {
        let data = try Appcast.adding(item("1.3.0"), to: nil)
        let xml = String(decoding: data, as: UTF8.self)
        #expect(xml.contains(#"xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle""#))
        #expect(try values(data, "/rss/channel/title") == ["The Collective"])
        #expect(try values(data, "/rss/channel/item/title") == ["1.3.0"])
        #expect(try values(data, "/rss/channel/item/pubDate") == ["Mon, 23 Nov 2026 21:04:48 +0000"])
        #expect(try values(data, "/rss/channel/item/sparkle:version") == ["1.3.0"])
        #expect(try values(data, "/rss/channel/item/sparkle:shortVersionString") == ["1.3.0"])
        #expect(try values(data, "/rss/channel/item/sparkle:minimumSystemVersion") == ["15.0.0"])
        #expect(try values(data, "/rss/channel/item/enclosure/@url")
            == ["https://github.com/we-are-the-borg/collective/releases/download/v1.3.0/The-Collective-1.3.0.zip"])
        #expect(try values(data, "/rss/channel/item/enclosure/@length") == ["11357703"])
        #expect(try values(data, "/rss/channel/item/enclosure/@type") == ["application/octet-stream"])
        #expect(try values(data, "/rss/channel/item/enclosure/@sparkle:edSignature") == ["c2lnbmF0dXJl"])
        #expect(try values(data, "/rss/channel/item/description") == ["<p>Notes</p>"])
        #expect(xml.contains("<![CDATA[<p>Notes</p>]]>"))
    }

    /// The latest release's appcast carries the history; the new version goes on top.
    @Test func aNewReleaseGoesOnTopOfThePreviousOnes() throws {
        let first = try Appcast.adding(item("1.3.0"), to: nil)
        let second = try Appcast.adding(item("1.3.1"), to: first)
        #expect(try values(second, "/rss/channel/item/sparkle:version") == ["1.3.1", "1.3.0"])
        #expect(try values(second, "/rss/channel/title") == ["The Collective"])
        // The earlier item keeps its notes as CDATA.
        #expect(String(decoding: second, as: UTF8.self).components(separatedBy: "<![CDATA[").count == 3)
    }

    @Test func aRepeatedVersionReplacesItsItem() throws {
        let first = try Appcast.adding(item("1.3.0", notesHTML: "<p>Old</p>"), to: nil)
        let again = try Appcast.adding(item("1.3.0", notesHTML: "<p>New</p>"), to: first)
        #expect(try values(again, "/rss/channel/item/sparkle:version") == ["1.3.0"])
        #expect(try values(again, "/rss/channel/item/description") == ["<p>New</p>"])
    }

    /// A "]]>" in the notes can't end the CDATA section early.
    @Test func notesThatLookLikeTheEndOfCDATAStayWhole() throws {
        let tricky = "<p>a ]]> b</p>"
        let data = try Appcast.adding(item("1.3.0", notesHTML: tricky), to: nil)
        #expect(try values(data, "/rss/channel/item/description") == [tricky])
    }

    @Test func aBrokenPreviousAppcastStops() {
        #expect(throws: Appcast.Failure.self) { try Appcast.adding(item("1.3.0"), to: Data("not xml".utf8)) }
        #expect(throws: Appcast.Failure.self) { try Appcast.adding(item("1.3.0"), to: Data("<rss/>".utf8)) }
    }

    /// Only the version's own section, its comments dropped, as HTML with the version as heading.
    @Test func theNotesAreTheVersionsSectionAsHTML() throws {
        let html = try Appcast.notesHTML(releaseNotes: notes, version: "1.3.0")
        #expect(html.contains("<h1>1.3.0</h1>"))
        #expect(html.contains("<li><p><strong>App updates:</strong> The Collective updates itself. Check <code>Settings › About</code>.</p>"))
        #expect(html.contains("<li><p>Fixes 2 &lt; 3 &amp; more.</p>"))
        #expect(html.contains("<code>a &lt;b&gt;</code>"))
        #expect(html.contains("<kbd>⌘,</kbd>"))
        #expect(!html.contains("Older notes"))
        #expect(!html.contains("Write the notes"))
        #expect(html.contains("color-scheme: light dark"))
        #expect(html.contains("-apple-system"))
    }

    @Test func aVersionWithoutNotesStops() {
        #expect(throws: Appcast.Failure.noNotes(version: "1.4.0")) {
            try Appcast.notesHTML(releaseNotes: notes, version: "1.4.0")
        }
        #expect(throws: Appcast.Failure.noNotes(version: "1.3.0")) {
            try Appcast.notesHTML(releaseNotes: "## 1.3.0\n\n<!-- only a hint -->\n", version: "1.3.0")
        }
    }
}
