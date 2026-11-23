import Foundation

/// A JSON value as Python's `json` module sees it, which is what the reference
/// interpreter (subspace `tools/model/apply.py`) works on.
///
/// Parsed with yyjson and walked into this enum, rather than with
/// `JSONSerialization` or `JSONDecoder`: both go through `NSNumber` or lenient
/// numeric decoding, which blurs `true` with `1` and `1` with `1.0`. Mapping
/// `type` checks depend on that difference. Like Python, a number literal
/// without fraction or exponent is an `integer`, everything else a `number`.
/// (Python 3.11+ `json.loads` rejects integer literals over 4300 digits; they
/// are accepted here as `bigInteger`.)
///
/// Strings compare by code points, as in Python: Swift's own `String ==` treats
/// NFC "é" and NFD "e" + U+0301 as equal, Python does not.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    /// An integer outside `Int64`, kept exact like Python does: its decimal
    /// digits with an optional leading `-`. The parser never puts a value that
    /// fits `integer` here.
    case bigInteger(String)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([JSONKey: JSONValue])

    /// Parses one JSON document, strictly as RFC 8259 defines it: no `NaN` or
    /// `Infinity`, no comments, no trailing commas. Nesting deeper than 512
    /// levels is rejected with a `JSONParseError`. A lone surrogate escape
    /// (`\ud800` without its partner) becomes U+FFFD.
    public init(data: Data) throws {
        self = try JSONReader.read(data)
    }

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        lhs.matches(rhs) { a, b in
            switch (a, b) {
            case (.null, .null): true
            case let (.bool(a), .bool(b)): a == b
            case let (.integer(a), .integer(b)): a == b
            case let (.bigInteger(a), .bigInteger(b)): a == b
            case let (.number(a), .number(b)): a == b
            case let (.string(a), .string(b)): JSONKey(a) == JSONKey(b)
            default: false
            }
        }
    }

    /// Equality for golden-file comparison, close to Python's `==`: an integer
    /// equals a number of the same value (`1 == 1.0`). Unlike Python, where
    /// `True == 1`, a bool stays a bool.
    public func isSemanticallyEqual(to other: JSONValue) -> Bool {
        matches(other) { a, b in
            switch (a, b) {
            case let (.integer(i), .number(d)), let (.number(d), .integer(i)):
                // Exact like Python: no rounding of large integers through Double.
                Int64(exactly: d) == i
            case let (.bigInteger(digits), .number(d)), let (.number(d), .bigInteger(digits)):
                Self.decimalDigits(of: d) == digits
            default:
                a == b
            }
        }
    }

    /// Whether arrays and objects hold the same elements and keys, all the
    /// way down, and `leavesMatch` holds for every other pair at the same place
    /// (also for an array or object paired with something else).
    ///
    /// Iterative, with the pairs still to compare on a list: recursing would
    /// take one to two kilobytes of stack per level in a debug build, at
    /// `JSONReader.maxDepth` most or more than all of a 512 KB thread stack
    /// (the cooperative pool's).
    private func matches(_ other: JSONValue, leavesMatch: (JSONValue, JSONValue) -> Bool) -> Bool {
        var pending: [(JSONValue, JSONValue)] = []
        var pair = (self, other)
        while true {
            switch pair {
            case let (.array(a), .array(b)):
                guard a.count == b.count else { return false }
                pending.append(contentsOf: zip(a, b))
            case let (.object(a), .object(b)):
                guard a.count == b.count else { return false }
                for (key, value) in a {
                    guard let match = b[key] else { return false }
                    pending.append((value, match))
                }
            default:
                guard leavesMatch(pair.0, pair.1) else { return false }
            }
            guard let next = pending.popLast() else { return true }
            pair = next
        }
    }

    /// The exact decimal digits of a double at least 2^63 in magnitude, the
    /// only doubles a `bigInteger` can equal. All of them are integral.
    private static func decimalDigits(of d: Double) -> String? {
        guard d.isFinite, d.magnitude >= 0x1p63 else { return nil }
        // magnitude = significand * 2^shift, with shift >= 11.
        var significand = UInt64(1) << 52 | d.significandBitPattern
        var digits: [UInt8] = [] // least significant first
        while significand > 0 {
            digits.append(UInt8(significand % 10))
            significand /= 10
        }
        for _ in 0..<(Int(d.exponent) - 52) {
            var carry: UInt8 = 0
            for i in digits.indices {
                let doubled = digits[i] * 2 + carry
                digits[i] = doubled % 10
                carry = doubled / 10
            }
            if carry > 0 { digits.append(carry) }
        }
        return (d < 0 ? "-" : "") + String(digits.reversed().map { Character(Unicode.Scalar($0 + 0x30)) })
    }
}

/// An object key that compares and hashes by code points, as Python's `dict`
/// does. Keys that differ only in Unicode normalization stay distinct, which a
/// `String`-keyed dictionary cannot do. A string literal is a key, so lookups
/// by plain names read like `object["session"]`.
public struct JSONKey: Sendable, Hashable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// The key as read from the document.
    public let string: String

    /// Wraps `string` as a key.
    public init(_ string: String) { self.string = string }
    /// A literal key, so lookups read like `object["session"]`.
    public init(stringLiteral value: String) { self.init(value) }

    // UTF-8 bytes are equal exactly when the code points are.
    public static func == (lhs: JSONKey, rhs: JSONKey) -> Bool {
        lhs.string.utf8.elementsEqual(rhs.string.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        for byte in string.utf8 { hasher.combine(byte) }
        hasher.combine(string.utf8.count)
    }

    /// Code-point order, like Python's `sorted` on strings; UTF-8 byte order
    /// is the same.
    public static func < (lhs: JSONKey, rhs: JSONKey) -> Bool {
        lhs.string.utf8.lexicographicallyPrecedes(rhs.string.utf8)
    }

    public var description: String { string }
}

/// Why `JSONValue(data:)` rejected a document.
public struct JSONParseError: Error, Equatable {
    /// Byte offset into the input where reading stopped, usually the start of
    /// the offending token. For nesting deeper than 512 levels, the offset of
    /// the first `[` or `{` beyond them.
    public let offset: Int
}

extension JSONValue {
    /// Compact JSON text that `init(data:)` reads back as an equal value, so a
    /// value can be stored as text and restored exactly. Integers beyond
    /// `Int64` keep their digits, doubles use Swift's shortest round-trip form.
    /// Object keys are sorted by code points, so equal values give identical
    /// bytes. Strings are written as UTF-8 unchanged except for the escapes
    /// RFC 8259 requires; no Unicode normalization, so keys that differ only
    /// there stay distinct.
    ///
    /// A literal beyond the double range (`1e400`) parses to infinity, so
    /// infinity is written as `1e999` (`-1e999`), a valid JSON number that
    /// reads back as the same infinity. NaN, which the parser never produces
    /// (JSON has no literal for it), is written as `null` to keep the output
    /// valid JSON.
    func serialized() -> Data {
        var writer = Writer()
        writer.write(self)
        return Data(writer.bytes)
    }
}

/// Builds the output of `JSONValue.serialized()` in one byte buffer: it runs
/// once per stored event, so no intermediate strings per value.
///
/// Iterative, with one `Level` per open array or object: recursing would take
/// about 1.5 KB of stack per level in a debug build, and a 512 KB thread stack
/// (the cooperative pool's) would run out before `JSONReader.maxDepth`.
private struct Writer {
    var bytes: [UInt8] = []

    /// An array or object being written. An object's members are in key
    /// order, so `elements` is empty for it and `members` for an array.
    private struct Level {
        let isObject: Bool
        let elements: [JSONValue]
        let members: [(key: JSONKey, value: JSONValue)]
        /// How many children are written.
        var written = 0
    }

    mutating func write(_ root: JSONValue) {
        var levels: [Level] = []
        open(root, in: &levels)
        // The next child of the innermost level, or its closing bracket.
        while let last = levels.indices.last {
            let index = levels[last].written
            levels[last].written += 1
            if levels[last].isObject {
                guard index < levels[last].members.count else {
                    bytes.append(UInt8(ascii: "}"))
                    levels.removeLast()
                    continue
                }
                let member = levels[last].members[index]
                if index > 0 { bytes.append(UInt8(ascii: ",")) }
                write(member.key.string)
                bytes.append(UInt8(ascii: ":"))
                open(member.value, in: &levels)
            } else {
                guard index < levels[last].elements.count else {
                    bytes.append(UInt8(ascii: "]"))
                    levels.removeLast()
                    continue
                }
                if index > 0 { bytes.append(UInt8(ascii: ",")) }
                open(levels[last].elements[index], in: &levels)
            }
        }
    }

    /// Writes a scalar whole; an array or object only its opening bracket,
    /// its children follow as its level in `levels`.
    private mutating func open(_ value: JSONValue, in levels: inout [Level]) {
        switch value {
        case let .array(elements):
            bytes.append(UInt8(ascii: "["))
            levels.append(Level(isObject: false, elements: elements, members: []))
        case let .object(members):
            bytes.append(UInt8(ascii: "{"))
            levels.append(Level(isObject: true, elements: [], members: members.sorted { $0.key < $1.key }))
        case .null: bytes.append(contentsOf: "null".utf8)
        case let .bool(b): bytes.append(contentsOf: (b ? "true" : "false").utf8)
        case let .integer(i): write(i)
        case let .bigInteger(digits): bytes.append(contentsOf: digits.utf8)
        case let .number(d):
            // `description` is the shortest text that parses back to the same
            // bits, always with a `.` or an exponent, so it stays a `number`.
            // Infinity has no JSON spelling, but any literal past the double
            // range parses to it.
            if d.isFinite { bytes.append(contentsOf: d.description.utf8) }
            else if d == .infinity { bytes.append(contentsOf: "1e999".utf8) }
            else if d == -.infinity { bytes.append(contentsOf: "-1e999".utf8) }
            else { bytes.append(contentsOf: "null".utf8) }
        case let .string(s): write(s)
        }
    }

    mutating func write(_ integer: Int64) {
        if integer < 0 { bytes.append(UInt8(ascii: "-")) }
        var magnitude = integer.magnitude
        let start = bytes.count
        repeat {
            bytes.append(UInt8(ascii: "0") + UInt8(magnitude % 10))
            magnitude /= 10
        } while magnitude > 0
        bytes[start...].reverse()
    }

    /// Escapes `"`, `\` and U+0000–U+001F, the characters RFC 8259 requires
    /// escaped; every other byte is copied as is.
    mutating func write(_ string: String) {
        bytes.append(UInt8(ascii: "\""))
        let utf8 = string.utf8
        // Most strings need no escape: copy them in one go.
        if !utf8.contains(where: Self.needsEscape) {
            bytes.append(contentsOf: utf8)
        } else {
            for byte in utf8 {
                guard Self.needsEscape(byte) else { bytes.append(byte); continue }
                bytes.append(UInt8(ascii: "\\"))
                switch byte {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"): bytes.append(byte)
                case 0x08: bytes.append(UInt8(ascii: "b"))
                case 0x0C: bytes.append(UInt8(ascii: "f"))
                case 0x0A: bytes.append(UInt8(ascii: "n"))
                case 0x0D: bytes.append(UInt8(ascii: "r"))
                case 0x09: bytes.append(UInt8(ascii: "t"))
                default:
                    bytes.append(contentsOf: [UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0"),
                                              Self.hex[Int(byte >> 4)], Self.hex[Int(byte & 0x0F)]])
                }
            }
        }
        bytes.append(UInt8(ascii: "\""))
    }

    static let hex = Array("0123456789abcdef".utf8)

    static func needsEscape(_ byte: UInt8) -> Bool {
        byte < 0x20 || byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\")
    }
}
