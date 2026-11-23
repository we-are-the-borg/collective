import Foundation
import Testing
@testable import SubspaceKit

/// Real FSEvents against a temp folder laid out like a spool's `events/`.
@Suite struct FSEventsWatcherTests {
    let directory: URL
    let day: URL

    init() throws {
        directory = try temporaryDirectory()
        day = directory.appending(path: "events/2026-11-19", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    }

    @Test(.timeLimit(.minutes(1))) func fileEventsNameTheRenamedEventFile() async throws {
        let (reported, _) = try await firstReport(FSEventsWatcher(fileEvents: true)) { url in
            url.deletingLastPathComponent().lastPathComponent == "2026-11-19"
                && url.lastPathComponent.hasPrefix("event-") && url.lastPathComponent.hasSuffix(".json")
        }
        #expect(!reported.hasDirectoryPath)
    }

    @Test(.timeLimit(.minutes(1))) func directoryEventsNameTheDayFolderButNoFile() async throws {
        // The first report may still stem from creating the folders; by the
        // third, renames have been reported too, so "no file" means something.
        var dayReports = 0
        let (reported, seen) = try await firstReport(FSEventsWatcher()) { url in
            guard url.lastPathComponent == "2026-11-19" else { return false }
            dayReports += 1
            return dayReports == 3
        }
        #expect(reported.hasDirectoryPath)
        #expect(!seen.contains { $0.lastPathComponent.hasSuffix(".json") })
    }

    /// What the store's ingest needs from a watcher that reports files: in
    /// steady state a batch names the new event files and nothing that would
    /// list a day or every day. FSEvents names the root, `events/` and the day
    /// folder only in the first batch, which flushes their creation; writes
    /// after it name the files alone.
    @Test(.timeLimit(.minutes(1))) func fileEventsOfOrdinaryWritesAreReportedFilesOnly() async throws {
        let content = envelopeJSON(rawPayload: try capturedPayloadData("claude-code/009-PostToolUse.json"))
        let steady = await steadyBatches(writing: content, in: day) {
            let name = String(format: "event-%04d", $0)
            return (".\(name).tmp", "\(name).json")
        }
        var files: Set<String> = []
        for batch in steady {
            let report = try #require(SpoolListing.report(changed: batch), "every day for \(String(describing: batch))")
            #expect(report.days.isEmpty, "a day listing for \(String(describing: batch))")
            // A batch may name only a `.tmp` file, whose rename comes in the next.
            #expect(Set(report.files.keys).isSubset(of: ["2026-11-19"]))
            files.formUnion(report.files["2026-11-19"] ?? [])
        }
        #expect(!files.isEmpty)
        #expect(files.allSatisfy { $0.hasPrefix("event-") && $0.hasSuffix(".json") })
    }

    /// The plugin rewrites `plugin.json` in the root on every SessionStart,
    /// by renaming a temporary file over it (§3, §11; `spool.sh` names it
    /// `.plugin.json.<event name>.tmp`). In steady state FSEvents names those
    /// two files only, not the root, so the batch calls for nothing rather
    /// than every day.
    @Test(.timeLimit(.minutes(1))) func fileEventsOfAPluginJSONRewriteCallForNothing() async throws {
        let content = Data(#"{"v":1,"version":"1.0.0"}"#.utf8)
        let steady = await steadyBatches(writing: content, in: directory) { (".plugin.json.event-\($0).tmp", "plugin.json") }
        for batch in steady {
            let report = try #require(SpoolListing.report(changed: batch), "every day for \(String(describing: batch))")
            #expect(report == SpoolListing.Report(), "\(String(describing: batch))")
        }
    }

    /// Five batches FSEvents reports with file events while `folder` gets a
    /// file every 100 ms, written like the plugin writes: to the temporary
    /// name `named` gives, then renamed to the final one, over a file of
    /// that name if there is one. Batches up to the first naming a `.json`
    /// are skipped: that one also flushes the creation of the folders.
    private func steadyBatches(
        writing content: Data, in folder: URL, named: @escaping @Sendable (Int) -> (temporary: String, file: String)
    ) async -> [Set<URL>?] {
        defer { try? FileManager.default.removeItem(at: directory) }
        let stream = FSEventsWatcher(fileEvents: true).changes(under: directory)
        let writer = Task {
            for index in 0..<500 {
                let (temporary, file) = named(index)
                let temp = folder.appending(path: temporary)
                try content.write(to: temp)
                // rename(2), as `mv` does: it replaces an existing file.
                guard rename(temp.path, folder.appending(path: file).path) == 0 else { throw POSIXError(.EIO) }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { writer.cancel() }
        var steady: [Set<URL>?] = []
        var settling = true
        for await batch in stream {
            if settling {
                settling = !(batch ?? []).contains { $0.lastPathComponent.hasSuffix(".json") }
                continue
            }
            steady.append(batch)
            if steady.count == 5 { break }
        }
        #expect(steady.count == 5)
        return steady
    }

    /// Writes events the way the plugin does (`.<name>.tmp`, then renamed to
    /// `<name>.json`) every 100 ms until a reported URL `matches`, and returns
    /// it with every URL reported up to then. Keeps writing because a stream
    /// started with `SinceNow` misses whatever happens before FSEvents is ready.
    private func firstReport(
        _ watcher: FSEventsWatcher, matches: (URL) -> Bool
    ) async throws -> (match: URL, seen: [URL]) {
        defer { try? FileManager.default.removeItem(at: directory) }
        let stream = watcher.changes(under: directory)
        let content = envelopeJSON(rawPayload: try capturedPayloadData("claude-code/009-PostToolUse.json"))
        let day = self.day
        let writer = Task {
            for index in 0..<500 {
                let name = String(format: "event-%04d", index)
                let temp = day.appending(path: ".\(name).tmp")
                try content.write(to: temp)
                try FileManager.default.moveItem(at: temp, to: day.appending(path: "\(name).json"))
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { writer.cancel() }
        var seen: [URL] = []
        for await batch in stream {
            guard let batch else { continue }
            seen += batch
            if let match = batch.first(where: matches) { return (match, seen) }
        }
        Issue.record("the stream ended without reporting a matching URL")
        throw CancellationError()
    }
}
