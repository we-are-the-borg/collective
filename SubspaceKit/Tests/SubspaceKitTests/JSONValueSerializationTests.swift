import Foundation
import Testing
@testable import SubspaceKit

private func text(_ value: JSONValue) -> String {
    String(decoding: value.serialized(), as: UTF8.self)
}

private func roundTrip(_ value: JSONValue) throws -> JSONValue {
    try JSONValue(data: value.serialized())
}

@Suite struct JSONValueSerializationTests {
    @Test func escapesQuoteBackslashAndControlCharacters() throws {
        #expect(text(.string("a\"b\\c")) == #""a\"b\\c""#)
        #expect(text(.string("\u{08}\u{0C}\n\r\t")) == #""\b\f\n\r\t""#)
        #expect(text(.string("\u{00}\u{01}\u{1F}")) == #""\u0000\u0001\u001f""#)
        let all = String(String.UnicodeScalarView((0..<0x20).map { Unicode.Scalar($0)! }))
        #expect(try roundTrip(.string(all)) == .string(all))
    }

    @Test func nonASCIIIsWrittenAsUTF8Unchanged() {
        #expect(text(.string("/é😀\u{7F}")) == "\"/é😀\u{7F}\"")
    }

    @Test func compactWithoutWhitespace() {
        #expect(text(.object(["a": .array([.integer(1), .null, .bool(true), .bool(false)]), "b": .object([:])]))
                == #"{"a":[1,null,true,false],"b":{}}"#)
        #expect(text(.array([.array([]), .object([:])])) == "[[],{}]")
    }

    @Test func integersAreExact() throws {
        #expect(text(.integer(0)) == "0")
        #expect(text(.integer(-42)) == "-42")
        #expect(text(.integer(.max)) == "9223372036854775807")
        #expect(text(.integer(.min)) == "-9223372036854775808")
        for digits in ["18446744073709551617", "-18446744073709551617", "9223372036854775808"] {
            #expect(text(.bigInteger(digits)) == digits)
            #expect(try roundTrip(.bigInteger(digits)) == .bigInteger(digits))
        }
    }

    @Test(arguments: [0.1, 1e300, -0.0, 5e-324, 1.0, 100.0, 1e16, -2.5e-7, .greatestFiniteMagnitude])
    func doublesRoundTripBitExactly(d: Double) throws {
        let parsed = try roundTrip(.number(d))
        guard case let .number(back) = parsed else {
            Issue.record("\(d) came back as \(parsed)")
            return
        }
        #expect(back.bitPattern == d.bitPattern)
    }

    @Test func doublesStayNumbers() {
        #expect(text(.number(1.0)) == "1.0")
        #expect(text(.number(0.1)) == "0.1")
    }

    /// The parser reads a literal beyond the double range as the infinity of its sign.
    @Test(arguments: ["1e400", "1e999", "1e99999999999999999999"])
    func theParserReadsAnOverflowingLiteralAsInfinity(literal: String) throws {
        #expect(try JSONValue(data: Data("[\(literal),-\(literal)]".utf8)) == .array([.number(.infinity), .number(-.infinity)]))
    }

    @Test func anOverflowingNumberSurvivesSerialization() throws {
        let value = try JSONValue(data: Data("[1e400,-1e400]".utf8))
        #expect(try JSONValue(data: value.serialized()) == value)
        #expect(text(value) == "[1e999,-1e999]")
    }

    /// JSON has no NaN literal, so the parser never produces one; the writer
    /// keeps the output valid JSON anyway.
    @Test func nanIsWrittenAsNull() {
        #expect(text(.number(.nan)) == "null")
    }

    @Test func keysDifferingOnlyInNormalizationStayDistinct() throws {
        let nfc = "\u{E9}", nfd = "e\u{301}"
        let value = JSONValue.object([JSONKey(nfc): .integer(1), JSONKey(nfd): .integer(2)])
        #expect(try roundTrip(value) == value)
        #expect(try roundTrip(.string(nfd)) == .string(nfd))
        #expect(try roundTrip(.string(nfd)) != .string(nfc))
    }

    @Test func keysAreSortedByCodePoints() throws {
        // "Z" (U+005A) < "a" < "é" (U+00E9) < "😀" by code point.
        #expect(text(.object(["😀": .null, "a": .null, "é": .null, "Z": .null, "ab": .null]))
                == #"{"Z":null,"a":null,"ab":null,"é":null,"😀":null}"#)
        // Same value built in another insertion order gives identical bytes.
        var first: [JSONKey: JSONValue] = [:]
        var second: [JSONKey: JSONValue] = [:]
        for i in 0..<50 { first[JSONKey("k\(i)")] = .integer(Int64(i)) }
        for i in (0..<50).reversed() { second[JSONKey("k\(i)")] = .integer(Int64(i)) }
        #expect(JSONValue.object(first).serialized() == JSONValue.object(second).serialized())
    }

    @Test func mappingResultRoundTripsThroughJSONValue() throws {
        let result = MappingResult(core: ["event": .string("stop"), "ts": .integer(1)], blockName: "codex",
                                   block: ["turn": .object(["id": .string("t")])])
        #expect(MappingResult(jsonValue: result.jsonValue, blockName: "codex") == result)
        #expect(MappingResult(jsonValue: MappingResult(blockName: "x").jsonValue, blockName: "x") == MappingResult(blockName: "x"))
    }

    @Test func mappingResultRejectsOtherShapes() {
        #expect(MappingResult(jsonValue: .array([]), blockName: "x") == nil)
        #expect(MappingResult(jsonValue: .object(["a": .null]), blockName: "x") == nil)
        #expect(MappingResult(jsonValue: .object(["x": .integer(1)]), blockName: "x") == nil)
    }
}

/// Round trip over everything captured in the subspace dev repo: payloads and
/// golden expectations alike, plus each payload's mapping result.
@Suite(.enabled(if: SubspaceDevRepo.isAvailable,
                "subspace dev repo not found (expected at ../../we-are-the-borg/subspace or $SUBSPACE_DEV_DIR); captured round trip NOT checked"))
struct JSONValueSerializationCapturedTests {
    static var fixtures: URL { SubspaceDevRepo.root.appendingPathComponent("fixtures", isDirectory: true) }

    static func jsonFiles() -> [URL] {
        let enumerator = FileManager.default.enumerator(at: fixtures, includingPropertiesForKeys: nil)
        return (enumerator?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "json" }
            .sorted { $0.path < $1.path }
    }

    @Test func everyCapturedFileRoundTrips() throws {
        let files = Self.jsonFiles()
        #expect(!files.isEmpty, "no .json files under \(Self.fixtures.path)")
        var serializeTime = Duration.zero
        let clock = ContinuousClock()
        for file in files {
            let value = try JSONValue(data: Data(contentsOf: file))
            var bytes = Data()
            serializeTime += clock.measure { bytes = value.serialized() }
            let back = try JSONValue(data: bytes)
            #expect(back == value, "round trip changed \(file.path)")
            #expect(back.serialized() == bytes, "serialization not idempotent for \(file.path)")
        }
        print("JSONValueSerialization: round-tripped \(files.count) captured files, serialized in \(serializeTime)")
    }

    /// Parsing shares no state: every captured file, parsed several times at
    /// once, equals its serial parse and serializes to the same bytes.
    @Test func concurrentParsesEqualTheSerialParse() async throws {
        let files = Self.jsonFiles()
        #expect(!files.isEmpty, "no .json files under \(Self.fixtures.path)")
        var inputs: [(path: String, data: Data, expected: JSONValue, bytes: Data)] = []
        for file in files {
            let data = try Data(contentsOf: file)
            let value = try JSONValue(data: data)
            inputs.append((file.path, data, value, value.serialized()))
        }
        let repetitions = 8
        let mismatches = try await withThrowingTaskGroup(of: [String].self) { group in
            for input in inputs {
                for _ in 0..<repetitions {
                    group.addTask {
                        let value = try JSONValue(data: input.data)
                        return value == input.expected && value.serialized() == input.bytes ? [] : [input.path]
                    }
                }
            }
            return try await group.reduce(into: []) { $0 += $1 }
        }
        #expect(mismatches.isEmpty, "concurrent parse differs: \(mismatches)")
    }

    /// Every payload in an `events/` or `status/` folder, mapped with the
    /// document the conformance tests use for it.
    @Test func everyCapturedMappingResultRoundTrips() throws {
        let model = SubspaceDevRepo.root.appendingPathComponent("model", isDirectory: true)
        var documents: [String: MappingDocument?] = [:]
        var checked = 0
        for file in Self.jsonFiles() {
            let folder = file.deletingLastPathComponent().lastPathComponent
            guard folder == "events" || folder == "status" else { continue }
            // fixtures/<source>/<version>/<run>/<folder>/<file>
            let source = file.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            let name = folder == "events" ? source : "\(source)-session"
            if documents[name] == nil {
                let url = model.appendingPathComponent("\(name).json")
                documents[name] = .some(try? MappingDocument(data: Data(contentsOf: url)))
            }
            guard let document = documents[name] ?? nil else { continue }
            let result = MappingInterpreter.apply(document, to: try JSONValue(data: Data(contentsOf: file)))
            let stored = try JSONValue(data: result.jsonValue.serialized())
            #expect(MappingResult(jsonValue: stored, blockName: document.block) == result, "\(file.path)")
            checked += 1
        }
        #expect(checked > 0)
        print("JSONValueSerialization: round-tripped \(checked) captured mapping results")
    }
}
