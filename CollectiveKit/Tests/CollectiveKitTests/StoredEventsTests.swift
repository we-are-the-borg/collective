import Foundation
import Testing
@testable import CollectiveKit

/// A fresh folder as the app's Application Support one, with the path of the store in it.
private func supportFolder() throws -> (folder: URL, store: URL) {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("CollectiveKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return (folder, folder.appendingPathComponent("events.sqlite"))
}

/// The store's files as SQLite and `EventStore.moveAside` name them.
private let suffixes = ["", "-wal", "-shm", ".corrupt", ".corrupt-wal"]

/// Writes `count` bytes to `path`, creating the folders above it.
private func write(_ count: Int, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: count).write(to: url)
}

private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

@Suite struct StoredEventsTests {
    @Test func clearDeletesTheStoresFilesAndTheLeftoversAndNothingElse() throws {
        let (folder, store) = try supportFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for suffix in suffixes { try write(10, to: store.path + suffix) }
        let mirror = folder.appendingPathComponent("spool-mirror", isDirectory: true)
        try write(10, to: mirror.path + "/claude-code/events/2026-10-01/1.json")
        let file = folder.appendingPathComponent("old.json")
        try write(10, to: file.path)
        let archive = folder.appendingPathComponent("archive.json")
        try Data(#"{"archived":["s1"]}"#.utf8).write(to: archive)
        // As a reader that ran before left it.
        close(try SpoolReader.lock(store))
        let lock = store.path + ".lock"
        #expect(exists(lock))

        try StoredEvents(store: store, leftovers: [mirror, file]).clear()

        for suffix in suffixes { #expect(!exists(store.path + suffix), "\(suffix) is left") }
        #expect(!exists(mirror.path))
        #expect(!exists(file.path))
        #expect(exists(lock))
        #expect(try Data(contentsOf: archive) == Data(#"{"archived":["s1"]}"#.utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["archive.json", "events.sqlite.lock"])
    }

    /// E.g. the first launch, or a second click on the button.
    @Test func clearingWhatDoesNotExistIsNotAnError() throws {
        let (folder, store) = try supportFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = StoredEvents(store: store, leftovers: [folder.appendingPathComponent("spool-mirror", isDirectory: true)])

        try events.clear()
        try events.clear()
    }

    /// E.g. a second copy of the app reads with the store: its file is not
    /// pulled away under it.
    @Test func clearThrowsAndDeletesNothingWhileTheLockIsHeld() throws {
        let (folder, store) = try supportFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for suffix in suffixes { try write(10, to: store.path + suffix) }
        let mirror = folder.appendingPathComponent("spool-mirror", isDirectory: true)
        try write(10, to: mirror.path + "/1.json")
        let events = StoredEvents(store: store, leftovers: [mirror])
        let held = try SpoolReader.lock(store)

        #expect { try events.clear() } throws: { ($0 as? POSIXError)?.code == .EWOULDBLOCK }
        for suffix in suffixes { #expect(exists(store.path + suffix), "\(suffix) is gone") }
        #expect(exists(mirror.path + "/1.json"))

        // The failed attempt took nothing: the lock is free once its holder lets go.
        close(held)
        close(try SpoolReader.lock(store))
        try events.clear()
        #expect(!exists(store.path))
        // And so it is after a clearing that went through.
        close(try SpoolReader.lock(store))
    }

    /// A child process the app starts keeps a copy of a just-closed lock until
    /// its exec: the button waits for that instead of saying "in use".
    @Test func clearWaitsForALockLetGoOfShortlyAfter() throws {
        let (folder, store) = try supportFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for suffix in suffixes { try write(10, to: store.path + suffix) }
        let held = try SpoolReader.lock(store)
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.05)
            close(held)
        }

        try StoredEvents(store: store).clear()

        for suffix in suffixes { #expect(!exists(store.path + suffix), "\(suffix) is left") }
        close(try SpoolReader.lock(store))
    }

    /// What can't be deleted doesn't keep the rest: a half-cleared store would
    /// be worse than one with a leftover next to it.
    @Test func clearDeletesEverythingElseWhenOneDeletionFailsAndThenThrows() throws {
        let (folder, store) = try supportFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for suffix in suffixes { try write(10, to: store.path + suffix) }
        let readOnly = folder.appendingPathComponent("read-only", isDirectory: true)
        let stuck = readOnly.appendingPathComponent("old.json")
        try write(10, to: stuck.path)
        let mirror = folder.appendingPathComponent("spool-mirror", isDirectory: true)
        try write(10, to: mirror.path + "/1.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }

        #expect { try StoredEvents(store: store, leftovers: [stuck, mirror]).clear() } throws: {
            ($0 as? CocoaError)?.code == .fileWriteNoPermission
        }

        #expect(exists(stuck.path))
        #expect(!exists(mirror.path))
        for suffix in suffixes { #expect(!exists(store.path + suffix), "\(suffix) is left") }
        #expect(exists(store.path + ".lock"))
        close(try SpoolReader.lock(store))
    }

    /// The spool is subspace's (contract §3/§4): a folder chosen as event folder
    /// that holds the store, or lies in what the clear deletes, keeps it from
    /// creating or deleting anything.
    @Test func clearThrowsAndTouchesNothingWhenItOverlapsARoot() throws {
        let (folder, store) = try supportFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for suffix in suffixes { try write(10, to: store.path + suffix) }
        let mirror = folder.appendingPathComponent("spool-mirror", isDirectory: true)
        let root = mirror.appendingPathComponent("claude-code", isDirectory: true)
        try write(10, to: root.path + "/events/2026-10-01/1.json")
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("CollectiveKitTests-\(UUID().uuidString)")
        let before = try FileManager.default.subpathsOfDirectory(atPath: folder.path).sorted()

        // The store's folder, a parent of it, and a root inside a leftover.
        for roots in [[folder], [other, folder.deletingLastPathComponent()], [root]] {
            #expect(throws: StoredEvents.ClearError.overlapsSpoolRoot) {
                try StoredEvents(store: store, leftovers: [mirror], roots: roots).clear()
            }
            #expect(try FileManager.default.subpathsOfDirectory(atPath: folder.path).sorted() == before)
        }
        #expect(!exists(store.path + ".lock"))
    }

    /// The lock would create the store's folder: not inside a root either.
    @Test func clearCreatesNoFolderWhenItOverlapsARoot() throws {
        let (folder, _) = try supportFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = folder.appendingPathComponent("app/events.sqlite")

        #expect(throws: StoredEvents.ClearError.overlapsSpoolRoot) {
            try StoredEvents(store: store, roots: [folder]).clear()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func clearCatchesARootThatIsALinkToTheStoresFolder() throws {
        let (folder, store) = try supportFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(10, to: store.path)
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("CollectiveKitTests-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        defer { try? FileManager.default.removeItem(at: link) }

        #expect(throws: StoredEvents.ClearError.overlapsSpoolRoot) {
            try StoredEvents(store: store, roots: [link]).clear()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["events.sqlite"])
    }

    @Test func clearDeletesNextToRootsItDoesNotOverlap() throws {
        let (folder, store) = try supportFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for suffix in suffixes { try write(10, to: store.path + suffix) }
        let mirror = folder.appendingPathComponent("spool-mirror", isDirectory: true)
        try write(10, to: mirror.path + "/1.json")
        let root = folder.appendingPathComponent("subspace/claude-code", isDirectory: true)
        try write(10, to: root.path + "/events/2026-10-01/1.json")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("CollectiveKitTests-\(UUID().uuidString)")

        try StoredEvents(store: store, leftovers: [mirror], roots: [root, missing]).clear()

        for suffix in suffixes { #expect(!exists(store.path + suffix), "\(suffix) is left") }
        #expect(!exists(mirror.path))
        #expect(exists(root.path + "/events/2026-10-01/1.json"))
    }

    @Test func sizeIsTheSumOfWhatExists() throws {
        let (folder, store) = try supportFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mirror = folder.appendingPathComponent("spool-mirror", isDirectory: true)
        let file = folder.appendingPathComponent("old.json")
        let events = StoredEvents(store: store, leftovers: [mirror, file])
        #expect(events.size() == 0)

        try write(1000, to: store.path)
        try write(200, to: store.path + "-wal")
        #expect(events.size() == 1200)

        try write(30, to: store.path + "-shm")
        try write(4, to: store.path + ".corrupt")
        try write(5, to: store.path + ".corrupt-wal")
        try write(100_000, to: mirror.path + "/claude-code/events/2026-10-01/1.json")
        try write(20_000, to: mirror.path + "/codex/events/2026-10-02/2.json")
        try write(3000, to: file.path)
        #expect(events.size() == 124_239)
    }

    /// Neither the lock nor what else the app keeps in the folder is what the
    /// button deletes, so the number next to it doesn't count them.
    @Test func sizeCountsNeitherTheLockNorOtherFiles() throws {
        let (folder, store) = try supportFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(50, to: store.path + ".lock")
        try write(60, to: folder.appendingPathComponent("archive.json").path)
        #expect(StoredEvents(store: store).size() == 0)

        try write(7, to: store.path)
        #expect(StoredEvents(store: store).size() == 7)
    }
}
