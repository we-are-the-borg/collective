import Foundation
import Synchronization

/// What a Codex child thread's rollout says about it in its first line, the
/// `session_meta` record. Hooks name a child only by its thread id; this is
/// where its parent and task name are (subspace contract §6, §8). The format is
/// internal to Codex, so everything but the id is optional.
public struct RolloutMeta: Sendable, Equatable {
    /// The thread id, i.e. `agent_id` of the child's hooks.
    public var id: String
    public var parentThreadID: String?
    /// Task path such as `/root/alpha`.
    public var agentPath: String?
    public var nickname: String?

    public init(id: String, parentThreadID: String? = nil, agentPath: String? = nil, nickname: String? = nil) {
        self.id = id
        self.parentThreadID = parentThreadID
        self.agentPath = agentPath
        self.nickname = nickname
    }
}

/// Reads rollout metadata. A protocol so adapter tests run without a file system.
public protocol RolloutMetaReading: Sendable {
    /// `nil` while the rollout doesn't exist yet or its first line can't be understood.
    func meta(rolloutPath: String) -> RolloutMeta?

    /// Who answers the permission requests of turn `turnID`, as its
    /// `turn_context` record says (`approvals_reviewer`, e.g. `auto_review` or
    /// `user`; subspace contract §6). No hook payload tells. `nil` while the
    /// record isn't written yet or the rollout can't be read.
    func approvalsReviewer(rolloutPath: String, turnID: String) -> String?

    /// The reasoning effort turn `turnID` runs at, as its `turn_context`
    /// record says (`effort`, e.g. `low` or `high`; subspace contract §6,
    /// `docs/model.md` §4.3). No hook payload tells. `nil` while the record
    /// isn't written yet or the rollout can't be read.
    func effort(rolloutPath: String, turnID: String) -> String?
}

/// Reads a rollout JSONL, read-only. Codex may still be writing it, so a
/// missing file or an unfinished line is simply no answer yet.
public struct FileRolloutMetaReader: RolloutMetaReading {
    /// The first line carries the base instructions, which can be long; beyond
    /// this the file is not a rollout we understand. A later line this long is
    /// tool output, never a `turn_context` record.
    private static let maxLineLength = 4 << 20

    /// How far each rollout was read and the turns found there. Rollouts
    /// grow to tens of megabytes and the event store is replayed at start, so
    /// a lookup reads on where the last one stopped instead of from the top.
    /// Kept here, next to the reading, rather than in the adapter's session
    /// state: a child's rollout is its own file. An entry is an offset and a
    /// few bytes per turn, but every session and child thread brings its own
    /// rollout, so the app would remember each one it ever ran beside; see
    /// `defaultMaxRollouts` for the bound.
    private let scans: RolloutScans

    /// Far more rollouts than sessions and children run at once, so a live
    /// one is never forgotten, while all entries together stay a few
    /// kilobytes. A rollout forgotten and asked about again is read once
    /// more from the start: slower, still right.
    static let defaultMaxRollouts = 128

    public init() { self.init(maxRollouts: Self.defaultMaxRollouts) }

    init(maxRollouts: Int) { scans = RolloutScans(capacity: maxRollouts) }

    public func meta(rolloutPath: String) -> RolloutMeta? {
        guard let line = Self.firstLine(of: URL(fileURLWithPath: rolloutPath)) else { return nil }
        return Self.parse(line)
    }

    public func approvalsReviewer(rolloutPath: String, turnID: String) -> String? {
        turnContext(rolloutPath: rolloutPath, turnID: turnID)?.approvalsReviewer
    }

    public func effort(rolloutPath: String, turnID: String) -> String? {
        turnContext(rolloutPath: rolloutPath, turnID: turnID)?.effort
    }

    /// The file is read on only while the turn's record wasn't seen yet;
    /// Codex writes a record once, so a seen one is the answer for good.
    private func turnContext(rolloutPath: String, turnID: String) -> TurnContext? {
        // The lock is held while the file is read, so lookups wait for each
        // other. They all come from the adapter, which correlates one envelope
        // after the other in spool order, so nothing waits in practice.
        scans.cache.withLock { cache in
            var scan = cache.take(rolloutPath) ?? TurnContextScan()
            if scan.turns[turnID] == nil { Self.read(URL(fileURLWithPath: rolloutPath), into: &scan) }
            cache.put(scan, for: rolloutPath)
            return scan.turns[turnID]
        }
    }

    /// Reads the complete lines after `scan.offset`; an unfinished last line
    /// is left for the next lookup. A file smaller than what was read is no
    /// longer the one read, so it is read from the start.
    private static func read(_ url: URL, into scan: inout TurnContextScan) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        if size < scan.offset { scan = TurnContextScan() }
        guard size > scan.offset, (try? handle.seek(toOffset: scan.offset)) != nil else { return }

        var line = Data()
        // Set once a line outgrows `maxLineLength`; the rest of it is skipped.
        var overlong = false
        var chunkStart = scan.offset
        while let chunk = try? handle.read(upToCount: 64 << 10), !chunk.isEmpty {
            var start = chunk.startIndex
            while let newline = chunk[start...].firstIndex(of: UInt8(ascii: "\n")) {
                if !overlong, line.count + (newline - start) <= maxLineLength {
                    line.append(chunk[start..<newline])
                    note(line, in: &scan)
                }
                line.removeAll(keepingCapacity: true)
                overlong = false
                start = newline + 1
                scan.offset = chunkStart + UInt64(start - chunk.startIndex)
            }
            if !overlong {
                if line.count + (chunk.endIndex - start) > maxLineLength {
                    overlong = true
                    line.removeAll()
                } else {
                    line.append(chunk[start...])
                }
            }
            chunkStart += UInt64(chunk.count)
        }
    }

    /// Only `turn_context` records are parsed. Inside a JSON string a quote
    /// is escaped, so tool output never holds the quoted type name and the
    /// check costs a byte search for every other line.
    private static func note(_ line: Data, in scan: inout TurnContextScan) {
        guard
            line.range(of: turnContextMarker) != nil,
            let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            json["type"] as? String == "turn_context",
            let payload = json["payload"] as? [String: Any],
            let turn = payload["turn_id"] as? String, !turn.isEmpty
        else { return }
        scan.turns[turn] = TurnContext(
            approvalsReviewer: payload["approvals_reviewer"] as? String,
            effort: payload["effort"] as? String
        )
    }

    private static let turnContextMarker = Data(#""turn_context""#.utf8)

    static func parse(_ line: Data) -> RolloutMeta? {
        guard
            let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            json["type"] as? String == "session_meta",
            let payload = json["payload"] as? [String: Any],
            let id = payload["id"] as? String, !id.isEmpty
        else { return nil }
        return RolloutMeta(
            id: id,
            parentThreadID: payload["parent_thread_id"] as? String,
            agentPath: payload["agent_path"] as? String,
            nickname: payload["agent_nickname"] as? String
        )
    }

    /// The bytes before the first newline; `nil` until a newline was written.
    private static func firstLine(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var line = Data()
        while line.count < maxLineLength {
            guard let chunk = try? handle.read(upToCount: 64 << 10), !chunk.isEmpty else { return nil }
            if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                line.append(chunk[chunk.startIndex..<newline])
                return line
            }
            line.append(chunk)
        }
        return nil
    }
}

/// What was read of one rollout.
private struct TurnContextScan {
    /// The end of the last complete line read.
    var offset: UInt64 = 0
    /// The records by `turn_id`.
    var turns: [String: TurnContext] = [:]
}

/// What the adapter needs of one `turn_context` record.
private struct TurnContext {
    var approvalsReviewer: String?
    var effort: String?
}

/// The scans of the most recently asked rollouts.
private struct ScanCache {
    let capacity: Int
    private var entries: [String: (scan: TurnContextScan, lastUse: UInt64)] = [:]
    private var uses: UInt64 = 0

    init(capacity: Int) { self.capacity = max(1, capacity) }

    mutating func take(_ path: String) -> TurnContextScan? {
        entries.removeValue(forKey: path)?.scan
    }

    /// A linear search for the oldest entry, only when a new rollout comes
    /// in; at this size cheaper to keep than a linked list.
    mutating func put(_ scan: TurnContextScan, for path: String) {
        if entries.count >= capacity, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            entries.removeValue(forKey: oldest.key)
        }
        uses += 1
        entries[path] = (scan, uses)
    }
}

/// A class so that the reader stays a `Sendable` value whose copies share
/// what was read.
private final class RolloutScans: Sendable {
    let cache: Mutex<ScanCache>

    init(capacity: Int) { cache = Mutex(ScanCache(capacity: capacity)) }
}
