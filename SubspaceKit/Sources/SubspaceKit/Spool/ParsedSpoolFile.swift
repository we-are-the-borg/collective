import Foundation

/// What one event file comes to once its envelope is read (contract §4) and its
/// source's mapping document applied (contract §12). Sendable, so files can be
/// parsed in parallel and only the outcomes cross back.
public enum ParsedSpoolFile: Sendable {
    /// The source's mapping document applied to the payload.
    case mapped(Envelope, MappingResult)
    /// A known source, but there is nothing to map with: it has no mapping
    /// document. The consumer reads the payload itself.
    case whole(Envelope)
    /// A valid envelope from a source the caller did not ask for.
    case foreign(Envelope)
    /// The file is unreadable or not a version-1 envelope (broken JSON,
    /// unknown `v`, missing field); a consumer skips it (contract §6).
    case failed(any Error)
}

extension SpoolFile {
    /// Reads and maps one event file. `documents` holds every source the caller
    /// handles, with nil for a source it knows but has no mapping document for.
    public static func parsed(from file: URL, documents: [SourceID: MappingDocument?]) -> ParsedSpoolFile {
        do {
            return parsed(from: try Data(contentsOf: file), documents: documents)
        } catch {
            return .failed(error)
        }
    }

    /// Like `parsed(from:documents:)` for a file URL, for callers that already
    /// hold the file's bytes.
    public static func parsed(from data: Data, documents: [SourceID: MappingDocument?]) -> ParsedSpoolFile {
        parsed(from: data, documents: documents, version: version)
    }

    /// `parsed(from:documents:)` accepting envelopes of `version`.
    static func parsed(from data: Data, documents: [SourceID: MappingDocument?], version: Int) -> ParsedSpoolFile {
        do {
            let (envelope, payload) = try read(data, version: version)
            return parsed(envelope, payload: payload, documents: documents)
        } catch {
            return .failed(error)
        }
    }

    /// Maps an envelope already read, whose `payload` parses to `payload`:
    /// e.g. one an `EventStore` kept whole and maps once its source has a
    /// document.
    static func parsed(_ envelope: Envelope, payload: JSONValue, documents: [SourceID: MappingDocument?]) -> ParsedSpoolFile {
        guard let document = documents[envelope.source] else { return .foreign(envelope) }
        guard let document else { return .whole(envelope) }
        return .mapped(envelope, MappingInterpreter.apply(document, to: payload))
    }
}
