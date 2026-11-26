import Foundation
import Testing
@testable import SubspaceKit

// MARK: - Helpers

/// A fresh, empty directory; removed when the test's `defer` runs.
func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SubspaceKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A version-1 envelope around `payload`; `terminal` is left out when nil.
func envelopeJSON(source: String = "claude-code", v: Any = 1, ts: Int = 1_790_000_000,
                          pid: Any = 4242, terminal: Any? = nil, payload: [String: Any]) -> Data {
    var envelope: [String: Any] = ["v": v, "source": source, "ts": ts, "pid": pid, "payload": payload]
    if let terminal { envelope["terminal"] = terminal }
    return try! JSONSerialization.data(withJSONObject: envelope)
}

/// Like `envelopeJSON(source:payload:)`, but with the payload's text spliced in
/// as is, so a payload that `JSONSerialization` would alter (keys differing
/// only in normalization, integers beyond `UInt64`) reaches the reader intact.
func envelopeJSON(source: String = "claude-code", rawPayload: Data) -> Data {
    Data(#"{"v":1,"source":"\#(source)","ts":1790000000,"pid":4242,"payload":"#.utf8) + rawPayload + Data("}".utf8)
}

/// A captured payload from `Fixtures/` (see its README), as its file's bytes.
func capturedPayloadData(_ path: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(path)", withExtension: nil))
    return try Data(contentsOf: url)
}

/// The captured PostToolUse payload with `members` added to the object that
/// opens at `marker`: `{` for the payload itself, or its `tool_input`, which
/// the claude-code mapping copies whole (`type: any`) into the mapped result.
func postToolUse(adding members: String, after marker: String = #""tool_input":{"#) throws -> Data {
    let text = String(decoding: try capturedPayloadData("claude-code/009-PostToolUse.json"), as: UTF8.self)
    let range = try #require(text.range(of: marker))
    return Data(text.replacingCharacters(in: range, with: marker + members + ",").utf8)
}

/// How `nestedJSON` nests: arrays, objects, or both in turn.
enum Nesting: CaseIterable, Sendable {
    case arrays, objects, mixed
}

/// Compact JSON text of `depth` nested arrays or objects (each object's only
/// key is `a`) around `inner`, the outermost an array in `mixed`.
func nestedJSON(_ nesting: Nesting, depth: Int, around inner: String = "1") -> String {
    var open = "", close = ""
    for level in 0..<depth {
        let isArray = nesting == .arrays || (nesting == .mixed && level.isMultiple(of: 2))
        open += isArray ? "[" : #"{"a":"#
        close += isArray ? "]" : "}"
    }
    return open + inner + String(close.reversed())
}

/// Runs `body` on a thread with a 512 KB stack, the size of the cooperative
/// pool's and of dispatch's worker threads: code that recurses once per
/// nesting level takes about a kilobyte per level in a debug build, so on a
/// 512-deep value it crashes the test run here. The calling task waits
/// without blocking its thread.
func onSmallStack<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await onThread(stackSize: 512 * 1024, body)
}

/// Runs `body` on a thread of its own with `stackSize` bytes of stack; the
/// calling task waits without blocking its thread.
func onThread<T: Sendable>(stackSize: Int, _ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let thread = Thread { continuation.resume(with: Result { try body() }) }
        thread.stackSize = stackSize
        thread.start()
    }
}

private func payload(_ hook: String, session: String = "s1") -> [String: Any] {
    ["hook_event_name": hook, "session_id": session]
}

/// Writes an event file the way subspace does: a dot-file renamed into place (contract §4).
@discardableResult
func writeEvent(_ data: Data, in root: URL, day: String = "2026-10-01", name: String,
                        mtime: Date? = nil) throws -> URL {
    let folder = root.appendingPathComponent("events/\(day)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let temporary = folder.appendingPathComponent(".\(name).tmp")
    let file = folder.appendingPathComponent("\(name).json")
    try data.write(to: temporary)
    if let mtime { try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: temporary.path) }
    try FileManager.default.moveItem(at: temporary, to: file)
    return file
}

// MARK: - Roots

@Suite struct SubspaceRootTests {
    @Test func aChosenFolderWinsOverSubspaceDirWhichWinsOverTheGivenRoot() {
        let own = URL(fileURLWithPath: "/own", isDirectory: true)
        let chosen = URL(fileURLWithPath: "/chosen/./spool/", isDirectory: true)
        let shared = ["SUBSPACE_DIR": "/shared"]
        #expect(SubspaceRoot.resolve(own, chosen: chosen, environment: shared).path == "/chosen/spool")
        #expect(SubspaceRoot.resolve(own, chosen: nil, environment: shared).path == "/shared")
        #expect(SubspaceRoot.resolve(own, chosen: nil, environment: [:]).path == "/own")
        // An empty `SUBSPACE_DIR` counts as unset.
        #expect(SubspaceRoot.resolve(own, chosen: nil, environment: ["SUBSPACE_DIR": ""]).path == "/own")
        // A chosen folder without a path, e.g. a broken stored value, falls through.
        let empty = URL(string: "file:")
        #expect(SubspaceRoot.resolve(own, chosen: empty, environment: shared).path == "/shared")
    }

    @Test func choosingTheDefaultFolderChangesNoRoot() {
        let defaults: [SourceID: [URL]] = ["a": [URL(fileURLWithPath: "/a")], "b": [URL(fileURLWithPath: "/b")]]
        // The open panel hands out directories with a trailing slash.
        let same: [SourceID: URL] = ["a": URL(fileURLWithPath: "/a/", isDirectory: true)]
        #expect(!SubspaceRoot.rootsChange(defaults: defaults, from: [:], to: same))
        #expect(!SubspaceRoot.rootsChange(defaults: defaults, from: same, to: [:]))
        #expect(!SubspaceRoot.rootsChange(defaults: defaults, from: [:], to: [:]))
    }

    @Test func choosingAnotherFolderOrResettingChangesARoot() {
        let defaults: [SourceID: [URL]] = ["a": [URL(fileURLWithPath: "/a")], "b": [URL(fileURLWithPath: "/b")]]
        let chosen: [SourceID: URL] = ["b": URL(fileURLWithPath: "/chosen", isDirectory: true)]
        #expect(SubspaceRoot.rootsChange(defaults: defaults, from: [:], to: chosen))
        // Reset: back to the default.
        #expect(SubspaceRoot.rootsChange(defaults: defaults, from: chosen, to: [:]))
        #expect(SubspaceRoot.rootsChange(defaults: defaults, from: chosen, to: ["b": URL(fileURLWithPath: "/other")]))
        // A choice for a source that isn't registered moves nothing.
        #expect(!SubspaceRoot.rootsChange(defaults: defaults, from: [:], to: ["gone": URL(fileURLWithPath: "/x")]))
    }

    /// A chosen folder replaces all of a source's roots, so choosing its primary
    /// one still stops reading the others.
    @Test func choosingThePrimaryOfSeveralRootsChangesTheRoots() {
        let defaults: [SourceID: [URL]] = ["a": [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/a-app")]]
        let primary: [SourceID: URL] = ["a": URL(fileURLWithPath: "/a/", isDirectory: true)]
        #expect(SubspaceRoot.rootsChange(defaults: defaults, from: [:], to: primary))
        #expect(SubspaceRoot.rootsChange(defaults: defaults, from: primary, to: [:]))
        #expect(!SubspaceRoot.rootsChange(defaults: defaults, from: primary, to: ["a": URL(fileURLWithPath: "/a")]))
        #expect(!SubspaceRoot.rootsChange(defaults: defaults, from: [:], to: [:]))
    }
}

// MARK: - Event files

@Suite struct SpoolFileTests {
    @Test func readsTheEnvelope() throws {
        let envelope = try SpoolFile.envelope(from: envelopeJSON(payload: payload("Stop")))
        #expect(envelope.source == "claude-code")
        #expect(envelope.pid == 4242)
        #expect(envelope.receivedAt == Date(timeIntervalSince1970: 1_790_000_000))
        let object = try JSONSerialization.jsonObject(with: envelope.payload) as? [String: String]
        #expect(object == ["hook_event_name": "Stop", "session_id": "s1"])
    }

    @Test func pidIsOptional() throws {
        #expect(try SpoolFile.envelope(from: envelopeJSON(pid: NSNull(), payload: payload("Stop"))).pid == nil)
    }

    @Test func rejectsUnknownVersionsAndBrokenFiles() {
        #expect(throws: SpoolFileError.unknownVersion) { try SpoolFile.envelope(from: envelopeJSON(v: 2, payload: [:])) }
        #expect(throws: SpoolFileError.unknownVersion) { try SpoolFile.envelope(from: envelopeJSON(v: "1", payload: [:])) }
        #expect(throws: SpoolFileError.notAJSONObject) { try SpoolFile.envelope(from: Data("[1]".utf8)) }
        #expect(throws: (any Error).self) { try SpoolFile.envelope(from: Data("{\"v\":1,".utf8)) }
        let noPayload = try! JSONSerialization.data(withJSONObject: ["v": 1, "source": "claude-code", "ts": 1])
        #expect(throws: SpoolFileError.missingField("payload")) { try SpoolFile.envelope(from: noPayload) }
    }

    /// Contract §4: the payload is the hook's stdin. Keys that differ only in
    /// Unicode normalization are distinct keys there (and in apply.py), so they
    /// must survive reading and mapping.
    @Test func keysDifferingOnlyInNormalizationStayDistinct() throws {
        let nfc = "caf\u{E9}", nfd = "cafe\u{301}"
        let raw = try postToolUse(adding: #""\#(nfc)":"nfc","\#(nfd)":"nfd""#, after: "{")
        let data = envelopeJSON(rawPayload: raw)

        let envelope = try SpoolFile.envelope(from: data)
        let payload = try JSONValue(data: envelope.payload)
        #expect(payload == (try JSONValue(data: raw)))
        guard case let .object(members) = payload else { Issue.record("expected an object"); return }
        #expect(members[JSONKey(nfc)] == .string("nfc"))
        #expect(members[JSONKey(nfd)] == .string("nfd"))

        let document = try #require(MappingLoader.bundledDocument(named: "claude-code"))
        guard case let .mapped(mappedEnvelope, result) = SpoolFile.parsed(from: data, documents: ["claude-code": document]) else {
            Issue.record("expected .mapped"); return
        }
        #expect(mappedEnvelope == envelope)
        #expect(result == MappingInterpreter.apply(document, to: try JSONValue(data: raw)))
    }

    /// Numbers keep their value and JSON type as the mapping parser reads them:
    /// integers beyond `UInt64` stay exact, `1.0` stays a number, a long
    /// fraction stays the same double.
    @Test func numbersStayExact() throws {
        let raw = try postToolUse(adding: """
            "big":18446744073709551617123,"bigger":123456789012345678901234567890123456789012345,\
            "float":1.0,"fraction":0.1000000000000000055511151231257827021181583404541015625
            """)
        let data = envelopeJSON(rawPayload: raw)

        let envelope = try SpoolFile.envelope(from: data)
        #expect(try JSONValue(data: envelope.payload) == JSONValue(data: raw))

        let document = try #require(MappingLoader.bundledDocument(named: "claude-code"))
        guard case let .mapped(_, result) = SpoolFile.parsed(from: data, documents: ["claude-code": document]) else {
            Issue.record("expected .mapped"); return
        }
        #expect(result == MappingInterpreter.apply(document, to: try JSONValue(data: raw)))
    }

    /// A literal beyond the double range is read as infinity; the payload
    /// re-serialized for the envelope must read back as the same value, not as `null`.
    @Test func anOverflowingNumberSurvivesTheEnvelope() throws {
        let raw = try postToolUse(adding: #""huge":1e400,"hugeNegative":-1e400"#)
        let envelope = try SpoolFile.envelope(from: envelopeJSON(rawPayload: raw))
        let original = try JSONValue(data: raw)
        #expect(try JSONValue(data: envelope.payload) == original)
        #expect(String(decoding: envelope.payload, as: UTF8.self).contains(#""huge":1e999,"hugeNegative":-1e999"#))
    }

    /// A payload nested as deep as the reader accepts: the envelope, the
    /// payload and its `tool_input` take three of the 512 levels. It is read,
    /// re-serialized and mapped on a 512 KB stack, like the store does on its
    /// worker threads, and comes out unchanged.
    @Test(arguments: Nesting.allCases)
    func theDeepestPayloadIsReadOnASmallStack(nesting: Nesting) async throws {
        let raw = try postToolUse(adding: #""deep":"# + nestedJSON(nesting, depth: 509))
        let data = envelopeJSON(rawPayload: raw)
        #expect(throws: JSONParseError.self) {
            try SpoolFile.envelope(from: envelopeJSON(rawPayload: postToolUse(adding: #""deep":"# + nestedJSON(nesting, depth: 510))))
        }
        let document = try #require(MappingLoader.bundledDocument(named: "claude-code"))
        let (unchanged, mapped) = try await onSmallStack {
            let envelope = try SpoolFile.envelope(from: data)
            let original = try JSONValue(data: raw)
            guard case let .mapped(_, result) = SpoolFile.parsed(from: data, documents: ["claude-code": document]) else {
                return (false, false)
            }
            return (try JSONValue(data: envelope.payload) == original, result == MappingInterpreter.apply(document, to: original))
        }
        #expect(unchanged)
        #expect(mapped)
    }

    /// Today's accept/reject behavior for `v`, `ts` and `pid` values that are
    /// numbers of another JSON type than the contract's.
    @Test func numericFieldsAcceptEqualNumbers() throws {
        func envelope(v: String = "1", ts: String = "1790000000", pid: String = "4242") throws -> Envelope {
            try SpoolFile.envelope(from: Data(#"{"v":\#(v),"source":"claude-code","ts":\#(ts),"pid":\#(pid),"payload":{}}"#.utf8))
        }
        #expect(try envelope(v: "1.0").source == "claude-code")
        #expect(try envelope(v: "10e-1").source == "claude-code")
        #expect(throws: SpoolFileError.unknownVersion) { try envelope(v: "1.5") }
        #expect(throws: SpoolFileError.unknownVersion) { try envelope(v: "null") }
        #expect(try envelope(ts: "1790000000.25").receivedAt == Date(timeIntervalSince1970: 1_790_000_000.25))
        #expect(throws: SpoolFileError.missingField("ts")) { try envelope(ts: "\"1\"") }
        #expect(try envelope(pid: "4242.0").pid == 4242)
        #expect(try envelope(pid: "1.5").pid == nil)
        #expect(try envelope(pid: "2147483648").pid == nil)
        #expect(try envelope(pid: "18446744073709551617123").pid == nil)
        #expect(try envelope(pid: "\"4242\"").pid == nil)
        // JSON booleans are not numbers, though Foundation reads them as 1.
        #expect(throws: SpoolFileError.unknownVersion) { try envelope(v: "true") }
        #expect(throws: SpoolFileError.missingField("ts")) { try envelope(ts: "true") }
        #expect(try envelope(pid: "true").pid == nil)
    }

    /// Contract §4: the hook copies terminal identifiers from its environment
    /// into `terminal`; the package passes them on as captured.
    @Test func passesOnTheCapturedTerminal() throws {
        let terminal = try capturedTerminal()
        let envelope = try SpoolFile.envelope(from: envelopeJSON(terminal: terminal, payload: capturedPayload("claude-code/008-Stop.json")))
        #expect(envelope.terminal == capturedTerminalEntries)
    }

    /// `Envelope` is `Codable`: `terminal` survives a round trip, and data
    /// encoded before the field existed still decodes, without identifiers.
    @Test func codableKeepsTheTerminalAndReadsDataWithoutIt() throws {
        let envelope = try SpoolFile.envelope(from: envelopeJSON(terminal: capturedTerminal(), payload: capturedPayload("claude-code/008-Stop.json")))
        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(Envelope.self, from: encoded)
        #expect(decoded == envelope)
        #expect(decoded.terminal == capturedTerminalEntries)

        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object.removeValue(forKey: "terminal") != nil)
        let withoutTerminal = try JSONDecoder().decode(Envelope.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(withoutTerminal.terminal == [:])
        #expect(withoutTerminal.source == envelope.source)
        #expect(withoutTerminal.pid == envelope.pid)
        #expect(withoutTerminal.payload == envelope.payload)
        #expect(withoutTerminal.receivedAt == envelope.receivedAt)
    }

    /// `terminal` is optional (contract §4): without it the envelope has none.
    @Test func aFileWithoutTerminalHasNone() throws {
        let envelope = try SpoolFile.envelope(from: envelopeJSON(payload: capturedPayload("claude-code/008-Stop.json")))
        #expect(envelope.terminal == [:])
    }

    /// A `terminal` that is not an object costs the identifiers, not the event.
    @Test(arguments: ["null", #""WarpTerminal""#, #"["WarpTerminal"]"#, "42"])
    func aTerminalThatIsNoObjectIsDropped(json: String) throws {
        let terminal = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
        let captured = try capturedPayload("claude-code/008-Stop.json")
        let envelope = try SpoolFile.envelope(from: envelopeJSON(terminal: terminal, payload: captured))
        #expect(envelope.terminal == [:])
        #expect(envelope.source == "claude-code")
        #expect(envelope.pid == 4242)
        #expect(envelope.receivedAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(try JSONValue(data: envelope.payload) == JSONValue(data: JSONSerialization.data(withJSONObject: captured)))
    }

    /// Only string members are identifiers; others are left out, the rest kept.
    @Test func onlyStringMembersAreKept() throws {
        var terminal = try capturedTerminal()
        terminal["KITTY_WINDOW_ID"] = 3
        terminal["TMUX"] = true
        terminal["TMUX_PANE"] = NSNull()
        terminal["WEZTERM_PANE"] = ["id": "1"]
        let envelope = try SpoolFile.envelope(from: envelopeJSON(terminal: terminal, payload: capturedPayload("claude-code/008-Stop.json")))
        #expect(envelope.terminal == capturedTerminalEntries)
    }

    /// The package doesn't filter names; ignoring unknown ones is the app's job (contract §4).
    @Test func anUnknownNamePassesThrough() throws {
        let envelope = try SpoolFile.envelope(from: envelopeJSON(terminal: ["FOO_BAR": "x"], payload: capturedPayload("claude-code/008-Stop.json")))
        #expect(envelope.terminal == ["FOO_BAR": "x"])
    }

    /// Names that differ only in Unicode normalization are one `String` key;
    /// the one first in code point order wins (here the decomposed one), on
    /// every read.
    @Test func namesDifferingOnlyInNormalizationKeepTheFirstInCodePointOrder() throws {
        let nfc = "caf\u{E9}", nfd = "cafe\u{301}"
        let raw = Data(#"{"v":1,"source":"claude-code","ts":1790000000,"terminal":{"\#(nfc)":"nfc","\#(nfd)":"nfd"},"payload":"#.utf8)
            + (try capturedPayloadData("claude-code/008-Stop.json")) + Data("}".utf8)
        let envelope = try SpoolFile.envelope(from: raw)
        #expect(envelope.terminal.count == 1)
        #expect(envelope.terminal[nfc] == "nfd")
    }
}

// MARK: - Parsed event files

/// A captured payload from `Fixtures/` (see its README), as a JSON object.
func capturedPayload(_ path: String) throws -> [String: Any] {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(path)", withExtension: nil))
    return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

/// The captured envelope `terminal` from `Fixtures/` (see its README), as a JSON object.
func capturedTerminal() throws -> [String: Any] {
    try capturedPayload("claude-code/terminal.json")
}

/// The entries of `Fixtures/claude-code/terminal.json`, written out.
let capturedTerminalEntries: [String: String] = [
    "TERM_PROGRAM": "WarpTerminal",
    "TERM_PROGRAM_VERSION": "v0.2026.10.07.08.29.stable_00",
    "__CFBundleIdentifier": "dev.warp.Warp-Stable",
    "WARP_FOCUS_URL": "warp://session/16e5a860f58d4186bd579a30d87d0d18",
    "WARP_TERMINAL_SESSION_UUID": "16e5a860f58d4186bd579a30d87d0d18",
]

@Suite struct ParsedSpoolFileTests {
    private static let claudeCode = MappingLoader.bundledDocument(named: "claude-code")
    private static let codex = MappingLoader.bundledDocument(named: "codex")

    @Test(arguments: [("claude-code", "claude-code/008-Stop.json"), ("codex", "codex/005-Stop.json")])
    func mapsAKnownSourceWithItsDocument(source: String, fixture: String) throws {
        let captured = try capturedPayload(fixture)
        let documents: [SourceID: MappingDocument?] = ["claude-code": Self.claudeCode, "codex": Self.codex]
        let document = try #require(documents[SourceID(rawValue: source)] ?? nil)
        let data = envelopeJSON(source: source, payload: captured)

        guard case let .mapped(envelope, result) = SpoolFile.parsed(from: data, documents: documents) else {
            Issue.record("expected .mapped"); return
        }
        #expect(envelope.source == SourceID(rawValue: source))
        #expect(envelope.pid == 4242)
        #expect(envelope.receivedAt == Date(timeIntervalSince1970: 1_790_000_000))
        let payload = try JSONValue(data: JSONSerialization.data(withJSONObject: captured))
        #expect(result == MappingInterpreter.apply(document, to: payload))
        #expect(!result.core.isEmpty)
    }

    @Test func readsTheFileAtAURL() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeEvent(envelopeJSON(payload: capturedPayload("claude-code/008-Stop.json")), in: root, name: "1-1-a")
        let documents: [SourceID: MappingDocument?] = ["claude-code": Self.claudeCode]

        guard case let .mapped(envelope, result) = SpoolFile.parsed(from: file, documents: documents) else {
            Issue.record("expected .mapped"); return
        }
        #expect(envelope.source == "claude-code")
        let fromData = SpoolFile.parsed(from: try Data(contentsOf: file), documents: documents)
        guard case let .mapped(_, expected) = fromData else { Issue.record("expected .mapped"); return }
        #expect(result == expected)
    }

    @Test func aKnownSourceWithoutDocumentStaysWhole() throws {
        let data = envelopeJSON(source: "codex", payload: try capturedPayload("codex/005-Stop.json"))
        guard case let .whole(envelope) = SpoolFile.parsed(from: data, documents: ["codex": nil]) else {
            Issue.record("expected .whole"); return
        }
        #expect(envelope.source == "codex")
        #expect(envelope.pid == 4242)
    }

    @Test func aSourceNotAmongTheDocumentsIsForeign() throws {
        let data = envelopeJSON(source: "codex", payload: try capturedPayload("codex/005-Stop.json"))
        guard case let .foreign(envelope) = SpoolFile.parsed(from: data, documents: ["claude-code": Self.claudeCode]) else {
            Issue.record("expected .foreign"); return
        }
        #expect(envelope.source == "codex")
    }

    /// The parsed outcome carries the envelope's `terminal` whether the
    /// payload is mapped, kept whole or belongs to another source.
    @Test func everyOutcomeCarriesTheTerminal() throws {
        let terminal = try capturedTerminal()
        let expected = capturedTerminalEntries

        let claudeCode = envelopeJSON(terminal: terminal, payload: try capturedPayload("claude-code/008-Stop.json"))
        guard case let .mapped(mapped, _) = SpoolFile.parsed(from: claudeCode, documents: ["claude-code": Self.claudeCode]) else {
            Issue.record("expected .mapped"); return
        }
        #expect(mapped.terminal == expected)

        guard case let .whole(whole) = SpoolFile.parsed(from: claudeCode, documents: ["claude-code": nil]) else {
            Issue.record("expected .whole"); return
        }
        #expect(whole.terminal == expected)

        let codex = envelopeJSON(source: "codex", terminal: terminal, payload: try capturedPayload("codex/005-Stop.json"))
        guard case let .foreign(foreign) = SpoolFile.parsed(from: codex, documents: ["claude-code": Self.claudeCode]) else {
            Issue.record("expected .foreign"); return
        }
        #expect(foreign.terminal == expected)
    }

    @Test func unreadableFilesFail() throws {
        let documents: [SourceID: MappingDocument?] = ["claude-code": Self.claudeCode]
        let captured = try capturedPayload("claude-code/008-Stop.json")

        guard case let .failed(error) = SpoolFile.parsed(from: envelopeJSON(v: 2, payload: captured), documents: documents) else {
            Issue.record("expected .failed for an unknown v"); return
        }
        #expect(error as? SpoolFileError == .unknownVersion)

        guard case .failed = SpoolFile.parsed(from: Data("{\"v\":1,".utf8), documents: documents) else {
            Issue.record("expected .failed for broken JSON"); return
        }

        let noSource = try JSONSerialization.data(withJSONObject: ["v": 1, "ts": 1, "payload": captured])
        guard case let .failed(error) = SpoolFile.parsed(from: noSource, documents: documents) else {
            Issue.record("expected .failed for a missing field"); return
        }
        #expect(error as? SpoolFileError == .missingField("source"))

        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("SubspaceKitTests-\(UUID().uuidString).json")
        guard case .failed = SpoolFile.parsed(from: missing, documents: documents) else {
            Issue.record("expected .failed for a missing file"); return
        }
    }
}

// MARK: - Scanner

@Suite struct SpoolScannerTests {
    @Test func returnsEachEventFileOnceAndIgnoresTheRest() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try writeEvent(Data("{}".utf8), in: root, name: "1-1-a")
        let day = first.deletingLastPathComponent()
        try Data().write(to: day.appendingPathComponent(".2-1-b.tmp"))
        try Data().write(to: day.appendingPathComponent(".hidden.json"))
        try Data().write(to: day.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: day.appendingPathComponent("nested.json"), withIntermediateDirectories: true)

        var scanner = SpoolScanner(root: root)
        #expect(scanner.scanAll().map(\.lastPathComponent) == [first.lastPathComponent])
        let second = try writeEvent(Data("{}".utf8), in: root, name: "2-1-b")
        #expect(scanner.scanAll().map(\.lastPathComponent) == [second.lastPathComponent])
        #expect(scanner.scanAll().isEmpty)
    }

    @Test func ordersByMtimeThenNameAcrossDays() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        try writeEvent(Data(), in: root, day: "2026-10-02", name: "c", mtime: t.addingTimeInterval(2))
        try writeEvent(Data(), in: root, day: "2026-10-01", name: "b", mtime: t.addingTimeInterval(1))
        try writeEvent(Data(), in: root, day: "2026-10-02", name: "a", mtime: t.addingTimeInterval(1))
        try writeEvent(Data(), in: root, day: "2026-10-01", name: "z", mtime: t)

        var scanner = SpoolScanner(root: root)
        #expect(scanner.scanAll().map(\.lastPathComponent) == ["z.json", "a.json", "b.json", "c.json"])
    }

    @Test func aChangedDayFolderIsScannedAlone() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var scanner = SpoolScanner(root: root)
        #expect(scanner.scanAll().isEmpty)

        let today = try writeEvent(Data(), in: root, day: "2026-10-02", name: "a")
        try writeEvent(Data(), in: root, day: "2026-10-01", name: "b")
        #expect(scanner.scan(changed: [today.deletingLastPathComponent()]).map(\.lastPathComponent) == ["a.json"])
        // Anything else, e.g. a new day folder in `events/`, rescans everything.
        #expect(scanner.scan(changed: [root.appendingPathComponent("events")]).map(\.lastPathComponent) == ["b.json"])
    }

    @Test func aReportedFileScansItsDayAndSchemaOrModelNothing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var scanner = SpoolScanner(root: root)
        #expect(scanner.scanAll().isEmpty)

        let t = Date(timeIntervalSince1970: 1_790_000_000)
        let today = try writeEvent(Data(), in: root, day: "2026-10-02", name: "a", mtime: t)
        try writeEvent(Data(), in: root, day: "2026-10-02", name: "c", mtime: t.addingTimeInterval(1))
        try writeEvent(Data(), in: root, day: "2026-10-01", name: "b")
        // Resolved, as FSEvents reports it: only the trailing components count.
        let resolved = URL(fileURLWithPath: root.resolvingSymlinksInPath().path, isDirectory: true)
        let schema: Set<URL> = [resolved.appendingPathComponent("schema", isDirectory: true),
                                resolved.appendingPathComponent("model/claude-code.json"),
                                resolved.appendingPathComponent("events/2026-10-01/.d.tmp")]
        #expect(scanner.scan(changed: schema).isEmpty)
        let reported = resolved.appendingPathComponent("events/2026-10-02/\(today.lastPathComponent)")
        // Its day is scanned, so the day's other new file comes too.
        #expect(scanner.scan(changed: [reported]).map(\.lastPathComponent) == ["a.json", "c.json"])
        #expect(scanner.scan(changed: [root.appendingPathComponent("events")]).map(\.lastPathComponent) == ["b.json"])
    }

    @Test func forgetsDaysThatRetentionDeleted() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeEvent(Data(), in: root, name: "a")
        var scanner = SpoolScanner(root: root)
        #expect(scanner.scanAll().count == 1)

        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        #expect(scanner.scanAll().isEmpty)
        // Proof the record was dropped: the same name counts as new again.
        try writeEvent(Data(), in: root, name: "a")
        #expect(scanner.scanAll().count == 1)
    }

    @Test func aMissingRootHasNoFiles() {
        var scanner = SpoolScanner(root: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"))
        #expect(scanner.scanAll().isEmpty)
        #expect(scanner.scan(changed: nil).isEmpty)
    }
}
