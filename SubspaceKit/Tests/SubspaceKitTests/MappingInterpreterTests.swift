import Foundation
import Testing
@testable import SubspaceKit

private func json(_ text: String) throws -> JSONValue {
    try JSONValue(data: Data(text.utf8))
}

/// A format-1 document with one block field `f` holding `spec`.
private func document(field spec: String) throws -> MappingDocument {
    try MappingDocument(data: Data(#"{"format": 1, "revision": 1, "source": "t", "block": "t", "fields": {"f": \#(spec)}}"#.utf8))
}

/// The value of block field `f` for `spec` applied to `payload`, nil if absent.
private func field(_ spec: String, _ payload: String) throws -> JSONValue? {
    MappingInterpreter.apply(try document(field: spec), to: try json(payload)).block["f"]
}

@Suite struct MappingInterpreterTests {
    @Test func pathCopiesTheValue() throws {
        #expect(try field(#"{"path": "/a/b"}"#, #"{"a": {"b": [1, null]}}"#) == .array([.integer(1), .null]))
        #expect(try field(#"{"path": "/missing"}"#, #"{"a": 1}"#) == nil)
    }

    // MARK: when

    @Test func whenNeedsEveryConditionToHold() throws {
        let spec = #"{"when": [{"path": "/e", "in": ["A", "B"]}, {"path": "/t", "in": ["x"]}], "path": "/v"}"#
        #expect(try field(spec, #"{"e": "B", "t": "x", "v": 1}"#) == .integer(1))
        #expect(try field(spec, #"{"e": "B", "t": "y", "v": 1}"#) == nil)
        #expect(try field(spec, #"{"e": "C", "t": "x", "v": 1}"#) == nil)
    }

    @Test func conditionOnANonStringValueDoesNotHold() throws {
        let spec = #"{"when": [{"path": "/e", "in": ["1", "true"]}], "path": "/v", "default": "d"}"#
        #expect(try field(spec, #"{"e": 1, "v": 1}"#) == nil)
        #expect(try field(spec, #"{"e": true, "v": 1}"#) == nil)
    }

    @Test func conditionWithAnUnknownKeyDoesNotHold() throws {
        let spec = #"{"when": [{"path": "/e", "in": ["A"], "not": true}], "path": "/v"}"#
        #expect(try field(spec, #"{"e": "A", "v": 1}"#) == nil)
    }

    // MARK: path

    @Test func pathListStopsAtTheFirstExistingPath() throws {
        let spec = #"{"path": ["/a", "/b", "/c"]}"#
        #expect(try field(spec, #"{"b": 2, "c": 3}"#) == .integer(2))
        // A key holding null exists, so /c is never reached.
        #expect(try field(spec, #"{"b": null, "c": 3}"#) == .null)
        #expect(try field(spec, #"{"d": 4}"#) == nil)
    }

    // MARK: parse and pick

    @Test func parseJSONReadsAStringValue() throws {
        #expect(try field(#"{"path": "/r", "parse": "json"}"#, #"{"r": "{\"task\": \"t1\", \"n\": 2}"}"#)
            == .object(["task": .string("t1"), "n": .integer(2)]))
    }

    @Test func parseJSONOfInvalidJSONOrANonStringYieldsNothing() throws {
        let spec = #"{"path": "/r", "parse": "json"}"#
        #expect(try field(spec, #"{"r": "{not json"}"#) == nil)
        #expect(try field(spec, #"{"r": {"task": "t1"}}"#) == nil)
    }

    @Test func pickHitAndMiss() throws {
        let spec = #"{"path": "/r", "parse": "json", "pick": "/task"}"#
        #expect(try field(spec, #"{"r": "{\"task\": \"t1\"}"}"#) == .string("t1"))
        #expect(try field(spec, #"{"r": "{\"other\": 1}"}"#) == nil)
    }

    @Test func pickWithoutParseYieldsNothing() throws {
        #expect(try field(#"{"path": "/r", "pick": "/task"}"#, #"{"r": {"task": "t1"}}"#) == nil)
    }

    // MARK: map

    @Test func mapReplacesListedStringsOnly() throws {
        let spec = #"{"path": "/s", "map": {"busy": "working", "idle": null}}"#
        #expect(try field(spec, #"{"s": "busy"}"#) == .string("working"))
        #expect(try field(spec, #"{"s": "idle"}"#) == .null)
        #expect(try field(spec, #"{"s": "sleeping"}"#) == nil)
        #expect(try field(spec, #"{"s": 1}"#) == nil)
    }

    // MARK: each

    /// The `background_agents` example of §5.2.
    private let backgroundAgents = #"{"path": "/tasks", "each": {"when": [{"path": "/type", "in": ["subagent"]}], "path": "/id", "type": "id"}}"#

    @Test func eachProjectsAndFiltersElements() throws {
        #expect(try field(backgroundAgents, #"{"tasks": [{"id": "a1", "type": "subagent"}, {"id": "b2", "type": "shell"}]}"#)
            == .array([.string("a1")]))
    }

    @Test func eachKeepsAnEmptyArrayEmpty() throws {
        #expect(try field(backgroundAgents, #"{"tasks": []}"#) == .array([]))
    }

    @Test func eachOfAMissingValueOrANonArrayYieldsNothing() throws {
        #expect(try field(backgroundAgents, #"{}"#) == nil)
        #expect(try field(backgroundAgents, #"{"tasks": {"id": "a1", "type": "subagent"}}"#) == nil)
    }

    @Test func eachEvaluatesRuleListsAgainstTheElement() throws {
        // Pointers and `when` start at the element, not at the payload: the
        // payload's own /k and /x never count.
        let spec = #"{"path": "/l", "each": [{"when": [{"path": "/k", "in": ["x"]}], "path": "/x"}, {"path": "/y"}]}"#
        #expect(try field(spec, #"{"k": "x", "x": 0, "l": [{"k": "x", "x": 1, "y": 2}, {"y": 3}, {"k": "x", "y": 4}]}"#)
            == .array([.integer(1), .integer(3)]))
    }

    @Test func eachLeavesOutElementsWhoseSpecHasAnUnknownKey() throws {
        #expect(try field(#"{"path": "/l", "each": {"path": "/i", "split": ","}}"#, #"{"l": [{"i": "a,b"}]}"#) == .array([]))
    }

    @Test func nestedEachChoosesAndLeavesOutPerElementAtEveryLevel() throws {
        // Per group: "skip" decides on a missing /none (no fallback to /name),
        // "list" maps its items, any other kind gives its /name. Per item: "a"
        // gives /v, others hit a rule with an unknown key. Left out: the
        // skipped group, items without a value, a group whose /items is no
        // array, a scalar group, and the page without /groups.
        let groups = #"""
            {"path": "/groups", "each": [
                {"when": [{"path": "/kind", "in": ["skip"]}], "path": "/none"},
                {"when": [{"path": "/kind", "in": ["list"]}], "path": "/items", "each": [
                    {"when": [{"path": "/t", "in": ["a"]}], "path": "/v"},
                    {"path": "/w", "zz": 1}
                ]},
                {"path": "/name"}
            ]}
            """#
        let spec = #"{"path": "/pages", "each": \#(groups)}"#
        let payload = #"""
            {"pages": [
                {"groups": [
                    {"kind": "skip", "name": "n0"},
                    {"kind": "list", "items": [{"t": "a", "v": 1}, {"t": "b", "w": 2}, {"t": "a"}]},
                    {"kind": "list", "items": "x"},
                    {"kind": "other", "name": "n3"},
                    "scalar"
                ]},
                {"groups": []},
                {}
            ]}
            """#
        #expect(try field(spec, payload) == .array([.array([.array([.integer(1)]), .string("n3")]), .array([])]))
    }

    @Test func nestedEachAppliesMapTypeAndDefaultAfterItsElements() throws {
        // Inner rules map and default per cell; the row's default stands in
        // where /cells is no array or missing.
        let cells = #"{"path": "/cells", "each": {"path": "/s", "map": {"on": "ON"}, "default": "?"}, "default": "no cells"}"#
        #expect(try field(#"{"path": "/rows", "each": \#(cells)}"#, #"{"rows": [{"cells": [{"s": "on"}, {"s": "off"}, {}]}, {"cells": "x"}, {}]}"#)
            == .array([.array([.string("ON"), .string("?"), .string("?")]), .string("no cells"), .string("no cells")]))

        // `type` and `map` see the collected array: at the row level it is no
        // string, so the row's default applies; the outer array passes
        // "array", fails "object" and cannot be mapped.
        let rows = #"[{"cells": [{"n": 1}, {"n": "x"}]}, {"cells": []}]"#
        let typed = #"{"path": "/cells", "each": {"path": "/n", "type": "integer"}, "type": "string", "default": 0}"#
        #expect(try field(#"{"path": "/rows", "each": \#(typed), "type": "array", "default": "outer"}"#, #"{"rows": \#(rows)}"#)
            == .array([.integer(0), .integer(0)]))
        #expect(try field(#"{"path": "/rows", "each": \#(typed), "type": "object", "default": "outer"}"#, #"{"rows": \#(rows)}"#)
            == .string("outer"))
        let mapped = #"{"path": "/cells", "each": {"path": "/n", "type": "integer"}, "map": {"1": "one"}, "default": "m"}"#
        #expect(try field(#"{"path": "/rows", "each": \#(mapped), "map": {"a": 1}, "default": "outer"}"#, #"{"rows": \#(rows)}"#)
            == .string("outer"))
        let kept = #"{"path": "/cells", "each": {"path": "/n", "type": "integer"}, "type": "array"}"#
        #expect(try field(#"{"path": "/rows", "each": \#(kept)}"#, #"{"rows": \#(rows)}"#)
            == .array([.array([.integer(1)]), .array([])]))
        #expect(try field(#"{"path": "/rows", "each": \#(mapped)}"#, #"{"rows": \#(rows)}"#)
            == .array([.string("m"), .string("m")]))
    }

    // MARK: type

    @Test func typeSingleAndList() throws {
        #expect(try field(#"{"path": "/v", "type": "string"}"#, #"{"v": "x"}"#) == .string("x"))
        #expect(try field(#"{"path": "/v", "type": "string"}"#, #"{"v": 1}"#) == nil)
        #expect(try field(#"{"path": "/v", "type": ["string", "null"]}"#, #"{"v": null}"#) == .null)
        #expect(try field(#"{"path": "/v", "type": ["string", "null"]}"#, #"{"v": []}"#) == nil)
        #expect(try field(#"{"path": "/v", "type": "unheard-of"}"#, #"{"v": 1}"#) == nil)
    }

    @Test func idRejectsTheEmptyString() throws {
        #expect(try field(#"{"path": "/v", "type": "id"}"#, #"{"v": "s1"}"#) == .string("s1"))
        #expect(try field(#"{"path": "/v", "type": "id"}"#, #"{"v": ""}"#) == nil)
    }

    @Test func integerAcceptsOnlyIntegerLiterals() throws {
        let spec = #"{"path": "/v", "type": "integer"}"#
        #expect(try field(spec, #"{"v": 1}"#) == .integer(1))
        #expect(try field(spec, #"{"v": 1.0}"#) == nil)
        #expect(try field(spec, #"{"v": true}"#) == nil)
    }

    @Test func numberAcceptsIntegersAndFractionsButNoBool() throws {
        let spec = #"{"path": "/v", "type": "number"}"#
        #expect(try field(spec, #"{"v": 1}"#) == .integer(1))
        #expect(try field(spec, #"{"v": 1.5}"#) == .number(1.5))
        #expect(try field(spec, #"{"v": true}"#) == nil)
    }

    @Test func remainingTypeNames() throws {
        #expect(try field(#"{"path": "/v", "type": "boolean"}"#, #"{"v": false}"#) == .bool(false))
        #expect(try field(#"{"path": "/v", "type": "boolean"}"#, #"{"v": 0}"#) == nil)
        #expect(try field(#"{"path": "/v", "type": "object"}"#, #"{"v": {}}"#) == .object([:]))
        #expect(try field(#"{"path": "/v", "type": "array"}"#, #"{"v": []}"#) == .array([]))
        #expect(try field(#"{"path": "/v", "type": "any"}"#, #"{"v": null}"#) == .null)
    }

    // MARK: default and note

    @Test func defaultIsUsedWhenTheStepsYieldNothing() throws {
        let spec = #"{"path": "/e", "map": {"Stop": "turn.stop"}, "default": "unknown"}"#
        #expect(try field(spec, #"{"e": "Stop"}"#) == .string("turn.stop"))
        #expect(try field(spec, #"{"e": "Nope"}"#) == .string("unknown"))
        #expect(try field(spec, #"{}"#) == .string("unknown"))
    }

    @Test func noteIsIgnored() throws {
        #expect(try field(#"{"path": "/v", "note": "documentation only"}"#, #"{"v": 1}"#) == .integer(1))
    }

    @Test func unknownRuleKeyLeavesTheFieldAbsentDespiteADefault() throws {
        #expect(try field(#"{"path": "/v", "regex": "x", "default": "d"}"#, #"{"v": "x"}"#) == nil)
    }

    // MARK: rule lists

    @Test func firstRuleWhoseWhenHoldsDecidesEvenWithoutAValue() throws {
        let spec = #"""
            [{"when": [{"path": "/e", "in": ["SubagentStop"]}], "path": "/agent_path"},
             {"path": "/path"}]
            """#
        #expect(try field(spec, #"{"e": "SubagentStop", "path": "/parent"}"#) == nil)
        #expect(try field(spec, #"{"e": "SubagentStop", "agent_path": "/child", "path": "/parent"}"#) == .string("/child"))
        #expect(try field(spec, #"{"e": "Stop", "path": "/parent"}"#) == .string("/parent"))
    }

    @Test func noRuleWhoseWhenHoldsLeavesTheFieldAbsent() throws {
        let spec = #"[{"when": [{"path": "/e", "in": ["A"]}], "path": "/v", "default": 0}]"#
        #expect(try field(spec, #"{"e": "B", "v": 1}"#) == nil)
    }

    // MARK: document

    @Test func unknownFormatYieldsAnEmptyResult() throws {
        let document = try MappingDocument(data: Data(#"""
            {"format": 2, "block": "b", "core": {"kind": {"default": "unknown"}}, "fields": {"f": {"path": "/v"}}}
            """#.utf8))
        let result = MappingInterpreter.apply(document, to: try json(#"{"v": 1}"#))
        #expect(result == MappingResult(blockName: "b"))
    }

    @Test func documentReadsItsHeaderAndIgnoresUnknownKeys() throws {
        let data = Data(#"""
            {"format": 1, "revision": 3, "source": "claude-code", "block": "cc", "observed": ["2.1"],
             "future": {"anything": true}, "core": {"session": {"path": "/s"}}}
            """#.utf8)
        let document = try MappingDocument(data: data)
        #expect(document.format == 1)
        #expect(document.revision == 3)
        #expect(document.source == "claude-code")
        #expect(document.block == "cc")
        #expect(document.document == MappingDocument.hookEvent)
        #expect(document.core == [MappingDocument.Field(name: "session", spec: .object(["path": .string("/s")]))])
        #expect(document.fields.isEmpty)

        let status = try MappingDocument(data: Data(#"{"format": 1, "block": "b", "document": "session-status"}"#.utf8))
        #expect(status.document == MappingDocument.sessionStatus)
    }

    @Test func blockIsPresentEvenWhenEmpty() throws {
        let document = try MappingDocument(data: Data(#"{"format": 1, "block": "cc", "core": {"s": {"path": "/s"}}, "fields": {"f": {"path": "/f"}}}"#.utf8))
        let result = MappingInterpreter.apply(document, to: try json(#"{"s": "x"}"#))
        #expect(result.jsonValue == .object(["s": .string("x"), "cc": .object([:])]))
    }

    @Test func unparseablePayloadStillYieldsDefaults() throws {
        let document = try MappingDocument(data: Data(#"""
            {"format": 1, "block": "cc",
             "core": {"kind": {"path": "/e", "map": {"Stop": "turn.stop"}, "default": "unknown"}, "session": {"path": "/s"}},
             "fields": {"kind": {"path": "/e", "type": "string", "default": "unknown"}}}
            """#.utf8))
        // What a caller passes when the payload isn't even JSON.
        for payload in [JSONValue.null, .string("{garbage"), .array([.integer(1)])] {
            let result = MappingInterpreter.apply(document, to: payload)
            #expect(result.jsonValue == .object(["kind": .string("unknown"), "cc": .object(["kind": .string("unknown")])]))
        }
    }

    // MARK: drift

    @Test func pathFallbackAbsorbsARenamedKey() throws {
        let original = #"{"format": 1, "block": "b", "fields": {"rollout": {"path": "/agent_transcript_path", "type": "string"}}}"#
        let drifted = #"{"format": 1, "block": "b", "fields": {"rollout": {"path": ["/child_transcript_path", "/agent_transcript_path"], "type": "string"}}}"#
        let old = try json(#"{"agent_transcript_path": "/tmp/a.jsonl"}"#)
        let new = try json(#"{"child_transcript_path": "/tmp/a.jsonl"}"#)

        let expected = MappingInterpreter.apply(try MappingDocument(data: Data(original.utf8)), to: old)
        #expect(expected.block["rollout"] == .string("/tmp/a.jsonl"))
        let document = try MappingDocument(data: Data(drifted.utf8))
        #expect(MappingInterpreter.apply(document, to: old) == expected)
        #expect(MappingInterpreter.apply(document, to: new) == expected)
    }

    // MARK: Python parity

    @Test func stringsMatchByCodePoints() throws {
        // The mapping uses NFC "é", the payload NFD; apply.py matches nothing.
        let document = try MappingDocument(data: Data(#"""
            {"format": 1, "block": "b", "core": {},
             "fields": {"w": {"when": [{"path": "/e", "in": ["\u00e9"]}], "path": "/e"},
                        "m": {"path": "/e", "map": {"\u00e9": "hit"}},
                        "k": {"path": "/\u00e9"}}}
            """#.utf8))
        let result = MappingInterpreter.apply(document, to: try json(#"{"e": "e\u0301", "e\u0301": 1}"#))
        #expect(result == MappingResult(blockName: "b"))
        // The same mapping on an NFC payload hits all three.
        let hit = MappingInterpreter.apply(document, to: try json(#"{"e": "\u00e9", "\u00e9": 1}"#))
        #expect(hit.block == ["w": .string("\u{E9}"), "m": .string("hit"), "k": .integer(1)])
    }

    @Test func fieldNamesDifferingOnlyInNormalizationStayDistinct() throws {
        let document = try MappingDocument(data: Data(#"""
            {"format": 1, "block": "b", "fields": {"\u00e9": {"default": 1}, "e\u0301": {"default": 2}}}
            """#.utf8))
        let block = MappingInterpreter.apply(document, to: .null).block
        #expect(block.count == 2)
        #expect(block[JSONKey("\u{E9}")] == .integer(1))
        #expect(block[JSONKey("e\u{301}")] == .integer(2))
    }

    @Test func integersBeyondInt64AreIntegersAndNumbers() throws {
        #expect(try field(#"{"path": "/v", "type": "integer"}"#, #"{"v": 18446744073709551616}"#)
            == .bigInteger("18446744073709551616"))
        #expect(try field(#"{"path": "/v", "type": "number"}"#, #"{"v": -9223372036854775809}"#)
            == .bigInteger("-9223372036854775809"))
    }

    // MARK: depth

    /// The deepest result there is (see `MappingResult.maxDepth`): a block
    /// field of 509 nested `each`, as many as a 512-deep document holds,
    /// around a string parsed 512 deep. It is 1023 levels deep; a document with
    /// one `each` more is rejected. On a small stack: the interpreter keeps
    /// nested `each` on a stack of its own, not the thread's.
    @Test func nestedEachAroundTheDeepestParsedValueGivesTheDeepestResult() async throws {
        func document(eachLevels: Int) -> Data {
            var rule = #"{"path": "", "parse": "json"}"#
            for level in (0..<eachLevels).reversed() {
                rule = #"{"path": "\#(level == 0 ? "/x" : "")", "each": \#(rule)}"#
            }
            return Data(#"{"format": 1, "block": "b", "fields": {"f": \#(rule)}}"#.utf8)
        }
        #expect(throws: JSONParseError.self) { try MappingDocument(data: document(eachLevels: 510)) }
        let deepest = try MappingDocument(data: document(eachLevels: 509))
        let parsed = nestedJSON(.mixed, depth: 512).replacingOccurrences(of: "\"", with: #"\""#)
        let payload = try json(#"{"x": "# + nestedJSON(.arrays, depth: 509, around: "\"\(parsed)\"") + "}")
        let (fits, oneLevelTooDeep) = try await onSmallStack {
            let result = MappingInterpreter.apply(deepest, to: payload).jsonValue
            let serialized = result.serialized()
            return (try JSONReader.read(serialized, maxDepth: 1023) == result,
                    (try? JSONReader.read(serialized, maxDepth: 1022)) == nil)
        }
        #expect(fits)
        #expect(oneLevelTooDeep)
    }
}
