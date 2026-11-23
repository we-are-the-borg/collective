import Foundation
import Testing
@testable import CollectiveKit

/// The scheme reader, ported from Unimatrix Zero's `theme/scheme.rs` with the same inputs and
/// expectations, plus the bundled scheme files it derives the themes from.
@Suite struct ThemeSchemeTests {
    static let base24 = #"""

    system: "base24"
    name: "Catppuccin Mocha"
    author: "https://github.com/catppuccin/catppuccin"
    variant: "dark"
    palette:
      base00: "#1e1e2e"
      base01: "#181825"
      base02: "#313244"
      base03: "#45475a"
      base04: "#585b70"
      base05: "#cdd6f4"
      base06: "#f5e0dc"
      base07: "#b4befe"
      base08: "#f38ba8"
      base09: "#fab387"
      base0A: "#f9e2af"
      base0B: "#a6e3a1"
      base0C: "#94e2d5"
      base0D: "#89b4fa"
      base0E: "#cba6f7"
      base0F: "#F2CDCD"
      base10: "#181825"
      base11: "#11111b"
      base12: "#eba0ac"
      base13: "#f5e0dc"
      base14: "#a6e3a1"
      base15: "#89dceb"
      base16: "#74c7ec"
      base17: "#f5c2e7"

    """#

    static let base16 = #"""
    system: "base16"
    name: "Test Scheme"
    palette:
      base00: "#000000"
      base01: "#111111"
      base02: "#222222"
      base03: "#333333"
      base04: "#444444"
      base05: "#555555"
      base06: "#666666"
      base07: "#777777"
      base08: "#880000"
      base09: "#990000"
      base0A: "#aa0000"
      base0B: "#bb0000"
      base0C: "#cc0000"
      base0D: "#dd0000"
      base0E: "#ee0000"
      base0F: "#ff0000"

    """#

    /// The palette as `(key, #rrggbb)` pairs, to compare against the spec's literals.
    private func hexPairs(_ palette: Palette) -> [Pair] {
        PaletteKey.all.map { Pair(key: $0.name, hex: palette[$0].description) }
    }

    struct Pair: Equatable, CustomStringConvertible {
        var key: String
        var hex: String
        var description: String { "\(key): \(hex)" }
    }

    @Test func readsACompleteBase24SchemeWithAll24ColorsInLowerCase() throws {
        let scheme = try Scheme.parse(Self.base24)

        #expect(scheme.system == .base24)
        #expect(scheme.name == "Catppuccin Mocha")
        #expect(scheme.author == "https://github.com/catppuccin/catppuccin")
        #expect(scheme.variant == .dark)
        let expected = [
            ("base00", "#1e1e2e"),
            ("base01", "#181825"),
            ("base02", "#313244"),
            ("base03", "#45475a"),
            ("base04", "#585b70"),
            ("base05", "#cdd6f4"),
            ("base06", "#f5e0dc"),
            ("base07", "#b4befe"),
            ("base08", "#f38ba8"),
            ("base09", "#fab387"),
            ("base0A", "#f9e2af"),
            ("base0B", "#a6e3a1"),
            ("base0C", "#94e2d5"),
            ("base0D", "#89b4fa"),
            ("base0E", "#cba6f7"),
            ("base0F", "#f2cdcd"),
            ("base10", "#181825"),
            ("base11", "#11111b"),
            ("base12", "#eba0ac"),
            ("base13", "#f5e0dc"),
            ("base14", "#a6e3a1"),
            ("base15", "#89dceb"),
            ("base16", "#74c7ec"),
            ("base17", "#f5c2e7"),
        ].map { Pair(key: $0.0, hex: $0.1) }
        #expect(hexPairs(scheme.palette) == expected)
    }

    @Test func readsABase16SchemeAsBase24UsingTheOfficialFallback() throws {
        let scheme = try Scheme.parse(Self.base16)

        #expect(scheme.system == .base16)
        let palette = hexPairs(scheme.palette)
        for (key, hex) in [
            ("base00", "#000000"),
            ("base08", "#880000"),
            ("base0F", "#ff0000"),
            ("base10", "#000000"),
            ("base11", "#000000"),
            ("base12", "#880000"),
            ("base13", "#aa0000"),
            ("base14", "#bb0000"),
            ("base15", "#cc0000"),
            ("base16", "#dd0000"),
            ("base17", "#ee0000"),
        ] {
            #expect(palette.contains(Pair(key: key, hex: hex)), "\(key) should be \(hex)")
        }
        #expect(palette.count == 24)
    }

    @Test func ignoresUnknownExtraKeys() throws {
        let text = "\(Self.base16)\nslug: \"extra\"\n"
            .replacingOccurrences(of: "palette:", with: "palette:\n  base18: \"not a color\"")

        let scheme = try Scheme.parse(text)

        #expect(scheme.name == "Test Scheme")
        // `Palette` has no slot beyond base17, so base18 can only have been skipped.
        #expect(scheme.palette == (try Scheme.parse(Self.base16)).palette)
    }

    @Test func leavesAuthorAndVariantEmptyWhenAbsent() throws {
        let scheme = try Scheme.parse(Self.base16)

        #expect(scheme.author == nil)
        #expect(scheme.variant == nil)
    }

    /// Whether `message` holds every part, in this order, as the spec's regexes ask.
    private func containsInOrder(_ message: String, _ parts: [String]) -> Bool {
        var rest = message[...]
        for part in parts {
            guard let range = rest.range(of: part) else { return false }
            rest = rest[range.upperBound...]
        }
        return true
    }

    struct InvalidCase: CustomTestStringConvertible, Sendable {
        var label: String
        var text: String
        var isExpected: @Sendable (SchemeError) -> Bool
        var parts: [String]
        var testDescription: String { label }
    }

    static let invalidCases: [InvalidCase] = [
        InvalidCase(label: "empty text", text: "", isExpected: { $0 == .notMapping }, parts: ["mapping"]),
        InvalidCase(label: "a list", text: "- base16\n", isExpected: { $0 == .notMapping }, parts: ["mapping"]),
        InvalidCase(label: "a plain string", text: "hello\n", isExpected: { $0 == .notMapping }, parts: ["mapping"]),
        InvalidCase(
            label: "missing system",
            text: base16.replacingOccurrences(of: "system: \"base16\"", with: ""),
            isExpected: { $0 == .missingSystem }, parts: ["\"system\""]
        ),
        InvalidCase(
            label: "unknown system",
            text: base16.replacingOccurrences(of: "\"base16\"", with: "\"base32\""),
            isExpected: { if case .unknownSystem = $0 { true } else { false } }, parts: ["\"base32\""]
        ),
        InvalidCase(
            label: "missing name",
            text: base16.replacingOccurrences(of: "name: \"Test Scheme\"", with: ""),
            isExpected: { $0 == .missingName }, parts: ["\"name\""]
        ),
        InvalidCase(
            label: "blank name",
            text: base16.replacingOccurrences(of: "\"Test Scheme\"", with: "\"  \""),
            isExpected: { $0 == .missingName }, parts: ["\"name\""]
        ),
        InvalidCase(
            label: "non-string author",
            text: "\(base16)author: 42\n",
            isExpected: { $0 == .invalidAuthor }, parts: ["\"author\""]
        ),
        InvalidCase(
            label: "invalid variant",
            text: "\(base16)variant: \"dim\"\n",
            isExpected: { if case .invalidVariant = $0 { true } else { false } }, parts: ["\"dim\""]
        ),
        InvalidCase(
            label: "missing palette",
            text: "system: \"base16\"\nname: \"X\"\n",
            isExpected: { $0 == .missingPalette }, parts: ["\"palette\""]
        ),
        InvalidCase(
            label: "missing key",
            text: base16.replacingOccurrences(of: "  base0C: \"#cc0000\"\n", with: ""),
            isExpected: { $0 == .missingColor(key: .base0C) }, parts: ["\"base0C\""]
        ),
        InvalidCase(
            label: "missing base24 key",
            text: base24.replacingOccurrences(of: "  base17: \"#f5c2e7\"\n", with: ""),
            isExpected: { $0 == .missingColor(key: .base17) }, parts: ["\"base17\""]
        ),
        InvalidCase(
            label: "invalid hex",
            text: base16.replacingOccurrences(of: "\"#dd0000\"", with: "\"#dd00\""),
            isExpected: { if case .invalidColor(key: .base0D, _) = $0 { true } else { false } },
            parts: ["\"base0D\"", "\"#dd00\""]
        ),
        InvalidCase(
            label: "hex without #",
            text: base16.replacingOccurrences(of: "\"#dd0000\"", with: "\"dd0000\""),
            isExpected: { if case .invalidColor(key: .base0D, _) = $0 { true } else { false } },
            parts: ["\"base0D\""]
        ),
        InvalidCase(
            label: "non-string color",
            text: base16.replacingOccurrences(of: "\"#dd0000\"", with: "12"),
            isExpected: { if case .invalidColor(key: .base0D, _) = $0 { true } else { false } },
            parts: ["\"base0D\"", "12"]
        ),
    ]

    @Test(arguments: invalidCases)
    func rejectsInvalidSchemesNamingTheProblem(_ invalid: InvalidCase) {
        let error = #expect(throws: SchemeError.self) { try Scheme.parse(invalid.text) }
        guard let error else { return }
        #expect(invalid.isExpected(error), "got \(error)")
        #expect(containsInOrder(error.description, invalid.parts), "\(error)")
    }

    /// Deviation from abnahme, which expanded `#rgb`: like `SRGB.parse`, only `#rrggbb`.
    @Test func rejectsShortHexColors() {
        let error = #expect(throws: SchemeError.self) {
            try Scheme.parse(Self.base16.replacingOccurrences(of: "\"#000000\"", with: "\"#ABC\""))
        }
        guard let error else { return }

        #expect(
            { if case .invalidColor(key: .base00, _) = error { true } else { false } }(),
            "got \(error)"
        )
        #expect(containsInOrder(error.description, ["\"base00\"", "\"#ABC\""]))
    }

    @Test func turnsAYAMLSyntaxErrorIntoInvalidYAMLWithTheCause() {
        let error = #expect(throws: SchemeError.self) { try Scheme.parse("system: \"base16\nname: [") }
        guard let error else { return }

        guard case .invalidYAML(let cause) = error else {
            Issue.record("got \(error)")
            return
        }
        #expect(error.description.contains("not valid YAML"), "\(error)")
        #expect(!cause.isEmpty)
    }

    @Test func rejectsMoreThanOneYAMLDocumentAsInvalidYAML() {
        let error = #expect(throws: SchemeError.self) { try Scheme.parse("\(Self.base16)---\n\(Self.base16)") }

        #expect(error == .multipleDocuments)
        #expect(error?.description.contains("not valid YAML") == true, "\(String(describing: error))")
    }

    @Test func declaredVariantWinsOverTheColors() throws {
        // base16 is dark by its colors: base00 black, base05 grey.
        let scheme = try Scheme.parse("\(Self.base16)variant: \"light\"\n")

        #expect(scheme.appearance == .light)
    }

    @Test func withoutVariantIsLightWhenBase00IsLighterThanBase05() throws {
        let light = Self.base16
            .replacingOccurrences(of: "\"#000000\"", with: "\"#ffffff\"")
            .replacingOccurrences(of: "\"#555555\"", with: "\"#222222\"")

        #expect(try Scheme.parse(light).appearance == .light)
    }

    @Test func withoutVariantIsDarkOtherwise() throws {
        #expect(try Scheme.parse(Self.base16).appearance == .dark)
        let equal = Self.base16.replacingOccurrences(of: "\"#555555\"", with: "\"#000000\"")
        #expect(try Scheme.parse(equal).appearance == .dark)
    }
}
