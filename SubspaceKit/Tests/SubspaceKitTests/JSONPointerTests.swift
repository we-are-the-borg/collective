import Foundation
import Testing
@testable import SubspaceKit

private let document: JSONValue = .object([
    "a": .object(["b": .string("deep")]),
    "x/y": .integer(1),
    "m~n": .integer(2),
    "list": .array([.string("zero"), .string("one")]),
    "gone": .null,
])

private func resolve(_ pointer: String) -> JSONValue? {
    JSONPointer(pointer)?.resolve(in: document)
}

@Suite struct JSONPointerTests {
    @Test func emptyPointerIsTheWholeDocument() {
        #expect(resolve("") == document)
    }

    @Test func nestedKeys() {
        #expect(resolve("/a/b") == .string("deep"))
    }

    @Test func escapedTokens() {
        #expect(resolve("/x~1y") == .integer(1))
        #expect(resolve("/m~0n") == .integer(2))
    }

    @Test func arrayIndex() {
        #expect(resolve("/list/1") == .string("one"))
    }

    @Test(arguments: ["/list/2", "/list/01", "/list/-", "/list/x", "/missing", "/a/b/c"])
    func unresolvablePointersYieldNothing(pointer: String) {
        #expect(JSONPointer(pointer) != nil)
        #expect(resolve(pointer) == nil)
    }

    @Test func keyHoldingNullExists() {
        #expect(resolve("/gone") == .null)
    }

    @Test func pointerWithoutLeadingSlashIsInvalid() {
        #expect(JSONPointer("a/b") == nil)
    }

    @Test func keysMatchByCodePoints() {
        let nfc: JSONValue = .object([JSONKey("\u{E9}"): .integer(1)])
        #expect(JSONPointer("/\u{E9}")?.resolve(in: nfc) == .integer(1))
        #expect(JSONPointer("/e\u{301}")?.resolve(in: nfc) == nil)
    }

    @Test func tokensSplitAndUnescapeByCodePoints() {
        // A combining mark after `/` or `~1` must not hide the separator or escape.
        let marked: JSONValue = .object([JSONKey("\u{301}"): .object([JSONKey("/\u{301}"): .integer(1)])])
        #expect(JSONPointer("/\u{301}/~1\u{301}")?.resolve(in: marked) == .integer(1))
    }
}
