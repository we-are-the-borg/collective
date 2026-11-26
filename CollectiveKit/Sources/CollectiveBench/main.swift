import CollectiveKit
import Foundation
import SubspaceKit

// Cold-backlog benchmark (not a test):
//
//   cd CollectiveKit && swift run -c release collective-bench [fileCount] [--store] [--runs N] [--fixtures <dir>] [--keep]
//
// It multiplies the captured fixture runs into a temporary spool root and times
// how long `SpoolReader` takes from start to `backlogFinished`.
//
// `--store` times what the app does: `SpoolReader` with a store. Per run, in this
// order: raw (no store, the reference), a cold start on a fresh store (the spool is
// ingested, then replayed from the database) and a warm start on the store the last
// cold run left (nothing is parsed, the database is replayed). Then the store's
// size on disk and the warm start as a share of raw. The event counts of the three
// must be equal.
//
// Fresh ids: every copy of a captured run gets its own session, agent and tool_use
// ids, or the copies would collapse into the same few sessions and the store would
// look different from a real backlog. The ids are found by regex in the raw bytes
// (UUIDs, `toolu_…`, and the values of `agent_id`)
// and replaced in every file of the run by the same text with its last eight
// characters set to the copy number in hex. Same length, same shape, unique per
// copy. Bench code only: the adapters are not involved in this.

// MARK: - Arguments

struct Options {
    var fileCount = 20_000
    var runs = 3
    var store = false
    var keep = false
    var fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/CollectiveKitTests/Fixtures", isDirectory: true)

    init(_ arguments: [String]) {
        var rest = arguments.dropFirst()[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--store": store = true
            case "--keep": keep = true
            case "--runs": runs = rest.popFirst().flatMap(Int.init) ?? runs
            case "--fixtures": fixtures = rest.popFirst().map { URL(fileURLWithPath: $0, isDirectory: true) } ?? fixtures
            default:
                guard let count = Int(argument), count > 0 else { fail("unknown argument \(argument)") }
                fileCount = count
            }
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("collective-bench: \(message)\n".utf8))
    exit(1)
}

// MARK: - Fixtures

/// One captured run: bare payload files in arrival order, and the source that sent them.
struct CapturedRun {
    let source: String
    let payloads: [String]
    /// The ids that must differ in every copy.
    let ids: [String]
}

func capturedRuns(in fixtures: URL) -> [CapturedRun] {
    let patterns = [
        "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
        "toolu_[A-Za-z0-9]{12,}",
        "(?<=\"agent_id\":\")[A-Za-z0-9_-]{12,}(?=\")",
    ].map { try! NSRegularExpression(pattern: $0) }
    var runs: [CapturedRun] = []
    for source in ["claude-code", "codex", "antigravity"] {
        let base = fixtures.appendingPathComponent(source, isDirectory: true)
        for path in (FileManager.default.subpaths(atPath: base.path) ?? []).sorted() where path.hasSuffix("/events") {
            let events = base.appendingPathComponent(path, isDirectory: true)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: events.path)) ?? [])
                .filter { $0.hasSuffix(".json") }.sorted()
            let payloads = names.compactMap { try? String(contentsOf: events.appendingPathComponent($0), encoding: .utf8) }
            guard !payloads.isEmpty else { continue }
            var ids: Set<String> = []
            for payload in payloads {
                let range = NSRange(payload.startIndex..., in: payload)
                for pattern in patterns {
                    for match in pattern.matches(in: payload, range: range) {
                        ids.insert(String(payload[Range(match.range, in: payload)!]))
                    }
                }
            }
            runs.append(CapturedRun(source: source, payloads: payloads, ids: ids.sorted()))
        }
    }
    return runs
}

/// `id` with its last eight characters replaced by `copy` in hex.
func freshID(_ id: String, copy: Int) -> String {
    id.dropLast(8) + String(format: "%08x", copy)
}

// MARK: - Spool

/// Writes about `count` event files, whole runs at a time, below `root/events/<day>/`.
/// Returns the number of files and bytes written.
func writeSpool(_ runs: [CapturedRun], count: Int, into root: URL) throws -> (files: Int, bytes: Int) {
    let fileManager = FileManager.default
    let start = Date().addingTimeInterval(-Double(count) / 100)
    var files = 0, bytes = 0, copy = 0
    var createdDays: Set<String> = []
    while files < count {
        let run = runs[copy % runs.count]
        copy += 1
        var payloads = run.payloads
        for id in run.ids {
            let fresh = freshID(id, copy: copy)
            payloads = payloads.map { $0.replacingOccurrences(of: id, with: fresh) }
        }
        for payload in payloads {
            // Ten milliseconds apart; 500 files per day folder.
            let mtime = start.addingTimeInterval(Double(files) / 100)
            let day = "day-\(String(format: "%05d", files / 500))"
            let folder = root.appendingPathComponent("events/\(day)", isDirectory: true)
            if createdDays.insert(day).inserted { try fileManager.createDirectory(at: folder, withIntermediateDirectories: true) }
            let envelope = #"{"v":1,"source":"\#(run.source)","ts":\#(mtime.timeIntervalSince1970),"pid":4242,"payload":\#(payload)}"#
            let file = folder.appendingPathComponent("\(String(format: "%08d", files))-4242-\(files).json")
            try Data(envelope.utf8).write(to: file)
            try fileManager.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
            files += 1
            bytes += envelope.utf8.count
        }
    }
    return (files, bytes)
}

// MARK: - Measuring

struct SilentWatcher: DirectoryWatching {
    func changes(under directory: URL) -> AsyncStream<Set<URL>?> { AsyncStream { _ in } }
}

/// One start: events counted until `backlogFinished`, and the seconds it took.
/// With `store`, the reader ingests new spool files into the database at that path
/// and replays from it; without, it parses every spool file.
func measure(root: URL, store: URL? = nil) async -> (events: Int, seconds: Double) {
    let environment = ["SUBSPACE_DIR": root.path]
    // The adapters' defaults otherwise: real meta readers, mapping from the temporary root (bundled documents).
    let reader = SpoolReader(
        adapters: [ClaudeCodeAdapter(mapping: ClaudeCodeAdapter.defaultMapping(environment: environment)),
                   CodexAdapter(mapping: CodexAdapter.defaultMapping(environment: environment)),
                   AntigravityAdapter(mapping: AntigravityAdapter.defaultMapping(environment: environment))],
        environment: environment, watcher: SilentWatcher(), store: store.map { SpoolReader.Store(path: $0, maxAge: nil) })
    var events = 0
    let clock = ContinuousClock()
    let began = clock.now
    var elapsed = Duration.zero
    for await output in await reader.events() {
        switch output {
        case .events(let batch), .replay(let batch, _): events += batch.count
        case .backlogFinished: elapsed = clock.now - began
        }
        if elapsed != .zero { break }
    }
    await reader.stop()
    return (events, seconds(elapsed))
}

func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

// MARK: - Measuring with a store

/// The bytes of the database at `path` with its WAL and shared memory files.
func storeSize(_ path: URL) -> Int {
    ["", "-wal", "-shm"].reduce(0) { total, suffix in
        let size = (try? FileManager.default.attributesOfItem(atPath: path.path + suffix))?[.size] as? Int
        return total + (size ?? 0)
    }
}

/// Runs `options.runs` starts of one kind, prints each and returns the best time and the event count.
func bench(_ label: String, _ start: (Int) async -> (events: Int, seconds: Double)) async -> (best: Double, events: Int) {
    var best = Double.infinity
    var events = 0
    for run in 1...options.runs {
        let result = await start(run)
        best = min(best, result.seconds)
        events = result.events
        print(String(format: "%@ run %d: %d events in %.3f s", label, run, result.events, result.seconds))
    }
    print(String(format: "best %@: %.3f s", label, best))
    return (best, events)
}

func benchStore(root: URL, work: URL) async {
    // One fresh store per cold run; the warm starts open the last one.
    let path = { (run: Int) in work.appendingPathComponent("store-\(run)/events.sqlite") }
    let raw = await bench("raw") { _ in await measure(root: root) }
    let cold = await bench("cold start") { await measure(root: root, store: path($0)) }
    let warm = await bench("warm start") { _ in await measure(root: root, store: path(options.runs)) }
    guard raw.events == cold.events, cold.events == warm.events else {
        fail("event counts differ: raw \(raw.events), cold \(cold.events), warm \(warm.events)")
    }
    print(String(format: "store size after closing: %.1f MB", Double(storeSize(path(options.runs))) / 1_048_576))
    print(String(format: "warm start / raw: %.0f %%", warm.best / raw.best * 100))
}

// MARK: - Main

let options = Options(CommandLine.arguments)
let runs = capturedRuns(in: options.fixtures)
guard !runs.isEmpty else { fail("no captured runs below \(options.fixtures.path)") }

let work = FileManager.default.temporaryDirectory.appendingPathComponent("collective-bench-\(UUID().uuidString)", isDirectory: true)
let root = work.appendingPathComponent("spool", isDirectory: true)
defer { if !options.keep { try? FileManager.default.removeItem(at: work) } }
print("Writing about \(options.fileCount) files from \(runs.count) captured runs to \(root.path) ...")
let written: (files: Int, bytes: Int)
do { written = try writeSpool(runs, count: options.fileCount, into: root) } catch { fail("\(error)") }
let megabytes = Double(written.bytes) / 1_048_576
print(String(format: "files: %d, %.1f MB", written.files, megabytes))

if options.store {
    await benchStore(root: root, work: work)
    // `exit` skips the `defer` above.
    if options.keep { print("kept \(work.path)") } else { try? FileManager.default.removeItem(at: work) }
    exit(0)
}

var best = Double.infinity
for run in 1...options.runs {
    let result = await measure(root: root)
    best = min(best, result.seconds)
    print(String(format: "run %d: %d events in %.3f s", run, result.events, result.seconds))
}
print(String(format: "best: %.3f s (%d files, %.1f MB)", best, written.files, megabytes))
if options.keep { print("kept \(work.path)") }
