import Foundation
import SubspaceKit
import Testing
@testable import CollectiveKit

/// subspace rewrites `$ROOT/plugin.json` on every session start; a source with
/// several roots started its last session in the root whose file is newest.
@Suite struct LastSessionStartTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CollectiveKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePluginFile(in root: URL, at date: Date) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("plugin.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    @Test func theNewestPluginFileAcrossTheRootsCounts() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cli = base.appendingPathComponent("cli", isDirectory: true)
        let desktop = base.appendingPathComponent("desktop", isDirectory: true)
        let missing = base.appendingPathComponent("missing", isDirectory: true)
        try writePluginFile(in: cli, at: Date(timeIntervalSince1970: 1_790_000_000))
        try writePluginFile(in: desktop, at: Date(timeIntervalSince1970: 1_790_000_500))

        #expect(SubspaceRoot.lastSessionStart(in: [cli, missing, desktop]) == Date(timeIntervalSince1970: 1_790_000_500))
        #expect(SubspaceRoot.lastSessionStart(in: [cli]) == Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func noPluginFileInAnyRootIsNoSessionStart() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(SubspaceRoot.lastSessionStart(in: [base, base.appendingPathComponent("missing", isDirectory: true)]) == nil)
        #expect(SubspaceRoot.lastSessionStart(in: []) == nil)
    }
}
