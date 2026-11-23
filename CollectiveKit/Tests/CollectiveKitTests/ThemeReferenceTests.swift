import Foundation
import Testing
@testable import CollectiveKit

/// The derived roles of every scheme Unimatrix Zero bundles against its reference file, a port of
/// its `theme/reference.rs` (commit 43f1307). This port of the derivation must produce that file
/// byte for byte.
///
/// `Fixtures/unimatrix/roles.json` is Unimatrix's `crates/core/src/theme/reference/roles.json`
/// at commit 43f1307, copied unchanged; Unimatrix generates it with
/// `UNIMATRIX_UPDATE_REFERENCE=1 cargo test -p unimatrix-core theme::reference`. It covers all
/// of Unimatrix's schemes, copied to `Fixtures/unimatrix/schemes` (`FixtureThemes`); the app
/// bundles all of them, its folder kept identical to the fixture's by
/// `schemesFolderIsTheFixtureFolder`. When Unimatrix changes the derivation or a scheme, copy
/// the regenerated file and the schemes here (and to `Resources/Schemes`) and make this suite
/// pass again; never edit the copies by hand.
///
/// `coversEveryFixtureSchemeRoleAndHueAndNothingElse` also stands in for derive.rs'
/// `roles_are_exactly_the_contract_table`, which reads a document this repo does not have.
@Suite struct ThemeReferenceTests {
    private static let fixture = Bundle.module.resourceURL!
        .appendingPathComponent("Fixtures/unimatrix/roles.json")

    private static func committed() throws -> Data {
        try Data(contentsOf: fixture)
    }

    // MARK: Writing the file

    /// `#rrggbb`, with the alpha byte appended only when the role is not opaque.
    private func hex(_ color: ThemeColor) -> String {
        let rgb = String(format: "#%02x%02x%02x", color.r, color.g, color.b)
        return color.a == 255 ? rgb : rgb + String(format: "%02x", color.a)
    }

    /// The slot as spelled in the YAML, or the literal for a mixed orange.
    private func sourceName(_ source: HueSource) -> String {
        switch source {
        case .slot(let key): key.name
        case .mixed: "mix(red, yellow)"
        }
    }

    private func appearanceName(_ appearance: ThemeAppearance) -> String {
        switch appearance {
        case .light: "light"
        case .dark: "dark"
        }
    }

    /// The file as it should be: schemes by id, hues in `Hue.allCases` order, roles in
    /// `ThemeRole.allCases` order, pretty-printed with a trailing newline.
    private func content() -> String {
        let schemes = zip(FixtureThemes.all, FixtureThemes.schemes).map { theme, bundled in
            #expect(theme.id == bundled.id)
            let scheme = bundled.scheme
            let naming = ThemeFamily.naming(bundled.id)
            #expect(naming != nil, "scheme \(bundled.id) has no entry in ThemeFamily")
            let pickedHues = pickHues(scheme.palette)
            let hues = Hue.allCases.map { hue in
                let picked = pickedHues[hue]
                return (String(describing: hue), JSON.object([
                    ("color", .string(hex(ThemeColor(picked.color)))),
                    ("source", .string(sourceName(picked.source))),
                ]))
            }
            let roles = ThemeRole.allCases.map { role in (role.name, JSON.string(hex(theme.roles[role]))) }
            return JSON.object([
                ("file", .string("\(bundled.id).yaml")),
                ("name", .string(theme.name)),
                ("family", naming.map { .string($0.family) } ?? .null),
                ("short_name", naming.map { .string($0.shortName) } ?? .null),
                ("high_contrast", naming.map { .bool($0.contrast == .high) } ?? .null),
                ("author", theme.author.map(JSON.string) ?? .null),
                ("variant", scheme.variant.map { .string(appearanceName($0)) } ?? .null),
                ("appearance", .string(appearanceName(scheme.appearance))),
                ("hues", .object(hues)),
                ("roles", .object(roles)),
            ])
        }
        return JSON.object([("schemes", .array(schemes))]).pretty() + "\n"
    }

    // MARK: Tests

    @Test func namesTheSourceOfAMixedOrange() throws {
        // The file backs this spelling only while a bundled scheme mixes orange (Tokyo Night
        // Moon, Rosé Pine, Rosé Pine Moon); this pins it on a palette of its own.
        var colors = Array(repeating: try SRGB.parse("#808080"), count: PaletteKey.all.count)
        colors[PaletteKey.all.firstIndex(of: .base08)!] = try SRGB.parse("#e03030")
        colors[PaletteKey.all.firstIndex(of: .base0A)!] = try SRGB.parse("#d0c000")
        let picked = pickHueWithSource(Palette(colors: colors), .orange)
        #expect(sourceName(picked.source) == "mix(red, yellow)")
    }

    @Test func spellsColorsInLowercaseWithAlphaOnlyWhenNotOpaque() {
        #expect(hex(.rgb(0x8231e8)) == "#8231e8")
        #expect(hex(.rgba(0xd20f39, alpha: 41)) == "#d20f3929")
        #expect(hex(.rgba(0xabcdef, alpha: 0)) == "#abcdef00")
    }

    /// No bundled name or author needs escaping, so the file cannot back the writer's escaping.
    @Test func escapesStringsAsSerdeJSONDoes() {
        let text = "say \"hi\"\\ a/b\u{01}\u{1f}\n\t\u{08}\u{0C}\r é"
        #expect(JSON.string(text).pretty() == #""say \"hi\"\\ a/b\u0001\u001f\n\t\b\f\r é""#)
    }

    @Test func matchesTheCommittedFile() throws {
        let expected = content()
        let committed = try Self.committed()
        let committedText = String(decoding: committed, as: UTF8.self)
        let line = zip(expected.split(separator: "\n", omittingEmptySubsequences: false),
                       committedText.split(separator: "\n", omittingEmptySubsequences: false))
            .prefix { $0 == $1 }
            .count + 1
        #expect(
            Data(expected.utf8) == committed,
            "\(Self.fixture.lastPathComponent) differs from line \(line); copy the regenerated file from Unimatrix or fix the port"
        )
    }

    @Test func coversEveryFixtureSchemeRoleAndHueAndNothingElse() throws {
        let file = try #require(try JSONSerialization.jsonObject(with: Self.committed()) as? [String: Any])
        let schemes = try #require(file["schemes"] as? [[String: Any]])
        let files = schemes.map { $0["file"] as? String }
        #expect(files == FixtureThemes.ids.map { "\($0).yaml" })

        let roles = Set(ThemeRole.allCases.map(\.name))
        let hues = Set(Hue.allCases.map { String(describing: $0) })
        for scheme in schemes {
            let name = scheme["file"] as? String ?? "?"
            let keys = { (field: String) in Set((scheme[field] as? [String: Any])?.keys.map { $0 } ?? []) }
            #expect(keys("roles") == roles, "\(name)")
            #expect(keys("hues") == hues, "\(name)")
        }
    }

    @Test func carriesTheFamilyShortNameAndContrastOfEveryScheme() throws {
        let file = try #require(try JSONSerialization.jsonObject(with: Self.committed()) as? [String: Any])
        let schemes = try #require(file["schemes"] as? [[String: Any]])
        for scheme in schemes {
            let fileName = try #require(scheme["file"] as? String)
            let id = String(fileName.dropLast(".yaml".count))
            let naming = try #require(ThemeFamily.naming(id), "\(id)")
            #expect(scheme["family"] as? String == naming.family, "\(id)")
            #expect(scheme["short_name"] as? String == naming.shortName, "\(id)")
            #expect(scheme["high_contrast"] as? Bool == (naming.contrast == .high), "\(id)")
        }
        let frappe = try #require(schemes.first { $0["file"] as? String == "catppuccin-frappe.yaml" })
        #expect(frappe["family"] as? String == "Catppuccin")
        #expect(frappe["short_name"] as? String == "Frappé")
    }
}

/// The JSON the reference file holds, written as serde_json's `to_string_pretty` writes it:
/// objects keep the order their entries were given in, unlike `JSONSerialization`.
private indirect enum JSON {
    case string(String)
    case bool(Bool)
    case null
    case object([(String, JSON)])
    case array([JSON])

    func pretty(indent: Int = 0) -> String {
        let inner = String(repeating: "  ", count: indent + 1)
        let outer = String(repeating: "  ", count: indent)
        switch self {
        case .string(let text):
            return Self.quoted(text)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        case .object(let entries):
            if entries.isEmpty { return "{}" }
            let lines = entries.map { key, value in inner + Self.quoted(key) + ": " + value.pretty(indent: indent + 1) }
            return "{\n" + lines.joined(separator: ",\n") + "\n" + outer + "}"
        case .array(let values):
            if values.isEmpty { return "[]" }
            let lines = values.map { inner + $0.pretty(indent: indent + 1) }
            return "[\n" + lines.joined(separator: ",\n") + "\n" + outer + "]"
        }
    }

    /// serde_json's escaping: quote, backslash and the control characters below 0x20, short
    /// forms where JSON has them; `/` and everything else as is.
    private static func quoted(_ text: String) -> String {
        var quoted = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\u{08}": quoted += "\\b"
            case "\u{0C}": quoted += "\\f"
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"
            case _ where scalar.value < 0x20: quoted += String(format: "\\u%04x", scalar.value)
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }
}
