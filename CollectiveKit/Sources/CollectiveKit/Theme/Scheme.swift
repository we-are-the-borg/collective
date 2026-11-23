import Foundation
import Yams

// Reads a base16 or base24 scheme in the tinted-theming YAML format, a port of Unimatrix Zero's
// `theme/scheme.rs` (commit 43f1307). The scheme is only input; roles are derived from it.
// Unimatrix reads YAML with saphyr (YAML 1.2 core schema); here Yams composes the nodes and
// scalars follow saphyr's core-schema typing by style and text. Known differences, which only
// touch error paths and unusual custom schemes, never the bundled files:
// - Explicit tags are ignored both ways: a core tag saphyr honours (`name: !!str 123` is the
//   name "123" there, `missingName` here) or rejects (`!!bool yes` is a bad value there, a
//   string here), and a non-core tag (`name: !x "Foo"` or `palette: !x {…}` is rejected there
//   as missing name/palette, accepted here).
// - Yams detects duplicate keys by text plus YAML 1.1 tag; saphyr compares parsed values
//   (`0x1` next to `1` is a duplicate only there).
// - The `invalidYAML` cause text comes from Yams/libyaml, not saphyr's `ScanError` message.
// - A blank name is checked per grapheme with `Character.isWhitespace`, Rust's `trim()` works
//   per scalar (a space plus a combining mark is a name there, `missingName` here).
// - Yams expands aliases without saphyr's 100,000-node limit.
// - `describe` may print large or tiny floats in exponent form, and quotes strings escaping
//   control characters only, not the other non-printable characters or a leading grapheme
//   extender that Rust's `{:?}` escapes.

/// A palette slot, spelled in `rawValue` as the YAML keys are.
enum PaletteKey: String, CaseIterable, Sendable {
    case base00, base01, base02, base03, base04, base05, base06, base07
    case base08, base09, base0A, base0B, base0C, base0D, base0E, base0F
    case base10, base11, base12, base13, base14, base15, base16, base17

    /// Every base24 slot, in palette order.
    static let all: [PaletteKey] = allCases

    /// The slots a base16 scheme has; the first 16 of `all`.
    static let base16Keys: [PaletteKey] = Array(all.prefix(16))

    /// The key as written in the YAML, e.g. `base0A`.
    var name: String { rawValue }

    fileprivate var index: Int { Self.all.firstIndex(of: self)! }
}

/// All 24 colors, whatever the source system, so the derivation never asks which one it was.
struct Palette: Sendable, Equatable {
    private var colors: [SRGB]

    /// A palette from colors in `PaletteKey.all` order; `readPalette` builds palettes this way too.
    init(colors: [SRGB]) {
        precondition(colors.count == PaletteKey.all.count, "a palette has 24 colors")
        self.colors = colors
    }

    subscript(key: PaletteKey) -> SRGB {
        colors[key.index]
    }
}

/// The official fallback for reading a base16 scheme as base24: each extra slot and the base16
/// slot it copies.
private let base24Fallback: [(PaletteKey, PaletteKey)] = [
    (.base10, .base00),
    (.base11, .base00),
    (.base12, .base08),
    (.base13, .base0A),
    (.base14, .base0B),
    (.base15, .base0C),
    (.base16, .base0D),
    (.base17, .base0E),
]

/// The tinted-theming system a scheme declares.
enum SchemeSystem: Sendable, Equatable {
    case base16
    case base24
}

/// A validated scheme.
struct Scheme: Sendable, Equatable {
    var system: SchemeSystem
    var name: String
    var author: String?
    /// As declared in the file; not derived from the colors, see `appearance`.
    var variant: ThemeAppearance?
    var palette: Palette
}

/// The text is not a valid base16 or base24 scheme; each case names the offending key or
/// value, so a custom theme can say what to fix. A `value` is the parsed YAML value: strings
/// quoted, anything else bare, e.g. `12`.
enum SchemeError: Error, Equatable, CustomStringConvertible {
    /// The YAML reader's own message as the cause.
    case invalidYAML(cause: String)
    /// Several `---` documents; a scheme is one, as abnahme's YAML reader insisted.
    case multipleDocuments
    /// Anything but a mapping at the top: empty text, a list, a plain string.
    case notMapping
    case missingSystem
    case unknownSystem(value: String)
    /// Absent, blank or not a string.
    case missingName
    case invalidAuthor
    case invalidVariant(value: String)
    /// Absent or not a mapping.
    case missingPalette
    case missingColor(key: PaletteKey)
    /// Not a `#rrggbb` string; shorthand `#rgb` included, as in `SRGB.parse`.
    case invalidColor(key: PaletteKey, value: String)

    var description: String {
        switch self {
        case .invalidYAML(let cause): "scheme is not valid YAML: \(cause)"
        case .multipleDocuments: "scheme is not valid YAML: it holds more than one document"
        case .notMapping: "scheme must be a YAML mapping"
        case .missingSystem: "scheme is missing \"system\""
        case .unknownSystem(let value): "unknown scheme system \(value); expected \"base16\" or \"base24\""
        case .missingName: "scheme is missing \"name\""
        case .invalidAuthor: "scheme \"author\" must be a string"
        case .invalidVariant(let value): "invalid scheme variant \(value); expected \"light\" or \"dark\""
        case .missingPalette: "scheme is missing \"palette\""
        case .missingColor(let key): "scheme palette is missing \"\(key.name)\""
        case .invalidColor(let key, let value): "scheme palette \"\(key.name)\" is not a hex color: \(value)"
        }
    }
}

extension Scheme {
    /// Parses and validates a scheme. Unknown extra keys are ignored, at the top and in
    /// `palette`, so upstream additions such as `slug` do not break reading.
    static func parse(_ text: String) throws(SchemeError) -> Scheme {
        let documents: [Node]
        do {
            let parser = try Parser(yaml: text)
            var nodes: [Node] = []
            while let node = try parser.nextRoot() {
                nodes.append(node)
            }
            documents = nodes
        } catch {
            throw .invalidYAML(cause: String(describing: error))
        }
        if documents.count > 1 {
            throw .multipleDocuments
        }
        guard let data = documents.first, case .mapping(let top) = data else {
            throw .notMapping
        }

        let system: SchemeSystem
        guard let systemValue = value(top, "system") else { throw .missingSystem }
        switch string(systemValue) {
        case let text? where equalBytes(text, "base16"): system = .base16
        case let text? where equalBytes(text, "base24"): system = .base24
        default: throw .unknownSystem(value: describe(systemValue))
        }

        guard
            let name = value(top, "name").flatMap(string),
            !name.allSatisfy(\.isWhitespace)
        else { throw .missingName }

        var author: String?
        if let authorValue = value(top, "author") {
            guard let text = string(authorValue) else { throw .invalidAuthor }
            author = text
        }

        var variant: ThemeAppearance?
        if let variantValue = value(top, "variant") {
            switch string(variantValue) {
            case let text? where equalBytes(text, "light"): variant = .light
            case let text? where equalBytes(text, "dark"): variant = .dark
            default: throw .invalidVariant(value: describe(variantValue))
            }
        }

        return Scheme(
            system: system,
            name: name,
            author: author,
            variant: variant,
            palette: try readPalette(value(top, "palette"), system)
        )
    }

    /// The declared `variant`, else light when the background `base00` is brighter than the
    /// text `base05`; many schemes leave `variant` out.
    var appearance: ThemeAppearance {
        if let variant {
            return variant
        }
        let background = relativeLuminance(palette[.base00])
        let text = relativeLuminance(palette[.base05])
        return background > text ? .light : .dark
    }
}

private func readPalette(_ node: Node?, _ system: SchemeSystem) throws(SchemeError) -> Palette {
    guard let node, case .mapping(let palette) = node else { throw .missingPalette }
    let keys = system == .base16 ? PaletteKey.base16Keys : PaletteKey.all
    var colors = Array(repeating: SRGB(0), count: PaletteKey.all.count)
    for key in keys {
        guard let colorValue = value(palette, key.name) else { throw .missingColor(key: key) }
        guard let hex = string(colorValue), let color = try? SRGB.parse(hex) else {
            throw .invalidColor(key: key, value: describe(colorValue))
        }
        colors[key.index] = color
    }
    if system == .base16 {
        for (key, source) in base24Fallback {
            colors[key.index] = colors[source.index]
        }
    }
    return Palette(colors: colors)
}

/// Byte-wise, as Rust compares, so no Unicode equivalence lets anything else in.
private func equalBytes(_ a: String, _ b: String) -> Bool {
    a.utf8.elementsEqual(b.utf8)
}

/// The value under the string key `key`, as saphyr's `as_mapping_get` finds it: a key typed as
/// anything but a string (`1`, `true`) never matches.
private func value(_ mapping: Node.Mapping, _ key: String) -> Node? {
    mapping.first { pair in
        if case .string(let text) = ScalarValue(pair.key) { equalBytes(text, key) } else { false }
    }?.value
}

/// The node's text if it is typed as a string, as saphyr's `as_str`.
private func string(_ node: Node) -> String? {
    if case .string(let text) = ScalarValue(node) { text } else { nil }
}

/// A YAML value typed as saphyr's `Scalar::parse_from_cow_and_metadata` types it (YAML 1.2
/// core schema), not by Yams' YAML 1.1 resolver, where `yes` is a bool and `0o7`, `1:30` and
/// dates are no strings.
private enum ScalarValue {
    case string(String)
    case null
    case bool(Bool)
    case int(Int64)
    case float(Double)
    case list
    case mapping
    case unreadable

    init(_ node: Node) {
        switch node {
        case .scalar(let scalar):
            self = scalar.style == .plain ? Self(plain: scalar.string) : .string(scalar.string)
        case .sequence: self = .list
        case .mapping: self = .mapping
        case .alias: self = .unreadable
        }
    }

    /// saphyr's `Scalar::parse_from_cow`, plus its rule that an empty plain scalar is null.
    private init(plain text: String) {
        if text.isEmpty {
            self = .null
            return
        }
        for (prefix, radix) in [("0x", 16), ("0o", 8)] where text.utf8.starts(with: prefix.utf8) {
            let rest = String(decoding: text.utf8.dropFirst(2), as: UTF8.self)
            // A sign after the prefix (`0x-1`) is no number in the core schema.
            if !rest.hasPrefix("+"), !rest.hasPrefix("-"), let number = Int64(rest, radix: radix) {
                self = .int(number)
                return
            }
        }
        switch text {
        case "~", "null", "Null", "NULL": self = .null
        case "true", "True", "TRUE": self = .bool(true)
        case "false", "False", "FALSE": self = .bool(false)
        default:
            if let number = Int64(text) {
                self = .int(number)
            } else if let number = coreSchemaFloat(text) {
                self = .float(number)
            } else {
                self = .string(text)
            }
        }
    }
}

/// saphyr's `parse_core_schema_fp`: the named infinities and NaN, else what Rust's `f64` parse
/// takes from text with a digit, which is decimal notation only (Swift's would take hex too).
private func coreSchemaFloat(_ text: String) -> Double? {
    switch text {
    case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF": return .infinity
    case "-.inf", "-.Inf", "-.INF": return -.infinity
    case ".nan", ".NaN", ".NAN": return .nan
    default:
        let decimal = text.utf8.allSatisfy { "0123456789+-.eE".utf8.contains($0) }
        guard decimal, text.utf8.contains(where: { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
            return nil
        }
        return Double(text)
    }
}

/// A parsed YAML value for an error message, so `"12"` and `12` read differently.
private func describe(_ node: Node) -> String {
    switch ScalarValue(node) {
    case .string(let text): debugQuoted(text)
    case .null: "null"
    case .bool(let flag): String(flag)
    case .int(let number): String(number)
    case .float(let number): rustDisplay(number)
    case .list: "a list"
    case .mapping: "a mapping"
    case .unreadable: "an unreadable value"
    }
}

/// The text quoted and escaped as Rust's `{:?}` writes a string.
private func debugQuoted(_ text: String) -> String {
    var quoted = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": quoted += "\\\""
        case "\\": quoted += "\\\\"
        case "\n": quoted += "\\n"
        case "\r": quoted += "\\r"
        case "\t": quoted += "\\t"
        case "\0": quoted += "\\0"
        case _ where scalar.properties.generalCategory == .control:
            quoted += "\\u{\(String(scalar.value, radix: 16))}"
        default: quoted.unicodeScalars.append(scalar)
        }
    }
    return quoted + "\""
}

/// A float as Rust's `Display` writes it for the usual cases: whole numbers without `.0`,
/// `inf` and `NaN` spelled the Rust way.
private func rustDisplay(_ number: Double) -> String {
    if number.isNaN {
        return "NaN"
    }
    if number.isInfinite {
        return number < 0 ? "-inf" : "inf"
    }
    if number == number.rounded(), abs(number) < 1e16 {
        return (number.sign == .minus ? "-" : "") + String(Int64(abs(number)))
    }
    return String(number)
}
