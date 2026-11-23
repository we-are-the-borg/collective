import Foundation
import SubspaceKit

/// What `SpoolReader` uses of SubspaceKit's `EventStore`. A protocol so that
/// tests can hand the reader a store that fails.
protocol SpoolStore: AnyObject, Sendable {
    var maxAge: TimeInterval? { get set }
    func ingest(root: URL, changed: Set<URL>?, documents: [SourceID: MappingDocument?],
                excluding: [SourceID: Set<String>], now: Date) async throws -> IngestResult
    func prune(now: Date) async throws -> Int
    func replay() async throws -> [StoredEvent]
}

extension EventStore: SpoolStore {}
