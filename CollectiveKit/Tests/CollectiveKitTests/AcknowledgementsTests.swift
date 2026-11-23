import Foundation
import Testing
@testable import CollectiveKit

/// The bundled acknowledgements against the real `Package.resolved`: the
/// check that stands in for a build phase. Run `scripts/acknowledgements.sh` when it fails.
@Suite struct AcknowledgementsTests {
    private static let packageResolved = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "../../Package.resolved")
        .standardized
    /// What Xcode builds the app with; it pins separately from the kit, so it can drift.
    private static let appPackageResolved = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "../../../App/Collective.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        .standardized

    private func text(_ resource: LocalizedStringResource) -> String { String(localized: resource) }

    /// The kit's pins and the packages only the app links (Sparkle), as the script reads them.
    @Test func listsEveryPinnedPackageWithItsVersionAndNothingElse() throws {
        let kit = try PackagePin.parse(Data(contentsOf: Self.packageResolved))
        let app = try PackagePin.parse(Data(contentsOf: Self.appPackageResolved))
        #expect(!kit.isEmpty)
        let pins = kit + app.filter { pin in !kit.contains { $0.identity == pin.identity } }
        #expect(Acknowledgements.bundled.packageMismatches(with: pins) == [])
    }

    /// The app resolves the kit's packages itself and may drift from the kit's pins.
    @Test func theAppsPinsMatchTheListToo() throws {
        let pins = try PackagePin.parse(Data(contentsOf: Self.appPackageResolved))
        #expect(!pins.isEmpty)
        #expect(Acknowledgements.bundled.packageMismatches(with: pins).filter {
            if case .unpinned = $0 { false } else { true }
        } == [])
    }

    @Test func reportsABumpedAnUnlistedAndAnUnpinnedPackage() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolved = directory.appending(path: "Package.resolved")
        try Data("""
        {
          "pins" : [
            { "identity" : "grdb.swift", "kind" : "remoteSourceControl", "location" : "https://github.com/groue/GRDB.swift",
              "state" : { "revision" : "b83108d10f42680d78f23fe4d4d80fc88dab3212", "version" : "7.11.1" } },
            { "identity" : "swift-cmark", "kind" : "remoteSourceControl", "location" : "https://github.com/swiftlang/swift-cmark.git",
              "state" : { "revision" : "08ddb528923cc1a6527e02b7a1aee9e516ca749a", "version" : "0.9.0" } },
            { "identity" : "swift-markdown", "kind" : "remoteSourceControl", "location" : "https://github.com/swiftlang/swift-markdown",
              "state" : { "revision" : "25cb61d3482054b09ae76ca4f281b1bfe7fe5a43", "version" : "0.9.0" } },
            { "identity" : "yams", "kind" : "remoteSourceControl", "location" : "https://github.com/jpsim/Yams.git",
              "state" : { "revision" : "a27b21e0c81c5bf42049b897a62aaf387e80f279", "version" : "6.3.0" } },
            { "identity" : "swift-collections", "kind" : "remoteSourceControl", "location" : "https://github.com/apple/swift-collections",
              "state" : { "revision" : "8c0c0a8b49e080e54e5e328cc552821ff07cd341", "version" : "1.2.0" } }
          ],
          "version" : 3
        }
        """.utf8).write(to: resolved)

        let pins = try PackagePin.parse(Data(contentsOf: resolved))

        #expect(Acknowledgements.bundled.packageMismatches(with: pins) == [
            .version(identity: "yams", listed: "6.2.2", pinned: "6.3.0"),
            .unlisted(identity: "swift-collections"),
            .unpinned(identity: "yyjson"),
            .unpinned(identity: "sparkle"),
        ])
    }

    @Test func everyEntryCarriesALicenseText() {
        let entries = Acknowledgements.bundled.sections.flatMap(\.entries)
        #expect(!entries.isEmpty)
        for entry in entries {
            #expect(!entry.texts.isEmpty, "\(entry.name)")
            #expect(entry.texts.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, "\(entry.name)")
        }
    }

    @Test func listsTheThreeSectionsOfTheDesignInOrder() {
        let sections = Acknowledgements.bundled.sections
        #expect(sections.map(\.id) == [.libraries, .fontsAndIcons, .colorSchemes])
        #expect(sections.map { text($0.title) } == ["Libraries", "Fonts and icons", "Color schemes"])
        #expect(sections.map { $0.entries.map(\.name) } == [
            ["GRDB.swift", "yyjson", "Swift Markdown", "swift-cmark", "Yams", "Sparkle", "libyaml"],
            ["Lucide", "Lobe Icons", "IBM Plex Sans", "IBM Plex Mono"],
            [
                "Ayu", "Catppuccin", "Dracula", "Everforest", "GitHub", "Gruvbox", "Kanagawa", "Material",
                "Nord", "One", "Rosé Pine", "Solarized", "Tokyo Night", "Tomorrow", "Tinted Theming schemes",
            ],
        ])
        #expect(sections[1].entries.map { text($0.versionText) } == ["1.72.0", "1.104.0", "1.1.0", "2.5.0"])
        #expect(sections[2].entries.map(\.schemeCount) == [3, 4, 1, 2, 5, 2, 2, 4, 1, 2, 3, 2, 4, 3, nil])
        #expect(sections[2].entries.map { text($0.versionText) }.suffix(2) == ["3 schemes", "spec-0.11"])
        #expect(sections[2].entries.allSatisfy { $0.spdx == "MIT" })
    }

    /// The scheme families the list credits, without the repository the files come from.
    private var familyEntries: [Acknowledgements.Entry] {
        Acknowledgements.bundled.sections.last?.entries.filter { $0.schemeIDPrefix != nil } ?? []
    }

    /// A scheme dropped into or removed from `Schemes` changes a family's count; the list must
    /// follow, one entry per family of the bundled themes.
    @Test func schemeCountsMatchTheBundledThemesByFamily() {
        let families = Dictionary(grouping: BundledThemes.all) { $0.family ?? "" }
        #expect(families[""] == nil)
        #expect(Set(familyEntries.map(\.name)) == Set(families.keys))
        #expect(familyEntries.count == families.count)
        for entry in familyEntries {
            #expect(entry.schemeCount == families[entry.name]?.count, "\(entry.name)")
        }
    }

    /// The prefixes count by id, so one that also matched another family's id ("one-" and
    /// "one-dark") would credit a scheme twice or to the wrong family.
    @Test func everyBundledThemeIsCountedByExactlyItsFamily() {
        for theme in BundledThemes.all {
            let counting = familyEntries.filter { theme.id.hasPrefix($0.schemeIDPrefix ?? "") }.map(\.name)
            #expect(counting == [theme.family].compactMap(\.self), "\(theme.id)")
        }
    }

    /// Families alphabetically ignoring case and accents, so "Rosé Pine" sits between "One"
    /// and "Solarized"; the files' repository closes the list.
    @Test func listsTheSchemeFamiliesAlphabeticallyAndTheirRepositoryLast() throws {
        let entries = try #require(Acknowledgements.bundled.sections.last).entries
        #expect(entries.last?.name == "Tinted Theming schemes")
        #expect(entries.last?.schemeIDPrefix == nil)
        let names = entries.dropLast().map(\.name)
        #expect(names == names.sorted {
            $0.compare($1, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")) == .orderedAscending
        })
    }

    /// One goes back to two Atom repositories and ships both texts; Gruvbox has no license file
    /// upstream, so its text names where MIT comes from and claims no copyright.
    @Test func oneShipsBothTextsAndGruvboxTheMITTextWithoutACopyright() throws {
        let one = try #require(familyEntries.first { $0.name == "One" })
        #expect(one.texts.map(\.file) == ["one-dark-syntax-LICENSE", "one-light-syntax-LICENSE"])
        #expect(one.url.absoluteString == "https://github.com/atom/one-dark-syntax")
        let gruvbox = try #require(familyEntries.first { $0.name == "Gruvbox" })
        #expect(gruvbox.texts.count == 1)
        #expect(gruvbox.texts[0].text.hasPrefix(
            "No license file upstream; README.md and package.json of morhetz/gruvbox name MIT.\n\nPermission is hereby granted"
        ))
        #expect(!gruvbox.texts[0].text.contains("Copyright ("))
        for entry in familyEntries where entry.name != "Gruvbox" {
            #expect(entry.texts.allSatisfy { $0.text.contains("Copyright (") }, "\(entry.name)")
        }
    }

    @Test func swiftMarkdownShipsItsNoticeAndCmarkItsWholeCopying() throws {
        let entries = Acknowledgements.bundled.sections.flatMap(\.entries)
        let markdown = try #require(entries.first { $0.name == "Swift Markdown" })
        #expect(markdown.texts.map(\.file) == ["LICENSE.txt", "NOTICE.txt"])
        let cmark = try #require(entries.first { $0.name == "swift-cmark" })
        #expect(cmark.texts.map(\.file) == ["COPYING"])
        #expect(cmark.texts[0].text.contains("houdini"))
        #expect(cmark.texts[0].text.contains("utf8proc"))
    }

    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "../../..")
        .standardized

    private struct ShippedText: Decodable, Equatable {
        var file: String
        var text: String
    }

    private struct Generated: Decodable {
        struct Section: Decodable {
            var id: String
            var entries: [Entry]
        }
        struct Entry: Decodable {
            var name: String
            var spdx: String
            var license: String
            var url: String
            var package: String?
            var schemeIDPrefix: String?
            var version: String?
            var texts: [ShippedText]
        }
        var sections: [Section]
    }

    private struct Maintained: Decodable {
        struct Section: Decodable {
            var id: String
            var entries: [Entry]
        }
        struct Entry: Decodable {
            var name: String
            var spdx: String
            var url: String
            var package: String?
            var bundledIn: String?
            var schemeIDPrefix: String?
            var version: String?
            var files: [String]?
        }
        var licenses: [String: String]
        var sections: [Section]
    }

    private func readMaintainedAndShipped() throws -> (Maintained, Generated) {
        let decoder = JSONDecoder()
        let maintained = try decoder.decode(Maintained.self, from: Data(contentsOf: Self.repository
            .appending(path: "CollectiveKit/Acknowledgements/acknowledgements.json")))
        let shipped = try decoder.decode(Generated.self, from: Data(contentsOf: Self.repository
            .appending(path: "CollectiveKit/Sources/CollectiveKit/Resources/Acknowledgements.json")))
        return (maintained, shipped)
    }

    /// What the script copies from the maintained file must reach the shipped one too: an entry
    /// renamed, reordered, relicensed or moved to another URL there is drift like an edited text.
    /// Package versions and scheme counts are computed; the tests above check those.
    @Test func theShippedEntriesAreTheMaintainedOnesInOrder() throws {
        let (maintained, shipped) = try readMaintainedAndShipped()
        #expect(shipped.sections.map(\.id) == maintained.sections.map(\.id), "run scripts/acknowledgements.sh")
        for (section, generated) in zip(maintained.sections, shipped.sections) {
            #expect(generated.entries.map(\.name) == section.entries.map(\.name), "\(section.id): run scripts/acknowledgements.sh")
            for (entry, match) in zip(section.entries, generated.entries) where entry.name == match.name {
                let hint: Comment = "\(entry.name): run scripts/acknowledgements.sh"
                #expect(match.spdx == entry.spdx, hint)
                #expect(match.license == maintained.licenses[entry.spdx], hint)
                #expect(match.url == entry.url, hint)
                #expect(match.package == entry.package, hint)
                #expect(match.schemeIDPrefix == entry.schemeIDPrefix, hint)
                if let host = entry.bundledIn {
                    // The host's version comes from its pin; its name is maintained.
                    let hostName = maintained.sections.flatMap(\.entries).first { $0.package == host }?.name
                    #expect(hostName.map { match.version?.hasPrefix("in \($0) ") == true } == true, hint)
                } else if entry.package == nil, entry.schemeIDPrefix == nil {
                    #expect(match.version == entry.version, hint)
                }
            }
        }
    }

    /// A license text edited in `Acknowledgements/texts` or in a bundled resource folder must
    /// reach the shipped file, which only `scripts/acknowledgements.sh` writes. Texts are compared
    /// as the script reads them: named by the file's last path component, newlines trimmed at
    /// both ends and nothing else.
    @Test func theShippedTextsAreTheMaintainedFilesAsTheScriptReadsThem() throws {
        let (maintained, shipped) = try readMaintainedAndShipped()
        var checked = 0
        for section in maintained.sections {
            for entry in section.entries {
                guard let files = entry.files else { continue }
                let expected = try files.map { relative in
                    let text = try String(contentsOf: Self.repository.appending(path: relative), encoding: .utf8)
                    return ShippedText(
                        file: URL(fileURLWithPath: relative).lastPathComponent,
                        text: String(text.trimmingPrefix { $0 == "\n" }.reversed().drop { $0 == "\n" }.reversed())
                    )
                }
                let match = shipped.sections.first { $0.id == section.id }?.entries.first { $0.name == entry.name }
                #expect(match?.texts == expected, "\(entry.name): run scripts/acknowledgements.sh")
                checked += 1
            }
        }
        #expect(checked > 0)
    }

    @Test func aSingleSchemeReadsInTheSingular() {
        #expect(text(Acknowledgements.schemeCountText(1)) == "1 scheme")
        #expect(text(Acknowledgements.schemeCountText(5)) == "5 schemes")
    }

    @Test func theSheetHeadsEachTextWithNameVersionAndLicense() throws {
        let documents = Acknowledgements.bundled.licenseDocuments
        #expect(documents.first?.header == "GRDB.swift 7.11.1 · MIT License")
        #expect(documents.map(\.header).contains("libyaml in Yams 6.2.2 · MIT License"))
        #expect(documents.map(\.header).contains("IBM Plex Mono 2.5.0 · SIL Open Font License 1.1"))
        let markdown = try #require(documents.first { $0.header.hasPrefix("Swift Markdown") })
        #expect(markdown.header == "Swift Markdown 0.9.0 · Apache License 2.0")
        #expect(markdown.text.contains("Apache License"))
        #expect(markdown.text.contains("The Swift Markdown Project"))
    }
}
