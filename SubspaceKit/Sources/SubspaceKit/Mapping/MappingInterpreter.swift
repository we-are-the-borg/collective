import Foundation
import os

/// The result of applying a mapping document to one payload. A field without
/// a value is absent; the block is always there, even when empty.
public struct MappingResult: Sendable, Equatable {
    /// Source-neutral target fields.
    public var core: [JSONKey: JSONValue]
    /// The document's `block`, the key the block sits under in `jsonValue`.
    public var blockName: String
    /// Source-specific fields.
    public var block: [JSONKey: JSONValue]

    /// Builds a result, e.g. as a test expectation.
    public init(core: [JSONKey: JSONValue] = [:], blockName: String, block: [JSONKey: JSONValue] = [:]) {
        self.core = core
        self.blockName = blockName
        self.block = block
    }

    /// `{ <core fields>, "<block>": { <block fields> } }`, the shape of the
    /// golden files. A core field named like the block is replaced by it, as in
    /// apply.py; `core` itself still holds it.
    public var jsonValue: JSONValue {
        var object = core
        object[JSONKey(blockName)] = .object(block)
        return .object(object)
    }

    /// The deepest `jsonValue` for a payload and a document the reader
    /// accepted, so the store reads back every result it writes: 2M − 1, with
    /// M = `JSONReader.maxDepth` and depth the arrays and objects on the
    /// longest path. A field can hold a value M deep (a string parsed, a
    /// payload copied with `path: ""`), and `each` nests such values further.
    ///
    /// A rule object r levels deep in its document gives at most 2M − r
    /// levels, for any value at most M deep it applies to (a payload or an
    /// element):
    /// - Without `each`: part of that value, a string parsed (and with `pick`
    ///   a part of it), or part of the document (`map`, `default`); at most M.
    /// - With `each`: an array of what its rules, at least r + 1 deep, give
    ///   for the elements of the value got so far, which is at most M deep as
    ///   above; at most 1 + 2M − (r + 1). (At r = M there is no such rule, and
    ///   the array is empty.)
    /// A field's rule is at least 3 deep (document, `core` or `fields`, rule),
    /// and in `jsonValue` a core field sits one level down, a block field two:
    /// 2M − 1. Reached by a block field of 509 nested `each` around a string
    /// parsed M deep (see `MappingInterpreterTests`).
    ///
    /// Holds for documents read from JSON (`MappingDocument(data:)`, the
    /// loader); one built with `init(json:)` from a deeper value can exceed it.
    static let maxDepth = 2 * JSONReader.maxDepth - 1

    /// Restores a result from its `jsonValue`, e.g. as read back from storage.
    /// The block name is not part of the shape, so the caller supplies it (the
    /// document's `block`). Nil unless `jsonValue` is an object holding an
    /// object under `blockName`. Exact except where `jsonValue` already lost
    /// information: a core field named like the block does not come back.
    init?(jsonValue: JSONValue, blockName: String) {
        guard case var .object(core) = jsonValue,
              case let .object(block)? = core.removeValue(forKey: JSONKey(blockName)) else { return nil }
        self.init(core: core, blockName: blockName, block: block)
    }
}

/// Applies mapping documents (subspace `docs/model.md` §5.1). Mirrors the
/// reference interpreter `tools/model/apply.py` step by step; where the two
/// could disagree, apply.py is right. The deliberate differences are noted
/// where they arise, here and in `JSONValue`, `JSONPointer`, `MappingDocument`.
public enum MappingInterpreter {
    /// The only document `format` this interpreter applies; others yield an empty result.
    public static let supportedFormat: Int64 = 1

    static let ruleKeys: Set<JSONKey> = ["when", "path", "parse", "pick", "each", "map", "type", "default", "note"]
    static let conditionKeys: Set<JSONKey> = ["path", "in"]

    private static let log = Logger(subsystem: "SubspaceKit", category: "mapping")

    /// Never fails: a malformed payload only leaves fields absent, and
    /// `default`s still apply.
    public static func apply(_ document: MappingDocument, to payload: JSONValue) -> MappingResult {
        var result = MappingResult(blockName: document.block)
        // Debug only: this runs per event, and `MappingLoader` already keeps
        // unknown formats out and logs which document it uses.
        // Differs from apply.py, which returns `{}` here: the result still
        // carries the empty block, so `jsonValue` is `{"<block>": {}}`. Every
        // target field is still absent, as §5 requires.
        guard document.format == supportedFormat else {
            let format = document.format.map(String.init) ?? "none"
            log.debug("Mapping document for \(document.source?.rawValue ?? "?", privacy: .public) has unknown format \(format, privacy: .public); applying nothing")
            return result
        }
        for field in document.core {
            result.core[JSONKey(field.name)] = value(of: field.spec, in: payload)
        }
        for field in document.fields {
            result.block[JSONKey(field.name)] = value(of: field.spec, in: payload)
        }
        return result
    }

    /// A spec is one rule or a list of them. The first rule whose `when` holds
    /// decides, even when it yields nothing; later rules are no fallback.
    static func value(of spec: JSONValue, in payload: JSONValue) -> JSONValue? {
        rule(of: spec, for: payload).flatMap { evaluate($0, in: payload) }
    }

    /// The rule of `spec` that decides for `payload`, nil if none applies.
    static func rule(of spec: JSONValue, for payload: JSONValue) -> [JSONKey: JSONValue]? {
        let rules: [JSONValue]
        if case let .array(list) = spec { rules = list } else { rules = [spec] }
        for case let .object(rule) in rules where applies(rule, to: payload) {
            return rule
        }
        return nil
    }

    /// An absent `when` holds; anything but a list of holding conditions doesn't.
    static func applies(_ rule: [JSONKey: JSONValue], to payload: JSONValue) -> Bool {
        guard let when = rule["when"] else { return true }
        guard case let .array(conditions) = when else { return false }
        return conditions.allSatisfy { holds($0, in: payload) }
    }

    static func holds(_ condition: JSONValue, in payload: JSONValue) -> Bool {
        guard case let .object(condition) = condition,
              Set(condition.keys).isSubset(of: conditionKeys),
              case let .array(allowed)? = condition["in"],
              case let .string(value)? = resolve(condition["path"], in: payload) else { return false }
        return allowed.contains(.string(value))
    }

    /// A rule whose `each` is under way: its elements are evaluated one by
    /// one, and its steps after `each` wait until all of them are.
    private struct Frame {
        let rule: [JSONKey: JSONValue]
        let each: JSONValue
        let elements: [JSONValue]
        /// How many elements are evaluated.
        var next = 0
        /// The values of the evaluated elements, those without one left out.
        var collected: [JSONValue] = []
    }

    /// What `begin` leaves of a rule: its value, or an `each` to go through.
    private enum Step {
        case done(JSONValue?)
        case each(Frame)
    }

    /// The steps in the order of §5.1. The rule's `when` already held.
    ///
    /// Iterative, with one `Frame` per `each` under way: recursing would take
    /// a few kilobytes of stack per nested `each` in a debug build, and a
    /// 512 KB thread stack (the cooperative pool's, dispatch's) would run out
    /// before the deepest document `MappingDocument(data:)` accepts. A rule
    /// without `each`, the common case, needs no frame.
    static func evaluate(_ rule: [JSONKey: JSONValue], in payload: JSONValue) -> JSONValue? {
        var frames: [Frame]
        switch begin(rule, in: payload) {
        case let .done(value): return value
        case let .each(outermost): frames = [outermost]
        }
        while let last = frames.indices.last {
            guard frames[last].next < frames[last].elements.count else {
                let frame = frames.removeLast()
                let value = finish(frame.rule, with: .array(frame.collected))
                guard let outer = frames.indices.last else { return value }
                if let value { frames[outer].collected.append(value) }
                continue
            }
            // Each element stands in for the payload: its pointers and `when`
            // start at the element. Elements without a value are left out.
            let element = frames[last].elements[frames[last].next]
            frames[last].next += 1
            guard let elementRule = Self.rule(of: frames[last].each, for: element) else { continue }
            switch begin(elementRule, in: element) {
            case let .done(value?): frames[last].collected.append(value)
            case .done(nil): break
            case let .each(frame): frames.append(frame)
            }
        }
        return nil
    }

    /// The steps up to `each`; `finish` does the rest. Stops at an `each`
    /// over an array, whose elements `evaluate` goes through.
    private static func begin(_ rule: [JSONKey: JSONValue], in payload: JSONValue) -> Step {
        // An unknown key is an operation this interpreter doesn't know: the
        // field stays absent, without even its default.
        guard Set(rule.keys).isSubset(of: ruleKeys) else { return .done(nil) }

        var value: JSONValue?
        let paths: [JSONValue?]
        if case let .array(list)? = rule["path"] { paths = list } else { paths = [rule["path"]] }
        for path in paths {
            value = resolve(path, in: payload)
            if value != nil { break }
        }

        if let parse = rule["parse"], let current = value {
            // Differs from apply.py where the parser differs from `json.loads`
            // (see `JSONReader`): `NaN`/`Infinity` and nesting over 512 levels give
            // no value here but one in Python (past about 10,000 levels Python
            // raises `RecursionError`, which apply.py does not catch); integers
            // over 4300 digits give a value here but none in Python.
            if parse == .string("json"), case let .string(text) = current {
                value = try? JSONValue(data: Data(text.utf8))
            } else {
                value = nil
            }
        }

        if let pick = rule["pick"] {
            // Only meaningful on a parsed value.
            value = rule["parse"] == nil ? nil : value.flatMap { resolve(pick, in: $0) }
        }

        if let each = rule["each"], let current = value {
            guard case let .array(elements) = current else { return .done(finish(rule, with: nil)) }
            return .each(Frame(rule: rule, each: each, elements: elements))
        }

        return .done(finish(rule, with: value))
    }

    /// The steps after `each`.
    private static func finish(_ rule: [JSONKey: JSONValue], with value: JSONValue?) -> JSONValue? {
        var value = value

        if let map = rule["map"], let current = value {
            if case let .object(table) = map, case let .string(key) = current {
                value = table[JSONKey(key)]
            } else {
                value = nil
            }
        }

        if let type = rule["type"], let current = value {
            let names: [JSONValue]
            if case let .array(list) = type { names = list } else { names = [type] }
            let matches = names.contains { name in
                if case let .string(name) = name { return has(current, type: name) }
                return false
            }
            if !matches { value = nil }
        }

        return value ?? rule["default"]
    }

    /// A pointer that is missing, not a string or invalid leads nowhere.
    static func resolve(_ pointer: JSONValue?, in document: JSONValue) -> JSONValue? {
        guard case let .string(text)? = pointer, let pointer = JSONPointer(text) else { return nil }
        return pointer.resolve(in: document)
    }

    /// An unknown type name never matches. The names are ASCII without a
    /// canonical equivalent, so `String` matching here is code-point matching.
    static func has(_ value: JSONValue, type name: String) -> Bool {
        switch (name, value) {
        case ("any", _): return true
        case ("string", .string): return true
        case ("id", let .string(text)): return !text.isEmpty
        case ("boolean", .bool): return true
        case ("integer", .integer), ("integer", .bigInteger): return true
        case ("number", .integer), ("number", .bigInteger), ("number", .number): return true
        case ("object", .object): return true
        case ("array", .array): return true
        case ("null", .null): return true
        default: return false
        }
    }
}
