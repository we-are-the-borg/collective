import Foundation
import Testing
@testable import SubspaceKit

private func parse(_ text: String) throws -> JSONValue {
    try JSONValue(data: Data(text.utf8))
}

@Suite struct JSONValueTests {
    @Test func integerLiteralIsInteger() throws {
        #expect(try parse("1") == .integer(1))
        #expect(try parse("-0") == .integer(0))
    }

    @Test func fractionOrExponentIsNumber() throws {
        #expect(try parse("1.0") == .number(1.0))
        #expect(try parse("1.5") == .number(1.5))
        #expect(try parse("1e3") == .number(1000))
    }

    @Test func boolIsNeverANumber() throws {
        #expect(try parse("true") == .bool(true))
        #expect(try parse("false") == .bool(false))
    }

    @Test func unixMillisecondsStayExact() throws {
        #expect(try parse("1790968965288") == .integer(1_790_968_965_288))
    }

    @Test func nestedObjectsArraysAndNull() throws {
        let value = try parse(#" { "a": [1, 2.5, "x\né😀", null, {"b": false}], "c": {} } "#)
        #expect(value == .object([
            "a": .array([.integer(1), .number(2.5), .string("x\né😀"), .null, .object(["b": .bool(false)])]),
            "c": .object([:]),
        ]))
        #expect(try parse("null") == .null)
    }

    @Test(arguments: ["", "{", "[1,]", "01", "1.", "tru", "\"abc", "{\"a\" 1}", "1 2", "NaN"])
    func malformedInputThrows(text: String) {
        #expect(throws: (any Error).self) { try parse(text) }
    }

    @Test func semanticEqualityTreatsIntegerAndEqualNumberAsSame() {
        #expect(JSONValue.integer(1).isSemanticallyEqual(to: .number(1.0)))
        #expect(JSONValue.object(["a": .array([.number(2)])]).isSemanticallyEqual(to: .object(["a": .array([.integer(2)])])))
        #expect(!JSONValue.integer(1).isSemanticallyEqual(to: .number(1.5)))
        #expect(!JSONValue.integer(1).isSemanticallyEqual(to: .bool(true)))
        #expect(!JSONValue.object(["a": .null]).isSemanticallyEqual(to: .object([:])))
    }

    // MARK: Python parity

    @Test func integersBeyondInt64StayExact() throws {
        #expect(try parse("18446744073709551616") == .bigInteger("18446744073709551616"))
        #expect(try parse("-9223372036854775809") == .bigInteger("-9223372036854775809"))
        #expect(try parse("9223372036854775807") == .integer(.max))
        #expect(try parse("-9223372036854775808") == .integer(.min))
    }

    @Test func semanticEqualityComparesBigIntegersExactly() {
        #expect(JSONValue.bigInteger("18446744073709551616").isSemanticallyEqual(to: .bigInteger("18446744073709551616")))
        #expect(!JSONValue.bigInteger("18446744073709551616").isSemanticallyEqual(to: .bigInteger("18446744073709551617")))
        // Like Python: 2**64 == float(2**64), but 2**64 + 1 != float(2**64 + 1).
        #expect(JSONValue.bigInteger("18446744073709551616").isSemanticallyEqual(to: .number(0x1p64)))
        #expect(JSONValue.number(0x1p64).isSemanticallyEqual(to: .bigInteger("18446744073709551616")))
        #expect(!JSONValue.bigInteger("18446744073709551617").isSemanticallyEqual(to: .number(0x1p64)))
        #expect(JSONValue.bigInteger("-100000000000000000000").isSemanticallyEqual(to: .number(-1e20)))
    }

    @Test func stringsCompareByCodePoints() throws {
        // NFC "é" and NFD "e" + U+0301 are different strings to Python.
        #expect(JSONValue.string("\u{E9}") != .string("e\u{301}"))
        #expect(!JSONValue.string("\u{E9}").isSemanticallyEqual(to: .string("e\u{301}")))
        #expect(try parse(#""\u00e9""#) == .string("\u{E9}"))
    }

    @Test func keysDifferingOnlyInNormalizationStayDistinct() throws {
        guard case let .object(object) = try parse(#"{"\u00e9": 1, "e\u0301": 2}"#) else {
            Issue.record("not an object")
            return
        }
        #expect(object.count == 2)
        #expect(object[JSONKey("\u{E9}")] == .integer(1))
        #expect(object[JSONKey("e\u{301}")] == .integer(2))
    }

    @Test func repeatedKeyKeepsItsLastValue() throws {
        #expect(try parse(#"{"a": 1, "a": 2}"#) == .object(["a": .integer(2)]))
    }

    // MARK: Literals as Python reads them

    @Test func negativeZeroNumberKeepsItsSign() throws {
        guard case let .number(d) = try parse("-0.0") else {
            Issue.record("-0.0 is not a number")
            return
        }
        #expect(d == 0 && d.sign == .minus)
    }

    @Test(arguments: ["1e2", "1E2", "1e+2", "100.0"])
    func exponentOrFractionIsANumber(literal: String) throws {
        #expect(try parse(literal) == .number(100))
    }

    @Test func outOfRangeLiteralsSaturateLikePython() throws {
        #expect(try parse("1e400") == .number(.infinity))
        #expect(try parse("-1e400") == .number(-.infinity))
        guard case let .number(tiny) = try parse("1e-400") else {
            Issue.record("1e-400 is not a number")
            return
        }
        #expect(tiny == 0 && tiny.sign == .plus)
    }

    /// Past `Int64` but within `UInt64`, which yyjson still reads as a number.
    @Test func unsignedIntegersBeyondInt64StayExact() throws {
        #expect(try parse("9223372036854775808") == .bigInteger("9223372036854775808"))
        #expect(try parse("18446744073709551615") == .bigInteger("18446744073709551615"))
    }

    /// Python 3.11+ rejects integer literals over 4300 digits; they are kept here.
    @Test func integersOverPythonsDigitLimitAreKept() throws {
        let digits = "1" + String(repeating: "0", count: 4300)
        #expect(try parse(digits) == .bigInteger(digits))
        #expect(try parse("-" + digits) == .bigInteger("-" + digits))
    }

    @Test func scalarRoots() throws {
        #expect(try parse("42") == .integer(42))
        #expect(try parse(#""x""#) == .string("x"))
        #expect(try parse("null") == .null)
        #expect(try parse("true") == .bool(true))
        #expect(try parse(" [1]\n") == .array([.integer(1)]))
    }

    @Test func escapedNullCharacterStaysInTheString() throws {
        #expect(try parse(#""a\u0000b""#) == .string("a\u{0}b"))
        #expect(try parse(#"{"a\u0000": 1}"#) == .object([JSONKey("a\u{0}"): .integer(1)]))
    }

    /// Strict RFC 8259: no NaN or Infinity, no BOM, no raw control character,
    /// no empty document, nothing after the value, no comment, no trailing comma.
    @Test(arguments: ["Infinity", "-Infinity", "\u{FEFF}[1]", "\"a\u{01}b\"", " \n\t", "[1]\u{0}", "/* c */ [1]", "[1,2,]"])
    func nonStandardInputThrows(text: String) {
        #expect(throws: JSONParseError.self) { try parse(text) }
    }

    @Test(arguments: [[0x22, 0x61, 0xFF, 0x62, 0x22], [0x22, 0x61, 0xED, 0xA0, 0xBD, 0x62, 0x22], [0x22, 0xF0, 0x9F, 0x98, 0x22]] as [[UInt8]])
    func invalidUTF8Throws(bytes: [UInt8]) {
        #expect(throws: JSONParseError.self) { try JSONValue(data: Data(bytes)) }
    }

    // MARK: Surrogate escapes

    @Test func escapedSurrogatePairIsOneScalar() throws {
        #expect(try parse(#""\ud83d\ude00""#) == .string("😀"))
        #expect(try parse(#""\uD83D\uDE00""#) == .string("😀"))
    }

    /// Node's `JSON.stringify` writes half an emoji as a lone surrogate escape.
    /// A Swift `String` cannot hold one, so it becomes U+FFFD; Python keeps it.
    @Test(arguments: [
        (#""\ud83d""#, "\u{FFFD}"),
        (#""\ude00""#, "\u{FFFD}"),
        (#""abc\ud83d""#, "abc\u{FFFD}"),
        (#""\ud83dA""#, "\u{FFFD}A"),
        (#""\ud83d\u0041""#, "\u{FFFD}A"),
        (#""\ud83d\ud83d\ude00""#, "\u{FFFD}😀"),
        (#""\ude00\ud83d""#, "\u{FFFD}\u{FFFD}"),
        (#""\ud83d\ude00\ude00""#, "😀\u{FFFD}"),
    ])
    func loneSurrogateEscapeBecomesReplacementCharacter(json: String, expected: String) throws {
        #expect(try parse(json) == .string(expected))
    }

    @Test func loneSurrogateEscapeInAPayload() throws {
        let value = try parse(#"{"n": 1, "tool_response": {"stdout": "cut mid emoji \ud83d"}}"#)
        #expect(value == .object(["n": .integer(1), "tool_response": .object(["stdout": .string("cut mid emoji \u{FFFD}")])]))
    }

    /// Two keys differing only in a lone surrogate collide here, unlike in Python;
    /// the last one wins.
    @Test func loneSurrogateEscapeInAKey() throws {
        #expect(try parse(#"{"\ud83d": 1}"#) == .object(["\u{FFFD}": .integer(1)]))
        #expect(try parse(#"{"\ud83d": 1, "\ufffd": 2}"#) == .object(["\u{FFFD}": .integer(2)]))
    }

    @Test func escapedBackslashBeforeSurrogateDigitsStaysText() throws {
        #expect(try parse(#""\\ud83d""#) == .string(#"\ud83d"#))
        #expect(try parse(#"["\\ud83d", "\ud83d"]"#) == .array([.string(#"\ud83d"#), .string("\u{FFFD}")]))
    }

    @Test(arguments: [#""\ud83d\uzzzz""#, #""\ud83d\u12""#, #""\ud83d\x""#])
    func highSurrogateBeforeAnInvalidEscapeThrows(json: String) {
        #expect(throws: JSONParseError.self) { try parse(json) }
    }

    /// The document is read again once its lone surrogates are replaced; a
    /// second error is reported where that read stopped, at the trailing comma.
    @Test func errorAfterALoneSurrogateIsReportedFromTheSecondRead() {
        #expect(throws: JSONParseError(offset: 9)) { try parse(#"["\ud83d",]"#) }
    }

    // MARK: Depth

    @Test func nestingUpTo512LevelsIsRead() throws {
        var value = try parse(String(repeating: "[", count: 512) + String(repeating: "]", count: 512))
        var depth = 0
        while case let .array(elements) = value {
            depth += 1
            value = elements.first ?? .null
        }
        #expect(depth == 512)
        _ = try parse(String(repeating: #"{"a":"#, count: 511) + "{}" + String(repeating: "}", count: 511))
    }

    /// The error points at the first bracket beyond the limit.
    @Test func nestingBeyond512LevelsThrows() {
        #expect(throws: JSONParseError(offset: 512)) {
            try parse(String(repeating: "[", count: 513) + String(repeating: "]", count: 513))
        }
        #expect(throws: JSONParseError(offset: 2560)) {
            try parse(String(repeating: #"{"a":"#, count: 512) + "{}" + String(repeating: "}", count: 512))
        }
        #expect(throws: JSONParseError(offset: 512)) {
            try parse(String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000))
        }
    }

    /// The deepest value the reader accepts serializes on a 512 KB stack, as
    /// the compact text it was read from (each object has one key), and reads
    /// back as itself.
    @Test(arguments: Nesting.allCases)
    func theDeepestValueSerializesOnASmallStack(nesting: Nesting) async throws {
        let text = nestedJSON(nesting, depth: 512)
        let (serialized, readsBack) = try await onSmallStack {
            let value = try parse(text)
            let serialized = value.serialized()
            return (String(decoding: serialized, as: UTF8.self), try JSONValue(data: serialized) == value)
        }
        #expect(serialized == text)
        #expect(readsBack)
    }

    /// Two of the deepest values the reader accepts compare on a 512 KB
    /// stack, down to their innermost value: `1` equals `1.0` semantically
    /// only, `2` neither way.
    @Test(arguments: Nesting.allCases)
    func theDeepestValuesCompareOnASmallStack(nesting: Nesting) async throws {
        let comparisons = try await onSmallStack {
            let one = try parse(nestedJSON(nesting, depth: 512, around: "1"))
            let same = try parse(nestedJSON(nesting, depth: 512, around: "1"))
            let float = try parse(nestedJSON(nesting, depth: 512, around: "1.0"))
            let two = try parse(nestedJSON(nesting, depth: 512, around: "2"))
            return [one == same, one.isSemanticallyEqual(to: same),
                    one == float, one.isSemanticallyEqual(to: float), float.isSemanticallyEqual(to: one),
                    one == two, one.isSemanticallyEqual(to: two)]
        }
        #expect(comparisons == [true, true, false, true, true, false, false])
    }

    /// The store reads its mapped results back with `MappingResult.maxDepth`,
    /// 2 × 512 − 1 levels: the deepest result reads, serializes, compares and
    /// is freed on a 512 KB stack, the store's and an app's; one level more is
    /// rejected where it starts.
    @Test(arguments: Nesting.allCases)
    func theDeepestMappedResultIsReadOnASmallStack(nesting: Nesting) async throws {
        let text = nestedJSON(nesting, depth: 1023)
        let (serialized, readsBack) = try await onSmallStack {
            let value = try JSONReader.read(Data(text.utf8), maxDepth: MappingResult.maxDepth)
            let serialized = value.serialized()
            let again = try JSONReader.read(serialized, maxDepth: MappingResult.maxDepth)
            return (String(decoding: serialized, as: UTF8.self), again == value)
        }
        #expect(serialized == text)
        #expect(readsBack)
        #expect(throws: JSONParseError.self) { try JSONValue(data: Data(text.utf8)) }
        #expect(throws: JSONParseError(offset: 1023)) {
            try JSONReader.read(Data((String(repeating: "[", count: 1024) + String(repeating: "]", count: 1024)).utf8),
                                maxDepth: MappingResult.maxDepth)
        }
    }

    @Test func depthErrorOffsetSkipsBracketsInStrings() {
        let prefix = #"["[\"[{\\", {"]": ["#
        // The prefix opens three levels, so the 510th bracket after it is level 513.
        let json = prefix + String(repeating: "[", count: 511) + String(repeating: "]", count: 512) + "}]"
        #expect(throws: JSONParseError(offset: prefix.utf8.count + 509)) { try parse(json) }
    }

    // MARK: Performance

    /// A long tool output is one string full of `\n` escapes. The former parser
    /// took time quadratic in their number: about a second for this one in a
    /// debug build, against about 2 ms now. The bound sits a hundred times
    /// above that, so a loaded machine cannot fail it, and well below the
    /// quadratic case, so a regression does.
    @Test func manyEscapesInOneStringParseInLinearTime() throws {
        let line = "hello world \\n"
        let json = "\"" + String(repeating: line, count: 80_000) + "\""
        let clock = ContinuousClock()
        var value = JSONValue.null
        let elapsed = try clock.measure { value = try parse(json) }
        #expect(value == .string(String(repeating: "hello world \n", count: 80_000)))
        #expect(elapsed < .milliseconds(200), "took \(elapsed)")
    }
}
