import Foundation
internal import yyjson

/// Reads JSON for `JSONValue(data:)`: yyjson parses, a walk turns its tree into
/// a `JSONValue`.
///
/// Strict RFC 8259. Differs from Python's `json.loads` in four places, which
/// matter for a payload, a mapping document and a `parse: json` string alike:
/// - `NaN`, `Infinity` and `-Infinity` are rejected; Python accepts them.
/// - Nesting deeper than `maxDepth` is rejected; Python parses it.
/// - Integer literals over 4300 digits are accepted as `bigInteger`; Python
///   3.11+ rejects them.
/// - Lone surrogate escapes become U+FFFD, since a Swift `String` cannot hold
///   them; Python keeps them. Strings or object keys differing only there are
///   equal here (two such keys collide), distinct in Python.
enum JSONReader {
    /// Integers beyond 64 bits and floats beyond the double range come back
    /// as their literal, so big integers keep their digits. No other flag:
    /// each of the others accepts something RFC 8259 does not.
    private static let flags = YYJSON_READ_BIGNUM_AS_RAW

    /// Protects what consumes a parsed value, not yyjson, which has no depth
    /// limit: a value's deinit still recurses once per level in the runtime
    /// (about 150 KB of stack at this depth in a debug build, under a third of
    /// a 512 KB thread stack), as may an app's code over a `JSONValue`. The
    /// package's own walks (`Walk`, `serialized()`, `==`,
    /// `isSemanticallyEqual`) are iterative. The store reads its mapped
    /// results with `MappingResult.maxDepth`, about twice this: about 300 KB
    /// there, three fifths of the stack. Raising either limit thins that
    /// margin. Python 3.13's `json.loads` goes much deeper (about 10,000
    /// levels, then `RecursionError`), so it parses what is rejected here
    /// between the two. yyjson reads the whole document before the walk applies
    /// the limit, so a huge, deeply nested input is fully materialized (about
    /// 16 bytes per value) before it is rejected: a memory spike, not a crash.
    static let maxDepth = 512

    /// `maxDepth` is the limit for this read; only the store passes another.
    static func read(_ data: Data, maxDepth: Int = maxDepth) throws -> JSONValue {
        try data.withUnsafeBytes { bytes in
            let document = try document(bytes)
            defer { yyjson_doc_free(document) }
            do {
                return try Walk.value(of: yyjson_doc_get_root(document), maxDepth: maxDepth)
            } catch {
                throw JSONParseError(offset: offsetBeyond(maxDepth, in: bytes))
            }
        }
    }

    /// yyjson's document for `bytes`, for the caller to free.
    ///
    /// yyjson rejects a lone surrogate escape under every flag, and Node's
    /// `JSON.stringify` writes one for a string cut in half an emoji: the
    /// whole file would be lost. So a failed read is tried once more with
    /// those escapes replaced; a document yyjson accepts costs nothing extra.
    private static func document(_ bytes: UnsafeRawBufferPointer) throws -> UnsafeMutablePointer<yyjson_doc> {
        do {
            return try readDocument(bytes)
        } catch {
            guard let rewritten = replacingLoneSurrogates(in: bytes) else { throw error }
            return try rewritten.withUnsafeBytes { try readDocument($0) }
        }
    }

    private static func readDocument(_ bytes: UnsafeRawBufferPointer) throws -> UnsafeMutablePointer<yyjson_doc> {
        // Without `YYJSON_READ_INSITU`, yyjson reads a copy of the input: it
        // never writes to `bytes`, and the document does not point into them.
        let input = bytes.baseAddress.map { UnsafeMutableRawPointer(mutating: $0).assumingMemoryBound(to: CChar.self) }
        var error = yyjson_read_err()
        guard let document = yyjson_read_opts(input, bytes.count, flags, nil, &error) else {
            throw JSONParseError(offset: error.pos)
        }
        return document
    }

    /// `bytes` with every lone surrogate escape (`\uD800` to `\uDFFF`, not
    /// part of a high-low pair) rewritten to `\ufffd`, or nil if there is
    /// none. The replacement has the same length, so the offset of a later
    /// error still fits the input. Each backslash takes the next byte with it,
    /// so an escaped backslash followed by `ud83d` stays text. String
    /// boundaries are not tracked: outside a string, a backslash fails the
    /// read anyway.
    static func replacingLoneSurrogates(in bytes: UnsafeRawBufferPointer) -> [UInt8]? {
        var rewritten: [UInt8]?
        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "\\") else {
                index += 1
                continue
            }
            guard let unit = codeUnit(in: bytes, at: index) else {
                index += 2
                continue
            }
            if (0xD800..<0xDC00).contains(unit), let low = codeUnit(in: bytes, at: index + 6), (0xDC00..<0xE000).contains(low) {
                index += 12
                continue
            }
            if (0xD800..<0xE000).contains(unit) {
                if rewritten == nil { rewritten = Array(bytes) }
                rewritten?.replaceSubrange(index + 2..<index + 6, with: "fffd".utf8)
            }
            index += 6
        }
        return rewritten
    }

    /// The code unit of the `\uXXXX` escape at `index`, if one is there.
    private static func codeUnit(in bytes: UnsafeRawBufferPointer, at index: Int) -> UInt32? {
        guard index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
            return nil
        }
        var unit: UInt32 = 0
        for byte in bytes[index + 2..<index + 6] {
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: return nil
            }
            unit = unit << 4 | UInt32(digit)
        }
        return unit
    }

    /// Where the first `[` or `{` nested deeper than `maxDepth` starts, for
    /// the error. Only called for a document yyjson accepted, so its strings
    /// are well formed.
    private static func offsetBeyond(_ maxDepth: Int, in bytes: UnsafeRawBufferPointer) -> Int {
        var depth = 0
        var inString = false
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\\") where inString:
                index += 1
            case UInt8(ascii: "\""):
                inString.toggle()
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                guard !inString else { break }
                depth += 1
                if depth > maxDepth { return index }
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                guard !inString else { break }
                depth -= 1
            default:
                break
            }
            index += 1
        }
        return bytes.count
    }
}

/// Nesting beyond the read's limit, found by the walk.
private struct DepthExceeded: Error {}

/// Turns yyjson's tree into a `JSONValue`, typed by literal as in Python.
///
/// Iterative, with one `Level` per open array or object: recursing would take
/// over a kilobyte of stack per level in a debug build, and a 512 KB thread
/// stack would run out before `maxDepth`.
private enum Walk {
    static func value(of root: UnsafeMutablePointer<yyjson_val>, maxDepth: Int) throws(DepthExceeded) -> JSONValue {
        var levels: [Level] = []
        var node = root
        while true {
            if yyjson_is_ctn(node) {
                guard levels.count < maxDepth else { throw DepthExceeded() }
                levels.append(Level(node))
            } else {
                let value = scalar(node)
                guard !levels.isEmpty else { return value }
                levels[levels.count - 1].add(value)
            }
            // On to the next child of the innermost level that has one left;
            // each level without is closed into its parent.
            while true {
                if let child = levels[levels.count - 1].nextChild() {
                    node = child
                    break
                }
                let closed = levels.removeLast().value
                guard !levels.isEmpty else { return closed }
                levels[levels.count - 1].add(closed)
            }
        }
    }

    static func scalar(_ node: UnsafeMutablePointer<yyjson_val>) -> JSONValue {
        switch yyjson_get_type(node) {
        case YYJSON_TYPE_NULL:
            return .null
        case YYJSON_TYPE_BOOL:
            return .bool(yyjson_get_bool(node))
        case YYJSON_TYPE_NUM:
            // yyjson reads a literal with fraction or exponent as real, other
            // negative ones as signed, the rest as unsigned.
            if yyjson_is_real(node) { return .number(yyjson_get_real(node)) }
            if yyjson_is_sint(node) { return .integer(yyjson_get_sint(node)) }
            let unsigned = yyjson_get_uint(node)
            return Int64(exactly: unsigned).map(JSONValue.integer) ?? .bigInteger(String(unsigned))
        case YYJSON_TYPE_RAW:
            return number(literal: text(of: node, at: yyjson_get_raw(node)))
        default:
            // `YYJSON_TYPE_STR`, the only scalar type left.
            return .string(text(of: node, at: yyjson_get_str(node)))
        }
    }

    /// The bytes of a string, key or raw literal. yyjson has validated them
    /// as UTF-8; the length, not a NUL, ends them, since `\u0000` is allowed.
    static func text(of node: UnsafeMutablePointer<yyjson_val>, at start: UnsafePointer<CChar>?) -> String {
        let bytes = UnsafeRawBufferPointer(start: start, count: yyjson_get_len(node))
        return String(decoding: bytes.assumingMemoryBound(to: UInt8.self), as: UTF8.self)
    }

    /// A literal yyjson left raw: an integer beyond 64 bits, or a float beyond
    /// the double range. Typed by its form, as Python does.
    static func number(literal: String) -> JSONValue {
        let isInteger = !literal.utf8.contains { $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") }
        if isInteger { return Int64(literal).map(JSONValue.integer) ?? .bigInteger(literal) }
        // Overflows to the infinity of its sign, like Python. yyjson only
        // leaves a float raw when it overflows, so that is also the answer
        // should Swift ever not read the literal.
        return .number(Double(literal) ?? (literal.hasPrefix("-") ? -.infinity : .infinity))
    }

    /// An array or object being filled.
    private struct Level {
        private let isObject: Bool
        private var arrayIterator = yyjson_arr_iter()
        private var objectIterator = yyjson_obj_iter()
        private var elements: [JSONValue] = []
        private var members: [JSONKey: JSONValue] = [:]
        /// The key of the member whose value comes next.
        private var key = JSONKey("")

        init(_ container: UnsafeMutablePointer<yyjson_val>) {
            isObject = yyjson_is_obj(container)
            if isObject {
                yyjson_obj_iter_init(container, &objectIterator)
                members.reserveCapacity(yyjson_obj_size(container))
            } else {
                yyjson_arr_iter_init(container, &arrayIterator)
                elements.reserveCapacity(yyjson_arr_size(container))
            }
        }

        mutating func nextChild() -> UnsafeMutablePointer<yyjson_val>? {
            guard isObject else { return yyjson_arr_iter_next(&arrayIterator) }
            guard let next = yyjson_obj_iter_next(&objectIterator) else { return nil }
            key = JSONKey(Walk.text(of: next, at: yyjson_get_str(next)))
            return yyjson_obj_iter_get_val(next)
        }

        mutating func add(_ value: JSONValue) {
            // A repeated key keeps its last value, as in Python.
            if isObject { members[key] = value } else { elements.append(value) }
        }

        var value: JSONValue { isObject ? .object(members) : .array(elements) }
    }
}
