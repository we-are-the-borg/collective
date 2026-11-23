import Foundation
import Testing
@testable import CollectiveKit

private let key = SessionKey(source: "test-tool", sessionID: "s1")
private let other = SessionKey(source: "other-tool", sessionID: "s2")
/// Sub-second on purpose: the file must keep the exact `Date`.
private let now = Date(timeIntervalSince1970: 1_790_000_000.123_456)
private let day: TimeInterval = 24 * 60 * 60

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CollectiveKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct ArchiveFileTests {
    @Test func savedMarksLoadBackExactly() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = ArchiveFile(url: folder.appendingPathComponent("archive.json"))
        let marks: [ArchiveTarget: Date] = [
            .session(key): now.addingTimeInterval(-0.987_654),
            .agent(other, .subagent("a")): now.addingTimeInterval(-3 * day),
            .agent(other, .root): now,
        ]

        file.save(marks, now: now)

        #expect(file.load(now: now) == marks)
    }

    @Test func aMissingOrCorruptFileHasNoMarks() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("archive.json")
        #expect(ArchiveFile(url: url).load(now: now).isEmpty)

        try Data([0xFF, 0x00, 0x7B, 0x22]).write(to: url)
        #expect(ArchiveFile(url: url).load(now: now).isEmpty)
    }

    @Test func marksOlderThanThirtyDaysAreDroppedOnSaveAndLoad() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = ArchiveFile(url: folder.appendingPathComponent("archive.json"))
        let recent = ArchiveTarget.session(key)
        let aging = ArchiveTarget.agent(key, .subagent("a"))
        let old = ArchiveTarget.session(other)

        file.save([recent: now.addingTimeInterval(-29 * day),
                   aging: now.addingTimeInterval(-29 * day),
                   old: now.addingTimeInterval(-31 * day)], now: now)
        #expect(Set(file.load(now: now).keys) == [recent, aging])
        // Seen from two days earlier the old mark would be young again: only the
        // save can have dropped it.
        #expect(Set(file.load(now: now.addingTimeInterval(-2 * day)).keys) == [recent, aging])

        // Two days later the 29-day marks have aged past retention in the file.
        #expect(file.load(now: now.addingTimeInterval(2 * day)).isEmpty)
    }

    @Test func savingCreatesMissingFolders() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = ArchiveFile(url: folder.appendingPathComponent("Application Support/Collective/archive.json"))

        file.save([.session(key): now], now: now)

        #expect(file.load(now: now) == [.session(key): now])
    }

    @Test func archivedTargetsStayArchivedInANewState() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = ArchiveFile(url: folder.appendingPathComponent("archive.json"))
        var before = CollectiveState()
        before.apply(AgentEvent(session: key, timestamp: now, kind: .promptSubmitted("go")))
        before.apply(AgentEvent(session: other, timestamp: now, kind: .promptSubmitted("go")))
        before.archive(.session(key), at: now)
        before.archive(.agent(other, .subagent("a")), at: now)

        file.save(before.archiveMarks, now: now)
        // The new state has no sessions yet: marks must not depend on them.
        var after = CollectiveState()
        after.restoreArchive(file.load(now: now))

        #expect(after.isArchived(key))
        #expect(!after.isArchived(other))
        #expect(after.isArchived(.subagent("a"), in: other))
        #expect(!after.isArchived(.root, in: other))
    }
}
