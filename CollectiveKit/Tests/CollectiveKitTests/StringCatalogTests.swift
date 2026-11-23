import Foundation
import Testing
@testable import CollectiveKit
@testable import CollectiveUI

/// The catalogs are hand-written JSON; these checks keep them translatable:
/// every text has an English value and a translator comment, plurals are
/// complete, and the Borg allusions carry the note that preserves their tone.
@Suite("String catalogs")
struct StringCatalogTests {
    private struct Entry {
        let key: String
        let comment: String?
        let english: [String: Any]?
    }

    private static let catalogs = ["CollectiveKit", "CollectiveUI"]

    private static func load(_ target: String) throws -> (language: String?, entries: [Entry]) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "../../Sources/\(target)/Resources/Localizable.xcstrings")
            .standardized
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try #require(json?["strings"] as? [String: [String: Any]])
        let entries = strings.map { key, value in
            let localizations = value["localizations"] as? [String: Any]
            return Entry(key: key, comment: value["comment"] as? String, english: localizations?["en"] as? [String: Any])
        }
        return (json?["sourceLanguage"] as? String, entries)
    }

    private static func plural(_ entry: Entry) -> [String: Any]? {
        (entry.english?["variations"] as? [String: Any])?["plural"] as? [String: Any]
    }

    private static func value(of unit: Any?) -> String? {
        ((unit as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
    }

    @Test("source language is English", arguments: catalogs)
    func sourceLanguage(target: String) throws {
        #expect(try Self.load(target).language == "en")
    }

    @Test("every key has an English value and a comment", arguments: catalogs)
    func valuesAndComments(target: String) throws {
        for entry in try Self.load(target).entries {
            let hasValue = Self.value(of: entry.english) != nil
                || (Self.plural(entry)?.values.allSatisfy { Self.value(of: $0) != nil } ?? false)
            #expect(hasValue, "\(entry.key): no English value")
            #expect(!(entry.comment ?? "").isEmpty, "\(entry.key): missing comment")
        }
    }

    @Test("plural entries have one and other", arguments: catalogs)
    func pluralVariants(target: String) throws {
        for entry in try Self.load(target).entries {
            guard let plural = Self.plural(entry) else { continue }
            #expect(plural["one"] != nil && plural["other"] != nil, "\(entry.key): needs one and other")
        }
    }

    @Test("counts in a single-count key are plural", arguments: catalogs)
    func countsArePlural(target: String) throws {
        for entry in try Self.load(target).entries where entry.key.contains("%lld") {
            // Keys joining several numbers ("%lld h %lld min") cannot vary on one count.
            let isSingleCount = entry.key.components(separatedBy: "%").count == 2
            guard isSingleCount, !isMeasurementUnit(entry.key) else { continue }
            #expect(Self.plural(entry) != nil, "\(entry.key): count without plural variants")
        }
    }

    /// Abbreviated units such as "%lld h" read the same for any count.
    private func isMeasurementUnit(_ key: String) -> Bool {
        let rest = key.replacingOccurrences(of: "%lld", with: "").trimmingCharacters(in: .whitespaces)
        return rest.count <= 3 && !rest.contains(" ")
    }

    @Test("Borg allusions are explained to translators")
    func borgComments() throws {
        let ui = try Self.load("CollectiveUI").entries
        let expected: [(entries: [Entry], key: (String) -> Bool, name: String)] = [
            (ui, { $0 == "The Collective is dormant." }, "dormant"),
        ]
        for item in expected {
            let entry = try #require(item.entries.first { item.key($0.key) }, "\(item.name): key missing")
            #expect(entry.comment?.contains("Borg") == true, "\(item.name): comment must mention Borg")
        }
    }

    @Test("the kit's own plural keys resolve through the CollectiveKit catalog")
    func kitKeysResolve() {
        let en = Locale(identifier: "en")
        let b = Bundle.collectiveKit
        let cases: [(String, (Int) -> String, String, String)] = [
            ("done", { String(localized: "\($0) done", bundle: b, locale: en) }, "1 done", "2 done"),
            ("working", { String(localized: "\($0) working", bundle: b, locale: en) }, "1 working", "2 working"),
            ("lost contact", { String(localized: "\($0) lost contact", bundle: b, locale: en) },
             "1 lost contact", "2 lost contact"),
            ("archived", { String(localized: "\($0) archived", bundle: b, locale: en) }, "1 archived", "2 archived"),
            ("finished sessions archived", { String(localized: "\($0) finished sessions archived", bundle: b, locale: en) },
             "1 finished session archived", "2 finished sessions archived"),
            ("need you", { String(localized: "\($0) need you", bundle: b, locale: en) }, "1 needs you", "2 need you"),
            ("waiting for a type", { String(localized: "\($0) waiting for a type", bundle: b, locale: en) },
             "1 waiting for a type", "2 waiting for a type"),
            ("subagents", { String(localized: "\($0) subagents", bundle: b, locale: en) }, "1 subagent", "2 subagents"),
            ("subagents, all done", { String(localized: "\($0) subagents, all done", bundle: b, locale: en) },
             "1 subagent, done", "2 subagents, all done"),
            ("subagents working", { String(localized: "\($0) subagents working", bundle: b, locale: en) },
             "1 subagent working", "2 subagents working"),
            ("subagents done", { String(localized: "\($0) subagents done", bundle: b, locale: en) },
             "1 subagent done", "2 subagents done"),
            ("show idle", { String(localized: "Show \($0) idle", bundle: b, locale: en) }, "Show 1 idle", "Show 2 idle"),
            ("has questions", { String(localized: "has \($0) questions", bundle: b, locale: en) }, "has a question", "has 2 questions"),
            ("more", { String(localized: "+\($0) more", bundle: b, locale: en) }, "+1 more", "+2 more"),
        ]
        for (name, make, one, other) in cases {
            #expect(make(1) == one, "\(name)")
            #expect(make(2) == other, "\(name)")
        }
    }

    /// The Active tab's VoiceOver label varies both counts in number each on
    /// their own, through the catalog's substitutions.
    @Test func theActiveTabsTwoCountsResolveTheirPluralsApart() {
        let en = Locale(identifier: "en")
        let b = Bundle.collectiveKit
        func label(_ sessions: Int, _ needYou: Int) -> String {
            String(localized: "\("Active"), \(sessions) sessions, \(needYou) need you", bundle: b, locale: en)
        }
        #expect(label(1, 1) == "Active, 1 session, 1 needs you")
        #expect(label(2, 1) == "Active, 2 sessions, 1 needs you")
        #expect(label(3, 2) == "Active, 3 sessions, 2 need you")
    }

    /// Idle's and Finished's VoiceOver label varies the count in number,
    /// with the tab's tooltip after it.
    @Test func theTabWithATooltipResolvesItsCountsPlural() {
        let en = Locale(identifier: "en")
        let b = Bundle.collectiveKit
        func label(_ sessions: Int) -> String {
            String(localized: "\("Finished"), \(sessions) sessions, \("Cleared after 10 min")", bundle: b, locale: en)
        }
        #expect(label(1) == "Finished, 1 session, Cleared after 10 min")
        #expect(label(2) == "Finished, 2 sessions, Cleared after 10 min")
    }
}
