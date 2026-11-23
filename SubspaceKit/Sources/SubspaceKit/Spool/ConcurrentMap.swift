import Foundation
import Synchronization

extension Array where Element: Sendable {
    /// `map` spread over the cores in contiguous chunks, results in input order.
    /// A list too short to be worth the tasks is mapped in place.
    public func concurrentMap<T: Sendable>(minimumChunk: Int = 32, _ transform: @escaping @Sendable (Element) -> T) async -> [T] {
        // A few chunks per core, so one slow chunk (large payloads) doesn't idle the rest.
        let chunks = ProcessInfo.processInfo.activeProcessorCount * 4
        let size = Swift.max(minimumChunk, (count + chunks - 1) / chunks)
        guard count > size else { return map(transform) }
        return await withTaskGroup(of: (Int, [T]).self) { group in
            for start in stride(from: 0, to: count, by: size) {
                let chunk = Array(self[start..<Swift.min(start + size, count)])
                group.addTask { (start, chunk.map(transform)) }
            }
            var parts: [Int: [T]] = [:]
            for await (start, part) in group { parts[start] = part }
            return parts.keys.sorted().flatMap { parts[$0]! }
        }
    }
}

extension Array where Element: Sendable {
    /// `concurrentMap` for synchronous code, e.g. inside a database
    /// transaction: the same chunks, run with `DispatchQueue.concurrentPerform`.
    /// It blocks the calling thread until every chunk is done, so it belongs on
    /// a dispatch queue (GRDB's writer queue), never on a cooperative thread.
    func blockingConcurrentMap<T: Sendable>(minimumChunk: Int = 32, _ transform: @Sendable (Element) -> T) -> [T] {
        // As in `concurrentMap`.
        let chunks = ProcessInfo.processInfo.activeProcessorCount * 4
        let size = Swift.max(minimumChunk, (count + chunks - 1) / chunks)
        guard count > size else { return map(transform) }
        let starts = Array<Int>(stride(from: 0, to: count, by: size))
        let elements = self
        let parts = Mutex<[Int: [T]]>([:])
        DispatchQueue.concurrentPerform(iterations: starts.count) { index in
            let start = starts[index]
            let part = elements[start..<Swift.min(start + size, elements.count)].map(transform)
            parts.withLock { $0[start] = part }
        }
        return parts.withLock { parts in starts.flatMap { parts[$0]! } }
    }
}
