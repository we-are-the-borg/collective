import Foundation

/// One event of the subspace spool (contract §4). The envelope is
/// source-neutral; only a consumer that knows the source understands `payload`.
public struct Envelope: Sendable, Equatable, Codable {
    /// The source that pushed the event.
    public let source: SourceID
    /// Process of the tool that sent this, if the forwarder knows it.
    public let pid: Int32?
    /// The payload, a JSON object, semantically exact as the source sent it:
    /// keys, strings and numbers (value and JSON type) are unchanged, but it is
    /// re-serialized (see `SpoolFile.envelope(from:)`), not the original bytes.
    public let payload: Data
    /// The envelope's `ts`.
    public let receivedAt: Date
    /// Terminal identifiers from the hook's environment, keyed by variable name
    /// (contract §4), so an app can bring the agent's terminal to the front.
    /// Empty when the envelope has none. It may hold names an app doesn't know;
    /// the app ignores those.
    public let terminal: [String: String]

    /// Builds an envelope, e.g. in tests; spool files go through `SpoolFile`.
    public init(source: SourceID, pid: Int32?, payload: Data, receivedAt: Date, terminal: [String: String] = [:]) {
        self.source = source
        self.pid = pid
        self.payload = payload
        self.receivedAt = receivedAt
        self.terminal = terminal
    }

    /// Like the synthesized decoder, but an envelope encoded before `terminal`
    /// existed still decodes, with none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(SourceID.self, forKey: .source)
        pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
        payload = try container.decode(Data.self, forKey: .payload)
        receivedAt = try container.decode(Date.self, forKey: .receivedAt)
        terminal = try container.decodeIfPresent([String: String].self, forKey: .terminal) ?? [:]
    }
}
