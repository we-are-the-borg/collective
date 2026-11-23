import Foundation

/// Why an event file is not a usable envelope; a consumer skips such files.
public enum SpoolFileError: Error, Equatable {
    /// The file is not a JSON object.
    case notAJSONObject
    /// `v` is missing or not the version this package reads.
    case unknownVersion
    /// A required field is missing or has the wrong type.
    case missingField(String)
}

/// One event file of the subspace spool (contract §4):
/// `{"v":1,"source":"…","ts":…,"pid":…,"terminal":{…},"payload":{…}}`, where
/// `pid` and `terminal` are optional.
public enum SpoolFile {
    static let version = 1

    /// Decodes one event file's bytes; throws `SpoolFileError` for anything
    /// that is not a version-1 envelope, and the parser's error for a file that
    /// is not JSON.
    ///
    /// The envelope's `payload` is the payload re-serialized from the exact
    /// parse the mapping uses (`JSONValue`), not the file's original bytes: key
    /// order and number spelling may differ, but every key (also those that
    /// differ only in Unicode normalization), every string and every number's
    /// value and JSON type stay as the source sent them.
    public static func envelope(from data: Data) throws -> Envelope {
        try read(data).envelope
    }

    /// The envelope plus its payload as parsed, so `parsed(from:documents:)`
    /// maps the very value the envelope was built from without parsing again.
    /// `version` is the envelope version accepted; tests pass another to stand
    /// in for a package that reads a newer one.
    static func read(_ data: Data, version: Int = version) throws -> (envelope: Envelope, payload: JSONValue) {
        guard case let .object(json) = try JSONValue(data: data) else { throw SpoolFileError.notAJSONObject }
        // `v`, `ts` and `pid` accept what `JSONSerialization` (which read these
        // files before) accepted: any number equal to the value, so `1.0` is
        // version 1 and `4242.0` a pid. A bool is not a number here.
        guard json["v"].flatMap(integer) == Int64(version) else { throw SpoolFileError.unknownVersion }
        guard case let .string(source)? = json["source"], !source.isEmpty else { throw SpoolFileError.missingField("source") }
        guard let ts = json["ts"].flatMap(double), ts.isFinite else { throw SpoolFileError.missingField("ts") }
        guard let payload = json["payload"], case .object = payload else { throw SpoolFileError.missingField("payload") }
        let envelope = Envelope(
            source: SourceID(rawValue: source),
            pid: json["pid"].flatMap(integer).flatMap(Int32.init(exactly:)),
            payload: payload.serialized(),
            receivedAt: Date(timeIntervalSince1970: ts),
            terminal: json["terminal"].map(terminal) ?? [:]
        )
        return (envelope, payload)
    }

    /// The string members of `terminal`. It is optional and only a hint for
    /// apps, so a value of another shape loses the member (or, if `terminal`
    /// is not an object, all of them) instead of the event. Every name passes,
    /// known or not: which ones an app uses is the app's business (contract §4).
    private static func terminal(_ value: JSONValue) -> [String: String] {
        guard case let .object(members) = value else { return [:] }
        var terminal: [String: String] = [:]
        // `String` keys compare by canonical equivalence, `JSONKey` by code
        // point, so two names may become one key; in code point order the
        // first one wins, the same on every read.
        for key in members.keys.sorted() {
            if case let .string(string)? = members[key], terminal[key.string] == nil {
                terminal[key.string] = string
            }
        }
        return terminal
    }

    /// An integer, or a number with an integral value within `Int64`.
    private static func integer(_ value: JSONValue) -> Int64? {
        switch value {
        case let .integer(i): i
        case let .number(d): Int64(exactly: d)
        default: nil
        }
    }

    /// Any number as a double; an integer beyond `Int64` rounds.
    private static func double(_ value: JSONValue) -> Double? {
        switch value {
        case let .integer(i): Double(i)
        case let .bigInteger(digits): Double(digits)
        case let .number(d): d
        default: nil
        }
    }
}
