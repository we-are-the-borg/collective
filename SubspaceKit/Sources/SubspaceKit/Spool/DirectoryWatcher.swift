import CoreServices
import Foundation

/// Reports changes below a directory. A protocol so reader tests run without FSEvents.
public protocol DirectoryWatching: Sendable {
    /// Each element holds the directories in which something changed or, for a
    /// watcher that reports at file level, the changed items themselves, files
    /// (file URLs) and directories, not the parent of a changed file. Items are
    /// not filtered: a named file may already be gone. An element is `nil`
    /// when the watcher lost track and everything must be rescanned. Watching
    /// starts before this returns; it stops when the stream is dropped.
    func changes(under directory: URL) -> AsyncStream<Set<URL>?>
}

/// Watches a directory tree recursively with FSEvents.
public struct FSEventsWatcher: DirectoryWatching {
    private let latency: TimeInterval
    private let fileEvents: Bool

    /// With `fileEvents`, FSEvents names the changed items themselves instead
    /// of their parent directories, so a consumer can read just the changed
    /// files instead of listing a folder that may hold thousands of them.
    /// Without it, only directories are reported.
    public init(latency: TimeInterval = 0.1, fileEvents: Bool = false) {
        self.latency = latency
        self.fileEvents = fileEvents
    }

    public func changes(under directory: URL) -> AsyncStream<Set<URL>?> {
        AsyncStream { continuation in
            let handle = Handle(continuation, fileEvents: fileEvents)
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(handle).toOpaque(),
                retain: nil, release: nil, copyDescription: nil
            )
            var flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer
            if fileEvents { flags |= kFSEventStreamCreateFlagFileEvents }
            guard let stream = FSEventStreamCreate(
                nil, Self.callback, &context, [directory.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, FSEventStreamCreateFlags(flags)
            ) else {
                continuation.finish()
                return
            }
            FSEventStreamSetDispatchQueue(stream, handle.queue)
            guard FSEventStreamStart(stream) else {
                // Not watching: release the stream and end, which consumers
                // treat like any ended watch (try again later).
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                continuation.finish()
                return
            }
            handle.stream = stream
            // Keeps the handle, and with it the callback's context, alive until the end.
            continuation.onTermination = { _ in handle.stop() }
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let handle = Unmanaged<Handle>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        let lostTrack = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
        )
        var changed: Set<URL> = []
        for index in 0..<count {
            if flags[index] & lostTrack != 0 {
                handle.continuation.yield(nil)
                return
            }
            // Without file events every path is a directory and the flag is not set.
            // An item of unknown kind counts as a directory: consumers ignore unknown
            // files but rescan for unknown directories, which is the safe side.
            let isDirectory = !handle.fileEvents || flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) == 0
            if index < paths.count { changed.insert(URL(fileURLWithPath: paths[index], isDirectory: isDirectory)) }
        }
        handle.continuation.yield(changed)
    }

    /// Owns the stream; FSEvents calls back on `queue` only.
    private final class Handle: @unchecked Sendable {
        let continuation: AsyncStream<Set<URL>?>.Continuation
        let fileEvents: Bool
        let queue = DispatchQueue(label: "SubspaceKit.FSEventsWatcher")
        var stream: FSEventStreamRef?

        init(_ continuation: AsyncStream<Set<URL>?>.Continuation, fileEvents: Bool) {
            self.continuation = continuation
            self.fileEvents = fileEvents
        }

        func stop() {
            queue.sync {
                guard let stream else { return }
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
    }
}
