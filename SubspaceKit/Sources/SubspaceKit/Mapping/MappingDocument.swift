import Foundation

/// A subspace mapping document (subspace `docs/model.md` §5): where each target
/// field sits in a raw payload, for one source.
///
/// Field specs stay raw `JSONValue`s. The interpreter has to treat malformed
/// rules exactly like the reference interpreter does (an unknown key, a `when`
/// that is not a list, …), so a typed model would only have to re-encode them.
public struct MappingDocument: Sendable, Equatable {
    /// Hook-event documents apply to an event's `payload`, session-status
    /// documents to a session status file (§12).
    public static let hookEvent = "hook-event"
    /// See `hookEvent`.
    public static let sessionStatus = "session-status"

    /// One target field and its raw rule.
    public struct Field: Sendable, Equatable {
        /// The target field's name.
        public let name: String
        /// The rule as written, interpreted only by `MappingInterpreter`.
        public let spec: JSONValue
    }

    /// Nil when absent or not an integer; the interpreter then applies nothing.
    /// Stricter than apply.py, whose `== 1` also accepts `1.0` and `true`.
    /// Deliberate: a format version is an integer.
    public let format: Int64?
    /// Which of two copies is newer (contract §12); nil when absent.
    public let revision: Int64?
    /// The source whose payloads this document maps.
    public let source: SourceID?
    /// Name of the source-specific block in a `MappingResult`.
    public let block: String
    /// What the document applies to: `hookEvent` or `sessionStatus`.
    public let document: String
    /// Sorted by name: the source order is lost in `JSONValue.object`, and
    /// fields don't depend on each other, so any fixed order will do.
    public let core: [Field]
    /// The block's fields, sorted by name like `core`.
    public let fields: [Field]

    /// Why a document was rejected.
    public enum DecodingError: Error, Equatable {
        /// The document is not a JSON object.
        case notAnObject
        /// `block` is missing or not a string.
        case missingBlock
    }

    /// Parses and decodes a document read from disk or the bundle.
    public init(data: Data) throws {
        try self.init(json: JSONValue(data: data))
    }

    /// Unknown top-level keys (`observed`, future ones) are ignored.
    ///
    /// Documents read from JSON (`init(data:)`, the loader) are at most 512 levels
    /// deep. A `JSONValue` built in code should be too: deeper documents can make
    /// the interpreter map results that nest deeper than the event store reads
    /// back (about twice that limit), and replay would skip those rows.
    public init(json: JSONValue) throws {
        // Differs from apply.py, which returns `{}` for a mapping that is not an
        // object: here it is rejected, and the loader then falls back to the
        // bundled copy.
        guard case let .object(object) = json else { throw DecodingError.notAnObject }
        // Differs from apply.py, which keys the block by whatever `block` holds
        // (`null` when missing, a number or bool as is) and raises for a list or
        // object: here anything but a string is rejected, with the same fallback.
        guard case let .string(block)? = object["block"] else { throw DecodingError.missingBlock }
        self.block = block
        if case let .integer(format)? = object["format"] { self.format = format } else { format = nil }
        if case let .integer(revision)? = object["revision"] { self.revision = revision } else { revision = nil }
        if case let .string(source)? = object["source"] { self.source = SourceID(rawValue: source) } else { source = nil }
        if case let .string(document)? = object["document"] { self.document = document } else { document = Self.hookEvent }
        core = Self.fields(object["core"])
        fields = Self.fields(object["fields"])
    }

    /// Anything but an object counts as no fields. Matches `or {}` in apply.py
    /// for an absent or falsy value (`null`, `false`, `0`, `""`, `[]`), but
    /// differs for a truthy non-object (e.g. a list), which crashes apply.py.
    private static func fields(_ value: JSONValue?) -> [Field] {
        guard case let .object(specs)? = value else { return [] }
        return specs.keys.sorted().map { Field(name: $0.string, spec: specs[$0]!) }
    }
}
