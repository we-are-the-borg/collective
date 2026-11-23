import Foundation

/// One spool file as kept in an `EventStore`: its place in the spool, its
/// envelope fields and what parsing and mapping made of it, so a warm start
/// needs neither the file nor the mapping.
public struct StoredEvent: Sendable, Equatable {
    /// What the store keeps of the payload.
    public enum Content: Sendable, Equatable {
        /// The source's mapping document applied, minus the excluded fields.
        case mapped(MappingResult)
        /// A known source with nothing to map with (`ParsedSpoolFile.whole`):
        /// the payload bytes, so they can be mapped later.
        case whole(Data)
        /// A source the app did not ask for (`ParsedSpoolFile.foreign`): the
        /// payload bytes, so a later app version that knows it can map them.
        case foreign(Data)
    }

    /// The spool root the file was read from, standardized.
    public let root: URL
    /// The file's day folder (contract §4).
    public let day: String
    /// The file name, `.json` included.
    public let name: String
    /// The file's mtime in nanoseconds, the contract's order hint (§6).
    public let mtime: Int64
    /// The envelope's `source`.
    public let source: SourceID
    /// The envelope's `pid`.
    public let pid: Int32?
    /// The envelope's `ts`.
    public let receivedAt: Date
    /// The envelope's `terminal`; empty when it has none, and for events
    /// stored before the store kept it.
    public let terminal: [String: String]
    /// The mapped result or the payload bytes.
    public let content: Content

    /// The event's envelope, for code that handles spool files and stored
    /// events alike. Its `payload` holds the payload bytes of whole and foreign
    /// events but is empty (`Data()`) for mapped ones: the store keeps only the
    /// result, which is what a warm start reads instead.
    public var envelope: Envelope {
        let payload: Data
        switch content {
        case .mapped: payload = Data()
        case let .whole(bytes), let .foreign(bytes): payload = bytes
        }
        return Envelope(source: source, pid: pid, payload: payload, receivedAt: receivedAt, terminal: terminal)
    }
}
