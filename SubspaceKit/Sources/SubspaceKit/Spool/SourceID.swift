/// Identifies the tool an event came from, e.g. `"claude-code"`.
///
/// Deliberately an open string rather than an enum: adding a tool must not
/// require touching the model.
public struct SourceID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// The source's name as subspace writes it into the envelope, e.g. `claude-code`.
    public let rawValue: String

    /// Wraps a source name read from an envelope or a spool directory name.
    public init(rawValue: String) { self.rawValue = rawValue }
    /// Lets call sites and tests write a source as a plain string literal.
    public init(stringLiteral value: String) { self.rawValue = value }

    /// The bare source name, so it interpolates cleanly into logs and paths.
    public var description: String { rawValue }
}
